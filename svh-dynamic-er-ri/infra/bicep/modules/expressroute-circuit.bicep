// =============================================================================
// Module: expressroute-circuit.bicep
// Purpose: Deploy an ExpressRoute circuit (provider not yet provisioned).
// Notes:   - Cost-conscious defaults: lowest practical bandwidth, Standard tier,
//            MeteredData family.
//          - In the interactive lab flow the deploy scripts create circuits via
//            az CLI so they can print the service key and pause for the provider
//            handoff. This module exists for pure-Bicep / non-interactive use and
//            is invoked from main.bicep only when a 'circuits' array is supplied.
// =============================================================================

@description('Name of the ExpressRoute circuit.')
param circuitName string

@description('Azure region for the circuit.')
param location string

@description('Resource tags.')
param tags object

@description('Service provider name (e.g., Megaport, Equinix).')
param provider string

@description('Peering / edge location (e.g., "Washington DC", "Silicon Valley").')
param peeringLocation string

@description('Bandwidth in Mbps. Use the lowest practical lab value.')
param bandwidthMbps int = 50

@description('SKU tier.')
@allowed([
  'Local'
  'Standard'
  'Premium'
])
param skuTier string = 'Standard'

@description('SKU family (billing model).')
@allowed([
  'MeteredData'
  'UnlimitedData'
])
param skuFamily string = 'MeteredData'

resource circuit 'Microsoft.Network/expressRouteCircuits@2023-11-01' = {
  name: circuitName
  location: location
  tags: tags
  sku: {
    name: '${skuTier}_${skuFamily}'
    tier: skuTier
    family: skuFamily
  }
  properties: {
    serviceProviderProperties: {
      serviceProviderName: provider
      peeringLocation: peeringLocation
      bandwidthInMbps: bandwidthMbps
    }
    allowClassicOperations: false
  }
}

@description('Resource ID of the circuit.')
output circuitId string = circuit.id

@description('Name of the circuit.')
output circuitName string = circuit.name

@description('Service key to hand to the provider.')
output serviceKey string = circuit.properties.serviceKey
