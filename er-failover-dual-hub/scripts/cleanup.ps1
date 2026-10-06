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
    # 'connection list' returns nothing on some CLI versions; read the child
    # collection off the gateway itself instead.
    $gwJson = az network express-route gateway show -n $gw -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
    if (-not $gwJson) { continue }
    foreach ($conn in @($gwJson.expressRouteConnections)) {
        if ($conn.name) {
            Write-Host "  $gw/$($conn.name)"
            az network express-route gateway connection delete --gateway-name $gw -g $ResourceGroup -n $conn.name -o none 2>$null
        }
    }
}

Write-Host 'Deleting ExpressRoute circuits (releases the provider-side VXC)...'
$blockedCircuits = @()
$circuits = @(az network express-route list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json)
foreach ($ckt in $circuits) {
    if (-not $ckt.name) { continue }
    Write-Host "  $($ckt.name)"

    # A previously failed delete leaves the circuit in 'Failed'; a no-op update
    # clears it (and any half-deleted peering) so the delete can be retried.
    if ($ckt.provisioningState -eq 'Failed') {
        Write-Host "    clearing Failed provisioning state..."
        az network express-route update -g $ResourceGroup -n $ckt.name -o none 2>$null
    }

    # Azure refuses to delete a circuit while the provider still has it
    # provisioned. Report that precisely rather than as a generic failure.
    if ($ckt.serviceProviderProvisioningState -eq 'Provisioned') {
        $blockedCircuits += $ckt
        Write-Warning "$($ckt.name) is still Provisioned by the service provider — deprovision the VXC in the provider portal first."
        continue
    }

    az network express-route delete -g $ResourceGroup -n $ckt.name -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        $blockedCircuits += $ckt
        Write-Warning "Could not delete $($ckt.name) — check the provider side, then retry."
    }
}

if ($blockedCircuits.Count -gt 0) {
    Write-Host ''
    Write-Warning 'The resource group cannot be fully removed until these circuits are deprovisioned by the provider:'
    foreach ($ckt in $blockedCircuits) {
        Write-Host ("    {0}  serviceKey={1}" -f $ckt.name, $ckt.serviceKey) -ForegroundColor Yellow
    }
    Write-Host '    Delete the matching VXCs in the provider portal, wait for'
    Write-Host "    serviceProviderProvisioningState to reach 'NotProvisioned', then re-run this script." -ForegroundColor Yellow
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
    if ($blockedCircuits.Count -gt 0) {
        Write-Host ''
        Write-Warning "Skipping resource group delete — it would fail while the circuits above are still provisioned."
        Write-Host "Re-run this script after the provider deprovisions them." -ForegroundColor Yellow
    }
    else {
        Write-Host "Deleting resource group '$ResourceGroup' (running in the background)..."
        az group delete -n $ResourceGroup --yes --no-wait
        Write-Host "Done. Track with: az group show -n $ResourceGroup"
    }
}

Write-Host ''
Write-Host 'REMINDER: cancel the VXCs in your provider (Megaport) portal so they stop billing.' -ForegroundColor Yellow
