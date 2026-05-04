#!/bin/bash
# Azure Virtual WAN Unified Lab Builder — Deploy Script
# Usage: ./deploy.sh <preset-name> [resource-group] [location]

set -e

PRESET="${1:-single-hub-vpn}"
RG="${2:-rg-vwan-lab}"
LOCATION="${3:-eastus2}"

# ─────────────────────────────────────────────────────────────
# Pre-requisite checks
# ─────────────────────────────────────────────────────────────

# 1. Check Azure CLI is installed
if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI not found. Install from https://aka.ms/installazurecli"
    exit 1
fi

# 2. Check user is logged in
if ! az account show &>/dev/null; then
    echo "ERROR: Not logged in. Run 'az login' first."
    exit 1
fi

# 3. Check virtual-wan extension is installed; auto-install if missing
if ! az extension show --name virtual-wan &>/dev/null 2>&1; then
    echo "⚙️  Installing required extension: virtual-wan..."
    az extension add --name virtual-wan --yes --output none
fi

# 4. Check Bicep CLI is available; install if missing
if ! az bicep version &>/dev/null 2>&1; then
    echo "⚙️  Installing Bicep CLI..."
    az bicep install
fi

# 5. Validate preset file exists
PRESET_FILE="presets/${PRESET}.bicepparam"
if [ ! -f "$PRESET_FILE" ]; then
    echo "❌ Preset not found: $PRESET_FILE"
    echo ""
    echo "Available presets:"
    ls presets/*.bicepparam 2>/dev/null | sed 's|presets/||;s|.bicepparam||' | sed 's/^/  • /'
    exit 1
fi

# 6. Print summary
SUBSCRIPTION_NAME=$(az account show --query "name" -o tsv)

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Azure Virtual WAN — Unified Lab Builder                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Preset:       $PRESET"
echo "📦 RG:           $RG"
echo "📍 Location:     $LOCATION"
echo "🔑 Subscription: $SUBSCRIPTION_NAME"
echo ""

# Create resource group
echo "🔧 Creating resource group..."
az group create --name "$RG" --location "$LOCATION" --output none

# Deploy
echo "🚀 Deploying (this may take 30-60 minutes for VPN gateways)..."
az deployment group create \
    --resource-group "$RG" \
    --template-file main.bicep \
    --parameters "$PRESET_FILE" \
    --parameters adminPassword="$(openssl rand -base64 16)!" \
    --name "vwan-lab-$(date +%Y%m%d-%H%M%S)" \
    --output table

echo ""
echo "✅ Lab deployed successfully!"
echo ""
echo "🧹 To clean up: az group delete --name $RG --yes --no-wait"
