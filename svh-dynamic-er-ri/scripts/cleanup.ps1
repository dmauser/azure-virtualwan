#Requires -Version 7.0
<#
.SYNOPSIS
  Cleanup for svh-dynamic-er-ri (Secured Virtual WAN lab).

.DESCRIPTION
  Removes lab resources with confirmation prompts.

  ⚠️  ER circuits and gateways accrue hourly cost.
  ⚠️  Provider-side VXCs / cross-connects must be removed separately FIRST.

.PARAMETER Rg
  Resource group to clean up. Prompted if not provided.

.PARAMETER VmsOnly
  Delete only VMs, NICs, and public IPs.

.PARAMETER ErOnly
  Delete ER gateway connections, ER gateways, and ER circuits.

.PARAMETER All
  Delete the entire resource group (default if no mode switch is specified).

.EXAMPLE
  .\cleanup.ps1
  .\cleanup.ps1 -Rg lab-svh-dynamic-er-ri
  .\cleanup.ps1 -Rg lab-svh-dynamic-er-ri -VmsOnly
  .\cleanup.ps1 -Rg lab-svh-dynamic-er-ri -ErOnly
  .\cleanup.ps1 -Rg lab-svh-dynamic-er-ri -All
#>

param(
  [string]$Rg      = "",
  [switch]$VmsOnly,
  [switch]$ErOnly,
  [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- Banner ----------------------------------------------------------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗"
Write-Host "║        svh-dynamic-er-ri — Lab Cleanup                          ║"
Write-Host "╠══════════════════════════════════════════════════════════════════╣"
Write-Host "║  ⚠️  ER circuits and gateways accrue hourly cost.                ║"
Write-Host "║  ⚠️  Provider-side VXCs must be removed separately.              ║"
Write-Host "╚══════════════════════════════════════════════════════════════════╝"
Write-Host ""

# Prompt for RG if not provided
if ([string]::IsNullOrWhiteSpace($Rg)) {
  $Rg = Read-Host "  Resource group to clean up [lab-svh-dynamic-er-ri]"
  if ([string]::IsNullOrWhiteSpace($Rg)) { $Rg = "lab-svh-dynamic-er-ri" }
}

# Verify RG exists
$rgCheck = az group show -n $Rg 2>$null
if ($LASTEXITCODE -ne 0) {
  throw "Resource group '$Rg' not found or not accessible."
}

# Determine mode (default = all)
$Mode = "all"
if ($VmsOnly) { $Mode = "vms-only" }
elseif ($ErOnly) { $Mode = "er-only" }

# ---------- Mode: delete entire RG ------------------------------------------
if ($Mode -eq "all") {
  Write-Host ""
  Write-Host "  Mode: DELETE ENTIRE RESOURCE GROUP"
  Write-Host "  Resource group: $Rg"
  Write-Host ""
  Write-Host "  This will permanently delete ALL resources including:"
  Write-Host "    * All vHubs, vWAN, Azure Firewalls"
  Write-Host "    * All ExpressRoute circuits (billing stops immediately)"
  Write-Host "    * All VMs, VNets, Key Vault"
  Write-Host ""
  $confirm = Read-Host "  Type 'yes' to confirm deletion of '$Rg'"
  if ($confirm -ne "yes") {
    Write-Host "  Cleanup cancelled."
    return
  }
  Write-Host ""
  Write-Host "  Deleting resource group $Rg (--no-wait, runs in background)..."
  az group delete -n $Rg --yes --no-wait
  Write-Host "  Deletion submitted. Monitor with:"
  Write-Host "    az group show -n $Rg --query provisioningState -o tsv"
  Write-Host ""
  Write-Host "  NOTE: Key Vault enters soft-delete (7-day retention). To purge:"
  Write-Host "    az keyvault list-deleted --query '[].name' -o tsv"
  Write-Host "    az keyvault purge -n <KV_NAME>"
  return
}

# ---------- Mode: VMs only --------------------------------------------------
if ($Mode -eq "vms-only") {
  Write-Host ""
  Write-Host "  Mode: VMs ONLY (delete VMs, NICs, and public IPs)"
  Write-Host "  Resource group: $Rg"
  Write-Host ""

  $vmIds = (az vm list -g $Rg --query '[].id' -o tsv 2>$null) -split "`n" | Where-Object { $_ }
  if (-not $vmIds) {
    Write-Host "  No VMs found in $Rg. Nothing to do."
    return
  }

  Write-Host "  VMs found:"
  az vm list -g $Rg --query '[].{Name:name,Region:location}' -o table
  Write-Host ""
  $confirm = Read-Host "  Delete all VMs, NICs, and public IPs? Type 'yes' to confirm"
  if ($confirm -ne "yes") {
    Write-Host "  Cleanup cancelled."
    return
  }

  # Collect NIC and PIP IDs before deleting VMs
  $nicIds = @(); $pipIds = @()
  foreach ($vmId in $vmIds) {
    $vmName = Split-Path $vmId -Leaf
    $nicId  = (az vm show --id $vmId `
      --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>$null)
    if ($nicId) { $nicIds += $nicId }
    $pipId  = (az network public-ip show -g $Rg `
      -n "pip-${vmName}" --query id -o tsv 2>$null)
    if ($pipId) { $pipIds += $pipId }
  }

  Write-Host "  Deleting VMs..."
  az vm delete --ids @vmIds --yes --output none
  Write-Host "  VMs deleted."

  if ($nicIds) {
    Write-Host "  Deleting NICs..."
    az network nic delete --ids @nicIds --output none
    Write-Host "  NICs deleted."
  }
  if ($pipIds) {
    Write-Host "  Deleting public IPs..."
    az network public-ip delete --ids @pipIds --output none
    Write-Host "  Public IPs deleted."
  }
  Write-Host "  VM cleanup complete."
  return
}

# ---------- Mode: ER only ---------------------------------------------------
if ($Mode -eq "er-only") {
  Write-Host ""
  Write-Host "  Mode: ER ONLY (delete ER connections, gateways, and circuits)"
  Write-Host "  Resource group: $Rg"
  Write-Host ""
  Write-Host "  ⚠️  Provider-side VXCs / cross-connects must be deprovisioned FIRST."
  Write-Host "  ⚠️  Deleting the circuit while the provider VXC is active may orphan the order."
  Write-Host ""

  $erGwNames = (az resource list -g $Rg `
    --resource-type Microsoft.Network/expressRouteGateways `
    --query '[].name' -o tsv 2>$null) -split "`n" | Where-Object { $_ }
  $erCircNames = (az resource list -g $Rg `
    --resource-type Microsoft.Network/expressRouteCircuits `
    --query '[].name' -o tsv 2>$null) -split "`n" | Where-Object { $_ }

  if (-not $erGwNames -and -not $erCircNames) {
    Write-Host "  No ER gateways or circuits found in $Rg. Nothing to do."
    return
  }

  Write-Host "  ER Gateways:"
  if ($erGwNames) { $erGwNames | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    (none)" }
  Write-Host "  ER Circuits:"
  if ($erCircNames) { $erCircNames | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    (none)" }
  Write-Host ""
  $confirm = Read-Host "  Delete all ER connections, gateways, and circuits? Type 'yes' to confirm"
  if ($confirm -ne "yes") {
    Write-Host "  Cleanup cancelled."
    return
  }

  # Delete ER gateway connections first
  if ($erGwNames) {
    foreach ($gw in $erGwNames) {
      $connIds = (az network express-route gateway connection list `
        -g $Rg --gateway-name $gw --query '[].name' -o tsv 2>$null) -split "`n" | Where-Object { $_ }
      foreach ($conn in $connIds) {
        Write-Host "  Deleting connection $conn in gateway $gw..."
        az network express-route gateway connection delete `
          --name $conn -g $Rg --gateway-name $gw --yes -o none
      }
    }
    Write-Host "  ER gateway connections deleted."

    Write-Host "  Deleting ER gateways..."
    $gwJobs = foreach ($gw in $erGwNames) {
      Start-Job -ScriptBlock {
        param($Rg,$gw)
        az network express-route gateway delete -g $Rg -n $gw --yes -o none
      } -ArgumentList $Rg,$gw
    }
    $gwJobs | Wait-Job | Remove-Job
    Write-Host "  ER gateways deleted."
  }

  # Delete ER circuits
  if ($erCircNames) {
    Write-Host "  Deleting ER circuits..."
    $circJobs = foreach ($circ in $erCircNames) {
      Start-Job -ScriptBlock {
        param($Rg,$circ)
        az network express-route delete -g $Rg -n $circ --yes -o none
      } -ArgumentList $Rg,$circ
    }
    $circJobs | Wait-Job | Remove-Job
    Write-Host "  ER circuits deleted."
  }

  Write-Host "  ER cleanup complete."
}
