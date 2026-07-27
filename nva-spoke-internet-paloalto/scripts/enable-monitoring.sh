#!/usr/bin/env bash
# =============================================================================
# enable-monitoring.sh — OPTIONAL monitoring stack for nva-spoke-internet
#
# Provisions the additional logging/monitoring resources required to analyse
# traffic flow through the DMZ NVAs with Traffic Analytics and LB metrics.
# This script is SEPARATE from the core lab deployment (deploy.sh) because
# these resources are optional and incur ongoing cost.
#
# IDEMPOTENT: resources that already exist are skipped.
#
# What this creates (all in the lab resource group + region):
#   1. Log Analytics workspace  (log-nva-spoke-internet)
#   2. Storage account          (stnvaspk<sub-8-chars>, Standard_LRS)
#   3. Network Watcher          (NetworkWatcher_<region>, in NetworkWatcherRG)
#   4. VNet flow logs           (flow-vnet-dmz, flow-vnet-spoke1, flow-vnet-spoke2)
#      -- VNet flow logs, NOT NSG flow logs (NSG flow logs retire 2027-09-30;
#         new NSG flow logs blocked after 2025-06-30)
#   5. LB diagnostic settings   (diag-lb-public, diag-lb-ilb -> workspace AllMetrics)
#
# Usage:
#   ./scripts/enable-monitoring.sh
#   RESOURCE_GROUP=my-rg ./scripts/enable-monitoring.sh
#
# References (authoritative):
#   VNet flow logs overview:   https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
#   Manage VNet flow logs:     https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
#   NSG flow log migration:    https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
#   Traffic Analytics:         https://learn.microsoft.com/azure/network-watcher/traffic-analytics
#   LB diagnostic settings:    https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/functions.sh"

RG="${RESOURCE_GROUP:-rg-nva-spoke-internet-pa}"

LA_NAME="log-nva-spoke-internet"
NW_RG="NetworkWatcherRG"

# ---- Idempotent resource helpers --------------------------------------------
resource_exists() {
  # Usage: resource_exists <az show command and args>
  "$@" --output none 2>/dev/null
}

# =============================================================================
# Phase 1 -- Pre-checks
# =============================================================================
log "=== Phase 1: Pre-checks ==="

if ! az account show --output none 2>/dev/null; then
  echo "ERROR: Not logged in to Azure. Run: az login"
  exit 1
fi

if ! az group show -n "$RG" --output none 2>/dev/null; then
  echo "ERROR: Resource group '$RG' not found. Deploy the lab first (deploy.sh)."
  exit 1
fi
log "  Resource group: $RG"

LOCATION=$(az group show -n "$RG" --query location -o tsv)
log "  Region: $LOCATION"

# Deterministic storage account name: prefix + first 8 chars of subscription ID (hex, no hyphens)
SUB_SHORT=$(az account show --query id -o tsv | tr -d '-' | cut -c1-8)
SA_NAME="stnvaspk${SUB_SHORT}"
log "  Storage account name: $SA_NAME"

# =============================================================================
# Phase 2 -- Log Analytics workspace
# =============================================================================
log ""
log "=== Phase 2: Log Analytics workspace '$LA_NAME' ==="
if az monitor log-analytics workspace show -g "$RG" -n "$LA_NAME" --output none 2>/dev/null; then
  log "  Workspace already exists -- skipping."
else
  log "  Creating workspace ..."
  az monitor log-analytics workspace create \
    -g "$RG" -n "$LA_NAME" -l "$LOCATION" \
    --retention-time 30 \
    --output none
  log "  Created."
fi

LA_ID=$(az monitor log-analytics workspace show \
  -g "$RG" -n "$LA_NAME" --query id -o tsv)
log "  Workspace ID: $LA_ID"

# =============================================================================
# Phase 3 -- Storage account for flow log blobs
# =============================================================================
log ""
log "=== Phase 3: Storage account '$SA_NAME' ==="
if az storage account show -n "$SA_NAME" -g "$RG" --output none 2>/dev/null; then
  log "  Storage account already exists -- skipping."
else
  log "  Creating storage account (Standard_LRS) ..."
  az storage account create \
    -n "$SA_NAME" -g "$RG" -l "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --output none
  log "  Created."
fi

SA_ID=$(az storage account show -n "$SA_NAME" -g "$RG" --query id -o tsv)
log "  Storage account ID: $SA_ID"

# =============================================================================
# Phase 4 -- Network Watcher
# =============================================================================
log ""
log "=== Phase 4: Network Watcher (NetworkWatcherRG / $LOCATION) ==="
NW_NAME="NetworkWatcher_${LOCATION}"
if az network watcher show -g "$NW_RG" -n "$NW_NAME" --output none 2>/dev/null; then
  log "  Network Watcher '$NW_NAME' already exists -- skipping."
else
  log "  Ensuring NetworkWatcherRG exists ..."
  az group create -n "$NW_RG" -l "$LOCATION" --output none 2>/dev/null || true
  log "  Creating Network Watcher for region '$LOCATION' ..."
  # az network watcher create --location creates NetworkWatcher_<location> in NetworkWatcherRG
  az network watcher create -l "$LOCATION" --output none
  log "  Created."
fi

# =============================================================================
# Phase 5 -- VNet flow logs (DMZ + Spoke1 + Spoke2)
# NOTE: Using VNet flow logs, NOT NSG flow logs.
#   NSG flow logs retire 2027-09-30; new NSG flow logs blocked after 2025-06-30.
#   Ref: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
#   Ref: https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
# =============================================================================
log ""
log "=== Phase 5: VNet flow logs (VNet flow logs, NOT NSG flow logs) ==="
log "  NSG flow logs are retiring 2027-09-30 and blocked for creation after 2025-06-30."
log "  Using VNet flow logs per https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate"

declare -A VNET_FLOW_LOGS
VNET_FLOW_LOGS["flow-vnet-dmz"]="vnet-dmz"
VNET_FLOW_LOGS["flow-vnet-spoke1"]="vnet-spoke1"
VNET_FLOW_LOGS["flow-vnet-spoke2"]="vnet-spoke2"

for FL_NAME in "${!VNET_FLOW_LOGS[@]}"; do
  VNET_NAME="${VNET_FLOW_LOGS[$FL_NAME]}"
  log ""
  log "  Flow log '$FL_NAME' for VNet '$VNET_NAME':"

  VNET_ID=$(az network vnet show -g "$RG" -n "$VNET_NAME" --query id -o tsv 2>/dev/null || true)
  if [[ -z "$VNET_ID" ]]; then
    log "  WARNING: VNet '$VNET_NAME' not found in '$RG' -- skipping."
    continue
  fi

  if az network watcher flow-log show -n "$FL_NAME" -g "$NW_RG" --output none 2>/dev/null; then
    log "    Already exists -- skipping."
  else
    log "    Creating (Traffic Analytics enabled) ..."
    az network watcher flow-log create \
      --name "$FL_NAME" \
      --vnet "$VNET_ID" \
      --storage-account "$SA_ID" \
      --workspace "$LA_ID" \
      --traffic-analytics true \
      --location "$LOCATION" \
      -g "$NW_RG" \
      --output none
    log "    Created."
  fi
done

# =============================================================================
# Phase 6 -- LB diagnostic settings (AllMetrics -> workspace)
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# =============================================================================
log ""
log "=== Phase 6: LB diagnostic settings -> Log Analytics workspace ==="
METRICS_JSON='[{"category":"AllMetrics","enabled":true}]'

for LB_NAME in lb-public lb-ilb; do
  log ""
  log "  LB '$LB_NAME':"
  LB_ID=$(az network lb show -g "$RG" -n "$LB_NAME" --query id -o tsv 2>/dev/null || true)
  if [[ -z "$LB_ID" ]]; then
    log "  WARNING: '$LB_NAME' not found in '$RG' -- skipping."
    continue
  fi

  DIAG_NAME="diag-${LB_NAME}"
  if az monitor diagnostic-settings show --resource "$LB_ID" -n "$DIAG_NAME" --output none 2>/dev/null; then
    log "    Diagnostic settings '$DIAG_NAME' already exist -- skipping."
  else
    log "    Creating diagnostic settings (AllMetrics) ..."
    az monitor diagnostic-settings create \
      --resource "$LB_ID" \
      -n "$DIAG_NAME" \
      --workspace "$LA_ID" \
      --metrics "$METRICS_JSON" \
      --output none
    log "    Created."
  fi
done

# =============================================================================
# Summary + KQL quickstart + cost note
# =============================================================================
log ""
log "======================================================================"
log "  ENABLE-MONITORING COMPLETE"
log "======================================================================"
log ""
log "  Log Analytics workspace : $LA_NAME"
log "  Storage account         : $SA_NAME"
log "  Resource group          : $RG  ($LOCATION)"
log ""
log "  Flow logs (VNet-level, Traffic Analytics enabled):"
log "    flow-vnet-dmz    -> vnet-dmz"
log "    flow-vnet-spoke1 -> vnet-spoke1"
log "    flow-vnet-spoke2 -> vnet-spoke2"
log ""
log "  Data takes ~10-20 minutes to appear in Log Analytics after first traffic."
log ""
log "  KQL QUICKSTART (run in: Azure portal -> Log Analytics -> Logs)"
log "  ────────────────────────────────────────────────────────────────"
log ""
log "  // Top internet-bound flows through NVAs (Traffic Analytics):"
echo '  AzureNetworkAnalytics_CL'
echo '  | where TimeGenerated > ago(1h)'
echo '  | where FlowType_s == "ExternalPublic"'
echo '  | summarize TotalBytes=sum(todouble(BytesSentFromPublicIP_d)+todouble(BytesSentToPublicIP_d)) by SrcIP_s, DestIP_s, DestPort_d'
echo '  | top 20 by TotalBytes'
echo ''
log "  // Public LB SNAT port usage (LB diagnostic settings):"
echo '  AzureMetrics'
echo '  | where ResourceProvider == "MICROSOFT.NETWORK"'
echo '  | where ResourceId has "lb-public"'
echo '  | where MetricName in ("UsedSNATPorts","AllocatedSNATPorts","SnatConnectionCount")'
echo '  | summarize avg(Average) by MetricName, bin(TimeGenerated, 1m)'
echo '  | render timechart'
echo ''
log "  ⚠  COST NOTE:"
log "     Log Analytics ingestion ~\$2.76/GB (Pay-As-You-Go, 30-day retention)"
log "     Storage account (flow log blobs) ~\$0.018/GB/month"
log "     Traffic Analytics ~\$0.10 per 1,000 flows (beyond free tier)"
log "     Keep this lab short-lived. To disable TA only:"
echo '     for FL in flow-vnet-dmz flow-vnet-spoke1 flow-vnet-spoke2; do'
echo "       az network watcher flow-log update -n \$FL -g NetworkWatcherRG --traffic-analytics false --output none"
echo '     done'
log "     To delete all monitoring resources: run cleanup.sh (deletes the whole RG)."
