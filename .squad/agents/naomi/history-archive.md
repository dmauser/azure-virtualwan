## Session: 3vhub-er-ri live deployment (2026-05-26)

**Deployment target:** DMAUSER-FDPO subscription (78216abe-8139-4b45-8715-6bab2010101e)
**Phases executed:** 0-7 (stopped as requested before Phase 8)
**Total elapsed:** ~52 minutes (15:08 → 16:00)

### Phase timings
| Phase | Duration | Notes |
|-------|----------|-------|
| 0 Pre-flight | ~4 min | Had to disable broken `nsp`, `portal`, `staticwebapp` extensions (WinError 5 access-denied on `.dist-info`); `azure-firewall` auto-installed on first use |
| 1 RG + vWAN | ~22 sec | Smooth |
| 2 3 vHubs | ~9 min | All 3 Succeeded; `--hub-routing-preference ASPath` accepted at create time (no fallback needed) |
| 3 VNets + NSGs | ~87 sec | Smooth |
| 4 VMs | ~8 min | **eastus capacity blocked ALL tested sizes** (DS1_v2, D2s_v5, D2s_v3, D4s_v3, B2s, A2_v2, B1s, etc.) — westus and centralus VMs created fine with DS1_v2 |
| 5 Hub connections | ~2 min | All Succeeded quickly; routingState=Provisioned was immediate |
| 6 ER circuits | ~10 min each (sequential) | eastus circuit first, then westus |
| 7 Service keys | instant | Both keys printed |

### CLI surprises / findings

- **Windows PowerShell `--nsg ""`:** Empty string arg fails with "expected one argument". The `--nsg ''` also fails. Solution: omit `--nsg` entirely (subnet NSG from Phase 3 already applied).
- **`--hub-routing-preference ASPath` at create time:** WORKS — no update fallback needed on CLI 2.83.0 with virtual-wan extension.
- **Broken extensions (nsp, portal, staticwebapp):** These had unreadable `.dist-info` folders (`WinError 5`), causing ALL az commands to fail fatally. Fixed by renaming the extension folders to `.disabled`. This is a known environment-specific issue.
- **eastus VM capacity:** Subscription DMAUSER-FDPO has no VM capacity in eastus for any standard size (DS1_v2, D2s_v3, D2s_v5, D4s_v3, E2s_v3, B2s, B1s, A2_v2, F2s, B4ms, DC2s_v3). Quota shows 0/100 used — this is a capacity restriction, not a quota issue. Likely subscription-type restriction. westus and centralus are unaffected.
- **`--no-wait` exit code bug:** When `--no-wait` is used and the deployment fails at ARM preflight validation, some failures return exit code 0 (bug in az CLI). Always poll provisioning state after --no-wait to confirm actual success.

### ER circuit IDs (for reference in Phase 9+)
- `er-vhub-eastus`: service key `69ce114c-d9c2-4cd1-b61b-f3a9a94815fc`, location Washington DC
- `er-vhub-westus`: service key `98843cf6-0a74-4472-910e-d672871ce388`, location Silicon Valley

### VM public IPs
- `vm-spoke-east`: **NOT CREATED** (eastus capacity restriction)
- `vm-spoke-west`: `13.83.148.81` (westus, Standard_DS1_v2)
- `vm-spoke-central`: `172.173.70.139` (centralus, Standard_DS1_v2)

## Session: 3vhub-er-ri resume phases 8-15 (2026-05-26)

**Deployment target:** DMAUSER-FDPO subscription (78216abe-8139-4b45-8715-6bab2010101e), RG `lab-3vhub-er-ri`
**Requested by:** Daniel Mauser

### Work Completed
- Verified both ExpressRoute circuits were `serviceProviderProvisioningState=Provisioned`.
- Created ER gateways `vhub-eastus-ergw` and `vhub-westus-ergw` with scale unit 1.
- Connected ER gateways to existing AzurePrivatePeering objects: `conn-er-eastus` and `conn-er-westus` both `Succeeded`.
- Created Basic firewall policies for eastus, westus, and centralus with `allow-all` network rule collections.
- Deployed Basic hub Azure Firewalls on all 3 vHubs:
  - `vhub-eastus-azfw` private IP `10.1.0.132`, public IP `13.72.86.117`
  - `vhub-westus-azfw` private IP `10.2.0.132`, public IP `104.42.44.154`
  - `vhub-centralus-azfw` private IP `10.3.0.132`, public IP `20.12.223.50`
- Enabled Routing Intent for `PrivateTraffic` only on all 3 hubs, next hop = local hub firewall.

### CLI Findings
- Routing Intent CLI on this workstation requires `--vhub` and `next-hop` in the routing policy object; `--vhub-name` and `nextHop` failed validation.
- Megaport had already created AzurePrivatePeering for both circuits, so no manual peering overwrite was performed.

### Final VM public IPs
- `vm-spoke-east`: `104.209.170.25`
- `vm-spoke-west`: `13.83.148.81`
- `vm-spoke-central`: `172.173.70.139`


## Session: 3vhub-er-ri deploy speedup (2026-05-26T19:51:57-05:00)

**Requested by:** Daniel Mauser

### Work Completed
- Reordered `3vhub-er-ri-deploy.azcli` so ExpressRoute circuits are created immediately after RG/vWAN, with service keys printed before vHub/spoke work.
- Kept the Megaport human handoff pause, but changed it to wait for order placement only; provider `Provisioned` polling now happens immediately before ER gateway creation.
- Parallelized per-region spoke network setup, ER gateway connections, firewall policy chains, and Routing Intent creation.
- Replaced sequential spoke-connection and Routing Intent polling with combined all-resource polling loops.
- Updated README considerations and deployment timing estimate to reflect the overlap strategy.

### Rationale
Expose Megaport service keys as early as possible and overlap external provider provisioning with independent Azure work while preserving deployed-resource semantics and interactive UX.

## Session: svh-dynamic-er-ri initial build (2026-06-15)

**Requested by:** Daniel Mauser  
**New lab:** `svh-dynamic-er-ri/` — dynamic N-hub reusable rebuild of `3vhub-er-ri`.

### Files Created
- `infra/bicep/modules/diagnostics.bicep` — optional Log Analytics workspace (PerGB2018, 30-day retention)
- `infra/bicep/main.bicep` — RG-scoped orchestrator; loops over `hubs` array; deploys vWAN, vHubs, FW policies, firewalls, spoke VNets, conditional VMs, conditional ER gateways, Key Vault, optional diagnostics workspace
- `infra/parameters/sample.singlehub.json` — single-hub example params
- `infra/parameters/sample.multihub.json` — 3-hub example (eastus/westus/centralus, 2 with ER gateways)
- `scripts/deploy.sh` + `scripts/deploy.ps1` — feature-equivalent interactive/non-interactive wrappers
- `scripts/cleanup.sh` + `scripts/cleanup.ps1` — cleanup with `--vms-only`, `--er-only`, `--all` modes

### Key Design Decisions

1. **Hub config includes `vmSize`** — per-hub vmSize in the hub array object (populated from `pick_vm_sku` pre-flight) avoids the eastus capacity issue from the live `3vhub-er-ri` deployment where a global vmSize would block all hubs.

2. **Secrets passed inline, not in params file** — `adminPassword` passed as `--parameters adminPassword=...` to `az deployment group create`; params file contains everything else (including `adminUsername` and `sshPublicKey`). This keeps the generated JSON file inspectable without leaking the password.

3. **ER gateway creation dual-path** — ER gateways can be pre-created by Bicep (when `hub.deployErGateway=true`) OR created on-demand by the deploy script when the user maps a circuit to a hub at interactive prompt. Script checks for existence and creates if missing.

4. **No jq dependency** — hub/spoke/fw names are computed in the script from the naming convention instead of being parsed from deployment JSON outputs. Deployment outputs are still emitted for external tooling.

5. **Cleanup modes** — `--vms-only` deletes VMs+NICs+PIPs; `--er-only` deletes connections → gateways → circuits (in order); `--all` deletes the whole RG. All require explicit `yes` confirmation.

6. **KV soft-delete note** — cleanup scripts remind users to purge the Key Vault via `az keyvault purge` since RG deletion leaves KV in 7-day soft-deleted state.

### Bicep notes
- `contains(hub, 'vmSize') ? hub.vmSize : vmSize` used for per-hub vmSize override with global fallback (valid Bicep built-in for object property check on untyped array elements)
- Conditional module loops `[for (hub, i) in hubs: if (hub.deployVm) {...}]` used for VMs and ER gateways
- `hubRoutingPreference` = `ExpressRoute` is hardcoded in the `vhub.bicep` module; deploy script also runs a fallback `az network vhub update` check post-deployment

## Session: svh-dynamic-er-ri capacity pre-flight (2026-06-15)

**Requested by:** Daniel Mauser  
**Trigger:** svh-dynamic-er-ri live deployment succeeded on vWAN/vHub/Firewall (~30 min) then failed on VM with `SkuNotAvailable` / allocation capacity errors in eastus, eastus2, centralus, and westus2. The `az vm list-skus` restrictions check returned empty (appeared to allow the SKU) but allocation was blocked.  

### Work Completed

Added Phase 5b VM capacity pre-flight to `deploy.ps1` and `deploy.sh`:

- **`Test-VmCapacity`** (PowerShell) / **`preflight_vm_capacity`** (bash): creates a throw-away resource group (`capcheck-<labPrefix>-<region>-<rand>`), a minimal VNet/subnet (`10.250.0.0/24`), and runs a **synchronous** `az vm create` (no `--no-wait`) with the chosen SKU. Capacity errors surface immediately. If the initial SKU fails, the function iterates through `$VmSkuCandidates` / `VM_SKU_CANDIDATES` in the same region. A working SKU is propagated back; if ALL candidates fail, the function aborts the run with a clear timestamped error before any vWAN/vHub resources are deployed.
- **Probe RG always deleted**: bash uses explicit cleanup before every return; PS1 uses `try/finally`.
- **Escape hatch**: `-SkipCapacityCheck` / `--skip-capacity-check` flag and `LAB_SKIP_CAPACITY_CHECK=1` env var bypass the probe with a warning.
- **Phase placement**: after Phase 5 (params file written, all regions and SKUs known) and before Phase 6 (main Bicep deployment). Only runs when `deploy_vms=true` / `$DeployVms`.

### Key CLI Learning

`az vm list-skus ... restrictions` returns EMPTY even for capacity-blocked SKUs in some subscription types (confirmed DMAUSER-FDPO eastus, eastus2, centralus, westus2 — all returned no restrictions but allocation failed). The ONLY reliable capacity check is a real synchronous `az vm create`.

### Abort message text (on total failure)

```
  ╔══════════════════════════════════════════════════════════════════╗
  ║  ✗  VM CAPACITY PRE-FLIGHT FAILED — deployment aborted          ║
  ╚══════════════════════════════════════════════════════════════════╝
  Region     : <region>
  Tried SKUs : <list>
  Azure error: <first matching error line>

  ➤ Suggested alternate regions to try:
      eastus  eastus2  westus  westus2  westus3  centralus  southcentralus

  ➤ Re-run deploy.ps1/deploy.sh and choose a different region for the affected hub.
  ➤ No vWAN/vHub resources have been deployed — safe to re-run.
```

### Escape hatch names
- PS1 flag: `-SkipCapacityCheck`  
- SH flag: `--skip-capacity-check`  
- Env var (both): `LAB_SKIP_CAPACITY_CHECK=1`

### Verification Results
- `deploy.ps1` PowerShell Parser → 0 parse errors ✔
- `validate.ps1` PowerShell Parser → 0 parse errors ✔
- `deploy.sh` bash -n → PASS, 0 CRLF ✔
- `validate.sh` bash -n → PASS, 0 CRLF ✔

## Learnings

### Learning 1: Detached Deployment Processes (Windows) Do NOT Inherit CLI Context

**Context:** Round 2 live deployment (2026-06-16).  
**Problem:** Launching `deploy.ps1` with PowerShell background mode (`detach:true`) on Windows did not inherit az CLI login context or environment variables. The process ran but produced no resource group or deployment logs.  
**Resolution:** Use `mode="async"` with `Tee-Object` for long-running deploys. Async (attached) mode preserves session environment variables and CLI context correctly.  
**Implication:** All long-deploy orchestration should use async-attached, not detached background processes.

### Learning 2: Subscription 78216abe Does NOT Support Bring-Your-Own-Public-IP

**Context:** Round 2 live deployment (2026-06-16).  
**Restriction:** Subscription 78216abe-8139-4b45-8715-6bab2010101e is **not registered** for `Microsoft.Network/AllowBringYourOwnPublicIpAddress`.  
**Implication:** VMs must be created with `attachPublicIp=false` at deploy time (lab default is correct). Attempting to add a public IP post-VM-creation fails with HTTP 403 (Forbidden).  
**Workaround:** Accept no-public-IP default. Access VMs via Azure Serial Console (built-in) or VM-to-VM SSH within the lab VNet (password auth via Key Vault).  
**Lesson:** Subscription type and feature registration constraints must be validated early (Phase 0 pre-flights). Lab defaults (no public IP) are correct for restricted subscriptions.

---

## Cross-Agent Note: Amos Script Hardening (2026-06-16)

**From:** Scribe (recording Amos discoveries)  
**For:** Naomi (owns deploy.ps1 / deploy.sh)  
**Topic:** Script hardening standards from live validation

Amos fixed two critical query patterns in validate.ps1/validate.sh that directly affect your deploy scripts:

1. **vWAN tier query:** Use `--query typePropertiesType` (not `--query sku`). The az CLI remaps ARM `properties.type` → `typePropertiesType`. Your code likely references this for vWAN Standard/Basic tier checks.

2. **Allow-all firewall rule query:** Use `ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]` (flatten with `[]` before filtering). The pattern `[0][0]` against a projected list-of-lists always returns null.

3. **Phase 10 ER provider pause:** Amos added a non-interactive guard: if `$IsNonInteractive` (PS) or `NON_INTERACTIVE=1` (bash), print guidance and skip blocking prompts. This prevents CI pipelines and `pwsh -NonInteractive` from hanging on `Read-Host` at the ER provider pause.

**Action:** If your deploy.ps1/deploy.sh queries vWAN SKU or allow-all rules, update them to use the corrected patterns. Add non-interactive guards to any operator-interaction prompts.

**Skill reference:** See `.squad/skills/azure-validation-queries/SKILL.md` for the canonical az CLI query patterns for vWAN, firewall, and connectivity validation.

---

## Session: connect-er standalone scripts (2026-06-16)

**Requested by:** Daniel Mauser
**Trigger:** Circuits provisioned by Megaport; user needs to connect them to vHub ER gateways without re-running the full deploy.ps1.

### Work Completed

Created two standalone post-provisioning scripts in `svh-dynamic-er-ri/scripts/`:
- **connect-er.ps1** (PowerShell 7+, #Requires -Version 7.0)
- **connect-er.sh** (bash, set -euo pipefail, LF-only)

### ER Circuit → vHub Gateway Connection Pattern

**Exact CLI sequence:**
1. `az network express-route list -g <rg>` — discover circuits, check `serviceProviderProvisioningState`
2. `az network vhub list -g <rg>` — discover hubs + locations
3. `az network express-route gateway show -g <rg> -n <hub>-ergw` — check/create gateway with `--min-val 1 --virtual-hub <hub>`
4. `az network express-route show -g <rg> -n <circuit> --query 'peerings[0].id' -o tsv` — get AzurePrivatePeering id
5. `az network vhub route-table show --name defaultRouteTable --vhub-name <hub> -g <rg> --query id -o tsv` — get default route table id
6. `az network express-route gateway connection create --name <hub>-conn-to-<circuit> -g <rg> --gateway-name <hub>-ergw --peering <peeringId> --associated-route-table <rtid> --propagated-route-tables <rtid> --labels default -o none`
7. Poll `az network express-route gateway connection show --query provisioningState` to `Succeeded`

**Idempotency approach:** Before creating, call `az network express-route gateway connection list --gateway-name <hub>-ergw` and check for a connection named `<hub>-conn-to-<circuit>`. If found, skip with "AlreadyConnected".

**Connection name convention:** `${targetHub}-conn-to-${circuitName}`

**Non-interactive mode:** Pass `-CircuitHubMap "circuit=hub,circuit=hub"` (PS) or `--circuit-hub-map "circuit=hub,circuit=hub"` (bash). Also honoured via `LAB_CIRCUIT_HUB_MAP` env var. Interactive mode: prompts "Connect <circuit> to which hub number? [1]".

**Poll timeout:** Uses iteration counter (not wall-clock), max configurable via `-MaxWaitMin`/`--max-wait-min` (default 20 min = 40 × 30 s). On timeout: prints warning and continues (does not hard-fail the run).

### Verification
- `connect-er.ps1` PowerShell Parser → 0 parse errors ✔
- `connect-er.sh` bash -n → PASS, 0 CRLF ✔

