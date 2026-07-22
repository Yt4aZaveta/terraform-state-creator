#!/usr/bin/env bash
# Tear down Terraform remote state resources created by create-terraform-state.sh.
# WARNING: deletes state objects — only run when you no longer need the state.
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-central-1}"
STATE_BUCKET="${STATE_BUCKET:-}"
LOCK_TABLE="${LOCK_TABLE:-terraform-state-lock}"
FORCE=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") -b BUCKET [options]

Deletes S3 state bucket (all versions) and DynamoDB lock table.

Options:
  -b, --bucket NAME    S3 bucket name (required)
  -t, --table NAME     DynamoDB lock table (default: ${LOCK_TABLE})
  -r, --region REGION  AWS region (default: ${AWS_REGION})
  -f, --force          Skip confirmation prompt
  -n, --dry-run        Print actions only
  -h, --help           Show this help
EOF
}

log()  { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bucket) STATE_BUCKET="$2"; shift 2 ;;
    -t|--table)  LOCK_TABLE="$2"; shift 2 ;;
    -r|--region) AWS_REGION="$2"; shift 2 ;;
    -f|--force)  FORCE=true; shift ;;
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "${STATE_BUCKET}" ]] || die "Bucket name is required (-b)"
command -v aws >/dev/null 2>&1 || die "aws CLI is required"
command -v jq  >/dev/null 2>&1 || die "jq is required"

if [[ "${FORCE}" != true && "${DRY_RUN}" != true ]]; then
  printf 'This will PERMANENTLY delete s3://%s and DynamoDB table %s in %s.\n' \
    "${STATE_BUCKET}" "${LOCK_TABLE}" "${AWS_REGION}"
  read -r -p "Type the bucket name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${STATE_BUCKET}" ]] || die "Confirmation mismatch — aborted"
fi

log "Emptying bucket (including versions)..."
if [[ "${DRY_RUN}" == true ]]; then
  printf '[dry-run] empty s3://%s\n' "${STATE_BUCKET}"
else
  # Delete all object versions and delete markers
  while true; do
    VERSIONS="$(aws s3api list-object-versions \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --output json 2>/dev/null || echo '{}')"

    TO_DELETE="$(echo "${VERSIONS}" | jq -c '
      [
        (.Versions // [] | map({Key: .Key, VersionId: .VersionId})),
        (.DeleteMarkers // [] | map({Key: .Key, VersionId: .VersionId}))
      ] | add
    ')"

    COUNT="$(echo "${TO_DELETE}" | jq 'length')"
    if [[ "${COUNT}" -eq 0 ]]; then
      break
    fi

    # Batch delete up to 1000 objects
    echo "${TO_DELETE}" | jq -c '{Objects: .[0:1000], Quiet: true}' > /tmp/tfstate-delete.json
    aws s3api delete-objects \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --delete file:///tmp/tfstate-delete.json >/dev/null
    rm -f /tmp/tfstate-delete.json
  done

  run aws s3api delete-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}"
fi

log "Deleting DynamoDB table '${LOCK_TABLE}'..."
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  run aws dynamodb delete-table \
    --table-name "${LOCK_TABLE}" \
    --region "${AWS_REGION}"
else
  log "Table not found — skipping"
fi

log "Done."
