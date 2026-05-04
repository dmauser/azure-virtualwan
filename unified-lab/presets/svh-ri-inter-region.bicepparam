using '../main.bicep'

param labName = 'vwan-lab'
param primaryLocation = 'eastus2'
param secondaryLocation = 'westus2'
param vwanType = 'Standard'

param hubs = [
  {
    name: 'vwan-lab-hub1'
    location: 'eastus2'
    addressPrefix: '192.168.0.0/23'
    deployVpnGateway: true
    deployErGateway: false
    deployFirewall: true
    firewallSku: 'Standard'
    enableRoutingIntent: true
    routingIntentMode: 'InternetAndPrivate'
  }
  {
    name: 'vwan-lab-hub2'
    location: 'westus2'
    addressPrefix: '192.168.2.0/23'
    deployVpnGateway: true
    deployErGateway: false
    deployFirewall: true
    firewallSku: 'Standard'
    enableRoutingIntent: true
    routingIntentMode: 'InternetAndPrivate'
  }
]

param spokes = [
  {
    name: 'spoke1'
    location: 'eastus2'
    addressPrefix: '10.1.0.0/16'
    subnetPrefix: '10.1.1.0/24'
    associatedHub: 'vwan-lab-hub1'
    deployVm: true
  }
  {
    name: 'spoke2'
    location: 'eastus2'
    addressPrefix: '10.2.0.0/16'
    subnetPrefix: '10.2.1.0/24'
    associatedHub: 'vwan-lab-hub1'
    deployVm: true
  }
  {
    name: 'spoke3'
    location: 'westus2'
    addressPrefix: '10.3.0.0/16'
    subnetPrefix: '10.3.1.0/24'
    associatedHub: 'vwan-lab-hub2'
    deployVm: true
  }
  {
    name: 'spoke4'
    location: 'westus2'
    addressPrefix: '10.4.0.0/16'
    subnetPrefix: '10.4.1.0/24'
    associatedHub: 'vwan-lab-hub2'
    deployVm: true
  }
]

param deployBranches = true
param branches = [
  {
    name: 'branch1'
    location: 'eastus2'
    addressPrefix: '172.16.1.0/24'
    gatewaySubnetPrefix: '172.16.1.0/27'
    bgpAsn: 65010
    connectedHub: 'vwan-lab-hub1'
  }
  {
    name: 'branch2'
    location: 'westus2'
    addressPrefix: '172.16.2.0/24'
    gatewaySubnetPrefix: '172.16.2.0/27'
    bgpAsn: 65020
    connectedHub: 'vwan-lab-hub2'
  }
]

param adminUsername = 'azureuser'
param deployLogAnalytics = true
