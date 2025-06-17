#!/bin/bash

# Pre-Requisite
if ! az extension list | grep -q virtual-wan; then
    echo "virtual-wan extension is not installed, installing it now..."
    az extension add --name virtual-wan --only-show-errors
fi

# Parameters
# Prompt for location
read -p "Enter the location (hit enter for default: westus3): " location
location=${location:-westus3} # Prompt for location, default to westus3 if not provided
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
az network vnet create --address-prefixes 10.2.1.0/24 -n spoke3 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.2.1.0/27 --output none
az network vnet create --address-prefixes 10.2.2.0/24 -n spoke4 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.2.2.0/27 --output none

echo Creating VNET peerings...
az network vnet peering create -g $rg -n spoke2-to-spoke3 --vnet-name spoke2 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke3 --query id --out tsv) --output none
az network vnet peering create -g $rg -n spoke3-to-spoke2 --vnet-name spoke3 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke2  --query id --out tsv) --output none
az network vnet peering create -g $rg -n spoke2-to-spoke4 --vnet-name spoke2 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke4 --query id --out tsv) --output none 
az network vnet peering create -g $rg -n spoke4-to-spoke2 --vnet-name spoke4 --allow-vnet-access --allow-forwarded-traffic --remote-vnet $(az network vnet show -g $rg -n spoke2  --query id --out tsv) --output none

echo Creating VMs in branch1 and spokes...
az vm create -n branch1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name branch1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke3VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke3 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke4VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke4 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors

echo Creating NSG...
az network nsg create --resource-group $rg --name default-nsg-$region1 --location $region1 -o none
az network nsg rule create -g $rg --nsg-name default-nsg-$region1 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
az network vnet subnet update --id $(az network vnet list -g $rg --query '[].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$region1 -o none

echo Creating VPN Gateway in branch1...
az network vnet subnet create -g $rg --vnet-name branch1 -n GatewaySubnet --address-prefixes 10.100.100.0/26 --output none
az network public-ip create -n branch1-vpngw-pip -g $rg --location $region1 --output none 
az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65510 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 

echo "Checking Hub1 provisioning status..."
prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
while [[ $prState != 'Succeeded' ]]; do
    echo "provisioningState=$prState"
    sleep 5
    prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
done
echo "provisioningState=Succeeded"

rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
while [[ $rtState != 'Provisioned' ]]; do
    echo "routingState=$rtState"
    sleep 5
    rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
done
echo "routingState=Provisioned"

# Create spoke to Vwan connections to hub1
az network vhub connection create -n spoke1-conn --remote-vnet spoke1 -g $rg --vhub-name $hub1name --no-wait
az network vhub connection create -n spoke2-conn --remote-vnet spoke2 -g $rg --vhub-name $hub1name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState1=$(az network vhub connection show -n spoke1-conn --vhub-name $hub1name -g $rg --query 'provisioningState' -o tsv)
    prState2=$(az network vhub connection show -n spoke2-conn --vhub-name $hub1name -g $rg --query 'provisioningState' -o tsv)
    echo "vnet connection spoke1-conn provisioningState="$prState1
    echo "vnet connection spoke2-conn provisioningState="$prState2
    if [[ $prState1 == 'Succeeded' && $prState2 == 'Succeeded' ]]; then
        prState='Succeeded'
    else
        sleep 5
    fi
done

######## Deploying NVA on spoke2 ########
echo "Creating spoke2 NVA..."

#NVA specific variables:
# Deploy BGP endpoint (Make the changes based on your needs)
nvavnetnamer1=spoke2 #Target NET
instances=2 #Set number of NVA instaces to be created
nvaintname=linux-nva #NVA instance name
nvasubnetname=nvasubnet #Existing Subnet where NVA gets deployed
hubtopeer=$hub1name #Note: VNET has to be connected to the same hub
nvanames=$(i=1;while [ $i -le $instances ];do echo $nvavnetnamer1-$nvaintname$i; ((i++));done)

#Specific NVA BGP settings
asn_frr=65002 # Set ASN
bgp_network1="10.2.0.0/16"

# Creating spoke2 nvasubnet
echo Creating spoke2 nvasubnet...
az network vnet subnet create -g $rg --vnet-name spoke2 -n nvasubnet --address-prefixes 10.2.0.32/28  --output none

# Deploy NVA instances on the target VNET above.
for nvaname in $nvanames
do
 # Enable routing, NAT and BGP on Linux NVA:
 az network public-ip create --name $nvaname-pip --resource-group $rg --location $region1 --sku Standard --output none --only-show-errors
 az network nic create --name $nvaname-nic --resource-group $rg --subnet $nvasubnetname --vnet $nvavnetnamer1 --public-ip-address $nvaname-pip --ip-forwarding true --location $region1 -o none
 az vm create --resource-group $rg --location $region1 --name $nvaname --size $vmsize --nics $nvaname-nic  --image Ubuntu2204 --admin-username $username --admin-password $password -o none --only-show-errors

 #NVA BGP config variables (do not change)
 bgp_routerId=$(az network nic show --name $nvaname-nic --resource-group $rg --query ipConfigurations[0].privateIPAddress -o tsv)
 routeserver_IP1=$(az network vhub show -n $hubtopeer -g $rg --query virtualRouterIps[0] -o tsv)
 routeserver_IP2=$(az network vhub show -n $hubtopeer -g $rg --query virtualRouterIps[1] -o tsv)

 # Enable routing and NAT on Linux NVA:
 scripturi="https://raw.githubusercontent.com/dmauser/AzureVM-Router/master/scripts/linuxrouterbgpfrr.sh"
 az vm extension set --resource-group $rg --vm-name $nvaname  --name customScript --publisher Microsoft.Azure.Extensions \
 --protected-settings "{\"fileUris\": [\"$scripturi\"],\"commandToExecute\": \"./linuxrouterbgpfrr.sh $asn_frr $bgp_routerId $bgp_network1 $routeserver_IP1 $routeserver_IP2\"}" \
 --no-wait

 # Build Virtual Router BGP Peering
 az network vhub bgpconnection create --resource-group $rg \
 --vhub-name $hubtopeer \
 --name $nvaname \
 --peer-asn $asn_frr \
 --peer-ip $(az network nic show --name $nvaname-nic --resource-group $rg --query ipConfigurations[0].privateIPAddress -o tsv) \
 --vhub-conn $(az network vhub connection show --name $nvavnetnamer1-conn --resource-group $rg --vhub-name $hubtopeer --query id -o tsv) \
 --output none
done

#Creating Internal Load Balancer, Frontend IP, Backend, probe and LB Rule.
echo Creating Internal Load Balancer, Frontend IP, Backend, probe and LB Rule.
az network lb create -g $rg --name $nvavnetnamer1-$nvaintname-ilb --sku Standard --frontend-ip-name frontendip1 --backend-pool-name nvabackend --vnet-name $nvavnetnamer1 --subnet=$nvasubnetname --location $region1 --output none --only-show-errors
az network lb probe create -g $rg --lb-name $nvavnetnamer1-$nvaintname-ilb --name sshprobe --protocol tcp --port 22 --output none  
az network lb rule create -g $rg --lb-name $nvavnetnamer1-$nvaintname-ilb --name haportrule1 --protocol all --frontend-ip-name frontendip1 --backend-pool-name nvabackend --probe-name sshprobe --frontend-port 0 --backend-port 0 --output none

# Attach NVAs to the Backend as NICs
for nvaname in $nvanames
do
  az network nic ip-config address-pool add \
  --address-pool nvabackend \
  --ip-config-name ipconfig1 \
  --nic-name $nvaname-nic \
  --resource-group $rg \
  --lb-name $nvavnetnamer1-$nvaintname-ilb \
  --output none
done

# Create UDR from spoke3 and spoke 4 to spoke2 nvalb
echo "Creating UDR from spoke3 and spoke4 to spoke2 NVA load balancer..."
# Get load balancer spoke2-linux-nva-ilb ip address
nvalbip=$(az network lb frontend-ip list -g $rg --lb-name spoke2-linux-nva-ilb --query "[?contains(name, 'frontend')].{Name:privateIPAddress}" -o tsv)
az network route-table create -g $rg -n spoke3-rt --location $region1 --output none
az network route-table route create -g $rg --route-table-name spoke3-rt -n spoke2 --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $nvalbip --output none
az network vnet subnet update --vnet-name spoke3 -g $rg --name main --route-table spoke3-rt --output none

az network route-table create -g $rg -n spoke4-rt --location $region1 --output none
az network route-table route create -g $rg --route-table-name spoke4-rt -n spoke2 --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $nvalbip --output none
az network vnet subnet update --vnet-name spoke4 -g $rg --name main --route-table spoke4-rt --output none

echo Creating Hub1 VPN Gateway...
az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait 

echo Validating vHubs VPN Gateways provisioning...
#vWAN Hubs VPN Gateway Status
prState=$(az network vpn-gateway show -g $rg -n $hub1name-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vpn-gateway delete -n $hub1name-vpngw -g $rg
    az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vpn-gateway show -g $rg -n $hub1name-vpngw --query provisioningState -o tsv)
        echo $hub1name-vpngw "provisioningState="$prState
        sleep 5
    done
fi

echo Validating VPN Gateways provisioning...
#Branch VPN Gateways provisioning status
prState=$(az network vnet-gateway show -g $rg -n branch1-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vnet-gateway delete -n branch1-vpngw -g $rg
    az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65510 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vnet-gateway show -g $rg -n branch1-vpngw --query provisioningState -o tsv)
        echo "branch1-vpngw provisioningState="$prState
        sleep 5
    done
fi

echo Enabling boot diagnostics
az vm boot-diagnostics enable --ids $(az vm list -g $rg --query '[].{id:id}' -o tsv) -o none

### Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others (check link below for more details) 
echo "Installing net utilities inside VMs (traceroute, tcptraceroute, iperf3, hping3, and others)"
nettoolsuri="https://raw.githubusercontent.com/dmauser/azure-vm-net-tools/main/script/nettools.sh"
for vm in `az vm list -g $rg --query "[?contains(storageProfile.imageReference.publisher,'Canonical')].name" -o tsv`
do
 az vm extension set --force-update \
 --resource-group $rg \
 --vm-name $vm \
 --name customScript \
 --publisher Microsoft.Azure.Extensions \
 --protected-settings "{\"fileUris\": [\"$nettoolsuri\"],\"commandToExecute\": \"./nettools.sh\"}" \
 --no-wait
done

echo Building VPN connections from VPN Gateways to the respective Branch...
# get bgp peering and public ip addresses of VPN GW and VWAN to set up connection
bgp1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
pip1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)

# Creating virtual wan vpn site
az network vpn-site create --ip-address $pip1 -n site-branch1 -g $rg --asn 65510 --bgp-peering-address $bgp1 -l $region1 --virtual-wan $vwanname --device-model 'Azure' --device-vendor 'Microsoft' --link-speed '50' --with-link true --output none

# Creating virtual wan vpn connection
az network vpn-gateway connection create --gateway-name $hub1name-vpngw -n site-branch1-conn -g $rg --enable-bgp true --remote-vpn-site site-branch1 --internet-security --shared-key 'abc123' --output none

# Creating connection from vpn gw to local gateway and watch for connection succeeded
az network local-gateway create -g $rg -n lng-$hub1name-gw1 --gateway-ip-address $vwanh1gwpip1 --asn 65515 --bgp-peering-address $vwanh1gwbgp1 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw1 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw1 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub1name-gw2 --gateway-ip-address $vwanh1gwpip2 --asn 65515 --bgp-peering-address $vwanh1gwbgp2 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw2 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw2 --enable-bgp --shared-key 'abc123' --output none

echo Deployment has finished
# Add script ending time but hours, minutes and seconds
end=`date +%s`
runtime=$((end-start))
echo "Script finished at $(date)"
echo "Total script execution time: $(($runtime / 3600)) hours $((($runtime / 60) % 60)) minutes and $(($runtime % 60)) seconds."

