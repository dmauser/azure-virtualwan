#!/usr/bin/env bash
# =============================================================================
# validate.sh — Validate gcp-onprem lab deployment via gcloud
#
# Usage:
#   ./validate.sh
#   ./validate.sh -p my-project
#   GCP_PROJECT=my-project ./validate.sh
#
# Options:
#   -p, --project PROJECT   GCP project ID (or set GCP_PROJECT env var)
#
# Checks per environment:
#   - VPC network exists
#   - Subnet exists
#   - VM instance is RUNNING
#   - Cloud Router exists
#   - Interconnect attachment exists + pairing key present (PENDING_PARTNER ok)
#   - Firewall rule exists
#
# Exits non-zero if any check fails.
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
lab_require_tools gcloud


# Defaults
GCP_PROJECT="${GCP_PROJECT:-}"

# ---------- Helpers ----------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
hdr()  { echo ""; echo "###############################################################"; echo "# $*"; echo "###############################################################"; }
pass() { echo -e "  \033[32m[PASS] $*\033[0m"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo -e "  \033[31m[FAIL] $*\033[0m"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn() { echo -e "  \033[33m[WARN] $*\033[0m"; }

gcloud_val() {
  gcloud "$@" 2>/dev/null || true
}

# ---------- Parse arguments --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) GCP_PROJECT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------- Project ----------------------------------------------------------
if [[ -z "$GCP_PROJECT" ]]; then
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$GCP_PROJECT" ]]; then
  read -r -p "Enter your GCP Project ID: " GCP_PROJECT
fi
[[ -z "$GCP_PROJECT" ]] && { echo "[FAIL] GCP project ID required."; exit 1; }
log "Project: ${GCP_PROJECT}"

# ---------- Environments -----------------------------------------------------
declare -a NAMES=("env1" "env2")
declare -a NETWORKS=("onprem-la" "onprem-lv")
declare -a REGIONS=("us-west2" "us-west4")
declare -a ZONES=("us-west2-a" "us-west4-a")

for i in 0 1; do
  NAME="${NAMES[$i]}"
  NET="${NETWORKS[$i]}"
  REGION="${REGIONS[$i]}"
  ZONE="${ZONES[$i]}"
  VM="${NET}-vm"
  ROUTER="${NET}-router"
  ATTACHMENT="${NET}-partner-attachment"
  FIREWALL="${NET}-allow"

  hdr "Validating ${NAME} — ${NET} (${REGION})"

  # VPC network
  net_val="$(gcloud_val compute networks describe "${NET}" --project="${GCP_PROJECT}" --format="value(name)")"
  if [[ "$net_val" == "$NET" ]]; then
    pass "VPC network '${NET}' exists"
  else
    fail "VPC network '${NET}' not found"
  fi

  # Subnet
  sn_val="$(gcloud_val compute networks subnets describe "${NET}-subnet" \
             --project="${GCP_PROJECT}" --region="${REGION}" --format="value(name)")"
  if [[ "$sn_val" == "${NET}-subnet" ]]; then
    pass "Subnet '${NET}-subnet' exists in ${REGION}"
  else
    fail "Subnet '${NET}-subnet' not found in ${REGION}"
  fi

  # VM status
  vm_status="$(gcloud_val compute instances describe "${VM}" \
               --project="${GCP_PROJECT}" --zone="${ZONE}" --format="value(status)")"
  if [[ "$vm_status" == "RUNNING" ]]; then
    pass "VM '${VM}' is RUNNING"
  else
    fail "VM '${VM}' status='${vm_status}' (expected RUNNING)"
  fi

  # Cloud Router
  router_val="$(gcloud_val compute routers describe "${ROUTER}" \
                --project="${GCP_PROJECT}" --region="${REGION}" --format="value(name)")"
  if [[ "$router_val" == "$ROUTER" ]]; then
    pass "Cloud Router '${ROUTER}' exists"
  else
    fail "Cloud Router '${ROUTER}' not found"
  fi

  # Interconnect attachment + pairing key
  pairing_key="$(gcloud_val compute interconnects attachments describe "${ATTACHMENT}" \
                 --project="${GCP_PROJECT}" --region="${REGION}" --format="value(pairingKey)")"
  if [[ -n "$pairing_key" ]]; then
    pass "Interconnect attachment '${ATTACHMENT}' exists and has pairing key"
    warn "  Pairing key: ${pairing_key}  (supply to Megaport VXC)"
  else
    attach_name="$(gcloud_val compute interconnects attachments describe "${ATTACHMENT}" \
                   --project="${GCP_PROJECT}" --region="${REGION}" --format="value(name)")"
    if [[ "$attach_name" == "$ATTACHMENT" ]]; then
      pass "Interconnect attachment '${ATTACHMENT}' exists (pairing key not yet available — PENDING_PARTNER ok)"
    else
      fail "Interconnect attachment '${ATTACHMENT}' not found"
    fi
  fi

  # Firewall rule
  fw_val="$(gcloud_val compute firewall-rules describe "${FIREWALL}" \
             --project="${GCP_PROJECT}" --format="value(name)")"
  if [[ "$fw_val" == "$FIREWALL" ]]; then
    pass "Firewall rule '${FIREWALL}' exists"
  else
    fail "Firewall rule '${FIREWALL}' not found"
  fi
done

# ---------- Summary ----------------------------------------------------------
echo ""
echo "###############################################################"
echo "# SUMMARY"
echo "###############################################################"
echo -e "  \033[32mPASS : ${PASS_COUNT}\033[0m"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo -e "  \033[31mFAIL : ${FAIL_COUNT}\033[0m"
  echo ""
  echo -e "\033[31mValidation FAILED. See [FAIL] items above.\033[0m"
  exit 1
else
  echo -e "  \033[32mFAIL : ${FAIL_COUNT}\033[0m"
  echo ""
  echo -e "\033[32mAll checks PASSED.\033[0m"
fi
