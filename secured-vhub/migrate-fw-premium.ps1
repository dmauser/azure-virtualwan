$hubname="svhub"
$fwname="$hubname-azfw" 
$rg="lab-vwan-svh-eus"
$fwpolicyname="$hubname-fwpolicy"

#Stop
$azfw = Get-AzFirewall -Name $fwname -ResourceGroupName $rg
$azfw.Deallocate()
Set-AzFirewall -AzureFirewall $azfw

#Start
$azfw = Get-AzFirewall -Name -Name "<firewall-name>" -ResourceGroupName $rg
$hub = Get-azvirtualhub -ResourceGroupName $rg -name $hubname
$azfw.Allocate($hub.id)
Set-AzFirewall -AzureFirewall $azfw


#Upgrade to Premium
$azfw = Get-AzFirewall -Name -Name "<firewall-name>" -ResourceGroupName $rg
$hub = Get-azvirtualhub -ResourceGroupName $rg -name $hubname
$azfw.Sku.Tier="Premium"
$azfw.Allocate($hub.id)
Set-AzFirewall -AzureFirewall $azfw