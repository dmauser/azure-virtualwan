<#
.SYNOPSIS
    Print the ExpressRoute service keys and provider provisioning state.

.DESCRIPTION
    Run this WHILE the deployment is parked on the provider-wait pollers. The
    `serviceKeys` deployment output only appears after the deployment finishes,
    which cannot happen until the circuits are provisioned — so read them here.

.EXAMPLE
    ./get-service-keys.ps1 -ResourceGroup rg-er-failover -Watch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [switch]$Watch,
    [int]$IntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'

function Show-Circuits {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
    Write-Host "ExpressRoute circuits in '$ResourceGroup'  —  $stamp"
    Write-Host ''

    $query = '[].{Circuit:name,' +
             'Provider:serviceProviderProperties.serviceProviderName,' +
             'PeeringLocation:serviceProviderProperties.peeringLocation,' +
             'Mbps:serviceProviderProperties.bandwidthInMbps,' +
             'ServiceKey:serviceKey,' +
             'ProviderState:serviceProviderProvisioningState,' +
             'CircuitState:circuitProvisioningState}'
    az network express-route list -g $ResourceGroup --query $query -o table

    Write-Host ''
    Write-Host 'Private peering status:'
    $circuits = az network express-route list -g $ResourceGroup --query '[].name' -o tsv
    foreach ($ckt in $circuits) {
        $count = az network express-route peering list -g $ResourceGroup --circuit-name $ckt `
                    --query "length([?name=='AzurePrivatePeering'])" -o tsv 2>$null
        if (-not $count -or $count -eq '0') {
            Write-Host "  ${ckt}: AzurePrivatePeering NOT configured"
        }
        else {
            Write-Host "  ${ckt}: AzurePrivatePeering present"
        }
    }
}

function Test-AllReady {
    $pending = az network express-route list -g $ResourceGroup `
                 --query "length([?serviceProviderProvisioningState!='Provisioned'])" -o tsv
    return ($pending -eq '0')
}

if ($Watch) {
    while ($true) {
        Clear-Host
        Show-Circuits
        if (Test-AllReady) {
            Write-Host ''
            Write-Host 'All circuits are Provisioned. The deployment should now create the hub connections.'
            return
        }
        Write-Host ''
        Write-Host "Waiting for the provider... refreshing in ${IntervalSeconds}s (Ctrl-C to stop)"
        Start-Sleep -Seconds $IntervalSeconds
    }
}
else {
    Show-Circuits
    Write-Host ''
    Write-Host 'Order one VXC per service key in your provider portal, then re-run with -Watch.'
}
