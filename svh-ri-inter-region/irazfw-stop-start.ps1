# PS Script to stop and star Azure Firewall

# Login to Azure
Connect-AzAccount

# Select Azure Subscription
$subscription = Get-AzSubscription | Out-GridView -Title "Select an Azure Subscription" -PassThru

# Set Azure Subscription
Set-AzContext -Subscription DMAUSER-FDPO

#Variables 
$RG = "lab-svh-inter"

#Stop Firewall

$virtualhub = get-azvirtualhub -ResourceGroupName $RG -name vwan-hub-ne
$firewall = Get-AzFirewall -Name "AzureFirewall_VWAN-Hub-NE" -ResourceGroupName "GBB-ER-LAB-WE"
$firewall.Allocate($virtualhub.Id)
$firewall | Set-AzFirewall

# Get Azure Firewall names and stop them
$azfw = Get-AzFirewall -ResourceGroupName $RG
$azfw | ForEach-Object -Parallel {
    $_.Deallocate() 
    Write-Host "Stopping Azure Firewall" $_.name
    Set-AzFirewall -AzureFirewall $_ | Out-Null
    Write-Host "Azure Firewall" $_.name "has stopped"
}

# Update Azure PowerShell
Update-Module -Name Az -Force -Scope CurrentUser


# List all resource groups in the subscription
Get-AzResourceGroup -Location WestCentralUS | Select-Object ResourceGroupName,Location

# Get all Azure VMs from the resource group
Get-AzVM -ResourceGroupName lab-svh-inter | Select-Object Name,ResourceGroupName,Location,PowerState
