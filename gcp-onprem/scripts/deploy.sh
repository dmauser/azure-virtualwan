#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy the gcp-onprem lab (two GCP Partner Interconnect envs)
#
# Usage:
#   ./deploy.sh                              # fully interactive
#   ./deploy.sh -p my-project -y            # non-interactive
#   GCP_PROJECT=my-project ./deploy.sh -y
#
# Options:
#   -p, --project PROJECT    GCP project ID (or set GCP_PROJECT env var)
#   -1, --env1-region REGION env1 region (default: us-west2)
#   -2, --env2-region REGION env2 region (default: us-west4)
#   -y, --yes                Skip confirmation prompts
#
# WARNING — LAB ONLY. Not for production use.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisite check — verify required CLIs are installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# ---------------------------------------------------------------------------
lab_require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ ${#missing[@]} -eq 0 ] && return 0

  echo "[prereq] Missing required tool(s): ${missing[*]}" >&2
  for t in "${missing[@]}"; do
    case "$t" in
      az)        echo "  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli" >&2 ;;
      terraform) echo "  - Terraform:         https://developer.hashicorp.com/terraform/install" >&2 ;;
      gcloud)    echo "  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install" >&2 ;;
      jq)        echo "  - jq:                https://jqlang.github.io/jq/download/" >&2 ;;
      openssl)   echo "  - openssl:           install via your OS package manager" >&2 ;;
      python3)   echo "  - python3:           https://www.python.org/downloads/" >&2 ;;
      *)         echo "  - $t:                install via your OS package manager" >&2 ;;
    esac
  done

  if [ ! -t 0 ]; then
    echo "[prereq] Non-interactive shell — install the tool(s) above and re-run." >&2
    exit 1
  fi
  local ans=""
  read -r -p "[prereq] Attempt to install the missing tool(s) now? [y/N] " ans
  if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "[prereq] Install the tool(s) above and re-run." >&2
    exit 1
  fi

  local pm=""
  if   command -v brew    >/dev/null 2>&1; then pm="brew"
  elif command -v apt-get >/dev/null 2>&1; then pm="apt"
  elif command -v dnf     >/dev/null 2>&1; then pm="dnf"
  elif command -v yum     >/dev/null 2>&1; then pm="yum"
  fi
  if [ -z "$pm" ]; then
    echo "[prereq] No supported package manager (brew/apt/dnf/yum) found — install manually (see links above)." >&2
    exit 1
  fi
  for t in "${missing[@]}"; do
    echo "[prereq] Installing '$t' via $pm ..."
    case "$pm" in
      brew) brew install "$t" || true ;;
      apt)  sudo apt-get update -y && sudo apt-get install -y "$t" || true ;;
      dnf)  sudo dnf install -y "$t" || true ;;
      yum)  sudo yum install -y "$t" || true ;;
    esac
  done

  missing=()
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "[prereq] Still missing: ${missing[*]} (az/terraform/gcloud need a vendor installer — see links above). Re-run when ready." >&2
    exit 1
  fi
}
# Replace the tool list below with the tools THIS script actually needs:
lab_require_tools gcloud terraform


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Defaults
GCP_PROJECT="${GCP_PROJECT:-}"
ENV1_REGION="us-west2"
ENV2_REGION="us-west4"
NON_INTERACTIVE=0

# ---------- Helpers ----------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
info() { echo "  $*"; }
ok()   { echo -e "  \033[32m[OK]   $*\033[0m"; }
warn() { echo -e "  \033[33m[WARN] $*\033[0m"; }
fail() { echo -e "  \033[31m[FAIL] $*\033[0m"; exit 1; }

confirm() {
  local prompt="$1"
  [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
  read -r -p "${prompt} [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ---------- Parse arguments --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)      GCP_PROJECT="$2";    shift 2 ;;
    -1|--env1-region)  ENV1_REGION="$2";    shift 2 ;;
    -2|--env2-region)  ENV2_REGION="$2";    shift 2 ;;
    -y|--yes)          NON_INTERACTIVE=1;   shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- Auth check -------------------------------------------------------
log "Checking gcloud authentication..."
active_account="$(gcloud config get-value account 2>/dev/null || true)"
if [[ -z "$active_account" ]]; then
  warn "No active gcloud account. Running: gcloud auth login"
  gcloud auth login
else
  ok "Active account: ${active_account}"
fi

# ---------- Project ----------------------------------------------------------
if [[ -z "$GCP_PROJECT" ]]; then
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$GCP_PROJECT" && "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "Enter your GCP Project ID: " GCP_PROJECT
fi
[[ -z "$GCP_PROJECT" ]] && fail "GCP project ID is required."
info "Project : ${GCP_PROJECT}"

# ---------- Regions ----------------------------------------------------------
if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "env1 region [default: ${ENV1_REGION}]: " r1_input
  [[ -n "$r1_input" ]] && ENV1_REGION="$r1_input"

  read -r -p "env2 region [default: ${ENV2_REGION}]: " r2_input
  [[ -n "$r2_input" ]] && ENV2_REGION="$r2_input"
fi
info "env1 region : ${ENV1_REGION}"
info "env2 region : ${ENV2_REGION}"

# ---------- Write tfvars -----------------------------------------------------
TFVARS_PATH="${TERRAFORM_DIR}/terraform.tfvars"
log "Writing ${TFVARS_PATH} ..."

cat > "${TFVARS_PATH}" <<EOF
# Auto-generated by deploy.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Re-run deploy.sh to regenerate or edit manually.

project        = "${GCP_PROJECT}"
default_region = "${ENV1_REGION}"

allowed_source_ranges = [
  "192.168.0.0/16",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "35.235.240.0/20",
]

environments = {
  env1 = {
    region           = "${ENV1_REGION}"
    zone             = "${ENV1_REGION}-a"
    network_name     = "onprem-la"
    network_cidr     = "192.168.100.0/24"
    subnet_cidr      = "192.168.100.0/24"
    vm_private_ip    = "192.168.100.10"
  }

  env2 = {
    region           = "${ENV2_REGION}"
    zone             = "${ENV2_REGION}-a"
    network_name     = "onprem-lv"
    network_cidr     = "192.168.200.0/24"
    subnet_cidr      = "192.168.200.0/24"
    vm_private_ip    = "192.168.200.10"
  }
}
EOF
ok "terraform.tfvars written"

# ---------- Terraform --------------------------------------------------------
cd "${TERRAFORM_DIR}"

log "Running terraform init..."
terraform init
ok "terraform init complete"

log "Running terraform plan..."
terraform plan -out=tfplan
ok "terraform plan complete (saved to tfplan)"

confirm "Apply the plan to GCP project '${GCP_PROJECT}'?"
log "Running terraform apply..."
terraform apply tfplan
ok "terraform apply complete"

# ---------- Pairing keys -----------------------------------------------------
log "Retrieving pairing keys..."
echo ""
echo "================================================================"
echo "  PARTNER INTERCONNECT PAIRING KEYS"
echo "  Copy each key to your Megaport VXC configuration."
echo "================================================================"
terraform output -json pairing_keys
echo ""
echo "Next steps:"
echo "  1. Create Megaport VXC for env1 (LA)      -> paste env1 key -> connect to vwanlab-er1"
echo "  2. Create Megaport VXC for env2 (Phoenix) -> paste env2 key -> connect to vwanlab-er2"
echo "  See docs/megaport-cross-connect.md for detailed instructions."
