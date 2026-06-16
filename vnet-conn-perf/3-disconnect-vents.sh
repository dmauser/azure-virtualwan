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
lab_require_tools az


# variables

resource_group="lab-svh-inter"
location="eastus2"
vnet_prefix="vnet"
vhub_name="sechub1"

# Delete the connections that contains the name 'vnet-'
echo "Deleting connections that contain 'vnet-' in their name..."
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?contains(name, 'vnet-')].name" -o tsv | while read -r conn_name; do
  echo "Deleting connection: $conn_name"
  az network vhub connection delete --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --no-wait --output none --yes
done
echo "✅ All connections containing 'vnet-' have been deleted."

# Check all connections with failed status and delete them
echo "Checking for connections with 'Failed' status..." 
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | while read -r conn_name; do
  echo "Deleting failed connection: $conn_name"
  az network vhub connection delete --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --no-wait --output none --yes
done
echo "✅ All connections with 'Failed' status have been deleted."