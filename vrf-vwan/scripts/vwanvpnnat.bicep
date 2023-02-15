param vpngwname string = 'hub2-vpngw'
param overlapiprange string = '10.110.0.0/16'
param outNatrange string = '10.140.0.0/16'
param inNatrange string = '10.130.0.0/16'
param outNatname string = 'branch1'
param inNatname string = 'branch3'
param vpngwid string = resourceId('Microsoft.Network/vpnGateways', 'hub2-vpngw')
param vhubname string = 'hub2'
param sitename string = 'site-branch3'
param connname string = 'conn-site-branch3'
param useLocalAzureIpAddress bool = false
param location string

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
      name: connname
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
              useLocalAzureIpAddress: useLocalAzureIpAddress
              vpnLinkConnectionMode: 'Default'
              ingressNatRules: [
                {
                  id: '${resourceId('Microsoft.Network/vpnGateways',vpngwname)}/natRules/${inNatname}'
                }
              ]
              egressNatRules: [
                {
                  id: '${resourceId('Microsoft.Network/vpnGateways',vpngwname)}/natRules/${outNatname}'
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
      name:outNatname
      id: '${vpngwid}/natRules/${outNatname}'      
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
            addressSpace: outNatrange
          }
        ]
      }
    }
    {
      name: inNatname
      id: '${vpngwid}/natRules/${inNatname}'   
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
            addressSpace: inNatrange
          }
        ]
      }
    }
  ]
 }
}
