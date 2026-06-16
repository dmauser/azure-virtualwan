// =============================================================================
// Module: expressroute-gateway.bicep
// Purpose: Deploy an ExpressRoute Gateway into a Virtual Hub.
// Notes:   - minScaleUnits is kept at 1 (lowest) for lab cost. Each scale unit
//            adds cost and throughput; 1 is plenty for connectivity testing.
//          - Gateways are created on demand by the deploy scripts (only on hubs
//            that a circuit maps to), or via main.bicep when a hub explicitly
//            sets deployErGateway=true.
// =============================================================================

@description('Name of the ExpressRoute Gateway.')
param gatewayName string

@description('Azure region (must match the hub region).')
param location string

@description('Resource ID of the parent Virtual Hub.')
param hubId string

@description('Resource tags.')
param tags object

@description('Gateway scale units. Keep at 1 for lab cost.')
@minValue(1)
@maxValue(10)
param scaleUnits int = 1

resource erGateway 'Microsoft.Network/expressRouteGateways@2023-11-01' = {
  name: gatewayName
  location: location
  tags: tags
  properties: {
    virtualHub: {
      id: hubId
    }
    autoScaleConfiguration: {
      bounds: {
        min: scaleUnits
      }
    }
  }
}

@description('Resource ID of the ExpressRoute Gateway.')
output gatewayId string = erGateway.id

@description('Name of the ExpressRoute Gateway.')
output gatewayName string = erGateway.name
