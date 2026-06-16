#!/usr/bin/env bash
# =============================================================================
# cleanup.sh — Tear down the gcp-onprem lab (terraform destroy)
#
# Usage:
#   ./cleanup.sh             # interactive
#   ./cleanup.sh -y          # skip confirms (non-interactive)
#
# Options:
#   -y, --yes    Skip confirmation prompts
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

NON_INTERACTIVE=0

# ---------- Helpers ----------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
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
    -y|--yes) NON_INTERACTIVE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- Megaport reminder -----------------------------------------------
echo ""
echo -e "\033[33m================================================================\033[0m"
echo -e "\033[33m  IMPORTANT — READ BEFORE CONTINUING\033[0m"
echo -e "\033[33m================================================================\033[0m"
echo -e "\033[33m  1. Interconnect VLAN attachments incur hourly cost even when\033[0m"
echo -e "\033[33m     the circuit is not passing traffic. Destroy removes them.\033[0m"
echo -e "\033[33m  2. Megaport VXCs are NOT managed by Terraform and will NOT be\033[0m"
echo -e "\033[33m     deleted by this script.\033[0m"
echo -e "\033[33m     --> Manually delete VXCs in the Megaport portal BEFORE or\033[0m"
echo -e "\033[33m         AFTER running this cleanup to avoid orphan charges.\033[0m"
echo -e "\033[33m================================================================\033[0m"
echo ""

confirm "Proceed with 'terraform destroy' for the gcp-onprem lab?"

# ---------- Terraform destroy -----------------------------------------------
cd "${TERRAFORM_DIR}"
log "Running terraform destroy..."
if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
  terraform destroy -auto-approve
else
  terraform destroy
fi
ok "terraform destroy complete"
echo ""
echo -e "\033[32mCleanup complete.\033[0m"
echo -e "\033[33mRemember to delete your Megaport VXCs manually in the Megaport portal.\033[0m"
