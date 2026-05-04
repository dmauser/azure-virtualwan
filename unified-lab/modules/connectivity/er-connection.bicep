metadata description = 'Creates an ExpressRoute connection from a hub ER gateway to an existing ExpressRoute circuit'

@description('Connection name')
param name string

#disable-next-line no-unused-params
@description('Virtual Hub name (must already exist)')
param hubName string

@description('ExpressRoute gateway name within the hub')
param expressRouteGatewayName string

@description('Resource ID of the ExpressRoute circuit peering (e.g., .../peerings/AzurePrivatePeering)')
param expressRouteCircuitPeeringId string

@description('Routing weight for the connection')
param routingWeight int = 0

@description('Enable internet security (route internet through hub)')
param enableInternetSecurity bool = false

@description('Routing configuration for associated/propagated route tables (optional)')
param routingConfiguration object = {}

@secure()
@description('Authorization key for cross-subscription or cross-tenant circuit connections (optional)')
param authorizationKey string = ''

#disable-next-line no-unused-params
@description('Tags for the connection resource')
param tags object = {}

// === ExpressRoute Connection ===
resource erConnection 'Microsoft.Network/expressRouteGateways/expressRouteConnections@2024-05-01' = {
  name: '${expressRouteGatewayName}/${name}'
  properties: {
    expressRouteCircuitPeering: {
      id: expressRouteCircuitPeeringId
    }
    routingWeight: routingWeight
    enableInternetSecurity: enableInternetSecurity
    routingConfiguration: !empty(routingConfiguration) ? routingConfiguration : null
    authorizationKey: !empty(authorizationKey) ? authorizationKey : null
  }
}

// === Outputs ===
output connectionId string = erConnection.id
output provisioningState string = erConnection.properties.provisioningState
