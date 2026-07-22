#!/usr/bin/env bash
# Discover existing cloud resources via AWS CLI (AWS or K2 Cloud / c2rc)
# and emit inventory JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AWS_REGION="${AWS_REGION:-eu-central-1}"
SKIP_BUCKET="${SKIP_BUCKET:-}"
SKIP_TABLE="${SKIP_TABLE:-}"
RC_FILE=""
# Default service set; for K2, rds/dynamodb/lambda are skipped unless explicitly requested
SERVICES="${SERVICES:-}"
DRY_RUN=false
OUTPUT_FILE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Discover cloud resources and print inventory JSON (or write to -o FILE).

Options:
  -c, --rc FILE           Source c2rc.sh-style credentials (K2 Cloud)
  -r, --region REGION     Region (default: from c2rc / eu-central-1)
  -s, --services LIST     Comma-separated services (or "all")
  --skip-bucket NAME      Exclude this S3 bucket
  --skip-table NAME       Exclude this DynamoDB table
  -o, --output FILE       Write JSON to file instead of stdout
  -n, --dry-run           Emit sample inventory without calling the API
  -h, --help              Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--rc)          RC_FILE="$2"; shift 2 ;;
    -r|--region)      AWS_REGION="$2"; shift 2 ;;
    -s|--services)    SERVICES="$2"; shift 2 ;;
    --skip-bucket)    SKIP_BUCKET="$2"; shift 2 ;;
    --skip-table)     SKIP_TABLE="$2"; shift 2 ;;
    -o|--output)      OUTPUT_FILE="$2"; shift 2 ;;
    -n|--dry-run)     DRY_RUN=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ -n "${RC_FILE}" ]]; then
  source_cloud_rc "${RC_FILE}"
  AWS_REGION="${AWS_REGION}"
fi

# Default services: K2-oriented set when endpoints present
if [[ -z "${SERVICES}" ]]; then
  if is_k2_cloud; then
    SERVICES="vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,elb"
  else
    SERVICES="vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,rds,dynamodb,lambda,elb"
  fi
fi

if [[ "${SERVICES}" == "all" ]]; then
  if is_k2_cloud; then
    SERVICES="vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,elb,iam_role"
  else
    SERVICES="vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,rds,dynamodb,lambda,elb,iam_role"
  fi
fi

IFS=',' read -r -a SERVICE_LIST <<< "${SERVICES}"

want() {
  local s
  for s in "${SERVICE_LIST[@]}"; do
    [[ "${s// /}" == "$1" ]] && return 0
  done
  return 1
}

RESOURCES_FILE="$(mktemp)"
trap 'rm -f "${RESOURCES_FILE}"' EXIT

add_resource() {
  local type="$1" id="$2" service="$3"
  local name
  name="$(tf_name "${type#aws_}_${id}")"
  case "${id}" in
    vpc-*|subnet-*|sg-*|i-*|vol-*|igw-*|nat-*|rtb-*|eipalloc-*)
      name="$(tf_name "${id}")"
      ;;
  esac
  jq -nc --arg type "${type}" --arg name "${name}" --arg id "${id}" --arg service "${service}" \
    '{type:$type, name:$name, id:$id, service:$service}' >> "${RESOURCES_FILE}"
}

safe_aws() {
  if ! "$@" 2>/tmp/aws-discover-err.txt; then
    warn "API call failed: $* — $(tr '\n' ' ' </tmp/aws-discover-err.txt)"
    return 1
  fi
}

discover_live() {
  export DISCOVERED_ACCOUNT_ID="${DISCOVERED_ACCOUNT_ID:-unknown}"
  if [[ -z "${DISCOVERED_ACCOUNT_ID}" || "${DISCOVERED_ACCOUNT_ID}" == "unknown" ]]; then
    if is_k2_cloud; then
      DISCOVERED_ACCOUNT_ID="${C2_PROJECT:-k2}"
    else
      DISCOVERED_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)"
    fi
    export DISCOVERED_ACCOUNT_ID
  fi

  if want vpc; then
    log "Scanning VPCs..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-vpcs --query 'Vpcs[].VpcId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_vpc" "${id}" "vpc"
    done
  fi

  if want subnet; then
    log "Scanning subnets..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-subnets --query 'Subnets[].SubnetId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_subnet" "${id}" "subnet"
    done
  fi

  if want route_table; then
    log "Scanning route tables..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-route-tables --query 'RouteTables[].RouteTableId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_route_table" "${id}" "route_table"
    done
  fi

  if want igw; then
    log "Scanning internet gateways..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-internet-gateways --query 'InternetGateways[].InternetGatewayId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_internet_gateway" "${id}" "igw"
    done
  fi

  if want nat; then
    log "Scanning NAT gateways..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-nat-gateways \
      --filter Name=state,Values=available \
      --query 'NatGateways[].NatGatewayId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_nat_gateway" "${id}" "nat"
    done
  fi

  if want eip; then
    log "Scanning Elastic IPs..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-addresses --query 'Addresses[].AllocationId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_eip" "${id}" "eip"
    done
  fi

  if want sg; then
    log "Scanning security groups..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-security-groups --query 'SecurityGroups[].GroupId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_security_group" "${id}" "sg"
    done
  fi

  if want ec2; then
    log "Scanning EC2 instances..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-instances \
      --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].InstanceId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_instance" "${id}" "ec2"
    done
  fi

  if want ebs; then
    log "Scanning EBS volumes..."
    local ids
    ids="$(safe_aws aws_svc ec2 ec2 describe-volumes --query 'Volumes[].VolumeId' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_ebs_volume" "${id}" "ebs"
    done
  fi

  if want s3; then
    log "Scanning S3 buckets..."
    local names
    names="$(safe_aws aws_svc s3 s3api list-buckets --query 'Buckets[].Name' --output text || true)"
    for name in ${names:-}; do
      [[ -z "${name}" || "${name}" == "None" ]] && continue
      [[ -n "${SKIP_BUCKET}" && "${name}" == "${SKIP_BUCKET}" ]] && continue
      if is_k2_cloud; then
        # K2: skip location filter — list-buckets is already endpoint-scoped
        add_resource "aws_s3_bucket" "${name}" "s3"
        continue
      fi
      local loc
      loc="$(aws_svc s3 s3api get-bucket-location --bucket "${name}" --query 'LocationConstraint' --output text 2>/dev/null || echo "unknown")"
      if [[ "${loc}" == "None" || "${loc}" == "null" ]]; then
        loc="us-east-1"
      fi
      if [[ "${loc}" != "unknown" && "${loc}" != "${AWS_REGION}" ]]; then
        continue
      fi
      add_resource "aws_s3_bucket" "${name}" "s3"
    done
  fi

  if want rds; then
    log "Scanning RDS instances..."
    local ids
    ids="$(safe_aws aws rds describe-db-instances --region "${AWS_REGION}" \
      --query 'DBInstances[].DBInstanceIdentifier' --output text || true)"
    for id in ${ids:-}; do
      [[ -n "${id}" && "${id}" != "None" ]] && add_resource "aws_db_instance" "${id}" "rds"
    done
  fi

  if want dynamodb; then
    log "Scanning DynamoDB tables..."
    local names
    names="$(safe_aws aws dynamodb list-tables --region "${AWS_REGION}" --query 'TableNames' --output text || true)"
    for name in ${names:-}; do
      [[ -z "${name}" || "${name}" == "None" ]] && continue
      [[ -n "${SKIP_TABLE}" && "${name}" == "${SKIP_TABLE}" ]] && continue
      add_resource "aws_dynamodb_table" "${name}" "dynamodb"
    done
  fi

  if want lambda; then
    log "Scanning Lambda functions..."
    local names
    names="$(safe_aws aws lambda list-functions --region "${AWS_REGION}" \
      --query 'Functions[].FunctionName' --output text || true)"
    for name in ${names:-}; do
      [[ -n "${name}" && "${name}" != "None" ]] && add_resource "aws_lambda_function" "${name}" "lambda"
    done
  fi

  if want elb; then
    log "Scanning load balancers..."
    local arns
    arns="$(safe_aws aws_svc elb elbv2 describe-load-balancers \
      --query 'LoadBalancers[].LoadBalancerArn' --output text || true)"
    for arn in ${arns:-}; do
      [[ -n "${arn}" && "${arn}" != "None" ]] && add_resource "aws_lb" "${arn}" "elb"
    done
  fi

  if want iam_role; then
    log "Scanning IAM roles..."
    local names
    names="$(safe_aws aws_svc iam iam list-roles --query 'Roles[].RoleName' --output text || true)"
    local count=0
    for name in ${names:-}; do
      [[ -z "${name}" || "${name}" == "None" ]] && continue
      [[ "${name}" == AWSServiceRole* ]] && continue
      add_resource "aws_iam_role" "${name}" "iam_role"
      count=$((count + 1))
      if [[ "${count}" -ge 100 ]]; then
        warn "IAM roles capped at 100"
        break
      fi
    done
  fi
}

discover_dry_run() {
  export DISCOVERED_ACCOUNT_ID="000000000000"
  add_resource "aws_vpc" "vpc-0dryrun000000001" "vpc"
  add_resource "aws_subnet" "subnet-0dryrun00000001" "subnet"
  add_resource "aws_security_group" "sg-0dryrun000000001" "sg"
  add_resource "aws_instance" "i-0dryrun0000000001" "ec2"
  add_resource "aws_s3_bucket" "dryrun-example-bucket" "s3"
}

if [[ "${DRY_RUN}" == true ]]; then
  discover_dry_run
else
  have aws || die "aws CLI is required"
  have jq || die "jq is required"
  verify_cloud_credentials
  discover_live
fi

DEDUPED="$(mktemp)"
if [[ ! -s "${RESOURCES_FILE}" ]]; then
  echo '[]' > "${DEDUPED}"
else
  jq -s '
    reduce .[] as $r ({seen:{}, out:[]};
      ($r.name) as $n
      | if .seen[$n] then
          .out += [$r + {name: ($n + "_" + ($r.id | gsub("[^a-zA-Z0-9]";"") | .[0:8]))}]
        else
          .seen[$n] = true | .out += [$r]
        end
    ) | .out
  ' "${RESOURCES_FILE}" > "${DEDUPED}"
fi

COUNT="$(jq 'length' "${DEDUPED}")"
SCANNED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CLOUD_NAME="aws"
is_k2_cloud && CLOUD_NAME="k2"
INVENTORY="$(jq -n \
  --arg region "${AWS_REGION}" \
  --arg account "${DISCOVERED_ACCOUNT_ID:-unknown}" \
  --arg cloud "${CLOUD_NAME}" \
  --argjson resources "$(cat "${DEDUPED}")" \
  --arg scanned "${SCANNED_AT}" \
  '{
    scanned_at: $scanned,
    cloud: $cloud,
    account_id: $account,
    region: $region,
    resource_count: ($resources | length),
    resources: $resources
  }')"

rm -f "${DEDUPED}"

log "Discovered ${COUNT} resources in ${AWS_REGION} (${CLOUD_NAME})" >&2

if [[ -n "${OUTPUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_FILE}")"
  printf '%s\n' "${INVENTORY}" > "${OUTPUT_FILE}"
  log "Wrote ${OUTPUT_FILE}" >&2
else
  printf '%s\n' "${INVENTORY}"
fi
