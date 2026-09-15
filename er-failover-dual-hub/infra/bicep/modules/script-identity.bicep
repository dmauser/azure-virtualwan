// =============================================================================
// Module: script-identity.bicep
// Purpose: User-assigned managed identity used by the er-wait deployment script.
// Notes:   - The poller only ever READS the circuit, so Reader at resource-group
//            scope is sufficient.
//          - createRoleAssignment can be set to false if you do not hold
//            Owner / User Access Administrator on the resource group. In that
//            case grant Reader to the identity out-of-band before deploying.
// =============================================================================

@description('Name of the user-assigned managed identity.')
param identityName string

@description('Azure region for the identity.')
param location string

@description('Create the Reader role assignment. Requires Owner or User Access Administrator.')
param createRoleAssignment bool = true

@description('Resource tags.')
param tags object

// Built-in "Reader" role definition ID.
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (createRoleAssignment) {
  name: guid(resourceGroup().id, identity.id, readerRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the managed identity.')
output identityId string = identity.id

@description('Principal (object) ID of the managed identity.')
output principalId string = identity.properties.principalId
