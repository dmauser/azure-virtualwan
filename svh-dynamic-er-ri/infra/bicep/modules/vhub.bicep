// =============================================================================
// Module: vhub.bicep
// Purpose: Deploy one Virtual Hub with Route Preference = ExpressRoute.
// Notes:   hubRoutingPreference is hard-set to 'ExpressRoute' for every hub in
//          this lab (lab-wide rule). Do NOT switch to ASPath/VpnGateway unless
//          the lab requirement changes. Validation scripts assert this value.
// =============================================================================

@description('Name of the Virtual Hub.')
param hubName string

@description('Azure region for the hub.')
param location string

@description('Hub address prefix (recommended /23).')
param hubAddressPrefix string

@description('Resource ID of the parent Virtual WAN.')
param vwanId string

@description('Resource tags applied to the hub.')
param tags object

// Route Preference is fixed for this lab. Centralized here so every hub is
// guaranteed identical. ExpressRoute preference makes ER-learned routes win.
var hubRoutingPreference = 'ExpressRoute'

resource vhub 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hubName
  location: location
  tags: tags
  properties: {
    sku: 'Standard'
    addressPrefix: hubAddressPrefix
    hubRoutingPreference: hubRoutingPreference
    virtualWan: {
      id: vwanId
    }
  }
}

@description('Resource ID of the hub.')
output hubId string = vhub.id

@description('Name of the hub.')
output hubName string = vhub.name

@description('Effective hub routing preference (expected: ExpressRoute).')
output hubRoutingPreference string = vhub.properties.hubRoutingPreference
