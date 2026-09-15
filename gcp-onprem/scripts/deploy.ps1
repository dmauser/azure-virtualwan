#Requires -Version 7.0
<#
.SYNOPSIS
  Deploy the gcp-onprem lab (one or more GCP Partner Interconnect environments).

.DESCRIPTION
  Checks for gcloud and terraform, prompts for GCP project + how many on-prem
  environments to create and a region per environment (with a coast-grouped
  picker), writes terraform.tfvars, then runs terraform init / plan / apply.
  After a successful apply the pairing keys are printed to the console.

  Environment N is auto-named:
    network_name  = onprem-<N>
    network_cidr  = subnet_cidr = 192.168.<N>.0/24
    vm_private_ip = 192.168.<N>.10
    zone          = <region>-a

  WARNING — LAB ONLY. Not for production use.

.PARAMETER Project
  GCP project ID. Prompted interactively if omitted.
  Alternatively set env var GCP_PROJECT.

.PARAMETER Count
  Number of on-prem environments to deploy (default: 1).

.PARAMETER Regions
  One region per environment, e.g. -Regions us-central1,us-west2. Used for
  non-interactive runs. If fewer regions than -Count are given, the default
  region (us-central1) fills the remainder.

.PARAMETER Yes
  Skip all interactive confirmation prompts (non-interactive mode).

.EXAMPLE
  .\deploy.ps1
  .\deploy.ps1 -Project my-gcp-project -Count 1 -Regions us-central1 -Yes
  .\deploy.ps1 -Project my-gcp-project -Count 3 -Regions us-central1,us-west2,us-east4 -Yes
  $env:GCP_PROJECT="my-gcp-project"; .\deploy.ps1 -Yes
#>

param(
  [string]$Project    = "",
  [int]$Count         = 1,
  [string[]]$Regions  = @(),
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

# ---------- Region picker ----------------------------------------------------
# Coast-grouped menu of common US regions. Returns a region string. Accepts a
# menu number, a free-text region (e.g. "europe-west1"), or empty for default.
$DefaultRegion = "us-central1"
$RegionMenu = @(
  @{ Label = "West";    Regions = @(
      @{ Id = "us-west1"; Desc = "Oregon" },
      @{ Id = "us-west2"; Desc = "Los Angeles" },
      @{ Id = "us-west3"; Desc = "Salt Lake City" },
      @{ Id = "us-west4"; Desc = "Las Vegas" }) },
  @{ Label = "Central"; Regions = @(
      @{ Id = "us-central1"; Desc = "Iowa (default)" },
      @{ Id = "us-south1";   Desc = "Dallas" }) },
  @{ Label = "East";    Regions = @(
      @{ Id = "us-east1"; Desc = "South Carolina" },
      @{ Id = "us-east4"; Desc = "Northern Virginia" },
      @{ Id = "us-east5"; Desc = "Columbus" }) }
)

function Select-GcpRegion([string]$Title) {
  # Build a flat numbered list across the coast groups.
  $flat = New-Object System.Collections.Generic.List[object]
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  foreach ($group in $RegionMenu) {
    Write-Host ("  -- {0} --" -f $group.Label) -ForegroundColor DarkCyan
    foreach ($r in $group.Regions) {
      $flat.Add($r.Id) | Out-Null
      Write-Host ("    [{0}] {1,-12} {2}" -f $flat.Count, $r.Id, $r.Desc)
    }
  }
  Write-Host ("  (Enter a number, type any other region id, or press Enter for default '{0}')" -f $DefaultRegion)
  $choice = Read-Host "  Region"
  if ([string]::IsNullOrWhiteSpace($choice)) { return $DefaultRegion }
  $n = 0
  if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $flat.Count) {
    return $flat[$n - 1]
  }
  return $choice.Trim()
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

# ---------- Environment count ------------------------------------------------
if (-not $Yes) {
  $cInput = Read-Host "How many on-prem environments to deploy? [default: $Count]"
  if (-not [string]::IsNullOrWhiteSpace($cInput)) {
    $parsed = 0
    if ([int]::TryParse($cInput, [ref]$parsed)) { $Count = $parsed }
  }
}
if ($Count -lt 1)   { Fail "Count must be at least 1." }
if ($Count -gt 254) { Fail "Count must be 254 or fewer (CIDR third-octet limit)." }
Info "On-prem environments : $Count"

# ---------- Regions per environment -----------------------------------------
$envRegions = @()
for ($i = 1; $i -le $Count; $i++) {
  if (-not $Yes) {
    $r = Select-GcpRegion "Select region for env$i"
  }
  elseif ($i -le $Regions.Count) {
    $r = $Regions[$i - 1]
  }
  else {
    $r = $DefaultRegion
  }
  if ([string]::IsNullOrWhiteSpace($r)) { $r = $DefaultRegion }
  $envRegions += $r
  Info "env$i region : $r"
}

# ---------- Write tfvars -----------------------------------------------------
$TfVarsPath = Join-Path $TerraformDir "terraform.tfvars"
Log "Writing $TfVarsPath ..."

$envBlocks = for ($i = 1; $i -le $Count; $i++) {
  $region = $envRegions[$i - 1]
@"
  env$i = {
    region        = "$region"
    zone          = "${region}-a"
    network_name  = "onprem-$i"
    network_cidr  = "192.168.$i.0/24"
    subnet_cidr   = "192.168.$i.0/24"
    vm_private_ip = "192.168.$i.10"
  }
"@
}
$envBlock = $envBlocks -join "`n"

$tfvarsContent = @"
# Auto-generated by deploy.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# Re-run deploy.ps1 to regenerate or edit manually.

project        = "$Project"
default_region = "$($envRegions[0])"

allowed_source_ranges = [
  "192.168.0.0/16",
  "10.0.0.0/8",
  "172.16.0.0/12",
  "35.235.240.0/20",
]

environments = {
$envBlock
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
  Write-Host "  For each environment above, create a Megaport VXC, paste its pairing"
  Write-Host "  key, and connect it to the matching Azure ExpressRoute circuit"
  Write-Host "  (e.g. vwanlab-er1, vwanlab-er2, ...)."
  Write-Host "  See docs\megaport-cross-connect.md for detailed instructions."
}
finally {
  Pop-Location
}