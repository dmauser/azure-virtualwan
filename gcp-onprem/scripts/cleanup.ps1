#Requires -Version 7.0
<#
.SYNOPSIS
  Tear down the gcp-onprem lab (terraform destroy).

.DESCRIPTION
  Prompts for confirmation, then runs terraform destroy.
  Also reminds you to manually delete Megaport VXCs and warns about
  ongoing interconnect VLAN attachment costs.

  WARNING — LAB ONLY. Not for production use.

.PARAMETER Project
  GCP project ID. Prompted interactively if omitted.
  Alternatively set env var GCP_PROJECT.

.PARAMETER Yes
  Skip all confirmation prompts (non-interactive mode).

.EXAMPLE
  .\cleanup.ps1
  .\cleanup.ps1 -Project my-gcp-project -Yes
#>

param(
  [string]$Project = "",
  [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Prerequisite check — verify required tooling is installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# Use 'Az' (PowerShell module) for scripts that use Connect-AzAccount/Az cmdlets,
# 'az' for Azure CLI, plus 'terraform' / 'gcloud' / 'jq' as needed.
# ---------------------------------------------------------------------------
function Invoke-LabPrereqCheck {
    param([Parameter(Mandatory)][string[]]$Tools)

    $missing = foreach ($t in $Tools) {
        $present = if ($t -eq 'Az') {
            [bool](Get-Module -ListAvailable -Name Az.Accounts)
        } else {
            [bool](Get-Command $t -ErrorAction SilentlyContinue)
        }
        if (-not $present) { $t }
    }
    if (-not $missing) { return }

    Write-Host "[prereq] Missing required tool(s): $($missing -join ', ')" -ForegroundColor Yellow
    foreach ($t in $missing) {
        switch ($t) {
            'az'        { Write-Host '  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli' }
            'terraform' { Write-Host '  - Terraform:         https://developer.hashicorp.com/terraform/install' }
            'gcloud'    { Write-Host '  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install' }
            'jq'        { Write-Host '  - jq:                https://jqlang.github.io/jq/download/' }
            'Az'        { Write-Host '  - Az PowerShell:     Install-Module Az -Scope CurrentUser' }
            default     { Write-Host "  - ${t}: install via your OS package manager" }
        }
    }

    $interactive = $true
    if ($env:LAB_NON_INTERACTIVE -eq '1' -or -not [Environment]::UserInteractive) { $interactive = $false }
    if (-not $interactive) {
        Write-Host '[prereq] Non-interactive — install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }

    $ans = Read-Host '[prereq] Attempt to install the missing tool(s) now? [y/N]'
    if ($ans -notmatch '^[Yy]') {
        Write-Host '[prereq] Install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }

    foreach ($t in $missing) {
        Write-Host "[prereq] Installing '$t' ..."
        if ($t -eq 'Az') {
            try { Install-Module Az -Scope CurrentUser -Force -AllowClobber } catch { Write-Host $_ -ForegroundColor Red }
            continue
        }
        $wingetId = switch ($t) {
            'az'        { 'Microsoft.AzureCLI' }
            'terraform' { 'Hashicorp.Terraform' }
            'gcloud'    { 'Google.CloudSDK' }
            'jq'        { 'jqlang.jq' }
            default     { $null }
        }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if ($wingetId) { winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements }
            else { winget install $t -e --accept-source-agreements --accept-package-agreements }
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install $t -y
        } else {
            Write-Host "[prereq] No winget/choco found — install '$t' manually (see link above)." -ForegroundColor Red
        }
    }

    $still = foreach ($t in $Tools) {
        $present = if ($t -eq 'Az') { [bool](Get-Module -ListAvailable -Name Az.Accounts) } else { [bool](Get-Command $t -ErrorAction SilentlyContinue) }
        if (-not $present) { $t }
    }
    if ($still) {
        Write-Host "[prereq] Still missing: $($still -join ', '). You may need to restart the shell after install, then re-run." -ForegroundColor Red
        exit 1
    }
}
# Replace the tool list below with the tools THIS script actually needs:
Invoke-LabPrereqCheck -Tools @('gcloud','terraform')


$ScriptDir    = $PSScriptRoot
$TerraformDir = Join-Path $ScriptDir "..\terraform"

# ---------- Helpers ----------------------------------------------------------
function Log([string]$m)  { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

function Confirm-Continue([string]$Prompt) {
  if ($Yes) { return }
  $ans = Read-Host "$Prompt [y/N]"
  if ($ans -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

# ---------- Megaport reminder -----------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  IMPORTANT — READ BEFORE CONTINUING" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  1. Interconnect VLAN attachments incur hourly cost even when" -ForegroundColor Yellow
Write-Host "     the circuit is not passing traffic. Destroy removes them." -ForegroundColor Yellow
Write-Host "  2. Megaport VXCs are NOT managed by Terraform and will NOT be" -ForegroundColor Yellow
Write-Host "     deleted by this script." -ForegroundColor Yellow
Write-Host "     --> Manually delete VXCs in the Megaport portal BEFORE or" -ForegroundColor Yellow
Write-Host "         AFTER running this cleanup to avoid orphan charges." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

Confirm-Continue "Proceed with 'terraform destroy' for the gcp-onprem lab?"

# ---------- Terraform destroy -----------------------------------------------
Push-Location $TerraformDir
try {
  Log "Running terraform destroy..."
  if ($Yes) {
    terraform destroy -auto-approve
  } else {
    terraform destroy
  }
  Ok "terraform destroy complete"
  Write-Host ""
  Write-Host "Cleanup complete." -ForegroundColor Green
  Write-Host "Remember to delete your Megaport VXCs manually in the Megaport portal." -ForegroundColor Yellow
}
finally {
  Pop-Location
}