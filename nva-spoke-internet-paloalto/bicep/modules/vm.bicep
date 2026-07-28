// =============================================================================
// Module: vm.bicep
// Generic Ubuntu 22.04 LTS VM
//   - Password auth + Serial Console (managed boot diagnostics, no storageUri)
//   - StandardSSD_LRS managed OS disk
//   - Optional cloud-init via customData (base64-encoded, use loadFileAsBase64)
//   - Optional IP forwarding on the NIC (set true for NVAs)
//   - Optional static private IP
//   - Optional LB backend pool membership via lbBackendPoolRefs
// =============================================================================

@description('VM name')
param vmName string

@description('Azure region')
param location string

@description('Subnet resource ID for the primary NIC')
param subnetId string

@description('Admin username')
param adminUsername string

@description('Admin password (secure)')
@secure()
param adminPassword string

@description('VM size (B-series recommended for cost)')
param vmSize string = 'Standard_B2s'

@description('Resource tags')
param tags object = {}

@description('Base64-encoded cloud-init (customData). Use loadFileAsBase64() at call site. Empty = no cloud-init.')
param customData string = ''

@description('Enable IP forwarding on the NIC. Set true for NVAs.')
param enableIPForwarding bool = false

@description('Attach a Standard static public IP to the NIC.')
param attachPublicIp bool = false

@description('Static private IP address. Empty string = Dynamic allocation.')
param privateIPAddress string = ''

@description('LB backend pool references to join. Array of {id: string} objects. Empty = no LB pools.')
param lbBackendPoolRefs array = []

// ── Public IP (only when requested) ──────────────────────────────────────────
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (attachPublicIp) {
  name: 'pip-${vmName}'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ── NIC ───────────────────────────────────────────────────────────────────────
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: enableIPForwarding
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAllocationMethod: empty(privateIPAddress) ? 'Dynamic' : 'Static'
          privateIPAddress: empty(privateIPAddress) ? null : privateIPAddress
          publicIPAddress: attachPublicIp ? { id: publicIp.id } : null
          loadBalancerBackendAddressPools: lbBackendPoolRefs
        }
      }
    ]
  }
}

// ── VM ────────────────────────────────────────────────────────────────────────
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: union(
      {
        computerName: vmName
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: { disablePasswordAuthentication: false }
      },
      // Conditionally add customData only when provided (avoids empty-string base64 noise)
      empty(customData) ? {} : { customData: customData }
    )
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
    // Managed boot diagnostics (no storageUri) — also enables Serial Console
    diagnosticsProfile: {
      bootDiagnostics: { enabled: true }
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('VM resource ID')
output vmId string = vm.id

@description('VM name')
output vmName string = vm.name

@description('Primary NIC private IP address')
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('Public IP address (empty string if not attached)')
output publicIp string = attachPublicIp ? publicIp!.properties.ipAddress : ''
