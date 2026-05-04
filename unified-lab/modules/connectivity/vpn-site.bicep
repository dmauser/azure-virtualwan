metadata description = 'Creates a VPN Site and S2S connection to a vWAN hub VPN Gateway'

@description('VPN Site name')
param siteName string

@description('Azure region')
param location string

@description('Virtual WAN resource ID')
param vwanId string

@description('VPN Gateway resource ID in the hub')
param vpnGatewayId string

@description('Branch public IP address')
param branchPublicIp string

@description('Branch BGP peering address')
param branchBgpAddress string

@description('Branch BGP ASN')
param branchBgpAsn int

@description('Pre-shared key')
@secure()
param psk string

@description('Tags')
param tags object = {}

// === VPN Site ===
resource vpnSite 'Microsoft.Network/vpnSites@2024-05-01' = {
  name: siteName
  location: location
  tags: tags
  properties: {
    virtualWan: { id: vwanId }
    vpnSiteLinks: [
      {
        name: '${siteName}-link1'
        properties: {
          ipAddress: branchPublicIp
          bgpProperties: {
            asn: branchBgpAsn
            bgpPeeringAddress: branchBgpAddress
          }
        }
      }
    ]
  }
}

// === VPN Connection ===
resource vpnConnection 'Microsoft.Network/vpnGateways/vpnConnections@2024-05-01' = {
  name: '${last(split(vpnGatewayId, '/'))}/${siteName}-conn'
  properties: {
    remoteVpnSite: { id: vpnSite.id }
    enableBgp: true
    vpnLinkConnections: [
      {
        name: '${siteName}-link1-conn'
        properties: {
          vpnSiteLink: { id: vpnSite.properties.vpnSiteLinks[0].id }
          sharedKey: psk
          enableBgp: true
          vpnConnectionProtocolType: 'IKEv2'
        }
      }
    ]
  }
}

output vpnSiteId string = vpnSite.id
output connectionId string = vpnConnection.id
