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
  printf '%s' "${name:0:60}"
}

json_escape() {
  printf '%s' "$1" | jq -Rs .
}

# True when c2rc / K2 Cloud style endpoints are loaded.
is_k2_cloud() {
  [[ -n "${EC2_URL:-}" || -n "${S3_URL:-}" || "${CLOUD_PROVIDER:-}" == "k2" ]]
}

# Infer region from EC2_URL like https://ec2.ru-msk.k2.cloud → ru-msk
infer_region_from_ec2_url() {
  local url="${EC2_URL:-}"
  if [[ "${url}" =~ ec2\.([a-z0-9-]+)\. ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Source a c2rc.sh-style credentials file (K2 Cloud / CROC).
# Expects exports: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, EC2_URL, S3_URL, ...
source_cloud_rc() {
  local rc_file="$1"
  [[ -f "${rc_file}" ]] || die "Credentials file not found: ${rc_file}"

  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1090
  source "${rc_file}"
  set +a

  export CLOUD_PROVIDER="${CLOUD_PROVIDER:-k2}"
  export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"

  # Map EC2_* aliases if AWS_* not set
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -n "${EC2_ACCESS_KEY:-}" ]]; then
    export AWS_ACCESS_KEY_ID="${EC2_ACCESS_KEY}"
  fi
  if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" && -n "${EC2_SECRET_KEY:-}" ]]; then
    export AWS_SECRET_ACCESS_KEY="${EC2_SECRET_KEY}"
  fi

  [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || die "RC file did not set AWS_ACCESS_KEY_ID / EC2_ACCESS_KEY"
  [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "RC file did not set AWS_SECRET_ACCESS_KEY / EC2_SECRET_KEY"

  # Region: keep explicit AWS_REGION; else infer from EC2_URL; else ru-msk for K2
  if [[ -z "${AWS_REGION:-}" ]]; then
    local inferred=""
    inferred="$(infer_region_from_ec2_url || true)"
    if [[ -n "${inferred}" ]]; then
      export AWS_REGION="${inferred}"
    elif is_k2_cloud; then
      export AWS_REGION="ru-msk"
    fi
  fi
  export AWS_DEFAULT_REGION="${AWS_REGION}"

  # Convenience: also expose AWS_ENDPOINT_URL_* for newer AWS CLI / SDKs
  [[ -n "${EC2_URL:-}" ]] && export AWS_ENDPOINT_URL_EC2="${EC2_URL}"
  [[ -n "${S3_URL:-}" ]] && export AWS_ENDPOINT_URL_S3="${S3_URL}"
  [[ -n "${ELB_URL:-}" ]] && export AWS_ENDPOINT_URL_ELASTIC_LOAD_BALANCING_V2="${ELB_URL}"
  [[ -n "${IAM_URL:-}" ]] && export AWS_ENDPOINT_URL_IAM="${IAM_URL}"
  [[ -n "${ROUTE53_URL:-}" ]] && export AWS_ENDPOINT_URL_ROUTE_53="${ROUTE53_URL}"
  [[ -n "${AUTO_SCALING_URL:-}" ]] && export AWS_ENDPOINT_URL_AUTO_SCALING="${AUTO_SCALING_URL}"
  [[ -n "${AWS_CLOUDWATCH_URL:-}" ]] && export AWS_ENDPOINT_URL_CLOUDWATCH="${AWS_CLOUDWATCH_URL}"
  [[ -n "${KMS_URL:-}" ]] && export AWS_ENDPOINT_URL_KMS="${KMS_URL}"
  [[ -n "${SQS_URL:-}" ]] && export AWS_ENDPOINT_URL_SQS="${SQS_URL}"
  [[ -n "${EFS_URL:-}" ]] && export AWS_ENDPOINT_URL_EFS="${EFS_URL}"
  [[ -n "${EKS_URL:-}" ]] && export AWS_ENDPOINT_URL_EKS="${EKS_URL}"

  log "Loaded credentials from ${rc_file}"
  log "Project: ${C2_PROJECT:-unknown}  region: ${AWS_REGION}"
  [[ -n "${EC2_URL:-}" ]] && log "EC2 endpoint: ${EC2_URL}"

  if is_k2_cloud; then
    configure_network_for_cloud
  fi
}

# After loading c2rc: K2 API is usually reachable directly.
# AWS CLI breaks on HTTPS_PROXY=socks5://... (turns into http://socks5://...).
configure_network_for_cloud() {
  local extras=".k2.cloud,k2.cloud,hc-registry.website.k2.cloud"
  extras+=",ec2.ru-msk.k2.cloud,s3.ru-msk.k2.cloud,elb.ru-msk.k2.cloud"
  extras+=",iam.k2.cloud,route53.k2.cloud,eks.ru-msk.k2.cloud"
  extras+=",localhost,127.0.0.1"

  if [[ -n "${NO_PROXY:-}" ]]; then
    export NO_PROXY="${NO_PROXY},${extras}"
  else
    export NO_PROXY="${extras}"
  fi
  export no_proxy="${NO_PROXY}"

  if [[ "${HTTP_PROXY:-}${HTTPS_PROXY:-}${http_proxy:-}${https_proxy:-}" == *socks* ]]; then
    # Preserve socks for tools that understand ALL_PROXY (curl); strip from HTTP(S)_PROXY
    if [[ -z "${ALL_PROXY:-}${all_proxy:-}" ]]; then
      export ALL_PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
      export all_proxy="${ALL_PROXY}"
    fi
    warn "SOCKS proxy detected — AWS CLI will talk to K2 Cloud directly (NO_PROXY=.k2.cloud)"
    warn "Proxy still used for provider download via curl/ALL_PROXY"
  fi
}

# Run a command without HTTP(S) proxy env (K2 / broken socks+aws-cli).
without_http_proxy() {
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
      -u ALL_PROXY -u all_proxy \
      "$@"
}

# aws wrapper with optional --endpoint-url for a service.
# Usage: aws_svc ec2 ec2 describe-vpcs ...
aws_svc() {
  local kind="$1"; shift
  local endpoint=""
  case "${kind}" in
    ec2)  endpoint="${EC2_URL:-}" ;;
    s3)   endpoint="${S3_URL:-}" ;;
    elb)  endpoint="${ELB_URL:-}" ;;
    iam)  endpoint="${IAM_URL:-}" ;;
    r53)  endpoint="${ROUTE53_URL:-}" ;;
    *)    endpoint="" ;;
  esac

  local args=(--region "${AWS_REGION:-ru-msk}")
  if [[ -n "${endpoint}" ]]; then
    args+=(--endpoint-url "${endpoint}")
  fi

  if is_k2_cloud; then
    # Direct to K2 — avoid AWS CLI + socks5 HTTPS_PROXY bug
    without_http_proxy aws "${args[@]}" "$@"
  else
    aws "${args[@]}" "$@"
  fi
}

# Validate that credentials work (STS on AWS; EC2 Describe on K2).
verify_cloud_credentials() {
  if is_k2_cloud; then
    log "Validating K2 Cloud credentials via EC2..."
    aws_svc ec2 ec2 describe-vpcs --output text >/dev/null \
      || die "Cannot reach ${EC2_URL:-EC2}. Check c2rc credentials / network."
    export DISCOVERED_ACCOUNT_ID="${C2_PROJECT:-k2}"
    log "OK — project ${DISCOVERED_ACCOUNT_ID}"
  else
    log "Validating AWS credentials..."
    aws sts get-caller-identity --output table \
      || die "Cannot authenticate. Set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or --rc c2rc.sh)."
    export DISCOVERED_ACCOUNT_ID
    DISCOVERED_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  fi
}

# Emit Terraform provider block (K2 → c2devel/rockitcloud, else hashicorp/aws).
# Docs: https://docs.k2.cloud/ru/api/tools/terraform.html
emit_provider_tf() {
  local region="${AWS_REGION:-ru-msk}"

  if is_k2_cloud; then
    local src="${ROCKITCLOUD_PROVIDER_SOURCE:-hc-registry.website.k2.cloud/c2devel/rockitcloud}"
    local ver="${ROCKITCLOUD_PROVIDER_VERSION:-~> 25.2}"
    cat <<EOF
# Generated for K2 Cloud — provider: c2devel/rockitcloud
# https://docs.k2.cloud/ru/api/tools/terraform.html
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      # Official K2 Cloud provider (AWS-compatible resource names)
      source  = "${src}"
      version = "${ver}"
    }
  }
}

# Block is named "aws" for backward compatibility with AWS configs
provider "aws" {
  insecure   = false
  region     = "${region}"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key

  # With a real K2 region (ru-msk / …) the provider builds API endpoints itself.
  # Explicit endpoints from c2rc are kept as overrides when set.
EOF
    # Only emit endpoints block if at least EC2_URL is present (from c2rc)
    if [[ -n "${EC2_URL:-}" ]]; then
      cat <<EOF

  endpoints {
EOF
      [[ -n "${EC2_URL:-}" ]] && printf '    ec2           = "%s"\n' "${EC2_URL}"
      [[ -n "${S3_URL:-}" ]] && printf '    s3            = "%s"\n' "${S3_URL}"
      [[ -n "${ELB_URL:-}" ]] && printf '    elbv2         = "%s"\n' "${ELB_URL}"
      [[ -n "${IAM_URL:-}" ]] && printf '    iam           = "%s"\n' "${IAM_URL}"
      [[ -n "${ROUTE53_URL:-}" ]] && printf '    route53       = "%s"\n' "${ROUTE53_URL}"
      [[ -n "${AUTO_SCALING_URL:-}" ]] && printf '    autoscaling   = "%s"\n' "${AUTO_SCALING_URL}"
      [[ -n "${AWS_CLOUDWATCH_URL:-}" ]] && printf '    cloudwatch    = "%s"\n' "${AWS_CLOUDWATCH_URL}"
      [[ -n "${DIRECT_CONNECT_URL:-}" ]] && printf '    directconnect = "%s"\n' "${DIRECT_CONNECT_URL}"
      [[ -n "${EFS_URL:-}" ]] && printf '    efs           = "%s"\n' "${EFS_URL}"
      [[ -n "${EKS_URL:-}" ]] && printf '    eks           = "%s"\n' "${EKS_URL}"
      [[ -n "${PAAS_URL:-}" ]] && printf '    paas          = "%s"\n' "${PAAS_URL}"
      [[ -n "${BACKUP_URL:-}" ]] && printf '    backup        = "%s"\n' "${BACKUP_URL}"
      cat <<'EOF'
  }
EOF
    fi
    cat <<'EOF'
}

variable "aws_access_key_id" {
  type        = string
  sensitive   = true
  description = "K2 Cloud access key (from c2rc EC2_ACCESS_KEY)"
}

variable "aws_secret_access_key" {
  type        = string
  sensitive   = true
  description = "K2 Cloud secret key (from c2rc EC2_SECRET_KEY)"
}
EOF
    return 0
  fi

  # Vanilla AWS
  cat <<EOF
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= ${AWS_PROVIDER_VERSION:-5.100.0}"
    }
  }
}

provider "aws" {
  region                      = "${region}"
  access_key                  = var.aws_access_key_id
  secret_key                  = var.aws_secret_access_key
  skip_metadata_api_check     = true
}

variable "aws_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}
EOF
}

# Write terraform.tfvars with keys (gitignored via *.tfvars).
write_tfvars() {
  local dir="$1"
  cat > "${dir}/terraform.tfvars" <<EOF
# Generated from c2rc / environment — do not commit
aws_access_key_id     = "${AWS_ACCESS_KEY_ID}"
aws_secret_access_key = "${AWS_SECRET_ACCESS_KEY}"
EOF
  log "Wrote ${dir}/terraform.tfvars (gitignored)"
}

# Detect OS/arch for provider binaries (sets TF_OS, TF_ARCH).
detect_tf_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported architecture: ${arch}" ;;
  esac
  case "${os}" in
    linux|darwin) ;;
    *) die "Unsupported OS: ${os}" ;;
  esac
  TF_OS="${os}"
  TF_ARCH="${arch}"
}

# Prepare provider installation for the current cloud.
# K2: prefer hc-registry.website.k2.cloud (rockitcloud); fallback GitHub filesystem mirror.
# AWS: hashicorp/aws from releases.hashicorp.com filesystem mirror.
ensure_aws_provider_mirror() {
  local mirror_root="${1:-${HOME}/.terraform.d/mirror}"
  detect_tf_platform

  if is_k2_cloud; then
    ensure_rockitcloud_provider "${mirror_root}"
    return $?
  fi

  local ver="${AWS_PROVIDER_VERSION:-5.100.0}"
  local dest_dir="${mirror_root}/registry.terraform.io/hashicorp/aws/${ver}/${TF_OS}_${TF_ARCH}"
  local url="https://releases.hashicorp.com/terraform-provider-aws/${ver}/terraform-provider-aws_${ver}_${TF_OS}_${TF_ARCH}.zip"

  if [[ ! -d "${dest_dir}" ]] || [[ -z "$(find "${dest_dir}" -type f -name 'terraform-provider-aws*' 2>/dev/null | head -1)" ]]; then
    log "Downloading hashicorp/aws ${ver} (${TF_OS}_${TF_ARCH}) into local mirror..."
    download_zip_to_dir "${url}" "${dest_dir}"
  else
    log "Using cached provider mirror: ${dest_dir}"
  fi

  write_filesystem_mirror_rc "${mirror_root}" "registry.terraform.io/hashicorp/aws"
  export AWS_PROVIDER_VERSION="${ver}"
  log "TF_CLI_CONFIG_FILE=${TF_CLI_CONFIG_FILE} (aws provider ${ver})"
}

download_zip_to_dir() {
  local url="$1"
  local dest_dir="$2"
  local tmp
  tmp="$(mktemp -d)"
  log "URL: ${url}"
  if ! curl -fsSL "${url}" -o "${tmp}/provider.zip"; then
    if [[ -n "${ALL_PROXY:-}${all_proxy:-}${HTTPS_PROXY:-}" ]]; then
      warn "Direct download failed — retrying via proxy..."
      if ! curl -fsSL --proxy "${ALL_PROXY:-${all_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}" \
          "${url}" -o "${tmp}/provider.zip"; then
        rm -rf "${tmp}"
        return 1
      fi
    else
      rm -rf "${tmp}"
      return 1
    fi
  fi
  have unzip || die "unzip is required"
  mkdir -p "${dest_dir}"
  unzip -qo "${tmp}/provider.zip" -d "${dest_dir}"
  chmod +x "${dest_dir}"/terraform-provider-* 2>/dev/null || true
  rm -rf "${tmp}"
  log "Installed provider → ${dest_dir}"
}

write_filesystem_mirror_rc() {
  local mirror_root="$1"
  local include_addr="$2"  # e.g. hc-registry.website.k2.cloud/c2devel/rockitcloud
  local rc_file="${mirror_root}/terraform.rc"
  cat > "${rc_file}" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${mirror_root}"
    include = ["${include_addr}"]
  }
  direct {
    exclude = ["${include_addr}"]
  }
}
EOF
  export TF_CLI_CONFIG_FILE="${rc_file}"
}

# Install c2devel/rockitcloud for K2 Cloud.
# 1) Let terraform init hit K2 registry (no TF_CLI_CONFIG_FILE) — preferred
# 2) Or filesystem-mirror from GitHub releases if registry init is forced offline
ensure_rockitcloud_provider() {
  local mirror_root="$1"
  detect_tf_platform
  local ver="${ROCKITCLOUD_PROVIDER_VERSION_PIN:-25.5.2}"
  local host_src="${ROCKITCLOUD_PROVIDER_SOURCE:-hc-registry.website.k2.cloud/c2devel/rockitcloud}"
  # hostname/namespace/name for mirror path = source address
  local dest_dir="${mirror_root}/${host_src}/${ver}/${TF_OS}_${TF_ARCH}"
  local gh_url="https://github.com/C2Devel/terraform-provider-rockitcloud/releases/download/v${ver}/terraform-provider-rockitcloud_${ver}_${TF_OS}_${TF_ARCH}.zip"

  export ROCKITCLOUD_PROVIDER_VERSION="${ROCKITCLOUD_PROVIDER_VERSION:-~> 25.2}"
  export ROCKITCLOUD_PROVIDER_SOURCE="${host_src}"

  # Prefer live K2 registry during terraform init (reachable as *.k2.cloud)
  if [[ "${ROCKITCLOUD_USE_MIRROR:-}" != "1" ]]; then
    unset TF_CLI_CONFIG_FILE || true
    log "K2 provider: ${host_src} (terraform init will fetch from K2 registry)"
    log "Optional offline mirror: ROCKITCLOUD_USE_MIRROR=1"
    # Still prefetch into mirror as backup (does not force TF_CLI_CONFIG_FILE)
    if [[ ! -d "${dest_dir}" ]] || [[ -z "$(find "${dest_dir}" -type f -name 'terraform-provider-rockitcloud*' 2>/dev/null | head -1)" ]]; then
      log "Prefetching rockitcloud ${ver} into backup mirror (GitHub)..."
      if download_zip_to_dir "${gh_url}" "${dest_dir}"; then
        log "Backup mirror ready at ${dest_dir}"
      else
        warn "Could not prefetch rockitcloud from GitHub — terraform init will use K2 registry only"
      fi
    else
      log "Backup mirror cached: ${dest_dir}"
    fi
    return 0
  fi

  # Forced filesystem mirror mode
  if [[ ! -d "${dest_dir}" ]] || [[ -z "$(find "${dest_dir}" -type f -name 'terraform-provider-rockitcloud*' 2>/dev/null | head -1)" ]]; then
    log "Downloading rockitcloud ${ver} into filesystem mirror..."
    download_zip_to_dir "${gh_url}" "${dest_dir}" \
      || die "Cannot download rockitcloud. Try proxy or unset ROCKITCLOUD_USE_MIRROR=1"
  fi
  write_filesystem_mirror_rc "${mirror_root}" "${host_src}"
  # Pin exact version in provider.tf when using mirror
  export ROCKITCLOUD_PROVIDER_VERSION="${ver}"
  log "TF_CLI_CONFIG_FILE=${TF_CLI_CONFIG_FILE} (rockitcloud ${ver})"
}

# Strip attributes / blocks that break on K2 Cloud (AWS-compatible but incomplete API).
sanitize_generated_hcl() {
  local src="$1"
  local dest="$2"
  [[ -f "${src}" ]] || return 1

  if have python3; then
    python3 - "${src}" "${dest}" <<'PY'
import re, sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()

# Drop attribute lines known to break on K2 / empty-invalid / conflicting values
drop_line = re.compile(
    r'^\s*(?:'
    r'throughput|iops|'
    r'enable_lni_at_device_index|map_customer_owned_ip_on_launch|'
    r'customer_owned_ipv4_pool|outpost_arn|enable_network_address_usage_metrics|'
    r'disable_api_stop|disable_api_termination|instance_initiated_shutdown_behavior|'
    r'ipv6_address_count|ipv6_addresses|ipv6_native|ipv6_netmask_length|ipv6_ipam_pool_id|'
    r'ipv6_cidr_block|assign_ipv6_address_on_creation|'
    r'enable_resource_name_dns_a_record_on_launch|'
    r'enable_resource_name_dns_aaaa_record_on_launch|private_dns_hostname_type_on_launch|'
    r'acceleration_status|request_payer|object_lock_enabled|'
    r'bucket_domain_name|bucket_regional_domain_name|hosted_zone_id|'
    r'carrier_ip|customer_owned_ip|network_border_group|'
    r'private_dns|public_dns|public_ipv4_pool|'
    r'allocation_id|association_id|domain|private_ip|public_ip|'
    r'ipv6_cidr_block_association_id|ipv6_association_id|'
    r'region\s*=\s*(?:null|"us-east-1")'
    r')\s*=.*$',
    re.M,
)
text = drop_line.sub('', text)

# name_prefix conflicts with name when both present; empty prefix is useless
text = re.sub(r'^\s*name_prefix\s*=\s*""\s*$', '', text, flags=re.M)

# Also drop null-valued optional junk
text = re.sub(r'^\s*\w+\s*=\s*null\s*$', '', text, flags=re.M)

# Drop empty-string assignments (often invalid CIDRs / unused optionals)
text = re.sub(r'^\s*\w+\s*=\s*""\s*$', '', text, flags=re.M)

# Drop argument-style empty block lists left by older dumps
text = re.sub(
    r'^\s*(?:capacity_reservation_specification|credit_specification|'
    r'ebs_block_device|enclave_options|ephemeral_block_device|launch_template|'
    r'maintenance_options|metadata_options|network_interface|root_block_device|'
    r'cors_rule|grant|lifecycle_rule|logging|object_lock_configuration|'
    r'replication_configuration|server_side_encryption_configuration|'
    r'versioning|website|route|ingress|egress)\s*=\s*(?:\[\]|jsondecode\([^)]*\))\s*$',
    '',
    text,
    flags=re.M,
)

# Remove route blocks with empty cidr / ipv6 cidr
text = re.sub(
    r'\n\s*route\s*\{(?:[^{}]|\n)*?cidr_block\s*=\s*""(?:[^{}]|\n)*?\}',
    '',
    text,
)
text = re.sub(
    r'\n\s*route\s*\{(?:[^{}]|\n)*?ipv6_cidr_block\s*=\s*""(?:[^{}]|\n)*?\}',
    '',
    text,
)

# Remove empty replication_configuration / server_side_encryption_configuration shells
text = re.sub(r'\n\s*replication_configuration\s*\{\s*(?:role\s*=\s*null\s*)?\}', '', text)
text = re.sub(r'\n\s*server_side_encryption_configuration\s*\{\s*\}', '', text)

# Collapse excessive blank lines
text = re.sub(r'\n{3,}', '\n\n', text)
open(dest, 'w', encoding='utf-8').write(text)
PY
  else
    grep -Ev '^\s*(throughput|enable_lni_at_device_index|map_customer_owned_ip_on_launch|customer_owned_ipv4_pool|outpost_arn|ipv6_address_count|ipv6_addresses|ipv6_netmask_length|ipv6_ipam_pool_id)\s*=' \
      "${src}" > "${dest}.tmp" || true
    mv "${dest}.tmp" "${dest}"
  fi
}
