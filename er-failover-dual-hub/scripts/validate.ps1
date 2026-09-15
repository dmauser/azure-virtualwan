<#
.SYNOPSIS
    Post-deployment health check for the ExpressRoute failover lab.

.EXAMPLE
    ./validate.ps1 -ResourceGroup rg-er-failover
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$Prefix = 'erfo'
)

$ErrorActionPreference = 'Continue'
$script:Failures = 0

function Pass($msg) { Write-Host "  [ OK ] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Failures++ }

Write-Host '== Virtual WAN =='
$b2b = az network vwan show -g $ResourceGroup -n "$Prefix-vwan" --query allowBranchToBranchTraffic -o tsv 2>$null
if ($b2b -eq 'true') {
    Pass 'allowBranchToBranchTraffic is true (required for hub-to-hub failover)'
}
else {
    Fail "allowBranchToBranchTraffic is '$b2b' — failover will NOT work"
}

Write-Host ''
Write-Host '== Virtual Hubs =='
foreach ($key in @('wus2', 'scus')) {
    $hub   = "$Prefix-hub-$key"
    $pref  = az network vhub show -g $ResourceGroup -n $hub --query hubRoutingPreference -o tsv 2>$null
    $state = az network vhub show -g $ResourceGroup -n $hub --query provisioningState -o tsv 2>$null
    if ($state -eq 'Succeeded') { Pass "$hub provisioningState=Succeeded" } else { Fail "$hub provisioningState=$state" }
    if ($pref -eq 'ASPath') { Pass "$hub hubRoutingPreference=ASPath" } else { Fail "$hub hubRoutingPreference=$pref (expected ASPath)" }
}

Write-Host ''
Write-Host '== Spoke connections =='
foreach ($key in @('wus2', 'scus')) {
    $hub   = "$Prefix-hub-$key"
    $conn  = "$Prefix-spoke-$key-conn"
    $state = az network vhub connection show --vhub-name $hub -g $ResourceGroup -n $conn --query provisioningState -o tsv 2>$null
    if ($state -eq 'Succeeded') { Pass "$conn Succeeded" } else { Fail "$conn is $state" }
}

Write-Host ''
Write-Host '== ExpressRoute circuits =='
foreach ($ckt in @("$Prefix-er-chicago", "$Prefix-er-dallas")) {
    $pstate = az network express-route show -g $ResourceGroup -n $ckt --query serviceProviderProvisioningState -o tsv 2>$null
    if ($pstate -eq 'Provisioned') { Pass "$ckt provider state Provisioned" } else { Fail "$ckt provider state $pstate" }

    $peer = az network express-route peering list -g $ResourceGroup --circuit-name $ckt --query "length([?name=='AzurePrivatePeering'])" -o tsv 2>$null
    if ($peer -and $peer -ne '0') { Pass "$ckt AzurePrivatePeering configured" } else { Fail "$ckt AzurePrivatePeering missing" }
}

Write-Host ''
Write-Host '== ExpressRoute gateways and connections =='
$circuitFor = @{ wus2 = 'chicago'; scus = 'dallas' }
foreach ($key in @('wus2', 'scus')) {
    $gw   = "$Prefix-hub-$key-ergw"
    $conn = "$Prefix-erconn-$($circuitFor[$key])"
    $gstate = az network express-route gateway show -g $ResourceGroup -n $gw --query provisioningState -o tsv 2>$null
    if ($gstate -eq 'Succeeded') { Pass "$gw Succeeded" } else { Fail "$gw is $gstate" }

    $cstate = az network express-route gateway connection show --gateway-name $gw -g $ResourceGroup -n $conn --query provisioningState -o tsv 2>$null
    if ($cstate -eq 'Succeeded') { Pass "$conn Succeeded" } else { Fail "$conn is $cstate" }
}

Write-Host ''
Write-Host '== Test VMs =='
foreach ($key in @('wus2', 'scus')) {
    $vm = "$Prefix-vm-$key"
    $ps = az vm get-instance-view -g $ResourceGroup -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>$null
    if ($ps -eq 'VM running') {
        Pass "$vm running"
    }
    elseif ($ps -eq 'VM deallocated') {
        Warn "$vm is deallocated (expected when idle - start it before running failover tests)"
        Write-Host "         az vm start -g $ResourceGroup -n $vm"
    }
    else { Fail "$vm is $ps" }

    $pipId = az network nic show -g $ResourceGroup -n "nic-$vm" --query "ipConfigurations[0].publicIPAddress.id" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($pipId)) { Pass "$vm has no public IP (private-only, as designed)" }
    else { Fail "$vm still has a public IP attached" }

    $boot = az vm show -g $ResourceGroup -n $vm --query diagnosticsProfile.bootDiagnostics.enabled -o tsv 2>$null
    if ($boot -eq 'true') { Pass "$vm boot diagnostics enabled (Serial Console ready)" }
    else { Fail "$vm boot diagnostics disabled - Serial Console will not work" }

    Write-Host "         az serial-console connect -g $ResourceGroup -n $vm"
}

Write-Host ''
Write-Host '== Effective routes (hub default route tables) =='
foreach ($key in @('wus2', 'scus')) {
    $hub   = "$Prefix-hub-$key"
    $rtId  = az network vhub route-table show --vhub-name $hub -g $ResourceGroup -n defaultRouteTable --query id -o tsv 2>$null
    if ($rtId) {
        Write-Host "--- $hub ---"
        $rows = az network vhub get-effective-routes --name $hub -g $ResourceGroup --resource-type RouteTable --resource-id $rtId -o table 2>$null
        if ($rows) { $rows | ForEach-Object { Write-Host "  $_" } }
        else { Write-Host '  (no effective routes returned)' }
    }
}

Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'All checks passed. Proceed to docs/failover-tests.md.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$($script:Failures) check(s) failed. See docs/troubleshooting.md." -ForegroundColor Red
    exit 1
}
