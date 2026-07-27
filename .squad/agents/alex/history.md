# Alex — History

**Last Updated:** 2026-07-27  
**Note:** Full session history archived to history-archive.md (19.6 KB).

## Core Identity

- **Role:** Network Engineer  
- **Stack:** Azure CLI, Bicep, ARM JSON, Bash/PowerShell
- **Domain:** Azure Networking (Virtual WAN, custom NVAs, Routing Intent, ER/VPN)
- **Key Labs Authored:** svh-dynamic-er-ri, nva-spoke-internet

---

## Key Learnings (Session: nva-spoke-internet)

### Virtual WAN Custom NVA Routing (no Routing Intent)

Two CLI operations required for spoke→NVA→internet traffic:

1. **DMZ connection static route** — `az network vhub connection create` with `--route-name`, `--address-prefixes "0.0.0.0/0"`, `--next-hop <ILB-IP>`
2. **Hub defaultRouteTable static route** — `az network vhub route-table route add --destination-type CIDR --destinations "0.0.0.0/0" --next-hop-type ResourceID --next-hop $CONN_DMZ_ID`

**Key distinction:** Do NOT set `--internet-security` true when using custom static routes (that flag is only for Routing Intent modes).

### VNet Connections Must Be Post-Deploy

VNet connections cannot be created in Bicep due to hub routingState timing issues. Always poll `routingState == Provisioned` before creating connections.

### On-Prem BGP-over-IPsec

- **strongSwan**: IKEv2, one `conn` per hub GW instance (active/active=2), route-based (0.0.0.0/0), `auto=start`, `dpdaction=restart`
- **FRR**: `router bgp 65001`, two neighbors, `ebgp-multihop 5` required (BGP peer not directly connected)
- **PSK pattern**: Create connection first, then `vpn-site-link-conn sharedkey update` separately
- **Hub queries**: `ipConfigurations[0].publicIpAddress` and `bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]`

### Bicep Output Contract (nva-spoke-internet)

Consumed outputs: location, vwanName, hubName, hubId, dmzVnetId, spoke1VnetId, spoke2VnetId, ilbFrontendIp, publicLbPublicIp, nvaNames, vpnGatewayName, onpremVnetId, onpremNvaPublicIp, onpremNvaPrivateIp, onpremNvaName, onpremVmName

Params TO Bicep: location, adminUsername, adminPassword, vmSize, deployOnPrem, onpremBgpAsn

Key constant: ILB frontend IP = **10.0.0.68** (in DMZ 10.0.0.0/24)

### Deploy.ps1 Fixes (D1–D4)

1. Non-interactive password via ``
2. DeployOnPrem prompt fix using `System.Management.Automation.PSBoundParametersDictionary.ContainsKey()`
3. DefaultRtId reuse (eliminate redundant `az account show`)
4. Windows empty-string bug: pre-create NIC instead of passing `--public-ip-address ""`

### Live Validation Results

**Deployment on DMAUSER-FDPO (2026-07-24, Phases 1–13):**
- **Resources:** All 24 present (hub, vWAN, 3 VNets, 2 NVAs, 2 workload VMs, Public LB, ILB, etc.)
- **Hub routingState:** Provisioned ✅
- **Routing:** defaultRouteTable 0/0→conn-dmz ✅ | conn-dmz static 0/0→10.0.0.68 ✅
- **Effective routes:** Spoke NICs see 0.0.0.0/0 via VirtualNetworkGateway ✅
- **Egress (curl ifconfig.io):** Returned Public LB PIP (20.65.77.169) ✅
- **East-west (Spoke1→Spoke2):** 3/3 pings, 0% loss ✅
- **LB metrics:** All 7 metrics on public LB + 3 on ILB collected ✅

**Status: PASS 12 / FAIL 0 / WARN 2** (warnings = Network Watcher not enabled, expected)

### Flow Validation & Monitoring Scripts (2026-07-27)

**validate-flow.sh/.ps1:** 5-phase read-only validation—
1. Pre-checks (az login, RG, hub routingState)
2. Control-plane (route table routes, effective routes, Network Watcher tests)
3. Data-plane (curl ifconfig.io from spoke VMs)
4. NVA evidence (iptables, conntrack, tcpdump)
5. LB metrics (Standard LB namespace)

**enable-monitoring.sh/.ps1:** 6-phase optional provisioning—
1. Pre-checks
2. Log Analytics workspace (30-day retention)
3. Storage account (Standard_LRS)
4. Network Watcher ensure-exists
5. VNet flow logs (future-proofed; NSG flow logs retire Sept 2027)
6. LB diagnostic settings (AllMetrics to workspace)

### EXPECTED-RESULTS.md is Canonical Baseline

The `nva-spoke-internet/EXPECTED-RESULTS.md` file captures the healthy state from live deployment (PASS 12/FAIL 0/WARN 2). README links to it. Entire lab infrastructure now committed under nva-spoke-internet/, ready for branch push + PR review.

---

## Decision References

See `.squad/decisions.md` for detailed decision entries including:
- Bicep lab decisions (Phase 1–4)
- vWAN NVA routing wiring
- Deploy script patterns
- Diagram relocation
- Flow validation & monitoring (all decisions timestamped with rationale)

Full session history available in `history-archive.md`.