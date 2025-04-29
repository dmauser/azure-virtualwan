#!/bin/bash
# Reference: https://docs.microsoft.com/en-us/azure/virtual-wan/scenario-route-through-nva
# This lab deploys Linux NVAs on Spoke2 with ILB.

# Pre-Requisite
if ! az extension list | grep -q virtual-wan; then
    echo "virtual-wan extension is not installed, installing it now..."
    az extension add --name virtual-wan --only-show-errors
fi

# Parameters
region1=eastus2
rg=lab-vwan-nexthop
vwanname=vwan-nexthop
hub1name=hub1
# Prompt for username with default suggestion
read -p "Enter username [azureuser]: " username
username=${username:-azureuser}

# Prompt for password with confirmation
while true; do
    read -s -p "Enter password: " password
    echo
    read -s -p "Confirm password: " password_confirm
    echo
    if [ "$password" = "$password_confirm" ] && [ -n "$password" ]; then
        break
    else
        echo "Passwords do not match or are empty. Please try again."
    fi
done
vmsize=Standard_DS1_v2

#Variables
mypip=$(curl -4 ifconfig.io -s)

start=`date +%s`
echo "Script started at $(date)"

# Creating rg
az group create -n $rg -l $region1 --output none

# Creating virtual wan and hub1
echo Creating vwan and hub1...
az network vwan create -g $rg -n $vwanname --branch-to-branch-traffic true --location $region1 --type Standard --output none
az network vhub create -g $rg --name $hub1name --address-prefix 192.168.1.0/24 --vwan $vwanname --location $region1 --sku Standard --no-wait

echo Creating branch1 VNET...
az network vnet create --address-prefixes 10.100.0.0/16 -n branch1 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.100.0.0/24 --output none

echo Creating spoke VNETs...
az network vnet create --address-prefixes 10.1.0.0/24 -n spoke1 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.1.0.0/27 --output none
az network vnet create --address-prefixes 10.2.0.0/24 -n spoke2 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.2.0.0/27 --output none
az network vnet create --address-prefixes 10.2.1.0/24 -n spoke5 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.2.1.0/27 --output none
az network vnet create --address-prefixes 10.2.2.0/24 -n spoke6 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.2.2.0/27 --output none

echo Creating VNET peerings...
az network vnet peering create -g $rg -n spoke2-to-spoke5 --vnet-name spoke2 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke5 --query id --out tsv) --output none
az network vnet peering create -g $rg -n spoke5-to-spoke2 --vnet-name spoke5 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke2  --query id --out tsv) --output none
az network vnet peering create -g $rg -n spoke2-to-spoke6 --vnet-name spoke2 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke6 --query id --out tsv) --output none 
az network vnet peering create -g $rg -n spoke6-to-spoke2 --vnet-name spoke6 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke2  --query id --out tsv) --output none

echo Creating VMs in branch1 and spokes...
az vm create -n branch1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name branch1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke5VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke5 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke6VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke6 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

echo Creating NSG...
az network nsg create --resource-group $rg --name default-nsg-$region1 --location $region1 -o none
az network nsg rule create -g $rg --nsg-name default-nsg-$region1 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
az network vnet subnet update --id $(az network vnet list -g $rg --query '[].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$region1 -o none

echo Creating VPN Gateway in branch1...
az network vnet subnet create -g $rg --vnet-name branch1 -n GatewaySubnet --address-prefixes 10.100.100.0/26 --output none
az network public-ip create -n branch1-vpngw-pip -g $rg --location $region1 --output none
az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65510 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 

echo Checking Hub1 provisioning status...
while [[ $(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv) != 'Succeeded' ]]; do sleep 5; done
while [[ $(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv) != 'Provisioned' ]]; do sleep 5; done

echo Creating Hub1 VPN Gateway...
az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait 

# Continue with NVA deployment, ILB, UDRs, VPN connections, etc. for region1, hub1, branch1, spoke2 as per original script logic.
