metadata description = 'Creates a BGP connection between an NVA and a Virtual Hub (AVM gap-fill)'

@description('Virtual Hub name')
param hubName string

@description('BGP connection name')
param connectionName string

@description('NVA peer IP address')
param peerIp string

@description('NVA BGP ASN')
param peerAsn int

@description('Hub VNet connection resource ID (the connection of the NVA VNet to the hub)')
param hubVirtualNetworkConnectionId string

// === BGP Connection ===
resource bgpConnection 'Microsoft.Network/virtualHubs/bgpConnections@2024-05-01' = {
  name: '${hubName}/${connectionName}'
  properties: {
    peerIp: peerIp
    peerAsn: peerAsn
    hubVirtualNetworkConnection: {
      id: hubVirtualNetworkConnectionId
    }
  }
}

// === Outputs ===
output bgpConnectionId string = bgpConnection.id
output connectionState string = bgpConnection.properties.connectionState
