// =============================================================================
// Module: onprem.bicep
// Simulated on-premises environment — ALWAYS deployed but resources are gated
// on deployOnPrem param. This avoids ARM reference() on undeployed modules.
//
// When deployOnPrem = true:
//   - VNet: vnet-onprem (192.168.100.0/24)
//     - snet-nva:       192.168.100.0/27  → on-prem NVA (nva-onprem)
//     - snet-workload:  192.168.100.32/27 → workload VM (vm-onprem)
//   - nva-onprem: Ubuntu with strongSwan + FRR, Public IP, static IP 192.168.100.4,
//                 IP forwarding. Tunnel/BGP configured by Alex's configure-onprem.sh.
//   - vm-onprem:  Minimal Ubuntu workload VM in snet-workload
//   - UDR on snet-workload: 10.0.0.0/8 → 192.168.100.4 (route to Azure via on-prem NVA)
//
// When deployOnPrem = false:
//   - No resources deployed; all outputs are empty strings.
// =============================================================================

@description('Deploy on-premises simulation resources')
param deployOnPrem bool = false

@description('Azure region (used as a simulated "on-prem" region)')
param location string

@description('On-prem NVA BGP ASN (used in cloud-init rendered by configure-onprem.sh)')
param onpremBgpAsn int = 65001

@description('Admin username')
param adminUsername string

@description('Admin password (secure)')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Resource tags')
param tags object = {}

// Cloud-init files
var onpremNvaCloudInit  = loadFileAsBase64('../cloud-init/onprem-nva.yaml')
var workloadCloudInit   = loadFileAsBase64('../cloud-init/workload.yaml')

// ── UDR on snet-workload: route Azure (RFC-1918) traffic via on-prem NVA ─────
resource udrWorkload 'Microsoft.Network/routeTables@2023-11-01' = if (deployOnPrem) {
  name: 'udr-onprem-workload'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-azure-via-nva'
        properties: {
          // Route all Azure RFC-1918 traffic through the on-prem NVA
          // (covers 10.0.0.0/8 which includes hub, DMZ, spokes)
          addressPrefix: '10.0.0.0/8'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '192.168.100.4'   // nva-onprem static IP in snet-nva
        }
      }
    ]
  }
}

// ── On-prem VNet ─────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (deployOnPrem) {
  name: 'vnet-onprem'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '192.168.100.0/24' ] }
    subnets: [
      {
        name: 'snet-nva'
        properties: {
          addressPrefix: '192.168.100.0/27'
        }
      }
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: '192.168.100.32/27'
          routeTable: { id: udrWorkload.id }
        }
      }
    ]
  }
}

// ── On-prem NVA VM (strongSwan + FRR, public IP, static private IP) ──────────
module nvaOnprem 'vm.bicep' = if (deployOnPrem) {
  name: 'nva-onprem-deploy'
  params: {
    vmName: 'nva-onprem'
    location: location
    subnetId: vnet!.properties.subnets[0].id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    customData: onpremNvaCloudInit
    enableIPForwarding: true
    attachPublicIp: true
    privateIPAddress: '192.168.100.4'   // Fixed; matches UDR next-hop above
    tags: tags
  }
}

// ── On-prem workload VM ───────────────────────────────────────────────────────
module vmOnprem 'vm.bicep' = if (deployOnPrem) {
  name: 'vm-onprem-deploy'
  params: {
    vmName: 'vm-onprem'
    location: location
    subnetId: vnet!.properties.subnets[1].id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    customData: workloadCloudInit
    tags: tags
  }
}

// ── Outputs — always emitted; empty string when deployOnPrem=false ─────────────
@description('On-prem VNet resource ID (empty if not deployed)')
output onpremVnetId string = deployOnPrem ? vnet!.id : ''

@description('On-prem NVA public IP address (empty if not deployed)')
output onpremNvaPublicIp string = deployOnPrem ? nvaOnprem!.outputs.publicIp : ''

@description('On-prem NVA private IP address (empty if not deployed)')
output onpremNvaPrivateIp string = deployOnPrem ? nvaOnprem!.outputs.privateIp : ''

@description('On-prem NVA VM name (empty if not deployed)')
output onpremNvaName string = deployOnPrem ? 'nva-onprem' : ''

@description('On-prem workload VM name (empty if not deployed)')
output onpremVmName string = deployOnPrem ? 'vm-onprem' : ''

@description('On-prem NVA BGP ASN (read by configure-onprem.sh via deployment output)')
output onpremBgpAsn int = onpremBgpAsn
