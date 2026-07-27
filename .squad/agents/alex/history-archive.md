# Alex — History Summary

**Last Updated:** 2026-07-27  
**File Size:** 19.6 KB (archived summary from 22 KB session history; earlier sessions preserved in decisions.md)

## Core Identity

- **Role:** Network Engineer  
- **Stack:** Azure CLI, Bicep, ARM JSON, Bash/PowerShell
- **Domain:** Azure Networking (Virtual WAN, custom NVAs, Routing Intent, ER/VPN)
- **Key Labs Authored:** svh-dynamic-er-ri, nva-spoke-internet

---

## Key Learnings Summary

### Virtual WAN & Routing

1. **Routing Intent**: Requires Azure Firewall in `Succeeded` state, incompatible with custom route tables, uses canonical destinations (`PrivateTraffic`, `Internet`), requires `enableInternetSecurity: true` on connections for internet modes.

2. **Custom NVA Routing** (nva-spoke-internet pattern): Two operations needed—
   - DMZ connection static route: `az network vhub connection create --route-name ... --address-prefixes 0.0.0.0/0 --next-hop <ILB-IP>`
   - Hub defaultRouteTable static route: `az network vhub route-table route add --destination-type CIDR --next-hop-type ResourceID`
   - **Do NOT set `--internet-security`** with custom static routes

3. **VNet Connections**: Must be created post-deploy (not in Bicep) to avoid routingState timing issues. Always poll `routingState == Provisioned` before connections.

### On-Prem BGP-over-IPsec

- **strongSwan**: IKEv2, one `conn` per hub GW instance (active/active=2), route-based (0.0.0.0/0), `auto=start`, `dpdaction=restart`
- **FRR**: `router bgp 65001`, two neighbors at hub BGP peer IPs, `ebgp-multihop 5`
- **PSK pattern**: Create connection first, then `vpn-site-link-conn sharedkey update` separately
- **Hub queries**: `ipConfigurations[0].publicIpAddress` and `bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]`

### Bicep & PowerShell Patterns

- **Outputs contract**: Locked names consumed by deploy.sh (16 outputs in nva-spoke-internet)
- **Non-interactive PowerShell**: Use `$env:ADMIN_PASSWORD` fallback + `$PSBoundParameters.ContainsKey()` for switch params
- **Windows empty-string bug**: `--public-ip-address ""` is silently dropped; pre-create NIC instead
- **Line endings**: All .sh files on Windows need CRLF→LF conversion before commit

### Load Balancer & Monitoring

- **Standard LB metrics** (public): UsedSNATPorts, AllocatedSNATPorts, SnatConnectionCount, ByteCount, PacketCount, DipAvailability, VipAvailability
- **VNet flow logs** (not NSG): NSG flow logs retire Sept 2027; VNet flow logs are future-proofed
- **Separate monitoring script**: enable-monitoring is optional, cost-transparent, keeps validate-flow read-only

---

## Current Lab Status

**nva-spoke-internet** (2026-07-27):
- Live deployment validated: PASS 12 / FAIL 0 / WARN 2
- Full infrastructure committed (Bicep, scripts, cloud-init, diagram)
- EXPECTED-RESULTS.md is canonical baseline
- Validation scripts (validate-flow, enable-monitoring) in place
- Ready for branch push + PR

---

## Decision References

See `.squad/decisions.md` for:
- Bicep output contract (nva-spoke-internet)
- vWAN NVA 0/0 routing wiring
- Lab documentation & diagram relocation
- Bicep lab validation findings
- Non-interactive deploy.ps1 patterns
- Flow validation & monitoring enablement (4 new decisions on 2026-07-27)

