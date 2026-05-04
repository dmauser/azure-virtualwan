# Azure Virtual WAN Unified Lab Builder — Deploy Script (PowerShell)
# Usage: .\deploy.ps1 -Preset single-hub-vpn [-ResourceGroup rg-vwan-lab] [-Location eastus2]

param(
    [Parameter(Mandatory=$true)]
    [string]$Preset,
    
    [string]$ResourceGroup = "rg-vwan-lab",
    [string]$Location = "eastus2"
)

$ErrorActionPreference = "Stop"

Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Azure Virtual WAN — Unified Lab Builder                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "📋 Preset:   $Preset"
Write-Host "📦 RG:       $ResourceGroup"
Write-Host "📍 Location: $Location"
Write-Host ""

# Check preset exists
$PresetFile = "presets/$Preset.bicepparam"
if (-not (Test-Path $PresetFile)) {
    Write-Host "❌ Preset not found: $PresetFile" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available presets:"
    Get-ChildItem presets/*.bicepparam | ForEach-Object { Write-Host "  • $($_.BaseName)" }
    exit 1
}

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
