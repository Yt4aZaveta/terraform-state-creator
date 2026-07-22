#!/usr/bin/env bash
# One-command flow:
#   credentials → validate → scan AWS → generate Terraform import blocks →
#   generate config → import into LOCAL state → assemble main.tf
#
# Usage:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_REGION=eu-central-1
#   ./scripts/collect-aws-state.sh --auto-approve
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AWS_REGION="${AWS_REGION:-eu-central-1}"
SERVICES="${SERVICES:-vpc,subnet,route_table,igw,nat,eip,sg,ec2,ebs,s3,rds,dynamodb,lambda,elb}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/imported}"
DRY_RUN=false
SKIP_IMPORT=false
AUTO_APPROVE=false
INSTALL_DEPS=true
KEEP_IMPORTS=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Scan existing AWS resources and build a local Terraform project:
  inventory.json + terraform.tfstate + main.tf

Ideal flow:
  1. Put AWS credentials in the environment (or ~/.aws/credentials)
  2. Run this script
  3. Commit imported/main.tf and imported/terraform.tfstate to git

Options:
  -r, --region REGION       AWS region (default: ${AWS_REGION})
  -s, --services LIST       Services to scan (default: common set; or "all")
  -w, --work-dir DIR        Where to write Terraform project (default: ./imported)
  --skip-import             Only discover + write import blocks (no terraform)
  --keep-imports            Keep imports.tf after successful import
  --auto-approve            Pass -auto-approve to terraform apply
  --no-install-deps         Do not attempt to install missing aws/terraform
  -n, --dry-run             Fake discovery; do not call AWS / terraform apply
  -h, --help                Show help

Credentials (any standard AWS method):
  export AWS_ACCESS_KEY_ID=...
  export AWS_SECRET_ACCESS_KEY=...
  export AWS_SESSION_TOKEN=...          # if using temporary creds
  export AWS_REGION=${AWS_REGION}
  # or: aws configure / AWS_PROFILE=...
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)         AWS_REGION="$2"; shift 2 ;;
    -s|--services)       SERVICES="$2"; shift 2 ;;
    -w|--work-dir)       WORK_DIR="$2"; shift 2 ;;
    --skip-import)       SKIP_IMPORT=true; shift ;;
    --keep-imports)      KEEP_IMPORTS=true; shift ;;
    --auto-approve)      AUTO_APPROVE=true; shift ;;
    --no-install-deps)   INSTALL_DEPS=false; shift ;;
    -n|--dry-run)        DRY_RUN=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    # Deprecated flags kept for compatibility (ignored)
    -b|--bucket|-t|--table|--state-key|--skip-backend) shift 2 2>/dev/null || shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

export AWS_REGION
export AWS_DEFAULT_REGION="${AWS_REGION}"

# ---------------------------------------------------------------------------
# Dependency helpers
# ---------------------------------------------------------------------------
install_aws_cli() {
  log "Installing AWS CLI v2..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
  have unzip || die "unzip is required to install AWS CLI"
  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  if [[ -w /usr/local ]]; then
    "${tmp}/aws/install" --update
  else
    mkdir -p "${HOME}/.local"
    "${tmp}/aws/install" --update -i "${HOME}/.local/aws-cli" -b "${HOME}/.local/bin"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
  rm -rf "${tmp}"
}

install_terraform() {
  log "Installing Terraform..."
  local ver="1.9.8"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://releases.hashicorp.com/terraform/${ver}/terraform_${ver}_linux_amd64.zip" -o "${tmp}/tf.zip"
  have unzip || die "unzip is required to install Terraform"
  unzip -q "${tmp}/tf.zip" -d "${tmp}"
  mkdir -p "${HOME}/.local/bin"
  mv "${tmp}/terraform" "${HOME}/.local/bin/terraform"
  chmod +x "${HOME}/.local/bin/terraform"
  export PATH="${HOME}/.local/bin:${PATH}"
  rm -rf "${tmp}"
}

ensure_deps() {
  have jq || die "jq is required (apt install jq / brew install jq)"

  if [[ "${DRY_RUN}" == true ]]; then
    return 0
  fi

  if ! have aws; then
    if [[ "${INSTALL_DEPS}" == true ]]; then
      install_aws_cli
    else
      die "aws CLI is required"
    fi
  fi

  if [[ "${SKIP_IMPORT}" != true ]]; then
    if ! have terraform; then
      if [[ "${INSTALL_DEPS}" == true ]]; then
        install_terraform
      else
        die "terraform is required"
      fi
    fi
    local tfver
    tfver="$(terraform version -json | jq -r '.terraform_version')"
    log "Terraform ${tfver}"
  fi
}

# ---------------------------------------------------------------------------
# Write Terraform project from inventory
# ---------------------------------------------------------------------------
write_terraform_project() {
  local inventory="$1"
  local dir="$2"

  mkdir -p "${dir}"
  rm -f "${dir}/imports.tf" "${dir}/provider.tf" "${dir}/backend.tf" \
        "${dir}/backend.hcl" "${dir}/generated_resources.tf" \
        "${dir}/main.tf" "${dir}/.terraform.lock.hcl" "${dir}/import.tfplan"
  rm -rf "${dir}/.terraform"

  cat > "${dir}/provider.tf" <<EOF
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "${AWS_REGION}"
}
EOF

  {
    echo "# AUTO-GENERATED import blocks — removed after successful import"
    echo "# Source inventory: inventory.json"
    echo
    jq -r '.resources[] | [
      "import {",
      "  to = \(.type).\(.name)",
      "  id = \(.id | tojson)",
      "}",
      ""
    ] | join("\n")' "${inventory}"
  } > "${dir}/imports.tf"

  if [[ "$(cd "$(dirname "${inventory}")" && pwd)/$(basename "${inventory}")" != \
        "$(cd "${dir}" && pwd)/inventory.json" ]]; then
    cp "${inventory}" "${dir}/inventory.json"
  fi

  local count
  count="$(jq '.resource_count' "${inventory}")"
  log "Wrote ${dir}/imports.tf (${count} import blocks)"
  log "Wrote ${dir}/provider.tf"
}

assemble_main_tf() {
  local dir="$1"
  local src="${dir}/generated_resources.tf"
  local out="${dir}/main.tf"

  if [[ ! -f "${src}" ]]; then
    warn "No generated_resources.tf — cannot assemble main.tf yet"
    return 1
  fi

  {
    cat <<'EOF'
# =============================================================================
# main.tf — assembled from live AWS resources (terraform -generate-config-out)
# Review and tidy before relying on plan/apply. Nested blocks may need edits.
# Regenerated by: scripts/collect-aws-state.sh  or  scripts/state-to-main-tf.sh
# =============================================================================

EOF
    # Drop leading terraform/provider blocks if generate-config-out ever emits them
    sed -E '/^[[:space:]]*terraform[[:space:]]*\{/,/^[[:space:]]*\}/d; /^[[:space:]]*provider[[:space:]]+"/,/^[[:space:]]*\}/d' "${src}"
  } > "${out}"

  log "Wrote ${out}"
}

run_terraform_import() {
  local dir="$1"

  pushd "${dir}" >/dev/null

  log "terraform init (local state)..."
  terraform init -input=false -backend=false

  local count
  count="$(jq '.resource_count' inventory.json)"
  if [[ "${count}" -eq 0 ]]; then
    warn "No resources discovered — nothing to import"
    popd >/dev/null
    return 0
  fi

  log "Generating Terraform config from live AWS resources..."
  set +e
  terraform plan -generate-config-out=generated_resources.tf -input=false -out=import.tfplan
  local plan_rc=$?
  set -e

  if [[ ! -f generated_resources.tf ]]; then
    warn "terraform did not write generated_resources.tf (exit ${plan_rc})"
    warn "Import blocks are in imports.tf — fix credentials/permissions and re-run"
    popd >/dev/null
    return 1
  fi

  log "Wrote generated_resources.tf"
  assemble_main_tf "${dir}"

  log "Applying imports into local Terraform state..."
  local apply_flags=(-input=false)
  if [[ "${AUTO_APPROVE}" == true ]]; then
    apply_flags+=(-auto-approve)
  fi

  if [[ -f import.tfplan ]]; then
    terraform apply "${apply_flags[@]}" import.tfplan
  else
    terraform plan -input=false -out=import.tfplan
    terraform apply "${apply_flags[@]}" import.tfplan
  fi

  # Import blocks are one-shot — archive unless asked to keep
  if [[ "${KEEP_IMPORTS}" != true ]]; then
    mkdir -p .import-archive
    mv -f imports.tf .import-archive/imports.tf
    rm -f import.tfplan
    log "Archived imports.tf → .import-archive/ (one-time import complete)"
  fi

  log "State summary:"
  terraform state list || true

  popd >/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "AWS region: ${AWS_REGION}"
log "State storage: local (${WORK_DIR}/terraform.tfstate)"
ensure_deps

if [[ "${DRY_RUN}" != true ]]; then
  log "Validating AWS credentials..."
  aws sts get-caller-identity --output table \
    || die "Cannot authenticate. Set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or AWS_PROFILE)."
fi

mkdir -p "${WORK_DIR}"

# 1) Discover
log "Step 1/3 — scan AWS resources (${SERVICES})..."
INVENTORY="${WORK_DIR}/inventory.json"
DISCOVER_ARGS=(-r "${AWS_REGION}" -s "${SERVICES}" -o "${INVENTORY}")
[[ "${DRY_RUN}" == true ]] && DISCOVER_ARGS+=(-n)
"${SCRIPT_DIR}/discover-aws-resources.sh" "${DISCOVER_ARGS[@]}"

COUNT="$(jq '.resource_count' "${INVENTORY}")"
log "Found ${COUNT} resources"

# 2) Generate Terraform project
log "Step 2/3 — write Terraform project into ${WORK_DIR}..."
write_terraform_project "${INVENTORY}" "${WORK_DIR}"

# 3) Import → local state + main.tf
if [[ "${SKIP_IMPORT}" == true || "${DRY_RUN}" == true ]]; then
  log "Step 3/3 — skipped terraform import (dry-run or --skip-import)"
  if [[ "${DRY_RUN}" == true ]]; then
    # Placeholder main.tf so the layout is clear without AWS
    cat > "${WORK_DIR}/main.tf" <<'EOF'
# =============================================================================
# main.tf — placeholder (dry-run)
# After a real run this file contains resource blocks generated from AWS.
# =============================================================================

# resource "aws_vpc" "example" { ... }
EOF
    log "Wrote ${WORK_DIR}/main.tf (dry-run placeholder)"
  fi
else
  log "Step 3/3 — import resources into local state and build main.tf..."
  run_terraform_import "${WORK_DIR}"
fi

cat <<EOF

Done.

What you have now (ready for git):
  • Inventory:   ${WORK_DIR}/inventory.json
  • Provider:    ${WORK_DIR}/provider.tf
  • Code:        ${WORK_DIR}/main.tf
  • Local state: ${WORK_DIR}/terraform.tfstate

Next:
  cd ${WORK_DIR}
  terraform state list
  terraform plan
  # edit main.tf as needed, then commit main.tf + terraform.tfstate

Rebuild main.tf from state later:
  ./scripts/state-to-main-tf.sh -w ${WORK_DIR}

Tips:
  • Narrow the scan:  ./scripts/collect-aws-state.sh -s vpc,subnet,ec2
  • Full-ish scan:    ./scripts/collect-aws-state.sh -s all
EOF
