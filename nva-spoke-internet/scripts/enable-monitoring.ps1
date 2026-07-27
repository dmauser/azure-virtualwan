#Requires -Version 5.1
# =============================================================================
# enable-monitoring.ps1 — OPTIONAL monitoring stack for nva-spoke-internet
#                          PowerShell parity with enable-monitoring.sh
#
# Provisions the additional logging/monitoring resources required to analyse
# traffic flow through the DMZ NVAs with Traffic Analytics and LB metrics.
# SEPARATE from core lab deployment because these resources incur ongoing cost.
#
# IDEMPOTENT: resources that already exist are skipped.
#
# What this creates:
#   1. Log Analytics workspace  (log-nva-spoke-internet)
#   2. Storage account          (stnvaspk<sub-8-chars>, Standard_LRS)
#   3. Network Watcher          (NetworkWatcher_<region>, in NetworkWatcherRG)
#   4. VNet flow logs           (flow-vnet-dmz, flow-vnet-spoke1, flow-vnet-spoke2)
#      -- VNet flow logs, NOT NSG flow logs (NSG flow logs retire 2027-09-30;
#         new NSG flow logs blocked after 2025-06-30)
#   5. LB diagnostic settings   (diag-lb-public, diag-lb-ilb -> workspace AllMetrics)
#
# Usage:
#   .\scripts\enable-monitoring.ps1
#   .\scripts\enable-monitoring.ps1 -Rg my-rg
#
# References (authoritative):
#   VNet flow logs overview:   https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
#   Manage VNet flow logs:     https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
#   NSG flow log migration:    https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
#   Traffic Analytics:         https://learn.microsoft.com/azure/network-watcher/traffic-analytics
#   LB diagnostic settings:    https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# =============================================================================

param(
    [string]$Rg = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-nva-spoke-internet" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log([string]$m) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan
}

$LA_NAME = "log-nva-spoke-internet"
$NW_RG   = "NetworkWatcherRG"

# =============================================================================
# Phase 1 -- Pre-checks
# =============================================================================
Log "=== Phase 1: Pre-checks ==="

$acctJson = az account show -o json 2>$null
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in. Run: az login"; exit 1 }
$acct = $acctJson | ConvertFrom-Json
Log "  Logged in: $($acct.name) ($($acct.id))"

az group show -n $Rg --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Resource group '$Rg' not found. Deploy the lab first (deploy.ps1)."
    exit 1
}
Log "  Resource group: $Rg"

$Location = "$(az group show -n $Rg --query location -o tsv 2>$null)".Trim()
Log "  Region: $Location"

# Deterministic storage account name: prefix + first 8 chars of subscription ID
$SubShort = ($acct.id -replace '-','').Substring(0,8).ToLower()
$SaName   = "stnvaspk${SubShort}"
Log "  Storage account name: $SaName"

# =============================================================================
# Phase 2 -- Log Analytics workspace
# =============================================================================
Log ""
Log "=== Phase 2: Log Analytics workspace '$LA_NAME' ==="

az monitor log-analytics workspace show -g $Rg -n $LA_NAME --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Log "  Workspace already exists -- skipping."
} else {
    Log "  Creating workspace (30-day retention) ..."
    az monitor log-analytics workspace create `
        -g $Rg -n $LA_NAME -l $Location `
        --retention-time 30 `
        --output none
    Log "  Created."
}

$LaId = "$(az monitor log-analytics workspace show -g $Rg -n $LA_NAME --query id -o tsv 2>$null)".Trim()
Log "  Workspace ID: $LaId"

# =============================================================================
# Phase 3 -- Storage account for flow log blobs
# =============================================================================
Log ""
Log "=== Phase 3: Storage account '$SaName' ==="

az storage account show -n $SaName -g $Rg --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Log "  Storage account already exists -- skipping."
} else {
    Log "  Creating storage account (Standard_LRS) ..."
    az storage account create `
        -n $SaName -g $Rg -l $Location `
        --sku Standard_LRS `
        --kind StorageV2 `
        --min-tls-version TLS1_2 `
        --output none
    Log "  Created."
}

$SaId = "$(az storage account show -n $SaName -g $Rg --query id -o tsv 2>$null)".Trim()
Log "  Storage account ID: $SaId"

# =============================================================================
# Phase 4 -- Network Watcher
# =============================================================================
Log ""
Log "=== Phase 4: Network Watcher (NetworkWatcherRG / $Location) ==="

$NwName = "NetworkWatcher_${Location}"
az network watcher show -g $NW_RG -n $NwName --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Log "  Network Watcher '$NwName' already exists -- skipping."
} else {
    Log "  Ensuring NetworkWatcherRG exists ..."
    az group create -n $NW_RG -l $Location --output none 2>$null
    Log "  Creating Network Watcher for region '$Location' ..."
    az network watcher create -l $Location --output none
    Log "  Created."
}

# =============================================================================
# Phase 5 -- VNet flow logs (DMZ + Spoke1 + Spoke2)
# NOTE: Using VNet flow logs, NOT NSG flow logs.
#   NSG flow logs retire 2027-09-30; new NSG flow logs blocked after 2025-06-30.
#   Ref: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
#   Ref: https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
# =============================================================================
Log ""
Log "=== Phase 5: VNet flow logs ==="
Log "  Using VNet flow logs (NOT NSG flow logs -- retiring 2027-09-30, blocked new creation after 2025-06-30)"
Log "  Ref: https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate"

$FlowLogMap = @{
    "flow-vnet-dmz"    = "vnet-dmz"
    "flow-vnet-spoke1" = "vnet-spoke1"
    "flow-vnet-spoke2" = "vnet-spoke2"
}

foreach ($FlName in $FlowLogMap.Keys) {
    $VnetName = $FlowLogMap[$FlName]
    Log ""
    Log "  Flow log '$FlName' for VNet '$VnetName':"

    $VnetId = "$(az network vnet show -g $Rg -n $VnetName --query id -o tsv 2>$null)".Trim()
    if ([string]::IsNullOrWhiteSpace($VnetId)) {
        Log "  WARNING: VNet '$VnetName' not found in '$Rg' -- skipping."
        continue
    }

    az network watcher flow-log show -n $FlName -g $NW_RG --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log "    Already exists -- skipping."
    } else {
        Log "    Creating (Traffic Analytics enabled) ..."
        az network watcher flow-log create `
            --name $FlName `
            --vnet $VnetId `
            --storage-account $SaId `
            --workspace $LaId `
            --traffic-analytics true `
            --location $Location `
            -g $NW_RG `
            --output none
        Log "    Created."
    }
}

# =============================================================================
# Phase 6 -- LB diagnostic settings
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# =============================================================================
Log ""
Log "=== Phase 6: LB diagnostic settings -> Log Analytics workspace ==="

$MetricsJson = '[{"category":"AllMetrics","enabled":true}]'

foreach ($LbName in @("lb-public","lb-ilb")) {
    Log ""
    Log "  LB '$LbName':"
    $LbId = "$(az network lb show -g $Rg -n $LbName --query id -o tsv 2>$null)".Trim()
    if ([string]::IsNullOrWhiteSpace($LbId)) {
        Log "  WARNING: '$LbName' not found in '$Rg' -- skipping."
        continue
    }

    $DiagName = "diag-${LbName}"
    az monitor diagnostic-settings show --resource $LbId -n $DiagName --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Log "    Diagnostic settings '$DiagName' already exist -- skipping."
    } else {
        Log "    Creating diagnostic settings (AllMetrics) ..."
        az monitor diagnostic-settings create `
            --resource $LbId `
            -n $DiagName `
            --workspace $LaId `
            --metrics $MetricsJson `
            --output none
        Log "    Created."
    }
}

# =============================================================================
# Summary + KQL quickstart + cost note
# =============================================================================
Log ""
Log "======================================================================"
Log "  ENABLE-MONITORING COMPLETE"
Log "======================================================================"
Log ""
Log "  Log Analytics workspace : $LA_NAME"
Log "  Storage account         : $SaName"
Log "  Resource group          : $Rg  ($Location)"
Log ""
Log "  Flow logs (VNet-level, Traffic Analytics enabled):"
Log "    flow-vnet-dmz    -> vnet-dmz"
Log "    flow-vnet-spoke1 -> vnet-spoke1"
Log "    flow-vnet-spoke2 -> vnet-spoke2"
Log ""
Log "  Data takes ~10-20 minutes to appear in Log Analytics after first traffic."
Log ""
Log "  KQL QUICKSTART (run in: Azure portal -> Log Analytics -> Logs)"
Log "  ────────────────────────────────────────────────────────────────"
Log ""
Log "  // Top internet-bound flows through NVAs (Traffic Analytics):"
Write-Host '  AzureNetworkAnalytics_CL'
Write-Host '  | where TimeGenerated > ago(1h)'
Write-Host '  | where FlowType_s == "ExternalPublic"'
Write-Host '  | summarize TotalBytes=sum(todouble(BytesSentFromPublicIP_d)+todouble(BytesSentToPublicIP_d)) by SrcIP_s, DestIP_s, DestPort_d'
Write-Host '  | top 20 by TotalBytes'
Write-Host ''
Log "  // Public LB SNAT port usage:"
Write-Host '  AzureMetrics'
Write-Host '  | where ResourceProvider == "MICROSOFT.NETWORK"'
Write-Host '  | where ResourceId has "lb-public"'
Write-Host '  | where MetricName in ("UsedSNATPorts","AllocatedSNATPorts","SnatConnectionCount")'
Write-Host '  | summarize avg(Average) by MetricName, bin(TimeGenerated, 1m)'
Write-Host '  | render timechart'
Write-Host ''
Log "  COST NOTE:"
Log "    Log Analytics ingestion ~`$2.76/GB (Pay-As-You-Go, 30-day retention)"
Log "    Storage account (flow log blobs) ~`$0.018/GB/month"
Log "    Traffic Analytics ~`$0.10 per 1,000 flows (beyond free tier)"
Log "    Keep this lab short-lived. To disable Traffic Analytics only:"
Write-Host '    @("flow-vnet-dmz","flow-vnet-spoke1","flow-vnet-spoke2") | ForEach-Object {'
Write-Host '      az network watcher flow-log update -n $_ -g NetworkWatcherRG --traffic-analytics false --output none'
Write-Host '    }'
Log "    To delete all monitoring resources: run cleanup (deletes the whole RG)."
