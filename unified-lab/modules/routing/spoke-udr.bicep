metadata description = 'Creates a spoke UDR (User Defined Route table) with custom next-hop'

@description('Route table name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Routes to add')
param routes array = []
// Each route: { name: string, addressPrefix: string, nextHopType: string, nextHopIpAddress: string? }

@description('Disable BGP route propagation (required when using NVA as next-hop)')
param disableBgpRoutePropagation bool = true

@description('Tags')
param tags object = {}

// === Route Table ===
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: disableBgpRoutePropagation
    routes: [for route in routes: {
      name: route.name
      properties: {
        addressPrefix: route.addressPrefix
        nextHopType: route.nextHopType
        nextHopIpAddress: route.?nextHopIpAddress ?? null
      }
    }]
  }
}

// === Outputs ===
output routeTableId string = routeTable.id
output routeTableName string = routeTable.name
