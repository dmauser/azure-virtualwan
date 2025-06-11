#!/bin/bash

# variables

resource_group="lab-svh-inter"
location="eastus2"
vnet_prefix="vnet"
vhub_name="sechub1"

for i in $(seq 1 100); do
  vnet_name="${vnet_prefix}-${i}"
  connection_name="${vnet_name}-conn"

  echo "Connecting $vnet_name to virtual hub"

az network vhub connection create \
    --name "$connection_name" \
    --resource-group "$resource_group" \
    --vhub-name "$vhub_name" \
    --remote-vnet "$vnet_name" \
    --internet-security false \
    --no-wait \
    --output none
done

# For each connection I need to keep a track on amount of seconds how long it takes to connected, so I will use a loop to check the status of each connection
# and print the time taken for each connection to reach the 'Connected' state.
# Function to check connection status and measure time
check_connection() {
  conn_name="$1"
  start_time=$(date +%s)
  while true; do
    status=$(az network vhub connection show --name "$conn_name" --resource-group "$resource_group" --vhub-name "$vhub_name" --query "provisioningState" -o tsv)
    if [ "$status" == "Succeeded" ]; then
      end_time=$(date +%s)
      duration=$((end_time - start_time))
      echo "✅ Connection $conn_name is in 'Connected' state. Time taken: $duration seconds."
      break
    elif [ "$status" == "Failed" ]; then
      echo "❌ Connection $conn_name failed to connect."
      break
    else
      sleep 10
    fi
  done
}

# Run all checks in parallel
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[].name" -o tsv | while read -r conn_name; do
  check_connection "$conn_name" &
done
wait



# Pause and wait for user input before starting the status check loop


# Check all the connections and their statuses, show the count for each status and only finish the script when all connections are in the 'Connected' state
while true; do
  echo "Checking connection statuses..."
  az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[].{Name:name, Status:provisioningState}" -o table
  sleep 10
  connected_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Succeeded'].name" -o tsv | wc -l)
  failed_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | wc -l)
  updating_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Updating'].name" -o tsv | wc -l)
  deleting_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Deleting'].name" -o tsv | wc -l)
  total_count=$(az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "length(@)" -o tsv)
  echo "Connected: $connected_count, Failed: $failed_count, Updating: $updating_count, Deleting: $deleting_count, Total: $total_count"
  read -n 1 -s -r -p "Press any key to start checking connection statuses..."
  echo
  if [ "$connected_count" -eq "$total_count" ]; then
      echo "✅ All connections are in the 'Connected' state."
      break
  fi
done

# Check all connections with status failed and retry to connect them in parallel
az network vhub connection list --resource-group "$resource_group" --vhub-name "$vhub_name" --query "[?provisioningState=='Failed'].name" -o tsv | while read -r conn_name; do
  echo "Retrying connection for $conn_name..."
  az network vhub connection create \
      --name "$conn_name" \
      --resource-group "$resource_group" \
      --vhub-name "$vhub_name" \
      --remote-vnet "${conn_name%-conn}" \
      --internet-security false \
      --no-wait \
      --output none
  check_connection "$conn_name" &
done
wait




