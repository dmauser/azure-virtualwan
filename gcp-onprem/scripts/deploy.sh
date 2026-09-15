#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Deploy the gcp-onprem lab (one or more Partner Interconnect envs)
#
# Usage:
#   ./deploy.sh                                   # fully interactive
#   ./deploy.sh -p my-project -n 1 -r us-central1 -y
#   ./deploy.sh -p my-project -n 3 -r us-central1 -r us-west2 -r us-east4 -y
#   GCP_PROJECT=my-project ./deploy.sh -y
#
# Options:
#   -p, --project PROJECT    GCP project ID (or set GCP_PROJECT env var)
#   -n, --count N            Number of on-prem environments (default: 1)
#   -r, --region REGION      Region for the next env (repeatable; fills in order)
#   -y, --yes                Skip confirmation prompts
#
# Environment N is auto-named:
#   network_name  = onprem-<N>
#   network_cidr  = subnet_cidr = 192.168.<N>.0/24
#   vm_private_ip = 192.168.<N>.10
#   zone          = <region>-a
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
DEFAULT_REGION="us-central1"
COUNT=1
REGIONS=()
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

# ---------- Region picker ----------------------------------------------------
# Coast-grouped menu of common US regions. Echoes the chosen region. Accepts a
# menu number, a free-text region, or empty for the default. Prompt text is sent
# to stderr so command substitution captures only the region id.
REGION_IDS=(us-west1 us-west2 us-west3 us-west4 us-central1 us-south1 us-east1 us-east4 us-east5)

select_gcp_region() {
  local title="$1"
  {
    echo ""
    echo "${title}"
    echo "  -- West --"
    echo "    [1] us-west1     Oregon"
    echo "    [2] us-west2     Los Angeles"
    echo "    [3] us-west3     Salt Lake City"
    echo "    [4] us-west4     Las Vegas"
    echo "  -- Central --"
    echo "    [5] us-central1  Iowa (default)"
    echo "    [6] us-south1    Dallas"
    echo "  -- East --"
    echo "    [7] us-east1     South Carolina"
    echo "    [8] us-east4     Northern Virginia"
    echo "    [9] us-east5     Columbus"
    echo "  (Enter a number, type any other region id, or press Enter for default '${DEFAULT_REGION}')"
  } >&2
  local choice=""
  read -r -p "  Region: " choice
  if [[ -z "$choice" ]]; then
    echo "$DEFAULT_REGION"; return
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#REGION_IDS[@]} )); then
    echo "${REGION_IDS[$((choice - 1))]}"; return
  fi
  echo "$choice"
}

# ---------- Parse arguments --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project)  GCP_PROJECT="$2";    shift 2 ;;
    -n|--count)    COUNT="$2";          shift 2 ;;
    -r|--region)   REGIONS+=("$2");     shift 2 ;;
    -y|--yes)      NON_INTERACTIVE=1;   shift   ;;
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

# ---------- Environment count ------------------------------------------------
if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "How many on-prem environments to deploy? [default: ${COUNT}]: " c_input
  [[ -n "$c_input" ]] && COUNT="$c_input"
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
  fail "Count must be a positive integer."
fi
(( COUNT > 254 )) && fail "Count must be 254 or fewer (CIDR third-octet limit)."
info "On-prem environments : ${COUNT}"

# ---------- Regions per environment -----------------------------------------
ENV_REGIONS=()
for (( i = 1; i <= COUNT; i++ )); do
  if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
    r="$(select_gcp_region "Select region for env${i}")"
  elif (( i <= ${#REGIONS[@]} )); then
    r="${REGIONS[$((i - 1))]}"
  else
    r="$DEFAULT_REGION"
  fi
  [[ -z "$r" ]] && r="$DEFAULT_REGION"
  ENV_REGIONS+=("$r")
  info "env${i} region : ${r}"
done

# ---------- Write tfvars -----------------------------------------------------
TFVARS_PATH="${TERRAFORM_DIR}/terraform.tfvars"
log "Writing ${TFVARS_PATH} ..."

cat > "${TFVARS_PATH}" <<EOF
# Auto-generated by deploy.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Re-run deploy.sh to regenerate or edit manually.

project        = "${GCP_PROJECT}"
default_region = "${ENV_REGIONS[0]}"

allowed_source_ranges = [
  "192.168.0.0/16",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "35.235.240.0/20",
]

environments = {
EOF

for (( i = 1; i <= COUNT; i++ )); do
  region="${ENV_REGIONS[$((i - 1))]}"
  cat >> "${TFVARS_PATH}" <<EOF
  env${i} = {
    region        = "${region}"
    zone          = "${region}-a"
    network_name  = "onprem-${i}"
    network_cidr  = "192.168.${i}.0/24"
    subnet_cidr   = "192.168.${i}.0/24"
    vm_private_ip = "192.168.${i}.10"
  }
EOF
done

echo "}" >> "${TFVARS_PATH}"
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
echo "  For each environment above, create a Megaport VXC, paste its pairing"
echo "  key, and connect it to the matching Azure ExpressRoute circuit"
echo "  (e.g. vwanlab-er1, vwanlab-er2, ...)."
echo "  See docs/megaport-cross-connect.md for detailed instructions."
