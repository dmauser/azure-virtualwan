# LAB: Azure Virtual WAN using NVA on Spoke for Internet

### Diagram

![NVA Spoke to Internet](./media/nva-spoke-internet.png)


### Lab steps:

```Bash
##Parameters (make changes based on your needs)
rg="vwan-lxnva-lab"
location="centralus"
hubname="vhub1"
username=azureuser
password=Msft123Msft123

#Variables
let "randomIdentifier=$RANDOM*$RANDOM" #used to create unique storage account name.
nvavnet=Spoke1 #NVA VNET Name
connname=to-spoke1 #vWAN connection name
mypip=$(curl -s -4 ifconfig.io)

#Resource Group
az group create --name $rg --location $location -o none

#Create VWAN Hub
az network vwan create --name VWAN --resource-group $rg --branch-to-branch-traffic true --location $location -o none
az network vhub create --address-prefix 192.168.0.0/24 --name $hubname --resource-group $rg --vwan VWAN --location $location --sku basic --no-wait

#Create Spoke1 and linux-nva
az network vnet create --resource-group $rg --name Spoke1 --location $location --address-prefixes 10.1.0.0/16 --subnet-name nvasubnet --subnet-prefix 10.1.0.0/24 -o none

#NVA + Config script to enable NAT
az network public-ip create --name linux-nva-pip --resource-group $rg --idle-timeout 30 --allocation-method Static -o none
az network nic create --name linux-nva-nic --resource-group $rg --subnet nvasubnet --vnet Spoke1 --public-ip-address linux-nva-pip --ip-forwarding true -o none
az vm create --resource-group $rg --location $location --name linux-nva --size Standard_B1s --nics linux-nva-nic  --image UbuntuLTS --admin-username $username --admin-password $password -o none
#Enable routing and NAT on Linux NVA:
scripturi="https://raw.githubusercontent.com/dmauser/AzureVM-Router/master/linuxrouter.sh"
az vm extension set --resource-group $rg --vm-name linux-nva  --name customScript --publisher Microsoft.Azure.Extensions \
--protected-settings "{\"fileUris\": [\"$scripturi\"],\"commandToExecute\": \"./linuxrouter.sh\"}" \
--no-wait

## Create Spoke2 VNET and Spoke2 VM
az network vnet create --resource-group $rg --name Spoke2 --location $location --address-prefixes 10.2.0.0/16 --subnet-name Spoke2VM --subnet-prefix 10.2.10.0/24 -o none
az network public-ip create --name Spoke2VMPubIP --resource-group $rg --location $location --allocation-method Dynamic -o none
az network nic create --resource-group $rg -n Spoke2VMNIC --location $location --subnet Spoke2VM --vnet-name Spoke2 --public-ip-address Spoke2VMPubIP --private-ip-address 10.2.10.4 -o none
az VM create -n Spoke2VM --resource-group $rg --image UbuntuLTS --admin-username $username --admin-password $password --nics Spoke2VMNIC --no-wait -o none

#Create NSG to allow SSH from Remote IP and allow RFC1918 (required by NVA)
az network nsg create --resource-group $rg --name default-nsg --location $location -o none
az network nsg rule create -g $rg --nsg-name default-nsg -n default-allow-ssh \
    --direction Inbound \
    --priority 100 \
    --source-address-prefixes $mypip/32 \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges 22 \
    --access Allow \
    --protocol Tcp \
    --description "Allow inbound SSH" \
    --output none
az network nsg rule create -g $rg --nsg-name default-nsg -n allow-RFC-1918 \
    --direction Inbound \
    --priority 110 \
    --source-address-prefixes 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --access Allow \
    --protocol '*' \
    --description "Allow-Traffic-RFC-1918" \
    --output none
az network vnet subnet update --name nvasubnet --resource-group $rg --vnet-name $nvavnet --network-security-group default-nsg -o none
az network vnet subnet update --name Spoke2VM --resource-group $rg --vnet-name Spoke2 --network-security-group default-nsg -o none

#Enable boot diagnostics for all VMs in the resource group (Serial console)
#Create Storage Account (boot diagnostics + serial console)
az storage account create -n sc$randomIdentifier -g $rg -l $location --sku Standard_LRS -o none
#Enable boot diagnostics
stguri=$(az storage account show -n sc$randomIdentifier -g $rg --query primaryEndpoints.blob -o tsv)
az vm boot-diagnostics enable --storage $stguri --ids $(az vm list -g $rg --query "[].id" -o tsv) -o none

#UDRs
### UDR to force NVA go out the Internet (it does not get affected by 0/0 propagated by vHUB)
az network route-table create --name linux-nva-RT --resource-group $rg --location $location -o none
az network route-table route create --resource-group $rg --name to-Internet --route-table-name linux-nva-RT --address-prefix 0.0.0.0/0 --next-hop-type Internet -o none
az network vnet subnet update --name nvasubnet --vnet-name Spoke1 --resource-group $rg --route-table linux-nva-RT -o none

### Make exception to remote SSH Spoke2VM from Home Public IP
az network route-table create --name Spoke2VM-RT --resource-group $rg --location $location -o none
az network route-table route create --resource-group $rg --name to-HomePIP --route-table-name Spoke2VM-RT --address-prefix $mypip/32 --next-hop-type Internet -o none
az network vnet subnet update --name Spoke2VM --vnet-name Spoke2 --resource-group $rg --route-table Spoke2VM-RT -o none

## Waiting vHUB Hub and routing state to Provisioned before proceeding with the next steps.

prState=''
rtState=''
start_time=`date +%s`
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network vhub show -g $rg -n $hubname --query 'provisioningState' -o tsv)
    echo "$hubname provisioningState="$prState
    sleep 5
done
run_time=$(expr `date +%s` - $start_time)
((minutes=${run_time}/60))
((seconds=${run_time}%60))
echo "vWAN Hub $hubname provisioning state is $prState, wait time $minutes minutes and $seconds seconds"

start_time=`date +%s`
while [[ $rtState != 'Provisioned' ]];
do
    rtState=$(az network vhub show -g $rg -n $hubname --query 'routingState' -o tsv)
    echo "$hubname routingState="$rtState
    sleep 5
done
run_time=$(expr `date +%s` - $start_time)
((minutes=${run_time}/60))
((seconds=${run_time}%60))
echo "vWAN Hub $hubname routing state is $prState, wait time $minutes minutes and $seconds seconds"

# az network vhub connection create --name to-Spoke1 --resource-group $rg --remote-vnet Spoke1 --vhub-name $hubname
lxnvaip=$(az network nic show -n linux-nva-nic -g $rg --query "ipConfigurations[].privateIPAddress" -o tsv)
az network vhub connection create --name to-Spoke2 --resource-group $rg --remote-vnet Spoke2 --vhub-name $hubname -o none
vnetid=$(az network vnet show -g $rg -n Spoke1 --query id --out tsv)
az network vhub connection create --name to-Spoke1 --resource-group $rg --remote-vnet $vnetid --vhub-name $hubname --route-name default --address-prefixes "0.0.0.0/0" --next-hop "$lxnvaip" -o none
connid=$(az network vhub connection show -g $rg -n to-Spoke1 --vhub-name $hubname --query id -o tsv)
az network vhub route-table route add --name defaultRouteTable --vhub-name $hubname --resource-group $rg --route-name default --destination-type CIDR --destinations "0.0.0.0/0" --next-hop-type ResourceID --next-hop $connid -o none

```

```bash
### VALIDATIONS ####

##1) Display Linux NVA Public IP (linux-nva)
az network public-ip show --name linux-nva-pip --resource-group $rg --query ipAddress -o tsv
##2) SpokeVM2 Effective Route table - You should see 0/0 next hop VirtualNetwork Gateway which is the Route Service in vWAN.
az network nic show-effective-route-table --resource-group $rg -n Spoke2VMNIC -o table
##3) SSH to the VM and test the tools are present (traceroute and others)
pip=$(az network public-ip show --name Spoke2VMPubIP --resource-group $rg --query ipAddress -o tsv)
ssh $username@$pip
## Note: if you have trouble over SSH for NSG restriction you can access Spoke2VM over Serial Console

# 1) Check if you can ping a remote IP:
Ping 8.8.8.8
# 2) Run curl localhost and you should see your VM name.
curl ifconfig.io
# Expected output is Linux NVA Public IP (1 as shown above).

#### Misc/Troubleshooting - Remove stale route tables based on error code: DuplicateRouteNames:
az network vhub route-table route remove --name defaultRouteTable --vhub-name $hubname --resource-group $rg --index 1

### Clean up
az group delete -g $rg --no-wait 
```