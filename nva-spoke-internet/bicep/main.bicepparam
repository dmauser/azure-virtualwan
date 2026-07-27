// =============================================================================
// main.bicepparam  —  nva-spoke-internet lab
// Sample parameter file for local testing / CI.
// Replace placeholder credentials before deploying to a real subscription.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-nva-spoke-internet \
//     --template-file main.bicep \
//     --parameters main.bicepparam
// =============================================================================

using 'main.bicep'

param location = 'eastus2'

// Replace with a real admin username before deploying
param adminUsername = 'azureadmin'

// Replace with a real password before deploying
// Must meet Azure complexity requirements (12+ chars, upper, lower, digit, special)
param adminPassword = 'PlaceholderP@ssw0rd123!'

// B-series SKU — validated against region by deploy.sh before template invocation
param vmSize = 'Standard_B2s'

// Set to true to deploy the on-prem simulation (VPN GW + on-prem VNet/NVA/VM)
// deploy.sh passes this as a flag; default is false for standard lab bring-up
param deployOnPrem = false

// On-prem NVA BGP ASN used by configure-onprem.sh after deploy
param onpremBgpAsn = 65001
