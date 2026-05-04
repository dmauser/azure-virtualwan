using '../main.bicep'

param projectName = 'vwan-er-basic'
param primaryLocation = 'eastus'
param vwanType = 'Standard'

param hubs = [
  {
    name: 'vwan-hub1'
    location: 'eastus'
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: false
    deployErGateway: true
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

param nvaConfigs = []

param adminUsername = 'azureuser'
param deployLogAnalytics = true
