# PS Script to stop and star Azure Firewall

#Variables 
$RG = "lab-vwan-irazfw"

#Stop Firewall

$azfw=Get-AzFirewall -ResourceGroupName $RG
$azfw | ForEach-Object -Parallel {
    $_.Deallocate() 
    Write-Host "Stopping Azure Firewall" $_.name
    Set-AzFirewall -AzureFirewall $_ | Out-Null
    Write-Host "Azure Firewall" $_.name "has stopped"
}

#Start Firewall

$azfw=Get-AzFirewall -ResourceGroupName $RG
$azfw | ForEach-Object -Parallel {
    $publicip = Get-AzPublicIpAddress -ResourceGroupName $RG -Name ($_.name + '-pip')
    $vnet = Get-AzVirtualNetwork -name ($_.name).trim("-azfw") -ResourceGroupName $RG
    $_.Allocate($vnet,$publicip) 
    Write-Host "Starting Azure Firewall" $_.name
    Set-AzFirewall -AzureFirewall $_ | Out-Null
    Write-Host "Azure Firewall" $_.name "has started"
}


