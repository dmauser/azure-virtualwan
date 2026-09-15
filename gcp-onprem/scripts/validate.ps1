#Requires -Version 7.0
<#
.SYNOPSIS
  Validate the gcp-onprem lab deployment via gcloud checks.

.DESCRIPTION
  Verifies each on-prem simulation environment:
    - VPC network exists
    - Subnet exists
    - VM instance is RUNNING
    - Cloud Router exists
    - Interconnect attachment exists and has a pairing key
    - Firewall rule exists
  Prints [PASS]/[FAIL] per check. Exits non-zero if any check fails.

.PARAMETER Project
  GCP project ID. Prompted interactively if omitted.
  Alternatively set env var GCP_PROJECT.

.EXAMPLE
  .\validate.ps1
  .\validate.ps1 -Project my-gcp-project
#>

param(
  [string]$Project = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

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


$script:PassCount = 0
$script:FailCount = 0

# ---------- Helpers ----------------------------------------------------------
function Log([string]$m)      { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Hdr([string]$Title)  {
  Write-Host ""
  Write-Host "###############################################################" -ForegroundColor Cyan
  Write-Host "# $Title" -ForegroundColor Cyan
  Write-Host "###############################################################" -ForegroundColor Cyan
}
function Pass([string]$m) { Write-Host "  [PASS] $m" -ForegroundColor Green;  $script:PassCount++ }
function Fail([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:FailCount++ }
function Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }

function GCloud([string[]]$Args) {
  $out = gcloud @Args 2>$null
  return $out
}

# ---------- Project ----------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Project)) { $Project = $env:GCP_PROJECT }
if ([string]::IsNullOrWhiteSpace($Project)) {
  $Project = GCloud @("config", "get-value", "project")
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  $Project = Read-Host "Enter your GCP Project ID"
}
if ([string]::IsNullOrWhiteSpace($Project)) {
  Write-Host "[FAIL] GCP project ID is required." -ForegroundColor Red; exit 1
}
Log "Project: $Project"

# ---------- Discover environments from terraform output ----------------------
# Instead of a hardcoded env list, read what was actually deployed so this
# scales to one or many on-prem environments.
$ScriptDir    = $PSScriptRoot
$TerraformDir = Join-Path $ScriptDir "..\terraform"

$Envs = @()
Push-Location $TerraformDir
try {
  $detailsJson = terraform output -json environment_details 2>$null
  if ([string]::IsNullOrWhiteSpace($detailsJson)) {
    Write-Host "[FAIL] Could not read 'environment_details' from terraform output." -ForegroundColor Red
    Write-Host "       Run terraform apply (or deploy.ps1) first, from $TerraformDir." -ForegroundColor Red
    exit 1
  }
  try {
    $details = $detailsJson | ConvertFrom-Json
  } catch {
    Write-Host "[FAIL] Failed to parse terraform output JSON: $_" -ForegroundColor Red
    exit 1
  }
  foreach ($key in ($details.PSObject.Properties.Name | Sort-Object)) {
    $d = $details.$key
    $Envs += @{
      Name       = $key
      Network    = $d.network_name
      Subnet     = $d.subnet_name
      Region     = $d.region
      Zone       = $d.zone
      VM         = $d.vm_name
      Router     = $d.router_name
      Attachment = $d.attachment_name
      Firewall   = $d.firewall_name
    }
  }
}
finally {
  Pop-Location
}

if ($Envs.Count -eq 0) {
  Write-Host "[FAIL] No environments found in terraform output." -ForegroundColor Red
  exit 1
}
Log "Discovered $($Envs.Count) environment(s): $(( $Envs | ForEach-Object { $_.Name }) -join ', ')"

foreach ($e in $Envs) {
  Hdr "Validating $($e.Name) — $($e.Network) ($($e.Region))"

  # VPC Network
  $net = GCloud @("compute", "networks", "describe", $e.Network, "--project=$Project", "--format=value(name)")
  if ($net -eq $e.Network) { Pass "VPC network '$($e.Network)' exists" }
  else                      { Fail "VPC network '$($e.Network)' not found" }

  # Subnet
  $sn = GCloud @("compute", "networks", "subnets", "describe", $e.Subnet,
                  "--project=$Project", "--region=$($e.Region)", "--format=value(name)")
  if ($sn -eq $e.Subnet) { Pass "Subnet '$($e.Subnet)' exists in $($e.Region)" }
  else                    { Fail "Subnet '$($e.Subnet)' not found in $($e.Region)" }

  # VM status
  $vmStatus = GCloud @("compute", "instances", "describe", $e.VM,
                        "--project=$Project", "--zone=$($e.Zone)", "--format=value(status)")
  if ($vmStatus -eq "RUNNING") { Pass "VM '$($e.VM)' is RUNNING" }
  else                          { Fail "VM '$($e.VM)' status = '$vmStatus' (expected RUNNING)" }

  # Cloud Router
  $router = GCloud @("compute", "routers", "describe", $e.Router,
                      "--project=$Project", "--region=$($e.Region)", "--format=value(name)")
  if ($router -eq $e.Router) { Pass "Cloud Router '$($e.Router)' exists" }
  else                        { Fail "Cloud Router '$($e.Router)' not found" }

  # Interconnect attachment + pairing key
  $pairingKey = GCloud @("compute", "interconnects", "attachments", "describe", $e.Attachment,
                          "--project=$Project", "--region=$($e.Region)", "--format=value(pairingKey)")
  if (-not [string]::IsNullOrWhiteSpace($pairingKey)) {
    Pass "Interconnect attachment '$($e.Attachment)' exists and has pairing key"
    Warn "  Pairing key: $pairingKey  (supply to Megaport VXC)"
  } else {
    $attachExists = GCloud @("compute", "interconnects", "attachments", "describe", $e.Attachment,
                              "--project=$Project", "--region=$($e.Region)", "--format=value(name)")
    if ($attachExists -eq $e.Attachment) {
      Pass "Interconnect attachment '$($e.Attachment)' exists (pairing key not yet available — state may be PENDING_PARTNER)"
    } else {
      Fail "Interconnect attachment '$($e.Attachment)' not found"
    }
  }

  # Firewall rule
  $fw = GCloud @("compute", "firewall-rules", "describe", $e.Firewall,
                  "--project=$Project", "--format=value(name)")
  if ($fw -eq $e.Firewall) { Pass "Firewall rule '$($e.Firewall)' exists" }
  else                      { Fail "Firewall rule '$($e.Firewall)' not found" }
}

# ---------- Summary ----------------------------------------------------------
Write-Host ""
Write-Host "###############################################################" -ForegroundColor Cyan
Write-Host "# SUMMARY" -ForegroundColor Cyan
Write-Host "###############################################################" -ForegroundColor Cyan
Write-Host "  PASS : $($script:PassCount)" -ForegroundColor Green
Write-Host "  FAIL : $($script:FailCount)" -ForegroundColor $(if ($script:FailCount -gt 0) { "Red" } else { "Green" })

if ($script:FailCount -gt 0) {
  Write-Host ""
  Write-Host "Validation FAILED. See [FAIL] items above." -ForegroundColor Red
  exit 1
} else {
  Write-Host ""
  Write-Host "All checks PASSED." -ForegroundColor Green
}