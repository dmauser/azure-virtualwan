metadata description = 'Creates a Route Map on a Virtual Hub for BGP route manipulation'

@description('Virtual Hub name (must exist)')
param hubName string

@description('Route map name')
param routeMapName string

@description('Array of route map rules')
param rules array
// Each rule: { name: string, matchCriteria: array, actions: array, nextStepIfMatched: string }
// matchCriteria: { matchCondition: 'Contains'|'Equals'|'NotContains'|'NotEquals'|'Unknown', routePrefix: string[], community: string[], asPath: string[] }
// actions: { type: 'Add'|'Drop'|'Remove'|'Replace'|'Unknown', parameters: [{ routePrefix: string[], community: string[], asPath: string[] }] }

@description('Resource IDs of inbound connections this route map applies to')
param associatedInboundConnections array = []

@description('Resource IDs of outbound connections this route map applies to')
param associatedOutboundConnections array = []

// === Route Map ===
resource routeMap 'Microsoft.Network/virtualHubs/routeMaps@2024-05-01' = {
  name: '${hubName}/${routeMapName}'
  properties: {
    rules: [for rule in rules: {
      name: rule.name
      matchCriteria: rule.matchCriteria
      actions: rule.actions
      nextStepIfMatched: rule.nextStepIfMatched
    }]
    associatedInboundConnections: associatedInboundConnections
    associatedOutboundConnections: associatedOutboundConnections
  }
}

// === Outputs ===
output routeMapId string = routeMap.id
output provisioningState string = routeMap.properties.provisioningState
