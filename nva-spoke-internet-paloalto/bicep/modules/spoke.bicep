// =============================================================================
// Module: spoke.bicep
// Spoke VNet + workload subnet + Ubuntu workload VM + empty UDR
// Used twice from main.bicep: Spoke1 (10.1.0.0/24) and Spoke2 (10.2.0.0/24)
//
// The hub programs 0/0 routing to the DMZ NVA via VNet connection + hub
// route table — set up by Alex's deploy.sh AFTER hub routingState=Provisioned.
// The UDR is created and associated here so deploy.sh has a handle for any
// spoke-level route overrides without re-running Bicep.
// =============================================================================

@description('Spoke VNet name (e.g. vnet-spoke1)')
param vnetName string

@description('Spoke VNet address prefix (e.g. 10.1.0.0/24)')
param vnetAddressPrefix string

@description('Workload subnet prefix (e.g. 10.1.0.0/26)')
param workloadSubnetPrefix string

@description('Workload VM name (e.g. vm-spoke1)')
param vmName string

@description('Azure region')
param location string

@description('Admin username')
param adminUsername string

@description('Admin password (secure)')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Resource tags')
param tags object = {}

// Cloud-init: workload tools
var workloadCloudInit = loadFileAsBase64('../cloud-init/workload.yaml')

// ── NSG (baseline / default-rules) ───────────────────────────────────────────
// Mirrors Azure platform default rules (immutable, always present — see
// https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules):
//   Inbound : AllowVNetInBound (65000), AllowAzureLoadBalancerInBound (65001), DenyAllInbound (65500)
//   Outbound: AllowVnetOutBound (65000), AllowInternetOutBound (65001), DenyAllOutBound (65500)
// Custom rule added here (no Deny rules — outbound Internet must remain open for spoke → PA ILB → Internet):
//   Inbound 100 — Allow SSH (TCP/22) from VirtualNetwork (includes hub + peered spokes in VWAN context)
// Applied at subnet scope on snet-workload only; DMZ/PA/GW subnets are untouched.
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${vnetName}-workload'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '22'
          description: 'Allow SSH from hub / on-prem / other spoke via VirtualNetwork service tag'
        }
      }
    ]
  }
}

// ── UDR (empty — placeholder for deploy.sh or manual spoke-level routes) ──────
resource udr 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'udr-${vnetName}-workload'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: []
  }
}

// ── VNet ──────────────────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: 'snet-workload'
        properties: {
          addressPrefix: workloadSubnetPrefix
          routeTable: { id: udr.id }
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ── Workload VM ───────────────────────────────────────────────────────────────
module workloadVm 'vm.bicep' = {
  name: '${vmName}-deploy'
  params: {
    vmName: vmName
    location: location
    subnetId: vnet.properties.subnets[0].id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    customData: workloadCloudInit
    tags: tags
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
@description('Spoke VNet resource ID')
output vnetId string = vnet.id

@description('Spoke VNet name')
output vnetName string = vnet.name

@description('Workload subnet resource ID')
output workloadSubnetId string = vnet.properties.subnets[0].id

@description('Workload VM name')
output vmName string = workloadVm.outputs.vmName

@description('Workload VM private IP')
output vmPrivateIp string = workloadVm.outputs.privateIp
