metadata description = '''
Azure Virtual WAN Unified Lab Builder
======================================
A decision-tree based deployment for Azure Virtual WAN lab scenarios.
Select your scenario through parameters — from a single hub with VPN
to multi-hub with NVA BGP peering and custom routing.

Usage:
  az deployment group create -g <rg> -f main.bicep -p presets/single-hub-vpn.bicepparam
  az deployment group create -g <rg> -f main.bicep -p presets/any-to-any.bicepparam
'''

targetScope = 'resourceGroup'

import { nvaConfigType } from 'types/scenario-types.bicep'

// ╔══════════════════════════════════════════════════════════════╗
// ║  DECISION TREE PARAMETERS                                    ║
// ╚══════════════════════════════════════════════════════════════╝

// --- Identity ---
@description('Base name prefix for all resources')
param labName string = 'vwan-lab'

@description('Primary Azure region')
param primaryLocation string = resourceGroup().location

@description('Secondary region (for multi-hub scenarios)')
param secondaryLocation string = 'westus2'

@description('Tags applied to all resources')
param tags object = {
  environment: 'lab'
  deployedBy: 'unified-lab-builder'
}

// --- Hub Configuration ---
@description('Virtual WAN type')
@allowed(['Basic', 'Standard'])
param vwanType string = 'Standard'

@description('Hub configurations array — add entries for multi-hub')
param hubs array = [
  {
    name: '${labName}-hub1'
    location: primaryLocation
    addressPrefix: '10.0.0.0/23'
    deployVpnGateway: false
    deployErGateway: false
    deployFirewall: false
    firewallSku: 'Standard'
    enableRoutingIntent: false
    routingIntentMode: 'PrivateOnly'
  }
]

// --- Spoke Configuration ---
@description('Spoke VNet configurations')
param spokes array = [
  {
    name: '${labName}-spoke1'
    location: primaryLocation
    addressPrefix: '10.1.0.0/16'
    subnetPrefix: '10.1.1.0/24'
    associatedHub: '${labName}-hub1'
    deployVm: true
  }
  {
    name: '${labName}-spoke2'
    location: primaryLocation
    addressPrefix: '10.2.0.0/16'
    subnetPrefix: '10.2.1.0/24'
    associatedHub: '${labName}-hub1'
    deployVm: true
  }
]

// --- Branch Configuration ---
@description('Deploy simulated branch sites')
param deployBranches bool = false

@description('Branch configurations')
param branches array = []

// --- Security Options ---
@description('Deploy Azure Firewall (set per-hub in hubs array)')
param defaultFirewallSku string = 'Standard'

// --- VM Configuration (lab defaults) ---
@description('Admin username for all VMs')
param adminUsername string = 'azureuser'

@description('Admin password for all VMs')
@secure()
param adminPassword string

@description('VM size for test VMs (lab-grade)')
param vmSize string = 'Standard_B2s'

// --- NVA Configuration ---
@description('NVA configurations for BGP peering scenarios')
param nvaConfigs nvaConfigType[] = []

// --- Add-ons ---
@description('Deploy Log Analytics workspace for diagnostics')
param deployLogAnalytics bool = false

// ╔══════════════════════════════════════════════════════════════╗
// ║  CORE DEPLOYMENT                                             ║
// ╚══════════════════════════════════════════════════════════════╝

// --- Virtual WAN + Hubs ---
module vwanDeployment 'modules/core/vwan-hub.bicep' = {
  name: 'deploy-vwan-hubs'
  params: {
    vwanName: '${labName}-vwan'
    location: primaryLocation
    vwanType: vwanType
    hubs: hubs
    tags: tags
  }
}

// --- Spoke VNets ---
module spokeDeployments 'modules/core/spoke-vnet.bicep' = [for (spoke, i) in spokes: {
  name: 'deploy-spoke-${spoke.name}'
  params: {
    name: spoke.name
    location: spoke.location
    addressPrefix: spoke.addressPrefix
    subnetPrefix: spoke.subnetPrefix
    deployVm: spoke.?deployVm ?? false
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}]

// --- Hub-to-Spoke VNet Connections ---
module spokeConnections 'modules/connectivity/vnet-connection.bicep' = [for (spoke, i) in spokes: {
  name: 'connect-spoke-${spoke.name}'
  params: {
    hubName: spoke.associatedHub
    spokeVnetId: spokeDeployments[i].outputs.vnetId
    spokeName: spoke.name
    routeTableLabel: spoke.?routeTableLabel ?? ''
  }
  dependsOn: [vwanDeployment]
}]

// ╔══════════════════════════════════════════════════════════════╗
// ║  BRANCH CONNECTIVITY (conditional)                           ║
// ╚══════════════════════════════════════════════════════════════╝

module branchDeployments 'modules/core/branch-sim.bicep' = [for (branch, i) in branches: if (deployBranches) {
  name: 'deploy-branch-${branch.name}'
  params: {
    name: branch.name
    location: branch.location
    addressPrefix: branch.addressPrefix
    gatewaySubnetPrefix: branch.gatewaySubnetPrefix
    bgpAsn: branch.?bgpAsn ?? (65010 + i)
    tags: tags
  }
}]

// VPN Site + Connection for each branch
module vpnSiteConnections 'modules/connectivity/vpn-site.bicep' = [for (branch, i) in branches: if (deployBranches) {
  name: 'connect-branch-${branch.name}'
  params: {
    siteName: '${branch.name}-site'
    location: branch.location
    vwanId: vwanDeployment.outputs.vwanId
    vpnGatewayId: vwanDeployment.outputs.vpnGatewayIds[indexOf(hubs, filter(hubs, h => h.name == branch.connectedHub)[0])]
    branchPublicIp: branchDeployments[i].outputs.gatewayPublicIp
    branchBgpAddress: branchDeployments[i].outputs.bgpPeeringAddress
    branchBgpAsn: branchDeployments[i].outputs.bgpAsn
    psk: branch.?psk ?? 'VwanLabPsk2024!'
    tags: tags
  }
  dependsOn: [branchDeployments[i]]
}]

// ╔══════════════════════════════════════════════════════════════╗
// ║  NVA DEPLOYMENT (conditional - Phase 3)                      ║
// ╚══════════════════════════════════════════════════════════════╝

// --- NVA Spoke VNets (dedicated VNet per NVA) ---
module nvaSpokeDeployments 'modules/core/spoke-vnet.bicep' = [for (nva, i) in nvaConfigs: {
  name: 'deploy-nva-spoke-${i}'
  params: {
    name: '${labName}-nva-${i}'
    location: primaryLocation
    addressPrefix: nva.addressPrefix!
    subnetPrefix: nva.addressPrefix!
    deployVm: false
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    tags: tags
  }
}]

// --- NVA Spoke-to-Hub Connections ---
module nvaConnections 'modules/connectivity/vnet-connection.bicep' = [for (nva, i) in nvaConfigs: {
  name: 'connect-nva-spoke-${i}'
  params: {
    hubName: hubs[0].name
    spokeVnetId: nvaSpokeDeployments[i].outputs.vnetId
    spokeName: '${labName}-nva-${i}'
  }
  dependsOn: [vwanDeployment]
}]

// --- Linux NVA Instances ---
module nvaDeployments 'modules/security/linux-nva.bicep' = [for (nva, i) in nvaConfigs: if (nva.nvaType == 'linux-frr') {
  name: 'deploy-nva-${i}'
  params: {
    name: '${labName}-nva-${i}'
    location: primaryLocation
    subnetId: nvaSpokeDeployments[i].outputs.subnetId
    privateIpAddress: nva.privateIp!
    vmSize: vmSize
    adminUsername: adminUsername
    adminPassword: adminPassword
    bgpAsn: nva.bgpAsn ?? 65001
    bgpNeighbors: []
    enableIpForwarding: true
    tags: tags
  }
  dependsOn: [nvaSpokeDeployments[i]]
}]

// --- NVA Internal Load Balancers (HA scenarios) ---
module nvaIlbDeployments 'modules/shared/nva-ilb.bicep' = [for (nva, i) in nvaConfigs: if (nva.deployIlb == true) {
  name: 'deploy-nva-ilb-${i}'
  params: {
    name: '${labName}-nva-ilb-${i}'
    location: primaryLocation
    subnetId: nvaSpokeDeployments[i].outputs.subnetId
    privateIpAddress: nva.privateIp!
    healthProbePort: 22
    tags: tags
  }
  dependsOn: [nvaDeployments[i]]
}]

// --- Hub BGP Peering for NVAs ---
module nvaBgpPeers 'modules/connectivity/hub-bgp-peer.bicep' = [for (nva, i) in nvaConfigs: if (nva.enableHubBgpPeering == true) {
  name: 'deploy-nva-bgp-peer-${i}'
  params: {
    hubName: hubs[0].name
    connectionName: '${labName}-nva-${i}-bgp'
    peerIp: nva.privateIp!
    peerAsn: nva.bgpAsn ?? 65001
    hubVirtualNetworkConnectionId: nvaConnections[i].outputs.connectionId
  }
  dependsOn: [nvaDeployments[i], nvaConnections[i]]
}]

// ╔══════════════════════════════════════════════════════════════╗
// ║  ADD-ONS (conditional)                                       ║
// ╚══════════════════════════════════════════════════════════════╝

// --- Log Analytics ---
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (deployLogAnalytics) {
  name: '${labName}-law'
  location: primaryLocation
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ╔══════════════════════════════════════════════════════════════╗
// ║  OUTPUTS                                                     ║
// ╚══════════════════════════════════════════════════════════════╝

@description('Virtual WAN resource ID')
output vwanId string = vwanDeployment.outputs.vwanId

@description('Hub resource IDs')
output hubIds array = vwanDeployment.outputs.hubIds

@description('Spoke VNet IDs')
output spokeVnetIds array = [for (spoke, i) in spokes: spokeDeployments[i].outputs.vnetId]

@description('NVA private IP addresses')
output nvaPrivateIps array = [for (nva, i) in nvaConfigs: nva.privateIp ?? '']

@description('Lab summary')
output summary object = {
  labName: labName
  hubCount: length(hubs)
  spokeCount: length(spokes)
  branchCount: deployBranches ? length(branches) : 0
  nvaCount: length(nvaConfigs)
  firewallDeployed: !empty(filter(hubs, h => h.deployFirewall == true))
  routingIntentEnabled: !empty(filter(hubs, h => h.enableRoutingIntent == true))
}
