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
### 2026-07-27 — Architecture diagram rebuild (Task 6)
- Rebuilt 
va-spoke-internet/media/nva-spoke-internet.svg as hand-authored standalone SVG (18 KB, 1400x800 viewBox).
- SVG constraints for GitHub rendering: no external fonts, no <script>, no <foreignObject>; ont-family="Segoe UI, Arial, sans-serif" inline.
- Rebuilt 
va-spoke-internet/media/nva-spoke-internet.excalidraw as Excalidraw v2 JSON (117 elements, 106 KB), matching SVG layout; roughness=0, fontFamily=2.
- Color palette: hub=#eff6ff (blue tint), DMZ=#fffbeb (amber tint), spokes=#f0fdf4 (green), on-prem=#f8fafc (grey-dashed border).
- Arrow types: solid black = egress data path; dashed purple = route advertisement (0/0 propagation); dashed brown bidirectional = IPsec S2S tunnel.
- Egress flow: Spoke VM → Hub defaultRouteTable → conn-dmz → ILB 10.0.0.68 (HA ports) → nva-dmz-0/1 (iptables MASQUERADE) → lb-public SNAT → pip-lb-public 20.65.77.169 → Internet.
- Removed 
va-spoke-internet/media/nva-spoke-internet.png via git rm.
- README line 9 updated from .png to .svg.
- Commit: 9f83356.
- PowerShell # parsing issue with hex colors → workaround: write Python to .py file and run it, never python -c "..." with hex colors.

## Learnings

### 2026-07-27 — PAN-OS VM-Series Azure Bootstrap (nva-spoke-internet-paloalto)

**Lab context:** Translated the Linux iptables MASQUERADE NVA into a Palo Alto VM-Series BYOL day-0 bootstrap package (`nva-spoke-internet-paloalto/bicep/bootstrap/`).

#### init-cfg.txt key facts
- `type=dhcp-client` with all IP fields blank → Azure DHCP assigns the management IP
- `op-command-modes=mgmt-interface-swap` is **REQUIRED** for 3-NIC Azure VM-Series deployments
  - Without it: PAN-OS expects a dedicated OOB management port (not present in Azure)
  - With it: Azure eth0 (first NIC) → PAN-OS management; Azure eth1 → ethernet1/1; Azure eth2 → ethernet1/2
- `vm-auth-key=` blank = BYOL standalone (no Panorama); `panorama-server=` blank
- PAN-OS init-cfg.txt parser treats `#` lines as comments — safe to include header blocks
- Docs verified: https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/bootstrap-configuration-files

#### bootstrap.xml PAN-OS 10.1+ schema structure
- Root: `<config version="10.1.0"><devices><entry name="localhost.localdomain">`
- Interface management profiles under `network/profiles/interface-management-profile` — **not** under vsys
- Zones under `vsys/entry[@name='vsys1']/zone` — **not** under `network/`; zone-to-interface binding inside `<network><layer3><member>`
- DHCP-client interfaces require `<create-default-route>no</create-default-route>` or Azure DHCP will inject a default route that conflicts with the explicit static 0/0
- Static routes under `network/virtual-router/entry[@name='default']/routing-table/ip/static-route`
- NAT rules under `vsys/entry/rulebase/nat/rules` — `<service>` element is plain text (`any`), NOT a member list
- Security rules under `vsys/entry/rulebase/security/rules` — `<service><member>any</member></service>` IS a member list
- `deviceconfig/setting/session/tcp/non-syn-tcp=yes` required for HA-ports ILB (mid-flow connections forwarded on failover)

#### LB health probe contract
- Both LBs probe TCP/22 on data interfaces (trust + untrust NICs)
- Interface management profile `allow-ssh-ping` (ssh=yes, ping=yes) on each data interface makes PAN-OS respond to the probe — no OS-level SSH server required
- Equivalent to Linux: `iptables -A INPUT -p tcp --dport 22 -j ACCEPT`

#### BYOL eval-forwards fact
- VM-Series BYOL boots into ~30-day full-feature eval period with no license applied
- During eval: complete dataplane active — L3 routing, NAT, security policy all work
- After eval: basic operation continues; advanced features (threat/URL) degrade
- For lab use: eval period sufficient; no license activation needed for internet-breakout testing

#### NAT policy = iptables MASQUERADE equivalent
- `dynamic-ip-and-port` source-translation with `<interface-address><interface>ethernet1/1</interface></interface-address>` translates spoke source IP to the untrust DHCP IP
- Public LB outbound SNAT rule then re-translates to the Public LB PIP — double-SNAT design identical to Linux NVA lab

#### Validator adaptation pattern for PA
- Phases 1/2/3/5 are NVA-agnostic — copied verbatim from Linux validator
- Phase 4 replaces iptables/conntrack/tcpdump with: mgmt IP discovery via az CLI chain (vm show → nic show → public-ip show), print HTTPS GUI URL + PAN-OS CLI command hints, emit `check_warn` not `check_fail`
- Phase 3 curl remains the authoritative pass/fail signal (data-plane truth)
- Default RG changed to `rg-nva-spoke-internet-paloalto`; NVA names `pa-nva-0`/`pa-nva-1`
- validate-flow.sh inlines `log()` function (no functions.sh dependency in PA lab)

**2026-07-27:** PA lab (nva-spoke-internet-paloalto) passed review gate — Amos PASS verdict, live deploy ready (separate opt-in).
