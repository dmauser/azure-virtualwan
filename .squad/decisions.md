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
