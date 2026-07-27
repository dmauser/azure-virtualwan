// =============================================================================
// Module: palo-alto.bicep — 2× Palo Alto VM-Series (vmseries-flex, BYOL)
//
// NIC ordering — PA mgmt-interface-swap mode:
//   NIC index 0 (primary) → snet-mgmt    → PA eth0 (management)
//   NIC index 1           → snet-untrust → PA eth1 (untrust, internet-facing)
//   NIC index 2           → snet-trust   → PA eth2 (trust, hub-facing)
//
// mgmt-interface-swap: PA normally treats NIC index 1 as management.  With the
// op-command passed via customData, NIC index 0 becomes the management interface
// so the primary NIC (eligible for DHCP-assigned default gateway) handles OOB
// management traffic while eth1/eth2 carry dataplane traffic.
//
// Bootstrap: PAN-OS reads init-cfg.txt and bootstrap.xml from an Azure Files
// share on first boot.  The storage account name + access key are provided via
// the customData block (Azure Files bootstrap format).
// =============================================================================

@description('Azure region')
param location string

@description('snet-mgmt subnet ID — PA eth0 management NIC')
param snetMgmtId string

@description('snet-untrust subnet ID — PA eth1, Public LB backend')
param snetUntrustId string

@description('snet-trust subnet ID — PA eth2, ILB backend')
param snetTrustId string

@description('Public LB backend pool resource ID (untrust NICs join this)')
param publicLbBackendPoolId string

@description('ILB backend pool resource ID (trust NICs join this)')
param ilbBackendPoolId string

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('VM size — Standard_DS3_v2 recommended; fallbacks DS4_v2 / D3_v2 / D4_v2')
param vmSize string = 'Standard_DS3_v2'

@description('Attach a Standard static public IP to each management NIC (GUI + licensing access)')
param enableMgmtPublicIp bool = true

@description('Bootstrap storage account name')
param bootstrapStorageAccount string

@description('Bootstrap storage account access key')
@secure()
param bootstrapStorageKey string

@description('Azure Files share name containing PA bootstrap content')
param bootstrapFileShare string

@description('Directory path inside the share (empty = root; PA convention reads from config/ subfolder)')
param bootstrapShareDirectory string = ''

@description('Resource tags')
param tags object = {}

// ── Optional management public IPs (one per firewall) ────────────────────────
resource pipMgmt 'Microsoft.Network/publicIPAddresses@2023-11-01' = [for i in range(0, 2): if (enableMgmtPublicIp) {
  name: 'pip-pa-${i}-mgmt'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}]

// ── Management NICs — PRIMARY (index 0), maps to PA eth0 after mgmt-interface-swap ───
resource nicMgmt 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(0, 2): {
  name: 'nic-pa-${i}-mgmt'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: false
    ipConfigurations: [
      {
        name: 'ipconfig-mgmt'
        properties: {
          subnet: { id: snetMgmtId }
          privateIPAllocationMethod: 'Dynamic'
          // Non-null assertion (!) is required because pipMgmt is a conditional
          // resource loop — Bicep cannot prove the element is non-null (BCP318).
          publicIPAddress: enableMgmtPublicIp ? { id: pipMgmt[i]!.id } : null
        }
      }
    ]
  }
}]

// ── Untrust NICs — index 1, PA eth1, internet-facing, Public LB backend ──────
resource nicUntrust 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(0, 2): {
  name: 'nic-pa-${i}-untrust'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig-untrust'
        properties: {
          subnet: { id: snetUntrustId }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            { id: publicLbBackendPoolId }
          ]
        }
      }
    ]
  }
}]

// ── Trust NICs — index 2, PA eth2, hub-facing, ILB backend ──────────────────
resource nicTrust 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(0, 2): {
  name: 'nic-pa-${i}-trust'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig-trust'
        properties: {
          subnet: { id: snetTrustId }
          privateIPAllocationMethod: 'Dynamic'
          loadBalancerBackendAddressPools: [
            { id: ilbBackendPoolId }
          ]
        }
      }
    ]
  }
}]

// ── Palo Alto VM-Series firewalls ─────────────────────────────────────────────
resource pa 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, 2): {
  name: 'pa-fw-${i}'
  location: location
  tags: tags

  // Marketplace plan block is REQUIRED for BYOL VM-Series images.
  // Without it the deployment fails with a terms/plan acceptance error.
  plan: {
    name: 'byol'
    publisher: 'paloaltonetworks'
    product: 'vmseries-flex'
  }

  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }

    storageProfile: {
      imageReference: {
        publisher: 'paloaltonetworks'
        offer: 'vmseries-flex'
        sku: 'byol'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }

    osProfile: {
      computerName: 'pa-fw-${i}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      // Azure Files bootstrap block in PAN-OS native format.
      // @secure() param bootstrapStorageKey is interpolated directly inside this
      // resource property — Bicep allows @secure() params in resource bodies but
      // not in plain var/variable declarations.
      // The \n escape sequences produce real newlines in the decoded string that
      // PAN-OS parses on first boot from the customData blob.
      customData: base64('type=dhcp-client\nop-command-modes=mgmt-interface-swap\nstorage-account=${bootstrapStorageAccount}\naccess-key=${bootstrapStorageKey}\nfile-share=${bootstrapFileShare}\nshare-directory=${bootstrapShareDirectory}\n')
    }

    networkProfile: {
      networkInterfaces: [
        {
          // NIC index 0 = primary NIC = PA eth0 (management) after mgmt-interface-swap
          id: nicMgmt[i].id
          properties: { primary: true }
        }
        {
          // NIC index 1 = PA eth1 (untrust / internet-facing / Public LB backend)
          id: nicUntrust[i].id
          properties: { primary: false }
        }
        {
          // NIC index 2 = PA eth2 (trust / hub-facing / ILB backend; 0/0 NH = 10.0.0.68)
          id: nicTrust[i].id
          properties: { primary: false }
        }
      ]
    }

    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        // storageUri omitted → managed boot diagnostics, enables Serial Console
      }
    }
  }

  dependsOn: [
    nicMgmt[i]
    nicUntrust[i]
    nicTrust[i]
  ]
}]

// ── Outputs ───────────────────────────────────────────────────────────────────
// Hardcoded arrays are used instead of loop expressions to avoid Bicep
// limitations around outputting loop-scoped expressions at module boundary.

@description('Firewall VM names')
output paNames array = ['pa-fw-0', 'pa-fw-1']

@description('Trust NIC IDs (PA eth2, ILB backend members)')
output nicTrustIds array = [nicTrust[0].id, nicTrust[1].id]

@description('Untrust NIC IDs (PA eth1, Public LB backend members)')
output nicUntrustIds array = [nicUntrust[0].id, nicUntrust[1].id]

@description('Management NIC IDs (PA eth0, primary NICs)')
output nicMgmtIds array = [nicMgmt[0].id, nicMgmt[1].id]
