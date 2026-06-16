// =============================================================================
// Module: vwan.bicep
// Purpose: Deploy a single Standard Azure Virtual WAN.
// Notes:   Standard SKU is required for secured hubs, hub-to-hub connectivity,
//          ExpressRoute, and Routing Intent. Do not downgrade to Basic.
// =============================================================================

@description('Name of the Virtual WAN resource.')
param vwanName string

@description('Azure region for the Virtual WAN metadata resource.')
param location string

@description('Resource tags applied to the Virtual WAN.')
param tags object

@description('Allow branch-to-branch traffic across the WAN (required for branch-to-branch lab tests).')
param allowBranchToBranchTraffic bool = true

resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: allowBranchToBranchTraffic
    allowVnetToVnetTraffic: true
  }
}

@description('Resource ID of the Virtual WAN.')
output vwanId string = vwan.id

@description('Name of the Virtual WAN.')
output vwanName string = vwan.name
