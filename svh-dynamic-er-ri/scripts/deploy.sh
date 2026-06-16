#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Interactive deploy for svh-dynamic-er-ri (Secured vWAN lab)
#
# Deploys 1-4 secured vHubs, optional ER circuits/gateways, Azure Firewall
# Basic, and Routing Intent via Bicep + Azure CLI.
#
# Usage:
#   ./deploy.sh                          # fully interactive
#   ./deploy.sh --answers-file env.sh    # source env file, skip prompts
#   LAB_NON_INTERACTIVE=1 ./deploy.sh    # env vars drive all defaults
#
# Non-interactive env vars (all optional; omitting = use built-in defaults):
#   LAB_SUBSCRIPTION, LAB_RG, LAB_LOCATION, LAB_PREFIX, LAB_NUM_HUBS
#   LAB_HUB1_REGION .. LAB_HUB4_REGION
#   LAB_HUB1_ERGW .. LAB_HUB4_ERGW     (true/false)
#   LAB_RI_MODE                          (privateOnly|internetOnly|both)
#   LAB_DEPLOY_VMS                       (true/false)
#   LAB_ATTACH_PUBLIC_IP                 (true/false)
#   LAB_ENABLE_DIAGNOSTICS               (true/false)
#   LAB_SSH_KEY_PATH                     (no longer used — password auth only)
#   LAB_NUM_ER_CIRCUITS, LAB_ER_PROVIDER, LAB_ER_BANDWIDTH
#   LAB_ER_SKU, LAB_ER_FAMILY
#   LAB_ER1_NAME .. LAB_ER4_NAME
#   LAB_ER1_PERLOC .. LAB_ER4_PERLOC
#   LAB_ER1_REGION .. LAB_ER4_REGION
#   MAX_WAIT_MIN                         (default 180)
#
# ⚠️  LAB-ONLY: firewall policies include an allow-all rule.
# ⚠️  All hubs use hubRoutingPreference = ExpressRoute.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/../infra/bicep"
PARAMS_DIR="${SCRIPT_DIR}/../infra/parameters"
VM_SKU_CANDIDATES=(Standard_B2s Standard_B2ms Standard_D2s_v3 Standard_D2as_v5 Standard_D2s_v5)
MAX_WAIT_MIN="${MAX_WAIT_MIN:-180}"
NON_INTERACTIVE="${LAB_NON_INTERACTIVE:-0}"

# ---------- Parse arguments -------------------------------------------------
ANSWERS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --answers-file) ANSWERS_FILE="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -n "$ANSWERS_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ANSWERS_FILE"
  NON_INTERACTIVE=1
fi

# ---------- Logging helper --------------------------------------------------
# Timestamp every progress line so stalls are obvious in terminal output.
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# ---------- Banner ----------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║       svh-dynamic-er-ri — Secured Virtual WAN Lab Deployment        ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  LAB-ONLY: every firewall policy includes an allow-all rule.     ║"
echo "║  ⚠️  All hubs use Route Preference = ExpressRoute.                   ║"
echo "║  ⚠️  NEVER use this configuration in production.                     ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ---------- Phase 0: Pre-flight ---------------------------------------------
log "### Phase 0: Pre-flight checks ###"
az extension add --name virtual-wan --upgrade -o none 2>/dev/null || true
az extension add --name azure-firewall --upgrade -o none 2>/dev/null || true
az account show &>/dev/null || { echo "ERROR: Not logged in. Run 'az login' first."; exit 1; }
echo "  CLI extensions OK."

# ---------- Helper: ask_default ---------------------------------------------
# Usage: ask_default VAR_NAME "Prompt text" "default value"
# If NON_INTERACTIVE=1 and var already set from env, uses it silently.
ask_default() {
  local var_name="$1" prompt_msg="$2" default_val="$3"
  if [[ "$NON_INTERACTIVE" == "1" ]] && [[ -n "${!var_name:-}" ]]; then
    echo "  ${prompt_msg}: ${!var_name} (env)"
  else
    local val
    read -r -p "  ${prompt_msg} [${default_val}]: " val
    val="${val:-$default_val}"
    printf -v "$var_name" '%s' "$val"
  fi
}

# ---------- Helper: pick_vm_sku ---------------------------------------------
pick_vm_sku() {
  local region="$1" result_var="$2" picked="" restrictions=""
  for sku in "${VM_SKU_CANDIDATES[@]}"; do
    restrictions=$(az vm list-skus -l "$region" --resource-type virtualMachines \
      --query "[?name=='$sku'].restrictions" -o tsv 2>/dev/null || echo "error")
    if [[ -z "$restrictions" && "$restrictions" != "error" ]]; then
      picked="$sku"; break
    fi
  done
  if [[ -z "$picked" ]]; then
    echo "ERROR: No candidate VM SKU available in '$region'. Tried: ${VM_SKU_CANDIDATES[*]}"
    exit 1
  fi
  printf -v "$result_var" '%s' "$picked"
}

# ---------- Helper: poll_until ----------------------------------------------
# Usage: poll_until LABEL TARGET SLEEP_SEC MAX_ITER COMMAND [args...]
# Polls COMMAND until it outputs TARGET or MAX_ITER is reached.
# Each tick is logged with a timestamp.
poll_until() {
  local label="$1" target="$2" sleep_sec="$3" max_iter="$4"
  shift 4
  local state="" iter=0
  while true; do
    iter=$((iter + 1))
    if [[ $iter -gt $max_iter ]]; then
      log "  WARNING: poll_until '$label' timed out after $max_iter iterations — continuing."
      break
    fi
    state=$("$@" 2>/dev/null || echo "NotFound")
    log "  ${label}: ${state}"
    [[ "$state" == "$target" ]] && break
    sleep "$sleep_sec"
  done
}

# ---------- Phase 1: Interactive configuration ------------------------------
echo ""
log "### Phase 1: Configuration ###"
[[ "$NON_INTERACTIVE" == "0" ]] && echo "  (Set LAB_NON_INTERACTIVE=1 to skip prompts)"
echo ""

ask_default LAB_SUBSCRIPTION "Azure Subscription ID" \
  "$(az account show --query id -o tsv 2>/dev/null || echo '')"
ask_default LAB_RG           "Resource group name"           "lab-svh-dynamic-er-ri"
ask_default LAB_LOCATION     "Deployment region (vWAN/KV/RG)" "eastus"
ask_default LAB_PREFIX       "Lab prefix"                     "vwanlab"
ask_default LAB_NUM_HUBS     "Number of vHubs (1-4)"          "1"
ask_default LAB_RI_MODE      "Routing Intent mode (privateOnly/internetOnly/both)" "privateOnly"

SUBSCRIPTION="${LAB_SUBSCRIPTION}"
rg="${LAB_RG}"
deploy_location="${LAB_LOCATION}"
labPrefix="${LAB_PREFIX}"
num_hubs="${LAB_NUM_HUBS}"
ri_mode="${LAB_RI_MODE}"

if ! [[ "$num_hubs" =~ ^[1-4]$ ]]; then
  echo "ERROR: num_hubs must be 1-4."; exit 1
fi
if ! [[ "$ri_mode" =~ ^(privateOnly|internetOnly|both)$ ]]; then
  echo "ERROR: ri_mode must be privateOnly, internetOnly, or both."; exit 1
fi

az account set --subscription "$SUBSCRIPTION"

# Per-hub regions
DEFAULT_REGIONS=("eastus" "westus" "centralus" "southcentralus")
declare -a hub_regions
for i in $(seq 1 "$num_hubs"); do
  idx=$((i - 1))
  var_name="LAB_HUB${i}_REGION"
  default_region="${DEFAULT_REGIONS[$idx]:-eastus}"
  ask_default "$var_name" "Hub $i region" "$default_region"
  hub_regions[$idx]="${!var_name}"
done

# Per-hub ER gateway
declare -a hub_has_erg
for i in $(seq 1 "$num_hubs"); do
  idx=$((i - 1))
  var_name="LAB_HUB${i}_ERGW"
  ask_default "$var_name" "Deploy ER Gateway in hub $i? (true/false)" "false"
  val="${!var_name}"
  [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" ]] && hub_has_erg[$idx]="true" || hub_has_erg[$idx]="false"
done

ask_default LAB_DEPLOY_VMS          "Deploy Ubuntu VMs in spokes? (true/false)" "true"
ask_default LAB_ATTACH_PUBLIC_IP    "Attach public IP to VMs? (true/false)"     "false"
ask_default LAB_ENABLE_DIAGNOSTICS  "Enable Log Analytics diagnostics? (true/false)" "false"

deploy_vms="${LAB_DEPLOY_VMS}"
[[ "$deploy_vms" == "true" || "$deploy_vms" == "1" ]] && deploy_vms="true" || deploy_vms="false"
attach_pip="${LAB_ATTACH_PUBLIC_IP}"
[[ "$attach_pip" == "true" || "$attach_pip" == "1" ]] && attach_pip="true" || attach_pip="false"
enable_diag="${LAB_ENABLE_DIAGNOSTICS}"
[[ "$enable_diag" == "true" || "$enable_diag" == "1" ]] && enable_diag="true" || enable_diag="false"

# No SSH key — VMs authenticate with username/password stored in Key Vault
ssh_pub_key=""

# Get caller public IP for NSG SSH rule (best-effort; empty = no rule)
mypip=$(curl -4 -s --max-time 5 ifconfig.io 2>/dev/null || echo "")

# ER circuits
ask_default LAB_NUM_ER_CIRCUITS "Number of ER circuits to create (0 to skip)" "0"
num_er_circuits="${LAB_NUM_ER_CIRCUITS}"

declare -a er_names er_perlocs er_regions
er_provider="" er_bandwidth="" er_sku="" er_family=""

if [[ "$num_er_circuits" -gt 0 ]]; then
  ask_default LAB_ER_PROVIDER  "ER provider (e.g. Megaport, Equinix)"         "Megaport"
  ask_default LAB_ER_BANDWIDTH "ER bandwidth (Mbps)"                           "50"
  ask_default LAB_ER_SKU       "ER SKU tier (Local/Standard/Premium)"          "Standard"
  ask_default LAB_ER_FAMILY    "ER billing family (MeteredData/UnlimitedData)" "MeteredData"
  er_provider="${LAB_ER_PROVIDER}"
  er_bandwidth="${LAB_ER_BANDWIDTH}"
  er_sku="${LAB_ER_SKU}"
  er_family="${LAB_ER_FAMILY}"

  for n in $(seq 1 "$num_er_circuits"); do
    idx=$((n - 1))
    var_name="LAB_ER${n}_NAME"; ask_default "$var_name" "ER circuit $n name"             "${labPrefix}-er${n}"
    er_names[$idx]="${!var_name}"
    var_perloc="LAB_ER${n}_PERLOC"; ask_default "$var_perloc" "ER circuit $n peering location" "Washington DC"
    er_perlocs[$idx]="${!var_perloc}"
    var_region="LAB_ER${n}_REGION"; ask_default "$var_region" "ER circuit $n Azure region"       "${hub_regions[0]}"
    er_regions[$idx]="${!var_region}"
  done
fi

# ---------- Phase 2: Generate credentials -----------------------------------
echo ""
log "### Phase 2: Generating VM credentials ###"
admin_username="labadmin$(openssl rand -hex 2)"
# Password: prefix Lab + 16 random hex chars + suffix ensures upper/lower/digit/symbol
admin_password="Lab$(openssl rand -hex 8)Aa1!"
echo "  Admin username : $admin_username"
echo "  Admin password : <stored in Key Vault — not echoed>"

# ---------- Phase 3: VM SKU pre-flight per hub region -----------------------
echo ""
log "### Phase 3: VM SKU pre-flight ###"
declare -a hub_vm_skus
if [[ "$deploy_vms" == "true" ]]; then
  declare -A region_sku_cache
  for i in $(seq 1 "$num_hubs"); do
    idx=$((i - 1))
    region="${hub_regions[$idx]}"
    cached="${region_sku_cache[$region]:-}"
    if [[ -n "$cached" ]]; then
      hub_vm_skus[$idx]="$cached"
    else
      pick_vm_sku "$region" "_tmp_sku"
      hub_vm_skus[$idx]="$_tmp_sku"
      region_sku_cache["$region"]="$_tmp_sku"
    fi
    echo "  Hub $i (${region}): ${hub_vm_skus[$idx]}"
  done
else
  for i in $(seq 1 "$num_hubs"); do
    hub_vm_skus[$((i-1))]="Standard_B2s"
  done
fi

# ---------- Phase 4: Resource group + Key Vault name ------------------------
echo ""
log "### Phase 4: Resource group ###"
az group create -n "$rg" -l "$deploy_location" --output none
echo "  Resource group : $rg ($deploy_location)"

# KV name: labPrefixkv + 4 random hex chars, lowercase alnum, max 24 chars
raw_kv="${labPrefix}kv$(openssl rand -hex 2)"
kv_name="$(echo "$raw_kv" | tr -dc 'a-z0-9' | cut -c1-24)"
echo "  Key Vault name : $kv_name"

deployer_oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo '')"
owner_name="$(az account show --query user.name -o tsv 2>/dev/null || echo 'unknown')"

# ---------- Phase 5: Build hubs JSON array ----------------------------------
echo ""
log "### Phase 5: Building deployment parameters ###"
hubs_json="["
for i in $(seq 1 "$num_hubs"); do
  idx=$((i - 1))
  region="${hub_regions[$idx]}"
  hub_addr="10.$((i * 10)).0.0/23"
  spoke_addr="10.$((i * 10 + 1)).0.0/24"
  subnet_addr="10.$((i * 10 + 1)).0.0/27"
  has_erg="${hub_has_erg[$idx]:-false}"
  vm_sku="${hub_vm_skus[$idx]:-Standard_B2s}"
  sep=""; [[ $i -lt $num_hubs ]] && sep=","
  hubs_json="${hubs_json}{\"region\":\"${region}\",\"hubAddressPrefix\":\"${hub_addr}\",\"spokeAddressPrefix\":\"${spoke_addr}\",\"subnetPrefix\":\"${subnet_addr}\",\"deployErGateway\":${has_erg},\"deployVm\":${deploy_vms},\"vmSize\":\"${vm_sku}\"}${sep}"
done
hubs_json="${hubs_json}]"

# Write generated params file (no secrets)
mkdir -p "$PARAMS_DIR"
PARAMS_FILE="${PARAMS_DIR}/generated-${labPrefix}.json"
cat > "$PARAMS_FILE" << PARAMSEOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "labPrefix":          { "value": "${labPrefix}" },
    "location":           { "value": "${deploy_location}" },
    "hubs":               { "value": ${hubs_json} },
    "tags":               { "value": { "owner": "${owner_name}", "labName": "${labPrefix}" } },
    "adminUsername":      { "value": "${admin_username}" },
    "sshPublicKey":       { "value": "${ssh_pub_key}" },
    "vmSize":             { "value": "Standard_B2s" },
    "keyVaultName":       { "value": "${kv_name}" },
    "deployerObjectId":   { "value": "${deployer_oid}" },
    "enableDiagnostics":  { "value": ${enable_diag} },
    "allowedSshSourceIp": { "value": "${mypip}" },
    "attachPublicIp":     { "value": ${attach_pip} }
  }
}
PARAMSEOF
echo "  Parameters file: $PARAMS_FILE"

# ---------- Phase 6: Deploy main.bicep (with VM SKU auto-retry) -------------
echo ""
log "### Phase 6: Deploying main Bicep template ###"
log "  Template       : ${BICEP_DIR}/main.bicep"
log "  NOTE: Azure Firewall provisioning takes ~30-45 min. Please wait."
# SKU auto-retry: if the bicep deployment fails with SkuNotAvailable/Capacity
# the loop advances to the next candidate in VM_SKU_CANDIDATES, regenerates
# the params file for ALL hubs with that SKU, and retries.
deploy_start=$(date +%s)
sku_retry_idx=0
deploy_success=false

while [[ "$deploy_success" == "false" ]]; do
  current_sku="${VM_SKU_CANDIDATES[$sku_retry_idx]}"

  # Rebuild hubs JSON with the current candidate SKU for every hub.
  hubs_json="["
  for i in $(seq 1 "$num_hubs"); do
    idx=$((i - 1))
    region="${hub_regions[$idx]}"
    hub_addr="10.$((i * 10)).0.0/23"
    spoke_addr="10.$((i * 10 + 1)).0.0/24"
    subnet_addr="10.$((i * 10 + 1)).0.0/27"
    has_erg="${hub_has_erg[$idx]:-false}"
    sep=""; [[ $i -lt $num_hubs ]] && sep=","
    hubs_json="${hubs_json}{\"region\":\"${region}\",\"hubAddressPrefix\":\"${hub_addr}\",\"spokeAddressPrefix\":\"${spoke_addr}\",\"subnetPrefix\":\"${subnet_addr}\",\"deployErGateway\":${has_erg},\"deployVm\":${deploy_vms},\"vmSize\":\"${current_sku}\"}${sep}"
  done
  hubs_json="${hubs_json}]"

  # Rewrite params file with the current SKU.
  cat > "$PARAMS_FILE" << PARAMSEOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "labPrefix":          { "value": "${labPrefix}" },
    "location":           { "value": "${deploy_location}" },
    "hubs":               { "value": ${hubs_json} },
    "tags":               { "value": { "owner": "${owner_name}", "labName": "${labPrefix}" } },
    "adminUsername":      { "value": "${admin_username}" },
    "sshPublicKey":       { "value": "${ssh_pub_key}" },
    "vmSize":             { "value": "${current_sku}" },
    "keyVaultName":       { "value": "${kv_name}" },
    "deployerObjectId":   { "value": "${deployer_oid}" },
    "enableDiagnostics":  { "value": ${enable_diag} },
    "allowedSshSourceIp": { "value": "${mypip}" },
    "attachPublicIp":     { "value": ${attach_pip} }
  }
}
PARAMSEOF

  DEPLOYMENT_NAME="${labPrefix}-deploy-$(date +%Y%m%d%H%M%S)"
  log "  Deployment name: $DEPLOYMENT_NAME  (VM SKU: $current_sku)"

  # Run deployment; capture combined stderr for SKU detection.
  deploy_out=$(az deployment group create \
    -g "$rg" \
    -n "$DEPLOYMENT_NAME" \
    --template-file "${BICEP_DIR}/main.bicep" \
    --parameters "@${PARAMS_FILE}" \
                 adminPassword="$admin_password" \
    --output none 2>&1) && deploy_rc=0 || deploy_rc=$?

  if [[ $deploy_rc -eq 0 ]]; then
    deploy_success=true
  elif echo "$deploy_out" | grep -qiE 'SkuNotAvailable|Capacity'; then
    # VM SKU unavailable — try the next candidate.
    sku_retry_idx=$((sku_retry_idx + 1))
    if [[ $sku_retry_idx -ge ${#VM_SKU_CANDIDATES[@]} ]]; then
      echo "ERROR: All VM SKU candidates exhausted. Tried: ${VM_SKU_CANDIDATES[*]}"
      exit 1
    fi
    log "  [SKU-RETRY] SkuNotAvailable/Capacity — retrying with ${VM_SKU_CANDIDATES[$sku_retry_idx]}..."
  else
    # Non-SKU failure: surface the error and abort.
    echo "$deploy_out"
    echo "ERROR: Deployment failed (not a SKU availability error)."
    exit 1
  fi
done
log "  Bicep deployment complete."

# ---------- Phase 7: Compute hub/spoke/fw names from naming convention ------
declare -a hub_names spoke_names fw_names
for i in $(seq 1 "$num_hubs"); do
  hub_names[$((i-1))]="${labPrefix}-vhub${i}"
  spoke_names[$((i-1))]="${labPrefix}-spoke${i}"
  fw_names[$((i-1))]="${labPrefix}-vhub${i}-azfw"
done

# ---------- Phase 8: Poll hub provisioningState + verify routingPreference --
echo ""
log "### Phase 8: Waiting for all vHubs to reach provisioningState=Succeeded ###"
p8_iter=0; p8_max=40   # 40 × 15 s = 10 min
while true; do
  p8_iter=$((p8_iter + 1))
  if [[ $p8_iter -gt $p8_max ]]; then
    log "  WARNING: hub provisioningState poll timed out after $p8_max iterations — continuing."
    break
  fi
  all_ok=true
  for i in $(seq 1 "$num_hubs"); do
    hub="${hub_names[$((i-1))]}"
    state=$(az network vhub show -g "$rg" -n "$hub" --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
    log "  $hub = $state"
    [[ "$state" != "Succeeded" ]] && all_ok=false
  done
  [[ "$all_ok" == "true" ]] && break
  sleep 15
done

echo "  Verifying hubRoutingPreference=ExpressRoute on all hubs..."
for i in $(seq 1 "$num_hubs"); do
  hub="${hub_names[$((i-1))]}"
  hrp=$(az network vhub show -g "$rg" -n "$hub" --query hubRoutingPreference -o tsv 2>/dev/null)
  if [[ "$hrp" != "ExpressRoute" ]]; then
    echo "  $hub: hubRoutingPreference=$hrp — applying fallback update..."
    az network vhub update -g "$rg" -n "$hub" --hub-routing-preference ExpressRoute --output none
    echo "  $hub updated to ExpressRoute."
  else
    echo "  $hub: hubRoutingPreference=$hrp ✔"
  fi
done

log "  Waiting for routingState=Provisioned on all hubs..."
for i in $(seq 1 "$num_hubs"); do
  hub="${hub_names[$((i-1))]}"
  rt_iter=0; rt_max=36   # 36 × 10 s = 6 min
  while true; do
    rt_iter=$((rt_iter + 1))
    if [[ $rt_iter -gt $rt_max ]]; then
      log "  WARNING: routingState poll timed out for $hub after $rt_max iterations — continuing."
      break
    fi
    rtState=$(az network vhub show -g "$rg" -n "$hub" --query routingState -o tsv 2>/dev/null || echo "Unknown")
    log "  $hub routingState=$rtState"
    [[ "$rtState" == "Provisioned" ]] && break
    sleep 10
  done
done

# ---------- Phase 9: Create spoke → hub VNet connections --------------------
echo ""
log "### Phase 9: Creating spoke VNet connections ###"
# Enable Propagate Default Route (internetSecurity) when Routing Intent injects 0.0.0.0/0.
isec=""; [[ "$ri_mode" == "internetOnly" || "$ri_mode" == "both" ]] && isec="--internet-security true"
for i in $(seq 1 "$num_hubs"); do
  hub="${hub_names[$((i-1))]}"
  spoke="${spoke_names[$((i-1))]}"
  echo "  Connecting $spoke → $hub (--no-wait)..."
  az network vhub connection create \
    -n "${spoke}-conn" \
    --remote-vnet "$spoke" \
    -g "$rg" \
    --vhub-name "$hub" \
    $isec \
    --no-wait --output none
done

echo "  Waiting for all spoke connections to Succeed..."
p9_iter=0; p9_max=40   # 40 × 30 s = 20 min
while true; do
  p9_iter=$((p9_iter + 1))
  if [[ $p9_iter -gt $p9_max ]]; then
    log "  WARNING: spoke-connection poll timed out after $p9_max iterations — continuing."
    break
  fi
  all_ok=true
  for i in $(seq 1 "$num_hubs"); do
    hub="${hub_names[$((i-1))]}"
    spoke="${spoke_names[$((i-1))]}"
    state=$(az network vhub connection show -n "${spoke}-conn" \
      --vhub-name "$hub" -g "$rg" --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
    log "  ${spoke}-conn = $state"
    [[ "$state" != "Succeeded" ]] && all_ok=false
  done
  [[ "$all_ok" == "true" ]] && break
  sleep 30
done

# ---------- Phase 10: ER circuits -------------------------------------------
if [[ "$num_er_circuits" -gt 0 ]]; then
  echo ""
  echo "### Phase 10: Creating ExpressRoute circuits early ###"
  declare -a er_create_pids
  for n in $(seq 1 "$num_er_circuits"); do
    idx=$((n - 1))
    er_name="${er_names[$idx]}"
    er_region="${er_regions[$idx]}"
    er_perloc="${er_perlocs[$idx]}"
    echo "  Creating $er_name ($er_perloc, $er_region) --no-wait..."
    az network express-route create \
      --bandwidth "$er_bandwidth" \
      -n "$er_name" \
      --peering-location "$er_perloc" \
      -g "$rg" \
      --provider "$er_provider" \
      -l "$er_region" \
      --sku-family "$er_family" \
      --sku-tier "$er_sku" \
      -o none &
    er_create_pids[$idx]=$!
  done
  for pid in "${er_create_pids[@]}"; do wait "$pid"; done

  echo ""
  echo "######################################################################"
  echo "#         ExpressRoute Service Keys — hand these to the provider     #"
  echo "######################################################################"
  for n in $(seq 1 "$num_er_circuits"); do
    idx=$((n - 1))
    er_name="${er_names[$idx]}"
    er_perloc="${er_perlocs[$idx]}"
    svc_key=$(az network express-route show -g "$rg" -n "$er_name" --query serviceKey -o tsv)
    echo ""
    echo "  Circuit     : $er_name  (Provider: $er_provider / Location: $er_perloc)"
    echo "  Service Key : $svc_key"
  done
  echo ""
  echo "  ➤ Log in to the provider portal and place orders using the keys above."
  echo "  ➤ Script continues Azure work, then polls circuits for Provisioned state."
  echo "  ➤ Provider provisioning typically takes hours to days."
  echo ""
  read -r -p "Press ENTER once you have submitted the orders to ${er_provider}..."

  # Poll + connect each circuit after provisioned
  max_er_secs=$((MAX_WAIT_MIN * 60))
  for n in $(seq 1 "$num_er_circuits"); do
    idx=$((n - 1))
    er_name="${er_names[$idx]}"
    echo ""
    echo "  Polling $er_name (max ${MAX_WAIT_MIN} min)..."
    er_poll_start=$(date +%s)
    while true; do
      elapsed=$(( $(date +%s) - er_poll_start ))
      if (( elapsed > max_er_secs )); then
        echo "ERROR: Timeout after ${MAX_WAIT_MIN} min waiting for $er_name to be Provisioned."
        echo "  Re-run the ER connection steps manually once the provider confirms."
        exit 1
      fi
      state=$(az network express-route show -g "$rg" -n "$er_name" \
        --query serviceProviderProvisioningState -o tsv 2>/dev/null || echo "Unknown")
      echo "  $er_name: $state  (elapsed: $((elapsed/60))m / ${MAX_WAIT_MIN}m)"
      [[ "$state" == "Provisioned" ]] && break
      sleep 30
    done
    echo "  $er_name is Provisioned ✔"

    # Prompt which hub to connect this circuit to
    echo ""
    echo "  Available hubs:"
    for i in $(seq 1 "$num_hubs"); do
      echo "    $i) ${hub_names[$((i-1))]} (${hub_regions[$((i-1))]})"
    done
    read -r -p "  Connect $er_name to which hub number? [1]: " hub_choice
    hub_choice="${hub_choice:-1}"
    hi=$((hub_choice - 1))
    target_hub="${hub_names[$hi]}"
    target_region="${hub_regions[$hi]}"
    ergw_name="${target_hub}-ergw"

    # Ensure ER gateway exists on the target hub
    ergw_state=$(az network express-route gateway show -g "$rg" -n "$ergw_name" \
      --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
    if [[ "$ergw_state" != "Succeeded" ]]; then
      echo "  Creating ER gateway $ergw_name in $target_hub ($target_region)..."
      az network express-route gateway create \
        -g "$rg" -n "$ergw_name" \
        --location "$target_region" \
        --min-val 1 \
        --virtual-hub "$target_hub" \
        -o none
      ergw_iter=0; ergw_max=40   # 40 × 15 s = 10 min
      while true; do
        ergw_iter=$((ergw_iter + 1))
        if [[ $ergw_iter -gt $ergw_max ]]; then
          log "  WARNING: ER-gateway poll timed out for $ergw_name after $ergw_max iterations — continuing."
          break
        fi
        ergw_state=$(az network express-route gateway show -g "$rg" -n "$ergw_name" \
          --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
        log "  $ergw_name = $ergw_state"
        [[ "$ergw_state" == "Succeeded" ]] && break
        sleep 15
      done
    else
      echo "  ER gateway $ergw_name already Succeeded ✔"
    fi

    # Create the ER gateway connection
    peering=$(az network express-route show -g "$rg" -n "$er_name" \
      --query 'peerings[0].id' -o tsv)
    rtid=$(az network vhub route-table show \
      --name defaultRouteTable \
      --vhub-name "$target_hub" \
      -g "$rg" \
      --query id -o tsv)
    conn_name="${target_hub}-conn-to-${er_name}"
    echo "  Creating ER gateway connection: $conn_name..."
    az network express-route gateway connection create \
      --name "$conn_name" \
      -g "$rg" \
      --gateway-name "$ergw_name" \
      --peering "$peering" \
      --associated-route-table "$rtid" \
      --propagated-route-tables "$rtid" \
      --labels default \
      -o none

    er_conn_iter=0; er_conn_max=40   # 40 × 30 s = 20 min
    while true; do
      er_conn_iter=$((er_conn_iter + 1))
      if [[ $er_conn_iter -gt $er_conn_max ]]; then
        log "  WARNING: ER-connection poll timed out for $conn_name after $er_conn_max iterations — continuing."
        break
      fi
      conn_state=$(az network express-route gateway connection show \
        --name "$conn_name" \
        -g "$rg" \
        --gateway-name "$ergw_name" \
        --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
      log "  $conn_name = $conn_state"
      [[ "$conn_state" == "Succeeded" ]] && break
      sleep 30
    done
    echo "  ER connection $conn_name Succeeded ✔"
  done
fi

# ---------- Phase 11: Wait for firewalls then create Routing Intent ---------
echo ""
log "### Phase 11: Waiting for all Azure Firewalls to Succeed ###"
p11_iter=0; p11_max=80   # 80 × 15 s = 20 min
while true; do
  p11_iter=$((p11_iter + 1))
  if [[ $p11_iter -gt $p11_max ]]; then
    log "  WARNING: firewall poll timed out after $p11_max iterations — continuing."
    break
  fi
  all_ok=true
  for i in $(seq 1 "$num_hubs"); do
    fw="${fw_names[$((i-1))]}"
    state=$(az network firewall show -g "$rg" -n "$fw" --query provisioningState -o tsv 2>/dev/null || echo "NotFound")
    log "  $fw = $state"
    [[ "$state" != "Succeeded" ]] && all_ok=false
  done
  [[ "$all_ok" == "true" ]] && break
  sleep 15
done

# Build routing policy JSON based on mode
build_ri_policies() {
  local fwid="$1" mode="$2"
  case "$mode" in
    privateOnly)
      echo "[{\"name\":\"PrivateTraffic\",\"destinations\":[\"PrivateTraffic\"],\"nextHop\":\"${fwid}\"}]" ;;
    internetOnly)
      echo "[{\"name\":\"InternetTraffic\",\"destinations\":[\"Internet\"],\"nextHop\":\"${fwid}\"}]" ;;
    both)
      echo "[{\"name\":\"PrivateTraffic\",\"destinations\":[\"PrivateTraffic\"],\"nextHop\":\"${fwid}\"},{\"name\":\"InternetTraffic\",\"destinations\":[\"Internet\"],\"nextHop\":\"${fwid}\"}]" ;;
  esac
}

echo ""
log "### Phase 12: Creating Routing Intent (mode: ${ri_mode}) on all hubs ###"
declare -a ri_pids
for i in $(seq 1 "$num_hubs"); do
  hub="${hub_names[$((i-1))]}"
  fw="${fw_names[$((i-1))]}"
  ri_name="${hub}-ri"
  fwid=$(az network firewall show -g "$rg" -n "$fw" --query id -o tsv)
  policies=$(build_ri_policies "$fwid" "$ri_mode")
  log "  Creating $ri_name (nextHop → $fw)..."
  # BUG FIX: routing-intent subcommands use --vhub (not --vhub-name)
  az network vhub routing-intent create \
    -g "$rg" \
    --vhub "$hub" \
    -n "$ri_name" \
    --routing-policies "$policies" \
    --output none &
  ri_pids[$((i-1))]=$!
done
for pid in "${ri_pids[@]}"; do wait "$pid"; done

log "  Polling Routing Intent provisioningState..."
p12_iter=0; p12_max=20   # 20 × 15 s = 5 min; empty/error status counts toward limit
while true; do
  p12_iter=$((p12_iter + 1))
  if [[ $p12_iter -gt $p12_max ]]; then
    log "  WARNING: Routing Intent poll timed out after $p12_max iterations — continuing."
    break
  fi
  all_ok=true
  for i in $(seq 1 "$num_hubs"); do
    hub="${hub_names[$((i-1))]}"
    ri_name="${hub}-ri"
    # BUG FIX: routing-intent subcommands use --vhub (not --vhub-name)
    state=$(az network vhub routing-intent show \
      -g "$rg" --vhub "$hub" -n "$ri_name" \
      --query provisioningState -o tsv 2>/dev/null || echo "Unknown")
    [[ -z "$state" ]] && state="Unknown"
    log "  $ri_name = $state"
    [[ "$state" != "Succeeded" ]] && all_ok=false
  done
  [[ "$all_ok" == "true" ]] && break
  sleep 15
done

# ---------- Phase 13: Summary -----------------------------------------------
deploy_end=$(date +%s)
echo ""
log "######################################################################"
log "#                    DEPLOYMENT COMPLETE                             #"
log "######################################################################"
echo ""
echo "  Lab prefix       : $labPrefix"
echo "  Resource group   : $rg"
echo "  Key Vault        : $kv_name"
echo "  Routing Intent   : $ri_mode (on all hubs)"
echo "  Total duration   : $(( (deploy_end - deploy_start) / 60 )) min"
echo ""
echo "=== Hub Summary ==="
for i in $(seq 1 "$num_hubs"); do
  idx=$((i - 1))
  hub="${hub_names[$idx]}"
  fw="${fw_names[$idx]}"
  spoke="${spoke_names[$idx]}"
  fwip=$(az network firewall show -g "$rg" -n "$fw" \
    --query 'hubIPAddresses.privateIPAddress' -o tsv 2>/dev/null || echo "N/A")
  echo "  Hub $i: $hub | FW: $fw ($fwip) | Spoke: $spoke"
done

echo ""
echo "=== VM Private IPs ==="
for nic in $(az network nic list -g "$rg" --query '[].name' -o tsv 2>/dev/null); do
  pip=$(az network nic show -g "$rg" -n "$nic" \
    --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>/dev/null || echo "N/A")
  echo "  $nic: $pip"
done

echo ""
echo "=== VM Credentials (stored in Key Vault) ==="
echo "  Authentication : username + password (no SSH key required)"
echo "  Key Vault      : $kv_name"
echo "  Retrieve username:"
echo "    az keyvault secret show --vault-name $kv_name --name vm-admin-username --query value -o tsv"
echo "  Retrieve password:"
echo "    az keyvault secret show --vault-name $kv_name --name vm-admin-password --query value -o tsv"
echo "  Access via Azure Serial Console or VM-to-VM SSH with the password."

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  ⚠️  REMINDER: Firewall policy has a LAB-ONLY allow-all rule.   ║"
echo "║  ⚠️  All hubs use Route Preference = ExpressRoute.               ║"
echo "║  ⚠️  Run cleanup.sh / cleanup.ps1 when the lab is done.          ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
