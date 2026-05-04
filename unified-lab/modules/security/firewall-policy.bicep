metadata description = 'Deploys an Azure Firewall Policy with lab-appropriate rule collections'

@description('Firewall Policy name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Firewall Policy SKU')
@allowed(['Standard', 'Premium', 'Basic'])
param sku string = 'Standard'

@description('Enable DNS proxy')
param enableDnsProxy bool = true

@description('Custom DNS servers (empty = Azure default)')
param dnsServers array = []

@description('Enable threat intelligence')
param enableThreatIntel bool = true

@description('Threat intelligence mode')
@allowed(['Alert', 'Deny', 'Off'])
param threatIntelMode string = 'Alert'

@description('Deploy default lab allow rules (permits all RFC1918 and internet for testing)')
param deployLabRules bool = true

@description('Tags')
param tags object = {}

// === Firewall Policy ===
resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: { tier: sku }
    dnsSettings: {
      enableProxy: enableDnsProxy
      servers: !empty(dnsServers) ? dnsServers : null
    }
    threatIntelMode: enableThreatIntel ? threatIntelMode : 'Off'
  }
}

// === Lab Rule Collection Group (permissive for testing) ===
resource labRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = if (deployLabRules) {
  name: 'DefaultLabRules'
  parent: policy
  properties: {
    priority: 100
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowRFC1918'
        priority: 100
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Private-to-Private'
            sourceAddresses: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
            destinationAddresses: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
            ipProtocols: ['Any']
            destinationPorts: ['*']
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'AllowInternet'
        priority: 200
        action: { type: 'Allow' }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'Allow-Outbound-Internet'
            sourceAddresses: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
            destinationAddresses: ['*']
            ipProtocols: ['TCP', 'UDP']
            destinationPorts: ['80', '443', '53']
          }
          {
            ruleType: 'NetworkRule'
            name: 'Allow-ICMP'
            sourceAddresses: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']
            destinationAddresses: ['*']
            ipProtocols: ['ICMP']
            destinationPorts: ['*']
          }
        ]
      }
    ]
  }
}

// === Outputs ===
output policyId string = policy.id
output policyName string = policy.name
