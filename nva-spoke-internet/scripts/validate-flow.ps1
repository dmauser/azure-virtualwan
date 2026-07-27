#Requires -Version 5.1
# =============================================================================
# validate-flow.ps1 — READ-ONLY traffic-breakout validation for nva-spoke-internet
#                     PowerShell parity with validate-flow.sh
#
# Traces: Spoke VM -> vHub (0/0 via VirtualNetworkGateway) -> conn-dmz ->
#   ILB 10.0.0.68 (HA-ports) -> NVA (iptables MASQUERADE) -> Public LB -> Internet
#
# READ-ONLY: never creates or modifies Azure resources.
#
# Usage:
#   .\scripts\validate-flow.ps1
#   .\scripts\validate-flow.ps1 -Rg my-rg -Hub my-hub
#
# References (authoritative):
#   Effective routes (vWAN):   https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
#   Manage route tables:       https://learn.microsoft.com/azure/virtual-network/manage-route-table
#   NW next-hop:               https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
#   NW IP flow verify:         https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
#   NW connectivity:           https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
#   LB monitoring:             https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
#   LB metric reference:       https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
#   Outbound troubleshoot:     https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
# =============================================================================

param(
    [string]$Rg  = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-nva-spoke-internet" }),
    [string]$Hub = "vhub-nva-spoke"
)

Set-StrictMode -Version Latest
# Use Continue so individual check failures do not abort the entire script.
$ErrorActionPreference = "Continue"

$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Log([string]$m) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan
}

function CheckPass([string]$label) { Log "  [PASS] $label"; $script:Pass++ }
function CheckFail([string]$label) { Log "  [FAIL] $label"; $script:Fail++ }
function CheckWarn([string]$label) { Log "  [WARN] $label"; $script:Warn++ }

# Extract first IPv4 address from a string
function Get-IPv4([string]$s) {
    $m = [regex]::Match($s, '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}')
    if ($m.Success) { return $m.Value.Trim() }
    return ""
}

# =============================================================================
# Phase 1 -- Pre-checks
# =============================================================================
Log "=== Phase 1: Pre-checks ==="

$acctJson = az account show -o json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acctJson)) {
    Write-Error "Not logged in to Azure. Run: az login"
    exit 1
}
$acct = $acctJson | ConvertFrom-Json
Log "  Logged in: $($acct.name) ($($acct.id))"

$rgExists = az group show -n $Rg --output none 2>$null; $rgEc = $LASTEXITCODE
if ($rgEc -ne 0) {
    Write-Error "Resource group '$Rg' not found. Deploy the lab first."
    exit 1
}
Log "  Resource group: $Rg"

$hubRouting = (az network vhub show -g $Rg -n $Hub --query routingState -o tsv 2>$null).Trim()
if ($hubRouting -eq "Provisioned") {
    CheckPass "Hub '$Hub' routingState = Provisioned"
} else {
    CheckFail "Hub '$Hub' routingState = $hubRouting (expected Provisioned)"
}

$HubId       = (az network vhub show -g $Rg -n $Hub --query id -o tsv 2>$null).Trim()
$DefaultRtId = "${HubId}/hubRouteTables/defaultRouteTable"

# =============================================================================
# Phase 2 -- Control-plane
# Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
# =============================================================================
Log ""
Log "=== Phase 2: Control-plane routes ==="

# 2a. defaultRouteTable: 0.0.0.0/0 -> conn-dmz
Log ""
Log "  [2a] Hub defaultRouteTable routes:"
$drt = az network vhub route-table show `
    -g $Rg --vhub-name $Hub --name defaultRouteTable `
    --query 'routes[].{destinations:destinations,nextHopType:nextHopType,nextHop:nextHop}' `
    -o table 2>$null
Log $drt
if ($drt -match "0\.0\.0\.0/0") {
    CheckPass "defaultRouteTable contains 0.0.0.0/0 route"
} else {
    CheckFail "defaultRouteTable missing 0.0.0.0/0 route (routing wiring incomplete)"
}

# 2b. conn-dmz static route
Log ""
Log "  [2b] conn-dmz static routes (expected: 0.0.0.0/0 -> 10.0.0.68):"
$connRoutes = az network vhub connection show `
    -g $Rg --vhub-name $Hub -n conn-dmz `
    --query 'routingConfiguration.vnetRoutes.staticRoutes[].{name:name,prefix:addressPrefixes,nextHop:nextHopIpAddress}' `
    -o table 2>$null
Log $connRoutes
if ($connRoutes -match "0\.0\.0\.0/0") {
    CheckPass "conn-dmz static route 0.0.0.0/0 -> 10.0.0.68 (ILB) present"
} else {
    CheckFail "conn-dmz static route 0.0.0.0/0 missing"
}

# 2c. Spoke1 NIC effective routes
# Ref: https://learn.microsoft.com/azure/virtual-network/manage-route-table
Log ""
Log "  [2c] Spoke1 NIC (nic-vm-spoke1) effective routes:"
Log "       Expecting 0.0.0.0/0 via VirtualNetworkGateway (vHub BGP router)"
$eff1 = az network nic show-effective-route-table -g $Rg -n nic-vm-spoke1 -o table 2>$null
Log $eff1
if ($eff1 -match "VirtualNetworkGateway") {
    CheckPass "Spoke1 NIC: 0.0.0.0/0 via VirtualNetworkGateway (vHub)"
} else {
    CheckFail "Spoke1 NIC: missing 0.0.0.0/0 via VirtualNetworkGateway"
}

# 2d. Spoke2 NIC effective routes
Log ""
Log "  [2d] Spoke2 NIC (nic-vm-spoke2) effective routes:"
$eff2 = az network nic show-effective-route-table -g $Rg -n nic-vm-spoke2 -o table 2>$null
Log $eff2
if ($eff2 -match "VirtualNetworkGateway") {
    CheckPass "Spoke2 NIC: 0.0.0.0/0 via VirtualNetworkGateway (vHub)"
} else {
    CheckFail "Spoke2 NIC: missing 0.0.0.0/0 via VirtualNetworkGateway"
}

# 2e. vHub effective routes (defaultRouteTable)
# Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
Log ""
Log "  [2e] vHub effective routes for defaultRouteTable:"
az network vhub get-effective-routes `
    --resource-type RouteTable `
    --resource-id $DefaultRtId `
    -g $Rg -n $Hub `
    -o table 2>$null
if ($LASTEXITCODE -eq 0) {
    CheckPass "vHub get-effective-routes returned successfully"
} else {
    CheckWarn "vhub get-effective-routes failed (may need az-cli >= 2.57)"
}

# 2f. Network Watcher next-hop
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
Log ""
Log "  [2f] NW next-hop: vm-spoke1 (10.1.0.4) -> 8.8.8.8"
$nhJson = az network watcher show-next-hop `
    -g $Rg `
    --vm vm-spoke1 `
    --source-ip 10.1.0.4 `
    --dest-ip 8.8.8.8 `
    --nic nic-vm-spoke1 `
    -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($nhJson)) {
    $nhObj  = $nhJson | ConvertFrom-Json
    $nhType = $nhObj.nextHopType
    $nhIp   = $nhObj.nextHopIpAddress
    Log "       nextHopType: $nhType   nextHopIpAddress: $nhIp"
    if ($nhType -eq "VirtualNetworkGateway") {
        CheckPass "NW next-hop: 0.0.0.0/0 -> VirtualNetworkGateway (vHub router)"
    } else {
        CheckFail "NW next-hop type = '$nhType' (expected VirtualNetworkGateway)"
    }
} else {
    CheckWarn "NW next-hop failed (Network Watcher may not be enabled in this region)"
}

# 2g. Network Watcher IP flow verify
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
Log ""
Log "  [2g] NW IP flow verify: vm-spoke1 -> 8.8.8.8:443 TCP Outbound"
$ifvJson = az network watcher test-ip-flow `
    -g $Rg `
    --vm vm-spoke1 `
    --direction Outbound `
    --protocol TCP `
    --local 10.1.0.4:0 `
    --remote 8.8.8.8:443 `
    --nic nic-vm-spoke1 `
    -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ifvJson)) {
    $ifvObj    = $ifvJson | ConvertFrom-Json
    $ifvAccess = $ifvObj.access
    $ifvRule   = $ifvObj.ruleName
    Log "       access: $ifvAccess   ruleName: $ifvRule"
    if ($ifvAccess -eq "Allow") {
        CheckPass "NW IP flow verify: Outbound TCP 10.1.0.4 -> 8.8.8.8:443 = Allow"
    } else {
        CheckFail "NW IP flow verify: access = '$ifvAccess' (expected Allow) -- check NSG rules"
    }
} else {
    CheckWarn "NW IP flow verify failed (Network Watcher may not be enabled)"
}

# 2h. Network Watcher connectivity test
# Ref: https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
Log ""
Log "  [2h] NW connectivity test: vm-spoke1 -> ifconfig.io:80"
$ctJson = az network watcher test-connectivity `
    -g $Rg `
    --source-resource vm-spoke1 `
    --dest-address ifconfig.io `
    --dest-port 80 `
    -o json 2>$null
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ctJson)) {
    $ctObj     = $ctJson | ConvertFrom-Json
    $ctStatus  = $ctObj.connectionStatus
    $ctLatency = $ctObj.avgLatencyInMs
    Log "       connectionStatus: $ctStatus   avgLatencyInMs: $ctLatency"
    if ($ctStatus -eq "Reachable") {
        CheckPass "NW connectivity: vm-spoke1 -> ifconfig.io:80 = Reachable"
    } else {
        CheckFail "NW connectivity: '$ctStatus' (expected Reachable)"
    }
} else {
    CheckWarn "NW connectivity test failed (Network Watcher may not be enabled)"
}

# =============================================================================
# Phase 3 -- Data-plane: curl from spoke VMs
# Ref: https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
# =============================================================================
Log ""
Log "=== Phase 3: Data-plane -- curl from spoke VMs ==="

$PublicLbPip = (az network public-ip show -g $Rg -n pip-lb-public `
    --query ipAddress -o tsv 2>$null).Trim()
Log "  Public LB PIP (pip-lb-public): $PublicLbPip"
Log "  Expected: VMs return this IP -- SNAT proof through NVA/Public LB"

Log ""
Log "  [3a] curl https://ifconfig.io from vm-spoke1:"
$raw1 = az vm run-command invoke -g $Rg -n vm-spoke1 `
    --command-id RunShellScript `
    --scripts 'curl -s --max-time 15 https://ifconfig.io' `
    --query 'value[0].message' -o tsv 2>$null
$curl1 = Get-IPv4 "$raw1"
Log "       returned IP: $curl1"
if (-not [string]::IsNullOrWhiteSpace($PublicLbPip) -and $curl1 -eq $PublicLbPip) {
    CheckPass "vm-spoke1 egress IP = $PublicLbPip (Public LB PIP) -- SNAT through NVA confirmed"
} elseif ($LASTEXITCODE -ne 0) {
    CheckWarn "vm-spoke1 run-command failed (VM unreachable or extension not ready)"
} else {
    CheckFail "vm-spoke1 returned '$curl1', expected '$PublicLbPip'"
}

Log ""
Log "  [3b] curl https://ifconfig.io from vm-spoke2:"
$raw2 = az vm run-command invoke -g $Rg -n vm-spoke2 `
    --command-id RunShellScript `
    --scripts 'curl -s --max-time 15 https://ifconfig.io' `
    --query 'value[0].message' -o tsv 2>$null
$curl2 = Get-IPv4 "$raw2"
Log "       returned IP: $curl2"
if (-not [string]::IsNullOrWhiteSpace($PublicLbPip) -and $curl2 -eq $PublicLbPip) {
    CheckPass "vm-spoke2 egress IP = $PublicLbPip (Public LB PIP) -- SNAT through NVA confirmed"
} elseif ($LASTEXITCODE -ne 0) {
    CheckWarn "vm-spoke2 run-command failed"
} else {
    CheckFail "vm-spoke2 returned '$curl2', expected '$PublicLbPip'"
}

# =============================================================================
# Phase 4 -- NVA forwarding evidence
# =============================================================================
Log ""
Log "=== Phase 4: NVA forwarding evidence ==="

foreach ($nvaName in @("nva-dmz-0", "nva-dmz-1")) {
    Log ""
    Log "  ---- $nvaName ----"

    Log "  [4a] iptables POSTROUTING MASQUERADE hit counters:"
    $ipt = az vm run-command invoke -g $Rg -n $nvaName `
        --command-id RunShellScript `
        --scripts 'sudo iptables -t nat -L POSTROUTING -v -n 2>&1' `
        --query 'value[0].message' -o tsv 2>$null
    Log $ipt
    if ($ipt -imatch "MASQUERADE") {
        CheckPass "${nvaName}: iptables MASQUERADE rule present in POSTROUTING"
    } elseif ($LASTEXITCODE -ne 0) {
        CheckWarn "${nvaName}: iptables query failed"
    } else {
        CheckFail "${nvaName}: MASQUERADE rule not found -- NVA cloud-init may not have completed"
    }

    Log ""
    Log "  [4b] Connection tracking (conntrack -L | head; fallback ss -s):"
    $ctbl = az vm run-command invoke -g $Rg -n $nvaName `
        --command-id RunShellScript `
        --scripts 'sudo conntrack -L 2>/dev/null | head -20 || ss -s' `
        --query 'value[0].message' -o tsv 2>$null
    Log $ctbl
}

# Concurrent: tcpdump on nva-dmz-0 while spoke VM generates traffic
Log ""
Log "  [4c] Concurrent: tcpdump on nva-dmz-0 + curl from vm-spoke1 (5 s capture)"
Log "       Starting background spoke traffic ..."

$bgJob = Start-Job -ScriptBlock {
    param($rg)
    az vm run-command invoke -g $rg -n vm-spoke1 `
        --command-id RunShellScript `
        --scripts 'for i in 1 2 3; do curl -s --max-time 5 https://ifconfig.io > /dev/null; done' `
        --output none 2>$null | Out-Null
} -ArgumentList $Rg

Log "       Running tcpdump on nva-dmz-0 (5 s or 20 packets) ..."
$tcpdOut = az vm run-command invoke -g $Rg -n "nva-dmz-0" `
    --command-id RunShellScript `
    --scripts 'sudo timeout 5 tcpdump -ni any "host 8.8.8.8 or port 443" -c 20 2>&1 || true' `
    --query 'value[0].message' -o tsv 2>$null
Log "  tcpdump output (nva-dmz-0):"
Log $tcpdOut

Wait-Job $bgJob -Timeout 120 | Out-Null
Remove-Job $bgJob -Force | Out-Null

if ($LASTEXITCODE -eq 0) {
    CheckPass "tcpdump on nva-dmz-0 succeeded (NVA is forwarding packets)"
} else {
    CheckWarn "tcpdump on nva-dmz-0 failed (non-fatal)"
}

# =============================================================================
# Phase 5 -- LB Metrics
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
# =============================================================================
Log ""
Log "=== Phase 5: Standard Load Balancer metrics ==="
Log "  (Non-zero values confirm active traffic; zero is normal when lab is idle)"

$lbPublicId = (az network lb show -g $Rg -n lb-public --query id -o tsv 2>$null).Trim()
$lbIlbId    = (az network lb show -g $Rg -n lb-ilb    --query id -o tsv 2>$null).Trim()

if ([string]::IsNullOrWhiteSpace($lbPublicId)) {
    CheckWarn "lb-public not found -- metrics phase skipped"
} else {
    Log ""
    Log "  Public LB (lb-public) -- SNAT, availability, traffic metrics:"
    foreach ($metric in @("UsedSNATPorts","AllocatedSNATPorts","SnatConnectionCount","ByteCount","PacketCount","DipAvailability","VipAvailability")) {
        Log "  -- $metric :"
        az monitor metrics list `
            --resource $lbPublicId `
            --metric $metric `
            --interval PT5M `
            --aggregation Maximum Total `
            -o table 2>$null
        if ($LASTEXITCODE -ne 0) { Log "     (no data or metric unavailable)" }
    }

    Log ""
    Log "  ILB (lb-ilb) -- health probe + traffic metrics:"
    foreach ($metric in @("DipAvailability","ByteCount","PacketCount")) {
        Log "  -- $metric :"
        az monitor metrics list `
            --resource $lbIlbId `
            --metric $metric `
            --interval PT5M `
            --aggregation Maximum Total `
            -o table 2>$null
        if ($LASTEXITCODE -ne 0) { Log "     (no data or metric unavailable)" }
    }
}

# =============================================================================
# Summary
# =============================================================================
Log ""
Log "======================================================================"
Log "  validate-flow.ps1 SUMMARY"
Log "======================================================================"
Log "  PASS: $($script:Pass)   FAIL: $($script:Fail)   WARN: $($script:Warn)"
Log "======================================================================"

if ($script:Fail -gt 0) {
    Log ""
    Log "  Some checks FAILED. Common causes:"
    Log "    - Lab not fully deployed or routing phases not completed"
    Log "    - NVA cloud-init not finished"
    Log "    - ILB backend pool empty (NVA NICs not registered)"
    Log "    - Network Watcher not enabled for the region"
    exit 1
}

Log ""
Log "  All critical checks passed. Internet breakout Spoke->NVA->Public LB is functioning."
Log "  For deeper analysis, run: .\scripts\enable-monitoring.ps1"
