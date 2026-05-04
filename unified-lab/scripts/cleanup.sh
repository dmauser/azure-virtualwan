#!/bin/bash
# Quick cleanup — deletes the lab resource group
RG="${1:-rg-vwan-lab}"
echo "🧹 Deleting resource group: $RG"
az group delete --name "$RG" --yes --no-wait
echo "✅ Deletion initiated (async). Resources will be removed in ~5 minutes."
