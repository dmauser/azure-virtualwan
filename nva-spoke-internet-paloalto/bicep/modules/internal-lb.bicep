// =============================================================================
// Module: internal-lb.bicep
// Standard Internal Load Balancer with HA-ports rule
// Reuses the nva-ilb.bicep pattern from unified-lab/modules/shared/
//
// Frontend: STATIC private IP 10.0.0.68 in snet-trust (10.0.0.64/27)
// Backend:  PA trust NICs (joined from palo-alto.bicep)
// Rule:     HA ports (protocol=All, frontendPort=0, backendPort=0)
// This frontend IP is the 0/0 next-hop that deploy.sh programs on the hub.
// =============================================================================

@description('Azure region')
param location string

@description('snet-trust subnet resource ID (10.0.0.64/27 in vnet-dmz)')
param snetIlbId string

@description('Resource tags')
param tags object = {}

var lbName       = 'lb-ilb'
var frontendName = 'frontend'
var backendName  = 'nva-backend'
var probeName    = 'health-probe-ssh'

// ILB frontend IP — FIXED by design contract; deploy.sh uses this as the 0/0 next-hop
var ilbFrontendIp = '10.0.0.68'

// ── Standard Internal Load Balancer ──────────────────────────────────────────
resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: lbName
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    frontendIPConfigurations: [
      {
        name: frontendName
        properties: {
          subnet: { id: snetIlbId }
          privateIPAddress: ilbFrontendIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    backendAddressPools: [
      { name: backendName }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: 'Tcp'
          port: 22
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        // HA-ports rule: all protocols, all ports — routes hub 0/0 traffic to any healthy PA instance
        name: 'ha-ports-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendName)
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
          }
          protocol: 'All'
          frontendPort: 0     // HA ports: 0 = all ports
          backendPort: 0      // HA ports: 0 = all ports
          enableFloatingIP: true
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('ILB resource ID')
output lbId string = lb.id

@description('Backend pool resource ID (used by PA trust NICs)')
output backendPoolId string = lb.properties.backendAddressPools[0].id

@description('ILB frontend private IP address (= 10.0.0.68, the 0/0 next-hop for the hub)')
output frontendIpAddress string = ilbFrontendIp
