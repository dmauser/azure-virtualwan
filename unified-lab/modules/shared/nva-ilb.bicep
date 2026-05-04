metadata description = 'Deploys a Standard SKU Internal Load Balancer for NVA high-availability (HA ports rule)'

@description('Load balancer name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Subnet resource ID for the frontend IP configuration')
param subnetId string

@description('Static private IP address for the frontend')
param privateIpAddress string

@description('Health probe port (default: SSH 22)')
param healthProbePort int = 22

@description('Tags')
param tags object = {}

// === Internal Load Balancer ===
resource lb 'Microsoft.Network/loadBalancers@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          subnet: { id: subnetId }
          privateIPAddress: privateIpAddress
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'nva-backend'
      }
    ]
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Tcp'
          port: healthProbePort
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'ha-ports-rule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', name, 'frontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', name, 'nva-backend')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', name, 'health-probe')
          }
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          enableFloatingIP: true
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// === Outputs ===
output lbId string = lb.id
output backendPoolId string = lb.properties.backendAddressPools[0].id
output frontendIpAddress string = privateIpAddress
