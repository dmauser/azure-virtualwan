// =============================================================================
// Module: ubuntu-vm.bicep
// Purpose: Deploy one small Ubuntu VM into a spoke subnet for connectivity tests.
// Notes:   - Username/password authentication (password stored in Key Vault);
//            SSH key optional/unused by default.
//          - Boot diagnostics use an Azure-MANAGED storage account (no storageUri),
//            which also enables Serial Console access.
//          - cloud-init installs basic troubleshooting tools.
// =============================================================================

@description('Name of the virtual machine.')
param vmName string

@description('Azure region (must match the spoke region).')
param location string

@description('Resource ID of the subnet the VM NIC attaches to.')
param subnetId string

@description('Admin username for the VM.')
param adminUsername string

@description('SSH public key (OpenSSH format). Optional — unused by default. Leave empty to use password-only auth.')
param sshPublicKey string = ''

@description('Admin password (secure). Stored in Key Vault and used for Serial Console login.')
@secure()
param adminPassword string

@description('VM size. Use the lowest-cost GA size suitable for connectivity tests.')
param vmSize string = 'Standard_B2s'

@description('Resource tags.')
param tags object

@description('Attach a public IP to the VM. Default false (cost + security).')
param attachPublicIp bool = false

// cloud-init: install common network troubleshooting tooling on first boot.
var cloudInit = '''
#cloud-config
package_update: true
packages:
  - traceroute
  - tcpdump
  - net-tools
  - dnsutils
  - curl
  - iputils-ping
'''

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (attachPublicIp) {
  name: 'pip-${vmName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: attachPublicIp ? {
            id: publicIp.id
          } : null
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(cloudInit)
      linuxConfiguration: empty(sshPublicKey) ? {
          // Password auth enabled — Serial Console and password SSH work.
          disablePasswordAuthentication: false
        } : {
          disablePasswordAuthentication: false
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    // Managed boot diagnostics (no storageUri) — also enables Serial Console.
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

@description('Resource ID of the VM.')
output vmId string = vm.id

@description('Name of the VM.')
output vmName string = vm.name

@description('Private IP of the VM NIC.')
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
