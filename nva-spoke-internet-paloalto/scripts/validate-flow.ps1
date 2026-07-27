#Requires -Version 5.1
# =============================================================================
# validate-flow.ps1 — READ-ONLY traffic-breakout validation for nva-spoke-internet-paloalto
#                     PowerShell parity with validate-flow.sh
#
# Traces: Spoke VM -> vHub (0/0 via VirtualNetworkGateway) -> conn-dmz ->
#   ILB 10.0.0.68 (HA-ports) -> Palo Alto VM-Series (NAT MASQUERADE) ->
#   Public LB -> Internet
#
# Adapted from: nva-spoke-internet/scripts/validate-flow.ps1
# NVA type:     Palo Alto VM-Series (BYOL, PAN-OS 10.1+)
#
# Phases 1-3 and 5 are IDENTICAL to the Linux NVA validator — they validate
# the Azure control plane and data plane (effective routes, curl egress, LB
# metrics) which are NVA-agnostic.
#
# Phase 4 (NVA forwarding evidence) replaces iptables/conntrack/tcpdump with:
#   - PA management GUI URL discovery (read-only az CLI)
#   - Manual PAN-OS CLI command hints for operator review
#   - Emits WARN (not FAIL) since PA API/CLI access is not provisioned in the lab
#
# READ-ONLY: never creates or modifies Azure resources.
#
# Usage:
#   .\scripts\validate-flow.ps1
#   .\scripts\validate-flow.ps1 -Rg my-rg -Hub my-hub
#   .\scripts\validate-flow.ps1 -Rg my-rg -Hub my-hub -NvaNames "pa-fw-0","pa-fw-1"
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
#   PAN-OS session commands:   https://docs.paloaltonetworks.com/pan-os/11-1/pan-os-cli-quick-start/use-the-cli/cli-cheat-sheets
# =============================================================================

param(
    [string]$Rg       = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { "rg-nva-spoke-internet-pa" }),
    [string]$Hub      = "hub-nva-si",
    # Override to match your Bicep NVA VM names
    [string[]]$NvaNames = @("pa-fw-0", "pa-fw-1")
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

$hubRouting = "$(az network vhub show -g $Rg -n $Hub --query routingState -o tsv 2>$null)".Trim()
if ($hubRouting -eq "Provisioned") {
    CheckPass "Hub '$Hub' routingState = Provisioned"
} else {
    CheckFail "Hub '$Hub' routingState = $hubRouting (expected Provisioned)"
}

$HubId       = "$(az network vhub show -g $Rg -n $Hub --query id -o tsv 2>$null)".Trim()
$DefaultRtId = "${HubId}/hubRouteTables/defaultRouteTable"

# =============================================================================
# Phase 2 -- Control-plane
# Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
# =============================================================================
Log ""
Log "=== Phase 2: Control-plane routes ==="

# 2a. defaultRouteTable: 0.0.0.0/0 -> conn-dmz
# Route prefixes live in routes[].destinations[] (array) -- use contains() to check presence.
Log ""
Log "  [2a] Hub defaultRouteTable routes:"
$drt = az network vhub route-table show `
    -g $Rg --vhub-name $Hub --name defaultRouteTable `
    --query 'routes[].{destinations:destinations,nextHopType:nextHopType,nextHop:nextHop}' `
    -o table 2>$null
Log $drt
$q2a = "routes[?contains(destinations, '0.0.0.0/0')]"
$drt0 = "$(az network vhub route-table show -g $Rg --vhub-name $Hub --name defaultRouteTable --query $q2a -o tsv 2>$null)".Trim()
if (-not [string]::IsNullOrWhiteSpace($drt0)) {
    CheckPass "defaultRouteTable contains 0.0.0.0/0 route"
} else {
    CheckFail "defaultRouteTable missing 0.0.0.0/0 route (routing wiring incomplete)"
}

# 2b. conn-dmz static route: 0.0.0.0/0 -> 10.0.0.68 (ILB)
# Route prefixes live in staticRoutes[].addressPrefixes[] (array) -- use contains() to check.
Log ""
Log "  [2b] conn-dmz static routes (expected: 0.0.0.0/0 -> 10.0.0.68):"
$connRoutes = az network vhub connection show `
    -g $Rg --vhub-name $Hub -n conn-dmz `
    --query 'routingConfiguration.vnetRoutes.staticRoutes[].{name:name,prefix:addressPrefixes,nextHop:nextHopIpAddress}' `
    -o table 2>$null
Log $connRoutes
$q2b = "routingConfiguration.vnetRoutes.staticRoutes[?contains(addressPrefixes, '0.0.0.0/0')].nextHopIpAddress"
$connNH = "$(az network vhub connection show -g $Rg --vhub-name $Hub -n conn-dmz --query $q2b -o tsv 2>$null)".Trim()
if (-not [string]::IsNullOrWhiteSpace($connNH)) {
    CheckPass "conn-dmz static route 0.0.0.0/0 -> $connNH (ILB) present"
    if ($connNH -ne "10.0.0.68") {
        CheckWarn "conn-dmz nextHop = $connNH (expected 10.0.0.68 -- ILB frontend)"
    }
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
    if ($nhType -eq "VirtualNetworkGateway" -or $nhType -eq "VirtualHub") {
        CheckPass "NW next-hop: 0.0.0.0/0 -> $nhType (vHub router -- valid for vWAN spoke)"
    } else {
        CheckFail "NW next-hop type = '$nhType' (expected VirtualNetworkGateway or VirtualHub)"
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

$PublicLbPip = "$(az network public-ip show -g $Rg -n pip-lb-public --query ipAddress -o tsv 2>$null)".Trim()
Log "  Public LB PIP (pip-lb-public): $PublicLbPip"
Log "  Expected: VMs return this IP -- SNAT proof through PA NVA/Public LB"

Log ""
Log "  [3a] curl https://ifconfig.io from vm-spoke1:"
$raw1 = az vm run-command invoke -g $Rg -n vm-spoke1 `
    --command-id RunShellScript `
    --scripts 'curl -s --max-time 15 https://ifconfig.io' `
    --query 'value[0].message' -o tsv 2>$null
$curl1 = Get-IPv4 "$raw1"
Log "       returned IP: $curl1"
if (-not [string]::IsNullOrWhiteSpace($PublicLbPip) -and $curl1 -eq $PublicLbPip) {
    CheckPass "vm-spoke1 egress IP = $PublicLbPip (Public LB PIP) -- SNAT through PA NVA confirmed"
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
    CheckPass "vm-spoke2 egress IP = $PublicLbPip (Public LB PIP) -- SNAT through PA NVA confirmed"
} elseif ($LASTEXITCODE -ne 0) {
    CheckWarn "vm-spoke2 run-command failed"
} else {
    CheckFail "vm-spoke2 returned '$curl2', expected '$PublicLbPip'"
}

# =============================================================================
# Phase 4 -- PA NVA forwarding evidence
#
# PALO ALTO NOTE: Unlike the Linux NVA (where iptables/conntrack can be queried
# via az vm run-command), Palo Alto VM-Series session tables and NAT counters
# are accessible ONLY through the PAN-OS management plane (GUI or CLI over SSH/
# API).  The bootstrap.xml enables SSH on both data interfaces for LB health
# probes, but PA credentials are not provisioned in the lab.
#
# This phase:
#   1. Discovers the PA management NIC public IP via az CLI (read-only).
#   2. Prints the PA HTTPS GUI URL and manual CLI commands for the operator.
#   3. Emits WARN (not FAIL) for missing PA API evidence -- the data-plane curl
#      in Phase 3 is the authoritative pass/fail signal.
#
# Manual PAN-OS CLI evidence commands (run via SSH or Web GUI > CLI):
#   show session all filter source-zone trust
#   show session all filter destination-zone untrust
#   show running nat-policy
#   show counter global | match nat
#   show interface ethernet1/1
#   show interface ethernet1/2
# =============================================================================
Log ""
Log "=== Phase 4: PA NVA forwarding evidence (MANUAL -- see instructions below) ==="

foreach ($nvaName in $NvaNames) {
    Log ""
    Log "  ---- $nvaName ----"

    # 4a. Discover the management NIC public IP (eth0 / first NIC in Azure)
    Log "  [4a] Discovering PA management IP for $nvaName ..."
    $nicId = "$(az vm show -g $Rg -n $nvaName --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>$null)".Trim()

    $mgmtPip = ""
    if (-not [string]::IsNullOrWhiteSpace($nicId) -and $nicId -ne "None") {
        $pipId = "$(az network nic show --ids $nicId --query 'ipConfigurations[0].publicIPAddress.id' -o tsv 2>$null)".Trim()
        if (-not [string]::IsNullOrWhiteSpace($pipId) -and $pipId -ne "None") {
            $mgmtPip = "$(az network public-ip show --ids $pipId --query ipAddress -o tsv 2>$null)".Trim()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($mgmtPip)) {
        Log "  [PASS] PA management public IP: $mgmtPip"
        Log ""
        Log "  +-----------------------------------------------------------------"
        Log "  |  MANUAL STEP -- Connect to $nvaName management plane"
        Log "  |"
        Log "  |  HTTPS GUI:  https://$mgmtPip"
        Log "  |  SSH CLI:    ssh admin@$mgmtPip"
        Log "  |"
        Log "  |  Run these PAN-OS CLI commands to confirm forwarding:"
        Log "  |    admin@pan> show session all filter source-zone trust"
        Log "  |    admin@pan> show session all filter destination-zone untrust"
        Log "  |    admin@pan> show running nat-policy"
        Log "  |    admin@pan> show counter global | match nat"
        Log "  |    admin@pan> show interface ethernet1/1"
        Log "  |    admin@pan> show interface ethernet1/2"
        Log "  |"
        Log "  |  Expected NAT policy output (similar to):"
        Log "  |    trust-to-untrust-masquerade  trust -> untrust  dynamic-ip-and-port"
        Log "  |"
        Log "  |  Expected counters (non-zero after Phase 3 curl runs):"
        Log "  |    flow_nat_translate   (NAT translations performed)"
        Log "  |    flow_fwd_l3          (L3 forwards)"
        Log "  +-----------------------------------------------------------------"
        CheckWarn "${nvaName}: PA forwarding evidence is MANUAL (see GUI/CLI instructions above)"
    } else {
        Log "  [WARN] Could not resolve management public IP for $nvaName."
        Log "         If the management NIC has no public IP, connect via Azure Bastion or"
        Log "         VPN to reach the snet-mgmt (10.0.0.0/27) address."
        Log ""
        Log "         Manual PAN-OS CLI evidence commands:"
        Log "           show session all filter source-zone trust"
        Log "           show session all filter destination-zone untrust"
        Log "           show running nat-policy"
        Log "           show counter global | match nat"
        CheckWarn "${nvaName}: management IP not resolvable via az CLI (manual access required)"
    }
}

# =============================================================================
# Phase 5 -- LB Metrics
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
# Ref: https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
# Ref: https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli
# =============================================================================
Log ""
Log "=== Phase 5: Standard Load Balancer metrics ==="
Log "  (30-min window; non-zero values confirm active traffic; zero is normal when lab is idle)"

$lbPublicId = "$(az network lb show -g $Rg -n lb-public --query id -o tsv 2>$null)".Trim()
$lbIlbId    = "$(az network lb show -g $Rg -n lb-ilb    --query id -o tsv 2>$null)".Trim()

$StartTime = (Get-Date).ToUniversalTime().AddMinutes(-30).ToString("yyyy-MM-ddTHH:mm:ssZ")
$EndTime   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
Log "  Window: $StartTime -> $EndTime"

if ([string]::IsNullOrWhiteSpace($lbPublicId)) {
    CheckWarn "lb-public not found -- metrics phase skipped"
} else {
    Log ""
    Log "  Public LB (lb-public) -- SNAT, availability, and traffic metrics:"
    Log "  Note: correct metric names are UsedSnatPorts / AllocatedSnatPorts (lowercase 'nat')"
    # Per https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli
    # aggregations: Average for ports/availability; Total for counts/bytes
    foreach ($m in @(
        @{name="UsedSnatPorts";      agg="Average"},
        @{name="AllocatedSnatPorts"; agg="Average"},
        @{name="SnatConnectionCount";agg="Total"},
        @{name="ByteCount";          agg="Total"},
        @{name="PacketCount";        agg="Total"},
        @{name="VipAvailability";    agg="Average"},
        @{name="DipAvailability";    agg="Average"}
    )) {
        Log "  -- $($m.name) ($($m.agg)):"
        $azOut = az monitor metrics list `
            --resource   $lbPublicId `
            --metric     $m.name `
            --start-time $StartTime `
            --end-time   $EndTime `
            --interval PT5M `
            --aggregation $m.agg `
            -o table 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "     ERROR (exit $LASTEXITCODE): $azOut"
            CheckWarn "$($m.name): az metrics call failed (see above)"
        } else {
            Log $azOut
        }
    }

    Log ""
    Log "  ILB (lb-ilb) -- backend health (DipAvailability only):"
    Log "  NOTE: ILB ByteCount/PacketCount are ZERO by design for UDR-forwarded traffic."
    Log "  Ref: https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics#multi-dimensional-metrics"
    if (-not [string]::IsNullOrWhiteSpace($lbIlbId)) {
        Log "  -- DipAvailability (Average):"
        $azOut = az monitor metrics list `
            --resource   $lbIlbId `
            --metric     "DipAvailability" `
            --start-time $StartTime `
            --end-time   $EndTime `
            --interval PT5M `
            --aggregation "Average" `
            -o table 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "     ERROR (exit $LASTEXITCODE): $azOut"
            CheckWarn "ILB DipAvailability: az metrics call failed (see above)"
        } else {
            Log $azOut
        }
    } else {
        CheckWarn "lb-ilb not found -- ILB metrics skipped"
    }
}

# =============================================================================
# Summary
# =============================================================================
Log ""
Log "======================================================================"
Log "  validate-flow.ps1 SUMMARY (nva-spoke-internet-paloalto)"
Log "======================================================================"
Log "  PASS: $($script:Pass)   FAIL: $($script:Fail)   WARN: $($script:Warn)"
Log "======================================================================"

if ($script:Fail -gt 0) {
    Log ""
    Log "  Some checks FAILED. Common causes:"
    Log "    - Lab not fully deployed or routing phases not completed"
    Log "    - PA NVA bootstrap not completed (check: az vm boot-diagnostics get-boot-log)"
    Log "    - ILB backend pool empty (PA trust NICs not registered)"
    Log "    - Network Watcher not enabled for the region"
    Log "    - PA management profile not allowing SSH on data interfaces (LB probe fails)"
    exit 1
}

Log ""
Log "  All critical checks passed. Internet breakout Spoke->PA NVA->Public LB is functioning."
Log "  Review Phase 4 WARN items above for manual PA session/NAT evidence."
