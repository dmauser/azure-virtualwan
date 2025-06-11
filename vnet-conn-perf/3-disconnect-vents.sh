#!/bin/bash

# variables

resource_group="lab-svh-inter"
location="eastus2"
vnet_prefix="vnet"
vhub_name="sechub1"

# Delete the connections that contains the name 'vnet-'
echo "Deleting connections that contain 'vnet-' in their name..."
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?contains(name, 'vnet-')].name" -o tsv | while read -r conn_name; do
  echo "Deleting connection: $conn_name"
  az network vhub connection delete --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --no-wait --output none --yes
done
echo "✅ All connections containing 'vnet-' have been deleted."

# Check all connections with failed status and delete them
echo "Checking for connections with 'Failed' status..." 
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | while read -r conn_name; do
  echo "Deleting failed connection: $conn_name"
  az network vhub connection delete --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --no-wait --output none --yes
done
echo "✅ All connections with 'Failed' status have been deleted."