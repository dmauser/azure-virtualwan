metadata description = 'Simulates an on-premises branch site with VNet and VPN Gateway'

@description('Branch name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Branch VNet address space')
param addressPrefix string

@description('GatewaySubnet prefix (must be /27 or larger)')
param gatewaySubnetPrefix string

@description('BGP ASN for branch gateway')
param bgpAsn int = 65010

@description('VPN Gateway SKU (lab-grade)')
@allowed(['VpnGw1', 'VpnGw2'])
param gatewaySku string = 'VpnGw1'

@description('Tags')
param tags object = {}

// === Branch VNet ===
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
      {
        name: 'default'
        properties: {
          addressPrefix: cidrSubnet(addressPrefix, 24, 1)
        }
      }
    ]
  }
}

// === Public IP for VPN GW ===
resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-vpngw-pip'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// === VPN Gateway (branch side) ===
resource vpnGw 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: '${name}-vpngw'
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    enableBgp: true
    bgpSettings: {
      asn: bgpAsn
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          publicIPAddress: { id: pip.id }
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
  }
}

// === Outputs ===
output vnetId string = vnet.id
output gatewayId string = vpnGw.id
output gatewayPublicIp string = pip.properties.ipAddress
output bgpPeeringAddress string = vpnGw.properties.bgpSettings.bgpPeeringAddress
output bgpAsn int = bgpAsn
