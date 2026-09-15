// =============================================================================
// Module: er-circuit-info.bicep
// Purpose: Read an existing ExpressRoute circuit and re-publish the handful of
//          values the rest of the lab needs (service key, peering ID).
// Notes:   - This exists so downstream resources can consume circuit details
//            whether or not main.bicep is currently managing the circuit
//            resource itself (see the manageCircuits parameter).
//          - The caller wires dependsOn to the circuit module so that on a
//            first-run deployment this read happens after the circuit exists.
// =============================================================================

@description('Name of an existing ExpressRoute circuit in this resource group.')
param circuitName string

resource circuit 'Microsoft.Network/expressRouteCircuits@2023-11-01' existing = {
  name: circuitName
}

@description('Resource ID of the circuit.')
output circuitId string = circuit.id

@description('Name of the circuit.')
output circuitName string = circuit.name

@description('Service key to hand to the connectivity provider.')
output serviceKey string = circuit.properties.serviceKey

@description('Provider provisioning state at deployment time.')
output serviceProviderProvisioningState string = circuit.properties.serviceProviderProvisioningState

@description('Resource ID of the AzurePrivatePeering child (exists only once peering is configured).')
output privatePeeringId string = '${circuit.id}/peerings/AzurePrivatePeering'
