// =============================================================================
// Module: dmz.bicep — DMZ VNet with 3-subnet design for Palo Alto VM-Series
//
// Subnets:
//   snet-mgmt    10.0.0.0/27   PA eth0 mgmt   (UDR 0/0→Internet, NSG)
//   snet-untrust 10.0.0.32/27  PA eth1 untrust (UDR 0/0→Internet, NSG, Public LB backend)
//   snet-trust   10.0.0.64/27  PA eth2 trust   (NO 0/0 UDR, NSG, ILB backend)
//
// The UDR on snet-mgmt and snet-untrust overrides any hub-propagated 0/0 route
// so PA egress traffic goes directly to Internet without looping through the hub.
//
// ILB frontend 10.0.0.68 sits inside snet-trust (10.0.0.64/27), preserving the
// hub static-route 0/0 → 10.0.0.68 contract from .squad/decisions.md.
// =============================================================================

param location string
param tags object = {}

// UDR: 0/0 → Internet.  Applied to snet-mgmt and snet-untrust so hub-propagated
// default routes do not loop PA egress traffic back through the hub.
resource udrInternet 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'udr-dmz-internet'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// NSG: allows RFC-1918 intra-lab, SSH (22) for management, PA GUI (443).
// In production tighten source prefixes for SSH/HTTPS rules.
resource nsgDmz 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-dmz'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-rfc1918-inbound'
        properties: {
          priority: 100
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '10.0.0.0/8'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'allow-ssh-inbound'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'allow-pa-mgmt-https-inbound'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'allow-azure-lb-inbound'
        properties: {
          priority: 900
          protocol: '*'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnetDmz 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-dmz'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/24' ]
    }
    subnets: [
      {
        name: 'snet-mgmt'
        properties: {
          addressPrefix: '10.0.0.0/27'
          routeTable: { id: udrInternet.id }
          networkSecurityGroup: { id: nsgDmz.id }
        }
      }
      {
        name: 'snet-untrust'
        properties: {
          addressPrefix: '10.0.0.32/27'
          routeTable: { id: udrInternet.id }
          networkSecurityGroup: { id: nsgDmz.id }
        }
      }
      {
        name: 'snet-trust'
        properties: {
          addressPrefix: '10.0.0.64/27'
          // NO 0/0 UDR on snet-trust: return traffic from PA trust NIC must
          // reach spoke/hub destinations via vWAN; a 0/0→Internet here would
          // black-hole those return paths.
          networkSecurityGroup: { id: nsgDmz.id }
        }
      }
    ]
  }
}

@description('DMZ VNet resource ID')
output vnetId   string = vnetDmz.id

@description('DMZ VNet name')
output vnetName string = vnetDmz.name

@description('snet-mgmt subnet ID (10.0.0.0/27 — PA eth0 management)')
output snetMgmtId    string = vnetDmz.properties.subnets[0].id

@description('snet-untrust subnet ID (10.0.0.32/27 — PA eth1, Public LB backend)')
output snetUntrustId string = vnetDmz.properties.subnets[1].id

@description('snet-trust subnet ID (10.0.0.64/27 — PA eth2, ILB frontend 10.0.0.68)')
output snetTrustId   string = vnetDmz.properties.subnets[2].id
