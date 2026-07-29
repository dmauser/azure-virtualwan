# Bicep — NSG in a Shared Spoke Module

## Pattern

When a Bicep module is instantiated multiple times (e.g., once per spoke), add the NSG
**inside** the module rather than in the orchestrator. The parameterized name (`nsg-${vnetName}-workload`)
produces distinct resource names automatically on each instantiation.

## Dependency Order

Declare NSG **before** the VNet resource that references it. Bicep resolves `nsg.id` at compile time;
if NSG appears after VNet in source, the Bicep compiler errors with a cyclical dependency.

```bicep
// ── NSG (baseline / default-rules) ─────────────────────────────────────────
// Platform defaults (immutable — https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules):
//   Inbound : AllowVNetInBound (65000), AllowAzureLoadBalancerInBound (65001), DenyAllInbound (65500)
//   Outbound: AllowVnetOutBound (65000), AllowInternetOutBound (65001), DenyAllOutBound (65500)
// Custom rule: Allow SSH from VirtualNetwork (hub + peered spokes in VWAN context). No Deny rules
// added — outbound Internet must remain open for spoke → NVA → Internet breakout.
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

// ── VNet (NSG associated to snet-workload alongside routeTable) ─────────────
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
          networkSecurityGroup: { id: nsg.id }   // <-- add alongside existing routeTable
        }
      }
    ]
  }
}
```

## Surgical CLI Apply (when full re-deploy is risky)

When `az deployment group what-if` shows more than just the NSG creates + subnet associations
(e.g. live admin creds are unknown, or hub/NVA re-PUTs are present), apply surgically:

```powershell
# Apply isolation pattern (see az-cli-extension-isolation skill)
foreach ($spoke in @("vnet-spoke1", "vnet-spoke2")) {
    $nsgName = "nsg-$spoke-workload"
    az network nsg create -g $Rg -n $nsgName -l $Location --output none
    az network nsg rule create -g $Rg --nsg-name $nsgName -n Allow-SSH-Inbound `
        --priority 100 --direction Inbound --access Allow --protocol Tcp `
        --source-address-prefixes VirtualNetwork --source-port-ranges '*' `
        --destination-address-prefixes VirtualNetwork --destination-port-ranges 22 `
        --output none
    az network vnet subnet update -g $Rg --vnet-name $spoke -n snet-workload `
        --nsg $nsgName --output none
}
```

## Verify Live Association

```bash
az network vnet subnet show -g $RG --vnet-name vnet-spoke1 -n snet-workload \
    --query "networkSecurityGroup.id" -o tsv
# Expected: .../Microsoft.Network/networkSecurityGroups/nsg-vnet-spoke1-workload
```

## Lab Safety Rules

1. **Never add custom Deny rules** for a baseline NSG — the platform `DenyAllInBound` at 65500 handles it.
2. **Never block outbound Internet** — `AllowInternetOutBound` at 65001 is what allows spoke → NVA → Internet flows to work. Any custom deny at priority < 65001 would break the lab.
3. **VirtualNetwork service tag** in VWAN context covers hub + all connected VNets/spokes — no need for explicit IP prefixes.
4. **DMZ/PA/GW subnets** should not use this pattern — they have their own NSG requirements or are NSG-less by design.

## Validated Facts

- apiVersion `Microsoft.Network/networkSecurityGroups@2023-11-01`: valid per Microsoft Learn
- Default rules priorities (65000/65001/65500): validated at https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules
- `VirtualNetwork` service tag in VWAN context includes hub + peered VNets: by design (Azure platform behavior)
