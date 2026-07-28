using 'main.bicep'

// =============================================================================
// main.bicepparam — sample parameters for nva-spoke-internet-paloalto
//
// ⚠  bootstrapStorageAccount / bootstrapStorageKey / bootstrapFileShare are
//    populated automatically by deploy.sh during Phase 5b (bootstrap storage
//    setup).  Replace the placeholder values below only if you are running
//    `az deployment group create` directly without deploy.sh.
// =============================================================================

param location = 'westus3'
param adminUsername = 'azureadmin'
param adminPassword = 'REPLACE_WITH_SECURE_PASSWORD'
param vmSize = 'Standard_DS3_v2'
param deployOnPrem = false
param onpremBgpAsn = 65001
param bootstrapStorageAccount = 'REPLACE_WITH_SA_NAME'
param bootstrapStorageKey = 'REPLACE_WITH_SA_KEY'
param bootstrapFileShare = 'bootstrap'
param bootstrapShareDirectory = ''
