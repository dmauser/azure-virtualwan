# Lab - Virtual WAN Scenario: Any-to-Any

## Intro

The goal of this lab is to demonstrate and validate the Azure Virtual WAN scenario...

### Lab diagram

The lab uses the same amount of VNETs (six total) and two regions with Hubs, and the remote connectivity to two branches using site-to-site VPN using and BGP. Below is a diagram of what you should expect to get deployed:

![net diagram](./media/networkdiagram.png)

### Components

- Two Virtual WAN Hubs in two different regions (default EastUS and WestUS).
- Six VNETs (Spoke 1 to 6) that are connected directly to their respective vHUBs.
- All Linux VMs include basic networking utilities such as: traceroute, tcptraceroute, hping3, nmap, curl.
    - For connectivity tests, you can use curl <"Destination IP"> and the output should be the VM name.
- Two remote branches emulated in Azure with Azure VPN Gateway on each site and S2S VPN using BGP to their respective vHUB. ASN 65010 is assigned to Branch 1 and ASN 65009 is assigned to Branch 2 while vHUBs VPN Gateways on both Hubs have fixed ASN 65515.

### Deploy this solution

The lab is also available in the above .azcli that you can rename as .sh (shell script) and execute. You can open [Azure Cloud Shell (Bash)](https://shell.azure.com) and run the following commands build the entire lab:

```bash
wget -O a2a-deploy.sh https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/any-to-any/a2a-deploy.azcli
chmod +xr a2a-deploy.sh
./a2a-deploy.sh 
```

**Note:** the provisioning process will take 45 to 60 minutes to complete.

Alternatively (recommended), you can run step-by-step to get familiar with the provisioning process and the components deployed:

```bash
#!/bin/bash
# Reference: https://docs.microsoft.com/en-us/azure/virtual-wan/scenario-isolate-vnets-custom

# Pre-Requisite
az extension add --name virtual-wan 
# or update
az extension update --name virtual-wan

# Parameters (make changes based on your requirements)
region1=eastus
region2=westus
rg=lab-vwan-a2a
vwanname=vwan-a2a
hub1name=hub1
hub2name=hub2
username=azureuser
password="Msft123Msft123"
vmsize=Standard_DS1_v2

#Variables
mypip=$(curl -4 ifconfig.io -s)

# create rg
az group create -n $rg -l $region1 --output none

echo Creating vwan and both hubs...
# create virtual wan
az network vwan create -g $rg -n $vwanname --branch-to-branch-traffic true --location $region1 --type Standard --output none
az network vhub create -g $rg --name $hub1name --address-prefix 192.168.1.0/24 --vwan $vwanname --location $region1 --sku Standard --no-wait
az network vhub create -g $rg --name $hub2name --address-prefix 192.168.2.0/24 --vwan $vwanname --location $region2 --sku Standard --no-wait

echo Creating branches VNETs...
# create location1 branch virtual network
az network vnet create --address-prefixes 10.100.0.0/16 -n branch1 -g $rg -l $region1 --subnet-name main --subnet-prefixes 10.100.0.0/24 --output none
az network vnet subnet create -g $rg --vnet-name branch1 -n GatewaySubnet --address-prefixes 10.100.100.0/26 --output none

# create location2 branch virtual network
az network vnet create --address-prefixes 10.200.0.0/16 -n branch2 -g $rg -l $region2 --subnet-name main --subnet-prefixes 10.200.0.0/24 --output none
az network vnet subnet create -g $rg --vnet-name branch2 -n GatewaySubnet --address-prefixes 10.200.100.0/26 --output none

echo Creating spoke VNETs...
# create spokes virtual network
# Region1
az network vnet create --address-prefixes 172.16.1.0/24 -n spoke1 -g $rg -l $region1 --subnet-name main --subnet-prefixes 172.16.1.0/27 --output none
az network vnet create --address-prefixes 172.16.2.0/24 -n spoke2 -g $rg -l $region1 --subnet-name main --subnet-prefixes 172.16.2.0/27 --output none
az network vnet create --address-prefixes 172.16.3.0/24 -n spoke3 -g $rg -l $region1 --subnet-name main --subnet-prefixes 172.16.3.0/27 --output none
# Region2
az network vnet create --address-prefixes 172.16.4.0/24 -n spoke4 -g $rg -l $region2 --subnet-name main --subnet-prefixes 172.16.4.0/27 --output none
az network vnet create --address-prefixes 172.16.5.0/24 -n spoke5 -g $rg -l $region2 --subnet-name main --subnet-prefixes 172.16.5.0/27 --output none
az network vnet create --address-prefixes 172.16.6.0/24 -n spoke6 -g $rg -l $region2 --subnet-name main --subnet-prefixes 172.16.6.0/27 --output none

echo Creating VMs in both branches...
# create a VM in each branch spoke
az vm create -n branch1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name branch1 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n branch2VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name branch2 --admin-username $username --admin-password $password --nsg "" --no-wait

echo Creating NSGs in both branches...
#Update NSGs:
az network nsg create --resource-group $rg --name default-nsg-$region1 --location $region1 -o none
az network nsg create --resource-group $rg --name default-nsg-$region2 --location $region2 -o none
# Add my home public IP to NSG for SSH acess
az network nsg rule create -g $rg --nsg-name default-nsg-$region1 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
az network nsg rule create -g $rg --nsg-name default-nsg-$region2 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none

# Associated NSG to the VNET subnets (Spokes and Branches)
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region1'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$region1 -o none
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region2'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$region2 -o none

echo Creating VPN Gateways in both branches...
# create pips for VPN GW's in each branch
az network public-ip create -n branch1-vpngw-pip -g $rg --location $region1 --sku Standard --output none
az network public-ip create -n branch2-vpngw-pip -g $rg --location $region2 --sku Standard --output none

# create VPN gateways
az network vnet-gateway create -n branch1-vpngw --public-ip-addresses branch1-vpngw-pip -g $rg --vnet branch1 --asn 65510 --gateway-type Vpn -l $region1 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
az network vnet-gateway create -n branch2-vpngw --public-ip-addresses branch2-vpngw-pip -g $rg --vnet branch2 --asn 65509 --gateway-type Vpn -l $region2 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait

echo Creating Spoke VMs...
# create a VM in each connected spoke
az vm create -n spoke1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n spoke2VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke2 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n spoke3VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke3 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n spoke4VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke4 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n spoke5VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke5 --admin-username $username --admin-password $password --nsg "" --no-wait
az vm create -n spoke6VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke6 --admin-username $username --admin-password $password --nsg "" --no-wait
#Enable boot diagnostics for all VMs in the resource group (Serial console)
#Create Storage Account (boot diagnostics + serial console)
let "randomIdentifier1=$RANDOM*$RANDOM" 
az storage account create -n sc$randomIdentifier1 -g $rg -l $region1 --sku Standard_LRS -o none
let "randomIdentifier2=$RANDOM*$RANDOM" 
az storage account create -n sc$randomIdentifier2 -g $rg -l $region2 --sku Standard_LRS -o none
#Enable boot diagnostics
stguri1=$(az storage account show -n sc$randomIdentifier1 -g $rg --query primaryEndpoints.blob -o tsv)
stguri2=$(az storage account show -n sc$randomIdentifier2 -g $rg --query primaryEndpoints.blob -o tsv)
az vm boot-diagnostics enable --storage $stguri1 --ids $(az vm list -g $rg --query '[?location==`'$region1'`].{id:id}' -o tsv) -o none
az vm boot-diagnostics enable --storage $stguri2 --ids $(az vm list -g $rg --query '[?location==`'$region2'`].{id:id}' -o tsv) -o none
### Install tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others (check link below for more details) 
nettoolsuri="https://raw.githubusercontent.com/dmauser/azure-vm-net-tools/main/script/nettools.sh"
for vm in `az vm list -g $rg --query "[?contains(storageProfile.imageReference.publisher,'Canonical')].name" -o tsv`
do
 az vm extension set \
 --resource-group $rg \
 --vm-name $vm \
 --name customScript \
 --publisher Microsoft.Azure.Extensions \
 --protected-settings "{\"fileUris\": [\"$nettoolsuri\"],\"commandToExecute\": \"./nettools.sh\"}" \
 --no-wait
done

echo Checking Hub1 provisioning status...
# Checking Hub1 provisioning and routing state 
prState=''
rtState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
    echo "$hub1name provisioningState="$prState
    sleep 5
done

while [[ $rtState != 'Provisioned' ]];
do
    rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
    echo "$hub1name routingState="$rtState
    sleep 5
done

echo Creating Hub1 vNET connections
# create spoke to Vwan connections to hub1
az network vhub connection create -n spoke1conn --remote-vnet spoke1 -g $rg --vhub-name $hub1name --no-wait
az network vhub connection create -n spoke2conn --remote-vnet spoke2 -g $rg --vhub-name $hub1name --no-wait
az network vhub connection create -n spoke3conn --remote-vnet spoke3 -g $rg --vhub-name $hub1name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke1conn --vhub-name $hub1name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke1conn provisioningState="$prState
    sleep 5
done

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke2conn --vhub-name $hub1name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke2conn provisioningState="$prState
    sleep 5
done

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke3conn --vhub-name $hub1name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke3conn provisioningState="$prState
    sleep 5
done

echo Creating Hub1 VPN Gateway...
# Creating VPN gateways in each Hub1
az network vpn-gateway create -n $hub1name-vpngw -g $rg --location $region1 --vhub $hub1name --no-wait 

echo Checking Hub2 provisioning status...
# Checking Hub2 provisioning and routing state 
prState=''
rtState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub show -g $rg -n $hub2name --query 'provisioningState' -o tsv)
    echo "$hub2name provisioningState="$prState
    sleep 5
done

while [[ $rtState != 'Provisioned' ]];
do
    rtState=$(az network vhub show -g $rg -n $hub2name --query 'routingState' -o tsv)
    echo "$hub2name routingState="$rtState
    sleep 5
done

# create spoke to Vwan connections to hub2
az network vhub connection create -n spoke4conn --remote-vnet spoke4 -g $rg --vhub-name $hub2name --no-wait
az network vhub connection create -n spoke5conn --remote-vnet spoke5 -g $rg --vhub-name $hub2name --no-wait
az network vhub connection create -n spoke6conn --remote-vnet spoke6 -g $rg --vhub-name $hub2name --no-wait

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke4conn --vhub-name $hub2name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke4conn provisioningState="$prState
    sleep 5
done

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke5conn --vhub-name $hub2name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke5conn provisioningState="$prState
    sleep 5
done

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub connection show -n spoke6conn --vhub-name $hub2name -g $rg  --query 'provisioningState' -o tsv)
    echo "vnet connection spoke6conn provisioningState="$prState
    sleep 5
done

echo Creating Hub2 VPN Gateway...
# Creating VPN gateways in each Hub2
az network vpn-gateway create -n $hub2name-vpngw -g $rg --location $region2 --vhub $hub2name --no-wait

echo Validating Branches VPN Gateways provisioning...
#Branches VPN Gateways provisioning status
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

prState=$(az network vnet-gateway show -g $rg -n branch2-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vnet-gateway delete -n branch2-vpngw -g $rg
    az network vnet-gateway create -n branch2-vpngw --public-ip-addresses branch2-vpngw-pip -g $rg --vnet branch2 --asn 65509 --gateway-type Vpn -l $region2 --sku VpnGw1 --vpn-gateway-generation Generation1 --no-wait 
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vnet-gateway show -g $rg -n branch2-vpngw --query provisioningState -o tsv)
        echo "branch2-vpngw provisioningState="$prState
        sleep 5
    done
fi

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

prState=$(az network vpn-gateway show -g $rg -n $hub2name-vpngw --query provisioningState -o tsv)
if [[ $prState == 'Failed' ]];
then
    echo VPN Gateway is in fail state. Deleting and rebuilding.
    az network vpn-gateway delete -n $hub2name-vpngw -g $rg
    az network vpn-gateway create -n $hub2name-vpngw -g $rg --location $region2 --vhub $hub2name --no-wait
    sleep 5
else
    prState=''
    while [[ $prState != 'Succeeded' ]];
    do
        prState=$(az network vpn-gateway show -g $rg -n $hub2name-vpngw --query provisioningState -o tsv)
        echo $hub2name-vpngw "provisioningState="$prState
        sleep 5
    done
fi

echo Building VPN connections from VPN Gateways to the respective Branches...
# get bgp peering and public ip addresses of VPN GW and VWAN to set up connection
# Branch 1 and Hub1 VPN Gateway variables
bgp1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
pip1=$(az network vnet-gateway show -n branch1-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip1=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh1gwbgp2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
vwanh1gwpip2=$(az network vpn-gateway show -n $hub1name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)

# Branch 2 and Hub2 VPN Gateway variables
bgp2=$(az network vnet-gateway show -n branch2-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
pip2=$(az network vnet-gateway show -n branch2-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh2gwbgp1=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv)
vwanh2gwpip1=$(az network vpn-gateway show -n $hub2name-vpngw  -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv)
vwanh2gwbgp2=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv)
vwanh2gwpip2=$(az network vpn-gateway show -n $hub2name-vpngw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv)

# create virtual wan vpn site
az network vpn-site create --ip-address $pip1 -n site-branch1 -g $rg --asn 65510 --bgp-peering-address $bgp1 -l $region1 --virtual-wan $vwanname --device-model 'Azure' --device-vendor 'Microsoft' --link-speed '50' --with-link true --output none
az network vpn-site create --ip-address $pip2 -n site-branch2 -g $rg --asn 65509 --bgp-peering-address $bgp2 -l $region2 --virtual-wan $vwanname --device-model 'Azure' --device-vendor 'Microsoft' --link-speed '50' --with-link true --output none

# create virtual wan vpn connection
az network vpn-gateway connection create --gateway-name $hub1name-vpngw -n site-branch1-conn -g $rg --enable-bgp true --remote-vpn-site site-branch1 --internet-security --shared-key 'abc123' --output none
az network vpn-gateway connection create --gateway-name $hub2name-vpngw -n site-branch2-conn -g $rg --enable-bgp true --remote-vpn-site site-branch2 --internet-security --shared-key 'abc123' --output none

# create connection from vpn gw to local gateway and watch for connection succeeded
az network local-gateway create -g $rg -n lng-$hub1name-gw1 --gateway-ip-address $vwanh1gwpip1 --asn 65515 --bgp-peering-address $vwanh1gwbgp1 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw1 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw1 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub1name-gw2 --gateway-ip-address $vwanh1gwpip2 --asn 65515 --bgp-peering-address $vwanh1gwbgp2 -l $region1 --output none
az network vpn-connection create -n branch1-to-$hub1name-gw2 -g $rg -l $region1 --vnet-gateway1 branch1-vpngw --local-gateway2 lng-$hub1name-gw2 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub2name-gw1 --gateway-ip-address $vwanh2gwpip1 --asn 65515 --bgp-peering-address $vwanh2gwbgp1 -l $region2 --output none
az network vpn-connection create -n branch2-to-$hub2name-gw1 -g $rg -l $region2 --vnet-gateway1 branch2-vpngw --local-gateway2 lng-$hub2name-gw1 --enable-bgp --shared-key 'abc123' --output none

az network local-gateway create -g $rg -n lng-$hub2name-gw2 --gateway-ip-address $vwanh2gwpip2 --asn 65515 --bgp-peering-address $vwanh2gwbgp2 -l $region2 --output none
az network vpn-connection create -n branch2-to-$hub2name-gw2 -g $rg -l $region2 --vnet-gateway1 branch2-vpngw --local-gateway2 lng-$hub2name-gw2 --enable-bgp --shared-key 'abc123' --output none

# Note: at this point you can test connectivity and the expected behavior is to have any-to-any connectivity using the default route table (by design vWAN behavior).
# Use instruction of validation section below if you want to test that connectivity.
echo Deployment has finished
```

### Validation

```bash
# Parameters 
rg=lab-vwan-a2a #set resource group

#### Validate connectivity between VNETs and Branches


# 1) Test connectivity between VMs (they can be accessible via SSH over Public IP or Serial Console)

#List of VMs Public IP for SSH access
az network public-ip list -g $rg --query "[].{name:name,ip:ipAddress}" -o table 

#List of VMs Private IPs
for nicname in `az network nic list -g $rg --query [].name -o tsv`
do 
echo -e $nicname private IP:
az network nic show -g $rg --name $nicname --query "ipConfigurations[].privateIPAddress" --output tsv
echo -e 
done

# For connectivity test you can also use curl or traceroute. For example from BranchVM1 or BranchVM2 run:
curl 10.2.1.4 #expected output spoke5VM
traceroute 10.2.1.4
ping 10.2.1.4 -O

# 2) Dump VMs route tables:
for nicname in `az network nic list -g $rg --query [].name -o tsv`
do 
echo -e $nicname effective routes:
az network nic show-effective-route-table -g $rg --name $nicname --output table
echo -e 
done

# 3) Dump all vHUBs route tables.
for vhubname in `az network vhub list -g $rg --query "[].id" -o tsv | rev | cut -d'/' -f1 | rev`
do
  for routetable in `az network vhub route-table list --vhub-name $vhubname -g $rg --query "[].id" -o tsv`
   do
   if [ "$(echo $routetable | rev | cut -d'/' -f1 | rev)" != "noneRouteTable" ]; then
     echo -e vHUB: $vhubname 
     echo -e Effective route table: $(echo $routetable | rev | cut -d'/' -f1 | rev)   
     az network vhub get-effective-routes -g $rg -n $vhubname \
     --resource-type RouteTable \
     --resource-id $routetable \
     --query "value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}" \
     --output table
     echo
    fi
   done
done

# Dump the Branches VPN Gateway routes:
vpngws=$(az network vnet-gateway list -g $rg --query [].name -o tsv) 
array=($vpngws)
for vpngw in "${array[@]}"
 do 
 echo "*** $vpngw BGP peer status ***"
 az network vnet-gateway list-bgp-peer-status -g $rg -n $vpngw -o table
 echo "*** $vpngw BGP learned routes ***"
 az network vnet-gateway list-learned-routes -g $rg -n $vpngw -o table
 echo
done

# VPN Gateways advertised routes per BGP peer.
vpngws=$(az network vnet-gateway list -g $rg --query [].name -o tsv) 
array=($vpngws)
for vpngw in "${array[@]}"
 do 
  ips=$(az network vnet-gateway list-bgp-peer-status -g $rg -n $vpngw --query 'value[].{ip:neighbor}' -o tsv)
  array2=($ips)
   for ip in "${array2[@]}"
   do
   echo *** $vpngw advertised routes to peer $ip ***
   az network vnet-gateway list-advertised-routes -g $rg -n $vpngw -o table --peer $ip
  done
 echo
done
```

### Clean-up

```bash
# Parameters 
rg=lab-vwan-a2a #set resource group

### Clean up
az group delete -g $rg --no-wait 
```
