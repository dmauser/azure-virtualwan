// =============================================================================
// Module: firewall-policy.bicep
// Purpose: Deploy a Basic Azure Firewall Policy per hub, including a LAB-ONLY
//          allow-all network rule to simplify connectivity testing.
//
//  ⚠️  SECURITY WARNING — LAB USE ONLY
//  The rule collection group 'default-allow-all-rcg' contains an Allow rule
//  that permits ANY source, ANY destination, ANY protocol, ANY port.
//  This exists so spoke-to-spoke, inter-hub, branch-to-spoke, branch-to-branch
//  and outbound Internet traffic flows without per-test rule edits.
//  NEVER use this policy in production.
// =============================================================================

@description('Name of the firewall policy.')
param policyName string

@description('Azure region for the policy.')
param location string

@description('Resource tags.')
param tags object

@description('Firewall tier for the policy. Basic is the lowest-cost option.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param tier string = 'Basic'

resource policy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: policyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: tier
    }
  }
}

// Lab-only allow-all rule collection group. Names are explicit & stable so the
// validation scripts can assert their existence.
resource allowAllRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: policy
  name: 'default-allow-all-rcg'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'allow-all-network'
        priority: 100
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-all'
            ipProtocols: [
              'Any'
            ]
            sourceAddresses: [
              '*'
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

@description('Resource ID of the firewall policy.')
output policyId string = policy.id

@description('Name of the firewall policy.')
output policyName string = policy.name
