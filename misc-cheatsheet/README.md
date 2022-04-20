# Misc commands and useful tips when working with Virtual WAN


- Script to dump all vHUBs effective routes:

```bash
#vHUB effective routes

#parameters
rg=vwan-pair #Set your resource group

#variables (do not change)
#Parameter
$rg=vwan-pair

# Dump all vHUB route tables.
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
```

Expected output:

```bash
vHUB: NCUS-PAIR
Effective route table: defaultRouteTable
AddressPrefixes    AsPath             NextHopType
-----------------  -----------------  --------------------------
172.100.154.0/30   12076-65154        ExpressRouteGateway
10.100.20.0/24     12076-65154-16550  ExpressRouteGateway
172.100.112.0/30   12076-65112        ExpressRouteGateway
10.100.10.0/24     12076-65112-16550  ExpressRouteGateway
10.60.0.0/22       12076-12076-12076  ExpressRouteGateway
10.60.12.0/22      65520-65520        Remote Hub
10.60.4.0/22       65520-65520        Remote Hub
10.60.8.0/22       65520-65520        Remote Hub
10.70.4.0/22                          Virtual Network Connection
10.70.8.0/22                          Virtual Network Connection

vHUB: SCUS-PAIR
Effective route table: defaultRouteTable
AddressPrefixes    AsPath             NextHopType
-----------------  -----------------  --------------------------
10.100.20.0/24     12076-65154-16550  ExpressRouteGateway
172.100.154.0/30   12076-65154        ExpressRouteGateway
10.100.10.0/24     12076-65112-16550  ExpressRouteGateway
172.100.112.0/30   12076-65112        ExpressRouteGateway
10.70.0.0/22       12076-12076-12076  ExpressRouteGateway
10.70.4.0/22       65520-65520        Remote Hub
10.70.8.0/22       65520-65520        Remote Hub
10.60.8.0/22                          Virtual Network Connection
10.60.12.0/22                         Virtual Network Connection
10.60.4.0/22                          Virtual Network Connection

vHUB: SCUS-PAIR
Effective route table: nva-rt
AddressPrefixes    NextHopType
-----------------  --------------------------
10.60.12.0/22      Virtual Network Connection
```
