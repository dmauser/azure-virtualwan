// =============================================================================
// Module: expressroute-circuit.bicep
// Purpose: Deploy an ExpressRoute circuit in the "NotProvisioned" state.
// Notes:   - The circuit is created by Azure immediately, but it is NOT usable
//            until the connectivity provider (Megaport here) provisions its side
//            against the service key. That handoff is out-of-band and manual.
//          - er-wait.bicep polls for serviceProviderProvisioningState=Provisioned
//            before the hub connection is attempted.
//          - Lab defaults are the cheapest usable shape: Standard tier,
//            MeteredData family, 50 Mbps.
// =============================================================================

@description('Name of the ExpressRoute circuit.')
param circuitName string

@description('Azure region the circuit resource lives in. Pick the region closest to the peering location.')
param location string

@description('Connectivity provider name exactly as Azure spells it (e.g. "Megaport", "Equinix").')
param provider string

@description('ExpressRoute peering / edge location (e.g. "Dallas", "Chicago").')
param peeringLocation string

@description('Circuit bandwidth in Mbps. Keep low for a lab.')
param bandwidthMbps int = 50

@description('SKU tier. Standard is required for cross-region (non-local) reach.')
@allowed([
  'Local'
  'Standard'
  'Premium'
])
param skuTier string = 'Standard'

@description('SKU family / billing model.')
@allowed([
  'MeteredData'
  'UnlimitedData'
])
param skuFamily string = 'MeteredData'

@description('Resource tags.')
param tags object

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

@description('Service key to hand to the connectivity provider.')
output serviceKey string = circuit.properties.serviceKey

@description('Provider provisioning state at deployment time (expected "NotProvisioned" on first run).')
output serviceProviderProvisioningState string = circuit.properties.serviceProviderProvisioningState

@description('Resource ID of the AzurePrivatePeering child (exists only once peering is configured).')
output privatePeeringId string = '${circuit.id}/peerings/AzurePrivatePeering'
