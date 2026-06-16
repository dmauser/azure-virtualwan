#!/usr/bin/env bash
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


# Get subscription ID from your current account context
subscriptionId=$(az account show --query id -o tsv)

# Set your resource group and virtual hub name
resourceGroupName="<your-resource-group-name>"
virtualHubName="<your-virtual-hub-name>"

# determine the existing resource location (required for PUT)
location=$(az resource show \
  --resource-group "$resourceGroupName" \
  --resource-type "Microsoft.Network/virtualHubs" \
  --name "$virtualHubName" \
  --query location -o tsv)

if [ -z "$location" ]; then
  echo "Failed to determine location for virtual hub '$virtualHubName' in resource group '$resourceGroupName'." >&2
  exit 1
fi

az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/virtualHubs/$virtualHubName?api-version=2024-05-01" \
  --headers "Content-Type=application/json" \
  --body "{\"location\":\"$location\"}"
# print the request URI for debugging
echo "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/virtualHubs/$virtualHubName?api-version=2024-05-01"

/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1


https://management.azure.com/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1?api-version=2023-06-01

# GET the current resource JSON, sanitize it, then PUT it back
uri="https://management.azure.com/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1?api-version=2023-06-01"

tmp_get=$(mktemp)
tmp_body=$(mktemp)
trap 'rm -f "$tmp_get" "$tmp_body"' EXIT

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not found. Install jq and retry." >&2
    exit 1
fi

# GET the resource
az rest --method GET --uri "$uri" -o json >"$tmp_get" || { echo "GET failed" >&2; exit 1; }

# Build a PUT body from the GET output:
# - remove read-only fields that can cause PUT to fail
# - ensure the location field stays set to $location (from earlier in the script)
jq --arg loc "$location" '
    del(.id, .name, .type, .etag, .properties.provisioningState, .systemData) |
    .location = $loc
' "$tmp_get" > "$tmp_body" || { echo "Failed to build request body" >&2; exit 1; }

# PUT using the sanitized body file
az rest --method PUT \
    --uri "$uri" \
    --headers "Content-Type=application/json" \
    --body @"$tmp_body" || { echo "PUT failed" >&2; exit 1; }

# Optional: GET to show the updated resource
az rest --method GET --uri "$uri" -o json


