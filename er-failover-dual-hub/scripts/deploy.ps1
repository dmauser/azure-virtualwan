<#
.SYNOPSIS
    Deploy the ExpressRoute failover lab (two Virtual WAN hubs, two ER circuits).

.DESCRIPTION
    The deployment intentionally parks partway through while each ExpressRoute
    circuit waits for its connectivity provider. Once started, run
    ./get-service-keys.ps1 in another terminal, order the VXCs against those
    service keys, and leave this running.

.EXAMPLE
    ./deploy.ps1 -ResourceGroup rg-er-failover
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$Location = 'westus2',
    [string]$DeploymentName = 'er-failover',
    [securestring]$AdminPassword,
    [switch]$SkipProviderWait,
    [switch]$SkipCircuits,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bicepDir  = Join-Path $scriptDir '..\infra\bicep'

if (-not $AdminPassword) {
    $AdminPassword = Read-Host -Prompt 'VM admin password' -AsSecureString
}
$plainPassword = [System.Net.NetworkCredential]::new('', $AdminPassword).Password
if ([string]::IsNullOrWhiteSpace($plainPassword)) {
    throw 'Admin password is required.'
}

if (-not $SkipProviderWait) {
    Write-Host 'Checking Microsoft.ContainerInstance registration (required by the provider-wait poller)...'
    $state = az provider show --namespace Microsoft.ContainerInstance --query registrationState -o tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Host "  State is '$state'. Registering..."
        az provider register --namespace Microsoft.ContainerInstance --wait
    }
}

Write-Host "Ensuring resource group '$ResourceGroup' exists in $Location..."
az group create -n $ResourceGroup -l $Location -o none

$deployArgs = @(
    '--resource-group', $ResourceGroup
    '--name', $DeploymentName
    '--template-file', (Join-Path $bicepDir 'main.bicep')
    '--parameters', (Join-Path $bicepDir 'main.bicepparam')
    '--parameters', "adminPassword=$plainPassword"
)

if ($SkipProviderWait) {
    Write-Host 'Skipping the provider-wait poller (waitForProvider=false).'
    $deployArgs += @('--parameters', 'waitForProvider=false')
}

if ($SkipCircuits) {
    Write-Host 'Leaving the ExpressRoute circuits untouched (manageCircuits=false).'
    $deployArgs += @('--parameters', 'manageCircuits=false')
}

if ($WhatIf) {
    Write-Host 'Running what-if...'
    az deployment group what-if @deployArgs
    return
}

Write-Host @"

-------------------------------------------------------------------------------
Starting deployment '$DeploymentName' in '$ResourceGroup'.
"@

if ($SkipProviderWait) {
    Write-Host @"

The provider-wait poller is disabled, so the ExpressRoute connections are
created immediately. Make sure both circuits already report
ServiceProviderProvisioningState = Provisioned, otherwise the connections fail.
-------------------------------------------------------------------------------

"@
}
else {
    Write-Host @"

This will PAUSE partway through while each ExpressRoute circuit waits for its
connectivity provider. That is expected.

In another terminal run:

    $scriptDir\get-service-keys.ps1 -ResourceGroup $ResourceGroup

...then order one VXC per service key in your provider portal. The deployment
resumes automatically once both circuits report Provisioned.
-------------------------------------------------------------------------------

"@
}

az deployment group create @deployArgs -o none
if ($LASTEXITCODE -ne 0) { throw "Deployment failed with exit code $LASTEXITCODE." }

Write-Host ''
Write-Host 'Deployment complete. Outputs:'
az deployment group show -g $ResourceGroup -n $DeploymentName --query properties.outputs -o json
Write-Host ''
Write-Host "Next: $scriptDir\validate.ps1 -ResourceGroup $ResourceGroup"
Write-Host ''
Write-Host 'The test VMs have no public IP. Reach them with Serial Console:'
Write-Host '    az extension add --name serial-console    # one time'
Write-Host "    az serial-console connect -g $ResourceGroup -n <vm-name>"
