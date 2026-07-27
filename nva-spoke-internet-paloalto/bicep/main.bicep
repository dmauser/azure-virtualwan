// =============================================================================
// main.bicep — nva-spoke-internet-paloalto lab
// Resource-Group-scoped orchestrator
//
// Wires modules:
//   vwan-hub → dmz → public-lb → internal-lb → palo-alto → spoke (×2) → onprem
//
// Outputs conform to the EXACT 16-output contract consumed by deploy.sh
// (see .squad/decisions.md).  DO NOT rename outputs without coordinating
// with the deploy scripts and the rest of the team.
//
// Critical design constraints:
//   - No vWAN VNet connections or route-table routes here — owned by deploy.sh
//   - ILB frontend 10.0.0.68 is the 0/0 next-hop deploy.sh programs on the hub
//   - deployOnPrem gates VPN GW (inside vwan-hub) and onprem resources
//   - PA firewalls bootstrap from Azure Files share (params below)
// =============================================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string

@description('Admin username for all VMs')
param adminUsername string

@description('Admin password for all VMs')
@secure()
param adminPassword string

@description('VM size for PA firewalls and spoke/onprem VMs; validated by deploy.sh SKU preflight')
param vmSize string = 'Standard_DS3_v2'

@description('Deploy the on-premises simulation (VPN GW + on-prem VNet/NVA/VM)')
param deployOnPrem bool = false

@description('BGP ASN for the on-prem NVA (used by configure-onprem.sh after deploy)')
param onpremBgpAsn int = 65001

@description('Bootstrap storage account name (Azure Files share owner, created by deploy.sh Phase 5b)')
param bootstrapStorageAccount string

@description('Bootstrap storage account access key')
@secure()
param bootstrapStorageKey string

@description('Azure Files share name containing PA bootstrap content')
param bootstrapFileShare string

@description('Directory inside the bootstrap share (empty = root; PA reads config/ subfolder)')
param bootstrapShareDirectory string = ''

// ── Shared tags ───────────────────────────────────────────────────────────────
var tags = {
  lab: 'nva-spoke-internet-paloalto'
  deployedBy: 'bicep'
}

// ── vWAN + Virtual Hub (+ conditional VPN GW) ─────────────────────────────────
module vwanHub 'modules/vwan-hub.bicep' = {
  name: 'vwan-hub-deploy'
  params: {
    location: location
    deployOnPrem: deployOnPrem
    tags: tags
  }
}

// ── DMZ VNet (3 subnets: snet-mgmt / snet-untrust / snet-trust + UDRs + NSG) ─
module dmz 'modules/dmz.bicep' = {
  name: 'dmz-deploy'
  params: {
    location: location
    tags: tags
  }
}

// ── Public Load Balancer (SNAT egress + health probe on PA untrust NICs) ──────
module publicLb 'modules/public-lb.bicep' = {
  name: 'public-lb-deploy'
  params: {
    location: location
    tags: tags
  }
}

// ── Internal Load Balancer (HA-ports, static frontend 10.0.0.68 in snet-trust) ─
module ilb 'modules/internal-lb.bicep' = {
  name: 'ilb-deploy'
  params: {
    location: location
    // snetTrustId → snetIlbId: the ILB frontend IP 10.0.0.68 is within
    // snet-trust (10.0.0.64/27), preserving the hub 0/0 next-hop contract.
    snetIlbId: dmz.outputs.snetTrustId
    tags: tags
  }
}

// ── Palo Alto VM-Series (pa-fw-0, pa-fw-1) ───────────────────────────────────
module paloAlto 'modules/palo-alto.bicep' = {
  name: 'palo-alto-deploy'
  params: {
    location: location
    snetMgmtId: dmz.outputs.snetMgmtId
    snetUntrustId: dmz.outputs.snetUntrustId
    snetTrustId: dmz.outputs.snetTrustId
    publicLbBackendPoolId: publicLb.outputs.backendPoolId
    ilbBackendPoolId: ilb.outputs.backendPoolId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    bootstrapStorageAccount: bootstrapStorageAccount
    bootstrapStorageKey: bootstrapStorageKey
    bootstrapFileShare: bootstrapFileShare
    bootstrapShareDirectory: bootstrapShareDirectory
    tags: tags
  }
}

// ── Spoke 1 (10.1.0.0/24) ────────────────────────────────────────────────────
module spoke1 'modules/spoke.bicep' = {
  name: 'spoke1-deploy'
  params: {
    vnetName: 'vnet-spoke1'
    vnetAddressPrefix: '10.1.0.0/24'
    workloadSubnetPrefix: '10.1.0.0/26'
    vmName: 'vm-spoke1'
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    tags: tags
  }
}

// ── Spoke 2 (10.2.0.0/24) ────────────────────────────────────────────────────
module spoke2 'modules/spoke.bicep' = {
  name: 'spoke2-deploy'
  params: {
    vnetName: 'vnet-spoke2'
    vnetAddressPrefix: '10.2.0.0/24'
    workloadSubnetPrefix: '10.2.0.0/26'
    vmName: 'vm-spoke2'
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    tags: tags
  }
}

// ── On-prem simulation (resources gated inside module by deployOnPrem flag) ───
module onprem 'modules/onprem.bicep' = {
  name: 'onprem-deploy'
  params: {
    deployOnPrem: deployOnPrem
    location: location
    onpremBgpAsn: onpremBgpAsn
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    tags: tags
  }
}

// =============================================================================
// Outputs — EXACT names consumed by deploy.sh (.squad/decisions.md contract)
// Any rename here MUST be mirrored in deploy.sh get_output() calls.
// =============================================================================

@description('Deployment region')
output location string = location

@description('Virtual WAN name')
output vwanName string = vwanHub.outputs.vwanName

@description('Virtual Hub name')
output hubName string = vwanHub.outputs.hubName

@description('Virtual Hub resource ID')
output hubId string = vwanHub.outputs.hubId

@description('DMZ VNet resource ID')
output dmzVnetId string = dmz.outputs.vnetId

@description('Spoke 1 VNet resource ID')
output spoke1VnetId string = spoke1.outputs.vnetId

@description('Spoke 2 VNet resource ID')
output spoke2VnetId string = spoke2.outputs.vnetId

@description('ILB frontend private IP — 0/0 next-hop programmed on hub route table by deploy.sh')
output ilbFrontendIp string = ilb.outputs.frontendIpAddress

@description('Public LB egress/SNAT public IP address')
output publicLbPublicIp string = publicLb.outputs.publicIpAddress

@description('PA firewall VM names (pa-fw-0, pa-fw-1)')
output nvaNames array = paloAlto.outputs.paNames

@description('VPN Gateway name (empty string when deployOnPrem=false)')
output vpnGatewayName string = vwanHub.outputs.vpnGatewayName

@description('On-prem VNet resource ID (empty string when deployOnPrem=false)')
output onpremVnetId string = onprem.outputs.onpremVnetId

@description('On-prem NVA public IP address (empty string when deployOnPrem=false)')
output onpremNvaPublicIp string = onprem.outputs.onpremNvaPublicIp

@description('On-prem NVA private IP address (empty string when deployOnPrem=false)')
output onpremNvaPrivateIp string = onprem.outputs.onpremNvaPrivateIp

@description('On-prem NVA VM name (empty string when deployOnPrem=false)')
output onpremNvaName string = onprem.outputs.onpremNvaName

@description('On-prem workload VM name (empty string when deployOnPrem=false)')
output onpremVmName string = onprem.outputs.onpremVmName
