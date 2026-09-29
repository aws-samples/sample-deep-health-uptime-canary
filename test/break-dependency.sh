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
# Usage:
#   ./break-dependency.sh                         # auto-discovers the sample-app table
#   ./break-dependency.sh --table <name>          # explicit table
#   ./break-dependency.sh --sample-stack <name>   # try this stack first (else all stacks are scanned)
#
# Options:
#   --table <name>          DynamoDB table holding the sentinel (skips discovery).
#   --sample-stack <name>   Sample-app stack to try first for the HealthTableName output. If not found, all stacks are scanned (covers the nested-stack deploy). Default: deep-health-uptime.
#   --sentinel-id <id>      Sentinel item id (default: health-sentinel).
#   --region <region>       AWS region (default: current CLI/env region).
#   -h | --help             Show this help.
#
set -euo pipefail

TABLE=""
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
    -h|--help)       sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown option: $1 (use --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH."
if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region || true)"
  [[ -n "${REGION}" ]] || die "No region set. Pass --region or configure the AWS CLI."
fi

# Discover the table name from the sample-app stack output if not provided.
# With the root/nested deploy (deploy.sh --sample-app), the sample app is a NESTED
# stack with an auto-generated name, so we try the named stack first, then
# named stack first, then fall back to scanning every stack for the HealthTableName
# output. Pass --table explicitly to skip discovery entirely.
if [[ -z "${TABLE}" ]]; then
  # 1) Try the named stack (works for a standalone sample-app deploy).
  TABLE="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null || true)"
  # 2) Fall back: scan only the DESCENDANTS of the target root stack for a
  #    HealthTableName output (catches the sample app deployed as a NESTED stack
  #    with an auto-generated name). Scoping to descendants avoids clobbering a
  #    sentinel in an unrelated stack when several deployments share the account.
  if [[ -z "${TABLE}" || "${TABLE}" == "None" ]]; then
    # Nested stacks carry a RootId pointing at the root stack's ARN. Find the root
    # stack ARN for SAMPLE_STACK, then match child stacks whose RootId equals it.
    ROOT_ID="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
      --query "Stacks[0].StackId" --output text 2>/dev/null || true)"
    if [[ -n "${ROOT_ID}" && "${ROOT_ID}" != "None" ]]; then
      # List stacks whose RootId is our root, then read HealthTableName from each.
      for child in $(aws cloudformation list-stacks --region "${REGION}" \
        --query "StackSummaries[?RootId=='${ROOT_ID}'].StackName" --output text 2>/dev/null | tr '\t' '\n'); do
        TABLE="$(aws cloudformation describe-stacks --stack-name "${child}" --region "${REGION}" \
          --query "Stacks[0].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null || true)"
        [[ -n "${TABLE}" && "${TABLE}" != "None" ]] && break
      done
    fi
  fi
  [[ -n "${TABLE}" && "${TABLE}" != "None" ]] || die "Could not auto-discover the sample-app table under stack '${SAMPLE_STACK}' (or its nested stacks). Pass --table <name> (find it with: aws dynamodb list-tables --region ${REGION})."
fi

echo "Breaking dependency: deleting sentinel '${SENTINEL_ID}' from table '${TABLE}' (${REGION}) ..."
aws dynamodb delete-item --region "${REGION}" \
  --table-name "${TABLE}" \
  --key "{\"id\":{\"S\":\"${SENTINEL_ID}\"}}"

echo "Done. /health/deep will now return 503 (degraded)."
echo "Within a run or two the canary fails and the availability alarm fires (check SNS email)."
echo "Restore with:  bash test/restore-dependency.sh --table ${TABLE}"
