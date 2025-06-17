# Parameters
region1=eastus2
rg=lab-vwan-nexthopip
vwanname=vwan-nexthopip
hub1name=hub1

# Get all vms with nva in the name
az vm list -g $rg --query "[?contains(name, 'nva')].{Name:name}" -o table

echo Configuring Next Hop IP on NVA VMs

# Pass $nvalbip as a parameter to the script
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nonexthopip.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva1 --command-id RunShellScript --scripts "curl -s $scripturi | bash" --output none --no-wait

# Pass $nvalbip as a parameter to the script
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nonexthopip.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva2 --command-id RunShellScript --scripts "curl -s $scripturi | bash" --output none --no-wait