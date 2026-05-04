#!/usr/bin/env bash

# Get subscription ID from your current account context
subscriptionId=$(az account show --query id -o tsv)

# Set your resource group and virtual hub name
resourceGroupName="<your-resource-group-name>"
virtualHubName="<your-virtual-hub-name>"

# determine the existing resource location (required for PUT)
location=$(az resource show \
  --resource-group "$resourceGroupName" \
  --resource-type "Microsoft.Network/virtualHubs" \
  --name "$virtualHubName" \
  --query location -o tsv)

if [ -z "$location" ]; then
  echo "Failed to determine location for virtual hub '$virtualHubName' in resource group '$resourceGroupName'." >&2
  exit 1
fi

az rest --method PUT \
  --uri "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/virtualHubs/$virtualHubName?api-version=2024-05-01" \
  --headers "Content-Type=application/json" \
  --body "{\"location\":\"$location\"}"
# print the request URI for debugging
echo "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/virtualHubs/$virtualHubName?api-version=2024-05-01"

/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1


https://management.azure.com/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1?api-version=2023-06-01

# GET the current resource JSON, sanitize it, then PUT it back
uri="https://management.azure.com/subscriptions/36ead89c-e817-4abc-ae66-5d29d23995bb/resourceGroups/lab-vwan-a2a/providers/Microsoft.Network/virtualHubs/hub1?api-version=2023-06-01"

tmp_get=$(mktemp)
tmp_body=$(mktemp)
trap 'rm -f "$tmp_get" "$tmp_body"' EXIT

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not found. Install jq and retry." >&2
    exit 1
fi

# GET the resource
az rest --method GET --uri "$uri" -o json >"$tmp_get" || { echo "GET failed" >&2; exit 1; }

# Build a PUT body from the GET output:
# - remove read-only fields that can cause PUT to fail
# - ensure the location field stays set to $location (from earlier in the script)
jq --arg loc "$location" '
    del(.id, .name, .type, .etag, .properties.provisioningState, .systemData) |
    .location = $loc
' "$tmp_get" > "$tmp_body" || { echo "Failed to build request body" >&2; exit 1; }

# PUT using the sanitized body file
az rest --method PUT \
    --uri "$uri" \
    --headers "Content-Type=application/json" \
    --body @"$tmp_body" || { echo "PUT failed" >&2; exit 1; }

# Optional: GET to show the updated resource
az rest --method GET --uri "$uri" -o json


