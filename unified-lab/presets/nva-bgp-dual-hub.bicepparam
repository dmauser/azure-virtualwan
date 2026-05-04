using '../main.bicep'

param projectName = 'vwan-nva-bgp-dual-hub'
param primaryLocation = 'eastus'
param secondaryLocation = 'westus2'
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
  {
    name: 'vwan-hub2'
    location: 'westus2'
    addressPrefix: '10.10.0.0/23'
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
  {
    name: 'spoke3'
    location: 'eastus'
    addressPrefix: '10.3.0.0/24'
    subnetPrefix: '10.3.0.0/25'
    associatedHub: 'vwan-hub1'
    deployVm: true
  }
  {
    name: 'spoke4'
    location: 'westus2'
    addressPrefix: '10.11.0.0/24'
    subnetPrefix: '10.11.0.0/25'
    associatedHub: 'vwan-hub2'
    deployVm: true
  }
  {
    name: 'spoke5'
    location: 'westus2'
    addressPrefix: '10.12.0.0/24'
    subnetPrefix: '10.12.0.0/25'
    associatedHub: 'vwan-hub2'
    deployVm: true
  }
  {
    name: 'spoke6'
    location: 'westus2'
    addressPrefix: '10.13.0.0/24'
    subnetPrefix: '10.13.0.0/25'
    associatedHub: 'vwan-hub2'
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
  {
    name: 'branch2'
    location: 'westus2'
    addressPrefix: '172.16.2.0/24'
    gatewaySubnetPrefix: '172.16.2.0/27'
    bgpAsn: 65002
    connectedHub: 'vwan-hub2'
  }
]

param nvaConfigs = [
  {
    nvaType: 'linux-frr'
    placement: 'spoke'
    spokeReference: 'spoke3'
    addressPrefix: '10.3.0.0/25'
    privateIp: '10.3.0.4'
    bgpAsn: 65010
    enableHubBgpPeering: true
    deployIlb: false
  }
  {
    nvaType: 'linux-frr'
    placement: 'spoke'
    spokeReference: 'spoke6'
    addressPrefix: '10.13.0.0/25'
    privateIp: '10.13.0.4'
    bgpAsn: 65020
    enableHubBgpPeering: true
    deployIlb: false
  }
]

param adminUsername = 'azureuser'
param deployLogAnalytics = true
