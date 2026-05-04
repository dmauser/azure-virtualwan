metadata description = 'Creates a custom route table in a Virtual Hub for VNet isolation scenarios'

@description('Virtual Hub name (must exist)')
param hubName string

@description('Route table name (e.g., RT_BLUE, RT_RED)')
param routeTableName string

@description('Labels for this route table (used in routing configuration)')
param labels array = []

@description('Static routes in this route table')
param routes array = []
// Each route: { name: string, destinationType: 'CIDR'|'Service', destinations: string[], nextHopType: 'ResourceId', nextHop: string }

// === Hub Route Table ===
resource routeTable 'Microsoft.Network/virtualHubs/hubRouteTables@2024-05-01' = {
  name: '${hubName}/${routeTableName}'
  properties: {
    labels: labels
    routes: [for route in routes: {
      name: route.name
      destinationType: route.?destinationType ?? 'CIDR'
      destinations: route.destinations
      nextHopType: 'ResourceId'
      nextHop: route.nextHop
    }]
  }
}

// === Outputs ===
output routeTableId string = routeTable.id
output routeTableName string = routeTableName
