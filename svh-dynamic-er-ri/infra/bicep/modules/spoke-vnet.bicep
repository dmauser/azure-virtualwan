// =============================================================================
// Module: spoke-vnet.bicep
// Purpose: Deploy one spoke VNet per hub with a VM subnet, an NSG, and an
//          optional connection to its local Virtual Hub.
// Notes:   - No Azure Bastion and no public IP on the VM by default (cost).
//          - NSG allows inbound SSH only from the caller's public IP.
//          - Hub connection is OPTIONAL here (connectToHub=false by default);
//            the deploy scripts create it after the hub router is ready. Bicep
//            users can set connectToHub=true for a one-shot deployment.
// =============================================================================

@description('Name of the spoke VNet.')
param spokeName string

@description('Azure region for the spoke.')
param location string

@description('Spoke VNet address prefix (recommended /24).')
param spokeAddressPrefix string

@description('Subnet prefix for the VM subnet (must be inside the spoke prefix).')
param subnetPrefix string

@description('Resource tags.')
param tags object

@description('Caller public IP allowed inbound on SSH (22). Use empty string to skip the SSH rule.')
param allowedSshSourceIp string = ''

@description('Create the hub VNet connection in Bicep. Default false (scripts do this post-router-ready).')
param connectToHub bool = false

@description('Resource ID of the local Virtual Hub (required only when connectToHub=true).')
param hubId string = ''

var subnetName = 'main'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${spokeName}'
  location: location
  tags: tags
  properties: {
    securityRules: empty(allowedSshSourceIp) ? [] : [
      {
        name: 'allow-ssh-from-caller'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedSshSourceIp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow inbound SSH from the deploying user only (lab).'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: spokeName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokeAddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Optional one-shot hub connection. Scripts leave this off and use az CLI so they
// can poll hub routingState first; Routing Intent handles the next-hop steering.
resource hubConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = if (connectToHub) {
  name: '${last(split(hubId, '/'))}/${spokeName}-conn'
  properties: {
    remoteVirtualNetwork: {
      id: vnet.id
    }
    enableInternetSecurity: true
  }
}

@description('Resource ID of the spoke VNet.')
output vnetId string = vnet.id

@description('Name of the spoke VNet.')
output vnetName string = vnet.name

@description('Name of the VM subnet.')
output subnetName string = subnetName

@description('Resource ID of the VM subnet.')
output subnetId string = '${vnet.id}/subnets/${subnetName}'
