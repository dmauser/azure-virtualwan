// =============================================================================
// Module: spoke-vnet.bicep
// Purpose: One spoke VNet per hub, with a VM subnet, an NSG, and the hub
//          VNet connection.
// Notes:   - The hub connection is created here (not in a post-deploy script)
//            because this lab is fully IaC-driven. ARM serialises it behind the
//            hub's own provisioning, so no manual routingState polling is needed.
//          - enableInternetSecurity is false: there is no Azure Firewall or
//            Routing Intent in this lab, so the spoke keeps its own default
//            Internet breakout and the hub only carries private prefixes.
// =============================================================================

@description('Name of the spoke VNet.')
param spokeName string

@description('Azure region for the spoke (must match its hub region).')
param location string

@description('Spoke VNet address prefix (/24 recommended).')
param spokeAddressPrefix string

@description('Subnet prefix for the VM subnet (must sit inside spokeAddressPrefix).')
param subnetPrefix string

@description('Resource ID of the local Virtual Hub.')
param hubId string

@description('Resource tags.')
param tags object

var subnetName = 'main'
var hubName = last(split(hubId, '/'))

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${spokeName}'
  location: location
  tags: tags
  properties: {
    // The VMs have no public IP, so there is no inbound-from-internet rule.
    // Interactive access is via Serial Console, which does not traverse the NSG.
    securityRules: [
      {
        // Required for the failover tests: ICMP/SSH between the two spokes and
        // from on-premises across either ExpressRoute circuit.
        name: 'allow-private-rfc1918'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefixes: [
            '10.0.0.0/8'
            '172.16.0.0/12'
            '192.168.0.0/16'
          ]
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow private-space traffic so ping/traceroute failover tests work.'
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

resource hub 'Microsoft.Network/virtualHubs@2023-11-01' existing = {
  name: hubName
}

resource hubConnection 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  parent: hub
  name: '${spokeName}-conn'
  properties: {
    remoteVirtualNetwork: {
      id: vnet.id
    }
    enableInternetSecurity: false
    routingConfiguration: {
      associatedRouteTable: {
        id: '${hubId}/hubRouteTables/defaultRouteTable'
      }
      propagatedRouteTables: {
        labels: [
          'default'
        ]
        ids: [
          {
            id: '${hubId}/hubRouteTables/defaultRouteTable'
          }
        ]
      }
    }
  }
}

@description('Resource ID of the spoke VNet.')
output vnetId string = vnet.id

@description('Name of the spoke VNet.')
output vnetName string = vnet.name

@description('Resource ID of the VM subnet.')
output subnetId string = '${vnet.id}/subnets/${subnetName}'

@description('Name of the hub VNet connection.')
output hubConnectionName string = hubConnection.name
