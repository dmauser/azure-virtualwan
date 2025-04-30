# Parameters
region1=eastus2
rg=lab-vwan-nexthop
vwanname=vwan-nexthop
hub1name=hub1

# Get all vms with nva in the name
az vm list -g $rg --query "[?contains(name, 'nva')].{Name:name}" -o table

echo Configuring iptables rules on DMZ-NVA...
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nexthop.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva1 --command-id RunShellScript --scripts "curl -s $scripturi | bash" --output none --no-wait

# Get spoke2-nvalb

echo Configuring iptables rules on DMZ-NVA...
scripturi="https://raw.githubusercontent.com/dmauser/azure-virtualwan/refs/heads/main/next-hop-ip/scripts/nexthop.sh"
az vm run-command invoke -g $rg -n spoke2-linux-nva1 --command-id RunShellScript --scripts "curl -s $scripturi | bash" --output none --no-wait