#!/bin/bash

# variables
resource_group="lab-svh-inter"
location="eastus2"
vnet_prefix="vnet"
subnet_name="subnet1"

for i in $(seq 1 100); do
    vnet_name="${vnet_prefix}-${i}"
    third_octet=$(( (i - 1) % 256 ))
    address_prefix="10.50.${third_octet}.0/24"

    echo "Creating vnet $vnet_name with prefix $address_prefix"

    az network vnet create \
        --name "$vnet_name" \
        --resource-group "$resource_group" \
        --location "$location" \
        --address-prefixes "$address_prefix" \
        --subnet-name "$subnet_name" \
        --subnet-prefix "$address_prefix" \
        --no-wait \
        --output none
done


