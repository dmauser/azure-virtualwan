// =============================================================================
// Module: secured-vhub-firewall.bicep
// Purpose: Deploy Azure Firewall Basic into a Virtual Hub (secured hub) and
//          associate the per-hub firewall policy.
// Notes:   - SKU name AZFW_Hub + tier Basic is the lowest-cost secured-hub
//            firewall. Basic auto-manages its public IP allocation
//            (hubIPAddresses.publicIPs.count) — no manually created PIPs.
//          - Firewall provisioning is slow (~30-45 min). main.bicep waits.
// =============================================================================

@description('Name of the Azure Firewall.')
param firewallName string

@description('Azure region (must match the hub region).')
param location string

@description('Resource ID of the parent Virtual Hub.')
param hubId string

@description('Resource ID of the firewall policy to attach.')
param firewallPolicyId string

@description('Resource tags.')
param tags object

@description('Firewall tier. Basic is the lowest-cost option for the lab.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param tier string = 'Basic'

@description('Number of public IPs the hub firewall manages. Basic requires at least 1.')
@minValue(1)
param publicIpCount int = 1

resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: firewallName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_Hub'
      tier: tier
    }
    virtualHub: {
      id: hubId
    }
    firewallPolicy: {
      id: firewallPolicyId
    }
    hubIPAddresses: {
      publicIPs: {
        count: publicIpCount
      }
    }
  }
}

@description('Resource ID of the Azure Firewall.')
output firewallId string = firewall.id

@description('Name of the Azure Firewall.')
output firewallName string = firewall.name
