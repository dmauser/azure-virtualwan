// =============================================================================
// main.bicep — ExpressRoute failover lab across two Virtual WAN hubs
// =============================================================================
// Scope: resource group
//
// What this deploys
//   1 Virtual WAN (Standard, branch-to-branch enabled)
//   2 Virtual Hubs                 — West US 2 and South Central US
//       - hubRoutingPreference = ASPath on both
//   2 Spoke VNets + 2 Linux VMs    — one per hub, the failover test endpoints
//   2 ExpressRoute Gateways        — one per hub
//   2 ExpressRoute circuits        — Chicago (-> West US 2 hub)
//                                    Dallas  (-> South Central US hub)
//   2 wait-for-provider pollers    — gate the hub connections
//   2 ExpressRoute connections     — created ONLY after the provider provisions
//
// The deployment flow
//   Circuits are created immediately but are unusable until the connectivity
//   provider (Megaport by default) provisions them against the service key.
//   That handoff is manual and out-of-band, so the deployment parks on a
//   deploymentScripts poller per circuit and resumes automatically once each
//   circuit reports serviceProviderProvisioningState = "Provisioned".
//
//   Run the deployment, collect the two service keys from the outputs, order the
//   VXCs in Megaport, and leave the deployment running. It picks up from there.
//
// Why ASPath
//   With hubRoutingPreference = ASPath the hub selects on shortest BGP AS path
//   before it considers route source. Each hub therefore prefers its own local
//   circuit, and when that circuit drops it falls back to the remote hub's
//   circuit over hub-to-hub transit — which is exactly the failover this lab
//   exists to validate. allowBranchToBranchTraffic on the vWAN is what makes
//   that re-advertisement possible.
// =============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

@description('ExpressRoute circuit definition attached to a hub.')
type circuitConfig = {
  @description('Short circuit name, e.g. "chicago".')
  name: string

  @description('Connectivity provider exactly as Azure spells it, e.g. "Megaport".')
  provider: string

  @description('ExpressRoute peering / edge location, e.g. "Chicago".')
  peeringLocation: string

  @description('Azure region the circuit resource lives in.')
  circuitLocation: string

  @description('Bandwidth in Mbps.')
  bandwidthMbps: int
}

@description('One Virtual Hub with its spoke and its local ExpressRoute circuit.')
type hubConfig = {
  @description('Short key used in resource names, e.g. "wus2".')
  key: string

  @description('Azure region for the hub, spoke, gateway and VM.')
  region: string

  @description('Hub address prefix (/23 recommended).')
  hubAddressPrefix: string

  @description('Spoke VNet address prefix.')
  spokeAddressPrefix: string

  @description('VM subnet prefix inside the spoke.')
  subnetPrefix: string

  @description('The ExpressRoute circuit terminated on THIS hub.')
  circuit: circuitConfig
}

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Prefix applied to every resource name.')
@minLength(2)
@maxLength(10)
param labPrefix string = 'erfo'

@description('Hub definitions. Exactly two hubs are expected for this failover lab.')
@minLength(2)
@maxLength(2)
param hubs hubConfig[]

@description('Hub route preference. ASPath is what this lab validates.')
@allowed([
  'ASPath'
  'ExpressRoute'
  'VpnGateway'
])
param hubRoutingPreference string = 'ASPath'

@description('ExpressRoute Gateway scale units per hub. 1 = 2 Gbps.')
@minValue(1)
@maxValue(10)
param erGatewayScaleUnits int = 1

@description('Admin username for both Linux VMs.')
param adminUsername string = 'azureuser'

@description('Admin password for both Linux VMs. This is also the Serial Console login, which is the only interactive access path — the VMs have no public IP.')
@secure()
param adminPassword string

@description('Optional SSH public key (OpenSSH format) added to both VMs. Only usable from private space (spoke-to-spoke or across ExpressRoute); there is no inbound path from the internet.')
param sshPublicKey string = ''

@description('VM size for both test VMs. Standard_B1s is the cheapest size that runs Ubuntu 22.04 comfortably and is more than enough for ping/traceroute failover tests.')
param vmSize string = 'Standard_B1s'

@description('OS disk SKU for both test VMs. Standard_LRS (HDD) is the cheapest option.')
@allowed([
  'Standard_LRS'
  'StandardSSD_LRS'
  'Premium_LRS'
])
param osDiskType string = 'Standard_LRS'

@description('Create a nightly auto-shutdown schedule on both test VMs so an idle lab stops billing compute.')
param enableAutoShutdown bool = true

@description('Auto-shutdown time in HHmm (24h) format.')
param autoShutdownTime string = '2300'

@description('Time zone for the auto-shutdown schedule.')
param autoShutdownTimeZone string = 'UTC'

@description('Region for the Virtual WAN resource itself. The vWAN is a global resource, so this is metadata only; its hubs are placed independently via hubs[].region. Defaults to the resource group location. An existing vWAN cannot be relocated, so keep this stable across redeployments.')
param vwanLocation string = resourceGroup().location

@description('Create/update the ExpressRoute circuit resources. Set false on redeployments once the provider has provisioned the circuits: re-PUTting a circuit whose AzurePrivatePeering is bound to a live provider link fails with "The specified bgp peering is in use". The circuits are still read and consumed, just not rewritten.')
param manageCircuits bool = true

@description('Gate the ExpressRoute connections behind a deploymentScripts poller that waits for the circuit to reach Provisioned. Set false when the circuits are already Provisioned, or when subscription policy blocks deployment scripts (they require a storage account with shared-key auth).')
param waitForProvider bool = true

@description('Create the Reader role assignment for the poller identity. Set false if you lack Owner / User Access Administrator.')
param createRoleAssignment bool = true

@description('Seconds between provider-provisioning polls.')
@minValue(15)
@maxValue(600)
param pollSeconds int = 60

@description('Hard deadline in seconds for each provider wait. Default 110 minutes.')
@minValue(60)
@maxValue(82800)
param waitTimeoutSeconds int = 6600

@description('Extra tags merged onto every resource.')
param tags object = {}

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var allTags = union(
  {
    lab: 'er-failover-dual-hub'
    purpose: 'ExpressRoute failover validation across two Virtual WAN hubs'
    hubRoutingPreference: hubRoutingPreference
  },
  tags
)

var vwanName = '${labPrefix}-vwan'
var identityName = '${labPrefix}-erwait-identity'
var identityLocation = hubs[0].region

// ---------------------------------------------------------------------------
// 1. Virtual WAN
// ---------------------------------------------------------------------------

module vwan 'modules/vwan.bicep' = {
  name: 'vwan'
  params: {
    vwanName: vwanName
    location: vwanLocation
    tags: allTags
  }
}

// ---------------------------------------------------------------------------
// 2. Virtual Hubs
// ---------------------------------------------------------------------------

module vhubs 'modules/vhub.bicep' = [for hub in hubs: {
  name: 'vhub-${hub.key}'
  params: {
    hubName: '${labPrefix}-hub-${hub.key}'
    location: hub.region
    hubAddressPrefix: hub.hubAddressPrefix
    vwanId: vwan.outputs.vwanId
    hubRoutingPreference: hubRoutingPreference
    tags: allTags
  }
}]

// ---------------------------------------------------------------------------
// 3. Spoke VNets (each connected to its local hub)
// ---------------------------------------------------------------------------

module spokes 'modules/spoke-vnet.bicep' = [for (hub, i) in hubs: {
  name: 'spoke-${hub.key}'
  params: {
    spokeName: '${labPrefix}-spoke-${hub.key}'
    location: hub.region
    spokeAddressPrefix: hub.spokeAddressPrefix
    subnetPrefix: hub.subnetPrefix
    hubId: vhubs[i].outputs.hubId
    tags: allTags
  }
}]

// ---------------------------------------------------------------------------
// 4. Test VMs
// ---------------------------------------------------------------------------

module vms 'modules/linux-vm.bicep' = [for (hub, i) in hubs: {
  name: 'vm-${hub.key}'
  params: {
    vmName: '${labPrefix}-vm-${hub.key}'
    location: hub.region
    subnetId: spokes[i].outputs.subnetId
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    osDiskType: osDiskType
    enableAutoShutdown: enableAutoShutdown
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    tags: allTags
  }
}]

// ---------------------------------------------------------------------------
// 5. ExpressRoute Gateways (one per hub)
// ---------------------------------------------------------------------------

module erGateways 'modules/expressroute-gateway.bicep' = [for (hub, i) in hubs: {
  name: 'ergw-${hub.key}'
  params: {
    gatewayName: '${labPrefix}-hub-${hub.key}-ergw'
    location: hub.region
    hubId: vhubs[i].outputs.hubId
    scaleUnits: erGatewayScaleUnits
    tags: allTags
  }
}]

// ---------------------------------------------------------------------------
// 6. ExpressRoute circuits (created in NotProvisioned state)
// ---------------------------------------------------------------------------

module erCircuits 'modules/expressroute-circuit.bicep' = [for hub in hubs: if (manageCircuits) {
  name: 'ercircuit-${hub.circuit.name}'
  params: {
    circuitName: '${labPrefix}-er-${hub.circuit.name}'
    location: hub.circuit.circuitLocation
    provider: hub.circuit.provider
    peeringLocation: hub.circuit.peeringLocation
    bandwidthMbps: hub.circuit.bandwidthMbps
    tags: allTags
  }
}]

// Everything downstream reads the circuit through this indirection instead of
// the module above, so the lab still works when manageCircuits is false.
module erCircuitInfo 'modules/er-circuit-info.bicep' = [for (hub, i) in hubs: {
  name: 'ercircuit-info-${hub.circuit.name}'
  params: {
    circuitName: '${labPrefix}-er-${hub.circuit.name}'
  }
  dependsOn: [
    erCircuits[i]
  ]
}]

// ---------------------------------------------------------------------------
// 7. Identity for the provider-provisioning pollers
// ---------------------------------------------------------------------------

module scriptIdentity 'modules/script-identity.bicep' = if (waitForProvider) {
  name: 'script-identity'
  params: {
    identityName: identityName
    location: identityLocation
    createRoleAssignment: createRoleAssignment
    tags: allTags
  }
}

// ---------------------------------------------------------------------------
// 8. Wait for the connectivity provider
// ---------------------------------------------------------------------------
// This is the gate the whole lab hinges on. Nothing downstream of it is
// attempted until the circuit reports Provisioned.
//
// Skipped entirely when waitForProvider is false. deploymentScripts need a
// storage account that permits shared-key auth, so a subscription policy
// enforcing allowSharedKeyAccess=false makes this mechanism unusable.

module erWaits 'modules/er-wait.bicep' = [for (hub, i) in hubs: if (waitForProvider) {
  name: 'erwait-${hub.circuit.name}'
  params: {
    waitName: '${labPrefix}-erwait-${hub.circuit.name}'
    location: hub.region
    circuitId: erCircuitInfo[i].outputs.circuitId
    identityId: scriptIdentity!.outputs.identityId
    // The connectivity provider (Megaport MCR) owns AzurePrivatePeering, so the
    // poller must wait for the peering to appear, not just for "Provisioned".
    requirePrivatePeering: true
    pollSeconds: pollSeconds
    waitTimeoutSeconds: waitTimeoutSeconds
    tags: allTags
  }
}]

// ---------------------------------------------------------------------------
// 9. Azure Private Peering — NOT managed here
// ---------------------------------------------------------------------------
// AzurePrivatePeering is created and owned by the connectivity provider.
// The Megaport MCR pushes the peering (peer ASN, VLAN and the two /30 link
// subnets) onto the circuit when the ExpressRoute VXC is provisioned, so this
// template must never write it — doing so overwrites Megaport's addressing and
// tears down the live BGP sessions.
//
// er-wait.bicep blocks until the provider-created peering appears, and
// er-circuit-info.bicep reads its resource ID for the connection below.

// ---------------------------------------------------------------------------
// 10. ExpressRoute connections — circuit to its LOCAL hub
// ---------------------------------------------------------------------------
// Chicago -> West US 2 hub, Dallas -> South Central US hub.
// Failover between them is exercised through hub-to-hub transit, not by
// cross-connecting the circuits.

module erConnections 'modules/er-connection.bicep' = [for (hub, i) in hubs: {
  name: 'erconn-${hub.circuit.name}'
  params: {
    gatewayName: erGateways[i].outputs.gatewayName
    connectionName: '${labPrefix}-erconn-${hub.circuit.name}'
    peeringId: erCircuitInfo[i].outputs.privatePeeringId
    defaultRouteTableId: vhubs[i].outputs.defaultRouteTableId
  }
  dependsOn: [
    erWaits[i]
  ]
}]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Name of the Virtual WAN.')
output vwanName string = vwan.outputs.vwanName

@description('Per-hub summary: hub, spoke, gateway, VM and circuit details.')
output hubSummary array = [for (hub, i) in hubs: {
  key: hub.key
  region: hub.region
  hubName: vhubs[i].outputs.hubName
  hubRoutingPreference: vhubs[i].outputs.hubRoutingPreference
  spokeName: spokes[i].outputs.vnetName
  vmName: vms[i].outputs.vmName
  vmPrivateIp: vms[i].outputs.privateIp
  erGatewayName: erGateways[i].outputs.gatewayName
  circuitName: erCircuitInfo[i].outputs.circuitName
  peeringLocation: hub.circuit.peeringLocation
  provider: hub.circuit.provider
  erConnectionName: erConnections[i].outputs.connectionName
}]

@description('Service keys to hand to the connectivity provider. Order the VXCs against these.')
output serviceKeys array = [for (hub, i) in hubs: {
  circuitName: erCircuitInfo[i].outputs.circuitName
  peeringLocation: hub.circuit.peeringLocation
  provider: hub.circuit.provider
  serviceKey: erCircuitInfo[i].outputs.serviceKey
}]

@description('Serial Console commands for the two test VMs. The VMs have no public IP, so this is the interactive access path. Log in as adminUsername with adminPassword.')
output serialConsoleCommands array = [for (hub, i) in hubs: 'az serial-console connect -g ${resourceGroup().name} -n ${vms[i].outputs.vmName}']
