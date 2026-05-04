#!/bin/bash
# Quick cleanup — deletes the lab resource group
RG="${1:-rg-vwan-lab}"

# Pre-requisite checks
if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI not found. Install from https://aka.ms/installazurecli"
    exit 1
fi

if ! az account show &>/dev/null; then
    echo "ERROR: Not logged in. Run 'az login' first."
    exit 1
fi

# Confirmation prompt
echo "⚠️  This will DELETE resource group: $RG"
read -p "Are you sure? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

echo "🧹 Deleting resource group: $RG"
az group delete --name "$RG" --yes --no-wait
echo "✅ Deletion initiated (async). Resources will be removed in ~5 minutes."
