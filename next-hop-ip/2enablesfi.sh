echo "Checking Hub1 provisioning status..."
prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
while [[ $prState != 'Succeeded' ]]; do
    echo "provisioningState=$prState"
    sleep 5
    prState=$(az network vhub show -g $rg -n $hub1name --query 'provisioningState' -o tsv)
done
echo "provisioningState=Succeeded (done)"

rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
while [[ $rtState != 'Provisioned' ]]; do
    echo "routingState=$rtState"
    sleep 5
    rtState=$(az network vhub show -g $rg -n $hub1name --query 'routingState' -o tsv)
done
echo "routingState=Provisioned (done)"