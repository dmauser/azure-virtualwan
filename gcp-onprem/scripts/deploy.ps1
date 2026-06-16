#Requires -Version 7.0
<#
.SYNOPSIS
  Deploy the gcp-onprem lab (two GCP Partner Interconnect environments).

.DESCRIPTION
  Checks for gcloud and terraform, prompts for GCP project + regions,
  writes terraform.tfvars, then runs terraform init / plan / apply.
  After a successful apply the pairing keys are printed to the console.

  WARNING — LAB ONLY. Not for production use.

.PARAMETER Project
  GCP project ID. Prompted interactively if omitted.
  Alternatively set env var GCP_PROJECT.

.PARAMETER Env1Region
  GCP region for env1 (default: us-west2 / Los Angeles).

.PARAMETER Env2Region
  GCP region for env2 (default: us-west4 / Las Vegas).

.PARAMETER Yes
  Skip all interactive confirmation prompts (non-interactive mode).

.EXAMPLE
  .\deploy.ps1
  .\deploy.ps1 -Project my-gcp-project -Yes
  $env:GCP_PROJECT="my-gcp-project"; .\deploy.ps1 -Yes
#>

param(
  [string]$Project     = "",
  [string]$Env1Region  = "us-west2",
  [string]$Env2Region  = "us-west4",
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


$ScriptDir  = $PSScriptRoot
$TerraformDir = Join-Path $ScriptDir "..\terraform"

# ---------- Helpers ----------------------------------------------------------
function Log([string]$m)  { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Info([string]$m) { Write-Host "  $m" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

function Confirm-Continue([string]$Prompt) {
  if ($Yes) { return }
  $ans = Read-Host "$Prompt [y/N]"
  if ($ans -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

# ---------- Auth check -------------------------------------------------------
Log "Checking gcloud authentication..."
$ActiveAccount = gcloud config get-value account 2>$null
if ([string]::IsNullOrWhiteSpace($ActiveAccount)) {
  Warn "No active gcloud account. Running: gcloud auth login"
  gcloud auth login
}
else {
  Ok "Active account: $ActiveAccount"
}

# ---------- Project ----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Project)) {
  $Project = $env:GCP_PROJECT
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  $Project = gcloud config get-value project 2>$null
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  $Project = Read-Host "Enter your GCP Project ID"
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  Fail "GCP project ID is required."
}
Info "Project : $Project"

# ---------- Regions ----------------------------------------------------------
if (-not $Yes) {
  $r1Input = Read-Host "env1 region [default: $Env1Region]"
  if (-not [string]::IsNullOrWhiteSpace($r1Input)) { $Env1Region = $r1Input }

  $r2Input = Read-Host "env2 region [default: $Env2Region]"
  if (-not [string]::IsNullOrWhiteSpace($r2Input)) { $Env2Region = $r2Input }
}
Info "env1 region : $Env1Region"
Info "env2 region : $Env2Region"

# ---------- Write tfvars -----------------------------------------------------
$TfVarsPath = Join-Path $TerraformDir "terraform.tfvars"
Log "Writing $TfVarsPath ..."

$tfvarsContent = @"
# Auto-generated by deploy.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Re-run deploy.ps1 to regenerate or edit manually.

project        = "$Project"
default_region = "$Env1Region"

allowed_source_ranges = [
  "192.168.0.0/16",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "35.235.240.0/20",
]

environments = {
  env1 = {
    region           = "$Env1Region"
    zone             = "${Env1Region}-a"
    network_name     = "onprem-la"
    network_cidr     = "192.168.100.0/24"
    subnet_cidr      = "192.168.100.0/24"
    vm_private_ip    = "192.168.100.10"
  }

  env2 = {
    region           = "$Env2Region"
    zone             = "${Env2Region}-a"
    network_name     = "onprem-lv"
    network_cidr     = "192.168.200.0/24"
    subnet_cidr      = "192.168.200.0/24"
    vm_private_ip    = "192.168.200.10"
  }
}
"@

Set-Content -Path $TfVarsPath -Value $tfvarsContent -Encoding UTF8
Ok "terraform.tfvars written"

# ---------- Terraform init ---------------------------------------------------
Log "Running terraform init..."
Push-Location $TerraformDir
try {
  terraform init
  Ok "terraform init complete"

  # ---------- Terraform plan -------------------------------------------------
  Log "Running terraform plan..."
  terraform plan -out=tfplan
  Ok "terraform plan complete (saved to tfplan)"

  # ---------- Terraform apply ------------------------------------------------
  Confirm-Continue "Apply the plan to your GCP project '$Project'?"
  Log "Running terraform apply..."
  terraform apply tfplan
  Ok "terraform apply complete"

  # ---------- Print pairing keys --------------------------------------------
  Log "Retrieving pairing keys..."
  Write-Host ""
  Write-Host "================================================================" -ForegroundColor Cyan
  Write-Host "  PARTNER INTERCONNECT PAIRING KEYS" -ForegroundColor Cyan
  Write-Host "  Copy each key to your Megaport VXC configuration." -ForegroundColor Cyan
  Write-Host "================================================================" -ForegroundColor Cyan
  terraform output -json pairing_keys | ConvertFrom-Json | Format-List
  Write-Host ""
  Write-Host "Next steps:" -ForegroundColor Yellow
  Write-Host "  1. Create Megaport VXC for env1 (LA) -> paste env1 pairing key -> connect to vwanlab-er1"
  Write-Host "  2. Create Megaport VXC for env2 (Phoenix) -> paste env2 pairing key -> connect to vwanlab-er2"
  Write-Host "  See docs\megaport-cross-connect.md for detailed instructions."
}
finally {
  Pop-Location
}