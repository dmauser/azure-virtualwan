#!/bin/bash

# Variables
VM_SIZE=Standard_DS1_v2    # e.g., Standard_DS1_v2
REGION=eastus          # e.g., eastus

if [[ -z $VM_SIZE || -z $REGION ]]; then
  echo "Usage: $0 <VM_SIZE> <REGION>"
  exit 1
fi

echo "Checking availability of VM size '$VM_SIZE' in region '$REGION'..."

# Check if the VM size is available in the specified region
VM_SKU_INFO=$(az vm list-skus --location $REGION --query "[?name=='$VM_SIZE']" -o json)

if [[ -z $VM_SKU_INFO ]]; then
  echo "VM size '$VM_SIZE' is NOT available in region '$REGION'."
  exit 1
fi

echo "VM size '$VM_SIZE' is available in region '$REGION'."

# Check quota for the VM size in the region
echo "Checking quota for VM size '$VM_SIZE' in region '$REGION'..."
QUOTA=$(az vm list-usage --location $REGION --query "[?contains(localName, '$VM_SIZE')]" -o json)

if [[ -z $QUOTA ]]; then
  echo "Error: Unable to retrieve quota information for VM size '$VM_SIZE' in region '$REGION'."
  exit 1
fi

LIMIT=$(echo $QUOTA | jq -r '.[0].limit')
CURRENT_USAGE=$(echo $QUOTA | jq -r '.[0].currentValue')

if [[ $CURRENT_USAGE -ge $LIMIT ]]; then
  echo "Error: Quota exceeded for VM size '$VM_SIZE' in region '$REGION'. Current usage: $CURRENT_USAGE, Limit: $LIMIT."
  echo "Request a quota increase through the Azure Portal."
  exit 1
fi

echo "Quota is sufficient for VM size '$VM_SIZE' in region '$REGION'. Current usage: $CURRENT_USAGE, Limit: $LIMIT."

# get vm size family
VM_SIZE_FAMILY=$(echo $VM_SKU_INFO | jq -r '.[0].family')

