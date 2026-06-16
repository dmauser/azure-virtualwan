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

for i in $(seq 1 100); do
  vnet_name="${vnet_prefix}-${i}"
  connection_name="${vnet_name}-conn"

  echo "Connecting $vnet_name to virtual hub"

az network vhub connection create \
    --name "$connection_name" \
    --resource-group "$resource_group" \
    --vhub-name "$vhub_name" \
    --remote-vnet "$vnet_name" \
    --internet-security false \
    --no-wait \
    --output none
done

# For each connection I need to keep a track on amount of seconds how long it takes to connected, so I will use a loop to check the status of each connection
# and print the time taken for each connection to reach the 'Connected' state.
# Function to check connection status and measure time
check_connection() {
  conn_name="$1"
  start_time=$(date +%s)
  while true; do
    status=$(az network vhub connection show --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --query "provisioningState" -o tsv)
    if [ "$status" == "Succeeded" ]; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      echo "✅ Connection $conn_name is in 'Connected' state. Time taken: $duration seconds."
      break
    elif [ "$status" == "Failed" ]; then
      echo "❌ Connection $conn_name failed to connect."
      break
    else
      sleep 10
    fi
  done
}

# Run all checks in parallel
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[].name" -o tsv | while read -r conn_name; do
  check_connection "$conn_name" &
done
wait



# Pause and wait for user input before starting the status check loop


# Check all the connections and their statuses, show the count for each status and only finish the script when all connections are in the 'Connected' state
while true; do
  echo "Checking connection statuses..."
  az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[].{Name:name, Status:provisioningState}" -o table
  sleep 10
  connected_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Succeeded'].name" -o tsv | wc -l)
  failed_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | wc -l)
  updating_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Updating'].name" -o tsv | wc -l)
  deleting_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Deleting'].name" -o tsv | wc -l)
  total_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "length(@)" -o tsv)
  echo "Connected: $connected_count, Failed: $failed_count, Updating: $updating_count, Deleting: $deleting_count, Total: $total_count"
  read -n 1 -s -r -p "Press any key to start checking connection statuses..."
  echo
  if [ "$connected_count" -eq "$total_count" ]; then
      echo "✅ All connections are in the 'Connected' state."
      break
  fi
done

# Check all connections with status failed and retry to connect them in parallel
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | while read -r conn_name; do
  echo "Retrying connection for $conn_name..."
  az network vhub connection create \
      --name "$conn_name" \
      --resource-group "$resource_group" \
      --vhub-name "$vhub_name" \
      --remote-vnet "${conn_name%-conn}" \
      --internet-security false \
      --no-wait \
      --output none
  check_connection "$conn_name" &
done
wait




