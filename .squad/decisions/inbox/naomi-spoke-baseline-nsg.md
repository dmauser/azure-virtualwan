# Decision: Spoke Workload Subnets Now Carry Baseline NSG

**Author:** Naomi (Infra Dev)
**Date:** 2026-07-28
**Status:** Applied — live in DMAUSER-FDPO (westus3, rg-nva-spoke-internet-pa)

---

## Decision

The prior "spokes are NSG-less by design" decision is **intentionally superseded for spoke workload subnets only**. Both `snet-workload` subnets on vnet-spoke1 and vnet-spoke2 now carry a dedicated baseline NSG:

| Subnet | NSG |
|---|---|
| vnet-spoke1 / snet-workload | `nsg-vnet-spoke1-workload` |
| vnet-spoke2 / snet-workload | `nsg-vnet-spoke2-workload` |

DMZ, PA management/untrust/trust, and on-prem/gateway subnets are **untouched** — they remain NSG-less or use their existing NSG (`nsg-dmz`) as before.

---

## NSG Rule Composition

### Custom rules (explicit, in Bicep)
| Priority | Name | Direction | Protocol | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| 100 | Allow-SSH-Inbound | Inbound | TCP | VirtualNetwork | VirtualNetwork | 22 | Allow |

`VirtualNetwork` in a VWAN spoke context includes hub + all peered spokes — so this covers SSH from hub/on-prem/other spoke without explicit IP targeting.

### Platform defaults (immutable, always present — [Microsoft Learn](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules))
| Priority | Name | Direction | Action |
|---|---|---|---|
| 65000 | AllowVNetInBound | Inbound | Allow |
| 65001 | AllowAzureLoadBalancerInBound | Inbound | Allow |
| 65500 | DenyAllInBound | Inbound | Deny |
| 65000 | AllowVnetOutBound | Outbound | Allow |
| 65001 | AllowInternetOutBound | Outbound | Allow |
| 65500 | DenyAllOutBound | Outbound | Deny |

No custom Deny rules were added. Outbound internet (`AllowInternetOutBound` 65001) remains unblocked — required for the spoke → PA ILB (10.0.0.68) → Internet breakout flow.

---

## IaC Change

**File:** `nva-spoke-internet-paloalto/bicep/modules/spoke.bicep`

Added `Microsoft.Network/networkSecurityGroups@2023-11-01` resource named `nsg-${vnetName}-workload` before the VNet resource, and added `networkSecurityGroup: { id: nsg.id }` to the `snet-workload` subnet properties alongside the existing `routeTable`. Because spoke.bicep is instantiated twice from main.bicep (for spoke1 and spoke2), this covers both spokes automatically. main.bicep required no changes.

---

## Validate-Flow Impact

`validate-flow.ps1` check **[2g] IP-flow-verify** was previously SKIP (no NSG on the subnet). Now that NSG is associated, it will **RUN** and is expected to **PASS** (Allow-SSH-Inbound covers inbound TCP/22 from VirtualNetwork; outbound internet is permitted by platform AllowInternetOutBound).

---

## Live Verification (2026-07-28)

```
az network vnet subnet show -g rg-nva-spoke-internet-pa --vnet-name vnet-spoke1 -n snet-workload --query "networkSecurityGroup.id" -o tsv
→ /subscriptions/.../Microsoft.Network/networkSecurityGroups/nsg-vnet-spoke1-workload  ✔

az network vnet subnet show -g rg-nva-spoke-internet-pa --vnet-name vnet-spoke2 -n snet-workload --query "networkSecurityGroup.id" -o tsv
→ /subscriptions/.../Microsoft.Network/networkSecurityGroups/nsg-vnet-spoke2-workload  ✔

az vm run-command invoke -n vm-spoke1 ... "curl -s -m 10 ifconfig.me"
→ 20.163.105.237 (Palo Alto Public LB SNAT IP — internet breakout intact)  ✔
```
