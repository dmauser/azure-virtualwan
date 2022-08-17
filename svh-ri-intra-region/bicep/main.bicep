// Parameters
@sys.description('Select scenario: PrivateOnly,Private-and-Internet,InternetOnly')
@allowed([
  'PrivateOnly'
  'Private-and-Internet'
  'InternetOnly'
])
param scenarioOption string = 'PrivateOnly'
param hubname string //Hubname
param nexthop string //Firewall as next hop

//Private Traffic Only
module riprivateonly 'routeintent.bicep' = if (scenarioOption == 'PrivateOnly') {
  name: '${hubname}PrivateOnly'
  params: {
    hubname: hubname
    routingPolicies: [
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

//Internet Traffic Only
module riinternetonly 'routeintent.bicep' = if (scenarioOption == 'InternetOnly') {
  name: '${hubname}PrivateOnly'
  params: {
    hubname: hubname
    routingPolicies: [
      {
        name: 'PublicTraffic'
        destinations: [
          'Internet'
        ]
        nextHop: nexthop
      }
    ]
  }
}

//Private and Internet Traffic
module riinternetandprivate 'routeintent.bicep' = if (scenarioOption == 'Private-and-Internet') {
  name: '${hubname}PrivateOnly'
  params: {
    hubname: hubname
    routingPolicies: [
      {
        name: 'PublicTraffic'
        destinations: [
          'Internet'
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
