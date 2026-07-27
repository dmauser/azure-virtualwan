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


### 2026-07-27 — Azure ILB Health-Probe Symmetry Fix (lb-ilb 0% healthy bug)

**Root cause:** Azure Standard LB health probes originate from the platform IP **168.63.129.16**. The ILB probes the PA *trust* NIC (ethernet1/2, snet-trust 10.0.0.64/27). PAN-OS generates the SYN-ACK with a trust source IP, but with no /32 route for 168.63.129.16 the virtual-router matched 0/0 and sent the reply out **ethernet1/1** (untrust). Azure SDN sees a trust subnet source IP egressing the untrust NIC → spoofing drop → probe never ACKs → 0% healthy → all spoke egress traffic dropped.

**Fix:** Added static route `azure-probe-via-trust` (`168.63.129.16/32 → 10.0.0.65, ethernet1/2, metric 10`) as the first entry in the virtual-router static-route block, forcing SYN-ACK replies to exit the same interface the probe arrived on.

**Reusable pattern:** Any PAN-OS (or other stateless NVA) placed behind an Azure ILB **MUST** have a host route (/32) to 168.63.129.16 pointing back out the probed dataplane interface. The probe arrives on the trust/backend NIC; without this route, the default 0/0 sends the reply out the wrong NIC, Azure SDN drops it as a spoof, and the health probe never becomes healthy. This is unrelated to security policy or NAT — it is purely a virtual-router routing issue.

**Scope:** bootstrap.xml is shared by both firewalls (pa-fw-0 and pa-fw-1); single edit covers both. Also fixed two pre-existing `--dport` occurrences in XML comments (double-hyphen is invalid per XML spec; changed to `-port` phrasing and `-&#45;dport` entity notation).


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

**2026-07-27 — MG-policy bootstrap blocker + post-boot API config-push fallback:**

#### MG-policy allowSharedKeyAccess=false bootstrap blocker
- Management-group policy `allowSharedKeyAccess=false` on DMAUSER-FDPO blocks `az storage account keys list` (shared-key auth) — the mechanism `deploy.sh` Phase 5b uses to upload `bootstrap.xml` / `init-cfg.txt` to Azure Files
- PAN-OS Azure Files bootstrap requires shared-key SMB auth; when blocked, both firewalls boot factory-default with no interfaces/zones/routes/NAT → 0 PAN-OS sessions → spoke egress fails
- The Azure routing design is NOT the problem: the identical Linux NVA lab uses the same hub routing and its live validation passes egress. Spoke UDRs are NOT the fix.
- Root cause is purely a config-delivery failure; fix is a post-boot API config-push fallback.

#### Post-boot API config-push pattern (import + load + commit)
- After PA VM boots (takes 10-15 min for PAN-OS API to be ready), apply day-0 config via PAN-OS XML API:
  1. Poll `GET /api/?type=keygen&user=U&password=P` until `<key>` returned (30s backoff, bounded by timeout)
  2. POST multipart: `type=import&category=configuration&key=K&file=@bootstrap.xml` stores named config on device
  3. POST op: `<load><config><from>bootstrap.xml</from></config></load>` loads as candidate
  4. POST commit: `<commit></commit>` returns job ID or "no changes" (idempotent)
  5. Poll job status until `<status>FIN</status><result>OK</result>`
- Import+load approach avoids hand-translating 320-line XML into xpath set commands — guaranteed fidelity
- Idempotent: re-importing and committing same file = "no changes to commit" (no-op if bootstrap already applied)
- Self-signed cert: `curl -sk` (bash); PS 5.x: ServicePointManager TrustAll; PS 7+: -SkipCertificateCheck
- Variable name trap in PS double-quoted strings: `$var:` (colon after variable) is parsed as namespace qualifier — use `${var}:` to delimit

#### Interface contract with deploy scripts (Naomi owns deploy.ps1/.sh)
- PowerShell: `-MgmtIps <string[]>` `-AdminUsername <string>` `-AdminPassword <string>` `-TimeoutMinutes <int> = 20`
- Bash: `--mgmt-ips "ip1,ip2"` `--admin-username U` `--admin-password P` `[--timeout-minutes 20]`
- Naomi's deploy scripts will call these after VM provisioning; do NOT modify deploy.ps1 / deploy.sh

#### 168.63.129.16/32 symmetric probe-return route (reinforced)
- Azure LB health probes originate from 168.63.129.16; without /32 static route, probe SYN-ACK exits eth1/1 (wrong interface) → Azure SDN drops as spoof → ILB 0% healthy → all spoke egress fails
- This /32 forces probe reply to exit eth1/2 (trust), same interface the probe arrived on
- Present in bootstrap.xml as static route `azure-probe-via-trust`: 168.63.129.16/32 → nexthop 10.0.0.65 via ethernet1/2
- Scripts verify this route post-commit as part of the PASS/FAIL check
