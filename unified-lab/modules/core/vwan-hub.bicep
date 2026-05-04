metadata description = 'Deploys Virtual WAN and Virtual Hubs using AVM pattern module'

// === Parameters ===
@description('Name for the Virtual WAN resource')
param vwanName string

@description('Location for the vWAN resource')
param location string = resourceGroup().location

@description('Virtual WAN type')
@allowed(['Basic', 'Standard'])
param vwanType string = 'Standard'

@description('Hub configurations')
param hubs array

@description('Tags applied to all resources')
param tags object = {}

// === Variables ===
var virtualHubParameters = [for hub in hubs: {
  name: hub.name
  location: hub.location
  addressPrefix: hub.addressPrefix
  // S2S VPN Gateway
  s2sVpnGatewayEnabled: hub.?deployVpnGateway ?? false
  // ExpressRoute Gateway
  expressRouteGatewayEnabled: hub.?deployErGateway ?? false
  // Secured Hub (Azure Firewall)
  azureFirewallEnabled: hub.?deployFirewall ?? false
  firewallSku: hub.?firewallSku ?? 'Standard'
  // Routing Intent
  routingIntentEnabled: hub.?enableRoutingIntent ?? false
  routingIntentMode: hub.?routingIntentMode ?? 'PrivateOnly'
}]

// === Resources ===
// Deploy vWAN resource
resource vwan 'Microsoft.Network/virtualWans@2024-05-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: vwanType
    allowBranchToBranchTraffic: true
    disableVpnEncryption: false
  }
}

// Deploy Virtual Hubs
resource virtualHubs 'Microsoft.Network/virtualHubs@2024-05-01' = [for (hub, i) in virtualHubParameters: {
  name: hub.name
  location: hub.location
  tags: tags
  properties: {
    virtualWan: { id: vwan.id }
    addressPrefix: hub.addressPrefix
    sku: 'Standard'
  }
}]

// Deploy VPN Gateways (where enabled)
resource vpnGateways 'Microsoft.Network/vpnGateways@2024-05-01' = [for (hub, i) in virtualHubParameters: if (hub.s2sVpnGatewayEnabled) {
  name: '${hub.name}-vpngw'
  location: hub.location
  tags: tags
  properties: {
    virtualHub: { id: virtualHubs[i].id }
    vpnGatewayScaleUnit: 1
    bgpSettings: {
      asn: 65515
    }
  }
}]

// Deploy ExpressRoute Gateways (where enabled)
resource erGateways 'Microsoft.Network/expressRouteGateways@2024-05-01' = [for (hub, i) in virtualHubParameters: if (hub.expressRouteGatewayEnabled) {
  name: '${hub.name}-ergw'
  location: hub.location
  tags: tags
  properties: {
    virtualHub: { id: virtualHubs[i].id }
    autoScaleConfiguration: {
      bounds: {
        min: 1
        max: 2
      }
    }
  }
}]

// Deploy Azure Firewalls (Secured vHub, where enabled)
resource firewalls 'Microsoft.Network/azureFirewalls@2024-05-01' = [for (hub, i) in virtualHubParameters: if (hub.azureFirewallEnabled) {
  name: '${hub.name}-azfw'
  location: hub.location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: hub.firewallSku
    }
    virtualHub: { id: virtualHubs[i].id }
    hubIPAddresses: {
      publicIPs: {
        count: 1
      }
    }
  }
}]

// Deploy Routing Intent (where Firewall + RoutingIntent both enabled)
resource routingIntents 'Microsoft.Network/virtualHubs/routingIntent@2024-05-01' = [for (hub, i) in virtualHubParameters: if (hub.azureFirewallEnabled && hub.routingIntentEnabled) {
  name: '${hub.name}-routing-intent'
  parent: virtualHubs[i]
  properties: {
    routingPolicies: concat(
      (hub.routingIntentMode == 'InternetOnly' || hub.routingIntentMode == 'InternetAndPrivate') ? [{
        name: 'PublicTraffic'
        destinations: ['Internet']
        nextHop: firewalls[i].id
      }] : [],
      (hub.routingIntentMode == 'PrivateOnly' || hub.routingIntentMode == 'InternetAndPrivate') ? [{
        name: 'PrivateTraffic'
        destinations: ['PrivateTraffic']
        nextHop: firewalls[i].id
      }] : []
    )
  }
  dependsOn: [firewalls[i]]
}]

// === Outputs ===
@description('Virtual WAN resource ID')
output vwanId string = vwan.id

@description('Virtual Hub resource IDs')
output hubIds array = [for (hub, i) in virtualHubParameters: virtualHubs[i].id]

@description('Virtual Hub names')
output hubNames array = [for (hub, i) in virtualHubParameters: virtualHubs[i].name]

@description('VPN Gateway resource IDs (empty string if not deployed)')
output vpnGatewayIds array = [for (hub, i) in virtualHubParameters: hub.s2sVpnGatewayEnabled ? vpnGateways[i].id : '']
