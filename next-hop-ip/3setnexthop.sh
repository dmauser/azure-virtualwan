#!/bin/bash

# Parameters
rg=lab-vwan-nexthopip

# Get all vms with nva in the name
az vm list -g $rg --query "[?contains(name, 'nva')].{Name:name}" -o table

echo Configuring Next Hop IP on NVA VMs

# Get load balancer spoke2-linux-nva-ilb ip address
nvalbip=$(az network lb frontend-ip list -g $rg --lb-name spoke2-linux-nva-ilb --query "[?contains(name, 'frontend')].{Name:privateIPAddress}" -o tsv)

# Pass $nvalbip as a parameter to the script
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nexthopip.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva1 --command-id RunShellScript --scripts "curl -s $scripturi | bash -s -- $nvalbip" --output none --no-wait

# Pass $nvalbip as a parameter to the script
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nexthopip.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva2 --command-id RunShellScript --scripts "curl -s $scripturi | bash -s -- $nvalbip" --output none --no-wait