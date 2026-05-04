metadata description = 'Deploys a Linux NVA with IP forwarding and FRR (BGP) via cloud-init'

@description('NVA name')
param name string

@description('Azure region')
param location string = resourceGroup().location

@description('Subnet resource ID where NVA will be deployed')
param subnetId string

@description('Static private IP for the NVA')
param privateIpAddress string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Admin username')
param adminUsername string = 'azureuser'

@description('Admin password')
@secure()
param adminPassword string

@description('BGP ASN for FRR')
param bgpAsn int = 65001

@description('BGP neighbors (array of {ip, asn} objects)')
param bgpNeighbors array = []

@description('Enable IP forwarding on NIC')
param enableIpForwarding bool = true

@description('Tags')
param tags object = {}

// === Cloud-init script for FRR ===
var frrNeighborConfig = [for neighbor in bgpNeighbors: '  neighbor ${neighbor.ip} remote-as ${neighbor.asn}\n  neighbor ${neighbor.ip} soft-reconfiguration inbound\n  neighbor ${neighbor.ip} route-map ALLOW-ALL in\n  neighbor ${neighbor.ip} route-map ALLOW-ALL out']

var cloudInitScript = '''#!/bin/bash
# Enable IP forwarding
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# Install FRR
apt-get update
apt-get install -y frr frr-pythontools

# Enable BGP daemon
sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
sed -i 's/zebra=no/zebra=yes/' /etc/frr/daemons

# FRR configuration
cat > /etc/frr/frr.conf << 'EOF'
frr version 8.1
frr defaults traditional
hostname ${name}
!
router bgp ${bgpAsn}
 bgp router-id ${privateIpAddress}
 no bgp ebgp-requires-policy
${neighborsBlock}
!
route-map ALLOW-ALL permit 10
!
line vty
!
EOF

# Restart FRR
systemctl restart frr
systemctl enable frr
'''

var neighborsBlock = join(frrNeighborConfig, '\n')
var finalCloudInit = replace(replace(replace(cloudInitScript, '${name}', name), '${bgpAsn}', string(bgpAsn)), '${privateIpAddress}', privateIpAddress)

// === NIC with IP forwarding ===
resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: enableIpForwarding
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          privateIPAddress: privateIpAddress
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
  }
}

// === Linux VM ===
resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: take(name, 15)
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(finalCloudInit)
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
output vmId string = vm.id
output nicId string = nic.id
output privateIp string = privateIpAddress
output bgpAsn int = bgpAsn
