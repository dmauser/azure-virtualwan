metadata description = 'Creates a VNet connection from a spoke to a Virtual Hub'

@description('Virtual Hub name (must already exist)')
param hubName string

@description('Spoke VNet resource ID')
param spokeVnetId string

@description('Connection name suffix')
param spokeName string

@description('Route table label for isolation (empty = default)')
param routeTableLabel string = ''

@description('Enable internet security (route internet through hub)')
param enableInternetSecurity bool = true

// Connection to the existing hub
resource connection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-05-01' = {
  name: '${hubName}/${spokeName}-connection'
  properties: {
    remoteVirtualNetwork: { id: spokeVnetId }
    enableInternetSecurity: enableInternetSecurity
    routingConfiguration: !empty(routeTableLabel) ? {
      associatedRouteTable: {
        id: resourceId('Microsoft.Network/virtualHubs/hubRouteTables', hubName, routeTableLabel)
      }
    } : null
  }
}

output connectionId string = connection.id
