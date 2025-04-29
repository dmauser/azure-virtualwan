#!/bin/bash

# Parameters (make changes based on your requirements)
region1=eastus2 #set region1
region2=centralus #set region2
rg=lab-svh-inter #set resource group
vwanname=svh-inter #set vWAN name
hub1name=sechub1 #set Hub1 name
hub2name=sechub2 #set Hub2 name
username=azureuser #set username
password="Msft123Msft123" #set password
vmsize=Standard_DS1_v2 #set VM Size

# Pre-Requisites
# Check if virtual wan extension is installed if not install it
if ! az extension list | grep -q virtual-wan; then
    echo "virtual-wan extension is not installed, installing it now..."
    az extension add --name virtual-wan --only-show-errors
fi

# Check if azure-firewall extension is installed if not install it
if ! az extension list | grep -q azure-firewall; then
    echo "azure-firewall extension is not installed, installing it now..."
    az extension add --name azure-firewall --only-show-errors
fi

# Validate Firewall SKU
if [ "$1" == "basic" ]; then
    firewalltier=basic
elif [ "$1" == "standard" ]; then
    firewalltier=standard
elif [ "$1" == "premium" ]; then
    firewalltier=premium
elif [ "$1" == "help" ]; then
    echo "Usage: ./vwan-irazfw.sh [basic|standard|premium]"
    exit 0
elif [ -z "$1" ]; then
    echo "No parameter passed, setting Azure Firewall to basic tier"
    firewalltier=basic
fi

# Adding script starting time and finish time
start=`date +%s`
echo "Script started at $(date)"

#Variables
mypip=$(curl -4 ifconfig.io -s)

# Check if VM size is available in both regions using az vm list-skus and checking restrictions is set to null
echo "Checking for VM Size availability in both regions ($region1 and $region2)..."
if [[ $(az vm list-skus -l $region1 --size $vmsize --all --query [?restrictions] -o tsv) != '' ]]; then
    echo "VM Size $vmsize is not available in $region1, please choose a different VM size or Region"
    exit 1
fi
if [[ $(az vm list-skus -l $region2 --size $vmsize --all --query [?restrictions] -o tsv) != '' ]]; then
    echo "VM Size $vmsize is not available in $region2, please choose a different VM size or Region"  
    exit 1
fi

# Create resouce group
az group create -n $rg -l $region1 --output none

echo Creating vwan and both hubs...
# create virtual wan
az network vwan create -g $rg -n $vwanname --branch-to-branch-traffic true --location $region1 --type Standard --output none
az network vhub create -g $rg --name $hub1name --address-prefix 192.168.1.0/24 --vwan $vwanname --location $region1 --sku Standard --no-wait
az network vhub create -g $rg --name $hub2name --address-prefix 192.168.2.0/24 --vwan $vwanname --location $region2 --sku Standard --no-wait

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

echo Creating NSGs in both regions...
#Update NSGs:
az network nsg create --resource-group $rg --name default-nsg-$hub1name-$region1 --location $region1 -o none
az network nsg create --resource-group $rg --name default-nsg-$hub2name-$region2 --location $region2 -o none
# Add my home public IP to NSG for SSH acess
az network nsg rule create -g $rg --nsg-name default-nsg-$hub1name-$region1 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
az network nsg rule create -g $rg --nsg-name default-nsg-$hub2name-$region2 -n 'default-allow-ssh' --direction Inbound --priority 100 --source-address-prefixes $mypip --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --access Allow --protocol Tcp --description "Allow inbound SSH" --output none
# Associated NSG to the VNET subnets (Spokes and Branches)
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region1'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$hub1name-$region1 -o none
az network vnet subnet update --id $(az network vnet list -g $rg --query '[?location==`'$region2'`].{id:subnets[0].id}' -o tsv) --network-security-group default-nsg-$hub2name-$region2 -o none

echo Creating Spoke VMs...
# create a VM in each connected spoke
az vm create -n spoke1VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke1 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke2VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke2 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke3VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region1 --subnet main --vnet-name spoke3 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke4VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke4 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke5VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke5 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
az vm create -n spoke6VM  -g $rg --image Ubuntu2204 --public-ip-sku Standard --size $vmsize -l $region2 --subnet main --vnet-name spoke6 --admin-username $username --admin-password $password --nsg "" --no-wait --only-show-errors
# Continue only if all VMs are created
echo Waiting VMs to complete provisioning...
az vm wait -g $rg --created --ids $(az vm list -g $rg --query '[].{id:id}' -o tsv) --only-show-errors -o none
#Enabling boot diagnostics for all VMs in the resource group 
echo Enabling boot diagnostics for all VMs in the resource group...
# enable boot diagnostics for all VMs in the resource group
az vm boot-diagnostics enable --ids $(az vm list -g $rg --query '[].{id:id}' -o tsv) -o none
### Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others (check link below for more details) 
echo Installing tools for networking connectivity validation such as traceroute, tcptraceroute, iperf and others...
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

echo Creating $hub1name Azure Firewall Policy
#Create firewall rules
fwpolicyname=$hub1name-fwpolicy #Firewall Policy Name
az network firewall policy create --name $fwpolicyname --resource-group $rg --sku $firewalltier --output none --only-show-errors
az network firewall policy rule-collection-group create --name NetworkRuleCollectionGroup --priority 200 --policy-name $fwpolicyname --resource-group $rg --output none --only-show-errors
#Adding any-to-any firewall rule
az network firewall policy rule-collection-group collection add-filter-collection \
 --resource-group $rg \
 --policy-name $fwpolicyname \
 --name GenericCollection \
 --rcg-name NetworkRuleCollectionGroup \
 --rule-type NetworkRule \
 --rule-name AnytoAny \
 --action Allow \
 --ip-protocols "Any" \
 --source-addresses "*" \
 --destination-addresses  "*" \
 --destination-ports "*" \
 --collection-priority 100 \
 --output none

echo Deploying Azure Firewall inside $hub1name vHub ...
fwpolid=$(az network firewall policy show --resource-group $rg --name $fwpolicyname --query id --output tsv)
az network firewall create -g $rg -n $hub1name-azfw --sku AZFW_Hub --tier $firewalltier --virtual-hub $hub1name --public-ip-count 1 --firewall-policy $fwpolid --location $region1 --output none

echo Enabling $hub1name Azure Firewall diagnostics...

echo Checking MS Insights subscription registration state
msinsights=$(az provider show -n microsoft.insights --query registrationState -o tsv)
if [ $msinsights == 'NotRegistered' ] || [ $msinsights == 'Unregistered' ]; then
az provider register -n microsoft.insights --accept-terms
 prState=''
 while [[ $prState != 'Registered' ]];
 do
    prState=$(az provider show -n microsoft.insights --query registrationState -o tsv)
    echo "MS Insights State="$prState
    sleep 5
 done
fi

## Log Analytics workspace name. 
Workspacename=$hub1name-$region1-Logs

#Creating Log Analytics Workspaces
az monitor log-analytics workspace create -g $rg --workspace-name $Workspacename --location $region1 --output none

#EnablingAzure Firewall diagnostics
az monitor diagnostic-settings create -n 'toLogAnalytics' \
--resource $(az network firewall show --name $hub1name-azfw --resource-group $rg --query id -o tsv) \
--workspace $(az monitor log-analytics workspace show -g $rg --workspace-name $Workspacename --query id -o tsv) \
--logs '[{"category":"AzureFirewallApplicationRule","Enabled":true}, {"category":"AzureFirewallNetworkRule","Enabled":true}, {"category":"AzureFirewallDnsProxy","Enabled":true}]' \
--metrics '[{"category": "AllMetrics","enabled": true}]' \
--output none

echo Creating $hub2name Azure Firewall Policy
#Create firewall rules
fwpolicyname=$hub2name-fwpolicy #Firewall Policy Name
az network firewall policy create --name $fwpolicyname --resource-group $rg --sku $firewalltier --output none --only-show-errors
az network firewall policy rule-collection-group create --name NetworkRuleCollectionGroup --priority 200 --policy-name $fwpolicyname --resource-group $rg --output none --only-show-errors
#Adding any-to-any firewall rule
az network firewall policy rule-collection-group collection add-filter-collection \
 --resource-group $rg \
 --policy-name $fwpolicyname \
 --name GenericCollection \
 --rcg-name NetworkRuleCollectionGroup \
 --rule-type NetworkRule \
 --rule-name AnytoAny \
 --action Allow \
 --ip-protocols "Any" \
 --source-addresses "*" \
 --destination-addresses  "*" \
 --destination-ports "*" \
 --collection-priority 100 \
 --output none

echo Deploying Azure Firewall inside $hub2name vHub...
fwpolid=$(az network firewall policy show --resource-group $rg --name $fwpolicyname --query id --output tsv)
az network firewall create -g $rg -n $hub2name-azfw --sku AZFW_Hub --tier $firewalltier --virtual-hub $hub2name --public-ip-count 1 --firewall-policy $fwpolid --location $region2 --output none

echo Enabling $hub2name Azure Firewall diagnostics...
## Log Analytics workspace name. 
Workspacename=$hub2name-$region2-Logs

#Creating Log Analytics Workspaces
az monitor log-analytics workspace create -g $rg --workspace-name $Workspacename --location $region2 --output none

echo Enabling Azure Firewall diagnostics
az monitor diagnostic-settings create -n 'toLogAnalytics' \
--resource $(az network firewall show --name $hub2name-azfw --resource-group $rg --query id -o tsv) \
--workspace $(az monitor log-analytics workspace show -g $rg --workspace-name $Workspacename --query id -o tsv) \
--logs '[{"category":"AzureFirewallApplicationRule","Enabled":true}, {"category":"AzureFirewallNetworkRule","Enabled":true}, {"category":"AzureFirewallDnsProxy","Enabled":true}]' \
--metrics '[{"category": "AllMetrics","enabled": true}]' \
--output none

#Enabling Secured-vHUB + Routing intenet
echo "Enabling Secured-vHUB + Routing intent (Private and Internet Traffic)"
nexthophub1=$(az network vhub show -g $rg -n $hub1name --query azureFirewall.id -o tsv)
az deployment group create --name $hub1name-ri \
--resource-group $rg \
--template-uri https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/svh-ri-inter-region/bicep/main.json \
--parameters scenarioOption=Private-and-Internet hubname=$hub1name nexthop=$nexthophub1 \
--no-wait

nexthophub2=$(az network vhub show -g $rg -n $hub2name --query azureFirewall.id -o tsv)
az deployment group create --name $hub2name-ri \
--resource-group $rg \
--template-uri https://raw.githubusercontent.com/dmauser/azure-virtualwan/main/svh-ri-inter-region/bicep/main.json \
--parameters scenarioOption=Private-and-Internet hubname=$hub2name nexthop=$nexthophub2 \
--no-wait

subid=$(az account list --query "[?isDefault == \`true\`].id" --all -o tsv)
prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az rest --method get --uri /subscriptions/$subid/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub1name/routingIntent/$hub1name_RoutingIntent?api-version=2022-01-01 --query 'value[].properties.provisioningState' -o tsv)
    echo "$hub1name routing intent provisioningState="$prState
    sleep 5
done
prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az rest --method get --uri /subscriptions/$subid/resourceGroups/$rg/providers/Microsoft.Network/virtualHubs/$hub2name/routingIntent/$hub2name_RoutingIntent?api-version=2022-01-01 --query 'value[].properties.provisioningState' -o tsv)
    echo "$hub2name routing intent provisioningState="$prState
    sleep 5
done
echo Base Deployment has finished
# Add script ending time but hours, minutes and seconds
end=`date +%s`
runtime=$((end-start))
echo "Script finished at $(date)"
echo "Total script execution time: $(($runtime / 3600)) hours $((($runtime / 60) % 60)) minutes and $(($runtime % 60)) seconds."
