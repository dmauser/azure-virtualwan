metadata description = 'Deploys a spoke VNet with subnet, NSG, and optional test VM'

@description('Spoke VNet name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('VNet address space')
param addressPrefix string

@description('Default subnet prefix')
param subnetPrefix string

@description('Deploy a test VM')
param deployVm bool = false

@description('VM size (lab-grade)')
param vmSize string = 'Standard_B2s'

@description('Admin username for VM')
param adminUsername string = 'azureuser'

@description('Admin password for VM')
@secure()
param adminPassword string = ''

@description('Tags')
param tags object = {}

// === NSG ===
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${name}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// === VNet ===
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: subnetPrefix
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// === Test VM (optional) ===
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = if (deployVm) {
  name: '${name}-vm-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = if (deployVm) {
  name: '${name}-vm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: take('${name}-vm', 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
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
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: nic.id }]
    }
  }
}

// === Outputs ===
output vnetId string = vnet.id
output vnetName string = vnet.name
output subnetId string = vnet.properties.subnets[0].id
output vmPrivateIp string = deployVm ? nic.properties.ipConfigurations[0].properties.privateIPAddress : ''
