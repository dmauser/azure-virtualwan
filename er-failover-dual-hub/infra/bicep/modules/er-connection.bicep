// =============================================================================
// Module: er-connection.bicep
// Purpose: Attach an ExpressRoute circuit's private peering to a vHub's
//          ExpressRoute Gateway.
// Notes:   - This is the resource that must NOT be attempted before the provider
//            has provisioned the circuit. main.bicep gates it behind er-wait.
//          - routingWeight is left at 0 by default. With hubRoutingPreference =
//            ASPath the hub decides on BGP AS path first, so routingWeight is
//            only a tie-breaker between two ER connections on the SAME hub. It is
//            exposed here so you can deliberately skew a tie during testing.
// =============================================================================

@description('Name of the ExpressRoute Gateway that hosts the connection.')
param gatewayName string

@description('Name of the ExpressRoute connection.')
param connectionName string

@description('Resource ID of the AzurePrivatePeering on the circuit.')
param peeringId string

@description('Resource ID of the hub default route table (association + propagation target).')
param defaultRouteTableId string

@description('Routing weight. Tie-breaker between ER connections on the same gateway.')
@minValue(0)
@maxValue(32000)
param routingWeight int = 0

@description('Enable Internet security (forces 0.0.0.0/0 through the hub). False — no firewall in this lab.')
param enableInternetSecurity bool = false

resource gateway 'Microsoft.Network/expressRouteGateways@2023-11-01' existing = {
  name: gatewayName
}

resource erConnection 'Microsoft.Network/expressRouteGateways/expressRouteConnections@2023-11-01' = {
  parent: gateway
  name: connectionName
  properties: {
    expressRouteCircuitPeering: {
      id: peeringId
    }
    routingWeight: routingWeight
    enableInternetSecurity: enableInternetSecurity
    routingConfiguration: {
      associatedRouteTable: {
        id: defaultRouteTableId
      }
      propagatedRouteTables: {
        labels: [
          'default'
        ]
        ids: [
          {
            id: defaultRouteTableId
          }
        ]
      }
    }
  }
}

@description('Resource ID of the ExpressRoute connection.')
output connectionId string = erConnection.id

@description('Name of the ExpressRoute connection.')
output connectionName string = erConnection.name
