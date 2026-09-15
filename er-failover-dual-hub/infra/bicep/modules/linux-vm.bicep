// =============================================================================
// Module: linux-vm.bicep
// Purpose: One small Ubuntu VM per spoke, used as the failover test endpoint.
// Notes:   - cloud-init installs the tools the failover tests need
//            (mtr, traceroute, tcpdump, hping3, iperf3).
//          - The VMs have NO public IP. Access is via Serial Console, which
//            managed boot diagnostics enable below. That keeps the VM reachable
//            even when you deliberately break the private data path, and it is
//            the only access method that survives an ExpressRoute failure.
//          - Cost: these VMs only emit ping/traceroute, so they default to the
//            smallest practical burstable size, a Standard HDD OS disk, and a
//            nightly auto-shutdown schedule. Compute stops billing while the
//            VM is deallocated; the OS disk keeps billing (~$1.50/month).
// =============================================================================

@description('Name of the virtual machine.')
param vmName string

@description('Azure region (must match the spoke region).')
param location string

@description('Resource ID of the subnet the NIC attaches to.')
param subnetId string

@description('Admin username for the VM.')
param adminUsername string

@description('Admin password (secure). Also used for Serial Console login.')
@secure()
param adminPassword string

@description('SSH public key (OpenSSH format). Optional; password auth stays enabled either way.')
param sshPublicKey string = ''

@description('VM size. Keep small — these VMs only generate ping/traceroute traffic. Standard_B1s is the cheapest size that still runs Ubuntu 22.04 comfortably.')
param vmSize string = 'Standard_B1s'

@description('OS disk SKU. Standard_LRS (HDD) is the cheapest option and is plenty for a test endpoint.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
param osDiskType string = 'Standard_LRS'

@description('Create a nightly auto-shutdown schedule so an idle lab stops billing compute.')
param enableAutoShutdown bool = true

@description('Auto-shutdown time in HHmm (24h) format.')
param autoShutdownTime string = '2300'

@description('Time zone for the auto-shutdown schedule.')
param autoShutdownTimeZone string = 'UTC'

@description('Resource tags.')
param tags object

var cloudInit = '''
#cloud-config
package_update: true
packages:
  - traceroute
  - mtr-tiny
  - tcpdump
  - net-tools
  - dnsutils
  - curl
  - iputils-ping
  - hping3
  - iperf3
  - jq
'''

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
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: osDiskType
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
    diagnosticsProfile: {
      // Managed boot diagnostics (no storageUri) are what make Serial Console
      // work. A customer storage account is deliberately avoided here because
      // it would require shared-key access, which many subscriptions block.
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// Nightly auto-shutdown. Deallocating stops compute billing; restart with
// `az vm start` (or `az vm deallocate` early) whenever you resume testing.
resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (enableAutoShutdown) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
      timeInMinutes: 30
    }
    targetResourceId: vm.id
  }
}

@description('Resource ID of the VM.')
output vmId string = vm.id
@description('Name of the VM.')
output vmName string = vm.name

@description('Private IP of the VM NIC.')
output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
