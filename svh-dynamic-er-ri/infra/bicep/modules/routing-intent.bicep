// =============================================================================
// Module: routing-intent.bicep
// Purpose: Create Microsoft.Network/virtualHubs/routingIntent for one hub.
//
// NOTE — Pure-Bicep option vs. interactive scripts:
//   The interactive deploy scripts (svh-dynamic-er-ri-deploy.azcli) create
//   Routing Intent via `az network vhub routing-intent create` AFTER firewall
//   provisioning completes (~30-45 min), because ARM will reject routingIntent
//   if the firewall is not yet in Succeeded state. When deploying via Bicep
//   (main.bicep), ensure this module is called with a dependsOn that resolves
//   only after the firewall resource reaches Succeeded; use the `existing`
//   resource pattern or pass firewallId from the firewall module output.
// =============================================================================

@description('Name of the existing Virtual Hub.')
param hubName string

@description('Resource ID of the Azure Firewall deployed in this hub.')
param firewallId string

@description('''
Routing Intent mode.
  privateOnly  — steer RFC-1918 / private traffic through the firewall.
  internetOnly — steer Internet (0.0.0.0/0) traffic through the firewall.
  both         — steer both private and Internet traffic through the firewall.
''')
@allowed([
  'privateOnly'
  'internetOnly'
  'both'
])
param mode string

// ---------------------------------------------------------------------------
// Build the routingPolicies array from `mode`.
// Azure accepts exactly these destination strings:
//   'PrivateTraffic' — covers RFC-1918 prefixes learned from all attachments.
//   'Internet'       — covers the default Internet route (0.0.0.0/0).
// ---------------------------------------------------------------------------
var privatePolicy = {
  name: 'PrivateTraffic'
  destinations: [
    'PrivateTraffic'
  ]
  nextHop: firewallId
}

var internetPolicy = {
  name: 'InternetTraffic'
  destinations: [
    'Internet'
  ]
  nextHop: firewallId
}

var routingPolicies = mode == 'privateOnly'
  ? [privatePolicy]
  : mode == 'internetOnly'
      ? [internetPolicy]
      : [privatePolicy, internetPolicy]   // 'both'

// ---------------------------------------------------------------------------
// Resource — child of the existing hub (parent/child name convention).
// Name pattern mirrors the CLI convention: <hubName>-ri
// ---------------------------------------------------------------------------
resource routingIntent 'Microsoft.Network/virtualHubs/routingIntent@2023-11-01' = {
  name: '${hubName}/${hubName}-ri'
  properties: {
    routingPolicies: routingPolicies
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
@description('Resource ID of the Routing Intent resource.')
output routingIntentId string = routingIntent.id

@description('Name of the Routing Intent resource (child segment only).')
output routingIntentName string = '${hubName}-ri'
