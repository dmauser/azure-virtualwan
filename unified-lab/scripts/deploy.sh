#!/bin/bash
# Azure Virtual WAN Unified Lab Builder — Deploy Script
# Usage: ./deploy.sh <preset-name> [resource-group] [location]

set -e

PRESET="${1:-single-hub-vpn}"
RG="${2:-rg-vwan-lab}"
LOCATION="${3:-eastus2}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Azure Virtual WAN — Unified Lab Builder                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "📋 Preset:   $PRESET"
echo "📦 RG:       $RG"
echo "📍 Location: $LOCATION"
echo ""

# Check preset exists
PRESET_FILE="presets/${PRESET}.bicepparam"
if [ ! -f "$PRESET_FILE" ]; then
    echo "❌ Preset not found: $PRESET_FILE"
    echo ""
    echo "Available presets:"
    ls presets/*.bicepparam 2>/dev/null | sed 's|presets/||;s|.bicepparam||' | sed 's/^/  • /'
    exit 1
fi

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
