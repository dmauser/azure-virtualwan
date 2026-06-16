// =============================================================================
// Module: diagnostics.bicep
// Purpose: Optionally deploy a Log Analytics workspace for lab diagnostics.
//          Only created when enableDiagnostics=true in main.bicep.
//          Minimal cost: PerGB2018 SKU, 30-day retention.
// =============================================================================

@description('Name of the Log Analytics workspace.')
param workspaceName string

@description('Azure region for the workspace.')
param location string

@description('Resource tags.')
param tags object

@description('Log retention in days. 30 is the minimum free tier for PerGB2018.')
@minValue(30)
@maxValue(730)
param retentionDays int = 30

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

@description('Resource ID of the Log Analytics workspace.')
output workspaceId string = workspace.id

@description('Name of the Log Analytics workspace.')
output workspaceName string = workspace.name
