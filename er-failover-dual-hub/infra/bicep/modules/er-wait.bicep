// =============================================================================
// Module: er-wait.bicep
// Purpose: Block the deployment until the connectivity provider has provisioned
//          an ExpressRoute circuit, so the vHub ExpressRoute connection is only
//          created once it can succeed.
//
// How it works:
//   Microsoft.Resources/deploymentScripts runs an Azure CLI container that polls
//   `az network express-route show` until serviceProviderProvisioningState is
//   "Provisioned" (and, optionally, until AzurePrivatePeering exists).
//   main.bicep wires the ER connection with dependsOn this module.
//
// Requirements:
//   - Microsoft.ContainerInstance must be registered on the subscription.
//   - The supplied user-assigned identity needs Reader on the circuit.
//
// Cost/behaviour notes:
//   - forceUpdateTag defaults to utcNow() so the poller re-evaluates on every
//     redeploy instead of returning a cached success.
//   - cleanupPreference is 'OnSuccess': a failed/timed-out poller keeps its
//     container and logs so you can read why it gave up.
// =============================================================================

@description('Name of the deployment script resource.')
param waitName string

@description('Azure region for the deployment script.')
param location string

@description('Resource ID of the ExpressRoute circuit to poll.')
param circuitId string

@description('Resource ID of the user-assigned managed identity (needs Reader on the circuit).')
param identityId string

@description('''
Also wait for AzurePrivatePeering to exist on the circuit.
The connectivity provider (Megaport MCR) always configures peering in this lab,
so this stays true. Kept as a parameter for portability to Layer 3 providers
that hand the peering over ready-made.
''')
param requirePrivatePeering bool = true

@description('Seconds between polls.')
@minValue(15)
@maxValue(600)
param pollSeconds int = 60

@description('Hard deadline in seconds for the wait. Keep below the container timeout.')
@minValue(60)
@maxValue(82800)
param waitTimeoutSeconds int = 6600

@description('Container timeout (ISO 8601). Must exceed waitTimeoutSeconds.')
param containerTimeout string = 'PT2H'

@description('Azure CLI version for the script container.')
param azCliVersion string = '2.61.0'

@description('Forces the poller to re-run on redeploy. Leave as-is unless you want cached results.')
param forceUpdateTag string = utcNow()

@description('Resource tags.')
param tags object

resource wait 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: waitName
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    azCliVersion: azCliVersion
    forceUpdateTag: forceUpdateTag
    timeout: containerTimeout
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      {
        name: 'CIRCUIT_ID'
        value: circuitId
      }
      {
        name: 'POLL_SECONDS'
        value: string(pollSeconds)
      }
      {
        name: 'TIMEOUT_SECONDS'
        value: string(waitTimeoutSeconds)
      }
      {
        name: 'REQUIRE_PRIVATE_PEERING'
        value: requirePrivatePeering ? 'true' : 'false'
      }
    ]
    scriptContent: loadTextContent('../scripts/wait-for-er-provisioned.sh')
  }
}

@description('True once the circuit satisfied the provisioning gate.')
output ready bool = wait.properties.outputs.ready

@description('Provider provisioning state observed when the gate passed.')
output providerState string = wait.properties.outputs.providerState

@description('Seconds the deployment waited for the provider.')
output elapsedSeconds int = wait.properties.outputs.elapsedSeconds
