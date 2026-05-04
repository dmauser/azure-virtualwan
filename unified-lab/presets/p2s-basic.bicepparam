using '../main.bicep'

// Point-to-Site VPN configuration
// Note: P2S server configuration is applied post-deploy via CLI with address pool and root certificate

param projectName = 'vwan-p2s-basic'
param primaryLocation = 'eastus'
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

param deployBranches = false
param branches = []

param nvaConfigs = []

param adminUsername = 'azureuser'
param deployLogAnalytics = true
