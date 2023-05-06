param hubname string //Hubname
param routingPolicies array = []

resource routeintent 'Microsoft.Network/virtualHubs/routingIntent@2022-01-01' = {
  name: '${hubname}/${hubname}_RoutingIntent'
  properties: {
    routingPolicies: routingPolicies
  }
}
