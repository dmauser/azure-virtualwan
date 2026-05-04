metadata description = 'Deploys an OPNsense NVA VM using FreeBSD 14.2 marketplace image. NOTE: OPNsense cannot be fully automated via cloud-init (FreeBSD limitation) — manual post-deploy configuration is required via the web UI.'

@description('VM name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Subnet resource ID for the WAN (public-facing) NIC')
param wanSubnetId string

@description('Subnet resource ID for the LAN (private) NIC')
param lanSubnetId string

@description('Static private IP for the WAN NIC')
param wanPrivateIp string

@description('Static private IP for the LAN NIC')
param lanPrivateIp string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Admin username')
param adminUsername string

@description('Admin password')
@secure()
param adminPassword string

@description('Tags')
param tags object = {}

// === WAN NIC (public-facing, IP forwarding enabled) ===
resource wanNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-wan-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig-wan'
        properties: {
          subnet: { id: wanSubnetId }
          privateIPAddress: wanPrivateIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
  }
}

// === LAN NIC (private, IP forwarding enabled) ===
resource lanNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-lan-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig-lan'
        properties: {
          subnet: { id: lanSubnetId }
          privateIPAddress: lanPrivateIp
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
  }
}

// === OPNsense VM (FreeBSD marketplace image) ===
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  plan: {
    name: '14_2-release-amd64-gen2'
    publisher: 'thefreebsdfoundation'
    product: 'freebsd-14_2'
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: take(name, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'thefreebsdfoundation'
        offer: 'freebsd-14_2'
        sku: '14_2-release-amd64-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: wanNic.id
          properties: { primary: true }
        }
        {
          id: lanNic.id
          properties: { primary: false }
        }
      ]
    }
  }
}

// === Outputs ===
output vmId string = vm.id
output wanNicId string = wanNic.id
output lanNicId string = lanNic.id
output lanPrivateIp string = lanPrivateIp
