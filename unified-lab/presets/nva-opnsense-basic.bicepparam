using '../main.bicep'

param projectName = 'vwan-nva-opnsense-basic'
param location = 'eastus'
param vwanType = 'Standard'

param hubs = [
  {
    name: 'vwan-hub1'
    location: 'eastus'
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: false
    deployErGateway: false
    deployFirewall: false
  }
]

param spokes = [
  {
    name: 'spoke1'
    location: 'eastus'
    addressPrefix: '10.1.0.0/24'
    subnetPrefix: '10.1.0.0/25'
    associatedHub: 'vwan-hub1'
    deployVm: true
  }
  {
    name: 'spoke2'
    location: 'eastus'
    addressPrefix: '10.2.0.0/24'
    subnetPrefix: '10.2.0.0/25'
    associatedHub: 'vwan-hub1'
    deployVm: true
  }
]

param deployBranches = false
param branches = []

param nvaConfigs = [
  {
    nvaType: 'opnsense'
    placement: 'spoke'
    spokeReference: 'spoke2'
    addressPrefix: '10.2.0.0/25'
    privateIp: '10.2.0.4'
    bgpAsn: 0
    enableHubBgpPeering: false
    deployIlb: false
  }
]

param adminUsername = 'azureuser'
param deployLogAnalytics = false
