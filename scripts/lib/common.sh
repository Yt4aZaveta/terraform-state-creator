#!/usr/bin/env bash
# Shared helpers for terraform-state-creator scripts.
# shellcheck disable=SC2034

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Sanitize a string into a valid Terraform resource name.
tf_name() {
  local raw="$1"
  local name
  name="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+//; s/_+$//; s/__+/_/g')"
  if [[ -z "${name}" ]]; then
    name="resource"
  fi
  if [[ ! "${name}" =~ ^[a-z_] ]]; then
    name="r_${name}"
  fi
  # Terraform names max ~ practical length
  printf '%s' "${name:0:60}"
}

json_escape() {
  printf '%s' "$1" | jq -Rs .
}
