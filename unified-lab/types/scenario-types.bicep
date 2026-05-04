// Scenario configuration types for the unified lab builder

@export()
type hubConfigType = {
  @description('Hub name suffix (e.g., hub1, hub2)')
  name: string

  @description('Azure region for this hub')
  location: string

  @description('Address prefix for the virtual hub (e.g., 10.0.0.0/23)')
  addressPrefix: string

  @description('Deploy S2S VPN Gateway in this hub')
  deployVpnGateway: bool?

  @description('Deploy ExpressRoute Gateway in this hub')
  deployErGateway: bool?

  @description('Deploy Azure Firewall (Secured Virtual Hub)')
  deployFirewall: bool?

  @description('Azure Firewall SKU (Basic, Standard, Premium)')
  firewallSku: ('Basic' | 'Standard' | 'Premium')?

  @description('Enable Routing Intent')
  enableRoutingIntent: bool?

  @description('Routing Intent mode')
  routingIntentMode: ('InternetOnly' | 'PrivateOnly' | 'InternetAndPrivate')?
}

@export()
type spokeConfigType = {
  @description('Spoke VNet name suffix')
  name: string

  @description('Azure region')
  location: string

  @description('VNet address space')
  addressPrefix: string

  @description('Subnet address prefix')
  subnetPrefix: string

  @description('Associated hub name (must match a hub name)')
  associatedHub: string

  @description('Deploy a test VM in this spoke')
  deployVm: bool?

  @description('Custom route table label for isolation scenarios')
  routeTableLabel: string?
}

@export()
type branchConfigType = {
  @description('Branch name suffix')
  name: string

  @description('Azure region for simulated branch')
  location: string

  @description('Branch VNet address space')
  addressPrefix: string

  @description('Branch gateway subnet prefix')
  gatewaySubnetPrefix: string

  @description('BGP ASN for branch VPN gateway')
  bgpAsn: int?

  @description('Connected hub name')
  connectedHub: string

  @description('Pre-shared key for VPN')
  @secure()
  psk: string?
}

@export()
type nvaConfigType = {
  @description('NVA type')
  nvaType: ('linux-frr' | 'opnsense')?

  @description('Deploy in hub or spoke')
  placement: ('spoke' | 'hub')?

  @description('NVA VNet address prefix')
  addressPrefix: string?

  @description('NVA private IP')
  privateIp: string?

  @description('BGP ASN for NVA')
  bgpAsn: int?

  @description('Enable BGP peering with virtual hub')
  enableHubBgpPeering: bool?

  @description('Deploy Internal Load Balancer for HA')
  deployIlb: bool?
}
