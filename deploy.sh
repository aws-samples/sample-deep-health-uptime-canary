#!/usr/bin/env bash
#
# deploy.sh — one-step package + deploy for deep-health-uptime-canary.
#
# Wraps `aws cloudformation package` (uploads the nested templates to S3) and
# `aws cloudformation deploy` (root stack) so you don't juggle the S3 step by
# hand. Optionally deploys the serverless sample app and auto-wires its
# /health/deep URL into the monitoring canary.
#
# Usage:
#   ./deploy.sh --sample-app                       # deploy sample app + monitoring together
#   ./deploy.sh --target-url https://app/health/deep   # monitor your own endpoint
#
# Options:
#   --sample-app                Deploy the bundled sample app and monitor it (DeploySampleApp=yes).
#   --target-url <url>          Your /health/deep URL (required unless --sample-app).
#   --stack-name <name>         CloudFormation stack name (default: deep-health-uptime).
#   --bucket <name>             S3 bucket for packaged templates (default: auto-created per account/region).
#   --schedule <expr>           Canary schedule (default: "rate(5 minutes)").
#   --slo-ms <n>                End-to-end latency SLO in ms, incl. cold start (default: 3000).
#   --alarm-period <seconds>    Alarm evaluation period: 60|300|900|3600. Derived from --schedule
#                               automatically; pass this only to override the derived value.
#   --alarm-email <email>       Email subscribed to the alarm SNS topic (optional).
#   --vpc-subnets <ids>         Private subnet IDs (comma-separated) to run the canary in VPC mode
#                               (private endpoints). Non-VPC if omitted. 2+ in different AZs recommended.
#   --vpc-id <id>               VPC ID (vpc-...) the canary security group is created in. Required in
#                               VPC mode unless you pass --security-group.
#   --security-group <id>       Existing SG (sg-...) for the canary. Omit in VPC mode to have one created (egress 443).
#   --skip-egress-check         Skip the VPC-mode NAT/endpoint egress precheck (for TGW/central-egress/proxy setups).
#   --tag KEY=VALUE             Extra stack tag (repeatable). Propagates to all nested stacks + resources.
#   --region <region>           AWS region (default: current CLI/env region).
#   -h | --help                 Show this help.
#
set -euo pipefail

STACK_NAME="deep-health-uptime"
DEPLOY_SAMPLE="no"
TARGET_URL=""
BUCKET=""
SCHEDULE="rate(5 minutes)"
SLO_MS="3000"
ALARM_PERIOD="300"
ALARM_EMAIL=""
VPC_ID=""
VPC_SUBNETS=""
SECURITY_GROUP=""
SKIP_EGRESS_CHECK="no"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
# Stack-level tags — CloudFormation propagates these to every taggable resource
# in the root AND nested stacks.
TAGS=( "project=deep-health-uptime-canary" "managed-by=cloudformation" )

# Track which values the user passed explicitly, so interactive prompts only
# ask for the ones left at their default (and never override a flag).
STACK_NAME_SET="no"; SCHEDULE_SET="no"; ALARM_EMAIL_SET="no"; SAMPLE_SET="no"; TARGET_URL_SET="no"; VPC_SET="no"; SLO_MS_SET="no"; ALARM_PERIOD_SET="no"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_TEMPLATE="${ROOT_DIR}/iac/cloudformation/deploy.yaml"

die() { echo "Error: $*" >&2; exit 1; }

# Derive the CloudWatch alarm evaluation period from the probe schedule.
# CloudWatch evaluates an alarm once per period, so a period SHORTER than the probe
# interval leaves most periods with no datapoint: the availability alarm stalls on
# stale state and the latency alarm flaps ALARM->OK between runs. Snap up to the
# smallest allowed period (60|300|900|3600) that is >= the probe interval.
# Prints the period and returns 0, or returns 1 for a form we can't parse (cron).
derive_alarm_period() {
  local expr="$1" n unit mins
  if [[ "${expr}" =~ ^rate\(([0-9]+)[[:space:]]+(minute|minutes|hour|hours)\)$ ]]; then
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "${unit}" in
      hour|hours) mins=$(( n * 60 )) ;;
      *)          mins="${n}" ;;
    esac
    if   (( mins <= 1  )); then echo 60
    elif (( mins <= 5  )); then echo 300
    elif (( mins <= 15 )); then echo 900
    else                        echo 3600
    fi
    return 0
  fi
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sample-app)   DEPLOY_SAMPLE="yes"; SAMPLE_SET="yes"; shift ;;
    --target-url)   TARGET_URL="${2:-}"; TARGET_URL_SET="yes"; shift 2 ;;
    --stack-name)   STACK_NAME="${2:-}"; STACK_NAME_SET="yes"; shift 2 ;;
    --bucket)       BUCKET="${2:-}"; shift 2 ;;
    --schedule)     SCHEDULE="${2:-}"; SCHEDULE_SET="yes"; shift 2 ;;
    --slo-ms)       SLO_MS="${2:-}"; SLO_MS_SET="yes"; shift 2 ;;
    --alarm-period) ALARM_PERIOD="${2:-}"; ALARM_PERIOD_SET="yes"; shift 2 ;;
    --alarm-email)  ALARM_EMAIL="${2:-}"; ALARM_EMAIL_SET="yes"; shift 2 ;;
    --vpc-id)       VPC_ID="${2:-}"; VPC_SET="yes"; shift 2 ;;
    --vpc-subnets)  VPC_SUBNETS="${2:-}"; VPC_SET="yes"; shift 2 ;;
    --security-group) SECURITY_GROUP="${2:-}"; VPC_SET="yes"; shift 2 ;;
    --skip-egress-check) SKIP_EGRESS_CHECK="yes"; shift ;;
    --tag)          TAGS+=( "${2:-}" ); shift 2 ;;
    --region)       REGION="${2:-}"; shift 2 ;;
    -h|--help)      sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "Unknown option: $1 (use --help)" ;;
  esac
done

command -v aws >/dev/null 2>&1 || die "AWS CLI not found on PATH."

# The stack name prefixes every resource, including the Synthetics canary name, so it must
# satisfy the STRICTEST of the constraints in play: a CloudFormation stack name starts with
# a letter and allows only letters/digits/hyphens (no underscore), and a canary name is
# lowercase and at most 21 characters. Validate here so a bad --stack-name fails
# immediately with a clear message instead of deep inside CloudFormation.
STACK_NAME_RE='^[a-z][a-z0-9-]{0,20}$'
valid_stack_name() { [[ "$1" =~ ${STACK_NAME_RE} ]]; }
valid_stack_name "${STACK_NAME}" || die "Invalid --stack-name '${STACK_NAME}': must be 1-21 characters, start with a lowercase letter, and contain only lowercase letters, digits and hyphens (it prefixes the Synthetics canary name)."

# The target URL must carry a scheme — it is passed to the canary as a full URL and the
# template enforces the same pattern (TargetUrl AllowedPattern). Catching it here avoids
# packaging and uploading templates only to have CloudFormation reject the parameter.
valid_target_url() { [[ "$1" =~ ^https?://.+ ]]; }
if [[ -n "${TARGET_URL}" ]]; then
  valid_target_url "${TARGET_URL}" \
    || die "Invalid --target-url '${TARGET_URL}': must be a full URL including the scheme, e.g. https://app.example.com/health/deep."
fi

# Resolve region early (needed to detect the stack and to run the egress check).
if [[ -z "${REGION}" ]]; then
  REGION="$(aws configure get region || true)"
  [[ -n "${REGION}" ]] || die "No region set. Pass --region or configure the AWS CLI."
fi

# Detect CREATE vs UPDATE up front. On UPDATE we skip interactive prompts entirely and
# reuse the deployed parameter values for anything not passed as a flag, so a targeted
# change (e.g. just --target-url) never clobbers the existing schedule / SLO / email / VPC.
STACK_EXISTS="no"
DEPLOYED_PARAM_KEYS=""
DEPLOYED_SCHEDULE=""
if aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  STACK_EXISTS="yes"
  echo "Stack '${STACK_NAME}' exists — updating in place. Unspecified values keep their current deployed settings."
  # Which parameters the DEPLOYED stack actually has. UsePreviousValue is only legal for
  # parameters that already exist on the stack, so upgrading from an older version of this
  # repo (which had fewer parameters) must send a concrete value for the new ones instead.
  DEPLOYED_PARAM_KEYS="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query "Stacks[0].Parameters[].ParameterKey" --output text 2>/dev/null | tr '\t' ' ' || true)"
  # The deployed schedule, so the alarm period can be derived from what is ACTUALLY
  # running when the user updates without passing --schedule.
  DEPLOYED_SCHEDULE="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" \
    --query "Stacks[0].Parameters[?ParameterKey=='ScheduleExpression'].ParameterValue" --output text 2>/dev/null || true)"
fi

# True when the deployed stack already carries this parameter (so UsePreviousValue is safe).
has_deployed_param() {
  [[ " ${DEPLOYED_PARAM_KEYS} " == *" $1 "* ]]
}

# ---- Interactive prompts (only when attached to a terminal) ----
# Prompt for common options the user did NOT pass as flags. In non-interactive
# runs (CI, piped stdin) we skip prompting entirely and keep the defaults, so the
# script never hangs waiting for input.
if [[ -t 0 && "${STACK_EXISTS}" == "no" ]]; then
  # Stack name — drives every resource name; validate and re-ask on bad input.
  if [[ "${STACK_NAME_SET}" == "no" ]]; then
    while true; do
      read -r -p "Stack name (prefixes all resources) [${STACK_NAME}]: " _ans
      _ans="${_ans:-${STACK_NAME}}"
      if valid_stack_name "${_ans}"; then STACK_NAME="${_ans}"; break; fi
      echo "  Invalid: must be 1-21 chars of lowercase letters, digits and hyphens, starting with a letter."
    done
  fi
  # Sample app — offer to deploy the bundled sample target for end-to-end testing.
  if [[ "${SAMPLE_SET}" == "no" && "${TARGET_URL_SET}" == "no" ]]; then
    read -r -p "Deploy the sample app for end-to-end testing? [y/N]: " _ans
    case "${_ans}" in
      y|Y|yes|YES) DEPLOY_SAMPLE="yes" ;;
      *)
        DEPLOY_SAMPLE="no"
        # No sample app -> we need a target URL to monitor; prompt until it is a full URL.
        while ! valid_target_url "${TARGET_URL}"; do
          read -r -p "Your /health/deep URL to monitor: " TARGET_URL
          if [[ -z "${TARGET_URL}" ]]; then
            echo "  A target URL is required when not deploying the sample app."
          elif ! valid_target_url "${TARGET_URL}"; then
            echo "  Include the scheme, e.g. https://app.example.com/health/deep."
          fi
        done
        # Networking mode: public endpoint -> non-VPC (default); private -> VPC mode
        # (canary gets ENIs in your subnets). Only asked for your-own-endpoint deploys;
        # the sample app is always public. Skip if VPC was already set via flags.
        if [[ "${VPC_SET}" == "no" ]]; then
          read -r -p "Is that endpoint public or private? [public/private] (public): " _ans
          case "${_ans}" in
            private|PRIVATE|priv|p)
              echo "  VPC mode: the canary runs inside your VPC and needs egress to CloudWatch/S3 - a NAT Gateway route, or S3 + CloudWatch/logs VPC endpoints - or its runs will fail. This is checked before deploy."
              # VPC ID (needed so the stack can create the canary security group).
              while [[ ! "${VPC_ID}" =~ ^vpc-[0-9a-f]{8,}$ ]]; do
                read -r -p "  VPC ID (vpc-...): " VPC_ID
                [[ "${VPC_ID}" =~ ^vpc-[0-9a-f]{8,}$ ]] || echo "    Enter a valid VPC ID like vpc-0123456789abcdef0."
              done
              # Private subnet IDs - at least one; recommend 2+ in different AZs.
              while true; do
                read -r -p "  Private subnet IDs (comma-separated, 2+ in different AZs recommended): " VPC_SUBNETS
                if [[ "${VPC_SUBNETS}" =~ ^subnet-[0-9a-f]{8,}(,subnet-[0-9a-f]{8,})*$ ]]; then break; fi
                echo "    Enter one or more subnet IDs like subnet-0123...,subnet-0456... (no spaces)."
              done
              # Security group: optional - blank means the stack CREATES one (egress 443).
              while true; do
                read -r -p "  Security group ID [blank = create one for you]: " SECURITY_GROUP
                [[ -z "${SECURITY_GROUP}" ]] && { echo "    Will create a canary security group (egress 443) in ${VPC_ID}."; break; }
                [[ "${SECURITY_GROUP}" =~ ^sg-[0-9a-f]{8,}$ ]] && break
                echo "    Enter a valid security group ID like sg-0123456789abcdef0, or leave blank to have one created."
              done
              ;;
            *) : ;;  # public -> non-VPC, nothing more to ask
          esac
        fi
        ;;
    esac
  fi
  # Schedule — accept a plain number of minutes (1-60) and build the rate(...)
  # expression (singular 'minute' for 1, plural otherwise), or a full rate(...)
  # / cron(...) expression typed as-is. Re-ask on invalid input.
  if [[ "${SCHEDULE_SET}" == "no" ]]; then
    while true; do
      read -r -p "Canary schedule — minutes between probes (1-60), or a full rate()/cron() [${SCHEDULE}]: " _ans
      _ans="${_ans:-${SCHEDULE}}"
      if [[ "${_ans}" =~ ^[0-9]+$ ]]; then
        if (( _ans >= 1 && _ans <= 60 )); then
          if (( _ans == 1 )); then SCHEDULE="rate(1 minute)"; else SCHEDULE="rate(${_ans} minutes)"; fi
          break
        fi
        echo "  Enter a number of minutes between 1 and 60."
      elif [[ "${_ans}" =~ ^(rate|cron)\(.*\)$ ]]; then
        SCHEDULE="${_ans}"; break
      else
        echo "  Enter a number (e.g. 1 or 5) or a full expression like rate(1 minute)."
      fi
    done
    echo "  Schedule set to: ${SCHEDULE}"
  fi
  # Alarm email (optional; blank = skip SNS subscription).
  if [[ "${ALARM_EMAIL_SET}" == "no" ]]; then
    read -r -p "Alarm email (optional, blank to skip): " _ans
    ALARM_EMAIL="${_ans:-${ALARM_EMAIL}}"
  fi
fi

# ---- Alarm period: keep it in step with the probe interval ----------------------
# An explicit --alarm-period always wins, but it must be one of the values the
# template accepts — fail fast here rather than letting CloudFormation reject it.
if [[ "${ALARM_PERIOD_SET}" == "yes" ]]; then
  case "${ALARM_PERIOD}" in
    60|300|900|3600) : ;;
    *) die "--alarm-period must be one of 60, 300, 900, 3600 (seconds). Got '${ALARM_PERIOD}'." ;;
  esac
# Otherwise derive it from the schedule that will actually be in effect: the one passed
# / prompted for, or — on an update where --schedule was not given — the deployed one.
else
  EFFECTIVE_SCHEDULE="${SCHEDULE}"
  if [[ "${STACK_EXISTS}" == "yes" && "${SCHEDULE_SET}" == "no" && -n "${DEPLOYED_SCHEDULE}" && "${DEPLOYED_SCHEDULE}" != "None" ]]; then
    EFFECTIVE_SCHEDULE="${DEPLOYED_SCHEDULE}"
  fi
  if _derived="$(derive_alarm_period "${EFFECTIVE_SCHEDULE}")"; then
    ALARM_PERIOD="${_derived}"
    echo "Alarm period: ${ALARM_PERIOD}s (derived from ${EFFECTIVE_SCHEDULE})."
  else
    echo "Note: can't derive an alarm period from '${EFFECTIVE_SCHEDULE}' — using ${ALARM_PERIOD}s." >&2
    echo "      If your probe interval is longer than ${ALARM_PERIOD}s, pass --alarm-period (60|300|900|3600) to match it, or the alarms will flap." >&2
  fi
fi

# Must monitor something: either the sample app or a user-supplied target URL.
# Only required on CREATE — on an UPDATE the deployed stack already has a target
# (TargetUrl / sample app), which is kept via UsePreviousValue when not re-supplied.
if [[ "${STACK_EXISTS}" == "no" && "${DEPLOY_SAMPLE}" == "no" && -z "${TARGET_URL}" ]]; then
  die "Provide --target-url <url>, or use --sample-app to deploy and monitor the bundled sample app."
fi

# All resource names derive from the stack name (canary, alarms, dashboard, SNS,
# sample-app API, DynamoDB table). The AWS Synthetics canary name is the tightest
# constraint: <=21 chars, lowercase letters/digits/-/_ only. Validate up front and
# fail fast with a clear message rather than letting AWS reject it mid-deploy.
if [[ ! "${STACK_NAME}" =~ ^[a-z0-9][a-z0-9_-]{0,20}$ ]]; then
  die "Stack name '${STACK_NAME}' can't be used as the resource-name prefix.
  It must be 1-21 characters, lowercase letters/digits/-/_ only, and start with a letter or digit
  (the 21-char cap is the CloudWatch Synthetics canary-name limit, since every resource is named
  after the stack). Pick a shorter, lowercase --stack-name (e.g. 'deep-health')."
fi

# VPC mode is keyed on VpcSubnetIds. It is only meaningful for your own (private)
# endpoint — the sample app is public — and the canary security group is created for
# you (needs VpcId) unless you supply your own with --security-group.
if [[ -n "${VPC_SUBNETS}" || -n "${SECURITY_GROUP}" || -n "${VPC_ID}" ]]; then
  [[ -n "${VPC_SUBNETS}" ]] || die "VPC mode needs --vpc-subnets (comma-separated private subnet IDs)."
  if [[ "${DEPLOY_SAMPLE}" == "yes" ]]; then
    die "VPC mode can't be combined with --sample-app: the sample app is a public endpoint, so there is nothing private for an in-VPC canary to reach. Deploy the sample app non-VPC, or point a VPC-mode canary at your own private --target-url."
  fi
  # Validate ID formats (catches e.g. a security-group *name* instead of an sg-... ID).
  [[ "${VPC_SUBNETS}" =~ ^subnet-[0-9a-f]{8,}(,subnet-[0-9a-f]{8,})*$ ]] || die "--vpc-subnets must be comma-separated subnet IDs (subnet-...), no spaces."
  if [[ -n "${SECURITY_GROUP}" ]]; then
    [[ "${SECURITY_GROUP}" =~ ^sg-[0-9a-f]{8,}$ ]] || die "--security-group must be an existing security group ID (sg-...), not a name. Omit it to have one created for you."
  else
    # No SG override -> the stack creates one, which needs the VPC ID.
    [[ -n "${VPC_ID}" ]] || die "VPC mode needs --vpc-id (vpc-...) so the canary security group can be created, or pass --security-group <sg-...> to use your own."
    [[ "${VPC_ID}" =~ ^vpc-[0-9a-f]{8,}$ ]] || die "--vpc-id must be a valid VPC ID (vpc-...)."
  fi
fi


# ---- VPC-mode egress precheck ----------------------------------------------------
# A VPC-mode canary must reach CloudWatch + S3 to publish results. If the subnets have
# no NAT route AND the VPC has no S3 + CloudWatch/logs endpoints, every run will fail
# and the user pays for a broken monitor. Refuse in that case (override with
# --skip-egress-check for setups the script can't see, e.g. TGW/central-egress/proxy).
# The security group the stack creates for VPC mode allows egress on 443 ONLY, so a
# plain-http private target would be blocked and every run would fail. Warn (don't
# refuse — the user may be about to pass their own SG, and http targets are legitimate).
if [[ -n "${VPC_SUBNETS}" && -z "${SECURITY_GROUP}" && "${TARGET_URL}" == http://* ]]; then
  echo "Warning: the target URL is plain http, but the security group this stack creates for VPC mode allows egress on 443 only — the canary would not reach it." >&2
  echo "         Use an https endpoint, or pass --security-group <sg-...> with an egress rule for the target port." >&2
fi

if [[ -n "${VPC_SUBNETS}" && "${SKIP_EGRESS_CHECK}" == "no" ]]; then
  echo "Checking VPC egress for the canary subnets ..."
  # Evaluate BOTH paths (no short-circuit). The canary does not choose the path —
  # VPC routing/DNS does: an S3 gateway endpoint auto-wins over NAT for S3, and
  # interface endpoints (private DNS) auto-capture CloudWatch/logs. Endpoints, when
  # present, are preferred (AWS backbone, no NAT data charge). We report the real
  # picture and only refuse when NEITHER path can carry the traffic.
  _nat_ok="no"
  IFS=',' read -ra _subnets <<< "${VPC_SUBNETS}"
  for _sn in "${_subnets[@]}"; do
    # Find the route table governing this subnet: its EXPLICITLY-associated table if
    # one exists, else the VPC MAIN route table (subnets with no explicit association
    # use the main table). We must resolve the VPC first to find the main table.
    _sn_vpc="$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${_sn}" \
      --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
    # 1) explicit association.
    # The --query single quotes are REQUIRED: the backticks are JMESPath literal
    # syntax, and double-quoting would make the shell run them as commands.
    # shellcheck disable=SC2016
    _nat="$(aws ec2 describe-route-tables --region "${REGION}" \
      --filters "Name=association.subnet-id,Values=${_sn}" \
      --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && NatGatewayId!=`null`].NatGatewayId' \
      --output text 2>/dev/null || true)"
    # 2) fall back to the VPC main route table if no explicit association matched
    if [[ ( -z "${_nat}" || "${_nat}" == "None" ) && -n "${_sn_vpc}" && "${_sn_vpc}" != "None" ]]; then
      # shellcheck disable=SC2016  # JMESPath backtick literals — see above.
      _nat="$(aws ec2 describe-route-tables --region "${REGION}" \
        --filters "Name=vpc-id,Values=${_sn_vpc}" "Name=association.main,Values=true" \
        --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && NatGatewayId!=`null`].NatGatewayId' \
        --output text 2>/dev/null || true)"
    fi
    # A NAT id looks like nat-xxxx. Only count it when a real NAT id is present AND active.
    if [[ "${_nat}" == nat-* ]]; then
      _nat_state="$(aws ec2 describe-nat-gateways --region "${REGION}" --nat-gateway-ids "${_nat}" \
        --query 'NatGateways[0].State' --output text 2>/dev/null || true)"
      if [[ "${_nat_state}" == "available" ]]; then _nat_ok="yes"; break; fi
    fi
  done
  # Endpoint inventory for this VPC.
  _vpc_for_ep="${VPC_ID}"
  if [[ -z "${_vpc_for_ep}" ]]; then
    _vpc_for_ep="$(aws ec2 describe-subnets --region "${REGION}" --subnet-ids "${_subnets[0]}" \
      --query 'Subnets[0].VpcId' --output text 2>/dev/null || true)"
  fi
  _eps=""
  if [[ -n "${_vpc_for_ep}" && "${_vpc_for_ep}" != "None" ]]; then
    _eps="$(aws ec2 describe-vpc-endpoints --region "${REGION}" \
      --filters "Name=vpc-id,Values=${_vpc_for_ep}" \
      --query 'VpcEndpoints[].ServiceName' --output text 2>/dev/null || true)"
  fi
  _ep_s3="no"; _ep_cw="no"; _ep_logs="no"
  [[ "${_eps}" == *".s3"* ]] && _ep_s3="yes"
  [[ "${_eps}" == *".monitoring"* ]] && _ep_cw="yes"
  [[ "${_eps}" == *".logs"* ]] && _ep_logs="yes"
  _ep_full="no"
  [[ "${_ep_s3}" == "yes" && "${_ep_cw}" == "yes" && "${_ep_logs}" == "yes" ]] && _ep_full="yes"

  # Refuse only when NEITHER a NAT route NOR a full endpoint set exists.
  if [[ "${_nat_ok}" == "no" && "${_ep_full}" == "no" ]]; then
    die "VPC-mode egress check failed: the chosen subnets have no NAT Gateway default route, and the VPC does not have all of S3 + CloudWatch(monitoring) + logs endpoints (found: S3=${_ep_s3}, monitoring=${_ep_cw}, logs=${_ep_logs}). A VPC-mode canary cannot publish metrics/artifacts without egress to CloudWatch and S3, so every run would fail. Fix by adding a NAT Gateway route to these private subnets, or the missing S3 (gateway) / com.amazonaws.${REGION}.monitoring / .logs (interface) endpoints. Re-run with --skip-egress-check to proceed anyway (e.g. egress via Transit Gateway / a central egress VPC / a proxy the check can't see)."
  fi

  # Verbose, honest per-path report of how traffic will actually flow.
  echo "  Egress paths detected:"
  echo "    NAT default route: ${_nat_ok}"
  echo "    VPC endpoints — S3: ${_ep_s3}, CloudWatch(monitoring): ${_ep_cw}, logs: ${_ep_logs}"
  if [[ "${_ep_full}" == "yes" && "${_nat_ok}" == "yes" ]]; then
    echo "  -> Full endpoint set present: CloudWatch/S3 traffic uses the VPC endpoints (AWS backbone, no NAT data charge); NAT remains as fallback for anything else."
  elif [[ "${_ep_full}" == "yes" ]]; then
    echo "  -> CloudWatch/S3 traffic uses the VPC endpoints (AWS backbone, no NAT data charge)."
  elif [[ "${_nat_ok}" == "yes" ]]; then
    if [[ "${_ep_s3}" == "yes" || "${_ep_cw}" == "yes" || "${_ep_logs}" == "yes" ]]; then
      echo "  -> Partial endpoints present (used for those services); the rest egress via NAT. Add the missing endpoints to keep all monitoring traffic on the backbone."
    else
      echo "  -> CloudWatch/S3 traffic egresses via the NAT Gateway. Add S3 + monitoring + logs endpoints to avoid NAT data-processing charges and keep traffic on the AWS backbone."
    fi
  fi
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Auto-create a deterministic deploy bucket if none supplied.
if [[ -z "${BUCKET}" ]]; then
  BUCKET="deep-health-uptime-deploy-${ACCOUNT_ID}-${REGION}"
  if ! aws s3api head-bucket --bucket "${BUCKET}" >/dev/null 2>&1; then
    echo "Creating deploy bucket s3://${BUCKET} ..."
    if [[ "${REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}"
    else
      aws s3api create-bucket --bucket "${BUCKET}" --region "${REGION}" \
        --create-bucket-configuration LocationConstraint="${REGION}"
    fi
    aws s3api put-bucket-encryption --bucket "${BUCKET}" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block --bucket "${BUCKET}" \
      --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  fi
fi

PACKAGED="$(mktemp -t dhuc-packaged-XXXX).yaml"
trap 'rm -f "${PACKAGED}"' EXIT   # clean up the packaged-template temp file on any exit
echo "Packaging nested templates to s3://${BUCKET} ..."
aws cloudformation package \
  --template-file "${ROOT_TEMPLATE}" \
  --s3-bucket "${BUCKET}" \
  --output-template-file "${PACKAGED}" \
  --region "${REGION}"

# Assemble parameter overrides
# Assemble --parameter-overrides.
#   CREATE: pass concrete values (prompted/defaults/flags), as before.
#   UPDATE: for anything the user did NOT pass as a flag, reuse the deployed value with
#           ParameterKey=<k>,UsePreviousValue=true — so a targeted change (e.g. just
#           --target-url) leaves schedule / SLO / email / VPC untouched.
PARAMS=()
if [[ "${STACK_EXISTS}" == "no" ]]; then
  # --- CREATE ---
  PARAMS+=( "DeploySampleApp=${DEPLOY_SAMPLE}" "ScheduleExpression=${SCHEDULE}" "SloMs=${SLO_MS}" "AlarmPeriodSeconds=${ALARM_PERIOD}" )
  [[ -n "${TARGET_URL}"  ]] && PARAMS+=( "TargetUrl=${TARGET_URL}" )
  [[ -n "${ALARM_EMAIL}" ]] && PARAMS+=( "AlarmEmail=${ALARM_EMAIL}" )
  [[ -n "${VPC_SUBNETS}" ]] && PARAMS+=( "VpcSubnetIds=${VPC_SUBNETS}" )
  [[ -n "${SECURITY_GROUP}" ]] && PARAMS+=( "CanarySecurityGroupId=${SECURITY_GROUP}" )
  [[ -n "${VPC_ID}" ]] && PARAMS+=( "VpcId=${VPC_ID}" )
else
  # --- UPDATE: new value if flagged, else keep previous ---
  # DeploySampleApp / ScheduleExpression / SloMs always exist on the stack.
  if [[ "${SAMPLE_SET}" == "yes" || "${TARGET_URL_SET}" == "yes" ]]; then PARAMS+=( "DeploySampleApp=${DEPLOY_SAMPLE}" ); else PARAMS+=( "ParameterKey=DeploySampleApp,UsePreviousValue=true" ); fi
  if [[ "${SCHEDULE_SET}" == "yes" ]]; then PARAMS+=( "ScheduleExpression=${SCHEDULE}" ); else PARAMS+=( "ParameterKey=ScheduleExpression,UsePreviousValue=true" ); fi
  if [[ "${SLO_MS_SET}" == "yes" ]]; then PARAMS+=( "SloMs=${SLO_MS}" ); else PARAMS+=( "ParameterKey=SloMs,UsePreviousValue=true" ); fi
  # Send a new alarm period only when it was set explicitly or re-derived from a changed
  # --schedule; otherwise keep the deployed value so the two stay consistent. A stack
  # deployed before this parameter existed has nothing to keep, so send the value.
  if [[ "${ALARM_PERIOD_SET}" == "yes" || "${SCHEDULE_SET}" == "yes" ]] || ! has_deployed_param AlarmPeriodSeconds; then
    PARAMS+=( "AlarmPeriodSeconds=${ALARM_PERIOD}" )
  else
    PARAMS+=( "ParameterKey=AlarmPeriodSeconds,UsePreviousValue=true" )
  fi
  if [[ "${TARGET_URL_SET}" == "yes" ]]; then PARAMS+=( "TargetUrl=${TARGET_URL}" ); else PARAMS+=( "ParameterKey=TargetUrl,UsePreviousValue=true" ); fi
  if [[ "${ALARM_EMAIL_SET}" == "yes" ]]; then PARAMS+=( "AlarmEmail=${ALARM_EMAIL}" ); else PARAMS+=( "ParameterKey=AlarmEmail,UsePreviousValue=true" ); fi
  if [[ "${VPC_SET}" == "yes" ]]; then
    PARAMS+=( "VpcSubnetIds=${VPC_SUBNETS}" "CanarySecurityGroupId=${SECURITY_GROUP}" "VpcId=${VPC_ID}" )
  else
    PARAMS+=( "ParameterKey=VpcSubnetIds,UsePreviousValue=true" "ParameterKey=CanarySecurityGroupId,UsePreviousValue=true" "ParameterKey=VpcId,UsePreviousValue=true" )
  fi
fi

MODE_DESC="non-VPC (public, outside-in)"; [[ -n "${VPC_SUBNETS}" ]] && MODE_DESC="VPC mode (private endpoint)"
echo "Deploying stack '${STACK_NAME}' (DeploySampleApp=${DEPLOY_SAMPLE}, ${MODE_DESC}) in ${REGION} ..."
echo "Stack tags: ${TAGS[*]}"
aws cloudformation deploy \
  --template-file "${PACKAGED}" \
  --stack-name "${STACK_NAME}" \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "${PARAMS[@]}" \
  --tags "${TAGS[@]}" \
  --no-fail-on-empty-changeset \
  --region "${REGION}"

echo ""
echo "Done. Stack outputs:"
aws cloudformation describe-stacks --stack-name "${STACK_NAME}" --region "${REGION}" \
  --query "Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}" --output table

echo ""
echo "Tip: open the CloudWatch dashboard '${STACK_NAME}-uptime' to watch SuccessPercent and the uptime %."
