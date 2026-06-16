#!/bin/bash
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
lab_require_tools az jq


# Variables
VM_SIZE=Standard_DS1_v2    # e.g., Standard_DS1_v2
REGION=eastus          # e.g., eastus

if [[ -z $VM_SIZE || -z $REGION ]]; then
  echo "Usage: $0 <VM_SIZE> <REGION>"
  exit 1
fi

echo "Checking availability of VM size '$VM_SIZE' in region '$REGION'..."

# Check if the VM size is available in the specified region
VM_SKU_INFO=$(az vm list-skus --location $REGION --query "[?name=='$VM_SIZE']" -o json)

if [[ -z $VM_SKU_INFO ]]; then
  echo "VM size '$VM_SIZE' is NOT available in region '$REGION'."
  exit 1
fi

echo "VM size '$VM_SIZE' is available in region '$REGION'."

# Check quota for the VM size in the region
echo "Checking quota for VM size '$VM_SIZE' in region '$REGION'..."
QUOTA=$(az vm list-usage --location $REGION --query "[?contains(localName, '$VM_SIZE')]" -o json)

if [[ -z $QUOTA ]]; then
  echo "Error: Unable to retrieve quota information for VM size '$VM_SIZE' in region '$REGION'."
  exit 1
fi

LIMIT=$(echo $QUOTA | jq -r '.[0].limit')
CURRENT_USAGE=$(echo $QUOTA | jq -r '.[0].currentValue')

if [[ $CURRENT_USAGE -ge $LIMIT ]]; then
  echo "Error: Quota exceeded for VM size '$VM_SIZE' in region '$REGION'. Current usage: $CURRENT_USAGE, Limit: $LIMIT."
  echo "Request a quota increase through the Azure Portal."
  exit 1
fi

echo "Quota is sufficient for VM size '$VM_SIZE' in region '$REGION'. Current usage: $CURRENT_USAGE, Limit: $LIMIT."

# get vm size family
VM_SIZE_FAMILY=$(echo $VM_SKU_INFO | jq -r '.[0].family')

