// =============================================================================
// Module: vhub.bicep
// Purpose: Deploy one Virtual Hub.
// Notes:   hubRoutingPreference defaults to 'ASPath' for this lab. With ASPath
//          the hub router picks the route with the shortest BGP AS path FIRST,
//          before it looks at the route source (ExpressRoute / VPN / VNet).
//          That is what makes the ExpressRoute failover in this lab observable:
//          the local circuit wins on AS path length, and when it drops the
//          remote hub's circuit (longer AS path via hub-to-hub) takes over.
// =============================================================================

@description('Name of the Virtual Hub.')
param hubName string

@description('Azure region for the hub.')
param location string

@description('Hub address prefix. /23 recommended; /24 is the minimum.')
param hubAddressPrefix string

@description('Resource ID of the parent Virtual WAN.')
param vwanId string

@description('''
Hub route preference. This lab uses ASPath.
  ASPath       — shortest BGP AS path wins, regardless of route source.
  ExpressRoute — ER-learned routes win over VPN/NVA regardless of AS path.
  VpnGateway   — VPN-learned routes win over ER/NVA regardless of AS path.
''')
@allowed([
  'ASPath'
  'ExpressRoute'
  'VpnGateway'
])
param hubRoutingPreference string = 'ASPath'

@description('Resource tags.')
param tags object

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

@description('Effective hub routing preference (expected: ASPath).')
output hubRoutingPreference string = vhub.properties.hubRoutingPreference

@description('Resource ID of the hub default route table.')
output defaultRouteTableId string = '${vhub.id}/hubRouteTables/defaultRouteTable'
