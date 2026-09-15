// =============================================================================
// main.bicepparam — defaults for the ExpressRoute failover lab
// =============================================================================
// Deploy with:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file main.bicep \
//     --parameters main.bicepparam \
//     --parameters adminPassword='<password>'
//
// The test VMs have no public IP. Reach them with Serial Console:
//   az serial-console connect -g <rg> -n erfo-vm-<key>
// =============================================================================

using 'main.bicep'

param labPrefix = 'erfo'

param hubRoutingPreference = 'ASPath'

param hubs = [
  {
    key: 'wus2'
    region: 'westus2'
    hubAddressPrefix: '10.0.0.0/23'
    spokeAddressPrefix: '10.10.0.0/24'
    subnetPrefix: '10.10.0.0/27'
    circuit: {
      name: 'chicago'
      provider: 'Megaport'
      peeringLocation: 'Chicago'
      // The circuit resource already exists in North Central US and cannot be
      // moved. Its location is metadata only — a Standard-SKU circuit can
      // attach to any hub in the same geopolitical region (US), so the Chicago
      // edge still fronts the West US 2 hub.
      circuitLocation: 'northcentralus'
      bandwidthMbps: 50
      // AzurePrivatePeering is NOT declared here. The Megaport MCR creates it
      // and owns the peer ASN, VLAN and both /30 link subnets.
    }
  }
  {
    key: 'scus'
    region: 'southcentralus'
    hubAddressPrefix: '10.1.0.0/23'
    spokeAddressPrefix: '10.20.0.0/24'
    subnetPrefix: '10.20.0.0/27'
    circuit: {
      name: 'dallas'
      provider: 'Megaport'
      peeringLocation: 'Dallas'
      circuitLocation: 'southcentralus'
      bandwidthMbps: 50
      // AzurePrivatePeering is NOT declared here. The Megaport MCR creates it
      // and owns the peer ASN, VLAN and both /30 link subnets.
    }
  }
]

param erGatewayScaleUnits = 1

param adminUsername = 'azureuser'

// Supply at deploy time: --parameters adminPassword='<password>'
param adminPassword = ''

param sshPublicKey = ''

// Cost control: B1s + Standard HDD + nightly auto-shutdown. These VMs only
// emit ping/traceroute, so nothing bigger is warranted.
param vmSize = 'Standard_B1s'

param osDiskType = 'Standard_LRS'

param enableAutoShutdown = true

param autoShutdownTime = '2300'

param autoShutdownTimeZone = 'UTC'

param createRoleAssignment = true

param pollSeconds = 60

param waitTimeoutSeconds = 6600

param tags = {}
