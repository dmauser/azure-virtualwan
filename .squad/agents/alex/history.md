# Alex — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Built `main.bicep` orchestrator to drive Phase 1 topology decisions
- Implemented decision-tree logic selecting preset configuration based on user topology preference
- Created 2 connectivity modules:
  - `vnet-connection.bicep` — vWAN vNet connection with delegation and route propagation
  - `vpn-site.bicep` — VPN site provisioning with address prefix and link bandwidth config
- Established module composition pattern that allows main.bicep to call core modules (from Naomi) + connectivity modules as single declarative flow

### Key Insight
Orchestrator layer benefits from clear module interfaces (input parameters, output IDs). Decision-tree logic in main.bicep decouples topology selection from infrastructure details, enabling presets to drive deployment without orchestrator rewrites. Module interdependencies require careful dependency ordering (hubs before sites, connections after both).

## Learnings

- `Microsoft.Network/virtualHubs/routingIntent` rejects deployment if the hub firewall is not in `Succeeded` state; Bicep modules must enforce `dependsOn` on the firewall resource, while CLI scripts use post-provisioning `az network vhub routing-intent create`.
- Routing Intent destination strings are ARM-canonical: `'PrivateTraffic'` (RFC-1918 aggregate) and `'Internet'` (0.0.0.0/0). Policy names (`PrivateTraffic`, `InternetTraffic`) are labels only.
- Azure Firewall Basic tier in secured-hub mode supports `internetOnly`/`both` Routing Intent for connectivity testing but lacks IDPS and TLS inspection; document the Basic-tier caveat in any lab that uses these modes.
- Routing Intent is mutually exclusive with custom hub route tables; never add static routes to `defaultRouteTable` that overlap RI destinations.
- `hubRoutingPreference = ExpressRoute` is a lab-wide invariant for svh-dynamic-er-ri; fixed in `vhub.bicep` and validated by assertion scripts.
- **VNet connection `enableInternetSecurity` (Propagate Default Route)** is a silent prerequisite for Routing Intent internet modes: if omitted (default false), the `0.0.0.0/0` default route is NOT injected into the spoke and internet traffic bypasses the hub firewall. Must be set to `true` via `--internet-security true` in CLI (`az network vhub connection create`) for any `internetOnly` or `both` RI mode. The Bicep path sets it unconditionally (`enableInternetSecurity: true`); the CLI path must set it conditionally based on the selected RI mode.
- In multi-hub deployments with private Routing Intent, inter-hub spoke-to-spoke traffic is inspected by the firewall in BOTH the source and destination hubs (double inspection). Azure Firewall Basic is ~250 Mbps aggregate — cross-hub throughput is approximately halved in lab measurements.
- When validating RI internet mode, the most reliable assertion is `az network vhub connection show ... --query enableInternetSecurity` — this checks the control-plane flag directly without requiring data-plane traffic. Asserting the presence of `0.0.0.0/0` in effective routes requires the connection and RI to be fully provisioned and the route table to be populated, which can be timing-dependent in CI.

## Team Update: 3vhub-er-ri Lab (2026-05-26)
- Naomi delivered new `3vhub-er-ri/` lab: 3-region vWAN with ER (East+West via Megaport), AzFw Basic all hubs, RI (private). Uses native CLI for RI (no Bicep), ASPath hub preference, single interactive script with ER pause-poll pattern. LABS_INDEX.md updated.

## Session: svh-dynamic-er-ri Lab Delivery (2026-06-15)

### Lab Delivered
**svh-dynamic-er-ri** — Dynamic replacement for `3vhub-er-ri`. Parameterized 1–4 hubs with ExpressRoute, Azure Firewall Basic, Routing Intent. Uses **ExpressRoute** hubRoutingPreference (not ASPath as in 3vhub-er-ri).

### Work Completed
- Authored `routing-intent.bicep` defining all three RI modes (privateOnly, internetOnly, both) with canonical ARM JSON shapes
- Documented routing design in `alex-routing-design.md`: ExpressRoute preference rationale, RI JSON schemas, destination strings, global mode enforcement, Azure Firewall Basic caveat, no custom route tables rule, resource naming convention
- Validated RI modes against reference lab and ARM API requirements

### Key Decisions Made
1. **ExpressRoute preference (not ASPath)**: Simpler, more predictable for single-ER-per-hub topologies in dynamic labs
2. **All RI modes supported**: privateOnly (default), internetOnly, both — with documented Basic SKU Internet caveat
3. **No custom hub route tables**: RI incompatible with static routes overlapping destinations
4. **Naming contract**: `<hubName>/<hubName>-ri` for RI child resources

### Learnings Confirmed
- RI destination strings are ARM-canonical: `PrivateTraffic` (RFC-1918 aggregate), `Internet` (0.0.0.0/0)
- Basic tier lacks IDPS/TLS inspection; document for internetOnly/both modes
- Routing Intent requires firewall `Succeeded` state; CLI creation after firewall deployment (Naomi's scripts)
- Global RI mode (same mode on all hubs) prevents asymmetric routing

## Session: nva-spoke-internet Lab Scripts (2026-07-24)

### Lab Overview
**nva-spoke-internet** — Virtual WAN hub + Spoke1/Spoke2/DMZ VNets, two active/active NVAs behind a Public LB (egress SNAT) and an HA-ports ILB (east-west steering), optional on-prem S2S BGP-over-IPsec.  No Routing Intent — custom static routes instead.

### Files Authored
- `nva-spoke-internet/scripts/functions.sh` — shared helpers (log, pick_vm_sku, preflight_vm_capacity, poll_until)
- `nva-spoke-internet/scripts/deploy.sh` — 13-phase main orchestration (prereqs → prompts → SKU → Bicep → routing wiring → optional VPN)
- `nva-spoke-internet/scripts/deploy.ps1` — PowerShell parity of deploy.sh (Daniel is on Windows)
- `nva-spoke-internet/scripts/configure-onprem.sh` — on-prem NVA strongSwan+FRR bring-up via az vm run-command invoke
- `nva-spoke-internet/scripts/cleanup.sh` — az group delete wrapper
- `nva-spoke-internet/scripts/cleanup.ps1` — PowerShell cleanup

### Learnings

#### vWAN Custom NVA 0/0 Routing Wiring (no Routing Intent)
Two CLI operations are required to route internet-bound spoke traffic through NVAs via the ILB:

1. **DMZ connection static route** — set at `az network vhub connection create` time with `--route-name`, `--address-prefixes "0.0.0.0/0"`, `--next-hop <ILB-IP>`.  This programs the hub to forward 0/0 traffic that arrives from other spokes and is resolved to the DMZ connection → toward the ILB (10.0.0.68), which load-balances across the NVA HA-ports backend pool.

2. **Hub defaultRouteTable static route** — added after getting the conn-dmz resource ID:
   ```bash
   az network vhub route-table route add \
     -g $RG --vhub-name $HUB --name defaultRouteTable \
     --route-name to-internet \
     --destination-type CIDR --destinations "0.0.0.0/0" \
     --next-hop-type ResourceID --next-hop $CONN_DMZ_ID
   ```
   This causes Spoke1/Spoke2 (associated to defaultRouteTable) to learn 0.0.0.0/0 → conn-dmz → ILB → NVA → SNAT via Public LB PIP.

**`enableInternetSecurity` is NOT needed here** — that flag is only required for Routing Intent modes (internetOnly/both).  Do not set `--internet-security true` on connections when using custom static routes.

**Custom routes CAN be added to defaultRouteTable** when NOT using Routing Intent.  The "no custom route tables" rule from svh-dynamic-er-ri only applies to RI labs (RI and static routes overlap — RI wins and ignores static).

#### VNet Connection Sequencing
VNet connections MUST be created post-deploy in scripts (not in Bicep) to avoid timing/ordering issues with hub routingState.  Always poll `routingState == Provisioned` before creating any connections.

#### On-prem BGP-over-IPsec Bring-up
- **strongSwan**: IKEv2, one `conn` block per hub GW instance (active/active = 2 PIPs), route-based (leftsubnet/rightsubnet = 0.0.0.0/0 so BGP TCP is not selector-restricted), `auto=start`, `dpdaction=restart`.
- **FRR**: `router bgp 65001`, two neighbors at hub BGP peer IPs (one per GW instance), `ebgp-multihop 5` (required — BGP peer is not directly connected; traverses IPsec tunnel), `network 192.168.100.0/24`.
- **Local-shell variable expansion**: all IP/ASN vars are expanded by the local shell BEFORE the `az vm run-command invoke` call; use quoted heredoc markers on the REMOTE side (`<< 'IPSECEOF'`) to prevent the remote shell from re-expanding `$` in config file content.
- **Two-step PSK pattern**: `az network vpn-gateway connection create` (creates the connection) + `az network vpn-gateway connection vpn-site-link-conn sharedkey update --index 0 --value $PSK` (sets PSK on link 0 separately).  Current az CLI cannot set PSK inline at create time for link-based connections.

#### Hub VPN Gateway IP/BGP Query Paths
```bash
HUB_GW_PIP0=$(az network vpn-gateway show -g $RG -n $VPN_GW --query "ipConfigurations[0].publicIpAddress" -o tsv)
HUB_BGP_PEER0=$(az network vpn-gateway show -g $RG -n $VPN_GW --query "bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]" -o tsv)
```
Active/active GW always has indices [0] and [1] for both arrays.

#### Bicep Output Name Contract (with Naomi)
Alex consumes these outputs from `nva-spoke-internet/bicep/main.bicep`:
`location, vwanName, hubName, hubId, dmzVnetId, spoke1VnetId, spoke2VnetId, ilbFrontendIp, publicLbPublicIp, nvaNames, vpnGatewayName, onpremVnetId, onpremNvaPublicIp, onpremNvaPrivateIp, onpremNvaName, onpremVmName`

Alex passes these params TO Bicep:
`location, adminUsername, adminPassword, vmSize, deployOnPrem, onpremBgpAsn`

Key constant: ILB frontend IP **10.0.0.68** (in snet-ilb 10.0.0.64/26 of DMZ VNet 10.0.0.0/24).

#### D1 Fix (2026-07-24) — Reuse deployment outputs instead of re-deriving resource IDs
`DEFAULT_RT_ID` was constructed via a redundant `az account show` subscription lookup; replaced with `DEFAULT_RT_ID="${HUB_ID}/hubRouteTables/defaultRouteTable"`, reusing the already-fetched `hubId` Bicep output and eliminating the dead `SUBSCRIPTION` variable.

#### Windows Line Endings
All `.sh` files written by the create tool on Windows have CRLF (`\r\n`) line endings by default.  Convert to LF before committing or running:
```powershell
$c = [System.IO.File]::ReadAllText($path)
[System.IO.File]::WriteAllText($path, $c.Replace("`r`n","`n"), [System.Text.UTF8Encoding]::new($false))
```

---

## Session: nva-spoke-internet Live Deploy — DMAUSER-FDPO (2026-07-24T22:28:48Z)

### Deployment Summary
**Subscription:** DMAUSER-FDPO (`78216abe-8139-4b45-8715-6bab2010101e`)  
**Region:** eastus2  
**VM size chosen by preflight:** Standard_B2s (list-skus confirmed no restrictions; quota 0/100; `-SkipPreflight` used after debugging false-fail)  
**Duration:** Phases 1-13 ~26 min total (Bicep 6 min, routingState poll ~12 min, connections ~5 min, route-table add ~90s)  
**Exit code:** 0 — all phases succeeded

### Fixes Applied to deploy.ps1 (4 changes)

#### 1. Non-interactive password via `$env:ADMIN_PASSWORD`
Added env-var fallback before the password loop:
```powershell
if (-not [string]::IsNullOrWhiteSpace($env:ADMIN_PASSWORD) -and $env:ADMIN_PASSWORD.Length -ge 12) {
    $AdminPasswordPlain = $env:ADMIN_PASSWORD
    Log "  Admin password : (taken from `$env:ADMIN_PASSWORD)"
}
```
Changed `while ($true) {` → `while ([string]::IsNullOrWhiteSpace($AdminPasswordPlain)) {`.

#### 2. DeployOnPrem prompt fix (`$PSBoundParameters`)
`if (-not $DeployOnPrem)` fires even when `-DeployOnPrem:$false` is explicitly passed (switch is `$false` in both the omitted and explicit cases). Fix: `if (-not $PSBoundParameters.ContainsKey('DeployOnPrem'))` — only prompts when genuinely omitted.

#### 3. D1 fix (PS1 parity with deploy.sh fix)
Replaced `az account show --query id` + manual string for `$DefaultRtId` with:
```powershell
$HubId = Get-Out "hubId"
$DefaultRtId = "${HubId}/hubRouteTables/defaultRouteTable"
```

#### 4. Windows empty-string arg bug in preflight (`--public-ip-address ""`)
Root cause: on Windows PowerShell, passing `""` to an external command (az CLI) drops the empty string silently. `az vm create --public-ip-address` receives no value → `ERROR: argument --public-ip-address: expected one argument` → exit code 2 → ALL SKUs appear "capacity-blocked".  
Fix: pre-create a NIC (no public IP) with `az network nic create`, then pass `--nics capchk-nic` to `az vm create` (no `--public-ip-address` argument at all).

### Live Validation Results (all PASS)

| Check | Result |
|-------|--------|
| Resources present | ✅ All 24 resources in rg-nva-spoke-internet: hub, vWAN, 3 VNets, 2 NVAs, 2 workload VMs, Public LB, ILB, Public PIP, NSGs, UDRs, NICs |
| Hub routingState | ✅ `Provisioned` |
| defaultRouteTable 0/0 → conn-dmz | ✅ Route `to-internet`: CIDR 0.0.0.0/0 → conn-dmz ResourceID |
| conn-dmz static 0/0 → 10.0.0.68 | ✅ Static route `default-via-ilb`: 0.0.0.0/0 → 10.0.0.68 |
| ILB frontend IP | ✅ 10.0.0.68 |
| Public LB PIP | ✅ 20.65.77.169 |
| Both NVAs in ILB backend pool | ✅ nic-nva-dmz-0 + nic-nva-dmz-1 both in `nva-backend` pool |
| Effective routes on Spoke1 NIC | ✅ 0.0.0.0/0 → VirtualNetworkGateway (10.100.0.68 = vWAN hub) |
| **Egress test (curl ifconfig.io from vm-spoke1)** | ✅ **Returned 20.65.77.169 — matches Public LB PIP** |
| East-west (Spoke1 → Spoke2 10.2.0.4) | ✅ 3/3 pings, 0% loss, TTL=63 |
| Boot diagnostics (vm-spoke1) | ✅ enabled=true, managed storage (no storageUri) |

### Transient Error (non-fatal)
Phase 9 `conn-spoke1` creation returned `InternalServerError` on first attempt. The script polled and conn-spoke1 reached `Succeeded` within ~3 min — vWAN hub occasionally returns 500 during back-to-back connection creates. Pattern: safe to continue polling; script handled gracefully.

---

## Team Update: 2026-07-24

**Lab Status:** nva-spoke-internet Bicep rebuild **COMPLETE & VALIDATED**

The team successfully rebuilt the nva-spoke-internet lab infrastructure as code. All agents contributed:
- naomi: 13 Bicep files
- alex: 6 deployment scripts
- holden: README + topology diagram
- amos: QA validation (8/8 PASS + 1 LOW defect fixed)

Lab is ready for end-to-end testing.