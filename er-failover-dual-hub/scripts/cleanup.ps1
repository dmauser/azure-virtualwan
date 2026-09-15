<#
.SYNOPSIS
    Tear down the ExpressRoute failover lab.

.DESCRIPTION
    Circuits are deleted first so the provider-side VXC is released cleanly
    before the resource group goes away. Delete the VXCs in your provider portal
    too, otherwise they keep billing.

.EXAMPLE
    ./cleanup.ps1 -ResourceGroup rg-er-failover
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$Prefix = 'erfo',
    [switch]$KeepResourceGroup,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

az group show -n $ResourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to do."
    return
}

if (-not $Force) {
    Write-Host "This will DELETE the ExpressRoute failover lab in resource group '$ResourceGroup'." -ForegroundColor Yellow
    if ($KeepResourceGroup) {
        Write-Host 'The resource group itself will be kept.'
    }
    else {
        Write-Host 'The resource group itself will also be deleted.'
    }
    $confirm = Read-Host 'Type the resource group name to confirm'
    if ($confirm -ne $ResourceGroup) {
        Write-Host 'Aborted.'
        return
    }
}

Write-Host ''
Write-Host 'Deleting ExpressRoute connections...'
foreach ($key in @('wus2', 'scus')) {
    $gw = "$Prefix-hub-$key-ergw"
    $conns = az network express-route gateway connection list --gateway-name $gw -g $ResourceGroup --query '[].name' -o tsv 2>$null
    foreach ($conn in $conns) {
        if ($conn) {
            Write-Host "  $gw/$conn"
            az network express-route gateway connection delete --gateway-name $gw -g $ResourceGroup -n $conn -o none 2>$null
        }
    }
}

Write-Host 'Deleting ExpressRoute circuits (releases the provider-side VXC)...'
$circuits = az network express-route list -g $ResourceGroup --query '[].name' -o tsv 2>$null
foreach ($ckt in $circuits) {
    if ($ckt) {
        Write-Host "  $ckt"
        az network express-route delete -g $ResourceGroup -n $ckt -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not delete $ckt — check the provider side, then retry."
        }
    }
}

if ($KeepResourceGroup) {
    Write-Host 'Deleting remaining lab resources...'
    $ids = az resource list -g $ResourceGroup --query "[?tags.lab=='er-failover-dual-hub'].id" -o tsv 2>$null
    if ($ids) {
        az resource delete --ids $ids --verbose 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Some resources could not be deleted individually; delete the group instead.'
        }
    }
    Write-Host "Done. Resource group '$ResourceGroup' kept."
}
else {
    Write-Host "Deleting resource group '$ResourceGroup' (running in the background)..."
    az group delete -n $ResourceGroup --yes --no-wait
    Write-Host "Done. Track with: az group show -n $ResourceGroup"
}

Write-Host ''
Write-Host 'REMINDER: cancel the VXCs in your provider (Megaport) portal so they stop billing.' -ForegroundColor Yellow
