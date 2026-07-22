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
  local extras=".k2.cloud,k2.cloud"
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

# Emit Terraform provider "aws" block for current env (K2 endpoints when set).
# Writes to stdout.
emit_provider_tf() {
  local region="${AWS_REGION:-ru-msk}"

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
  region     = "${region}"
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key

  # Compatible clouds (K2) and custom endpoints
  skip_credentials_validation = ${IS_COMPAT_CLOUD:-false}
  skip_metadata_api_check     = true
  skip_region_validation      = ${IS_COMPAT_CLOUD:-false}
  skip_requesting_account_id  = ${IS_COMPAT_CLOUD:-false}
  s3_use_path_style           = ${IS_COMPAT_CLOUD:-false}
EOF

  if is_k2_cloud; then
    cat <<EOF

  endpoints {
EOF
    [[ -n "${EC2_URL:-}" ]] && printf '    ec2            = "%s"\n' "${EC2_URL}"
    [[ -n "${S3_URL:-}" ]] && printf '    s3             = "%s"\n' "${S3_URL}"
    [[ -n "${ELB_URL:-}" ]] && printf '    elbv2          = "%s"\n' "${ELB_URL}"
    [[ -n "${IAM_URL:-}" ]] && printf '    iam            = "%s"\n' "${IAM_URL}"
    [[ -n "${ROUTE53_URL:-}" ]] && printf '    route53        = "%s"\n' "${ROUTE53_URL}"
    [[ -n "${AUTO_SCALING_URL:-}" ]] && printf '    autoscaling    = "%s"\n' "${AUTO_SCALING_URL}"
    [[ -n "${AWS_CLOUDWATCH_URL:-}" ]] && printf '    cloudwatch     = "%s"\n' "${AWS_CLOUDWATCH_URL}"
    [[ -n "${DIRECT_CONNECT_URL:-}" ]] && printf '    directconnect  = "%s"\n' "${DIRECT_CONNECT_URL}"
    [[ -n "${EFS_URL:-}" ]] && printf '    efs            = "%s"\n' "${EFS_URL}"
    [[ -n "${EKS_URL:-}" ]] && printf '    eks            = "%s"\n' "${EKS_URL}"
    [[ -n "${KMS_URL:-}" ]] && printf '    kms            = "%s"\n' "${KMS_URL}"
    [[ -n "${SQS_URL:-}" ]] && printf '    sqs            = "%s"\n' "${SQS_URL}"
    [[ -n "${BACKUP_URL:-}" ]] && printf '    backup         = "%s"\n' "${BACKUP_URL}"
    cat <<'EOF'
  }
EOF
  fi

  cat <<'EOF'
}

variable "aws_access_key_id" {
  type        = string
  sensitive   = true
  description = "Cloud access key (from c2rc / AWS)"
}

variable "aws_secret_access_key" {
  type        = string
  sensitive   = true
  description = "Cloud secret key (from c2rc / AWS)"
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

# Download hashicorp/aws into a local filesystem mirror and point Terraform at it.
# Avoids registry.terraform.io (often blocked without proxy).
# Sets: TF_CLI_CONFIG_FILE, AWS_PROVIDER_VERSION
ensure_aws_provider_mirror() {
  local mirror_root="${1:-${HOME}/.terraform.d/mirror}"
  # K2 Cloud: older AWS provider avoids unsupported Describe*Attribute calls
  local default_ver="5.100.0"
  if is_k2_cloud; then
    default_ver="4.67.0"
  fi
  local ver="${AWS_PROVIDER_VERSION:-${default_ver}}"
  detect_tf_platform

  local dest_dir="${mirror_root}/registry.terraform.io/hashicorp/aws/${ver}/${TF_OS}_${TF_ARCH}"
  local url="https://releases.hashicorp.com/terraform-provider-aws/${ver}/terraform-provider-aws_${ver}_${TF_OS}_${TF_ARCH}.zip"

  if [[ ! -d "${dest_dir}" ]] || [[ -z "$(find "${dest_dir}" -type f -name 'terraform-provider-aws*' 2>/dev/null | head -1)" ]]; then
    log "Downloading hashicorp/aws ${ver} (${TF_OS}_${TF_ARCH}) into local mirror..."
    log "URL: ${url}"
    local tmp
    tmp="$(mktemp -d)"
    if ! curl -fsSL "${url}" -o "${tmp}/provider.zip"; then
      # Retry with explicit ALL_PROXY if user had socks only in HTTPS_PROXY
      if [[ -n "${ALL_PROXY:-}${all_proxy:-}${HTTPS_PROXY:-}" ]]; then
        warn "Direct download failed — retrying via proxy..."
        if ! curl -fsSL --proxy "${ALL_PROXY:-${all_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}" \
            "${url}" -o "${tmp}/provider.zip"; then
          rm -rf "${tmp}"
          die "Cannot download AWS provider from releases.hashicorp.com.
  • With proxy:  proxy ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve
  • Or:          HTTPS_PROXY=socks5://127.0.0.1:7897 ./scripts/collect-aws-state.sh ..."
        fi
      else
        rm -rf "${tmp}"
        die "Cannot download AWS provider from releases.hashicorp.com.
  • With proxy:  proxy ./scripts/collect-aws-state.sh --rc ./c2rc.sh --auto-approve"
      fi
    fi
    have unzip || die "unzip is required"
    mkdir -p "${dest_dir}"
    unzip -qo "${tmp}/provider.zip" -d "${dest_dir}"
    chmod +x "${dest_dir}"/terraform-provider-aws* 2>/dev/null || true
    rm -rf "${tmp}"
    log "Installed provider → ${dest_dir}"
  else
    log "Using cached provider mirror: ${dest_dir}"
  fi

  local rc_file="${mirror_root}/terraform.rc"
  cat > "${rc_file}" <<EOF
provider_installation {
  filesystem_mirror {
    path    = "${mirror_root}"
    include = ["registry.terraform.io/hashicorp/aws"]
  }
  direct {
    exclude = ["registry.terraform.io/hashicorp/aws"]
  }
}
EOF
  export TF_CLI_CONFIG_FILE="${rc_file}"
  export AWS_PROVIDER_VERSION="${ver}"
  log "TF_CLI_CONFIG_FILE=${TF_CLI_CONFIG_FILE} (aws provider ${ver})"
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

# Drop attribute lines known to break on K2 / empty-invalid values
drop_line = re.compile(
    r'^\s*(?:'
    r'throughput|enable_lni_at_device_index|map_customer_owned_ip_on_launch|'
    r'customer_owned_ipv4_pool|outpost_arn|enable_network_address_usage_metrics|'
    r'disable_api_stop|disable_api_termination|instance_initiated_shutdown_behavior|'
    r'ipv6_address_count|ipv6_native|enable_resource_name_dns_a_record_on_launch|'
    r'enable_resource_name_dns_aaaa_record_on_launch|private_dns_hostname_type_on_launch|'
    r'acceleration_status|request_payer|object_lock_enabled|'
    r'bucket_domain_name|bucket_regional_domain_name|region\s*=\s*null'
    r')\s*=.*$',
    re.M,
)
text = drop_line.sub('', text)

# Remove route blocks with empty cidr_block = ""
text = re.sub(
    r'\n\s*route\s*\{[^{}]*?cidr_block\s*=\s*""[^{}]*?\}',
    '',
    text,
    flags=re.S,
)

# Remove empty replication_configuration / server_side_encryption_configuration shells
text = re.sub(r'\n\s*replication_configuration\s*\{\s*role\s*=\s*null\s*\}', '', text)
text = re.sub(r'\n\s*server_side_encryption_configuration\s*\{\s*\}', '', text)

# Fix SG default description that forces replacement
text = text.replace(
    'description            = "Managed by Terraform"',
    'description            = "default"',
)

# Collapse excessive blank lines
text = re.sub(r'\n{3,}', '\n\n', text)
open(dest, 'w', encoding='utf-8').write(text)
print(dest)
PY
  else
    # sed fallback
    grep -Ev '^\s*(throughput|enable_lni_at_device_index|map_customer_owned_ip_on_launch|customer_owned_ipv4_pool|outpost_arn)\s*=' \
      "${src}" > "${dest}.tmp" || true
    mv "${dest}.tmp" "${dest}"
  fi
}
