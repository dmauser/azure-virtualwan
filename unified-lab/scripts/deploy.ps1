# Azure Virtual WAN Unified Lab Builder — Deploy Script (PowerShell)
# Usage: .\deploy.ps1 -Preset single-hub-vpn [-ResourceGroup rg-vwan-lab] [-Location eastus2]

param(
    [Parameter(Mandatory=$true)]
    [string]$Preset,
    
    [string]$ResourceGroup = "rg-vwan-lab",
    [string]$Location = "eastus2"
)

$ErrorActionPreference = "Stop"

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
