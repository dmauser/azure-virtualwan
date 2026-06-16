# Naomi — History (Summarized)

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Career Arc Summary

### Phase 1: Repository Foundations (2026-05-04)
- Cataloged 30+ labs with LABS_INDEX.md and learning path ordering (fundamentals → advanced → hybrid/migration)
- Architected unified-lab framework with centralized Bicep type definitions and modular composition
- **Key Insight:** Centralized types prevent drift; module composition enables simple-to-complex topology scaling from same codebase

### Phase 2: SVH-Dynamic-ER-RI Lab Delivery (2026-06-15)
- Authored production Bicep orchestrator + all supporting modules (vwan, vhub, firewall, spoke, VM, KV, ER diagnostics)
- Designed deploy/cleanup scripts with correct phase sequencing (hub provisioning → ER gateway → spoke connections → firewall → Routing Intent)
- Implemented dual-path ER gateway creation (Bicep + CLI fallback) and demand-driven gateway model
- **Key Decisions:** Per-hub vmSize for capacity resilience, admin password inline (params safe to commit), spoke connections/RI script-driven (ARM timing gates)
- **Integration:** Cross-team naming contracts with Amos (validate), Alex (routing-intent), Holden (docs)

### Phase 3: Bug Fix + Hardening (2026-06-15)
- **BUG 1 (CRITICAL):** `az network vhub routing-intent` uses `--vhub` (not `--vhub-name`). Fixed infinite polling in all 4 scripts.
- **BUG 2:** Unbounded poll loops → added iteration counters + timeout guards (7 poll loops, 5–20 min each)
- **BUG 3:** `az vm list-skus` unreliable for capacity checks → implemented synchronous probe (Phase 5b) with SKU retry loop + throw-away RG
- **Feature:** Timestamped output across all scripts (`[HH:mm:ss]` prefixes on every phase/poll tick)
- **Learning:** Always verify CLI parameter names with `--help` before new calls; routing-intent and vhub-connection are distinct subcommand trees

### Phase 4: Live Deployment Round 2 (2026-06-16)
- 75-minute end-to-end deployment of 4-hub secured vWAN (westus, westus2, westus3, eastus2) with ER, AzFw Basic, Routing Intent both-mode
- Pre-flight VM capacity probe passed all 4 regions (Standard_B2s), preventing post-provisioning failures
- **Learning 1:** Windows detached processes don't inherit CLI context → use async-attached for long deploys
- **Learning 2:** Subscription 78216abe lacks bring-your-own-public-IP capability; lab defaults (no public IP) correct
- **Learning 3:** Single-char VNet/subnet names fail capacity probe (`NetcfgInvalidVirtualNetworkSite`); probe uses 7+ char names

## Learnings
- grep `routing-intent.*--vhub-name` → 0 in all 4 scripts ✔
- PowerShell Parser `deploy.ps1` → 0 errors ✔
- PowerShell Parser `validate.ps1` → 0 errors ✔
- `bash -n deploy.sh` → PASSED ✔
- `bash -n validate.sh` → PASSED ✔
- `deploy.sh` LF-only (0 CRLF) ✔
- `validate.sh` LF-only (0 CRLF) ✔

## Learnings

### 2026-06-15 — Password-Only VM Auth (removed SSH key requirement)

- **Context**: VMs in the svh-dynamic-er-ri lab were deploying with both SSH key and password authentication. The SSH key was required at deploy time, causing friction. VMs have no public IP, so SSH key auth from the internet was never used in practice — password + Serial Console is the only real access path.

- **Decision**: Removed all SSH key prompts and ephemeral keygen logic from `deploy.sh` and `deploy.ps1`. `sshPublicKey` Bicep param now defaults to `''` (empty string). The `ubuntu-vm.bicep` module uses a ternary on `empty(sshPublicKey)` to conditionally include the `ssh.publicKeys` block — only if a key is actually provided. `disablePasswordAuthentication: false` is always set, ensuring Serial Console and password SSH always work.

- **Bicep pattern** for optional SSH key in `linuxConfiguration`:
  ```bicep
  linuxConfiguration: empty(sshPublicKey) ? {
    disablePasswordAuthentication: false
  } : {
    disablePasswordAuthentication: false
    ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
  }
  ```

- **Files changed**: `ubuntu-vm.bicep`, `main.bicep`, `deploy.sh`, `deploy.ps1`, `README.md`, `docs/troubleshooting.md`, `docs/architecture.md`, `docs/cost-control.md`.

- **Verification**: `az bicep build --file main.bicep` → 0 errors (1 pre-existing upgrade warning). `deploy.ps1` Parser → 0 errors. `bash -n deploy.sh` → PASSED. deploy.sh has 0 CRLF sequences (LF-only).

- **Key Vault storage** of `vm-admin-username` and `vm-admin-password` secrets was already implemented and is kept unchanged. The deployment summary in both scripts now prominently shows how to retrieve credentials with `az keyvault secret show`.



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
