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
    deployFirewall: false
    firewallSku: 'Standard'
    enableRoutingIntent: false
    routingIntentMode: 'PrivateOnly'
  }
  {
    name: 'vwan-lab-hub2'
    location: 'westus2'
    addressPrefix: '192.168.2.0/23'
    deployVpnGateway: true
    deployErGateway: false
    deployFirewall: false
    firewallSku: 'Standard'
    enableRoutingIntent: false
    routingIntentMode: 'PrivateOnly'
  }
]

param spokes = [
  {
    name: 'spoke1-blue'
    location: 'eastus2'
    addressPrefix: '10.1.0.0/16'
    subnetPrefix: '10.1.1.0/24'
    associatedHub: 'vwan-lab-hub1'
    deployVm: true
    routeTableLabel: 'RT_BLUE'
  }
  {
    name: 'spoke2-blue'
    location: 'eastus2'
    addressPrefix: '10.2.0.0/16'
    subnetPrefix: '10.2.1.0/24'
    associatedHub: 'vwan-lab-hub1'
    deployVm: true
    routeTableLabel: 'RT_BLUE'
  }
  {
    name: 'spoke3-red'
    location: 'eastus2'
    addressPrefix: '10.3.0.0/16'
    subnetPrefix: '10.3.1.0/24'
    associatedHub: 'vwan-lab-hub1'
    deployVm: true
    routeTableLabel: 'RT_RED'
  }
  {
    name: 'spoke4-red'
    location: 'westus2'
    addressPrefix: '10.4.0.0/16'
    subnetPrefix: '10.4.1.0/24'
    associatedHub: 'vwan-lab-hub2'
    deployVm: true
    routeTableLabel: 'RT_RED'
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
]

param adminUsername = 'azureuser'
param deployLogAnalytics = false
