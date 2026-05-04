metadata description = 'Configures Routing Intent on a Virtual Hub (requires Azure Firewall already deployed)'

@description('Virtual Hub name')
param hubName string

@description('Azure Firewall resource ID (must be in the same hub)')
param azureFirewallId string

@description('Route internet traffic (0.0.0.0/0) through firewall')
param internetToFirewall bool = true

@description('Route private traffic (RFC1918) through firewall')
param privateToFirewall bool = true

// === Routing Intent ===
resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2024-05-01' = {
  name: '${hubName}/${hubName}-routing-intent'
  properties: {
    routingPolicies: concat(
      internetToFirewall ? [
        {
          name: 'InternetTrafficPolicy'
          destinations: ['Internet']
          nextHop: azureFirewallId
        }
      ] : [],
      privateToFirewall ? [
        {
          name: 'PrivateTrafficPolicy'
          destinations: ['PrivateTraffic']
          nextHop: azureFirewallId
        }
      ] : []
    )
  }
}

// === Outputs ===
output routingIntentId string = routingIntent.id
output internetRouted bool = internetToFirewall
output privateRouted bool = privateToFirewall
