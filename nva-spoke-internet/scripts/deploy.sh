#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Main orchestration for the nva-spoke-internet lab.
#
# Deploys:
#   Virtual WAN hub + Spoke1 + Spoke2 + DMZ VNets
#   Two active/active NVAs (Public LB for egress, HA-ports ILB for east-west)
#   Post-deploy vHub routing: conn-dmz static 0/0→ILB, defaultRouteTable 0/0→conn-dmz
#   Optional: on-prem S2S VPN (BGP-over-IPsec, strongSwan + FRR)
#
# Usage: ./deploy.sh [--yes]   (--yes skips DEPLOY_ONPREM prompt, defaults to N)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/../bicep"

source "${SCRIPT_DIR}/functions.sh"

DEPLOY_NAME="nva-spoke-internet-deploy"

# =============================================================================
# Phase 1 — Prerequisite check
# =============================================================================
log "=== Phase 1: Checking prerequisites ==="

for tool in az jq openssl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: $tool"
    echo "  Install: az=Azure CLI | jq=https://stedolan.github.io/jq/ | openssl (built into most distros)"
    exit 1
  fi
done

if ! az account show --output none 2>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run: az login"
  exit 1
fi

CURRENT_SUB=$(az account show --query '[name,id]' -o tsv | tr '\t' ' / ')
log "  Logged in — subscription: $CURRENT_SUB"

# =============================================================================
# Phase 2 — Prompts
# =============================================================================
log "=== Phase 2: Parameters ==="

ask_default() {
  local var_name="$1" prompt="$2" default="$3"
  read -r -p "  ${prompt} [${default}]: " _inp
  printf -v "$var_name" '%s' "${_inp:-$default}"
}

ask_default LOCATION    "Azure region"       "eastus"
ask_default RG          "Resource group name" "rg-nva-spoke-internet"
ask_default ADMIN_USERNAME "Admin username"  "azureuser"

# Secure password prompt with confirmation
while true; do
  read -r -s -p "  Admin password (min 12 chars, complexity required): " ADMIN_PASSWORD
  echo ""
  read -r -s -p "  Confirm password: " ADMIN_PASSWORD2
  echo ""
  if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD2" ]]; then
    echo "  Passwords do not match — try again."
  elif [[ ${#ADMIN_PASSWORD} -lt 12 ]]; then
    echo "  Password is too short (minimum 12 characters) — try again."
  else
    break
  fi
done

ask_default DEPLOY_ONPREM "Deploy on-prem simulation? (y/N)" "N"
DEPLOY_ONPREM="${DEPLOY_ONPREM,,}"   # lower-case

log ""
log "  Location       : $LOCATION"
log "  Resource group : $RG"
log "  Admin username : $ADMIN_USERNAME"
log "  On-prem deploy : $DEPLOY_ONPREM"
log ""

# =============================================================================
# Phase 3 — VM SKU selection + capacity preflight
# =============================================================================
log "=== Phase 3: VM SKU selection ==="

pick_vm_sku "$LOCATION" CANDIDATE_SKU
log "  list-skus candidate: $CANDIDATE_SKU"
log "  Running capacity pre-flight in $LOCATION (this may take ~2 min) ..."

if ! preflight_vm_capacity "$LOCATION" "$CANDIDATE_SKU" VM_SIZE; then
  # preflight_vm_capacity already printed a detailed failure message + region suggestions
  exit 1
fi
log "  ✔ VM_SIZE resolved: $VM_SIZE"

# =============================================================================
# Phase 4 — Create resource group
# =============================================================================
log "=== Phase 4: Creating resource group '$RG' ==="
az group create -n "$RG" -l "$LOCATION" --output none
log "  ✔ Resource group ready."

# =============================================================================
# Phase 5 — Generate PSK (if on-prem)
# =============================================================================
VPN_SHARED_KEY=""
if [[ "$DEPLOY_ONPREM" == "y" ]]; then
  log "=== Phase 5: Generating VPN PSK ==="
  VPN_SHARED_KEY="$(openssl rand -hex 24)"
  log "  ✔ PSK generated (hex-48, stored only in this shell session)."
fi

# =============================================================================
# Phase 6 — Bicep deployment
# =============================================================================
log "=== Phase 6: Deploying Bicep template '$DEPLOY_NAME' ==="
log "  This will take 20-40 minutes (vWAN hub + VPN gateway provisioning) ..."

DEPLOY_ONPREM_PARAM="false"
[[ "$DEPLOY_ONPREM" == "y" ]] && DEPLOY_ONPREM_PARAM="true"

az deployment group create \
  -g "$RG" \
  -f "${BICEP_DIR}/main.bicep" \
  -n "$DEPLOY_NAME" \
  --parameters \
    location="$LOCATION" \
    adminUsername="$ADMIN_USERNAME" \
    adminPassword="$ADMIN_PASSWORD" \
    vmSize="$VM_SIZE" \
    deployOnPrem="$DEPLOY_ONPREM_PARAM" \
    onpremBgpAsn=65001 \
  --output none

log "  ✔ Bicep deployment complete."

# =============================================================================
# Phase 7 — Read deployment outputs
# =============================================================================
log "=== Phase 7: Reading deployment outputs ==="

OUTPUTS=$(az deployment group show \
  -g "$RG" -n "$DEPLOY_NAME" \
  --query "properties.outputs" -o json)

# Helper: extract a named output value
get_output() { echo "$OUTPUTS" | jq -r ".[\"$1\"].value // empty"; }

LOCATION_OUT="$(get_output location)"
VWAN_NAME="$(get_output vwanName)"
HUB="$(get_output hubName)"
HUB_ID="$(get_output hubId)"
DMZ_VNET_ID="$(get_output dmzVnetId)"
SPOKE1_VNET_ID="$(get_output spoke1VnetId)"
SPOKE2_VNET_ID="$(get_output spoke2VnetId)"
ILB_FRONTEND_IP="$(get_output ilbFrontendIp)"
PUBLIC_LB_PIP="$(get_output publicLbPublicIp)"
VPN_GW_NAME="$(get_output vpnGatewayName)"
ONPREM_NVA_PIP="$(get_output onpremNvaPublicIp)"
ONPREM_NVA_PRIVATE_IP="$(get_output onpremNvaPrivateIp)"
ONPREM_NVA_NAME="$(get_output onpremNvaName)"
ONPREM_VM_NAME="$(get_output onpremVmName)"

# defaultRouteTable resource ID — derived from the already-fetched HUB_ID output
DEFAULT_RT_ID="${HUB_ID}/hubRouteTables/defaultRouteTable"

log "  Hub             : $HUB"
log "  VWAN            : $VWAN_NAME"
log "  DMZ VNet        : $DMZ_VNET_ID"
log "  Spoke1 VNet     : $SPOKE1_VNET_ID"
log "  Spoke2 VNet     : $SPOKE2_VNET_ID"
log "  ILB frontend    : $ILB_FRONTEND_IP"
log "  Public LB PIP   : $PUBLIC_LB_PIP"
[[ -n "$VPN_GW_NAME" ]] && log "  VPN GW          : $VPN_GW_NAME"
[[ -n "$ONPREM_NVA_PIP" ]] && log "  On-prem NVA PIP : $ONPREM_NVA_PIP"
[[ -n "$ONPREM_NVA_PRIVATE_IP" ]] && log "  On-prem NVA priv: $ONPREM_NVA_PRIVATE_IP"

# Guard: ILB frontend must match expected value
if [[ "$ILB_FRONTEND_IP" != "10.0.0.68" ]]; then
  echo "  WARNING: ILB frontend IP from outputs is '$ILB_FRONTEND_IP', expected '10.0.0.68'."
  echo "           Review Naomi's Bicep output.  Continuing with actual value."
fi

# =============================================================================
# Phase 8 — Wait for hub routingState = Provisioned
# =============================================================================
log "=== Phase 8: Waiting for hub '$HUB' to reach routingState=Provisioned ==="
# Max 60 iterations × 10s = 10 minutes.
poll_until "Hub routingState" "Provisioned" 10 60 \
  az network vhub show -g "$RG" -n "$HUB" --query "routingState" -o tsv
log "  ✔ Hub is Provisioned."

# =============================================================================
# Phase 9 — Create hub VNet connections
# =============================================================================
log "=== Phase 9: Creating hub VNet connections ==="

# conn-dmz: includes static route 0.0.0.0/0 → ILB frontend 10.0.0.68
# This route tells the hub: for 0/0 packets arriving from other connections and
# destined for routing through DMZ, forward to the ILB (which load-balances
# across NVA instances on the HA-ports backend pool).
log "  Creating conn-dmz (with static 0/0 → $ILB_FRONTEND_IP) ..."
az network vhub connection create \
  -g "$RG" --vhub-name "$HUB" -n "conn-dmz" \
  --remote-vnet "$DMZ_VNET_ID" \
  --associated-route-table "$DEFAULT_RT_ID" \
  --propagated-route-tables "$DEFAULT_RT_ID" \
  --labels "default" \
  --route-name "default-via-ilb" \
  --address-prefixes "0.0.0.0/0" \
  --next-hop "$ILB_FRONTEND_IP" \
  --output none

log "  Polling conn-dmz provisioningState ..."
poll_until "conn-dmz provisioningState" "Succeeded" 15 40 \
  az network vhub connection show -g "$RG" --vhub-name "$HUB" -n "conn-dmz" \
    --query "provisioningState" -o tsv

# conn-spoke1
log "  Creating conn-spoke1 ..."
az network vhub connection create \
  -g "$RG" --vhub-name "$HUB" -n "conn-spoke1" \
  --remote-vnet "$SPOKE1_VNET_ID" \
  --associated-route-table "$DEFAULT_RT_ID" \
  --propagated-route-tables "$DEFAULT_RT_ID" \
  --labels "default" \
  --output none

poll_until "conn-spoke1 provisioningState" "Succeeded" 15 40 \
  az network vhub connection show -g "$RG" --vhub-name "$HUB" -n "conn-spoke1" \
    --query "provisioningState" -o tsv

# conn-spoke2
log "  Creating conn-spoke2 ..."
az network vhub connection create \
  -g "$RG" --vhub-name "$HUB" -n "conn-spoke2" \
  --remote-vnet "$SPOKE2_VNET_ID" \
  --associated-route-table "$DEFAULT_RT_ID" \
  --propagated-route-tables "$DEFAULT_RT_ID" \
  --labels "default" \
  --output none

poll_until "conn-spoke2 provisioningState" "Succeeded" 15 40 \
  az network vhub connection show -g "$RG" --vhub-name "$HUB" -n "conn-spoke2" \
    --query "provisioningState" -o tsv

log "  ✔ All three hub VNet connections are Succeeded."

# =============================================================================
# Phase 10+11 — defaultRouteTable: add 0.0.0.0/0 → conn-dmz
# =============================================================================
log "=== Phase 10+11: Adding 0/0 route to hub defaultRouteTable ==="

CONN_DMZ_ID=$(az network vhub connection show \
  -g "$RG" --vhub-name "$HUB" -n "conn-dmz" \
  --query "id" -o tsv)

# This causes Spoke1 and Spoke2 (which are associated to defaultRouteTable)
# to learn 0.0.0.0/0 pointing at conn-dmz.  The conn-dmz static route
# (set in Phase 9) then steers 0/0 to the ILB frontend 10.0.0.68, which
# load-balances across NVA instances.  NVAs SNAT and forward via the Public LB.
#
# NOTE: `az network vhub route-table route add` appends a route to the named
# route table.  The defaultRouteTable already exists (created by the hub);
# we just add our static entry.  If the hub was deployed with Routing Intent
# you would use `az network vhub routing-intent` instead, but this lab does NOT
# use Routing Intent (custom NVA, not Azure Firewall).
log "  conn-dmz ID: $CONN_DMZ_ID"
log "  Adding defaultRouteTable route: 0.0.0.0/0 → conn-dmz ..."

az network vhub route-table route add \
  -g "$RG" --vhub-name "$HUB" --name "defaultRouteTable" \
  --route-name "to-internet" \
  --destination-type "CIDR" --destinations "0.0.0.0/0" \
  --next-hop-type "ResourceID" --next-hop "$CONN_DMZ_ID" \
  --output none

log "  ✔ defaultRouteTable 0.0.0.0/0 → conn-dmz route installed."
log "  NET RESULT: Spoke1/Spoke2 effective routes will include 0.0.0.0/0 → DMZ → ILB → NVA → SNAT."

# =============================================================================
# Phase 12 — On-prem VPN (conditional)
# =============================================================================
if [[ "$DEPLOY_ONPREM" == "y" ]]; then
  log "=== Phase 12: On-prem VPN site + connection ==="

  # a) Create vWAN VPN site for on-prem
  log "  Creating VPN site 'onprem-vpnsite' ..."
  az network vpn-site create \
    -g "$RG" -n "onprem-vpnsite" \
    -l "$LOCATION" \
    --virtual-wan "$VWAN_NAME" \
    --ip-address "$ONPREM_NVA_PIP" \
    --asn 65001 \
    --bgp-peering-address "$ONPREM_NVA_PRIVATE_IP" \
    --address-prefixes "192.168.100.0/24" \
    --link-name "onprem-link" \
    --output none
  log "  ✔ VPN site created."

  # b) Create S2S VPN connection on the hub VPN gateway
  # Two-step pattern: create the connection, then set the PSK on the link (index 0).
  # The PSK cannot be set at create time via `az network vpn-gateway connection create`
  # with link-based connections in current az CLI — the sharedkey update is required.
  log "  Creating VPN gateway connection 'conn-onprem' (BGP enabled) ..."
  az network vpn-gateway connection create \
    -g "$RG" --gateway-name "$VPN_GW_NAME" -n "conn-onprem" \
    --vpn-site "onprem-vpnsite" \
    --enable-bgp true \
    --vpn-site-link "onprem-link" \
    --output none

  log "  Setting PSK on link index 0 ..."
  # `az network vpn-gateway connection vpn-site-link-conn sharedkey update`
  # is the current az CLI command to set the PSK on a specific link (by index).
  az network vpn-gateway connection vpn-site-link-conn sharedkey update \
    -g "$RG" --gateway-name "$VPN_GW_NAME" \
    --connection-name "conn-onprem" \
    --index 0 \
    --value "$VPN_SHARED_KEY" \
    --output none

  log "  Polling conn-onprem provisioningState ..."
  poll_until "conn-onprem provisioningState" "Succeeded" 20 60 \
    az network vpn-gateway connection show \
      -g "$RG" --gateway-name "$VPN_GW_NAME" -n "conn-onprem" \
      --query "provisioningState" -o tsv

  log "  ✔ VPN connection provisioned."

  # c) Fetch hub GW public IPs + BGP peer IPs
  log "  Fetching hub VPN gateway instance IPs and BGP peer IPs ..."
  HUB_GW_PIP0=$(az network vpn-gateway show \
    -g "$RG" -n "$VPN_GW_NAME" \
    --query "ipConfigurations[0].publicIpAddress" -o tsv)
  HUB_GW_PIP1=$(az network vpn-gateway show \
    -g "$RG" -n "$VPN_GW_NAME" \
    --query "ipConfigurations[1].publicIpAddress" -o tsv)
  HUB_BGP_PEER0=$(az network vpn-gateway show \
    -g "$RG" -n "$VPN_GW_NAME" \
    --query "bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]" -o tsv)
  HUB_BGP_PEER1=$(az network vpn-gateway show \
    -g "$RG" -n "$VPN_GW_NAME" \
    --query "bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]" -o tsv)

  log "  Hub GW PIP0     : $HUB_GW_PIP0"
  log "  Hub GW PIP1     : $HUB_GW_PIP1"
  log "  Hub BGP peer0   : $HUB_BGP_PEER0"
  log "  Hub BGP peer1   : $HUB_BGP_PEER1"

  # d) Configure on-prem NVA (strongSwan + FRR)
  log "  Calling configure-onprem.sh ..."
  bash "${SCRIPT_DIR}/configure-onprem.sh" \
    "$ONPREM_NVA_NAME" "$RG" \
    "$HUB_GW_PIP0" "$HUB_GW_PIP1" \
    "$HUB_BGP_PEER0" "$HUB_BGP_PEER1" \
    "65515" "65001" "$ONPREM_NVA_PRIVATE_IP" "$VPN_SHARED_KEY"
fi

# =============================================================================
# Phase 13 — Validation summary
# =============================================================================
log ""
log "╔══════════════════════════════════════════════════════════════════════╗"
log "║                   DEPLOYMENT COMPLETE — VALIDATION                   ║"
log "╚══════════════════════════════════════════════════════════════════════╝"
log ""
log "  Resource group  : $RG"
log "  Hub             : $HUB  (routingState: Provisioned)"
log "  Public LB PIP   : $PUBLIC_LB_PIP   ← egress SNAT IP for spoke VMs"
log "  ILB frontend    : $ILB_FRONTEND_IP ← hub 0/0 next hop"
log ""
log "  ROUTING VERIFICATION:"
log "  ─────────────────────────────────────────────────────────────────────"
log "  # Check Spoke1 VM effective routes (replace <nic-name>):"
echo "  az network nic show-effective-route-table -g $RG --name <spoke1-nic-name> -o table | grep '0.0.0.0/0'"
log ""
log "  # Check defaultRouteTable routes:"
echo "  az network vhub route-table show -g $RG --vhub-name $HUB --name defaultRouteTable --query 'routes' -o table"
log ""
log "  EGRESS TEST (run from Spoke1 or Spoke2 VM via serial console):"
log "  ─────────────────────────────────────────────────────────────────────"
log "  # Serial console: Azure portal → VM → Serial console"
echo "  curl -s --max-time 10 https://ifconfig.me"
log "  # Expected: public IP matching the Public LB PIP = $PUBLIC_LB_PIP"
log ""

if [[ "$DEPLOY_ONPREM" == "y" ]]; then
  log "  ON-PREM TUNNEL VERIFICATION:"
  log "  ─────────────────────────────────────────────────────────────────────"
  log "  # Check VPN connection state:"
  echo "  az network vpn-gateway connection show -g $RG --gateway-name $VPN_GW_NAME -n conn-onprem --query 'connectionStatus' -o tsv"
  log ""
  log "  # From on-prem NVA (serial console or az vm run-command):"
  log "  # IPsec tunnels:"
  echo "  az vm run-command invoke -g $RG --name $ONPREM_NVA_NAME --command-id RunShellScript --scripts 'ipsec status | grep ESTABLISHED'"
  log ""
  log "  # BGP session:"
  echo "  az vm run-command invoke -g $RG --name $ONPREM_NVA_NAME --command-id RunShellScript --scripts \"vtysh -c 'show bgp summary'\""
  log ""
  log "  # Ping from on-prem VM → spoke1 VM private IP:"
  echo "  az vm run-command invoke -g $RG --name $ONPREM_VM_NAME --command-id RunShellScript --scripts 'ping -c 4 10.1.0.4'"
  log ""
fi

log "  CLEANUP:"
echo "  bash ${SCRIPT_DIR}/cleanup.sh --rg $RG"
log ""
