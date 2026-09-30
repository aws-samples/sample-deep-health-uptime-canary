#!/usr/bin/env bash
#
# break-dependency.sh — induce a REAL dependency failure in the sample app so the
# canary reports the app as down (503), the availability alarm fires, and SNS
# notifies you. Reversible with restore-dependency.sh.
#
# It deletes the "health-sentinel" item the sample app's /health/deep GetItem
# reads. With the item gone, the handler returns 503 {status:"degraded"}, so the
# canary fails with a genuine dependency error (not just a latency breach).
#
# SAMPLE APP ONLY — this breaks the bundled sample-app/ by deleting a DynamoDB item.
# It CANNOT break your own application's dependency, and pointing --table at one of
# your own tables is refused. See test/README.md for how to demo a failure against
# your own endpoint.
#
# Usage:
#   ./break-dependency.sh                         # interactive: prompts for whatever is not already set
#   ./break-dependency.sh --table <name> --region <r>  # non-interactive: use flags, no prompts
#   ./break-dependency.sh --table <name>          # explicit table
#   ./break-dependency.sh --sample-stack <name>   # root stack to discover the table from
#
# Options:
#   --table <name>          DynamoDB table holding the sentinel (skips discovery).
#   --sample-stack <name>   Root stack to discover the table from (reads its HealthTableName output, incl. its nested stacks). Default: deep-health-uptime (deploy.sh's default stack name).
#   --sentinel-id <id>      Sentinel item id (default: health-sentinel).
#   --region <region>       AWS region (default: current CLI/env region).
#   -h | --help             Show this help.
#
set -euo pipefail

TABLE=""
# Must match deploy.sh's default --stack-name, or a guided deploy that accepted the
# default cannot be discovered here.
SAMPLE_STACK="deep-health-uptime"
SENTINEL_ID="health-sentinel"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --table)         TABLE="${2:-}"; shift 2 ;;
    --sample-stack)  SAMPLE_STACK="${2:-}"; shift 2 ;;
    --sentinel-id)   SENTINEL_ID="${2:-}"; shift 2 ;;
    --region)        REGION="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown option: $1 (use --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH."

# Resolve the region. --region / AWS_REGION / AWS_DEFAULT_REGION win. Otherwise, when
# attached to a TTY, ASK — offering the configured CLI region as the default, so an
# interactive run is self-explanatory. Non-interactive runs take the configured region
# silently, or fail fast if there isn't one.
if [[ -z "${REGION}" ]]; then
  _def_region="$(aws configure get region 2>/dev/null || true)"
  if [[ -t 0 ]]; then
    read -r -p "AWS region${_def_region:+ [${_def_region}]}: " _in_region
    REGION="${_in_region:-${_def_region}}"
    [[ -n "${REGION}" ]] || die "No region provided. Pass --region or configure the AWS CLI."
  else
    REGION="${_def_region}"
    [[ -n "${REGION}" ]] || die "No region set. Pass --region or configure the AWS CLI."
  fi
fi

# Interactive prompts (only when attached to a TTY; any value already passed as a
# flag is kept and not re-asked). CI / non-interactive runs skip this entirely and
# fall back to flags + auto-discovery, so scripted behavior is unchanged.
if [[ -t 0 ]]; then
  if [[ -z "${TABLE}" ]]; then
    read -r -p "DynamoDB table name (leave blank to auto-discover from a stack): " TABLE
  fi
  if [[ -z "${TABLE}" ]]; then
    read -r -p "Sample-app / root stack name to discover the table from [${SAMPLE_STACK}]: " _in_stack
    SAMPLE_STACK="${_in_stack:-${SAMPLE_STACK}}"
  fi
fi

# Discover the table name if not provided (and not entered at the prompt). With the
# root/nested deploy the sample app is a NESTED stack with an auto-generated name, so
# we read the target root stack's HealthTableName output, scoped to its own descendants
# (never other stacks in the account). Pass --table explicitly to skip discovery.
if [[ -z "${TABLE}" ]]; then
  # 1) Direct HealthTableName output on the named stack (standalone sample-app deploy).
  TABLE="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null || true)"
  # 2) Deterministic name: the root deploy names the table '<root-stack>-health'
  #    (see iac/cloudformation/deploy.yaml). Try it directly and confirm it exists.
  if [[ -z "${TABLE}" || "${TABLE}" == "None" ]]; then
    _cand="${SAMPLE_STACK}-health"
    if aws dynamodb describe-table --table-name "${_cand}" --region "${REGION}" >/dev/null 2>&1; then
      TABLE="${_cand}"
    fi
  fi
  # 3) Fall back: scan only the DESCENDANTS of the named root stack for a HealthTableName
  #    output, scoped via RootId so an unrelated deployment's table is never touched.
  if [[ -z "${TABLE}" || "${TABLE}" == "None" ]]; then
    # Resolve the root: use this stack's RootId if it is itself nested, else its own StackId.
    ROOT_ID="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
      --query "Stacks[0].RootId" --output text 2>/dev/null || true)"
    if [[ -z "${ROOT_ID}" || "${ROOT_ID}" == "None" ]]; then
      ROOT_ID="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
        --query "Stacks[0].StackId" --output text 2>/dev/null || true)"
    fi
    if [[ -n "${ROOT_ID}" && "${ROOT_ID}" != "None" ]]; then
      for child in $(aws cloudformation list-stacks --region "${REGION}" \
        --query "StackSummaries[?RootId=='${ROOT_ID}'].StackName" --output text 2>/dev/null | tr '\t' '\n'); do
        TABLE="$(aws cloudformation describe-stacks --stack-name "${child}" --region "${REGION}" \
          --query "Stacks[0].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null || true)"
        [[ -n "${TABLE}" && "${TABLE}" != "None" ]] && break
      done
    fi
  fi
  [[ -n "${TABLE}" && "${TABLE}" != "None" ]] || die "Could not find the sample-app table for stack '${SAMPLE_STACK}' (tried its HealthTableName output, '${SAMPLE_STACK}-health', and its nested stacks). Pass --table <name> (list them: aws dynamodb list-tables --region ${REGION})."
fi

# --- Safety guards -----------------------------------------------------------------
# Auto-discovery is already scoped to the target stack and its descendants, but an
# explicit --table is not. Verify the target really is a sample-app table BEFORE
# issuing any delete, so a mistyped or hand-passed --table can never remove an item
# from an unrelated table. The sample app's table (sample-app/sample-app.yaml) is
# keyed on a single 'id' String partition key with no sort key.
_keys="$(aws dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" \
  --query "Table.KeySchema[].AttributeName" --output text 2>/dev/null | tr '\t' ' ' || true)"
[[ -n "${_keys}" && "${_keys}" != "None" ]] || die "Table '${TABLE}' not found in ${REGION}."
if [[ "${_keys}" != "id" ]]; then
  die "Table '${TABLE}' is keyed on '${_keys}', but the sample-app table uses a single 'id' partition key. Refusing to modify it. These scripts work ONLY against the bundled sample app (sample-app/) — they cannot break your own application's dependency. See test/README.md for how to demo a failure against your own endpoint."
fi

# The sentinel must exist, or there is nothing to break. This matters because
# DynamoDB delete-item on a non-existent key SUCCEEDS silently — without this check
# the script would print "now returns 503" having changed nothing.
_sentinel="$(aws dynamodb get-item --table-name "${TABLE}" --region "${REGION}" \
  --key "{\"id\":{\"S\":\"${SENTINEL_ID}\"}}" --query 'Item.id.S' --output text 2>/dev/null || true)"
if [[ -z "${_sentinel}" || "${_sentinel}" == "None" ]]; then
  die "Table '${TABLE}' has no '${SENTINEL_ID}' item, so there is nothing to break. If you already ran this script the dependency is ALREADY broken — restore it with: bash test/restore-dependency.sh --table ${TABLE} --region ${REGION}. If you have not, then --table is not pointing at the sample app's table."
fi
# -----------------------------------------------------------------------------------

echo "Breaking dependency: deleting sentinel '${SENTINEL_ID}' from table '${TABLE}' (${REGION}) ..."
aws dynamodb delete-item --region "${REGION}" \
  --table-name "${TABLE}" \
  --key "{\"id\":{\"S\":\"${SENTINEL_ID}\"}}"

echo "Done. /health/deep will now return 503 (degraded)."
echo "Within a run or two the canary fails and the availability alarm fires (check SNS email)."
echo "Restore with:  bash test/restore-dependency.sh --table ${TABLE}"
