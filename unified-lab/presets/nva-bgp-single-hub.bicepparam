using '../main.bicep'

param projectName = 'vwan-nva-bgp-single-hub'
param location = 'eastus'
param vwanType = 'Standard'

param hubs = [
  {
    name: 'vwan-hub1'
    location: 'eastus'
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: true
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

param deployBranches = true
param branches = [
  {
    name: 'branch1'
    location: 'eastus'
    addressPrefix: '172.16.1.0/24'
    gatewaySubnetPrefix: '172.16.1.0/27'
    bgpAsn: 65001
    connectedHub: 'vwan-hub1'
  }
]

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
]

param adminUsername = 'azureuser'
param deployLogAnalytics = true
