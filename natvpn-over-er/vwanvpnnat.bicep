param vpngwname string = 'vhub1-vpngw'
param overlapiprange string = '10.3.0.0/24'
param spoke4natrange string = '100.64.1.0/24'
param extbranchrange string = '100.64.2.0/24'
param vhubnatname string = 'vhub'
param extbranchnatname string = 'extbranch'
param location string = resourceGroup().location
param vpngwid string = resourceId('Microsoft.Network/vpnGateways', 'vhub1-vpngw')
param vhubname string = 'vhub1'
param sitename string = 'site-branch'

resource vwanrulename 'Microsoft.Network/vpnGateways@2022-07-01' = {
 name: vpngwname
 location: location
 properties: {
  virtualHub: {
    id: '${resourceId('Microsoft.Network/virtualHubs',vhubname)}'
  }
  enableBgpRouteTranslationForNat: true
  connections: [
    {
      name: 'Connection-site-branch'
      properties: {
        remoteVpnSite: {
          id: '${resourceId('Microsoft.Network/vpnSites',sitename)}'
        }
        routingConfiguration: {
          associatedRouteTable: {
            id: '${resourceId('Microsoft.Network/virtualHubs',vhubname)}/hubRouteTables/defaultRouteTable'
          }
          propagatedRouteTables: {
            labels: [
              'default'
            ]
            ids: [
              {
                id: '${resourceId('Microsoft.Network/virtualHubs',vhubname)}/hubRouteTables/defaultRouteTable'
              }
            ]
          }
        }
        vpnLinkConnections: [
          {
            name: sitename
            properties: {
              connectionBandwidth: 10
              vpnConnectionProtocolType: 'IKEv2'
              sharedKey: 'abc123'
              enableBgp: true
              vpnSiteLink: {
                id: '${resourceId('Microsoft.Network/vpnSites',sitename)}/vpnSiteLinks/${sitename}'
              }
              useLocalAzureIpAddress: true
              vpnLinkConnectionMode: 'Default'
              ingressNatRules: [
                {
                  id: '${resourceId('Microsoft.Network/vpnGateways',vpngwname)}/natRules/extbranch'
                }
              ]
              egressNatRules: [
                {
                  id: '${resourceId('Microsoft.Network/vpnGateways',vpngwname)}/natRules/vhub'
                }
              ]
            }
         
          }
        ]  
        }
      }
  ]
  natRules: [
    {
      name:vhubnatname
      id: '${vpngwid}/natRules/${vhubnatname}'      
      properties: {
        type:'Static'
        mode: 'EgressSnat'
        internalMappings: [
          {
            addressSpace: overlapiprange
          } 
        ]
        externalMappings: [
          {
            addressSpace: spoke4natrange
          }
        ]
      }
    }
    {
      name: extbranchnatname
      id: '${vpngwid}/natRules/${extbranchnatname}'   
      properties: {
        mode:'IngressSnat'
        type: 'Static'
        internalMappings: [
          {
            addressSpace: overlapiprange
          }          
        ]
        externalMappings: [
          {
            addressSpace: extbranchrange
          }
        ]
      }
    }
  ]
 }
}
