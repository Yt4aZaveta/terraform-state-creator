#!/usr/bin/env bash
# Bootstrap Terraform remote state in AWS using AWS CLI.
# Creates: S3 bucket (state) + DynamoDB table (locking).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Defaults (override via env or flags)
# ---------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-eu-central-1}"
STATE_BUCKET="${STATE_BUCKET:-}"
LOCK_TABLE="${LOCK_TABLE:-terraform-state-lock}"
PROJECT_PREFIX="${PROJECT_PREFIX:-tfstate}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/generated}"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Creates an S3 backend for Terraform remote state via AWS CLI.

Options:
  -b, --bucket NAME       S3 bucket name for state (required if STATE_BUCKET unset)
  -t, --table NAME        DynamoDB lock table (default: ${LOCK_TABLE})
  -r, --region REGION     AWS region (default: ${AWS_REGION})
  -p, --prefix PREFIX     Used to auto-generate bucket name if -b omitted
                          (bucket = PREFIX-<account-id>-REGION)
  -o, --output DIR        Where to write backend.hcl (default: ./generated)
  -n, --dry-run           Print actions without calling AWS
  -h, --help              Show this help

Environment:
  AWS_PROFILE / AWS credentials must allow s3, dynamodb, sts.
  AWS_REGION, STATE_BUCKET, LOCK_TABLE, PROJECT_PREFIX, OUTPUT_DIR

Example:
  ./scripts/create-terraform-state.sh -b my-org-tfstate -r eu-central-1
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bucket)  STATE_BUCKET="$2"; shift 2 ;;
    -t|--table)   LOCK_TABLE="$2"; shift 2 ;;
    -r|--region)  AWS_REGION="$2"; shift 2 ;;
    -p|--prefix)  PROJECT_PREFIX="$2"; shift 2 ;;
    -o|--output)  OUTPUT_DIR="$2"; shift 2 ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "${DRY_RUN}" != true ]]; then
  command -v aws >/dev/null 2>&1 || die "aws CLI is required. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  command -v jq  >/dev/null 2>&1 || die "jq is required. Install jq and retry."
fi

# ---------------------------------------------------------------------------
# Resolve account / bucket name
# ---------------------------------------------------------------------------
log "Checking AWS identity..."
if [[ "${DRY_RUN}" == true ]]; then
  ACCOUNT_ID="000000000000"
  CALLER_ARN="arn:aws:iam::000000000000:user/dry-run"
else
  CALLER_JSON="$(aws sts get-caller-identity --output json)"
  ACCOUNT_ID="$(echo "${CALLER_JSON}" | jq -r '.Account')"
  CALLER_ARN="$(echo "${CALLER_JSON}" | jq -r '.Arn')"
fi
log "Account: ${ACCOUNT_ID}"
log "Caller:  ${CALLER_ARN}"
log "Region:  ${AWS_REGION}"

if [[ -z "${STATE_BUCKET}" ]]; then
  STATE_BUCKET="${PROJECT_PREFIX}-${ACCOUNT_ID}-${AWS_REGION}"
  log "Generated bucket name: ${STATE_BUCKET}"
fi

# S3 bucket naming: lowercase, no underscores
if [[ ! "${STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
  die "Invalid bucket name '${STATE_BUCKET}'. Use lowercase letters, digits, dots, hyphens."
fi

# ---------------------------------------------------------------------------
# S3: create bucket + harden
# ---------------------------------------------------------------------------
bucket_exists() {
  aws s3api head-bucket --bucket "$1" --region "${AWS_REGION}" 2>/dev/null
}

log "Ensuring S3 bucket '${STATE_BUCKET}'..."
if [[ "${DRY_RUN}" != true ]] && bucket_exists "${STATE_BUCKET}"; then
  log "Bucket already exists — skipping create"
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    run aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}"
  else
    run aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
  fi
fi

log "Enabling versioning..."
run aws s3api put-bucket-versioning \
  --bucket "${STATE_BUCKET}" \
  --region "${AWS_REGION}" \
  --versioning-configuration Status=Enabled

log "Enabling default SSE-S3 encryption..."
run aws s3api put-bucket-encryption \
  --bucket "${STATE_BUCKET}" \
  --region "${AWS_REGION}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'

log "Blocking public access..."
run aws s3api put-public-access-block \
  --bucket "${STATE_BUCKET}" \
  --region "${AWS_REGION}" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

log "Enabling bucket ownership controls (BucketOwnerEnforced)..."
run aws s3api put-bucket-ownership-controls \
  --bucket "${STATE_BUCKET}" \
  --region "${AWS_REGION}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# Deny non-TLS access
BUCKET_POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
EOF
)"
log "Applying bucket policy (deny non-TLS)..."
if [[ "${DRY_RUN}" == true ]]; then
  printf '[dry-run] put-bucket-policy for %s\n' "${STATE_BUCKET}"
else
  aws s3api put-bucket-policy \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    --policy "${BUCKET_POLICY}"
fi

# ---------------------------------------------------------------------------
# DynamoDB: state lock table
# ---------------------------------------------------------------------------
table_exists() {
  aws dynamodb describe-table \
    --table-name "$1" \
    --region "${AWS_REGION}" \
    --output text \
    --query 'Table.TableName' 2>/dev/null
}

log "Ensuring DynamoDB lock table '${LOCK_TABLE}'..."
if [[ "${DRY_RUN}" != true ]] && table_exists "${LOCK_TABLE}" >/dev/null; then
  log "Table already exists — skipping create"
else
  run aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --region "${AWS_REGION}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags "Key=Purpose,Value=terraform-state-lock" "Key=ManagedBy,Value=terraform-state-creator"

  if [[ "${DRY_RUN}" != true ]]; then
    log "Waiting for table to become ACTIVE..."
    aws dynamodb wait table-exists \
      --table-name "${LOCK_TABLE}" \
      --region "${AWS_REGION}"
  fi
fi

# ---------------------------------------------------------------------------
# Write backend config for consumers
# ---------------------------------------------------------------------------
mkdir -p "${OUTPUT_DIR}"

BACKEND_HCL="${OUTPUT_DIR}/backend.hcl"
BACKEND_JSON="${OUTPUT_DIR}/backend.json"
TFVARS_EXAMPLE="${OUTPUT_DIR}/backend.tf.example"

cat > "${BACKEND_HCL}" <<EOF
# Generated by scripts/create-terraform-state.sh
# Usage:
#   terraform init -backend-config=${BACKEND_HCL}

bucket         = "${STATE_BUCKET}"
key            = "infrastructure/terraform.tfstate"
region         = "${AWS_REGION}"
dynamodb_table = "${LOCK_TABLE}"
encrypt        = true
EOF

cat > "${BACKEND_JSON}" <<EOF
{
  "bucket": "${STATE_BUCKET}",
  "dynamodb_table": "${LOCK_TABLE}",
  "region": "${AWS_REGION}",
  "account_id": "${ACCOUNT_ID}",
  "default_state_key": "infrastructure/terraform.tfstate",
  "encrypt": true
}
EOF

cat > "${TFVARS_EXAMPLE}" <<EOF
# Copy into your Terraform root module, then:
#   terraform init -backend-config=path/to/backend.hcl

terraform {
  backend "s3" {
    # Values come from backend.hcl — leave this block empty or partial.
  }
}
EOF

log "Wrote ${BACKEND_HCL}"
log "Wrote ${BACKEND_JSON}"
log "Wrote ${TFVARS_EXAMPLE}"

cat <<EOF

Terraform remote state is ready.

  Bucket:  s3://${STATE_BUCKET}
  Lock:    dynamodb://${LOCK_TABLE}
  Region:  ${AWS_REGION}

Next steps:
  1. Copy generated/backend.hcl next to your Terraform root (or point to it).
  2. Add an empty backend "s3" {} block to your terraform {} config.
  3. Run:
       terraform init -backend-config=${BACKEND_HCL}
  4. Manage infrastructure as usual:
       terraform plan
       terraform apply

See examples/infra for a minimal consumer project.
EOF
