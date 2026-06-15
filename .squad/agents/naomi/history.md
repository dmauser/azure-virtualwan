# Naomi — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: repo-improvements (2026-05-04T21:44:17Z)

### Work Completed
- Root cleanup: deleted `hello.txt`, moved `svhri-inter-deploy.sh`
- Created `LABS_INDEX.md` cataloging 30 labs with learning path ordering
- Implemented status classification for labs (Complete/Draft/Scripts only)
- Designed decision log entry for LABS_INDEX categorization

### Decision Proposed
- **LABS_INDEX.md Categorization Approach** — organized learning path from fundamentals through hybrid connectivity to migration scenarios

### Key Insight
Repository benefits from centralized lab catalog with natural learning progression. Scalable model for growing lab library.

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Architected `unified-lab/` folder structure with modular conventions
- Created `bicepconfig.json` with metadata and version constraints for Bicep modules
- Designed centralized type definitions in `types/scenario-types.bicep` for parameter consistency
- Implemented 3 core modules:
  - `vwan-hub.bicep` — vWAN hub provisioning with configurable SKU, routing preferences
  - `spoke-vnet.bicep` — Spoke VNet deployment with address space and peering prep
  - `branch-sim.bicep` — Branch office simulation via VM + site-to-site VPN setup
- Established module composition patterns for extension by orchestrator layer

### Key Insight
Centralized type definitions prevent configuration drift across presets. Bicep module composition enables both simple (single-hub) and complex (any-to-any) topologies from same codebase. Separated core (infra building blocks) from connectivity (routing logic) into distinct module namespaces.

## Session: svh-dynamic-er-ri Lab Delivery (2026-06-15)

### Lab Delivered
**svh-dynamic-er-ri** — Dynamic replacement for `3vhub-er-ri`. Deploys 1–4 Secured Virtual Hubs with ExpressRoute, Azure Firewall Basic, Routing Intent. Parameterized hub count, per-hub vmSize, demand-driven ER gateways, dual-path gateway creation (Bicep + CLI fallback).

### Work Completed
- Authored `main.bicep` orchestrator, all Bicep modules (vwan, vhub, firewall, spoke, VM, KV, ER, diagnostics)
- Fixed Bicep lint warnings (`az bicep build main.bicep` → exit 0)
- Authored `deploy.sh` / `deploy.ps1` with correct sequencing: hub → ER gateway → spoke connections → firewall → RI
- Authored `cleanup.sh` / `cleanup.ps1` with reverse-order cleanup
- Created `sample.singlehub.json` and `sample.multihub.json` parameter files
- Documented orchestration in `.squad/orchestration-log/2026-06-15T18-06-36Z-naomi.md`

### Key Decisions Made
1. **ER gateway dual-path**: Bicep creates when `hub.deployErGateway=true`; CLI fallback for interactive circuit mappings
2. **vmSize per-hub**: Region resilience (eastus capacity ≠ westus/centralus)
3. **adminPassword inline, not in params**: Params file safe to inspect/commit
4. **Spoke connections script-driven**: After hub `routingState=Provisioned` (ARM gate reliability)
5. **Routing Intent script-driven**: After firewalls `Succeeded` (critical path optimization)
6. **Naming contract enforced at Bicep + script layer**: Hub names derived from labPrefix + index (no jq dependency)

### Integration Points
- Alex: routing-intent.bicep used by RI CLI in deploy scripts
- Amos: validate scripts test hub names, ER gateways, spoke connections, RI modes
- Holden: README and docs reference deploy script interface and parameter examples

## Learnings

### Session: 3vhub-er-ri lab build (2026-05-26)

**New lab added:** `3vhub-er-ri/` — 3-region vWAN, ER on 2 hubs, AzFw Basic, Routing Intent (private only).

**Key CLI patterns used:**

- **Hub routing preference at create time:**
  ```bash
  az network vhub create ... --hub-routing-preference ASPath
  ```
  With fallback post-create if flag is silently ignored by older CLI extension:
  ```bash
  az network vhub update -g $rg -n $hubname --hub-routing-preference ASPath
  ```

- **Native CLI Routing Intent (private traffic only, no bicep):**
  ```bash
  fwid=$(az network firewall show -g $rg -n $hubname-azfw --query id -o tsv)
  az network vhub routing-intent create -g $rg --vhub-name $hubname -n $hubname-ri \
    --routing-policies '[{"name":"PrivateTraffic","destinations":["PrivateTraffic"],"nextHop":"'"$fwid"'"}]'
  ```
  Poll with:
  ```bash
  az network vhub routing-intent show -g $rg --vhub-name $hubname -n $hubname-ri \
    --query 'provisioningState' -o tsv
  ```

- **Azure Firewall Basic on vHub:**
  ```bash
  az network firewall create -g $rg -n $hubname-azfw \
    --sku AZFW_Hub --tier Basic --virtual-hub $hubname \
    --public-ip-count 1 --firewall-policy <policy-id> --location <region>
  ```
  Policy must also be Basic SKU: `az network firewall policy create ... --sku Basic`

- **ER service-key pause + poll pattern** (interactive script):
  1. Print service keys via `az network express-route show --query serviceKey -o tsv`
  2. Pause with `read -p "Press ENTER once circuits show Provisioned..."`
  3. Poll loop with configurable `MAX_WAIT_MIN=180`, `sleep 30`, abort with resume hint on timeout
  4. Timeout message includes instruction to re-run from Phase 9 onward

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
