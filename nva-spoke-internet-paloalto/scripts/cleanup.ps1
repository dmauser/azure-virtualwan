#Requires -Version 5.1
# =============================================================================
# cleanup.ps1 — Delete the nva-spoke-internet lab resource group.
# Usage: .\cleanup.ps1 [-Rg <resource-group>] [-Yes]
# PowerShell equivalent of cleanup.sh.
# =============================================================================

param(
    [string]$Rg  = "",
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

# Prompt for RG if not provided
if ([string]::IsNullOrWhiteSpace($Rg)) {
    $Rg = Read-Host "Resource group to delete [rg-nva-spoke-internet-pa]"
    if ([string]::IsNullOrWhiteSpace($Rg)) { $Rg = "rg-nva-spoke-internet-pa" }
}

# Verify the RG exists
$rgCheck = az group show -n $Rg --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Resource group '$Rg' not found — nothing to delete."
    exit 0
}

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗"
Write-Host "║  ⚠️  CLEANUP: This will delete ALL resources in the lab RG.  ║"
Write-Host "╚══════════════════════════════════════════════════════════════╝"
Write-Host "  Resource group : $Rg"
Write-Host ""

if (-not $Yes) {
    $Confirm = Read-Host "  Type the resource group name to confirm deletion"
    if ($Confirm -ne $Rg) {
        Write-Host "Name did not match. Aborting."
        exit 1
    }
}

Log "Deleting resource group '$Rg' (--no-wait) ..."
az group delete -n $Rg --yes --no-wait --output none
if ($LASTEXITCODE -ne 0) { throw "az group delete failed." }
Log "Deletion queued. Monitor progress:"
Write-Host "  az group show -n $Rg --query properties.provisioningState -o tsv"
