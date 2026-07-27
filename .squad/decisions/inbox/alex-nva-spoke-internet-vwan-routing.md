# Decision: vWAN NVA 0/0 Routing Wiring for nva-spoke-internet

**Date:** 2026-07-24  
**Author:** Alex (Network Engineer)  
**Status:** Adopted

## Context

The `nva-spoke-internet` lab uses a custom NVA pair (not Azure Firewall) to inspect and SNAT internet-bound traffic from Spoke1 and Spoke2.  We need spoke VMs to use 0.0.0.0/0 → NVA → SNAT via Public LB PIP.  Routing Intent is NOT used (requires Azure Firewall as the next-hop; custom NVAs are not supported as RI targets).

## Decision

Use **two custom static route entries** (no Routing Intent, no custom route table — use defaultRouteTable):

### 1. DMZ connection static route (set at connection create time)
```bash
az network vhub connection create -n conn-dmz ... \
  --route-name "default-via-ilb" \
  --address-prefixes "0.0.0.0/0" \
  --next-hop "10.0.0.68"
```
This instructs the hub: for 0/0 traffic resolved to the DMZ connection, forward to ILB frontend 10.0.0.68 (HA-ports backend = both NVAs).

### 2. defaultRouteTable static route (added after connection is Succeeded)
```bash
CONN_DMZ_ID=$(az network vhub connection show -g $RG --vhub-name $HUB -n conn-dmz --query id -o tsv)
az network vhub route-table route add \
  -g $RG --vhub-name $HUB --name defaultRouteTable \
  --route-name "to-internet" \
  --destination-type CIDR --destinations "0.0.0.0/0" \
  --next-hop-type ResourceID --next-hop "$CONN_DMZ_ID"
```
This causes Spoke1/Spoke2 (associated to defaultRouteTable) to learn 0.0.0.0/0 → conn-dmz.

### Net result
Spoke1/Spoke2 effective routes: `0.0.0.0/0 → conn-dmz → ILB 10.0.0.68 → NVA (active/active) → SNAT → Public LB PIP`

## Alternatives Rejected

| Option | Why rejected |
|--------|-------------|
| Routing Intent (privateOnly/internetOnly/both) | Requires Azure Firewall as the next-hop; not compatible with custom NVA |
| Custom hub route table | Not needed — defaultRouteTable is used; custom tables add management overhead with no benefit for a single-spoke-group lab |
| `--internet-security true` on spoke connections | Only needed for Routing Intent internet modes; causes unintended behavior in custom static route setups |
| Static 0/0 advertised from NVA via BGP | Not applicable — NVAs are in a spoke (DMZ VNet), not on-hub NVAs; BGP advertisement would require a BGP peering setup not present in this lab |

## Impact

- `deploy.sh` Phase 9: creates conn-dmz with `--route-name/--address-prefixes/--next-hop`
- `deploy.sh` Phase 10+11: adds defaultRouteTable route via `az network vhub route-table route add`
- `deploy.ps1`: identical logic using PowerShell `az` calls
- Naomi's Bicep: no change needed for this routing mechanism; VNet connections are NOT created in Bicep (timing issues with hub routingState)

## Notes on az CLI command shapes (version sensitivity)

- `az network vhub connection create --route-name --address-prefixes --next-hop` — connection-level static route; available in az-cli ≥ 2.40
- `az network vhub route-table route add --destination-type CIDR --destinations --next-hop-type ResourceID --next-hop` — adds a route to an existing route table; available in az-cli ≥ 2.40
- `az network vhub routing-intent` uses `--vhub` (NOT `--vhub-name`) — different from all `az network vhub connection` commands which use `--vhub-name`; do not mix up
