# Azure Virtual WAN Unified Lab Builder — Deploy Script (PowerShell)
# Usage: .\deploy.ps1 -Preset single-hub-vpn [-ResourceGroup rg-vwan-lab] [-Location eastus2]

param(
    [Parameter(Mandatory=$true)]
    [string]$Preset,
    
    [string]$ResourceGroup = "rg-vwan-lab",
    [string]$Location = "eastus2"
)

$ErrorActionPreference = "Stop"

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
Invoke-LabPrereqCheck -Tools @('az')

# ─────────────────────────────────────────────────────────────
# Pre-requisite checks
# ─────────────────────────────────────────────────────────────

# 1. Check Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Azure CLI not found. Install from https://aka.ms/installazurecli" -ForegroundColor Red
    exit 1
}

# 2. Check user is logged in
try {
    $account = az account show --output json | ConvertFrom-Json
} catch {
    Write-Host "ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}
if (-not $account) {
    Write-Host "ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}

# 3. Check virtual-wan extension is installed; auto-install if missing
$extCheck = az extension show --name virtual-wan 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "⚙️  Installing required extension: virtual-wan..." -ForegroundColor Yellow
    az extension add --name virtual-wan --yes --output none
}

# 4. Check Bicep CLI is available; install if missing
$bicepCheck = az bicep version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "⚙️  Installing Bicep CLI..." -ForegroundColor Yellow
    az bicep install
}

# 5. Validate preset file exists
$PresetFile = "presets/$Preset.bicepparam"
if (-not (Test-Path $PresetFile)) {
    Write-Host "❌ Preset not found: $PresetFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available presets:"
    Get-ChildItem presets/*.bicepparam | ForEach-Object { Write-Host "  • $($_.BaseName)" }
    exit 1
}

# 6. Print formatted summary
$subscriptionName = $account.name

Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Azure Virtual WAN — Unified Lab Builder                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "📋 Preset:       $Preset"
Write-Host "📦 RG:           $ResourceGroup"
Write-Host "📍 Location:     $Location"
Write-Host "🔑 Subscription: $subscriptionName"
Write-Host ""

# Generate password
$Password = -join ((65..90) + (97..122) + (48..57) + (33, 64, 35) | Get-Random -Count 16 | ForEach-Object {[char]$_})

# Create resource group
Write-Host "🔧 Creating resource group..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --output none

# Deploy
Write-Host "🚀 Deploying (this may take 30-60 minutes for VPN gateways)..." -ForegroundColor Yellow
$deploymentName = "vwan-lab-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file main.bicep `
    --parameters $PresetFile `
    --parameters adminPassword="$Password!" `
    --name $deploymentName `
    --output table

Write-Host ""
Write-Host "✅ Lab deployed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "🔑 Admin password: $Password!" -ForegroundColor Yellow
Write-Host "🧹 To clean up: az group delete --name $ResourceGroup --yes --no-wait" -ForegroundColor Gray
