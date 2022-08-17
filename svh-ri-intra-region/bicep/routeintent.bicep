param hubname string //Hubname
param nexthop string //Firewall as next hop

resource routeintent 'Microsoft.Network/virtualHubs/routingIntent@2022-01-01' = {
  name: '${hubname}/${hubname}_RoutingIntent'
  properties: {
    routingPolicies: [
      {
        name: 'InternetTraffic'
        destinations: [
          'InternetTraffic'
        ]
        nextHop: nexthop
      }
      {
        name: 'PrivateTraffic'
        destinations: [
          'PrivateTraffic'
        ]
        nextHop: nexthop
      }
    ]
  }
}
