// =============================================================================
// main.bicep  —  nva-spoke-internet lab
// Resource-Group-scoped orchestrator
//
// Wires modules:
//   vwan-hub  → dmz → public-lb → internal-lb → nva → spoke (×2) → onprem
//
// Outputs conform to the EXACT contract consumed by Alex's deploy.sh.
// DO NOT rename outputs without coordinating with Alex.
//
// Critical design constraints (see .squad/decisions.md):
//   - No vWAN VNet connections or route-table routes here — owned by deploy.sh
//   - ILB frontend 10.0.0.68 is the 0/0 next-hop deploy.sh programs on the hub
//   - deployOnPrem gates VPN GW (inside vwan-hub) and onprem resources
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

@description('VM size (B-series); validated against region by deploy.sh before calling this template')
param vmSize string = 'Standard_B2s'

@description('Deploy the on-premises simulation (VPN GW + on-prem VNet/NVA/VM)')
param deployOnPrem bool = false

@description('BGP ASN for the on-prem NVA (used by configure-onprem.sh after deploy)')
param onpremBgpAsn int = 65001

// ── Shared tags ───────────────────────────────────────────────────────────────
var tags = {
  lab: 'nva-spoke-internet'
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

// ── DMZ VNet (subnets, NSG, UDR on snet-nva) ─────────────────────────────────
module dmz 'modules/dmz.bicep' = {
  name: 'dmz-deploy'
  params: {
    location: location
    tags: tags
  }
}

// ── Public Load Balancer (SNAT egress + SSH mgmt inbound) ────────────────────
module publicLb 'modules/public-lb.bicep' = {
  name: 'public-lb-deploy'
  params: {
    location: location
    tags: tags
  }
}

// ── Internal Load Balancer (HA-ports, frontend 10.0.0.68 in snet-ilb) ────────
module ilb 'modules/internal-lb.bicep' = {
  name: 'ilb-deploy'
  params: {
    location: location
    snetIlbId: dmz.outputs.snetIlbId
    tags: tags
  }
}

// ── NVA VMs (nva-dmz-0 + nva-dmz-1) ─────────────────────────────────────────
module nva 'modules/nva.bicep' = {
  name: 'nva-deploy'
  params: {
    location: location
    snetNvaId: dmz.outputs.snetNvaId
    publicLbBackendPoolId: publicLb.outputs.backendPoolId
    ilbBackendPoolId: ilb.outputs.backendPoolId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
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

// ── On-prem simulation (always called; resources gated inside by deployOnPrem) ─
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
// Outputs  —  EXACT names consumed by Alex's deploy.sh
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

@description('ILB frontend private IP (0/0 next-hop for hub route table)')
output ilbFrontendIp string = ilb.outputs.frontendIpAddress

@description('Public LB egress/mgmt public IP address')
output publicLbPublicIp string = publicLb.outputs.publicIpAddress

@description('NVA VM names array')
output nvaNames array = nva.outputs.nvaNames

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
