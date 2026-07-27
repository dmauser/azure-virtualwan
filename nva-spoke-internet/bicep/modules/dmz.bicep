// =============================================================================
// Module: dmz.bicep
// DMZ VNet + subnets + NSG + UDR on snet-nva
//
// Address plan:
//   VNet:     10.0.0.0/24
//   snet-nva: 10.0.0.0/26   (NVA VMs live here)
//   snet-ilb: 10.0.0.64/26  (ILB frontend 10.0.0.68 lives here)
//
// UDR on snet-nva: 0.0.0.0/0 → Internet
//   Prevents propagated default route from the hub from black-holing NVA egress.
// =============================================================================

@description('Azure region')
param location string

@description('Resource tags')
param tags object = {}

// ── NSG ───────────────────────────────────────────────────────────────────────
resource nsgDmz 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-dmz'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Inbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow SSH inbound for mgmt and health probe'
        }
      }
      {
        name: 'Allow-RFC1918-Inbound'
        properties: {
          priority: 110
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefixes: [ '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' ]
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow all RFC-1918 traffic inbound (spoke + hub traffic)'
        }
      }
    ]
  }
}

// ── UDR on snet-nva: force 0/0 to Internet ───────────────────────────────────
// Prevents the vHub-propagated 0/0 default route from looping NVA egress traffic
// back into the hub instead of letting it reach the internet via the Public LB.
resource udrNva 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'udr-snet-nva'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// ── VNet ──────────────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-dmz'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/24' ] }
    subnets: [
      {
        name: 'snet-nva'
        properties: {
          addressPrefix: '10.0.0.0/26'
          networkSecurityGroup: { id: nsgDmz.id }
          routeTable: { id: udrNva.id }
        }
      }
      {
        name: 'snet-ilb'
        properties: {
          addressPrefix: '10.0.0.64/26'
          networkSecurityGroup: { id: nsgDmz.id }
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('DMZ VNet resource ID')
output vnetId string = vnet.id

@description('DMZ VNet name')
output vnetName string = vnet.name

@description('snet-nva subnet resource ID')
output snetNvaId string = vnet.properties.subnets[0].id

@description('snet-ilb subnet resource ID')
output snetIlbId string = vnet.properties.subnets[1].id
