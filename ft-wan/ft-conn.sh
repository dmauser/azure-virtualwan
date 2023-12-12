#!/bin/bash
# variables (make changes based on your requirements)
region=southcentralus
rg=lab-vwan-vpner
vwanname=vwan-vpner
hubname=vhub1

#ExpressRoute specific variables
ername1="ft-$hubname-er-circuit" 
perloc1="Chicago"
providerloc1=Megaport

# Validating Circuits Provider privisionaing status:
echo Validating Circuits Provider privisionaing status...
# $ername1
if  [ $(az network express-route show -g $rg --name $ername1 --query serviceProviderProvisioningState -o tsv) == 'Provisioned' ]; then
 echo "$ername1=Provisioned"
else
 echo $(az network express-route show -g $rg --name $ername1 --query serviceProviderProvisioningState -o tsv)
 echo "Please proceeed with the ER Circuit $ername1 provisioning with your Service Provider before proceed"
fi
echo Validating Circuits Provider privisionaing status...

# Connect vuhb1 to ErCircuit1
echo connecting vuhb1 to $ername1
peering1=$(az network express-route show -g $rg --name $ername1 --query peerings[].id -o tsv)
routetableid=$(az network vhub route-table show --name defaultRouteTable --vhub-name $hubname -g $rg --query id -o tsv)
az network express-route gateway connection create --name connection-to-$ername1 -g $rg --gateway-name $hubname-ergw --peering $peering1 --associated-route-table $routetableid  --propagated-route-tables $routetableid --labels default &>/dev/null &

prState=''
while [[ $prState != 'Succeeded' ]];
do
    prState=$(az network express-route gateway connection show --name connection-to-$ername1 -g $rg --gateway-name $hubname-ergw --query 'provisioningState' -o tsv)
    echo "ER connection connection-to-$ername1 provisioningState="$prState
    sleep 5
done



