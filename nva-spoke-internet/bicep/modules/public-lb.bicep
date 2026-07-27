// =============================================================================
// Module: public-lb.bicep
// Standard Public Load Balancer for DMZ NVAs
//
// Frontend: single Standard static public IP (pip-lb-public)
// Backend:  NVA NICs (joined from nva.bicep)
// Rules:
//   - LB rule: TCP 22 inbound → backend 22 (SSH mgmt), disableOutboundSnat=true
//   - Outbound rule: All protocols → SNAT via public IP (egress for NVAs)
// Health probe: TCP 22
// =============================================================================

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

var lbName     = 'lb-public'
var pipName    = 'pip-lb-public'
var frontendName = 'frontend'
var backendName  = 'nva-backend'
var probeName    = 'health-probe-ssh'

// ── Public IP ─────────────────────────────────────────────────────────────────
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ── Standard Public Load Balancer ─────────────────────────────────────────────
resource lb 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: lbName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: frontendName
        properties: { publicIPAddress: { id: pip.id } }
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
        // Inbound SSH for mgmt; disableOutboundSnat avoids conflict with outbound rule
        name: 'ssh-mgmt'
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
          protocol: 'Tcp'
          frontendPort: 22
          backendPort: 22
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          disableOutboundSnat: true
        }
      }
    ]
    outboundRules: [
      {
        // SNAT all NVA outbound traffic through the public IP
        name: 'snat-outbound'
        properties: {
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, frontendName)
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, backendName)
          }
          protocol: 'All'
          allocatedOutboundPorts: 0   // 0 = auto-allocate based on pool size
          enableTcpReset: true
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Public LB resource ID')
output lbId string = lb.id

@description('Backend pool resource ID (used by NVA NICs)')
output backendPoolId string = lb.properties.backendAddressPools[0].id

@description('Public IP address of the LB frontend (egress/mgmt IP)')
output publicIpAddress string = pip.properties.ipAddress

@description('Public IP resource ID')
output publicIpId string = pip.id
