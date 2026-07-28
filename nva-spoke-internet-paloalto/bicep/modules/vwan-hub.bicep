// =============================================================================
// Module: vwan-hub.bicep
// Virtual WAN + Virtual Hub
// Conditional S2S VPN Gateway (only when deployOnPrem = true)
// Naming: vwan-nva-si / hub-nva-si / vpngw-nva-si
// =============================================================================

@description('Azure region')
param location string

@description('Deploy S2S VPN Gateway inside the hub (required for on-prem option)')
param deployOnPrem bool = false

@description('Resource tags')
param tags object = {}

var vwanName = 'vwan-nva-si'
var hubName  = 'hub-nva-si'
var vpnGwName = 'vpngw-nva-si'

// ── Virtual WAN ───────────────────────────────────────────────────────────────
resource vwan 'Microsoft.Network/virtualWans@2024-05-01' = {
  name: vwanName
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
    disableVpnEncryption: false
  }
}

// ── Virtual Hub ───────────────────────────────────────────────────────────────
resource hub 'Microsoft.Network/virtualHubs@2024-05-01' = {
  name: hubName
  location: location
  tags: tags
  properties: {
    virtualWan: { id: vwan.id }
    addressPrefix: '10.100.0.0/23'
    sku: 'Standard'
  }
}

// ── S2S VPN Gateway (conditional) ────────────────────────────────────────────
// Only deployed when the on-prem simulation is requested.
resource vpnGw 'Microsoft.Network/vpnGateways@2024-05-01' = if (deployOnPrem) {
  name: vpnGwName
  location: location
  tags: tags
  properties: {
    virtualHub: { id: hub.id }
    vpnGatewayScaleUnit: 1
    bgpSettings: {
      asn: 65515   // Hub default BGP ASN
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Virtual WAN name')
output vwanName string = vwan.name

@description('Virtual Hub name')
output hubName string = hub.name

@description('Virtual Hub resource ID')
output hubId string = hub.id

@description('VPN Gateway name; empty string when not deployed')
output vpnGatewayName string = deployOnPrem ? vpnGwName : ''

@description('VPN Gateway resource ID; empty string when not deployed')
output vpnGatewayId string = deployOnPrem ? vpnGw.id : ''
