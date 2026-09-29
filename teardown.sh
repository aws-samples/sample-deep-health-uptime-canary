#!/usr/bin/env bash
#
# teardown.sh — delete the deep-health-uptime-canary stack (and optionally the
# deploy bucket created by deploy.sh). Mirrors deploy.sh's defaults.
#
# Usage:
#   ./teardown.sh                          # delete the default stack
#   ./teardown.sh --stack-name my-stack    # delete a named stack
#   ./teardown.sh --delete-bucket          # also empty + remove the deploy bucket
#
# Options:
#   --stack-name <name>   CloudFormation stack to delete (default: deep-health-uptime).
#   --bucket <name>       Deploy bucket to remove (default: auto-derived per account/region).
#   --delete-bucket       Empty and delete the deploy bucket after the stack is gone.
#   --region <region>     AWS region (default: current CLI/env region).
#   -h | --help           Show this help.
#
# Note: the root stack owns the nested sample-app and monitoring stacks, so
# deleting it removes them too (canary, alarms, SNS, dashboard, WAF, Lambda,
# API Gateway, DynamoDB). CloudFormation cannot delete a non-empty S3 bucket, so
# this script first EMPTIES the canary artifact bucket(s) — otherwise the stack
# delete fails with DELETE_FAILED on ArtifactBucket.
#
# Two buckets, treated differently:
#   - ARTIFACT bucket — created INSIDE the stack; holds the canary's per-run
#     artifacts. A non-empty artifact bucket blocks delete-stack, so it is
#     ALWAYS emptied automatically here (you never ask for this).
#   - DEPLOY bucket   — created by deploy.sh OUTSIDE any stack to hold the
#     packaged templates. Not a stack resource, so delete-stack never touches
#     it; it is shared/reusable across every stack in this account+region, so
#     it SURVIVES by default. Removing it is the explicit --delete-bucket opt-in
#     (for a full cleanup when you won't deploy again).
#
set -euo pipefail

STACK_NAME="deep-health-uptime"
BUCKET=""
DELETE_BUCKET="no"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)    STACK_NAME="${2:-}"; shift 2 ;;
    --bucket)        BUCKET="${2:-}"; shift 2 ;;
    --delete-bucket) DELETE_BUCKET="yes"; shift ;;
    --region)        REGION="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "Unknown option: $1 (use --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH."

if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region || true)"
  [[ -n "${REGION}" ]] || die "No region set. Pass --region or configure the AWS CLI."
fi

# Stop all Synthetics canaries in this stack (and nested stacks) BEFORE emptying the
# artifact bucket. The canary runs on a schedule (as often as every minute) and writes
# a fresh artifact each run — if it keeps running during teardown it re-fills the bucket
# after we empty it, and CloudFormation then fails to delete the (non-empty) bucket.
stop_stack_canaries() {
  local stack="$1"
  local nested n
  nested="$(aws cloudformation list-stack-resources --stack-name "${stack}" --region "${REGION}" \
    --query "StackResourceSummaries[?ResourceType=='AWS::CloudFormation::Stack'].PhysicalResourceId" \
    --output text 2>/dev/null || true)"
  for n in ${nested}; do
    [[ -n "${n}" && "${n}" != "None" ]] && stop_stack_canaries "${n}"
  done
  local canaries c
  canaries="$(aws cloudformation list-stack-resources --stack-name "${stack}" --region "${REGION}" \
    --query "StackResourceSummaries[?ResourceType=='AWS::Synthetics::Canary'].PhysicalResourceId" \
    --output text 2>/dev/null || true)"
  for c in ${canaries}; do
    [[ -z "${c}" || "${c}" == "None" ]] && continue
    echo "Stopping canary '${c}' so it stops writing artifacts ..."
    aws synthetics stop-canary --name "${c}" --region "${REGION}" >/dev/null 2>&1 || true
  done
}

# CloudFormation refuses to delete a non-empty bucket. Empty the artifact bucket(s)
# owned by this stack (and its nested stacks) BEFORE deleting, so the delete succeeds.
empty_stack_buckets() {
  local stack="$1"
  # Recurse into nested stacks first.
  local nested
  nested="$(aws cloudformation list-stack-resources --stack-name "${stack}" --region "${REGION}" \
    --query "StackResourceSummaries[?ResourceType=='AWS::CloudFormation::Stack'].PhysicalResourceId" \
    --output text 2>/dev/null || true)"
  local n
  for n in ${nested}; do
    [[ -n "${n}" && "${n}" != "None" ]] && empty_stack_buckets "${n}"
  done
  # Empty any S3 buckets directly owned by this stack.
  local buckets b
  buckets="$(aws cloudformation list-stack-resources --stack-name "${stack}" --region "${REGION}" \
    --query "StackResourceSummaries[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
    --output text 2>/dev/null || true)"
  for b in ${buckets}; do
    [[ -z "${b}" || "${b}" == "None" ]] && continue
    echo "Emptying artifact bucket s3://${b} (objects + versions) ..."
    # Remove current objects.
    aws s3 rm "s3://${b}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    # Remove all versions + delete markers (in case versioning is enabled).
    local versions
    versions="$(aws s3api list-object-versions --bucket "${b}" --region "${REGION}" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null || echo '{}')"
    if command -v python3 >/dev/null 2>&1; then
      B="${b}" REGION="${REGION}" python3 -c '
import sys, json, subprocess
d = json.load(sys.stdin) or {}
import os
b = os.environ["B"]; region = os.environ["REGION"]
items = (d.get("Objects") or []) + (d.get("DeleteMarkers") or [])
items = [i for i in items if i and i.get("Key")]
for i in range(0, len(items), 1000):
    batch = items[i:i+1000]
    payload = json.dumps({"Objects": [{"Key": x["Key"], "VersionId": x["VersionId"]} for x in batch], "Quiet": True})
    subprocess.run(["aws","s3api","delete-objects","--bucket",b,"--region",region,"--delete",payload],
                   check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
' <<<"${versions}" 2>/dev/null || true
    fi
  done
}

echo "Stopping canaries so they stop writing to the artifact bucket ..."
stop_stack_canaries "${STACK_NAME}" || true
# Give any in-flight run a moment to finish writing before we empty.
sleep 5

echo "Emptying artifact bucket(s) before deletion ..."
empty_stack_buckets "${STACK_NAME}" || true
# Empty once more immediately before delete, to catch any artifact written by a
# run that was already in flight when the canary was stopped.
empty_stack_buckets "${STACK_NAME}" || true

echo "Deleting stack '${STACK_NAME}' in ${REGION} ..."
aws cloudformation delete-stack --stack-name "${STACK_NAME}" --region "${REGION}"
echo "Waiting for stack deletion to complete ..."
aws cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" --region "${REGION}"
echo "Stack '${STACK_NAME}' deleted."

if [[ "${DELETE_BUCKET}" == "yes" ]]; then
  if [[ -z "${BUCKET}" ]]; then
    ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    BUCKET="deep-health-uptime-deploy-${ACCOUNT_ID}-${REGION}"
  fi
  if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
    echo "Emptying and deleting deploy bucket s3://${BUCKET} ..."
    aws s3 rm "s3://${BUCKET}" --recursive --region "${REGION}" || true
    aws s3api delete-bucket --bucket "${BUCKET}" --region "${REGION}"
    echo "Deploy bucket removed."
  else
    echo "Deploy bucket s3://${BUCKET} not found — skipping."
  fi
fi

echo "Teardown complete."
