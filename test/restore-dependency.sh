#!/usr/bin/env bash
#
# restore-dependency.sh — undo break-dependency.sh by re-seeding the sample app's
# "health-sentinel" DynamoDB item. /health/deep returns 200 {status:"ok"} again,
# the canary goes green, and the availability alarm returns to OK.
#
# Usage:
#   ./restore-dependency.sh                         # auto-discovers the sample-app table
#   ./restore-dependency.sh --table <name>          # explicit table
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
    -h|--help)       sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown option: $1 (use --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH."
if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region || true)"
  [[ -n "${REGION}" ]] || die "No region set. Pass --region or configure the AWS CLI."
fi

if [[ -z "${TABLE}" ]]; then
  # 1) Try the named stack (standalone sample-app deploy).
  TABLE="$(aws cloudformation describe-stacks --stack-name "${SAMPLE_STACK}" --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null || true)"
  # 2) Fall back: scan ALL stacks for a HealthTableName output (nested-stack deploy).
  if [[ -z "${TABLE}" || "${TABLE}" == "None" ]]; then
    TABLE="$(aws cloudformation describe-stacks --region "${REGION}" \
      --query "Stacks[].Outputs[?OutputKey=='HealthTableName'].OutputValue" --output text 2>/dev/null \
      | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | head -n1 || true)"
  fi
  [[ -n "${TABLE}" && "${TABLE}" != "None" ]] || die "Could not auto-discover the sample-app table (searched stack '${SAMPLE_STACK}' and all stacks' HealthTableName outputs). Pass --table <name> (find it with: aws dynamodb list-tables --region ${REGION})."
fi

echo "Restoring dependency: re-seeding sentinel '${SENTINEL_ID}' into table '${TABLE}' (${REGION}) ..."
aws dynamodb put-item --region "${REGION}" \
  --table-name "${TABLE}" \
  --item "{\"id\":{\"S\":\"${SENTINEL_ID}\"},\"ok\":{\"BOOL\":true}}"

echo "Done. /health/deep returns 200 (ok) again — the canary recovers and the alarm returns to OK."
