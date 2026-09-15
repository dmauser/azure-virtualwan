// =============================================================================
// Module: expressroute-gateway.bicep
// Purpose: Deploy an ExpressRoute Gateway into a Virtual Hub.
// Notes:   - 1 scale unit (2 Gbps) is the minimum and is plenty for a lab.
//          - Provisioning takes roughly 20-30 minutes. It runs in parallel with
//            the out-of-band provider provisioning of the circuits, so it is on
//            the critical path only if the provider finishes first.
// =============================================================================

@description('Name of the ExpressRoute Gateway.')
param gatewayName string

@description('Azure region (must match the hub region).')
param location string

@description('Resource ID of the parent Virtual Hub.')
param hubId string

@description('Gateway scale units. 1 = 2 Gbps. Keep at 1 for lab cost.')
@minValue(1)
@maxValue(10)
param scaleUnits int = 1

@description('Resource tags.')
param tags object

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
