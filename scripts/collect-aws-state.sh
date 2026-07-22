#!/usr/bin/env bash
# One-command flow:
#   c2rc / credentials → scan cloud → import into LOCAL state → assemble main.tf
#
# K2 Cloud example:
#   ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
#
# AWS example:
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_REGION=eu-central-1
#   ./scripts/collect-aws-state.sh --auto-approve
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AWS_REGION="${AWS_REGION:-}"
SERVICES="${SERVICES:-}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/imported}"
RC_FILE=""
DRY_RUN=false
SKIP_IMPORT=false
AUTO_APPROVE=false
INSTALL_DEPS=true
KEEP_IMPORTS=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Scan existing cloud resources and build a local Terraform project:
  inventory.json + terraform.tfstate + main.tf

K2 Cloud (c2rc.sh):
  ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve

AWS:
  export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
  ./scripts/collect-aws-state.sh --auto-approve

Options:
  -c, --rc FILE             Source c2rc.sh-style credentials (K2 Cloud)
  -r, --region REGION       Region (default: from c2rc URL, else eu-central-1)
  -s, --services LIST       Services to scan (default: cloud-aware set; or "all")
  -w, --work-dir DIR        Output dir (default: ./imported)
  --skip-import             Only discover + write import blocks
  --keep-imports            Keep imports.tf after successful import
  --auto-approve            terraform apply -auto-approve
  --no-install-deps         Do not auto-install aws/terraform
  -n, --dry-run             Fake discovery; no API / no apply
  -h, --help                Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--rc)             RC_FILE="$2"; shift 2 ;;
    -r|--region)         AWS_REGION="$2"; shift 2 ;;
    -s|--services)       SERVICES="$2"; shift 2 ;;
    -w|--work-dir)       WORK_DIR="$2"; shift 2 ;;
    --skip-import)       SKIP_IMPORT=true; shift ;;
    --keep-imports)      KEEP_IMPORTS=true; shift ;;
    --auto-approve)      AUTO_APPROVE=true; shift ;;
    --no-install-deps)   INSTALL_DEPS=false; shift ;;
    -n|--dry-run)        DRY_RUN=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ -n "${RC_FILE}" ]]; then
  source_cloud_rc "${RC_FILE}"
fi

# Region fallback when not set by rc / flag / env
if [[ -z "${AWS_REGION}" ]]; then
  if is_k2_cloud; then
    AWS_REGION="ru-msk"
  else
    AWS_REGION="eu-central-1"
  fi
fi
export AWS_REGION
export AWS_DEFAULT_REGION="${AWS_REGION}"

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

write_terraform_project() {
  local inventory="$1"
  local dir="$2"

  mkdir -p "${dir}"
  rm -f "${dir}/imports.tf" "${dir}/provider.tf" "${dir}/backend.tf" \
        "${dir}/backend.hcl" "${dir}/generated_resources.tf" \
        "${dir}/main.tf" "${dir}/.terraform.lock.hcl" "${dir}/import.tfplan" \
        "${dir}/terraform.tfvars"
  rm -rf "${dir}/.terraform"

  if is_k2_cloud; then
    export IS_COMPAT_CLOUD=true
  else
    export IS_COMPAT_CLOUD=false
  fi
  emit_provider_tf > "${dir}/provider.tf"
  write_tfvars "${dir}"

  # Save a copy of endpoints/meta for later regenerations (no secrets)
  jq -n \
    --arg cloud "$(is_k2_cloud && echo k2 || echo aws)" \
    --arg region "${AWS_REGION}" \
    --arg project "${C2_PROJECT:-}" \
    --arg ec2 "${EC2_URL:-}" \
    --arg s3 "${S3_URL:-}" \
    --arg elb "${ELB_URL:-}" \
    --arg iam "${IAM_URL:-}" \
    '{cloud:$cloud, region:$region, project:$project,
      endpoints:{ec2:$ec2, s3:$s3, elb:$elb, iam:$iam}}' \
    > "${dir}/cloud.json"

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
# main.tf — assembled from live cloud resources (terraform -generate-config-out)
# Review and tidy before relying on plan/apply. Nested blocks may need edits.
# Regenerated by: scripts/collect-aws-state.sh  or  scripts/state-to-main-tf.sh
# =============================================================================

EOF
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

  log "Generating Terraform config from live cloud resources..."
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

  if [[ "${KEEP_IMPORTS}" != true ]]; then
    mkdir -p .import-archive
    mv -f imports.tf .import-archive/imports.tf
    rm -f import.tfplan
    log "Archived imports.tf → .import-archive/"
  fi

  log "State summary:"
  terraform state list || true

  popd >/dev/null
}

# ---------------------------------------------------------------------------
log "Region: ${AWS_REGION}"
log "State storage: local (${WORK_DIR}/terraform.tfstate)"
is_k2_cloud && log "Cloud: K2 (custom endpoints from c2rc)"
ensure_deps

if [[ "${DRY_RUN}" != true ]]; then
  verify_cloud_credentials
fi

mkdir -p "${WORK_DIR}"

log "Step 1/3 — scan cloud resources..."
INVENTORY="${WORK_DIR}/inventory.json"
DISCOVER_ARGS=(-r "${AWS_REGION}" -o "${INVENTORY}")
[[ -n "${SERVICES}" ]] && DISCOVER_ARGS+=(-s "${SERVICES}")
[[ -n "${RC_FILE}" ]] && DISCOVER_ARGS+=(-c "${RC_FILE}")
[[ "${DRY_RUN}" == true ]] && DISCOVER_ARGS+=(-n)
# Env from sourced rc is inherited; -c re-sources inside discover for safety
"${SCRIPT_DIR}/discover-aws-resources.sh" "${DISCOVER_ARGS[@]}"

COUNT="$(jq '.resource_count' "${INVENTORY}")"
log "Found ${COUNT} resources"

log "Step 2/3 — write Terraform project into ${WORK_DIR}..."
write_terraform_project "${INVENTORY}" "${WORK_DIR}"

if [[ "${SKIP_IMPORT}" == true || "${DRY_RUN}" == true ]]; then
  log "Step 3/3 — skipped terraform import (dry-run or --skip-import)"
  if [[ "${DRY_RUN}" == true ]]; then
    cat > "${WORK_DIR}/main.tf" <<'EOF'
# =============================================================================
# main.tf — placeholder (dry-run)
# After a real run this file contains resource blocks generated from the cloud.
# =============================================================================

# resource "aws_vpc" "example" { ... }
EOF
    log "Wrote ${WORK_DIR}/main.tf (dry-run placeholder)"
  fi
else
  log "Step 3/3 — import into local state and build main.tf..."
  run_terraform_import "${WORK_DIR}"
fi

cat <<EOF

Done.

What you have now (ready for git — except secrets):
  • Inventory:   ${WORK_DIR}/inventory.json
  • Provider:    ${WORK_DIR}/provider.tf
  • Code:        ${WORK_DIR}/main.tf
  • Local state: ${WORK_DIR}/terraform.tfstate
  • Secrets:     ${WORK_DIR}/terraform.tfvars   (gitignored)

Usage:
  ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve

Next:
  cd ${WORK_DIR}
  terraform state list
  terraform plan
  # commit main.tf provider.tf terraform.tfstate — NOT terraform.tfvars / c2rc.sh
EOF
