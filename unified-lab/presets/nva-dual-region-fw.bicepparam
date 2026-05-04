using '../main.bicep'

param projectName = 'vwan-nva-dual-region-fw'
param primaryLocation = 'eastus'
param secondaryLocation = 'westus2'
param vwanType = 'Standard'

param hubs = [
  {
    name: 'vwan-hub1'
    location: 'eastus'
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: false
    deployErGateway: false
    deployFirewall: true
    firewallSku: 'Standard'
    enableRoutingIntent: false
  }
  {
    name: 'vwan-hub2'
    location: 'westus2'
    addressPrefix: '10.10.0.0/23'
    deployVpnGateway: false
    deployErGateway: false
    deployFirewall: true
    firewallSku: 'Standard'
    enableRoutingIntent: false
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
  {
    name: 'spoke3'
    location: 'westus2'
    addressPrefix: '10.11.0.0/24'
    subnetPrefix: '10.11.0.0/25'
    associatedHub: 'vwan-hub2'
    deployVm: true
  }
  {
    name: 'spoke4'
    location: 'westus2'
    addressPrefix: '10.12.0.0/24'
    subnetPrefix: '10.12.0.0/25'
    associatedHub: 'vwan-hub2'
    deployVm: true
  }
]

param deployBranches = false
param branches = []

param nvaConfigs = [
  {
    nvaType: 'linux-frr'
    placement: 'spoke'
    spokeReference: 'spoke2'
    addressPrefix: '10.2.0.0/25'
    privateIp: '10.2.0.4'
    bgpAsn: 65010
    enableHubBgpPeering: true
    deployIlb: false
  }
  {
    nvaType: 'linux-frr'
    placement: 'spoke'
    spokeReference: 'spoke4'
    addressPrefix: '10.12.0.0/25'
    privateIp: '10.12.0.4'
    bgpAsn: 65020
    enableHubBgpPeering: true
    deployIlb: false
  }
]

param adminUsername = 'azureuser'
param deployLogAnalytics = true
