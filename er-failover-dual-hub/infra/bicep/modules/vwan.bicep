// =============================================================================
// Module: vwan.bicep
// Purpose: Deploy the Virtual WAN (Standard) that parents both hubs.
// Notes:   Standard SKU is mandatory — ExpressRoute gateways and hub-to-hub
//          transit (the failover path in this lab) are Standard-only features.
// =============================================================================

@description('Name of the Virtual WAN.')
param vwanName string

@description('Azure region for the Virtual WAN resource.')
param location string

@description('Resource tags.')
param tags object

resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    // Branch-to-branch must stay enabled: it is what allows on-premises prefixes
    // learned on one hub's ExpressRoute to be re-advertised to the other hub.
    allowBranchToBranchTraffic: true
    allowVnetToVnetTraffic: true
    disableVpnEncryption: false
  }
}

@description('Resource ID of the Virtual WAN.')
output vwanId string = vwan.id

@description('Name of the Virtual WAN.')
output vwanName string = vwan.name
