// =============================================================================
// Module: nva.bicep
// 2x Ubuntu IPTables NVA VMs in snet-nva (DMZ)
//
// Each NVA:
//   - NIC in snet-nva with enableIPForwarding=true
//   - Joined to Public LB backend pool (for outbound SNAT + inbound SSH mgmt)
//   - Joined to ILB backend pool (HA-ports rule for hub 0/0 routing)
//   - cloud-init: ip_forward + iptables MASQUERADE (nva.yaml)
//   - Password auth, managed boot diagnostics, StandardSSD_LRS
// =============================================================================

@description('Azure region')
param location string

@description('snet-nva subnet resource ID (10.0.0.0/26 in vnet-dmz)')
param snetNvaId string

@description('Public LB backend pool resource ID')
param publicLbBackendPoolId string

@description('ILB backend pool resource ID')
param ilbBackendPoolId string

@description('Admin username')
param adminUsername string

@description('Admin password (secure)')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Resource tags')
param tags object = {}

// Cloud-init loaded at compile time from sibling cloud-init/ folder
var nvaCloudInit = loadFileAsBase64('../cloud-init/nva.yaml')

// ── 2x NVA VMs ────────────────────────────────────────────────────────────────
module nvaVm 'vm.bicep' = [for i in range(0, 2): {
  name: 'nva-dmz-${i}-deploy'
  params: {
    vmName: 'nva-dmz-${i}'
    location: location
    subnetId: snetNvaId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    customData: nvaCloudInit
    enableIPForwarding: true
    attachPublicIp: false
    lbBackendPoolRefs: [
      { id: publicLbBackendPoolId }
      { id: ilbBackendPoolId }
    ]
    tags: tags
  }
}]

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('NVA VM names (always [nva-dmz-0, nva-dmz-1])')
output nvaNames array = ['nva-dmz-0', 'nva-dmz-1']

@description('NVA 0 private IP')
output nva0PrivateIp string = nvaVm[0].outputs.privateIp

@description('NVA 1 private IP')
output nva1PrivateIp string = nvaVm[1].outputs.privateIp
