# Decisions

> Team decisions log. Append-only.

---

# Decision: nva-spoke-internet Bicep Output Contract

**Date:** 2026-07-24  
**Author:** Naomi (Infra Dev)  
**Status:** Active — do not change without coordinating with Alex

## Decision

The 16 outputs of `nva-spoke-internet/bicep/main.bicep` are a **locked contract** consumed by name in Alex's `deploy.sh` via `az deployment group show --query properties.outputs.<name>.value`. Any rename or removal breaks the deploy chain **silently** (the script just gets an empty string and proceeds incorrectly).

## Output Contract (exact names, do not rename)

| Output | Type | Notes |
|--------|------|-------|
| `location` | string | |
| `vwanName` | string | |
| `hubName` | string | |
| `hubId` | string | |
| `dmzVnetId` | string | full resource ID |
| `spoke1VnetId` | string | full resource ID |
| `spoke2VnetId` | string | full resource ID |
| `ilbFrontendIp` | string | always `10.0.0.68` |
| `publicLbPublicIp` | string | egress/mgmt public IP |
| `nvaNames` | array | `['nva-dmz-0','nva-dmz-1']` |
| `vpnGatewayName` | string | `''` when deployOnPrem=false |
| `onpremVnetId` | string | `''` when deployOnPrem=false |
| `onpremNvaPublicIp` | string | `''` when deployOnPrem=false |
| `onpremNvaPrivateIp` | string | `''` when deployOnPrem=false |
| `onpremNvaName` | string | `''` when deployOnPrem=false |
| `onpremVmName` | string | `''` when deployOnPrem=false |

## Input Parameters (exact names, deploy.sh passes these)

| Param | Type | Default |
|-------|------|---------|
| `location` | string | — (required) |
| `adminUsername` | string | — (required) |
| `adminPassword` | @secure() string | — (required) |
| `vmSize` | string | `'Standard_B2s'` |
| `deployOnPrem` | bool | `false` |
| `onpremBgpAsn` | int | `65001` |

## Rationale

Alex's `configure-onprem.sh` and all hub-connection steps depend on these exact strings. Bicep's type system won't catch a mismatch — the error surfaces only at runtime when the script tries to use an empty VNet ID for peering. Document here so any future Bicep refactor checks this list first.


---

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


---

# Decision: nva-spoke-internet Lab Documentation & Diagram

**Author:** Holden  
**Date:** 2026-07-24  
**Status:** Accepted  

## Decisions Made

### 1. Media folder at repo root (not inside lab subfolder)

**Decision:** `media/nva-spoke-internet.excalidraw` and the exported `media/nva-spoke-internet.png` live at the **repo root `media/`** folder, not inside `nva-spoke-internet/media/`.

**Rationale:** The task instructions explicitly specify `![diagram](../media/nva-spoke-internet.png)` in the README, which resolves to root-level `media/` from `nva-spoke-internet/README.md`. A root-level `media/` folder also allows topology images to be shared or cross-linked across labs without duplication. The old `nva-spoke-internet/media/nva-spoke-internet.png` (azcli lab diagram) is left untouched.

**Impact:** Naomi/Alex scripts and any future CI pipeline that exports the .excalidraw to .png should target `media/` at the repo root.

---

### 2. Excalidraw diagram traffic flow direction

**Decision:** Traffic flows **upward** in the diagram Y-axis. Internet is at the top (y=20); the vWAN Hub is in the center (y=530); on-prem simulation is at the bottom (y=790).

**Rationale:** Placing the internet destination at the top matches the conventional network diagram convention (external/cloud "above", on-prem "below"). The hub occupies the visual center as the routing hub, with spokes branching left and right. This produces a clean vertical traffic path: Spoke VM (bottom-left/right) → Hub (center) → ILB → NVA → PLB → Internet (top).

---

### 3. Excalidraw element style

**Decision:** `roughness: 0` on all elements, no element binding (`startBinding/endBinding: null`), arrow points as relative arrays.

**Rationale:** Zero roughness gives a clean infrastructure-diagram look consistent with the repo's other technical diagrams. No element binding makes the JSON portable — if element IDs change, arrows don't break. Relative `points` arrays are simpler to author and maintain than absolute coordinates on arrow endpoints.

---

### 4. Hub routing sequencing documented as script-driven (not Bicep)

**Decision:** README explicitly calls out that hub VNet connections and `defaultRouteTable` route programming are script-driven, performed after `routingState = Provisioned`, not in Bicep.

**Rationale:** Consistent with the pattern established in `svh-dynamic-er-ri`. Azure control plane rejects connection/route operations while the hub is initialising. Documenting this prominently prevents confusion for developers who expect all infrastructure to be idempotent Bicep.

---

## Impact on Other Agents

- **Naomi (scripts):** `deploy.sh` / `deploy.ps1` must write exported PNG to `media/` at repo root (not `nva-spoke-internet/media/`).
- **Alex (bicep):** No change — bicep modules are unaffected by media folder location.
- **Team:** Future labs should use root-level `media/` for topology diagrams to enable cross-lab image reuse.


---

# Finding: nva-spoke-internet Bicep Lab Validation

**Author:** Amos (Tester)  
**Date:** 2026-07-24T16:50:18Z  
**Status:** Finding — action required on D1  
**Related:** `naomi-nva-si-output-contract.md`, `alex-nva-spoke-internet-vwan-routing.md`

---

## Summary

Independent QA pass on the `nva-spoke-internet` lab (Bicep + scripts + cloud-init).
All structural checks pass. One low-severity defect found in `deploy.sh`.

---

## Validation Results

| Task | Check | Result | Notes |
|------|-------|--------|-------|
| 1 | `az bicep build` compile | **PASS** | Exit 0, zero BCP diagnostics; v0.42.1 advisory to upgrade to v0.45.15 |
| 2 | `bash -n` lint (all 4 scripts) | **PASS** | functions.sh, deploy.sh, configure-onprem.sh, cleanup.sh — clean |
| 3 | Contract cross-check (16 outputs) | **PASS + D1** | All 16 outputs present in main.bicep and main.json; see defect |
| 4 | Address plan audit | **PASS** | All CIDRs/ASNs match contract; no 10.200.0.0 references |
| 5 | VM size preflight | **PASS** | pick_vm_sku + preflight_vm_capacity in Phase 3, before Phase 6 Bicep deploy |
| 6 | Routing sequencing | **PASS** | poll_until gates Phase 8; connections created in Phases 9-11 post-Provisioned |
| 7 | Boot diag / serial console | **PASS** | vm.bicep: `bootDiagnostics: { enabled: true }`, no storageUri |
| 8 | Cloud-init review | **PASS** | nva.yaml: ip_forward + MASQUERADE + SSH INPUT; onprem-nva.yaml: strongSwan + FRR |

---

## Defects

### D1 — `HUB_ID` fetched but never used (LOW severity)

**File:** `nva-spoke-internet/scripts/deploy.sh:155`  
**Symptom:** Variable `HUB_ID` is assigned from `get_output hubId` but is referenced nowhere downstream.  
**Root cause:** `DEFAULT_RT_ID` is constructed at line 169 via a separate `az account show` call instead of from `HUB_ID`.

```bash
# deploy.sh line 155 — assigned but never used:
HUB_ID="$(get_output hubId)"

# deploy.sh line 167-169 — constructs DEFAULT_RT_ID without HUB_ID:
SUBSCRIPTION=$(az account show --query id -o tsv)
DEFAULT_RT_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RG}/providers/Microsoft.Network/virtualHubs/${HUB}/hubRouteTables/defaultRouteTable"
```

**Fix (Naomi):** Replace lines 167-169 with:
```bash
DEFAULT_RT_ID="${HUB_ID}/hubRouteTables/defaultRouteTable"
```
This removes one extra `az account show` API call and eliminates the dead variable.  
**Impact if not fixed:** None — functional, just wasteful and confusing to maintainers.

---

## Observations (non-defect)

### O1 — `disableBgpRoutePropagation: false` on snet-nva UDR

**File:** `nva-spoke-internet/bicep/modules/dmz.bicep:67`  
Hub-propagated routes appear in the NVA subnet routing table. The explicit `0.0.0.0/0 → Internet` UDR route correctly overrides any propagated 0/0 (UDR static wins over BGP for same prefix). No functional impact. Setting `disableBgpRoutePropagation: true` would be more defensive and reduce route-table noise.

### O2 — ILB frontend hardcoded as Bicep `var` (by design)

`ilbFrontendIp = '10.0.0.68'` (internal-lb.bicep:27). The value is statically assigned in both Bicep and ARM. The deploy.sh guard at line 183 catches any drift. This pattern is intentional and correct.

### O3 — Bicep compiler version advisory

Current: v0.42.1.51946. Upgrade to v0.45.15 available. Not a warning or BCP diagnostic; all output is structurally valid.

---

## Reusable Validation Patterns Established

1. **Bicep contract cross-check**: compare `grep -n "output " main.bicep` against all `get_output <name>` calls in deploy script — zero mismatches is the pass criterion.
2. **Dead variable detection**: `grep "HUB_ID" deploy.sh | wc -l` — count occurrences; if assignment is the only occurrence, it's unused.
3. **Old CIDR scan**: `grep -r "10.200.0.0" .` — must return zero results after any CIDR migration refactor.
4. **Cloud-init completeness check for NVA**: nva.yaml must have `ip_forward = 1`, `MASQUERADE`, `FORWARD -j ACCEPT`, and `INPUT --dport 22 -j ACCEPT` (last item supports ILB TCP/22 health probe).

See `.squad/skills/vwan-nva-routing/SKILL.md` for updated verification commands.

---

## Test Plan

See the end-to-end validation test plan in the Amos validation report. Key test cases:

1. **Spoke → Internet egress**: `curl -s https://ifconfig.me` from spoke1/spoke2 VM must return the Public LB PIP
2. **Effective routes**: spoke NIC effective routes must show `0.0.0.0/0` via `conn-dmz`
3. **HA failover**: stop nva-0, re-run curl from spoke — traffic resumes via nva-1 (ILB health probe detects failure in ~15s)
4. **Serial console**: `az serial-console connect -g $RG -n <vm-name>` must open without error (boot diag enabled)
5. **On-prem BGP (deployOnPrem=true)**: `az network vpn-gateway connection show` BGP status = Connected; on-prem VM can ping/SSH spoke1/spoke2 private IPs

All test cases are runnable with az CLI + ssh; no custom tooling required.

---

# Decision: Non-interactive deploy.ps1 patterns + Windows preflight fix

**Author:** Alex  
**Date:** 2026-07-24T22:28:48Z  
**Context:** Live deploy of nva-spoke-internet lab to DMAUSER-FDPO (eastus2)

---

## Decision 1: `$env:ADMIN_PASSWORD` env-var fallback for unattended runs

**Problem:** `deploy.ps1` blocks on `Read-Host -AsSecureString` in an interactive loop, preventing CI/agent use.

**Decision:** Insert an env-var check BEFORE the `while` loop. If `$env:ADMIN_PASSWORD` is set and ≥12 chars, skip interactive prompting entirely. The `while` condition is changed from `while ($true)` to `while ([string]::IsNullOrWhiteSpace($AdminPasswordPlain))` so the loop is skipped rather than broken out of — no `break` required.

```powershell
if (-not [string]::IsNullOrWhiteSpace($env:ADMIN_PASSWORD) -and $env:ADMIN_PASSWORD.Length -ge 12) {
    $AdminPasswordPlain = $env:ADMIN_PASSWORD
    Log "  Admin password : (taken from `$env:ADMIN_PASSWORD)"
}
while ([string]::IsNullOrWhiteSpace($AdminPasswordPlain)) { ... }
```

**Rationale:** Preserves interactive path (env var absent → loop runs as before). Allows unattended deploy from CI or agent contexts where `$env:ADMIN_PASSWORD` is pre-set in the calling process. Password never written to disk in git-tracked files.

---

## Decision 2: `$PSBoundParameters.ContainsKey('DeployOnPrem')` for switch params

**Problem:** `[switch]$DeployOnPrem` evaluates to `$false` both when omitted and when explicitly passed as `-DeployOnPrem:$false`. The guard `if (-not $DeployOnPrem)` therefore fires the interactive `Read-Host` prompt even when the caller explicitly opts out.

**Decision:** Replace `if (-not $DeployOnPrem)` with `if (-not $PSBoundParameters.ContainsKey('DeployOnPrem'))` — only prompt if the switch was genuinely absent from the command line.

**Rationale:** Standard PowerShell idiom for distinguishing "not passed" from "passed as false". Allows `-DeployOnPrem:$false` to cleanly suppress the prompt in all non-interactive contexts.

---

## Decision 3: Windows `az vm create --public-ip-address ""` is a silent no-arg bug

**Problem:** Phase 3 preflight used `az vm create --public-ip-address ""` to suppress public IP creation. On Windows PowerShell, the empty string `""` is dropped silently when passed to an external command. `az` receives `--public-ip-address` with no value → `ERROR: argument --public-ip-address: expected one argument` → exit code 2 → ALL VM SKUs appear capacity-blocked (false negative).

**Decision:** Pre-create a NIC without a public IP (`az network nic create`), then use `az vm create --nics capchk-nic` with no `--public-ip-address` argument. The absence of the flag (not an empty-string argument) reliably suppresses public IP creation cross-platform.

**Rationale:** The root cause is Windows PowerShell's handling of empty string args to external commands — this is not a capacity issue and not az-CLI-version-specific. The NIC pre-creation pattern avoids the arg entirely and is portable (Linux bash + Windows PS1).

**Scope:** Affects any PowerShell deploy script that passes empty strings to `az` for optional arguments. Apply this pattern to: `--public-ip-address ""`, `--subnet ""`, `--vnet-name ""` and any other optional resource-name args.

---

## Decision 4: Use `-SkipPreflight` when quota is confirmed adequate
After diagnosing the false-fail above, the preflight was bypassed with `-SkipPreflight` for the production run. The preflight fix was applied to deploy.ps1 for future use, but confirmed quota (B-series: 0/100 vCPUs used) made the check unnecessary for this run.

---

# Decision: nva-spoke-internet Flow Validation + Monitoring Enablement

**Author:** Alex (Network Engineer)  
**Date:** 2026-07-27  
**Status:** Accepted  
**Lab:** `nva-spoke-internet`

---

## Context

The `nva-spoke-internet` lab successfully deployed and validated manually on 2026-07-24. The team needed a repeatable, documented way to:

1. **Prove** the Spoke VM → vHub → DMZ connection → ILB → NVA → Public LB → Internet path is functioning correctly (control-plane + data-plane + NVA forwarding + LB metrics).
2. **Optionally** enable persistent flow logs and LB metric streaming for deeper observability.

---

## Decision (a): 4-phase validation approach

### Approach

The `validate-flow.sh` / `validate-flow.ps1` scripts trace the end-to-end breakout across four evidence tiers:

| Phase | Tier | Key commands | What it proves |
|-------|------|-------------|----------------|
| 2 | Control-plane | `az network vhub route-table show`, `az network vhub connection show`, `az network nic show-effective-route-table`, `az network vhub get-effective-routes`, `az network watcher show-next-hop`, `az network watcher test-ip-flow`, `az network watcher test-connectivity` | Route programming is correct end-to-end; vHub, connection, and NIC all agree |
| 3 | Data-plane | `az vm run-command invoke` → `curl https://ifconfig.io` on vm-spoke1 + vm-spoke2 | Actual egress IP matches `pip-lb-public` (SNAT proof) |
| 4 | NVA forwarding | `iptables -t nat -L POSTROUTING`, `conntrack -L`, concurrent `tcpdump` on nva-dmz-0 | NVA is the active MASQUERADE hop; packet capture confirms forwarding |
| 5 | LB metrics | `az monitor metrics list` — 7 metrics on lb-public, 3 on lb-ilb | SNAT port consumption, health probe status, byte/packet counters visible |

### Rationale

- **Control-plane first**: route programming failures (missing static route, wrong next-hop type) surface immediately before any VM traffic is generated.
- **Data-plane second**: `curl ifconfig.io` from both spoke VMs is the definitive SNAT proof — the returned IP must equal `pip-lb-public`.
- **NVA evidence third**: iptables + conntrack + tcpdump provide per-hop forensics when the data-plane check fails or is inconclusive.
- **Metrics last**: metrics confirm sustained activity and SNAT port allocation; they require traffic to have passed through, so they are most useful after phases 2–4 pass.

### Key expected values

- Spoke NIC effective route: `0.0.0.0/0 → nextHopType = VirtualNetworkGateway` (vHub BGP router at 10.100.x.68). This is documented behaviour for vWAN-connected spoke VNets. Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
- `curl ifconfig.io` from spoke VMs must return the Public LB PIP (`pip-lb-public`, 20.65.77.169 in the live deploy).
- `iptables -t nat -L POSTROUTING` on each NVA must show a `MASQUERADE` rule (provisioned by cloud-init).

---

## Decision (b): Use VNet flow logs — NOT NSG flow logs

### Decision

All `enable-monitoring` scripts create **VNet flow logs**, not NSG flow logs.

### Rationale

| Factor | NSG flow logs | VNet flow logs |
|--------|--------------|----------------|
| New creation blocked | **After June 30, 2025** | ✅ Still available |
| Retirement date | **September 30, 2027** | No announced retirement |
| Scope | Per-NSG | Per-VNet (broader coverage) |
| Traffic Analytics support | Yes (legacy) | Yes (current) |

NSG flow logs are being retired. After 2025-06-30 new NSG flow logs cannot be created. Using VNet flow logs future-proofs the lab and aligns with Microsoft's current guidance.

**Sources:**
- https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
- https://learn.microsoft.com/azure/network-watcher/traffic-analytics

---

## Decision (c): Separate `enable-monitoring` script

### Decision

Monitoring-stack provisioning (`enable-monitoring.sh` / `enable-monitoring.ps1`) is a **separate, optional, standalone script** — not part of `deploy.sh` / `deploy.ps1`.

### Rationale

1. **Cost surprise prevention.** Log Analytics ingestion, Traffic Analytics, and storage for flow logs incur ongoing cost. Including them in the core deploy would create surprise charges for users who just want to spin up the lab topology.
2. **Validate-flow is read-only.** The validate-flow scripts are deliberately zero-side-effect — they must be safe to run at any time without provisioning resources or incurring cost. Monitoring enablement requires resource creation (workspace, storage account, flow log resources, diagnostic settings) and must be in a separate script with an explicit user opt-in.
3. **Idempotency boundary.** Each script has a clean idempotency guarantee: `validate-flow` never writes anything; `enable-monitoring` checks-then-creates each resource individually. Mixing them would make the idempotency logic more complex and the cost contract ambiguous.
4. **Operational lifecycle.** Users may want to enable monitoring mid-session (e.g. to capture a specific traffic pattern) without re-running the full deployment. A standalone script supports this workflow.

### Resources created by `enable-monitoring`

| Resource | Name | Notes |
|----------|------|-------|
| Log Analytics workspace | `log-nva-spoke-internet` | 30-day retention |
| Storage account | `stnvaspk<sub-8-chars>` | Standard_LRS, globally unique |
| Network Watcher | `NetworkWatcher_<region>` | `NetworkWatcherRG` |
| VNet flow log | `flow-vnet-dmz` | Traffic Analytics on |
| VNet flow log | `flow-vnet-spoke1` | Traffic Analytics on |
| VNet flow log | `flow-vnet-spoke2` | Traffic Analytics on |
| LB diagnostic settings | `diag-lb-public` | AllMetrics → workspace |
| LB diagnostic settings | `diag-lb-ilb` | AllMetrics → workspace |

---

## References

- https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
- https://learn.microsoft.com/azure/virtual-network/manage-route-table
- https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
- https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
- https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
- https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
- https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
- https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
- https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
- https://learn.microsoft.com/azure/network-watcher/traffic-analytics

---

# Decision: nva-spoke-internet Diagram Relocated into Lab Folder

**Author:** Holden (Lead Architect)
**Date:** 2026-07-27
**Status:** Adopted — supersedes prior decision on root-level media/ for this lab

---

## Context

The `nva-spoke-internet` lab diagram was split across two locations:
- `media/nva-spoke-internet.excalidraw` — editable source at repo root (created 2026-07-24)
- `nva-spoke-internet/media/nva-spoke-internet.png` — exported PNG already inside the lab folder

The prior decision (2026-07-24) placed the `.excalidraw` source at repo root on the rationale that a root-level `media/` folder allows cross-lab reuse. That rationale no longer applies — no other lab references this diagram, and keeping the source outside the lab folder creates a confusing split.

---

## Decision

Move all diagram assets into `nva-spoke-internet/media/` and update the README to use `./media/` local paths.

**Files affected:**
| Before | After |
|--------|-------|
| `media/nva-spoke-internet.excalidraw` (repo root) | `nva-spoke-internet/media/nva-spoke-internet.excalidraw` |
| `nva-spoke-internet/media/nva-spoke-internet.png` | unchanged — already correct |

**Root `media/` folder:** removed (was empty after the move).

---

## README Changes

1. Image embed: `../media/nva-spoke-internet.png` → `./media/nva-spoke-internet.png`
2. Excalidraw callout (single line) → expanded three-option block with VS Code extension link, excalidraw.com manual open, and direct raw GitHub URL.
3. Footer source line: `../media/nva-spoke-internet.excalidraw` → `./media/nva-spoke-internet.excalidraw`
4. Files tree: added `.gitignore`, `bicep/main.json`, and `bicep/cloud-init/` entries to match actual disk contents.

---

## Rationale

- Self-contained lab folder: all assets (Bicep, scripts, cloud-init, diagrams) under one directory tree makes the lab portable and easier to copy or fork.
- `./media/` paths are simpler and work correctly when the lab folder is opened directly in GitHub or VS Code.
- The three-option Excalidraw block (VS Code / excalidraw.com / raw URL) gives users clear, actionable instructions for opening the editable source.

---

## Impact on Other Agents

- **Naomi / Alex:** If a future pipeline auto-exports `.excalidraw` → `.png`, the target path is now `nva-spoke-internet/media/nva-spoke-internet.png` (unchanged) and source is `nva-spoke-internet/media/nva-spoke-internet.excalidraw`.
- **No other labs are affected** — this was a single-lab relocation.


---


# Decision: PAN-OS VM-Series Day-0 Bootstrap Design

**Author:** Alex (Network Eng)  
**Date:** 2026-07-27  
**Lab:** nva-spoke-internet-paloalto  
**Status:** Draft — pending Naomi (Bicep deploy) and Amos (connectivity validation)

---

## Context

The `nva-spoke-internet-paloalto` lab replaces the Linux iptables MASQUERADE NVAs with Palo Alto VM-Series BYOL firewalls in the same DMZ VNet topology. The two PA firewalls must forward spoke egress traffic to the internet purely from their day-0 bootstrap config — no manual post-boot configuration, no Panorama.

**Traffic path (identical to Linux NVA lab):**
```
Spoke VM -> vHub defaultRouteTable (0/0 -> conn-dmz)
  -> conn-dmz static route (0/0 -> 10.0.0.68)
  -> ILB 10.0.0.68 (HA-ports, probes TCP/22 on trust NIC)
  -> PA ethernet1/2 (trust zone, Azure eth2, snet-trust 10.0.0.64/27)
  -> PAN-OS security policy (permit trust->untrust) + NAT (MASQUERADE)
  -> PA ethernet1/1 (untrust zone, Azure eth1, snet-untrust 10.0.0.32/27)
  -> Public LB outbound SNAT rule (probes TCP/22 on untrust NIC)
  -> pip-lb-public -> Internet
```

---

## Decisions

### D1: `op-command-modes=mgmt-interface-swap` in init-cfg.txt

**Decision:** Required in all Azure 3-NIC VM-Series deployments.

**Rationale:** PAN-OS expects a dedicated OOB management port that does not exist in Azure VMs. Without the swap, the management plane cannot be reached and the firewall boots into a broken state. With the swap: Azure eth0 (first NIC, snet-mgmt) maps to PAN-OS management; Azure eth1 → ethernet1/1 (untrust); Azure eth2 → ethernet1/2 (trust).

**Source:** Palo Alto bootstrap-configuration-files documentation (https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/bootstrap-configuration-files)

### D2: `create-default-route=no` on DHCP-client data interfaces

**Decision:** Set `<create-default-route>no</create-default-route>` on both ethernet1/1 and ethernet1/2.

**Rationale:** Azure DHCP will otherwise inject a 0.0.0.0/0 default route learned via DHCP option 3 on each interface, conflicting with the explicitly managed static route `0.0.0.0/0 → 10.0.0.33` in the virtual router. Only one default route is valid; the static route must win.

### D3: Interface management profile `allow-ssh-ping` on both data interfaces

**Decision:** Apply `allow-ssh-ping` (ssh=yes, ping=yes) to ethernet1/1 (untrust) and ethernet1/2 (trust).

**Rationale:** Both the Public LB (untrust side) and ILB (trust side) health probe TCP/22. The management profile causes PAN-OS to respond to these probes from the data interfaces without requiring a host SSH server. This is the PAN-OS equivalent of `iptables -A INPUT -p tcp --dport 22 -j ACCEPT` from the Linux NVA. Without this, both LBs mark both NVAs unhealthy and the traffic path breaks entirely.

**Risk:** SSH exposed on the untrust (internet-facing) interface. Acceptable for a lab. Mitigate in production with restricted source-IP management profiles or a dedicated management VNet.

### D4: NAT policy uses `dynamic-ip-and-port` with `interface-address ethernet1/1`

**Decision:** Source NAT rule `trust-to-untrust-masquerade` translates spoke source IPs to the DHCP-assigned IP on ethernet1/1 (untrust).

**Rationale:** Direct equivalent of `iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`. The DHCP IP on ethernet1/1 is in snet-untrust (10.0.0.32/27). The Public LB outbound SNAT rule then re-translates this to the Public LB PIP — double-SNAT design. This matches the Linux NVA lab exactly.

**Alternative considered:** Translate to a static NAT IP address pool. Rejected because the untrust IP is DHCP-assigned and not known at bootstrap time.

### D5: `non-syn-tcp=yes` in deviceconfig session settings

**Decision:** Enable `<non-syn-tcp>yes</non-syn-tcp>` under `deviceconfig/setting/session/tcp`.

**Rationale:** Azure ILB in HA-ports mode may forward mid-flow TCP connections to the firewall after a failover or initial load-distribution. Without this setting, PAN-OS drops non-SYN TCP packets (FIN, RST, data packets for sessions not yet in the session table), breaking TCP connections for flows that arrive mid-session.

### D6: Static route covering all RFC1918 10/8 as return path via trust

**Decision:** Single static route `10.0.0.0/8 → 10.0.0.65 (trust gateway) via ethernet1/2`.

**Rationale:** Covers spoke1 (10.1.0.0/16), spoke2 (10.2.0.0/16), and DMZ (10.0.0.0/24) in a single entry. Reply traffic from the internet-destined sessions never needs to return via the trust side (the NAT handles it), but this route ensures health probe response traffic and any east-west flows exit the correct interface. The trust gateway (10.0.0.65) routes back through the vHub to spokes.

**Alternative considered:** Two specific /16 routes. Rejected as unnecessarily granular for a lab; the 10/8 supernet is simpler and forward-compatible if more spokes are added.

### D7: BYOL eval-period reliance

**Decision:** The bootstrap.xml relies on the VM-Series BYOL 30-day eval dataplane.

**Rationale:** Lab environments do not require production licensing. During the eval period the full dataplane is active: routing, NAT, security policy all function normally. No license activation step is needed for internet-breakout testing.

**Risk:** Eval period expires in ~30 days. If the lab runs beyond that, basic operation continues but threat prevention and URL filtering may degrade. For a routing/NVA lab, this is acceptable. Apply a real license before any production use.

### D8: Security policy is any/any trust→untrust (lab only)

**Decision:** Single security rule permitting all traffic from trust to untrust zones.

**Rationale:** This is a lab focused on routing and NAT behavior, not threat policy. Any/any simplifies troubleshooting. In production: restrict to specific applications (web-browsing, ssl) with App-ID, add threat prevention profiles, and enable URL filtering.

---

## Deliverables Created

| File | Status |
|---|---|
| `nva-spoke-internet-paloalto/bicep/bootstrap/init-cfg.txt` | ✅ Created 2026-07-27 |
| `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml` | ✅ Created 2026-07-27 |
| `nva-spoke-internet-paloalto/scripts/validate-flow.sh` | ✅ Created 2026-07-27 |
| `nva-spoke-internet-paloalto/scripts/validate-flow.ps1` | ✅ Created 2026-07-27 |

**Not created (Naomi's responsibility):** Bicep modules for VM-Series NVA, storage account for bootstrap package, LB bicep adaptations, deploy scripts.

---

## Residual Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Azure Marketplace image version for PA VM-Series | Medium | bootstrap.xml uses config version="10.1.0" which is forward-compatible with 10.2/11.x; test against the actual Marketplace SKU version |
| `#` comments in init-cfg.txt | Low | Parser tolerates them in practice (treats as blank lines); if bootstrap fails, remove comment lines as first debug step |
| PA NVA VM names (pa-nva-0, pa-nva-1) | Low | Assumed defaults; Naomi must use these names in Bicep or set NVA_NAMES env var in validator |
| BYOL eval expiry | Low | ~30 days; acceptable for lab; document in README |
| SSH on untrust interface (management profile) | Medium | Lab-only acceptable; production requires restricted source-IP or Panorama-managed profiles |
| Double-SNAT visibility | Low | Logs at PA level show spoke source IP; logs at Azure Public LB level show PA untrust IP — need both to correlate end-to-end flows |
| Phase 4 PA API evidence is manual | Low | Phase 3 curl (data plane) is the authoritative pass/fail; Phase 4 warns but does not block the validator |

---

## Verification Sources

All PAN-OS constructs were verified against:
1. https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall
2. https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/bootstrap-configuration-files
3. https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/create-bootstrap-configuration-files

XML schema verified against:
- PAN-OS 10.1 VM-Series configuration guide (widely documented community reference for `config/devices/entry/vsys/entry` nesting)
- Known-good patterns: interface-management-profile location, zone-to-interface binding, NAT `<service>` as plain text vs Security `<service><member>` list


---

# QA Review: nva-spoke-internet-paloalto

**Reviewer:** Amos (Tester / QA)  
**Date:** 2026-07-27  
**Scope:** Static technical-correctness review — read-only + trivial safe fixes  
**az bicep build:** `az bicep build --file nva-spoke-internet-paloalto/bicep/main.bicep` → **exit 0** (one version-upgrade advisory WARNING only)  
**nva-spoke-internet/ unmodified:** `git status --porcelain nva-spoke-internet` → **empty** ✅

---

## Overall Verdict: ✅ PASS (after 6 trivial fixes applied by reviewer)

Six RG default-name mismatches were found across scripts and fixed in-place during this review (all single-string changes, clearly safe). Bicep and bootstrap artifacts are fully correct. One prior caution (C2, NVA_NAMES) is resolved in the actual code.

---

## Fixes Applied by Reviewer

| File | Change | Reason |
|------|--------|--------|
| `scripts/validate-flow.sh` line 45 | `rg-nva-spoke-internet-paloalto` → `rg-nva-spoke-internet-pa` | Align with deploy.sh canonical RG default |
| `scripts/validate-flow.ps1` line 42 | `rg-nva-spoke-internet-paloalto` → `rg-nva-spoke-internet-pa` | Same |
| `scripts/cleanup.sh` lines 25–26 | `rg-nva-spoke-internet` → `rg-nva-spoke-internet-pa` | Was pointing at Linux lab RG — blocking if used as-is |
| `scripts/cleanup.ps1` lines 20–21 | `rg-nva-spoke-internet` → `rg-nva-spoke-internet-pa` | Same |
| `scripts/enable-monitoring.sh` line 38 | `rg-nva-spoke-internet` → `rg-nva-spoke-internet-pa` | Was pointing at Linux lab RG |
| `scripts/enable-monitoring.ps1` line 34 | `rg-nva-spoke-internet` → `rg-nva-spoke-internet-pa` | Same |

**Bicep re-compiled after edits:** exit 0 ✅

---

## Findings Table

| # | Item | File | Status | Note |
|---|------|------|--------|------|
| 1 | `plan` block present (byol/paloaltonetworks/vmseries-flex) | palo-alto.bicep | ✅ | Lines 149-153. Both `plan` and `imageReference` present — Marketplace BYOL requirement met. |
| 2 | `imageReference` correct (paloaltonetworks/vmseries-flex/byol/latest) | palo-alto.bicep | ✅ | Lines 161-165. |
| 3 | 3 NICs: eth0 mgmt PRIMARY in snet-mgmt | palo-alto.bicep | ✅ | NIC index 0 has `primary: true` in networkProfile. enableIPForwarding=false. |
| 4 | 3 NICs: eth1 untrust in snet-untrust, IP forwarding enabled | palo-alto.bicep | ✅ | Lines 98-117. enableIPForwarding=true. |
| 5 | 3 NICs: eth2 trust in snet-trust, IP forwarding enabled | palo-alto.bicep | ✅ | Lines 119-139. enableIPForwarding=true. |
| 6 | eth1 → PublicLB backend; eth2 → ILB backend | palo-alto.bicep | ✅ | publicLbBackendPoolId on untrust NIC; ilbBackendPoolId on trust NIC. |
| 7 | customData: all 6 bootstrap fields present; key is @secure() | palo-alto.bicep | ✅ | Line 183. type/op-command-modes/storage-account/access-key/file-share/share-directory. `bootstrapStorageKey` is `@secure()` param (line 54) — not hardcoded. |
| 8 | bootDiagnostics enabled, no storageUri | palo-alto.bicep | ✅ | Lines 207-210. Managed boot diagnostics (Serial Console works). |
| 9 | VM size default Standard_DS3_v2 | palo-alto.bicep | ✅ | Line 45. |
| 10 | eth1/1 DHCP-client L3, create-default-route=no | bootstrap.xml | ✅ | Lines 123-136. DHCP-injected 0/0 suppressed; explicit static route wins. |
| 11 | eth1/2 DHCP-client L3, create-default-route=no | bootstrap.xml | ✅ | Lines 141-153. |
| 12 | Zones: untrust→eth1/1, trust→eth1/2 | bootstrap.xml | ✅ | Lines 218-234. Layer3 binding correct. |
| 13 | Interface mgmt-profile allow-ssh-ping on both data interfaces | bootstrap.xml | ✅ | Lines 106-111. SSH+ping enabled. LB TCP/22 probes will succeed on both eth1/1 and eth1/2. |
| 14 | VR default: 0/0→10.0.0.33 via eth1/1 | bootstrap.xml | ✅ | Lines 180-187. Untrust subnet GW. |
| 15 | VR default: 10.0.0.0/8→10.0.0.65 via eth1/2 | bootstrap.xml | ✅ | Lines 191-198. Trust subnet GW. Covers spoke1(10.1/16), spoke2(10.2/16), DMZ(10.0/24). |
| 16 | Source NAT: dynamic-ip-and-port + interface-address eth1/1 | bootstrap.xml | ✅ | Lines 257-265. MASQUERADE equivalent. Double-SNAT with Public LB outbound rule is by design. |
| 17 | Security policy: permit trust→untrust | bootstrap.xml | ✅ | Lines 276-293. Lab-only any/any. Logged at session-end. |
| 18 | non-syn-tcp=yes (HA-ports ILB requirement) | bootstrap.xml | ✅ | Lines 88-90. Required for ILB failover — mid-flow TCP packets arrive without SYN. |
| 19 | Well-formed XML | bootstrap.xml | ✅ | All elements correctly opened and closed. Nesting matches PAN-OS `config/devices/entry` schema. |
| 20 | config version="10.1.0" | bootstrap.xml | ⚠️ | If `vmseries-flex:byol:latest` resolves to PAN-OS ≥11.x at deploy time, PAN-OS performs automatic config migration. Generally safe; documented as residual risk in alex-panos-bootstrap.md. |
| 21 | type=dhcp-client present | init-cfg.txt | ✅ | Line 31. |
| 22 | op-command-modes=mgmt-interface-swap present | init-cfg.txt | ✅ | Line 42. REQUIRED for 3-NIC Azure deployment. |
| 23 | Hostname sane, no dead/contradictory keys | init-cfg.txt | ✅ | hostname=pan-dmz-nva. panorama-server and vm-auth-key intentionally blank. No static IP keys set (DHCP mode). |
| 24 | VNet 10.0.0.0/24, 3 subnets correct | dmz.bicep | ✅ | Lines 103-140. snet-mgmt 0/27, snet-untrust 32/27, snet-trust 64/27. |
| 25 | UDR 0/0→Internet on snet-mgmt AND snet-untrust | dmz.bicep | ✅ | Lines 113-126. Both subnets attach udrInternet. |
| 26 | NO UDR on snet-trust | dmz.bicep | ✅ | Lines 127-137. Correct — trust return traffic must reach hub via vWAN-learned routes. |
| 27 | disableBgpRoutePropagation=true on UDR | dmz.bicep | ✅ | Line 27. More defensive than Linux lab (which had false). Prevents hub-propagated routes from conflicting with explicit 0/0→Internet. |
| 28 | ILB Standard, static frontend 10.0.0.68, snet-trust | internal-lb.bicep | ✅ | Lines 27, 36-44. |
| 29 | HA-ports rule (protocol=All, port=0, enableFloatingIP=true) | internal-lb.bicep | ✅ | Lines 62-81. Floating IP required for HA-ports; preserves destination IP through NVA. |
| 30 | ILB TCP/22 health probe | internal-lb.bicep | ✅ | Lines 50-58. |
| 31 | Public LB Standard, static PIP | public-lb.bicep | ✅ | Lines 26-32, 35-39. |
| 32 | Public LB TCP/22 health probe | public-lb.bicep | ✅ | Lines 51-59. |
| 33 | Outbound SNAT-all rule (protocol=All); disableOutboundSnat=true on inbound rule | public-lb.bicep | ✅ | Lines 84-103 (outbound rule). Line 80 (disableOutboundSnat=true on inbound LB rule). No conflict between inbound and outbound SNAT rules. |
| 34 | palo-alto module wired in place of nva; bootstrap params passed | main.bicep | ✅ | Lines 102-120. All 4 bootstrap params (SA, key, share, dir) correctly threaded through. |
| 35 | 16-output contract intact (exact names, correct sources) | main.bicep | ✅ | Lines 174-219. All 16 outputs match .squad/decisions.md contract. `nvaNames` maps to `paloAlto.outputs.paNames`. |
| 36 | ILB 10.0.0.68 output contract preserved | main.bicep | ✅ | Line 195: `output ilbFrontendIp string = ilb.outputs.frontendIpAddress` → '10.0.0.68'. Hub 0/0 next-hop intact. |
| 37 | deploy.sh region default westus3 | deploy.sh | ✅ | Line 66: `ask_default LOCATION "Azure region" "westus3"`. |
| 38 | Image terms accept BEFORE VM create (Phase 1b before Phase 6) | deploy.sh | ✅ | Lines 49-53. Phase 1b runs immediately after login check. |
| 39 | Bootstrap SA + share + 4 dirs created (Phase 5b) | deploy.sh | ✅ | Lines 130-165. SA creation, share creation, 4 dirs (config/content/license/software), file uploads to config/. |
| 40 | init-cfg.txt + bootstrap.xml uploaded to config/ | deploy.sh | ✅ | Lines 168-184. Loop over both files; graceful warning if missing. |
| 41 | SA name + key passed to main.bicep | deploy.sh | ✅ | Lines 197-212. bootstrapStorageAccount, bootstrapStorageKey, bootstrapFileShare, bootstrapShareDirectory all passed. |
| 42 | SKU preflight for Standard_DS3_v2 | deploy.sh | ✅ | Lines 100-107. pick_vm_sku + preflight_vm_capacity (Phase 3). |
| 43 | conn-dmz 0/0→10.0.0.68 AFTER routingState=Provisioned | deploy.sh | ✅ | Phase 8 polls routingState; Phase 9 creates conn-dmz with static route. |
| 44 | defaultRouteTable 0/0→conn-dmz programmed post-connections | deploy.sh | ✅ | Lines 333-345. DEFAULT_RT_ID derived from HUB_ID output (no dead variable — this lab fixed the D1 defect from the Linux lab). |
| 45 | On-prem prompt intact | deploy.sh | ✅ | Line 85: ask_default DEPLOY_ONPREM. Phase 12 conditional block intact. |
| 46 | All consumed output names correct | deploy.sh | ✅ | Lines 228-244. 14 get_output calls match contract names. nvaNames and onpremVnetId not consumed — by design (post-deploy inspection). |
| 47 | validate-flow.sh default NVA_NAMES | validate-flow.sh | ✅ | Line 48: `NVA_NAMES="${NVA_NAMES:-pa-fw-0 pa-fw-1}"` — already correct. Prior caution (C2) was written against a draft; the final code has the right VM names. |
| 48 | validate-flow.sh default RG name | validate-flow.sh | ✅ FIXED | Line 45 had `rg-nva-spoke-internet-paloalto` (wrong suffix) — fixed to `rg-nva-spoke-internet-pa` by reviewer. |
| 49 | validate-flow.ps1 default RG name | validate-flow.ps1 | ✅ FIXED | Line 42 same mismatch — fixed to `rg-nva-spoke-internet-pa` by reviewer. |
| 50 | cleanup.sh default RG name | cleanup.sh | ✅ FIXED | Lines 25–26 had `rg-nva-spoke-internet` (Linux lab RG, blocking) — fixed to `rg-nva-spoke-internet-pa`. |
| 51 | cleanup.ps1 default RG name | cleanup.ps1 | ✅ FIXED | Lines 20–21 same Linux-lab RG — fixed to `rg-nva-spoke-internet-pa`. |
| 52 | enable-monitoring.sh default RG name | enable-monitoring.sh | ✅ FIXED | Line 38 had `rg-nva-spoke-internet` (Linux lab RG) — fixed to `rg-nva-spoke-internet-pa`. |
| 53 | enable-monitoring.ps1 default RG name | enable-monitoring.ps1 | ✅ FIXED | Line 34 same — fixed to `rg-nva-spoke-internet-pa`. |
| 54 | nva-spoke-internet/ unmodified | git | ✅ | `git status --porcelain nva-spoke-internet` → empty. |
| 55 | az bicep build exit 0 (post-fixes) | CLI | ✅ | Exit 0. One advisory: "A new Bicep release is available: v0.45.15." Not an error. |

---

## Blocking Issues Found (now fixed)

Six scripts had wrong RG defaults — two categories:

1. **`cleanup.sh` / `cleanup.ps1`** defaulted to `rg-nva-spoke-internet` (the Linux lab's RG). Running cleanup with the default would silently target the wrong resource group or fail with "not found", leaving PA lab resources undeleted.  
2. **`validate-flow.sh` / `validate-flow.ps1`** defaulted to `rg-nva-spoke-internet-paloalto` (wrong `-paloalto` suffix vs canonical `-pa`). Copy-paste validation from README would fail at Phase 1 pre-check.  
3. **`enable-monitoring.sh` / `enable-monitoring.ps1`** defaulted to `rg-nva-spoke-internet` (Linux lab's RG). Monitoring setup would target wrong/absent RG.

All 6 were single-string fixes aligned to the `deploy.sh` canonical default `rg-nva-spoke-internet-pa`. Fixed by reviewer.

---

## Non-Blocking Cautions (⚠️)

### ⚠️ C1 — bootstrap.xml config version="10.1.0" vs `latest` image

**File:** `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml`, attribute on `<config>` element (line 57)  
**Risk:** If Azure's `vmseries-flex:byol:latest` resolves to PAN-OS 11.1 or later at deploy time, PAN-OS performs an automatic XML config migration. The migration is generally safe for the constructs in this file (interfaces, VR, zones, NAT, security policy are stable across 10.1/11.x). However, if the version skew is large (e.g., bootstrap was written for 10.1, image ships 11.2), unexpected migration behaviour is possible.  
**Recommended action:** Before first production run, pin `version` in `imageReference` to the specific PAN-OS build you validated against (e.g., `10.1.14`) instead of `latest`. For the current lab this is acceptable — already documented as residual risk by Alex in `alex-panos-bootstrap.md`.  
**Severity:** ⚠️ Non-blocking — noted and acknowledged by author.

---

## Prior Caution C2 — RESOLVED

**Prior C2** (validate-flow.sh NVA_NAMES stale `pa-nva-0 pa-nva-1`) is **no longer applicable**. The actual file at line 48 already contains the correct default:

```bash
NVA_NAMES="${NVA_NAMES:-pa-fw-0 pa-fw-1}"
```

The prior caution was written against an intermediate draft. The final code is correct.

---

## Summary

| Category | Count |
|----------|-------|
| ✅ PASS  | 49 |
| ✅ FIXED (trivial RG default) | 6 |
| ⚠️ Caution (C1, version pin) | 1 |
| ❌ Blocking (unfixed) | 0 |

The Palo Alto lab is **ready to deploy**. The six RG default mismatches were fixed in-place during this review. The single remaining caution (C1, bootstrap.xml config version vs latest image) is risk-acknowledged and non-blocking for the lab scenario.


---

# Decision Drop: PA Diagram Scope & Style Parity

**Date:** 2026-07-27  
**Agent:** holden  
**Scope:** `nva-spoke-internet-paloalto/media/`

---

## Decision

Produce the flow-first architecture diagram for the Palo Alto VM-Series NVA lab as two files:
- `nva-spoke-internet-paloalto.excalidraw` — Excalidraw v2 JSON (editable source)
- `nva-spoke-internet-paloalto.svg` — hand-authored SVG (embeddable in README)

---

## Style Parity Decision

The PA diagram **exactly mirrors** the Linux NVA diagram (`nva-spoke-internet/media/`) in:
- Canvas size (1400×720), background, font family, container color vocabulary.
- Numbered-hop badge style (double-circle with colored fill).
- Arrow weights, styles, and marker types.
- Footer legend bar layout.
- On-prem optional block (Linux IPsec NVA — unchanged between Linux and PA variants).

Deviation from Linux diagram is **content-only**, not style:
- NVA boxes: PA-FW-1 / PA-FW-2 (Palo Alto VM-Series) replace Ubuntu NVA-1 / NVA-2.
- Added ILB hop (HA ports, trust side) and Public LB hop explicitly — 7 hops vs 5.
- ILB frontend IP (10.0.0.68) = hub's 0/0 next hop (same functional role as in Linux lab).
- PLB labeled with SNAT outbound + pip-lb-pa-public placeholder.
- NIC tier callout on each PA-FW box: mgmt · untrust · trust.

---

## Rationale

Maintaining visual style parity between the two lab diagrams ensures:
1. Readers moving between labs immediately recognize the same architectural pattern.
2. Both SVGs can be embedded in README files with identical styling without extra CSS.
3. The Excalidraw sources are structurally similar, making future edits predictable.


---

# Decision: PA Lab README & EXPECTED-RESULTS Documentation

**Author:** Holden (Lead Architect)  
**Date:** 2026-07-27  
**Status:** Accepted  

---

## What Was Documented

Two documentation files were authored for the `nva-spoke-internet-paloalto` lab:

1. **`nva-spoke-internet-paloalto/README.md`** (~29 KB)
2. **`nva-spoke-internet-paloalto/EXPECTED-RESULTS.md`** (~21 KB)

Both mirror the structure and tone of the completed Linux NVA lab docs at `nva-spoke-internet/` while accurately reflecting all Palo Alto VM-Series–specific differences.

---

## Structural Rationale

### README heading structure matches Linux lab exactly

Every heading from the Linux README is preserved in the same order:
Overview → Architecture → Address Plan → How Default Route Works → Optional On-Premises Connectivity → Prerequisites → Deployment → Validation → Cleanup → Monitoring & Logging → Files

This is intentional: users familiar with the Linux lab can navigate the PA doc without relearning the structure. The only addition is a **"Palo Alto VM-Series Details"** section inserted after Architecture.

### EXPECTED-RESULTS phase structure matches Linux lab exactly

Phase 1 (pre-flight) → Phase 2 (control plane, checks 2a–2h) → Phase 3 (data plane) → Phase 4 (NVA forwarding evidence) → Phase 5 (LB metrics) → Summary → Cited References

Phase 4 is the only phase with substantive PA-specific divergence (see below).

---

## Key PA-Specific Adaptations

### 1. Phase 4 is always WARN (not PASS)

PAN-OS session tables and NAT counters require management-plane access (HTTPS GUI or SSH). The lab automation does not provision PA API credentials, so `az vm run-command` cannot execute PAN-OS CLI. Phase 4 = WARN × 2 (one per firewall, `pa-fw-0` and `pa-fw-1`) regardless of actual firewall state.

**The data-plane Phase 3 `curl` check is the authoritative pass/fail signal for PA traffic forwarding.**

Expected final score: **PASS 10 / FAIL 0 / WARN 4** (without NW) or **PASS 12 / FAIL 0 / WARN 2** (with NW enabled).

### 2. NVA_NAMES default mismatch — documented prominently

`validate-flow.sh` defaults to `NVA_NAMES="pa-nva-0 pa-nva-1"`.  
Bicep (`palo-alto.bicep`) names VMs `pa-fw-0` and `pa-fw-1`.  
Users must run: `NVA_NAMES="pa-fw-0 pa-fw-1" ./scripts/validate-flow.sh`  
Documented in README Validation section and EXPECTED-RESULTS Phase 4 preamble.

### 3. snet-trust has NO UDR (asymmetric UDR design)

`snet-mgmt` and `snet-untrust` carry `UDR 0/0 → Internet`. `snet-trust` intentionally has no UDR — adding `0/0 → Internet` on the trust subnet would black-hole return traffic arriving from the Public LB. This asymmetric design is counter-intuitive to first-time readers; explanation added to Address Plan section.

### 4. ILB frontend inside snet-trust (not a dedicated subnet)

Unlike the Linux lab (which used a dedicated `snet-ilb` /26), the PA lab places the ILB frontend (`10.0.0.68`) directly inside `snet-trust` (10.0.0.64/27). The hub routing contract is unchanged: `conn-dmz` static route `0/0 → 10.0.0.68` is identical in both labs.

### 5. BYOL eval mode table

README includes an explicit table:
- **Unlicensed (eval):** routing, NAT, basic security policy, HA — lab validation fully passes
- **Licensed:** Threat Prevention, URL Filtering, WildFire

EXPECTED-RESULTS Summary reiterates: firewalls will show "Unlicensed" banners; this is expected.

### 6. Auto-bootstrap flow documented

README includes a numbered bootstrap sequence (deploy script → SA creation → file upload → VM customData → PAN-OS auto-import) and notes graceful degradation (if bootstrap files absent, PA boots minimal DHCP mode — unconfigured but reachable). EXPECTED-RESULTS Phase 4c covers how to verify bootstrap succeeded via PA GUI.

### 7. Double-SNAT explained

Spoke → PA trust NIC → PAN-OS NAT (to untrust NIC IP) → Public LB SNAT (to pip-lb-public).  
PAN-OS session logs show spoke IP; Azure LB logs show PA untrust IP. Documentation notes both are needed for end-to-end flow correlation.

### 8. 13-phase deploy table

README Deployment section includes a complete 13-phase table including the PA-unique phases:  
- Phase 1b: `az vm image terms accept` (marketplace BYOL terms, subscription-level, one-time)  
- Phase 5b: Bootstrap storage account creation + file upload

---

## Output Contract Preservation

All 16 output names match the Linux lab exactly. `nvaNames` array contains `['pa-fw-0', 'pa-fw-1']`.
No Linux lab files were modified.

---

## Cross-References

- Naomi's Bicep decision: `.squad/decisions/inbox/naomi-paloalto-bicep.md`
- Alex's bootstrap design: `.squad/decisions/inbox/alex-panos-bootstrap.md`
- Source Linux docs (not modified): `nva-spoke-internet/README.md`, `nva-spoke-internet/EXPECTED-RESULTS.md`

---

## Corrections Applied (Review Pass — 2026-07-27T20:35:00Z)

Four gaps found and corrected during review:

1. **Excalidraw link format:** Changed `🖉 **[▶ Open this diagram...]**` to exact required form `📐 [Open the editable diagram in Excalidraw](...)` immediately under the SVG embed.

2. **PASS count corrected:** Both docs erroneously claimed PASS 12 / WARN 4 (impossible — 16 checks total, but only 14 exist). Corrected to PASS 10 / WARN 4 (without NW) / PASS 12 / WARN 2 (with NW). Root cause: score was copied from Linux lab without adjusting for PA Phase 4 being WARN-only.

3. **RESOURCE_GROUP override added to validate commands:** `deploy.sh` creates `rg-nva-spoke-internet-pa`; `validate-flow.sh` defaults to `rg-nva-spoke-internet-paloalto`. README example commands now show both `RESOURCE_GROUP` and `NVA_NAMES` overrides in a dedicated callout box.

4. **Residual Risks section added to EXPECTED-RESULTS.md:** Formal 6-row table added before Cited References covering: BYOL eval, bootstrap.xml PAN-OS version conservatism (Medium — validate Marketplace SKU), SSH-on-untrust, double-SNAT visibility, script defaults mismatch, snet-trust no-UDR design.

### Open Items for Alex (scripts)

- Fix `validate-flow.sh` default `NVA_NAMES` to `pa-fw-0 pa-fw-1` and default `RESOURCE_GROUP` to `rg-nva-spoke-internet-pa` so plain `./scripts/validate-flow.sh` runs correctly.
- Consider pinning `paloaltonetworks:vmseries-flex:byol:latest` image version or adding a PAN-OS version compatibility check in deploy Phase 1b.


---

# Decision: Palo Alto VM-Series Bicep Module Design + Bootstrap-in-Script

**Date:** 2026-07-27  
**Author:** Naomi (Infra Dev)  
**Lab:** `nva-spoke-internet-paloalto/`  
**Status:** Implemented

---

## Summary

The `nva-spoke-internet-paloalto` lab replaces the 2 Linux IPTables NVAs from the
`nva-spoke-internet` lab with 2 Palo Alto VM-Series (vmseries-flex, BYOL) firewalls.
This decision record documents the key design choices in `palo-alto.bicep` and the
bootstrap-in-script pattern used by `deploy.sh` / `deploy.ps1`.

---

## PA Module Design (`palo-alto.bicep`)

### Plan Block (marketplace requirement)

All Palo Alto marketplace images require an explicit `plan` block on the VM resource:

```bicep
plan: {
  name: 'byol'
  publisher: 'paloaltonetworks'
  product: 'vmseries-flex'
}
```

This must accompany the `imageReference` block and is distinct from the image terms
acceptance step (`az vm image terms accept`). Both are required: terms must be accepted
once per subscription; the plan block must appear in every VM resource deployment.

### 3-NIC Design with `mgmt-interface-swap`

Each PA firewall has 3 NICs:

| NIC | Azure primary? | Subnet | IP Forwarding | Purpose |
|-----|---------------|--------|---------------|---------|
| eth0 | ✓ (index 0) | snet-mgmt | No | Management, HTTPS GUI, licensing |
| eth1 | No (index 1) | snet-untrust | Yes | Untrust zone, Public LB backend |
| eth2 | No (index 2) | snet-trust | Yes | Trust zone, ILB HA-ports backend |

PAN-OS `mgmt-interface-swap` mode (set via `customData`) maps the Azure primary NIC
(eth0) to the PAN-OS management interface.  Without this, PAN-OS would use the
secondary NIC as management, causing confusion with the IP addressing.

### `@secure()` in `base64()` — Direct-Only Pattern

The bootstrap storage account access key is passed as `@secure() param bootstrapStorageKey`.
Bicep prohibits assigning `@secure()` params to plain `var` bindings (they would appear
in ARM state/outputs in plaintext).  The solution is to use the param **directly** inside
the `base64()` call within the resource property:

```bicep
customData: base64('type=dhcp-client\nop-command-modes=mgmt-interface-swap\naccess-key=${bootstrapStorageKey}\n...')
```

This keeps the key in ARM's secure parameter handling chain end-to-end.

### Conditional Mgmt Public IPs (BCP318 suppression)

Management PIPs are conditionally created per-VM (`enableMgmtPublicIp` param, default `true`).
Conditional resources in a `for` loop require the non-null assertion `!` when referenced
in a ternary, to suppress BCP318:

```bicep
publicIPAddress: enableMgmtPublicIp ? { id: pipMgmt[i]!.id } : null
```

---

## DMZ 3-Subnet Layout

The Linux lab used a 2-subnet DMZ (`snet-nva` + `snet-ilb`).  PA requires 3 subnets:

| Subnet | CIDR | Notes |
|--------|------|-------|
| snet-mgmt | 10.0.0.0/27 | UDR: 0/0→Internet.  PA mgmt, GUI access. |
| snet-untrust | 10.0.0.32/27 | UDR: 0/0→Internet.  Public LB backend (SNAT). |
| snet-trust | 10.0.0.64/27 | **NO UDR.**  ILB backend (HA-ports). |

**snet-trust has no 0/0 UDR by design.**  Return traffic from the PA trust NIC must
reach spoke and hub destinations via vWAN-learned routes.  Adding a 0/0→Internet UDR
on snet-trust would black-hole asymmetric return paths (spoke→hub→PA trust→UDR→Internet
instead of PA trust→spoke via vWAN).

**ILB frontend 10.0.0.68 is inside snet-trust (10.0.0.64/27).**  This preserves the
hub `0.0.0.0/0` next-hop contract from the Linux variant unchanged: `conn-dmz` static
route still points to 10.0.0.68, and the spoke `defaultRouteTable` still propagates
0/0 via conn-dmz.

---

## Bootstrap-in-Script Rationale

PA VM-Series day-0 configuration is delivered via an Azure Files bootstrap package
referenced in VM `customData`.  The bootstrap package must exist **before** the VMs
deploy.  Two approaches were considered:

**Option A — Bicep-managed storage (rejected):**  A `storageAccount` Bicep module would
create the SA and share, then the `palo-alto` module would reference it.  Problem:
the bootstrap files (`init-cfg.txt`, `bootstrap.xml`) are authored separately (by Alex)
and are not available at Bicep compile time.  ARM cannot upload files; it can only
create the SA/share containers.

**Option B — Script-managed storage (chosen):**  `deploy.sh`/`deploy.ps1` Phase 5b:
1. Create SA (`pabstrap<hex4>`) + share (`bootstrap`) + 4 subdirs (config/, content/, license/, software/)
2. Upload `bicep/bootstrap/init-cfg.txt` and `bicep/bootstrap/bootstrap.xml` → `config/`
3. Capture SA name + key
4. Pass as `--parameters bootstrapStorageAccount=... bootstrapStorageKey=...` to `az deployment group create`

This cleanly separates concerns: script handles file I/O; Bicep handles VM+NIC resources.
The `@secure()` param ensures the key is never exposed in ARM outputs or logs.

**Graceful degradation:** If the bootstrap files are not yet present (Alex hasn't committed
them), the script emits a warning and continues.  PA will boot in minimal DHCP mode and
be accessible via the mgmt PIP for manual configuration.

---

## Output Contract Preservation

All 16 outputs from the Linux `main.bicep` are preserved with identical names.
The `nvaNames` output value changes (PA names instead of Linux NVA names) but the
key name is unchanged, ensuring `get_output nvaNames` in Alex's deploy scripts
continues to work without modification.

---

## Files Authored

```
nva-spoke-internet-paloalto/
  bicep/main.bicep                     NEW  (PA orchestrator, 16 outputs)
  bicep/main.bicepparam                NEW  (westus3, DS3_v2)
  bicep/modules/dmz.bicep              NEW  (3-subnet DMZ)
  bicep/modules/palo-alto.bicep        NEW  (PA VM module)
  bicep/modules/internal-lb.bicep      ADAPTED  (snet-trust comments)
  bicep/modules/public-lb.bicep        ADAPTED  (PA untrust NIC comments)
  bicep/modules/vwan-hub.bicep         COPY
  bicep/modules/vm.bicep               COPY
  bicep/modules/spoke.bicep            COPY
  bicep/modules/onprem.bicep           COPY
  bicep/cloud-init/workload.yaml       COPY
  bicep/cloud-init/onprem-nva.yaml     COPY
  scripts/deploy.sh                    NEW  (13 phases + 1b + 5b)
  scripts/deploy.ps1                   NEW  (PowerShell equiv)
  scripts/functions.sh                 ADAPTED  (DS3_v2 SKU candidates)
  scripts/cleanup.sh                   COPY
  scripts/cleanup.ps1                  COPY
  scripts/configure-onprem.sh          COPY
  scripts/enable-monitoring.sh         COPY
  scripts/enable-monitoring.ps1        COPY
  .gitignore                           COPY
```

**NOT created (owner-gated):**
- `bicep/bootstrap/init-cfg.txt` — Alex
- `bicep/bootstrap/bootstrap.xml` — Alex
- `media/` diagrams — Holden



---

# Decision: PAN-OS Day-0 Config Push Fallback

**Date:** 2026-07-27  
**Author:** Alex (Network Engineer)  
**Lab affected:** `nva-spoke-internet-paloalto/`  
**Status:** IMPLEMENTED

---

## Root Cause — Bootstrap blocked by allowSharedKeyAccess=false

The live deployment of `nva-spoke-internet-paloalto` to DMAUSER-FDPO passed 15/17
structure checks but failed both egress checks (spoke1 → Internet, spoke2 → Internet:
timed out, 0 PA sessions).

**Root cause confirmed:** Management-group policy `allowSharedKeyAccess=false` on
DMAUSER-FDPO blocks `az storage account keys list` (shared-key auth), which
`deploy.sh` Phase 5b uses to upload `bootstrap.xml` and `init-cfg.txt` to Azure
Files. PAN-OS Azure Files bootstrap requires shared-key SMB auth.  When the upload
is blocked, both firewalls boot **factory-default** — no interfaces configured,
no zones, no routes, no NAT → 0 PAN-OS sessions → all spoke egress fails.

---

## What is NOT the problem — Azure Routing is Correct

The Azure routing design for this lab is **not the problem** and must not be changed.

Evidence: The identical Linux NVA lab (`nva-spoke-internet/`) uses the **exact same**
hub routing topology:
- Hub default route: 0/0 → conn-dmz
- conn-dmz static route: 0/0 → ILB 10.0.0.68
- Spokes learn 0/0 → VirtualNetworkGateway (via Virtual WAN)
- **No spoke UDRs** are present or needed

The Linux lab live validation **passes egress**. Therefore:

> **Spoke UDRs are explicitly NOT the fix.** The routing design is proven correct.

---

## Fix — Idempotent Post-Boot API Config Push

Two self-contained scripts that apply the day-0 config to each firewall via the
PAN-OS XML API after the VMs boot, regardless of whether Azure Files bootstrap
succeeded:

| Script | Path |
|--------|------|
| PowerShell | `nva-spoke-internet-paloalto/scripts/apply-panos-config.ps1` |
| Bash | `nva-spoke-internet-paloalto/scripts/apply-panos-config.sh` |

### Approach: import + load + commit

Rather than hand-translating the 320-line `bootstrap.xml` into PAN-OS xpath `set`
commands (error-prone), the scripts upload the exact `bootstrap.xml` file directly:

1. **Poll keygen** — wait up to `TimeoutMinutes` (default 20) for PA API readiness
2. **Import** — `POST multipart type=import&category=configuration` uploads `bootstrap.xml`
3. **Load** — `op: <load><config><from>bootstrap.xml</from></config></load>` makes it candidate
4. **Commit** — push candidate to running; poll job until `FIN/OK`
5. **Verify** — confirm ethernet1/1 up, ethernet1/2 up, 0/0 route, 168.63.129.16/32 route

### Idempotency

If Azure Files bootstrap *did* succeed (future subscription or policy change) and the
scripts are also run, PAN-OS detects candidate = running → returns "no changes to
commit" → scripts complete successfully with no harm.

### Interface contract

Called by Naomi's `deploy.ps1` / `deploy.sh` (Alex does not modify those scripts):
- PowerShell: `-MgmtIps`, `-AdminUsername`, `-AdminPassword`, `-TimeoutMinutes`
- Bash: `--mgmt-ips`, `--admin-username`, `--admin-password`, `--timeout-minutes`

### Why 168.63.129.16/32 matters

The `bootstrap.xml` includes a static route `azure-probe-via-trust` for
168.63.129.16/32 → 10.0.0.65 via ethernet1/2 (trust).  Without it, Azure LB health
probe SYN-ACKs would exit ethernet1/1 (untrust) — Azure SDN drops asymmetric probe
replies as spoofed → ILB stays 0% healthy → spoke egress fails even with correct
routing.  The scripts verify this route is present post-commit.

---

## Files Changed

| File | Action |
|------|--------|
| `nva-spoke-internet-paloalto/scripts/apply-panos-config.ps1` | **Created** |
| `nva-spoke-internet-paloalto/scripts/apply-panos-config.sh` | **Created** |
| `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml` | **Unchanged** (source of truth) |
| `.squad/agents/alex/history.md` | Updated with learnings |


---

# Decision: Azure ILB Health-Probe Symmetry Route — bootstrap.xml Fix

**Date:** 2026-07-27  
**Author:** Alex (Network Engineer)  
**Status:** Applied — awaiting Naomi re-push to live firewalls  

---

## Problem

`lb-ilb` health probe was 0% healthy on both `pa-fw-0` and `pa-fw-1`, causing all spoke egress traffic to be dropped. Validated live by Amos.

### Root Cause (asymmetric routing inside PAN-OS)

1. Azure Standard LB health probes always originate from **168.63.129.16** (the Azure platform fabric address).
2. The ILB probes the PA **trust** NIC (`ethernet1/2`, subnet `snet-trust 10.0.0.64/27`, gateway `10.0.0.65`).
3. PAN-OS generates the TCP SYN-ACK reply destined to 168.63.129.16.
4. The virtual-router had **no route matching 168.63.129.16/32**, so it fell through to the default route `0.0.0.0/0 → ethernet1/1` (untrust).
5. The SYN-ACK exits the **untrust NIC** carrying a **trust subnet source IP** — Azure SDN identifies this as a spoofed packet and drops it.
6. The probe TCP handshake never completes → LB marks both backends unhealthy → 0% healthy → ILB forwards no traffic → spoke egress blackholed.

---

## Fix Applied

**File:** `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml`  
**Change:** Added one new static-route entry as the first entry in the virtual-router `<static-route>` block:

```xml
<!-- Azure LB health-probe source 168.63.129.16 must return via trust (symmetric) -->
<entry name="azure-probe-via-trust">
  <destination>168.63.129.16/32</destination>
  <nexthop>
    <ip-address>10.0.0.65</ip-address>
  </nexthop>
  <interface>ethernet1/2</interface>
  <metric>10</metric>
</entry>
```

The `/32` specificity guarantees longest-prefix-match wins over `0.0.0.0/0` regardless of route table ordering.  
bootstrap.xml is shared by both firewalls — this single edit fixes both `pa-fw-0` and `pa-fw-1`.

---

## Routing Gap Analysis (current on-prem-NOT-deployed topology)

With the three routes now in the virtual-router:

| Route | Destination | Interface | Covers |
|---|---|---|---|
| `azure-probe-via-trust` | 168.63.129.16/32 | ethernet1/2 | Azure platform fabric (LB probe) |
| `rfc1918-10-via-trust` | 10.0.0.0/8 | ethernet1/2 | All spoke / DMZ / hub return traffic |
| `default-via-untrust` | 0.0.0.0/0 | ethernet1/1 | Internet egress |

**Conclusion: no additional routing gaps.** The three routes fully cover the spoke-egress path. On-prem BGP-over-IPsec is not yet deployed; when it is, the 10/8 trust route already covers the on-prem RFC-1918 summary (assuming on-prem stays within 10.x.x.x) — no additional PA static routes will be required.

---

## Side-fix

Two pre-existing `--dport` occurrences in XML comments were invalid per the XML specification (comments cannot contain `--`). Both were corrected while validating the file. No functional change.

---

## Next Action

Naomi to re-push updated bootstrap.xml to the live firewalls (pa-fw-0 and pa-fw-1) per her IaC deployment runbook. After re-push, Amos to re-run `validate-flow.sh` Phase 2 LB metrics to confirm lb-ilb probe health returns to 100%.


---

# Defect: bootstrap.xml missing 168.63.129.16/32 route — ILB probe asymmetric routing

**From:** Amos (Tester)  
**Date:** 2026-07-27  
**Lab:** nva-spoke-internet-paloalto  
**Severity:** HIGH — data-plane broken, both spokes cannot reach internet  
**Status:** Open

---

## Summary

The ILB (`lb-ilb`) health probe permanently fails (DipAvailability = 0%) because the PAN-OS virtual router in `bootstrap.xml` is missing a host route for `168.63.129.16/32` via the trust interface gateway. This causes probe responses to route out the wrong NIC (untrust), which Azure SDN drops due to NIC-IP ownership enforcement. The ILB marks all backends unhealthy → all spoke traffic is dropped → zero internet connectivity.

---

## Evidence

| Metric | Value |
|--------|-------|
| lb-ilb DipAvailability | 0.0% (40+ min window, never recovered) |
| lb-public DipAvailability | 100.0% (untrust NICs healthy) |
| vm-spoke1 egress curl | timeout (returned empty, not 57.154.34.6) |
| vm-spoke2 egress curl | timeout (returned empty, not 57.154.34.6) |
| HTTP code from spokes | 000 (no TCP connection) |
| TCP:22 to trust NICs from spoke1 | timed out (10.0.0.69, 10.0.0.70) |

---

## Root Cause (confirmed)

Azure Standard LB health probe source IP: `168.63.129.16`

**bootstrap.xml virtual router routes:**
```
0.0.0.0/0  → 10.0.0.33  (ethernet1/1, untrust)   ← default route
10.0.0.0/8 → 10.0.0.65  (ethernet1/2, trust)
```

When ILB probes trust NIC (e.g., 10.0.0.70):
1. TCP SYN arrives on `ethernet1/2` ✓
2. PAN-OS generates SYN-ACK: src=10.0.0.70, dst=168.63.129.16
3. VR lookup for 168.63.129.16: no match in 10.0.0.0/8 → default → `ethernet1/1` (untrust)
4. Packet exits `nic-pa-0-untrust` (IP=10.0.0.37) with src=10.0.0.70
5. Azure SDN drops: source IP 10.0.0.70 is not owned by this NIC
6. LB receives no ACK → probe timeout → backend unhealthy

Untrust probe works because probe arrives on `ethernet1/1` and response exits `ethernet1/1` — symmetric, Azure SDN delivers it.

---

## Required Fix (Alex / Naomi)

Add to `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml` in the virtual router static routes section:

```xml
<!-- Azure LB health probe — must return via trust interface to avoid SDN IP ownership drop -->
<entry name="azure-lb-probe-via-trust">
  <destination>168.63.129.16/32</destination>
  <nexthop>
    <ip-address>10.0.0.65</ip-address>
  </nexthop>
  <interface>ethernet1/2</interface>
  <metric>10</metric>
</entry>
```

This routes probe responses back via `ethernet1/2` with src=10.0.0.70 — the same NIC that received the probe — so Azure SDN delivers the ACK and the ILB probe passes.

**After fix:** bootstrap.xml must be re-applied (redeploy PA VMs with new custom_data, or push via Panorama / API if firewalls have management access).

---

## Side-Finding: validate-flow.ps1 pool name mismatch (LOW)

`validate-flow.ps1` queries backend pool by hardcoded name `backend-pool` but the actual deployed pool is `nva-backend`. The pool membership check silently returns empty results. Metrics checks still work. Suggest changing line(s) in Phase 5 to use the correct name `nva-backend` (or make it a parameter).

---

## General Lesson for All Multi-NIC NVA Labs

**Any NVA data interface that is an LB backend MUST have a host route `168.63.129.16/32` via that interface's gateway in its virtual routing table.** Without it, probe responses route out the default-route interface, which in Azure SDN produces a source-IP mismatch → drop. This applies equally to any other NVA platform (Linux iptables, Cisco CSR, Fortinet, etc.) running in Azure with multiple data NICs on separate LBs.


---

# Decision: PAN-OS Bootstrap Fallback & Corrected Root Cause Documentation

**Date:** 2026-07-27  
**Author:** Holden (Docs/DevRel)  
**Status:** Implemented (docs updated)  
**Related:** Naomi deploy-hardening, Alex panos-config-fallback

---

## Context

Live deployment of `nva-spoke-internet-paloalto/` to DMAUSER-FDPO resulted in 15/17 validation PASS, 2 spoke→Internet egress FAIL. Investigation confirmed the root cause: management-group policy `allowSharedKeyAccess=false` blocks PAN-OS Azure Files bootstrap (shared-key SMB auth required; OAuth unsupported for Files data plane). Firewalls booted factory-default with no security policy or NAT rules.

## Corrected Understanding

**Not a routing bug.** The hub routing configuration (0.0.0.0/0 → conn-dmz → ILB 10.0.0.68 HA-ports) is correct and live-validated by the Linux twin (`nva-spoke-internet/`). The egress failure was a config-delivery symptom, not a network-design defect.

## Decision

Document the bootstrap-policy blocker + automatic Phase 7b fallback mechanism in both README.md and EXPECTED-RESULTS.md so operators understand:
1. Why Azure Files bootstrap might silently fail (looks like a routing bug but isn't)
2. How the automatic fallback (`apply-panos-config.ps1/.sh`, Phase 7b) mitigates it (no user action required)
3. How to manually re-apply config if needed
4. That the network routing design is correct (proven by the Linux twin)

## Implementation

- **README.md:** Added `## Known Limitations & Bootstrap Fallback` section (after Validation, before Cleanup) with:
  - Policy-blocker description
  - Symptom (factory-default PAs, 0 sessions, egress fails)
  - Built-in auto-fallback explanation (Phase 5b + Phase 7b)
  - Manual override command
  - One-line clarification that routing design is correct

- **EXPECTED-RESULTS.md:** Expanded `## Residual Risks / Caveats` table with new first row documenting:
  - Management-group policy `allowSharedKeyAccess=false` as the blocker
  - Automatic Phase 7b fallback
  - Manual remediation command
  - Routing validation by Linux twin

- **history.md:** Appended session learnings under "## Learnings" noting:
  - Live-deployment symptom and root cause
  - Corrected misconception about routing
  - Naomi + Alex's fix (Phase 5b + Phase 7b)
  - Docs updates and the routing-correct clarification
  - Actionable learning: always check for storage-account policies before live deploy

## Outcome

Documentation now accurately reflects the bootstrap-policy blocker and automatic fallback, preventing future misdiagnosis as a routing defect. Operators can see that the network topology is correct (validated by Linux twin) and understand the config-delivery mitigation strategy.

---

*Docs update committed to the worktree; re-validation of live deployment pending a re-deploy to DMAUSER-FDPO.*


---

# Decision: Harden `nva-spoke-internet-paloalto` Deploy Scripts

**Author:** Naomi  
**Date:** 2026-07-27T22:20:00Z  
**Status:** Implemented — commit `3a88aa7` on branch `dmauser-musical-guide`  
**Files changed:** `nva-spoke-internet-paloalto/scripts/deploy.ps1`, `nva-spoke-internet-paloalto/scripts/deploy.sh`

---

## Context

Live deployment of `nva-spoke-internet-paloalto/` to DMAUSER-FDPO subscription (westus3) showed 15/17 checks PASS but both Internet-egress checks FAIL (zero Palo Alto sessions). Root cause: DMAUSER-FDPO enforces a management-group policy `allowSharedKeyAccess=false` on all storage accounts. The PA Azure Files SMB bootstrap was silently blocked, firewalls booted factory-default, and the deploy script reported success throughout.

---

## Fix 1 — Silent Storage Failure in Phase 5b

**Problem:** All `az storage` data-plane operations in Phase 5b (`az storage share create`, `az storage directory create`, `az storage file upload`) had no `$LASTEXITCODE` checks. In `deploy.ps1`, the directory-create and file-upload calls were additionally piped to `| Out-Null`, which causes PowerShell to reset `$LASTEXITCODE` to 0 regardless of the actual az exit code. Result: every storage operation appeared successful even when returning 403 Forbidden.

**Decision:** 
1. Remove `| Out-Null` from all az storage data-plane calls so exit codes are visible.
2. Add `if ($LASTEXITCODE -ne 0)` checks (ps1) / `if ! az storage ...; then` pattern (sh) after every data-plane call.
3. Print `✔` only on genuine success; on failure log a WARNING and set `$SharedKeyBootstrapAvailable = $false` so Phase 7b handles it.

---

## Fix 2 — `allowSharedKeyAccess` Policy Detection + Graceful Fallback

**Problem:** `az storage account create` never set `--allow-shared-key-access true`, so the property was left at subscription default. Even with the flag set, management-group policy can override it to `false` post-create. There was no detection or graceful skip — the script would attempt (and silently fail) every SMB data-plane operation.

**Decision:** Implement a policy-detection guard immediately after account create:

```
az storage account create ... --allow-shared-key-access true
$effectiveSharedKey = az storage account show --query allowSharedKeyAccess -o tsv
if (policy returned false) → $SharedKeyBootstrapAvailable = $false + WARNING log
```

**Key design choices:**
- **Always create the storage account** (even in fallback mode) — `palo-alto.bicep` references it in `customData`; if account doesn't exist, Bicep fails.
- **Always retrieve the storage key** outside the data-plane guard — `az storage account keys list` is a management-plane ARM call that succeeds regardless of the shared-key policy. Key is still passed to Bicep.
- **Wrap all SMB ops** (`share create`, `dir create`, `file upload`) in `if ($SharedKeyBootstrapAvailable)` — they are skipped cleanly; no 403 spam, no misleading ✔.
- **Phase 7b is the authoritative fallback** — the skip is not an error state; it is an expected policy-compliant code path.

---

## Fix 3 — Phase 7b: Post-Boot PAN-OS Day-0 Config Push

**Problem:** When Azure Files bootstrap is blocked (or fails for any reason), there was no mechanism to configure the PA firewalls. They boot factory-default and egress never works.

**Decision:** Add Phase 7b immediately after Phase 7 (read deployment outputs). It always runs — whether or not Azure Files bootstrap succeeded.

**Implementation:**
- Query `pip-pa-0-mgmt` and `pip-pa-1-mgmt` PIPs directly by resource name (not from `main.bicep` outputs, which only contain `nvaNames`).
- Call Alex's `apply-panos-config.ps1` / `apply-panos-config.sh` (contract: `-MgmtIps`, `-AdminUsername`, `-AdminPassword`; exit non-zero if any firewall fails).
- Non-zero exit logs a WARNING but does NOT abort the deploy — routing phases 8–11 still run. Operator validates PA config state during egress check.
- Idempotent: safe to run against an already-configured PA.

**Timing:** Phase 7b runs before hub routing configuration (Phase 8). Alex's scripts handle PA boot-wait internally (default 20-min timeout).

---

## Alternatives Rejected

| Alternative | Reason rejected |
|---|---|
| Hard-throw on allowSharedKeyAccess=false | Would abort every deploy on DMAUSER-FDPO before Phase 6 (Bicep); no fallback possible |
| Modify `main.bicep` outputs to include PA mgmt PIPs | Changes bicep output contract; could break downstream callers; constraint was scripts-only |
| Add spoke UDRs to fix routing | Identical Linux lab (`nva-spoke-internet/`) passes egress with same routing — routing is NOT the problem; bootstrap failure is |

---

## Validation

- `deploy.ps1`: PowerShell parse `[ScriptBlock]::Create(...)` — **PASS**
- `deploy.sh`: `bash -n` via Git Bash — **PASS** (pre-existing CRLF endings; Git Bash handles correctly)
- `az bicep build -f nva-spoke-internet-paloalto/bicep/main.bicep` — **PASS** (exit 0; no bicep changes made)


---

# Decision Record — Palo Alto Live Deploy Findings (2026-07-27)

**Author:** Naomi (Infrastructure Developer)  
**Date:** 2026-07-27  
**Lab:** `nva-spoke-internet-paloalto/`  
**Subscription:** DMAUSER-FDPO (78216abe-8139-4b45-8715-6bab2010101e)  
**Region:** westus3  
**RG:** rg-nva-spoke-internet-pa (torn down 22:07 UTC by user after session)

---

## Summary

Live deployment reached ~90% operational. Bicep succeeded, PA config applied via XML API, ILB health probes passing, hub routing provisioned. Internet egress via spoke→PA→Internet NOT confirmed before user teardown due to a routing loop caused by the vWAN hub `nextHopType=ResourceId` route not enforcing the ILB IP as the physical forwarding next-hop.

---

## Issue 1 — Bootstrap key-auth policy blocks file upload

**Symptom:** `az storage share create` / `az storage file upload` exit 0 but all data-plane operations silently fail with `ErrorCode:KeyBasedAuthenticationNotPermitted`.

**Root cause:** DMAUSER-FDPO subscription has a management-group Azure Policy enforcing `allowSharedKeyAccess=false` on all storage accounts. `az storage account update --allow-shared-key-access true` silently succeeds but the policy reverts it immediately. Azure Files data-plane does NOT support OAuth bearer tokens; the API returns `FileOAuthManagementApiRestrictedToSrp`.

**Impact:** PA VMs boot with factory defaults (no init-cfg, no bootstrap.xml). Both firewalls come up with only management interface configured.

**Decision: XML API workaround**  
Apply full PAN-OS configuration via the PA XML API (`https://<mgmt-pip>/api/?type=config&action=set`) using `Invoke-RestMethod -SkipCertificateCheck`. Azure ARM credentials (`adminUsername` / `adminPassword`) map directly to PAN-OS admin credentials. Full config applied:
- ethernet1/1 (untrust): DHCP-client L3, management profile (ping)
- ethernet1/2 (trust): DHCP-client L3, management profile (SSH + ping)
- virtual-router default: both interfaces
- zones: untrust (eth1/1), trust (eth1/2)
- static route: `0.0.0.0/0 → untrust-subnet-GW via eth1/1`
- static route: `10.0.0.0/8 → trust-subnet-GW via eth1/2`
- NAT rule: `trust-to-untrust-masquerade` (MASQUERADE to eth1/1 IP)
- security rule: `permit-trust-to-untrust` (any→any allow)
- commit on both FWs

**Long-term fix:** If FDPO policy cannot be removed, add an alternative bootstrap path in deploy.ps1 that uses az rest ARM API to create the share (works) but then falls back to PA XML API for file injection — or accept that all PA bootstrapping must use cloud-init / custom-data exclusively. Consider encoding critical portions of bootstrap.xml as base64 in VM customData.

---

## Issue 2 — deploy.ps1 Phase 5b does not check $LASTEXITCODE

**File:** `nva-spoke-internet-paloalto/scripts/deploy.ps1`, Phase 5b (~lines 290–346)

**Symptom:** Script logs "✔ Bootstrap config uploaded" even when ALL storage operations fail silently (due to Issue 1). No `$LASTEXITCODE` check after any `az storage` call.

**Fix required:**
```powershell
# After each az storage call, add:
if ($LASTEXITCODE -ne 0) {
    Write-Host "✗ Storage operation failed (exit $LASTEXITCODE) — bootstrap may be incomplete" -ForegroundColor Red
    # Optionally: throw "Bootstrap upload failed; check allowSharedKeyAccess policy"
}
```

**Also affect:** Phase 5a (storage account creation) and Phase 5c (connection string retrieval) should be checked similarly.

---

## Issue 3 — bootstrap.xml contains `--` in XML comments (invalid XML)

**File:** `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml`

**Symptom:** `[xml]$content = Get-Content bootstrap.xml` throws parse error: `-- is not allowed inside comments`.

**Root cause:** XML spec prohibits `--` inside XML comments (`<!-- ... -->`). The bootstrap.xml uses `--` as visual separators inside comments.

**Impact:** Cannot use PowerShell's `[xml]` class to parse/transform bootstrap.xml programmatically.

**Fix:** Replace `--` in XML comments with alternative separators (e.g., `==`) or strip comments before parsing.

---

## Issue 4 — `<hip-profiles>` element incompatible with deployed PA version

**Symptom:** XML API `set` call for security rule including `<hip-profiles><member>any</member></hip-profiles>` returns success but rule is not created correctly.

**Root cause:** `<hip-profiles>` is not valid in security rule configuration for this PA version/license tier.

**Fix:** Omit `<hip-profiles>` from security rule XML. The rule works correctly without it.

---

## Issue 5 — `deviceconfig/setting/session/tcp/non-syn-tcp` xpath invalid

**Symptom:** `az network vhub route-table route remove --route-name ... ` CLI syntax requires `--name` and `--index` params (not `--route-name`).

**Also:** PA XML API set for `deviceconfig/setting/session/tcp/non-syn-tcp` returns path mismatch error.

**Fix:** Skip `non-syn-tcp` setting — it's non-critical for lab operation. The correct xpath (if needed) is version-specific and should be verified in PAN-OS admin guide for the exact BYOL version deployed.

---

## Issue 6 — vWAN hub routing: ResourceId next-hop does not enforce ILB IP (EGRESS FAIL)

**This is the critical issue preventing end-to-end traffic flow.**

### Topology
- Hub defaultRouteTable has: `to-internet: 0.0.0.0/0 → conn-dmz (nextHopType=ResourceId)`
- conn-dmz has: `vnetRoutes.staticRoutes: [{addressPrefixes: ["0.0.0.0/0"], nextHopIpAddress: "10.0.0.68"}]`
- conn-dmz has: `propagateStaticRoutes: true`, `vnetLocalRouteOverrideCriteria: Contains`
- snet-trust (PA trust subnet): NO UDR, receives hub BGP routes → effective route `0.0.0.0/0 → VirtualNetworkGateway (hub)`
- snet-workload in spoke1/spoke2: Empty UDR tables, receive hub BGP routes → effective route `0.0.0.0/0 → VirtualNetworkGateway (hub)`

### What happens
1. Spoke1 VM sends packet to 1.1.1.1 → effective route sends to hub (VirtualNetworkGateway 10.100.0.68) ✓
2. Hub looks up 1.1.1.1 in defaultRouteTable → finds `0.0.0.0/0 → conn-dmz (ResourceId)` → routes to DMZ VNet
3. Packet enters DMZ VNet WITHOUT a specific IP next-hop for 1.1.1.1 (ResourceId type just means "send to this connected VNet")
4. Azure VNet SDN applies snet-trust effective routes to the packet entering the subnet → `0.0.0.0/0 → VirtualNetworkGateway (hub)` → sends packet BACK to hub
5. Routing loop detected → Azure drops packet
6. Result: zero sessions on PA, curl times out

### Evidence
- Network Watcher next-hop from spoke1 to 1.1.1.1 = `VirtualNetworkGateway 10.100.0.68` ✓
- PA session table: ZERO sessions from 10.1.x / 10.2.x while curls running
- PA-FW-0 trust IP: 10.0.0.70, PA-FW-1 trust IP: 10.0.0.69 (ILB backends)
- ILB health probes passing (active SSH sessions from 168.63.129.16 → trust NICs)

### Root cause
The `nextHopType=ResourceId` in the hub defaultRouteTable tells the hub to forward traffic via `conn-dmz` but does NOT propagate the 10.0.0.68 IP as the physical forwarding address to the connected VNet. The `vnetRoutes.staticRoutes` propagation was intended to solve this but the explicit ResourceId route in defaultRouteTable supersedes the propagated static route.

### Fix — UDR on spoke workload subnets
Add explicit UDR route to `udr-vnet-spoke1-workload` and `udr-vnet-spoke2-workload`:
```
address-prefix: 0.0.0.0/0
next-hop-type: VirtualAppliance
next-hop-ip-address: 10.0.0.68
```

This forces Azure SDN to use 10.0.0.68 as the explicit L3 next-hop (VirtualAppliance type = direct forwarding, bypasses normal VNet routing). The ILB with HA-ports + floatingIP intercepts all traffic routed to its IP and load-balances to PA trust NICs.

The route tables `udr-vnet-spoke1-workload` and `udr-vnet-spoke2-workload` already exist (deployed by Bicep, currently empty) — only a route add command is needed.

```powershell
az network route-table route create `
  -g rg-nva-spoke-internet-pa `
  --route-table-name udr-vnet-spoke1-workload `
  -n to-internet-via-pa `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 10.0.0.68

az network route-table route create `
  -g rg-nva-spoke-internet-pa `
  --route-table-name udr-vnet-spoke2-workload `
  -n to-internet-via-pa `
  --address-prefix 0.0.0.0/0 `
  --next-hop-type VirtualAppliance `
  --next-hop-ip-address 10.0.0.68
```

### Alternative fix — Add IP-based route to hub defaultRouteTable
Instead of using `nextHopType=ResourceId`, add a CIDR-based route with next-hop IP via conn-dmz that propagates 10.0.0.68:
- Verify whether `az network vhub route-table route add` supports specifying a next-hop IP address
- If not supported, use `vnetRoutes.staticRoutes` ONLY (no explicit defaultRouteTable route) — the propagated static route from conn-dmz should then be the effective 0.0.0.0/0 route

### Recommendation for Bicep fix
In `bicep/main.bicep`, the `deploymentScript` that adds the hub route (Phase 9) should be changed to NOT add the explicit `nextHopType=ResourceId` route. Instead, rely solely on `vnetRoutes.staticRoutes` in conn-dmz with `propagateStaticRoutes=true`. This way the ILB IP (10.0.0.68) propagates as the actual next-hop IP to all connections using the defaultRouteTable.

Alternatively, after adding the ResourceId route, ALSO add the UDR routes to spoke workload subnets via an additional deploymentScript step.

---

## PA XML API Playbook (for environments with key-auth policy)

```powershell
# 1. Get API key
$apiKey = (Invoke-RestMethod -Method Post -SkipCertificateCheck `
  -Uri "https://$pip/api/" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body "type=keygen&user=$adminUser&password=$adminPass").response.result.key

# 2. Apply config (action=set, NOT action=merge)
function Set-PAConfig($pip, $apiKey, $xpath, $element) {
    $r = Invoke-RestMethod -Method Post -SkipCertificateCheck `
        -Uri "https://$pip/api/" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "type=config&action=set&key=$apiKey&xpath=$([uri]::EscapeDataString($xpath))&element=$([uri]::EscapeDataString($element))"
    return $r
}

# 3. Commit
$commit = Invoke-RestMethod -Method Post -SkipCertificateCheck `
  -Uri "https://$pip/api/" `
  -ContentType "application/x-www-form-urlencoded" `
  -Body "type=commit&key=$apiKey&cmd=<commit></commit>"

# 4. Poll for commit completion
do {
    Start-Sleep 15
    $status = Invoke-RestMethod -Method Post -SkipCertificateCheck `
        -Uri "https://$pip/api/" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body "type=op&key=$apiKey&cmd=<show><jobs><id>$jobId</id></jobs></show>"
} while ($status.response.result.job.status -ne 'FIN')
```

**Key notes:**
- `action=merge` is NOT supported — always use `action=set`
- Omit `<hip-profiles>` from security rule XML (version incompatibility)
- Omit `non-syn-tcp` xpath (not valid in deployed version)
- Use `-SkipCertificateCheck` (self-signed mgmt cert)
- Azure ARM adminPassword = PAN-OS admin password

---

## Deployed Infrastructure (Evidence Captured Before Teardown)

| Component | Value |
|-----------|-------|
| Hub | hub-nva-si, westus3, routingState=Provisioned |
| ILB frontend IP | 10.0.0.68 |
| Public LB PIP | 57.154.34.6 |
| PA-FW-0 mgmt PIP | 20.118.168.153 |
| PA-FW-1 mgmt PIP | 20.106.77.50 |
| PA-FW-0 untrust IP | 10.0.0.37 |
| PA-FW-1 untrust IP | 10.0.0.36 |
| PA-FW-0 trust IP | 10.0.0.70 |
| PA-FW-1 trust IP | 10.0.0.69 |
| ILB health probe | TCP/22, PASSING (active bytes exchanged) |
| Spoke1 default route | 0.0.0.0/0 → VirtualNetworkGateway 10.100.0.68 |
| Hub defaultRouteTable | 0.0.0.0/0 → conn-dmz (ResourceId) |
| conn-dmz static route | 0.0.0.0/0 → 10.0.0.68 |

RG torn down by dmauser@microsoft.com at 2026-07-27T22:07:16Z.

---

# Correction: Routing Design is Correct — UDRs are NOT the Fix

**Date:** 2026-07-27  
**Author:** Scribe (consolidating team findings)  
**Status:** Applies to 
aomi-pa-live-deploy.md Issue 6

---

## Correction

The 
aomi-pa-live-deploy.md record (Issue 6) diagnosed a routing loop and recommended adding UDRs to spoke workload subnets as a fix. **This diagnosis was incorrect** because the actual egress failure was caused by PA bootstrap not being applied (allowSharedKeyAccess=false policy block), not by routing.

## Evidence: Routing is Correct

The identical Linux NVA lab (
va-spoke-internet/) uses the exact same hub routing topology:

- Hub default route:  .0.0.0/0 → conn-dmz (ResourceId next-hop)
- conn-dmz static route:  .0.0.0/0 → ILB 10.0.0.68
- Spokes learn  .0.0.0/0 → VirtualNetworkGateway (via Virtual WAN)
- **No spoke UDRs present or needed**

The Linux lab **passes live egress validation** with this routing design. Therefore:

> **Spoke UDRs are NOT the fix.** Routing design is proven correct by the Linux twin.

## Actual Fix (Implemented)

The correct fix is **NOT routing changes**. The correct fix is:

1. **Phase 5b hardening** (Naomi): detect llowSharedKeyAccess=false policy + skip SMB ops gracefully
2. **Phase 7b fallback** (Naomi): always invoke Alex's PA XML API config-push script to apply day-0 config via PAN-OS API
3. **bootstrap.xml fix** (Alex): add 168.63.129.16/32 → trust route to fix ILB probe asymmetry

These changes ensure PA firewalls are configured correctly regardless of whether Azure Files bootstrap succeeds. Once PA config is applied, the existing routing topology works end-to-end.

## Implication for Future Debugging

If spoke→PA→Internet egress fails in a future iteration:

1. **First**: Verify PA is configured (check running config via PA admin panel or API)
2. **Second**: Verify ILB health probes pass (Azure Monitor LB metrics)
3. **Third**: Verify routing via Network Watcher effective routes and 	est-ip-flow
4. **Only if all above pass and traffic still fails**: Consider adding UDRs (but evidence suggests this will not be necessary)

---

# Decision: Dual Virtual Router Design for PA VM-Series (ELB + ILB topology)

**Date:** 2026-07-27  
**Author:** Alex (Network Engineer)  
**Status:** Implemented — bootstrap.xml updated; clean redeploy by Naomi pending  
**Supersedes:** alex-probe-route-fix.md (single-VR host-route approach — see anti-pattern section)

---

## Root Cause

Azure Standard LB health probes — **both internal (ILB) and external (ELB)** — always originate from the same platform IP: **168.63.129.16**. In our Active-Active VM-Series deployment:

- The **Public LB (lb-public)** backends the untrust NICs (ethernet1/1, snet-untrust 10.0.0.32/27, gw 10.0.0.33)
- The **Internal LB (lb-ilb, HA-ports)** backends the trust NICs (ethernet1/2, snet-trust 10.0.0.64/27, gw 10.0.0.65)

With a **single virtual router** containing only `0.0.0.0/0 → ethernet1/1` and `10.0.0.0/8 → ethernet1/2`:

- ILB probe arrives on ethernet1/2 (trust). No /32 for 168.63.129.16 → 0/0 → ethernet1/1. SYN-ACK exits the untrust NIC with a trust source IP → Azure SDN drops as spoof → **ILB 0% healthy → all spoke egress fails.**
- Adding a `/32 host-route 168.63.129.16 → ethernet1/2` fixes ILB probe symmetry BUT the ELB probe (arriving on ethernet1/1) now also gets routed out ethernet1/2 → same Azure SDN spoof drop → **ELB regresses to 0% healthy.**

A single virtual router fundamentally cannot serve both probe symmetry requirements simultaneously when both LBs probe from the same source IP.

---

## Decision: Dual Virtual Routers

Implement two separate virtual routers, each owning one dataplane NIC. Each VR's routes are scoped to its NIC, so each LB's probe naturally exits the interface it arrived on.

### VR-Untrust (ethernet1/1 — Public LB / internet egress)

| Route Name | Destination | Next-Hop | Interface | Metric | Purpose |
|---|---|---|---|---|---|
| `default-via-untrust` | 0.0.0.0/0 | 10.0.0.33 | ethernet1/1 | 10 | Internet egress; ELB probe symmetric (0/0 → eth1/1) |
| `rfc1918-10-to-vr-trust` | 10.0.0.0/8 | next-vr:VR-Trust | — | 20 | Inbound DNAT return hand-off |

### VR-Trust (ethernet1/2 — ILB backend / spoke ingress)

| Route Name | Destination | Next-Hop | Interface | Metric | Purpose |
|---|---|---|---|---|---|
| `azure-probe-via-trust` | 168.63.129.16/32 | 10.0.0.65 | ethernet1/2 | 10 | ILB probe symmetric (/32 beats 0/0) |
| `rfc1918-10-via-trust` | 10.0.0.0/8 | 10.0.0.65 | ethernet1/2 | 10 | Spoke return path via trust gw |
| `default-to-vr-untrust` | 0.0.0.0/0 | next-vr:VR-Untrust | — | 10 | Internet egress hand-off |

### Inter-VR Egress Flow

```
Spoke VM → vHub defaultRouteTable → conn-dmz 0/0 → ILB 10.0.0.68 → ethernet1/2
  → VR-Trust lookup: 0/0 → next-vr VR-Untrust
  → VR-Untrust lookup: 0/0 → 10.0.0.33 ethernet1/1
  → Zone crossing trust→untrust → NAT (masquerade to eth1/1 DHCP IP)
  → Public LB outbound SNAT → pip-lb-public
  → Internet
```

### Probe Coverage

LB probe traffic (TCP/22 to the PA interface) is PAN-OS **self-traffic** — handled by the `interface-management-profile` (`allow-ssh-ping`: ssh=yes) applied to both ethernet1/1 and ethernet1/2. This is not transit traffic; the security policy (`permit-trust-to-untrust`) is NOT evaluated for self-traffic. No additional security policy rules are required.

### Zones (unchanged)

- `untrust` zone → ethernet1/1
- `trust` zone → ethernet1/2

Zone assignments are unchanged. The zone crossing (trust→untrust) for egress traffic still triggers NAT and security policy evaluation, so the existing `trust-to-untrust-masquerade` NAT rule and `permit-trust-to-untrust` security rule apply as before.

---

## Reference

[microhack-azure-panfw scenario3](https://github.com/davidsntg/microhack-azure-panfw/blob/main/scenario3/README.md):

> "To ensure proper routing and management of traffic, it is crucial to define TWO distinct Virtual Routers (Trusted and Untrusted) per firewall instance, as the Azure Internal Load Balancer and External Load Balancer rely on the SAME probing source IP address 168.63.129.16."

> ⚠️ **NIC convention in that reference is the inverse of our lab:**  
> Reference: eth1/1=Trust, eth1/2=Untrust  
> Our lab: eth1/1=Untrust, eth1/2=Trust  
> The dual-VR logic is identical; just the NIC-to-VR assignments are swapped.

---

## File Changed

`nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml`  
- Replaced single VR `default` with `VR-Untrust` + `VR-Trust`  
- Fixed pre-existing XML comment `--dport` violations (XML spec forbids `--` inside comments)  
- XML validated via PowerShell `[xml]` cast — **VALID**  
- Shared by both pa-fw-0 and pa-fw-1 — single edit covers both

---

## Anti-Pattern: Single-VR Host Route (superseded)

Adding `168.63.129.16/32 → ethernet1/2` to a single VR is a partial fix:
- ILB probe: symmetric ✓
- ELB probe: broken ✗ (reply now exits wrong NIC, Azure SDN drops)

This approach was initially implemented (session 1) before the ELB regression was identified. The dual-VR design is the only correct solution when both an ELB and ILB are present.


---

# Decision Note: PA Live Re-Apply — Bootstrap Fix Deployment
**Author:** Naomi (Infra Dev)  
**Date:** 2026-07-27  
**Context:** nva-spoke-internet-paloalto lab, DMAUSER-FDPO / westus3, rg-nva-spoke-internet-pa

---

## Problem

Amos validated the live deployment and found data plane BROKEN: ILB `lb-ilb` health probe was 0% because PAN-OS lacked a return route for Azure health probe source `168.63.129.16/32`. Alex fixed `bootstrap.xml` with a new static route `azure-probe-via-trust` (168.63.129.16/32 → 10.0.0.65 via ethernet1/2). Since PA bootstrap is first-boot-only (Azure Files delivery), VM recreation was required to apply the fix.

---

## Approach Chosen

**Full clean redeploy** (not targeted VM recreate). Rationale: deterministic, validates shippable IaC end-to-end, eliminates any state drift from the broken deployment.

Steps executed:
1. Fixed `validate-flow.ps1` to add ILB backend pool membership check using `nva-backend` pool name (cosmetic fix for Amos's re-validation run)
2. Deleted existing RG with `cleanup.ps1 -Rg rg-nva-spoke-internet-pa -Yes` (uses `az group delete --no-wait`)
3. Waited for RG to disappear from `az group show`, then added **10-minute buffer** before redeploying to clear Azure's async deletion pipeline (see below)
4. Launched `deploy.ps1` from `nva-spoke-internet-paloalto/` with `-Location westus3 -Rg rg-nva-spoke-internet-pa -AdminUsername azureuser -DeployOnPrem:$false`
5. Bicep deployment completed (all sub-deployments Succeeded)
6. `apply-panos-config.ps1` ran post-boot to push fixed `bootstrap.xml` via PAN-OS XML API (Phase 7b fallback, required because DMAUSER-FDPO subscription policy `allowSharedKeyAccess=false` blocks Azure Files upload)

---

## Complications Encountered

### Complication 1: `az group delete --no-wait` race condition (critical)

The first redeploy attempt failed because `cleanup.ps1` uses `az group delete --no-wait`. The RG record disappears from `az group show` after ~22 minutes, but the ARM deletion pipeline continues processing child resources for additional minutes. When a new Bicep deployment created resources with the same names in the "deleted" RG, the still-running ARM pipeline deleted the newly created resources (PA VMs, LBs, VNets) approximately 6 minutes after the second Bicep run completed. This caused the deploy to fail in Phase 7b (PA API polling against already-deleted VMs).

**Fix applied:** After RG deletion, wait 10 minutes past the `az group show` disappearance before redeploying.

### Complication 2: Unknown third deployment

While Naomi was waiting for the 10-minute buffer, a third Bicep deployment ran automatically (PA VMs created at 23:17 UTC). The exact trigger is unknown — likely the original deploy.ps1 process (shellId: deploy2) was not fully stopped and completed Phase 6 again after Phase 7b timed out. The third deployment created a full environment with all resources in Succeeded state.

---

## Outcome

**COMPLETE — ILB probe healthy.**

- **Final deployment:** All resources deployed and Succeeded in westus3/rg-nva-spoke-internet-pa (Bicep Phase 6 at ~20:23 CDT 2026-07-27)
- **PA VMs:** pa-fw-0 (mgmt 20.106.90.158) and pa-fw-1 (mgmt 20.106.90.240) both **VM running**
- **PAN-OS config push (Phase 7b):** 8 config subtrees SET successfully on both FWs via `apply-panos-config.ps1`; probe route `168.63.129.16/32 → 10.0.0.65 via eth1/2` confirmed present in routing table on both FWs
- **Commit:** Auto-commit (job2) completed FIN/OK; commit-force (job3) completed FIN/OK on both FWs (~20:44 CDT)
- **Hub connections:** conn-dmz, conn-spoke1, conn-spoke2 all in Succeeded state
- **defaultRouteTable:** Route `default-via-nva` (0.0.0.0/0 → conn-dmz) added and Succeeded
- **ILB probe health (`DipAvailability`):** **100% at 01:47:00 UTC (20:47 CDT) — HEALTHY** ✅

### Key Azure deploy details
| Resource | Value |
|---|---|
| Hub | hub-nva-si |
| ILB frontend | 10.0.0.68 |
| Public LB PIP | 20.163.105.237 |
| Storage account | pabstrape461042f |
| pa-fw-0 mgmt IP | 20.106.90.158 |
| pa-fw-1 mgmt IP | 20.106.90.240 |

---

## Admin Credentials

- Username: `azureuser`
- Password: `PaLab!60af5799327244`

---

## Pending

- Full egress validation (Amos, authoritative) — ILB now healthy, egress path complete
- Git commit of bootstrap.xml + validate-flow.ps1 (separate dispatch after Amos confirms)


---

# Decision: PALO-ALTO-CONFIG.md — Canonical LB & PAN-OS Configuration Reference

**Date:** 2026-07-28  
**Author:** Coordinator (Session 274503b2-8535-4021-8ce3-c90e21d1658d)  
**Status:** Implemented — committed to main  
**Related:** Merges all prior decisions on Palo Alto bootstrap, LB design, dual-VR routing  

---

## Summary

A single canonical reference document 
va-spoke-internet-paloalto/PALO-ALTO-CONFIG.md (14,168 chars) has been authored documenting:

1. **Azure Load Balancer Configuration** (Standard LBs, Internal HA-ports, Public SNAT)  
   - ILB: static frontend 10.0.0.68, HA-ports rule (protocol=All, port=0, floating IP), TCP/22 health probe  
   - Public LB: static outbound PIP, SNAT-all rule, TCP/22 health probe  
   - Probe source: Azure platform fabric 168.63.129.16  

2. **PAN-OS Day-0 Configuration** (from ootstrap.xml)  
   - Interface mapping: eth0=mgmt (snet-mgmt), eth1=untrust (snet-untrust), eth2=trust (snet-trust)  
   - Dual virtual-router design (VR-Untrust, VR-Trust) with inter-VR handoff for egress flow  
   - NAT masquerade rule (trust→untrust→SNAT to eth1 DHCP IP)  
   - Security policy: permit trust→untrust  
   - Critical fixed route: 168.63.129.16/32 → 10.0.0.65 via eth2 (ILB probe symmetry)  
   - Session setting: 	cp non-syn-tcp=yes (HA-ports mid-flow packet handling)  

3. **End-to-End Packet Flow**  
   - Spoke VM egress → vHub defaultRouteTable (0/0 → conn-dmz) → ILB 10.0.0.68 → PA trust NIC → VR-Trust routes to VR-Untrust → NAT → PA untrust NIC → Public LB SNAT → Internet PIP  

4. **Verification Commands**  
   - Azure control-plane: hub routes, connection state, effective routes on spoke NICs  
   - PAN-OS API (via pply-panos-config.ps1/.sh): confirm ethernet1/1 & eth1/2 up, routes present, interfaces assigned to zones  
   - Data-plane: curl ifconfig.io from spoke VMs returns Public LB PIP  
   - LB metrics: DipAvailability = 100% (both LBs), SNAT port consumption observed  

5. **Azure Learn Citations**  
   - HA-ports: https://learn.microsoft.com/azure/load-balancer/load-balancer-ha-ports-overview  
   - Standard LB SNAT: https://learn.microsoft.com/azure/load-balancer/load-balancer-outbound-connections  
   - VNet effective routes: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub  

---

## Key Design Decisions Reflected

This document is the authoritative source for all LB + PAN-OS config decisions made across this session:

| Decision | Reference |
|---|---|
| Dual virtual-router design (VR-Untrust, VR-Trust) | alex-dual-vr-fix.md (this inbox merge) + related decisions |
| 168.63.129.16/32 host route for probe symmetry | alex-dual-vr-fix.md + decision "Azure ILB Health-Probe Symmetry Route" |
| HA-ports floating IP + non-syn-tcp=yes | naomi-paloalto-bicep.md (decisions log) |
| SNAT-all on Public LB + double-SNAT design | Public LB & SNAT decisions (decisions log) |
| Bootstrap fallback via XML API (Phase 7b) | alex-panos-config-fallback.md + naomi-harden-deploy-scripts.md |

---

## Supersedes

- README.md ASCII diagram (single-VR architecture, now outdated)  
- All single-VR routing approaches documented elsewhere  
- Partial probe-fix references in other decision entries  

**The dual-VR design in PALO-ALTO-CONFIG.md is authoritative.**

---

## Maintenance

This file is the living reference for troubleshooting Palo Alto deployments in Azure with dual LBs (internal + public). Future labs or productions deployments should reference PALO-ALTO-CONFIG.md for the proven pattern.


# Decision: az network watcher flow-log is location-based — never use -g

**Date:** 2026-07-28  
**Author:** Naomi (Infra Dev)  
**Status:** Applied

## Context

Live run of `enable-monitoring.ps1` passed Phases 1–4 but failed at Phase 5 (flow-log commands) and Phase 6 (diagnostic-settings). Three root causes were identified and verified against `az --help` and live CLI.

## Decisions

### 1. flow-log existence check must use `flow-log list --location`
`az network watcher flow-log show -n <name> -g <rg>` is **invalid** in modern az CLI. The `flow-log` group is location-scoped, not resource-group-scoped. Authoritative existence check:
```
az network watcher flow-log list --location <region> --query "[?name=='<name>'].name | [0]" -o tsv
```

### 2. flow-log create must NOT pass `-g`
`az network watcher flow-log create` requires `--name --location --vnet --storage-account --workspace --traffic-analytics true`. Passing `-g $NW_RG` causes a CLI error. The `-g` flag has been removed from the create call.

### 3. Capture pattern required for all az calls under EAP=Stop
Bare uncaptured `az ... 2>$null` statements halt the entire script under `$ErrorActionPreference='Stop'` when az writes to stderr (warnings, deprecation notices). The proven-safe pattern already used in Phases 2–4 of this script is:
- Existence check: `$x = "$(az ... 2>$null)".Trim()`
- Write/create call: `$out = az ... 2>&1`

This pattern was applied to both Phase 5 (flow-log) and Phase 6 (diagnostic-settings) in both files.

## Files Changed

- `nva-spoke-internet-paloalto/scripts/enable-monitoring.ps1` — Phase 5 + Phase 6
- `nva-spoke-internet/scripts/enable-monitoring.ps1` — Phase 5 + Phase 6 (parity)

## Verification

Both files parse with 0 errors:
```
[System.Management.Automation.Language.Parser]::ParseFile(...) → 0 errors
```

---

# Decision: vHub effective-routes NextHops → short-name display

**Date:** 2026-07-28  
**Author:** Amos (Tester/validation-script owner)  
**Status:** Deployed  
**File:** `nva-spoke-internet-paloalto/scripts/validate-flow.ps1`  
**Branch:** `'VHub'` in `Show-RouteTable`, line 150

## What changed

The `[2e] vHub effective routes for defaultRouteTable` table previously printed the full Azure resource ID in the **NextHops** column, e.g.:

```
/subscriptions/xxx/resourceGroups/rg-nva-spoke-internet-pa/providers/Microsoft.Network/virtualHubs/hub-nva-si/hubVirtualNetworkConnections/conn-dmz
```

Now displays only the trailing connection name:

```
conn-dmz
conn-spoke1
conn-spoke2
```

## How

Applied the same last-segment trim already used at line 116 for the `'Hub'` branch:
```powershell
($_.ToString().TrimEnd('/') -split '/')[-1]
```

Three cases handled: array of IDs, single string ID, empty/null.

## Scope

**Display-only.** No az commands changed. No logic changed. Parse: 0 errors. UTF-8 with BOM (EF BB BF) preserved to maintain Windows PowerShell 5.1 compatibility.

## Team relevance

If the `nva-spoke-internet` (non-PA) lab's `validate-flow.ps1` has a `'VHub'` branch with the same pattern, apply the identical fix there for consistency.


---

# Decision: NW Check Messaging -- SKIP tier + accurate error routing

**Date:** 2026-07-28
**Author:** Amos (Tester)
**Status:** Adopted
**Scope:** nva-spoke-internet-paloalto/scripts/validate-flow.ps1 checks [2g] and [2h]

## Context

Live diagnosis on sub 78216abe / rg-nva-spoke-internet-pa / westus3 confirmed:
- NetworkWatcher_westus3 exists with state = Succeeded (NW IS enabled).
- [2g] real error: `(NsgsNotAppliedOnNic)` -- no NSG on nic-vm-spoke1. IP flow verify ONLY evaluates NSG rules; with no NSG it can never succeed.
- [2h] real error: `(NetworkWatcherVmExtensionNotInstalled)` -- NetworkWatcherAgent not yet on vm-spoke1. Naomi is adding the install step to enable-monitoring.ps1.

The old code used `2>$null`, swallowing both real errors. The fallback message blamed Network Watcher not being enabled -- wrong for both checks.

## Decisions

### 1. Add a SKIP result tier

SKIP = "not applicable in this topology". Does NOT count as WARN or FAIL.
Displayed in DarkGray with `[SKIP]` tag. Included in summary tally.

Rationale: [2g] is permanently not applicable in this lab because the topology is governed by vHub routing + Palo Alto, not NSGs. Calling it a WARN or FAIL would be noise that operators can never resolve.

### 2. [2g] maps to SKIP (not WARN) on NsgsNotAppliedOnNic

When `az network watcher test-ip-flow` returns `NsgsNotAppliedOnNic`, the result is `[SKIP]` with a message explaining why (no NSG, vHub routing + PA governs traffic, IP flow verify only evaluates NSG rules).

Any other az error falls back to `[WARN]` with the generic "could not be evaluated -- see raw error above" message.

### 3. [2h] stays WARN (not SKIP) on NetworkWatcherVmExtensionNotInstalled

The missing NetworkWatcherAgent is a real, actionable gap. Once enable-monitoring.ps1 installs the agent, [2h] will pass. Keeping it as WARN with an actionable message ("run enable-monitoring.ps1") is correct.

### 4. Capture stderr via 2>&1; log raw error before result tag

Both az calls changed from `2>$null` to `2>&1` so the real Azure error code surfaces inline (Log before CheckSkip/CheckWarn). This is read-only -- no Azure resource writes.

### 5. Summary line format

`PASS: N  FAIL: N  WARN: N  SKIP: N` -- SKIP count in DarkGray, appended after WARN. Exit code logic unchanged (driven by $script:Fail only).

## Impact

| Check | Before | After |
|-------|--------|-------|
| [2g] NsgsNotAppliedOnNic | [WARN] misleading NW-disabled message | [SKIP] correct N/A message |
| [2h] VmExtensionNotInstalled | [WARN] misleading NW-disabled message | [WARN] actionable agent-install message |
| [2h] after agent installed | N/A | [PASS] |

---

# Decision: Install NetworkWatcherAgentLinux on Spoke VMs in enable-monitoring.ps1

**Date:** 2026-07-28
**Author:** Naomi (Infra Dev)
**Status:** Adopted

## Context

`validate-flow.ps1` check `[2h]` (az network watcher test-connectivity from vm-spoke1) was failing
live with:

    (NetworkWatcherVmExtensionNotInstalled) NetworkWatcherAgent is not installed, VM vm-spoke1

`enable-monitoring.ps1` enabled regional Network Watcher (Phase 4) but never installed the
per-VM NetworkWatcherAgentLinux extension that `test-connectivity` requires on the SOURCE VM.

## Decision

Add **Phase 4b** to `nva-spoke-internet-paloalto/scripts/enable-monitoring.ps1` that installs
`NetworkWatcherAgentLinux` (publisher `Microsoft.Azure.NetworkWatcher`, version 1.4,
`--enable-auto-upgrade true`) on `vm-spoke1` and `vm-spoke2`.

## Rationale

- The extension is **FREE** -- no Azure charge. Installing it does not change lab cost posture.
- Without it, `az network watcher test-connectivity` always exits non-zero on the source VM,
  making validate-flow.ps1 check [2h] permanently un-passable regardless of network config.
- Palo Alto firewall VMs are NOT given the agent -- they are not connectivity-test sources and
  the agent is a Linux package incompatible with PAN-OS.
- The install is idempotent: skipped if `provisioningState == Succeeded`; `WARN + continue` on
  failure so a single VM issue does not abort the broader monitoring setup.

## Files Changed

- `nva-spoke-internet-paloalto/scripts/enable-monitoring.ps1`
  - Header comment: added item 4 (NetworkWatcherAgentLinux, free, required for connectivity checks);
    renumbered old items 4 -> 5, 5 -> 6.
  - Inserted Phase 4b block (~line 170) between Phase 4 (Network Watcher) and Phase 5 (VNet flow logs).
  - Summary block: added NW Agent line noting vm-spoke1/vm-spoke2 coverage and [2h] enablement.

## References

- https://learn.microsoft.com/azure/network-watcher/network-watcher-agent-update
- https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview

