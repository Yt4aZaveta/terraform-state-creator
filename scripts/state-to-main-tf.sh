#!/usr/bin/env bash
# Build (or rebuild) main.tf from a local terraform.tfstate.
#
# Preferred path (accurate HCL, needs AWS creds):
#   recreate import blocks from state → terraform plan -generate-config-out
#
# Offline fallback:
#   dump resource attributes from state JSON into approximate HCL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

WORK_DIR="${WORK_DIR:-${ROOT_DIR}/imported}"
STATE_FILE=""
OUT_FILE=""
MODE="auto"   # auto | generate | dump
OFFLINE=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Assemble main.tf from local Terraform state so you can edit and commit it.

Options:
  -w, --work-dir DIR     Terraform project dir (default: ./imported)
  --state FILE           Path to terraform.tfstate (default: WORK_DIR/terraform.tfstate)
  -o, --output FILE      Output main.tf path (default: WORK_DIR/main.tf)
  --generate             Force live regenerate via terraform -generate-config-out (needs AWS)
  --dump                 Force offline dump from state JSON (no AWS)
  --offline              Alias for --dump
  -h, --help             Show help

Examples:
  ./scripts/state-to-main-tf.sh
  ./scripts/state-to-main-tf.sh -w imported --generate
  ./scripts/state-to-main-tf.sh --dump -o imported/main.tf
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--work-dir) WORK_DIR="$2"; shift 2 ;;
    --state)       STATE_FILE="$2"; shift 2 ;;
    -o|--output)   OUT_FILE="$2"; shift 2 ;;
    --generate)    MODE="generate"; shift ;;
    --dump|--offline) MODE="dump"; OFFLINE=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

STATE_FILE="${STATE_FILE:-${WORK_DIR}/terraform.tfstate}"
OUT_FILE="${OUT_FILE:-${WORK_DIR}/main.tf}"

[[ -f "${STATE_FILE}" ]] || die "State file not found: ${STATE_FILE}"
have jq || die "jq is required"

resource_count="$(jq '[.resources[]? | select(.mode=="managed")] | length' "${STATE_FILE}")"
[[ "${resource_count}" -gt 0 ]] || die "No managed resources in ${STATE_FILE}"

log "State: ${STATE_FILE} (${resource_count} managed resources)"

# ---------------------------------------------------------------------------
# Offline: approximate HCL from state attributes
# ---------------------------------------------------------------------------
hcl_escape() {
  # Escape for HCL quoted string
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

dump_main_tf() {
  local state="$1"
  local out="$2"

  log "Dumping approximate main.tf from state JSON (offline)..."

  {
    cat <<'EOF'
# =============================================================================
# main.tf — offline dump from terraform.tfstate
# Complex nested attributes use jsondecode(...) — review and replace with blocks.
# Prefer: ./scripts/state-to-main-tf.sh --generate  (accurate HCL via AWS)
# =============================================================================

EOF

    jq -r '
      def hcl($v):
        if $v == null then empty
        elif ($v|type) == "boolean" or ($v|type) == "number" then "\($v)"
        elif ($v|type) == "string" then ($v|@json)
        elif ($v|type) == "array" then
          if ($v|length) == 0 then "[]"
          elif all($v[]; type != "object") then
            "[" + ($v | map(hcl(.)) | join(", ")) + "]"
          else
            "jsondecode(" + ($v|tojson|@json) + ")"
          end
        elif ($v|type) == "object" then
          "jsondecode(" + ($v|tojson|@json) + ")"
        else ($v|@json)
        end;

      .resources[]
      | select(.mode=="managed")
      | . as $res
      | ($res.instances[0].attributes_flat // $res.instances[0].attributes // {}) as $attrs
      | (
          ["resource \($res.type|@json) \($res.name|@json) {"]
          + (
              if ($attrs|type) == "object" then
                [
                  $attrs
                  | to_entries[]
                  | select(.value != null)
                  | select(.key | (startswith("%") or contains(".")) | not)
                  | select(
                      .key as $k
                      | (["id","arn","owner_id","unique_id","availability_zone_id",
                          "primary_network_interface_id","instance_state",
                          "default_network_acl_id","default_route_table_id",
                          "default_security_group_id","dhcp_options_id",
                          "main_route_table_id","ipv6_association_id",
                          "vpc_arn","domain_name","zone_id","hosted_zone_id",
                          "caller_reference"] | index($k))
                      | not
                    )
                  | "  \(.key) = \(hcl(.value))"
                ]
              else
                ["  # (no attributes)"]
              end
            )
          + ["}", ""]
        )[]
    ' "${state}"
  } > "${out}"

  log "Wrote ${out}"
}

# ---------------------------------------------------------------------------
# Live: rebuild via import blocks + generate-config-out
# ---------------------------------------------------------------------------
generate_main_tf() {
  local dir="$1"
  local state="$2"
  local out="$3"

  have terraform || die "terraform is required for --generate"

  # Resolve id for each resource (terraform state show -json)
  pushd "${dir}" >/dev/null

  if [[ ! -d .terraform ]]; then
    log "terraform init (local)..."
    terraform init -input=false -backend=false >/dev/null
  fi

  local imports_tmp
  imports_tmp="$(mktemp)"
  {
    echo "# temporary import blocks for config regeneration"
    echo
  } > "${imports_tmp}"

  # Build address list from state
  local addresses
  addresses="$(jq -r '
    .resources[]
    | select(.mode=="managed")
    | if .module then "\(.module).\(.type).\(.name)" else "\(.type).\(.name)" end
  ' "${state}")"

  local addr id
  while IFS= read -r addr; do
    [[ -z "${addr}" ]] && continue
    # module addresses need care; skip modules for simplicity in v1
    if [[ "${addr}" == module.* ]]; then
      warn "Skipping module resource ${addr} (not supported in regenerate yet)"
      continue
    fi
    set +e
    id="$(terraform state show -json "${addr}" 2>/dev/null | jq -r '.values.id // empty')"
    set -e
    if [[ -z "${id}" || "${id}" == "null" ]]; then
      warn "No id for ${addr} — skipping"
      continue
    fi
    printf 'import {\n  to = %s\n  id = %s\n}\n\n' "${addr}" "$(jq -cn --arg i "${id}" '$i')" >> "${imports_tmp}"
  done <<< "${addresses}"

  local import_count
  import_count="$(grep -c '^import {' "${imports_tmp}" || true)"
  [[ "${import_count}" -gt 0 ]] || die "Could not build any import blocks from state"

  # Move existing main aside so generate-config-out can write fresh resources
  [[ -f main.tf ]] && mv -f main.tf "main.tf.bak.$(date +%s)"
  [[ -f generated_resources.tf ]] && rm -f generated_resources.tf

  cp "${imports_tmp}" imports_regen.tf
  rm -f "${imports_tmp}"

  log "Regenerating HCL from AWS for ${import_count} resources..."
  set +e
  terraform plan -generate-config-out=generated_resources.tf -input=false -refresh=true >/tmp/tf-regen-plan.log 2>&1
  local rc=$?
  set -e

  if [[ ! -f generated_resources.tf ]]; then
    warn "generate-config-out failed (exit ${rc}). Log: /tmp/tf-regen-plan.log"
    warn "Falling back to offline dump..."
    rm -f imports_regen.tf
    popd >/dev/null
    dump_main_tf "${state}" "${out}"
    return 0
  fi

  {
    cat <<'EOF'
# =============================================================================
# main.tf — regenerated from state via terraform -generate-config-out
# Review before apply. Nested blocks may need manual tidy-up.
# =============================================================================

EOF
    sed -E '/^[[:space:]]*terraform[[:space:]]*\{/,/^[[:space:]]*\}/d; /^[[:space:]]*provider[[:space:]]+"/,/^[[:space:]]*\}/d' generated_resources.tf
  } > "${out}"

  rm -f imports_regen.tf
  log "Wrote ${out}"
  log "Note: state already contains these resources — run terraform plan to verify drift"

  popd >/dev/null
}

# ---------------------------------------------------------------------------
# Decide mode
# ---------------------------------------------------------------------------
# If generated_resources.tf already exists and mode=auto, just assemble main.tf
if [[ "${MODE}" == "auto" && -f "${WORK_DIR}/generated_resources.tf" ]]; then
  log "Using existing generated_resources.tf"
  {
    cat <<'EOF'
# =============================================================================
# main.tf — assembled from generated_resources.tf
# =============================================================================

EOF
    sed -E '/^[[:space:]]*terraform[[:space:]]*\{/,/^[[:space:]]*\}/d; /^[[:space:]]*provider[[:space:]]+"/,/^[[:space:]]*\}/d' \
      "${WORK_DIR}/generated_resources.tf"
  } > "${OUT_FILE}"
  log "Wrote ${OUT_FILE}"
  exit 0
fi

if [[ "${MODE}" == "dump" || "${OFFLINE}" == true ]]; then
  dump_main_tf "${STATE_FILE}" "${OUT_FILE}"
  exit 0
fi

if [[ "${MODE}" == "generate" ]]; then
  generate_main_tf "${WORK_DIR}" "${STATE_FILE}" "${OUT_FILE}"
  exit 0
fi

# auto without generated_resources.tf: try live generate, else dump
if have terraform && have aws && aws sts get-caller-identity >/dev/null 2>&1; then
  log "AWS credentials OK — regenerating main.tf via terraform..."
  generate_main_tf "${WORK_DIR}" "${STATE_FILE}" "${OUT_FILE}"
else
  warn "No AWS/terraform available — offline dump"
  dump_main_tf "${STATE_FILE}" "${OUT_FILE}"
fi
