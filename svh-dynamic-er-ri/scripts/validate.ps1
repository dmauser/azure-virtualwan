#Requires -Version 5.1
<#
.SYNOPSIS
    Validate the svh-dynamic-er-ri lab deployment.
.DESCRIPTION
    Discovers all vHubs dynamically and validates every resource deployed by
    the svh-dynamic-er-ri Bicep templates. Prints [PASS]/[FAIL] for each check.
    Works for any number of hubs (1..N).
.PARAMETER ResourceGroup
    Azure resource group name. Prompted interactively if omitted.
.EXAMPLE
    .\validate.ps1 -ResourceGroup lab-svh-dynamic-er-ri
.EXAMPLE
    .\validate.ps1
#>
param(
    [Parameter(Position=0)]
    [string]$ResourceGroup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
$script:passCount = 0
$script:failCount = 0

function Write-Hdr([string]$Title) {
    Write-Host ""
    Write-Host "###############################################################"
    Write-Host "# $Title"
    Write-Host "###############################################################"
}

function Write-Ok([string]$Msg) {
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
    $script:passCount++
}

function Write-Fail([string]$Msg) {
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    $script:failCount++
}

function Write-Warn([string]$Msg) {
    Write-Host "  [WARN] $Msg" -ForegroundColor Yellow
}

# Timestamp every progress line so stalls are obvious in terminal output.
function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Invoke-Az {
    param([string[]]$Args)
    $output = az @Args 2>$null
    return $output
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
if (-not $ResourceGroup) {
    $ResourceGroup = Read-Host "Enter resource group name"
}
Write-Host ""
Write-Host "Resource group : $ResourceGroup"
Write-Host "============================================================="

# ---------------------------------------------------------------------------
# Section 1 — Virtual WAN
# ---------------------------------------------------------------------------
Write-Hdr "1. Virtual WAN"
$vwanName = (Invoke-Az @('network', 'vwan', 'list', '-g', $ResourceGroup, '--query', '[0].name', '-o', 'tsv')) -replace '\s',''
if (-not $vwanName) {
    Write-Fail "No Virtual WAN found in resource group $ResourceGroup"
    Write-Host ""; Write-Host "TOTAL: $($script:passCount) passed / $($script:failCount) failed"
    exit 1
}
Write-Ok "Virtual WAN found: $vwanName"

$vwanSku = (Invoke-Az @('network', 'vwan', 'show', '-g', $ResourceGroup, '-n', $vwanName, '--query', 'sku', '-o', 'tsv')) -replace '\s',''
if ($vwanSku -eq 'Standard') {
    Write-Ok "  SKU = $vwanSku"
} else {
    Write-Fail "  SKU = $vwanSku  (expected Standard)"
}

# ---------------------------------------------------------------------------
# Discover all hubs
# ---------------------------------------------------------------------------
$hubsRaw = Invoke-Az @('network', 'vhub', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'tsv')
$hubs = @($hubsRaw | Where-Object { $_ -ne '' } | Sort-Object)

if ($hubs.Count -eq 0) {
    Write-Fail "No vHubs found in resource group $ResourceGroup"
    Write-Host ""; Write-Host "TOTAL: $($script:passCount) passed / $($script:failCount) failed"
    exit 1
}
Write-Host "  Discovered $($hubs.Count) hub(s): $($hubs -join ', ')"

# ---------------------------------------------------------------------------
# Section 2 — vHub provisioning state + routingState
# ---------------------------------------------------------------------------
Write-Hdr "2. vHub Provisioning State"
foreach ($hub in $hubs) {
    $provState = (Invoke-Az @('network', 'vhub', 'show', '-g', $ResourceGroup, '-n', $hub, '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
    $rtState   = (Invoke-Az @('network', 'vhub', 'show', '-g', $ResourceGroup, '-n', $hub, '--query', 'routingState', '-o', 'tsv')) -replace '\s',''
    if ($provState -eq 'Succeeded') { Write-Ok "$hub provisioningState=$provState" }
    else                             { Write-Fail "$hub provisioningState=$provState  (expected Succeeded)" }
    if ($rtState -eq 'Provisioned') { Write-Ok "$hub routingState=$rtState" }
    else                             { Write-Fail "$hub routingState=$rtState  (expected Provisioned)" }
}

# ---------------------------------------------------------------------------
# Section 3 — hubRoutingPreference == ExpressRoute
# ---------------------------------------------------------------------------
Write-Hdr "3. Hub Routing Preference (expected: ExpressRoute)"
foreach ($hub in $hubs) {
    $hrp = (Invoke-Az @('network', 'vhub', 'show', '-g', $ResourceGroup, '-n', $hub, '--query', 'hubRoutingPreference', '-o', 'tsv')) -replace '\s',''
    if ($hrp -eq 'ExpressRoute') { Write-Ok "$hub hubRoutingPreference=$hrp" }
    else                          { Write-Fail "$hub hubRoutingPreference=$hrp  (expected ExpressRoute)" }
}

# ---------------------------------------------------------------------------
# Section 4 — Azure Firewall per hub
# ---------------------------------------------------------------------------
Write-Hdr "4. Azure Firewall per Hub"
$hubFwId = @{}
foreach ($hub in $hubs) {
    $fwName  = "$hub-azfw"
    $fwState = (Invoke-Az @('network', 'firewall', 'show', '-g', $ResourceGroup, '-n', $fwName, '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
    $fwId    = (Invoke-Az @('network', 'firewall', 'show', '-g', $ResourceGroup, '-n', $fwName, '--query', 'id', '-o', 'tsv')) -replace '\s',''
    if ($fwState -eq 'Succeeded') {
        Write-Ok "$fwName exists (provisioningState=$fwState)"
        $hubFwId[$hub] = $fwId
    } else {
        Write-Fail "$fwName not found or not Succeeded (state='$fwState')"
        $hubFwId[$hub] = ''
    }
}

# ---------------------------------------------------------------------------
# Section 5 — Firewall policy per hub
# ---------------------------------------------------------------------------
Write-Hdr "5. Firewall Policy per Hub"
$hubPolicy = @{}
foreach ($hub in $hubs) {
    $polName  = "$hub-fwpolicy"
    $polState = (Invoke-Az @('network', 'firewall', 'policy', 'show', '-g', $ResourceGroup, '-n', $polName, '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
    if ($polState -eq 'Succeeded') {
        Write-Ok "$polName exists (provisioningState=$polState)"
        $hubPolicy[$hub] = $polName
    } else {
        Write-Fail "$polName not found or not Succeeded (state='$polState')"
        $hubPolicy[$hub] = ''
    }
}

# ---------------------------------------------------------------------------
# Section 6 — Rule collection group + allow-all rule
# ---------------------------------------------------------------------------
Write-Hdr "6. Firewall Policy Rule Collection Group + allow-all Rule"
foreach ($hub in $hubs) {
    $polName = $hubPolicy[$hub]
    if (-not $polName) { Write-Warn "${hub}: policy not found, skipping RCG check"; continue }

    $rcgName  = 'default-allow-all-rcg'
    $rcgState = (Invoke-Az @('network', 'firewall', 'policy', 'rule-collection-group', 'show',
        '-g', $ResourceGroup, '--policy-name', $polName, '-n', $rcgName,
        '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''

    if ($rcgState -eq 'Succeeded') {
        Write-Ok "$polName / $rcgName exists (provisioningState=$rcgState)"
    } else {
        Write-Fail "$polName / $rcgName not found (state='$rcgState')"
        continue
    }

    # Verify allow-all rule fields
    $ruleJson = Invoke-Az @('network', 'firewall', 'policy', 'rule-collection-group', 'show',
        '-g', $ResourceGroup, '--policy-name', $polName, '-n', $rcgName,
        '--query', "ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]",
        '-o', 'json')

    if (-not $ruleJson -or $ruleJson -eq 'null') {
        Write-Fail "$polName / ${rcgName}: 'allow-all' rule not found in 'allow-all-network' collection"
        continue
    }

    try {
        $rule = $ruleJson | ConvertFrom-Json
        $ruleProto = $rule.ipProtocols[0]
        $ruleSrc   = $rule.sourceAddresses[0]
        $ruleDst   = $rule.destinationAddresses[0]
        $rulePort  = $rule.destinationPorts[0]
        if ($ruleProto -eq 'Any' -and $ruleSrc -eq '*' -and $ruleDst -eq '*' -and $rulePort -eq '*') {
            Write-Ok "${polName}: allow-all rule: proto=Any src=* dst=* ports=* [ALLOW]"
        } else {
            Write-Fail "${polName}: allow-all rule mismatch — proto=$ruleProto src=$ruleSrc dst=$ruleDst ports=$rulePort"
        }
    } catch {
        Write-Warn "${polName}: could not parse allow-all rule JSON"
    }
}

# ---------------------------------------------------------------------------
# Section 7 — Routing Intent per hub
# ---------------------------------------------------------------------------
Write-Hdr "7. Routing Intent per Hub"
foreach ($hub in $hubs) {
    $riName  = "$hub-ri"
    $riState = (Invoke-Az @('network', 'vhub', 'routing-intent', 'show', '-g', $ResourceGroup,
        '--vhub', $hub, '-n', $riName, '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
    if ($riState -eq 'Succeeded') { Write-Ok "$riName provisioningState=$riState" }
    else                           { Write-Fail "$riName provisioningState='$riState'  (expected Succeeded)" }

    Write-Host "     Routing policies for ${riName}:"
    Invoke-Az @('network', 'vhub', 'routing-intent', 'show', '-g', $ResourceGroup,
        '--vhub', $hub, '-n', $riName,
        '--query', 'routingPolicies[].{name:name, destinations:destinations, nextHop:nextHop}',
        '-o', 'table') | ForEach-Object { Write-Host "     $_" }

    $hasPrivate  = (Invoke-Az @('network', 'vhub', 'routing-intent', 'show', '-g', $ResourceGroup,
        '--vhub', $hub, '-n', $riName,
        "--query", "length(routingPolicies[?contains(destinations,'PrivateTraffic')])",
        '-o', 'tsv')) -replace '\s',''
    $hasInternet = (Invoke-Az @('network', 'vhub', 'routing-intent', 'show', '-g', $ResourceGroup,
        '--vhub', $hub, '-n', $riName,
        "--query", "length(routingPolicies[?contains(destinations,'Internet')])",
        '-o', 'tsv')) -replace '\s',''

    $modeStr = if ([int]($hasPrivate -replace '\D','0') -gt 0 -and [int]($hasInternet -replace '\D','0') -gt 0) {
        "Private + Internet (both)"
    } elseif ([int]($hasPrivate -replace '\D','0') -gt 0) {
        "Private only"
    } elseif ([int]($hasInternet -replace '\D','0') -gt 0) {
        "Internet only"
    } else {
        "(no Private or Internet destinations detected)"
    }
    Write-Host "     Mode: $modeStr"
}

# ---------------------------------------------------------------------------
# Section 8 — ER Gateways (optional per hub)
# ---------------------------------------------------------------------------
Write-Hdr "8. ExpressRoute Gateways (where deployed)"
$hubErgw = @{}
foreach ($hub in $hubs) {
    $ergwName  = "$hub-ergw"
    $ergwState = (Invoke-Az @('network', 'express-route', 'gateway', 'show', '-g', $ResourceGroup,
        '-n', $ergwName, '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
    if ($ergwState -eq 'Succeeded') {
        Write-Ok "$ergwName exists (provisioningState=$ergwState)"
        $hubErgw[$hub] = $ergwName
    } elseif (-not $ergwState) {
        Write-Warn "$ergwName not found for $hub (hub may be private-only — skipping)"
        $hubErgw[$hub] = ''
    } else {
        Write-Fail "$ergwName state='$ergwState'  (expected Succeeded)"
        $hubErgw[$hub] = ''
    }
}

# ---------------------------------------------------------------------------
# Section 9 — ER Circuits
# ---------------------------------------------------------------------------
Write-Hdr "9. ExpressRoute Circuits"
$circuitsRaw = Invoke-Az @('network', 'express-route', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'tsv')
$circuits = @($circuitsRaw | Where-Object { $_ -ne '' } | Sort-Object)

if ($circuits.Count -eq 0) {
    Write-Warn "No ExpressRoute circuits found in resource group $ResourceGroup"
} else {
    foreach ($circuit in $circuits) {
        Write-Host "  --- Circuit: $circuit ---"
        Invoke-Az @('network', 'express-route', 'show', '-g', $ResourceGroup, '-n', $circuit,
            '--query', '{Name:name, CircuitProvisioningState:circuitProvisioningState, ServiceProviderProvisioningState:serviceProviderProvisioningState, ServiceKey:serviceKey}',
            '-o', 'table') | ForEach-Object { Write-Host "  $_" }
        $circProv = (Invoke-Az @('network', 'express-route', 'show', '-g', $ResourceGroup, '-n', $circuit,
            '--query', 'circuitProvisioningState', '-o', 'tsv')) -replace '\s',''
        if ($circProv -eq 'Enabled') { Write-Ok "$circuit circuitProvisioningState=$circProv" }
        else { Write-Warn "$circuit circuitProvisioningState=$circProv  (may be Disabled if not yet provisioned by provider)" }
    }
}

# ---------------------------------------------------------------------------
# Section 10 — ER Gateway connection state
# ---------------------------------------------------------------------------
Write-Hdr "10. ExpressRoute Gateway Connections"
$anyErgw = $false
foreach ($hub in $hubs) {
    $ergwName = $hubErgw[$hub]
    if (-not $ergwName) { continue }
    $anyErgw = $true
    Write-Host "  --- Connections for gateway: $ergwName ---"
    Invoke-Az @('network', 'express-route', 'gateway', 'connection', 'list', '-g', $ResourceGroup,
        '--gateway-name', $ergwName,
        '--query', '[].{Name:name, ProvisioningState:provisioningState, ConnectionState:connectionStatus}',
        '-o', 'table') | ForEach-Object { Write-Host "  $_" }

    $connNames = @((Invoke-Az @('network', 'express-route', 'gateway', 'connection', 'list', '-g', $ResourceGroup,
        '--gateway-name', $ergwName, '--query', '[].name', '-o', 'tsv')) | Where-Object { $_ -ne '' })
    if ($connNames.Count -eq 0) {
        Write-Warn "${ergwName}: no connections found"
    } else {
        foreach ($connName in $connNames) {
            $connState = (Invoke-Az @('network', 'express-route', 'gateway', 'connection', 'show',
                '-g', $ResourceGroup, '--gateway-name', $ergwName, '-n', $connName,
                '--query', 'provisioningState', '-o', 'tsv')) -replace '\s',''
            if ($connState -eq 'Succeeded') { Write-Ok "$ergwName / $connName provisioningState=$connState" }
            else { Write-Warn "$ergwName / $connName provisioningState='$connState'" }
        }
    }
}
if (-not $anyErgw) { Write-Warn "No ER gateways deployed — skipping connection checks" }

# ---------------------------------------------------------------------------
# Section 11 — Spoke VNet hub connections
# ---------------------------------------------------------------------------
Write-Hdr "11. Spoke VNet Hub Connections"
foreach ($hub in $hubs) {
    Write-Host "  --- Hub: $hub ---"
    Invoke-Az @('network', 'vhub', 'connection', 'list', '-g', $ResourceGroup, '--vhub-name', $hub,
        '--query', '[].{Name:name, ProvisioningState:provisioningState}',
        '-o', 'table') | ForEach-Object { Write-Host "  $_" }
    $connCount = (Invoke-Az @('network', 'vhub', 'connection', 'list', '-g', $ResourceGroup,
        '--vhub-name', $hub, '--query', 'length([])', '-o', 'tsv')) -replace '\D',''
    if ([int]($connCount) -gt 0) { Write-Ok "$hub has $connCount spoke connection(s)" }
    else                           { Write-Warn "${hub}: no spoke connections found" }

    # Assert enableInternetSecurity (Propagate Default Route) for internetOnly/both RI modes.
    $hasInternetRi = (Invoke-Az @('network', 'vhub', 'routing-intent', 'show', '-g', $ResourceGroup,
        '--vhub', $hub, '-n', "$hub-ri",
        '--query', "length(routingPolicies[?contains(destinations,'Internet')])",
        '-o', 'tsv')) -replace '\D',''
    if ([int]($hasInternetRi -replace '\D','0') -gt 0) {
        $spokeConnNames = @((Invoke-Az @('network', 'vhub', 'connection', 'list', '-g', $ResourceGroup,
            '--vhub-name', $hub, '--query', '[].name', '-o', 'tsv')) | Where-Object { $_ -ne '' })
        foreach ($spokeConn in $spokeConnNames) {
            $isecVal = (Invoke-Az @('network', 'vhub', 'connection', 'show', '-g', $ResourceGroup,
                '--vhub-name', $hub, '-n', $spokeConn,
                '--query', 'enableInternetSecurity', '-o', 'tsv')) -replace '\s',''
            if ($isecVal -eq 'true') {
                Write-Ok "$hub / $spokeConn enableInternetSecurity=true (required for internet RI mode)"
            } else {
                Write-Fail "$hub / $spokeConn enableInternetSecurity=$isecVal (expected true — internet/both RI mode requires Propagate Default Route)"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Section 12 — Ubuntu VMs power state
# ---------------------------------------------------------------------------
Write-Hdr "12. VM Power State"
$vmsRaw = Invoke-Az @('vm', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'tsv')
$vms = @($vmsRaw | Where-Object { $_ -ne '' } | Sort-Object)

if ($vms.Count -eq 0) {
    Write-Warn "No VMs found in resource group $ResourceGroup"
} else {
    Write-Host "  Public IPs:"
    Invoke-Az @('network', 'public-ip', 'list', '-g', $ResourceGroup,
        '--query', '[].{Name:name, IP:ipAddress}', '-o', 'table') | ForEach-Object { Write-Host "    $_" }
    Write-Host ""
    Write-Host "  Private IPs:"
    $nicNames = @((Invoke-Az @('network', 'nic', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'tsv')) | Where-Object { $_ -ne '' })
    foreach ($nicname in $nicNames) {
        $privIp = (Invoke-Az @('network', 'nic', 'show', '-g', $ResourceGroup, '-n', $nicname,
            '--query', 'ipConfigurations[0].privateIPAddress', '-o', 'tsv')) -replace '\s',''
        Write-Host "    $nicname : $privIp"
    }
    Write-Host ""
    foreach ($vm in $vms) {
        $power = (Invoke-Az @('vm', 'get-instance-view', '-g', $ResourceGroup, '-n', $vm,
            '--query', "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]",
            '-o', 'tsv')) -replace '\s{2,}',' '
        if ($power -match 'running') { Write-Ok "$vm powerState='$power'" }
        else                          { Write-Fail "$vm powerState='$power'  (expected 'VM running')" }
    }
}

# ---------------------------------------------------------------------------
# Section 13 — Effective routes
# ---------------------------------------------------------------------------
Write-Hdr "13. Effective Routes"

Write-Host ""
Write-Host "  --- NIC Effective Routes ---"
foreach ($nicname in $nicNames) {
    Write-Host ""
    Write-Host "  === NIC: $nicname ==="
    Invoke-Az @('network', 'nic', 'show-effective-route-table', '-g', $ResourceGroup, '--name', $nicname,
        '--output', 'table') | ForEach-Object { Write-Host "  $_" }
}

Write-Host ""
Write-Host "  --- vHub Effective Route Tables ---"
foreach ($hub in $hubs) {
    $rtIds = @((Invoke-Az @('network', 'vhub', 'route-table', 'list', '--vhub-name', $hub,
        '-g', $ResourceGroup, '--query', '[].id', '-o', 'tsv')) | Where-Object { $_ -ne '' })
    foreach ($rtId in $rtIds) {
        $rtName = $rtId.Split('/')[-1]
        if ($rtName -eq 'noneRouteTable') { continue }
        Write-Host ""
        Write-Host "  === vHub: $hub | RouteTable: $rtName ==="
        Invoke-Az @('network', 'vhub', 'get-effective-routes', '-g', $ResourceGroup, '-n', $hub,
            '--resource-type', 'RouteTable',
            '--resource-id', $rtId,
            '--query', 'value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}',
            '--output', 'table') | ForEach-Object { Write-Host "  $_" }
    }
}

Write-Host ""
Write-Host "  --- Azure Firewall Effective Routes per Hub ---"
foreach ($hub in $hubs) {
    $fwId = $hubFwId[$hub]
    if (-not $fwId) { continue }
    $fwName = "$hub-azfw"
    Write-Host ""
    Write-Host "  === vHub: $hub | Firewall: $fwName ==="
    Invoke-Az @('network', 'vhub', 'get-effective-routes', '-g', $ResourceGroup, '-n', $hub,
        '--resource-type', 'AzureFirewalls',
        '--resource-id', $fwId,
        '--query', 'value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}',
        '--output', 'table') | ForEach-Object { Write-Host "  $_" }
}

# ---------------------------------------------------------------------------
# Section 14 — Hub connection status
# ---------------------------------------------------------------------------
Write-Hdr "14. Hub Connection Status"
foreach ($hub in $hubs) {
    Write-Host ""
    Write-Host "  === Hub: $hub ==="
    Invoke-Az @('network', 'vhub', 'connection', 'list', '-g', $ResourceGroup, '--vhub-name', $hub,
        '--query', '[].{Name:name, ProvisioningState:provisioningState}',
        '-o', 'table') | ForEach-Object { Write-Host "  $_" }
}

# ---------------------------------------------------------------------------
# Section 15 — Connectivity test hints
# ---------------------------------------------------------------------------
Write-Hdr "15. Connectivity Test Hints"
Write-Host ""
Write-Host "  Private IPs of spoke VMs:"
$vmPrivMap = @{}
foreach ($vm in $vms) {
    $privIp = (Invoke-Az @('vm', 'list-ip-addresses', '-g', $ResourceGroup, '-n', $vm,
        '--query', '[0].virtualMachine.network.privateIpAddresses[0]', '-o', 'tsv')) -replace '\s',''
    $pubIp  = (Invoke-Az @('vm', 'list-ip-addresses', '-g', $ResourceGroup, '-n', $vm,
        '--query', '[0].virtualMachine.network.publicIpAddresses[0].ipAddress', '-o', 'tsv')) -replace '\s',''
    Write-Host "    $vm : private=$privIp  public=$pubIp"
    $vmPrivMap[$vm] = $privIp
}

Write-Host ""
Write-Host "  Install tools on each VM if missing:"
Write-Host "    sudo apt-get install -y traceroute iputils-ping curl"
Write-Host ""
Write-Host "  Cross-spoke ping (from any VM):"
foreach ($vm in $vms) {
    $privIp = $vmPrivMap[$vm]
    if ($privIp) { Write-Host "    ping $privIp   # $vm" }
}

Write-Host ""
Write-Host "  NOTE: Under Routing Intent (private), ALL inter-spoke/inter-hub traffic"
Write-Host "        traverses the Azure Firewall of the SOURCE hub. Use traceroute to"
Write-Host "        verify the firewall private IP appears in the path."
Write-Host "  NOTE: Under Routing Intent (internet), Internet-bound traffic also traverses"
Write-Host "        the hub Azure Firewall. Check portal FW logs if access is blocked."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Hdr "SUMMARY"
$total = $script:passCount + $script:failCount
Write-Host "  $($script:passCount) / $total checks passed"
Write-Host "  $($script:failCount) / $total checks failed"
Write-Host ""
if ($script:failCount -eq 0) {
    Write-Host "  [ALL CHECKS PASSED] Lab deployment looks healthy." -ForegroundColor Green
} else {
    Write-Host "  [ATTENTION] $($script:failCount) check(s) failed. Review [FAIL] items above." -ForegroundColor Red
}
Write-Host ""
