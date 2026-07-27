# Decisions Archive

> Archived decisions older than 30 days. See decisions.md for current log.

---

## Decision: Documentation Standards for azure-virtualwan

**Date:** 2026-05-04
**Author:** Holden (Lead)
**Status:** Accepted
**Requested by:** Daniel Mauser

### Context

The repository has grown to 30+ labs but the root README only listed ~9 of them. There were no conventions for script structure or lab documentation, leading to inconsistency across labs.

### Decisions Made

#### 1. Root README expanded
- Added "Getting Started" section pointing to LABS_INDEX.md (to be created as full catalog)
- All 34 lab/resource folders now linked in the Articles/Lab section
- Added "Contributing" section referencing convention docs

#### 2. Script Conventions established (`docs/SCRIPT_CONVENTIONS.md`)
- File naming: `{prefix}-{action}.azcli` pattern
- Mandatory parameter section at top with `region` and `rg` first
- Pre-requisite checks: login status, CLI extensions, version
- Error handling: `set -e` for bash, progress echo before long commands
- Comments explain "why" not "what"
- Every lab must include a cleanup script

#### 3. Lab README Template created (`docs/LAB_README_TEMPLATE.md`)
- Standardized sections: Objectives, Architecture, Prerequisites, Estimated Time, Deployment Steps, Validation, Cleanup, Troubleshooting
- Includes cost estimate placeholder and Mermaid diagram option
- Troubleshooting table format for common issues

### Impact

- New labs should follow these conventions
- Existing labs are NOT required to retrofit immediately — adopt on next edit
- LABS_INDEX.md is referenced but not yet created (separate task)

### Trade-offs

- Chose `.azcli` as primary format (matches existing convention) over `.sh` wrapper scripts
- Template is guidance, not rigid — labs may omit sections that don't apply

---

## Decision: Unified IaC Framework — Architectural Analysis

**Date:** 2026-05-04
**Author:** Holden (Lead)
**Status:** Proposed
**Requested by:** Daniel Mauser

### Context

Daniel wants to consolidate all 30+ lab scenarios into a single deployable Bicep framework using Azure Verified Modules (AVM) as the foundation. This analysis covers the full scope, AVM gaps, architecture design, effort estimation, and risks.

### Analysis Delivered

See full report in session output. Summary:
- 30 lab scenarios cataloged across 5 complexity tiers
- AVM covers ~60% of base VWAN infrastructure; 7 critical gaps identified
- Hybrid architecture recommended (AVM core + custom modules for NVA/BGP)
- Estimated effort: XL (16-20 weeks for 2 engineers)
- Highest risks: NVA post-deployment config, BGP peering automation, AVM breaking changes

### Decision Pending

Awaiting Daniel's approval on architecture approach before implementation begins.

---

## Decision: LABS_INDEX.md Categorization Approach

**Author:** Naomi (Infra Dev)  
**Date:** 2026-05-04  
**Status:** Proposed

### Context

Created `LABS_INDEX.md` as a comprehensive index of all 30 lab folders in the repository.

### Decisions Made

1. **Learning Path ordering** — Organized from fundamentals (any-to-any, single VPN) → security layers (secured vHub, routing intent) → advanced NVA/BGP → hybrid connectivity (VPN-over-ER) → multi-VWAN → migration scenarios. This reflects a natural skill progression for someone learning Azure Virtual WAN.

2. **Status classification** — Three tiers based on README presence and completeness:
   - ✅ Complete: has a README with substantive documentation
   - ⚠️ Draft: README exists but explicitly says "under construction" or is minimal
   - 📝 Scripts only: no README file present

3. **Key Scripts column** — Limited to 1-2 most representative scripts (typically deploy + validate) rather than listing all scripts, to keep the table scannable.

4. **Excluded folders** — `.squad`, `.github`, `.copilot`, `.vscode`, `.git`, `misc`, `misc-cheatsheet`, `limits`, and `lab` were excluded as they are not lab scenarios.

### Impact

This file serves as the entry point for anyone discovering the repo. It should be updated when new labs are added or when draft labs get completed.

---
---

## Archived: 2026-07-24 (13 decisions older than 30 days)

## Decision: New Lab `3vhub-er-ri` Added

**Date:** 2026-05-26
**Author:** Naomi (Infra Dev)
**Status:** Accepted
**Requested by:** Daniel Mauser

### Context

Added a new lab folder `3vhub-er-ri/` demonstrating a 3-region Virtual WAN topology with ExpressRoute on 2 hubs, Azure Firewall Basic on all 3 hubs, and Routing Intent (private traffic only) across all 3 hubs. This fills a gap in the lab catalog for multi-hub + ER + AzFw Basic + RI in a single scenario.

### Decisions Made

#### 1. Single interactive script with `read -p` ER pause

The deployment uses one script (`3vhub-er-ri-deploy.azcli`) rather than separate deploy + erconn scripts. The script pauses at Phase 7 after printing the ER service keys, allowing the user to hand them to Megaport. This matches the intent of reducing context-switching for the operator and keeps the full workflow in one file.

#### 2. ASPath routing preference on all hubs at create time with update fallback

All 3 vHubs are created with `--hub-routing-preference ASPath`. After waiting for the hubs to succeed, the script verifies the property and applies `az network vhub update --hub-routing-preference ASPath` as a fallback for CLI extension versions that silently ignore the create-time flag.

#### 3. Native CLI for Routing Intent (no Bicep)

Routing Intent is enabled using `az network vhub routing-intent create` with a JSON routing-policies array, polling `az network vhub routing-intent show --query provisioningState`. This avoids the Bicep/ARM deployment used in older `enable-ri.azcli` references and aligns with current CLI extension capabilities.

#### 4. Azure Firewall Basic SKU in vHub

All three hubs use `--sku AZFW_Hub --tier Basic`. The AzFw policy is also created with `--sku Basic`. Management IPs are handled transparently by the vHub-managed deployment (no explicit `--management-ip-configuration` needed for hub firewalls).

### Impact

- `LABS_INDEX.md` updated with new row for `3vhub-er-ri` (status: ✅ Complete).
- New lab added to repository. No existing labs modified.

---

## Decision: Routing Design — svh-dynamic-er-ri Lab

**Author:** Alex (Network Engineer)  
**Date:** 2026-06-15T17:34:27-05:00  
**Status:** Accepted

### Why `hubRoutingPreference = ExpressRoute`

Every Virtual Hub in this lab is created with `hubRoutingPreference: 'ExpressRoute'`.

**Rationale:**
- In a multi-hub topology with both VPN and ExpressRoute attachments, the hub's route-selection algorithm must be deterministic. `ExpressRoute` preference instructs the hub control-plane to prefer ER-learned routes when the same prefix is reachable via both ER and VPN.
- Lab scenarios validate spoke-to-spoke and spoke-to-on-prem reachability over ER. Without this preference, VPN routes can shadow ER routes mid-test, producing intermittent failures that are hard to reproduce.
- Fixed in `vhub.bicep` (`var hubRoutingPreference = 'ExpressRoute'`) so every hub is identical. Validation scripts assert this value.

**Enforcement:** Do NOT change `hubRoutingPreference` to `ASPath` or `VpnGateway` in any hub module without a lab-wide requirement change and team sign-off.

### Routing Intent JSON Shapes

All three modes are defined in `routing-intent.bicep`. The canonical JSON shapes (matching the ARM API and az CLI `--routing-policies` argument) are:

#### `privateOnly`
```json
[
  {
    "name": "PrivateTraffic",
    "destinations": ["PrivateTraffic"],
    "nextHop": "<firewallResourceId>"
  }
]
```

#### `internetOnly`
```json
[
  {
    "name": "InternetTraffic",
    "destinations": ["Internet"],
    "nextHop": "<firewallResourceId>"
  }
]
```

#### `both`
```json
[
  {
    "name": "PrivateTraffic",
    "destinations": ["PrivateTraffic"],
    "nextHop": "<firewallResourceId>"
  },
  {
    "name": "InternetTraffic",
    "destinations": ["Internet"],
    "nextHop": "<firewallResourceId>"
  }
]
```

**Destination string rules (ARM canonical values):**
| String | Covers |
|---|---|
| `PrivateTraffic` | All RFC-1918 prefixes learned from VNet connections, VPN sites, ER circuits |
| `Internet` | Default route (0.0.0.0/0) — Internet-bound traffic |

**Policy name rules:** Names are informational labels in ARM. Use `PrivateTraffic` and `InternetTraffic` consistently across all hubs so logs and Azure Monitor queries match.

**Routing Intent is GLOBAL in this lab** — the same `mode` value MUST be applied to all hubs in a deployment. Mixed modes across hubs in the same vWAN produce asymmetric routing that breaks spoke-to-spoke connectivity through the firewall.

### Azure Firewall Basic — Internet Traffic Caveat

Azure Firewall **Basic** tier is deployed in all hubs (`tier: 'Basic'` in `secured-vhub-firewall.bicep`).

**Known limitation:** Azure Firewall Basic in secured-hub mode has documented restrictions on Internet traffic inspection via Routing Intent. Specifically:

- Basic tier does **not** support IDPS (Intrusion Detection and Prevention System).
- Basic tier does **not** support TLS inspection.
- For `internetOnly` and `both` modes, Internet traffic will egress through the firewall for allow/deny enforcement, but without the deep-inspection capabilities available in Standard/Premium tiers.
- Microsoft documentation notes that Azure Firewall Basic may have limitations steering Internet traffic in secured-hub configurations; always validate that your subscription and region support the desired `internetOnly`/`both` mode with Basic tier before production use.

**Lab posture:** `internetOnly` and `both` modes are **supported** in this lab for connectivity testing (verify reachability, inspect firewall logs). They are **not** a production-grade Internet security posture with Basic tier. Label test results accordingly.

### Rule: No Custom Hub Route Tables or Static Default-Route-Table Routes

**Do NOT create:**
- Custom hub route tables (e.g., `Microsoft.Network/virtualHubs/hubRouteTables` beyond the system `defaultRouteTable`)
- Static routes in `defaultRouteTable` that overlap with Routing Intent destinations (e.g., a static `0.0.0.0/0` or `10.0.0.0/8` pointing anywhere)

**Why:** Routing Intent is incompatible with custom route tables on the same hub. ARM will reject or silently override custom static routes when Routing Intent is active. The Routing Intent resource owns the default-route-table population for its declared destinations. Adding conflicting routes causes ARM deployment errors or undefined routing behavior.

**Rule applies to:** Naomi's Bicep modules, Holden's CLI scripts, and any ARM templates targeting hubs in this lab.

### Resource Naming Convention

Routing Intent child resource: `<hubName>/<hubName>-ri`

Example: hub `vhub-eastus` → Routing Intent `vhub-eastus/vhub-eastus-ri`

---

## Decision: svh-dynamic-er-ri Documentation Structure

**Date:** 2026-06-15T17:34:27-05:00  
**Author:** Holden (Lead Architect)  
**Status:** Accepted

### Context

New lab `svh-dynamic-er-ri` is a dynamic, reusable replacement for `3vhub-er-ri` that deploys 1..N Secured Virtual Hubs based on user input. The Bicep modules were already authored; documentation was absent. The reference lab `3vhub-er-ri/README.md` established the repo voice and structure (Mermaid diagram, Considerations section, CLI-first examples).

### Decision

Authored a five-file documentation set for `svh-dynamic-er-ri`:

1. **`README.md`** — Top-level lab doc. Matches repo voice. Includes: dynamic N-hub Mermaid diagram, address plan table, per-hub component table, Considerations (Route Preference = ExpressRoute and allow-all warnings prominently), Parameters table, deploy examples (7 scenarios), validate steps, cleanup steps, cost notes.

2. **`docs/architecture.md`** — Deep-dive components, Bicep module mapping, address plan formula, routing design (ExpressRoute preference rationale, RI modes, Bicep-vs-script step table), demand-driven ER gateway model, Key Vault secret handling, resource tagging.

3. **`docs/validation.md`** — Per-check description of what `validate.sh`/`validate.ps1` assert, how to read hub effective routes and VNet connection status, manual connectivity test procedures (5 test scenarios), Serial Console access instructions.

4. **`docs/troubleshooting.md`** — Eight common issues with root causes and fixes: ER provider slow, firewall 30-45 min, RI routingState not Provisioned, Internet+Basic SKU caveat, spoke VNet connection failed, VM SKU restrictions, no public IP access (Serial Console guidance), Key Vault 403.

5. **`docs/cost-control.md`** — Per-resource cost table, monthly estimates by hub count, per-resource reduction strategy, Options A–E for staged cost reduction, cleanup instructions, prominent production warning for allow-all rule.

### Key Design Choices

**Route Preference = ExpressRoute (not ASPath)**  
The reference lab `3vhub-er-ri` uses ASPath preference. This lab uses `ExpressRoute` preference. The rationale: `ExpressRoute` preference is simpler and more predictable for single-ER-circuit-per-hub topologies, which is the primary use case for dynamic N-hub labs.

**Explicit Warnings on Allow-All Policy**  
The allow-all firewall rule appears in `vhub.bicep` comments, `firewall-policy.bicep` header, `README.md` intro, and `cost-control.md`. This redundancy is intentional — labs are forked and copied; isolated warnings get missed. Belt-and-suspenders.

**Script-Driven vs. Bicep Steps**  
Routing Intent and VNet connections documented as **must-be-script-driven** (not Bicep) due to sequencing constraints that are hard to enforce reliably with Bicep `dependsOn` in multi-hub deployments.

**ER Gateway Demand Model**  
The demand-driven ER gateway model (no gateway unless a circuit maps to the hub) is the primary ER cost lever.

---

## Decision: 3vhub-er-ri Deployment to DMAUSER-FDPO — Phase 7 Complete

**Date:** 2026-05-26  
**Author:** Naomi (Infra Dev)  
**Status:** Accepted

### Context

Deployment of the `3vhub-er-ri` lab to subscription `DMAUSER-FDPO` was executed through Phase 7 per Daniel's instructions. Deployment is intentionally paused, waiting for Megaport to provision the ExpressRoute cross-connects.

### What Was Deployed (Phases 0–7)

| Resource | Status | Notes |
|----------|--------|-------|
| Resource Group `lab-3vhub-er-ri` (eastus) | ✅ Succeeded | |
| vWAN `vwan-3vhub-er-ri` (Standard, branch-to-branch) | ✅ Succeeded | |
| vHub `vhub-eastus` (10.1.0.0/23, ASPath) | ✅ Succeeded | hubRoutingPreference=ASPath confirmed |
| vHub `vhub-westus` (10.2.0.0/23, ASPath) | ✅ Succeeded | hubRoutingPreference=ASPath confirmed |
| vHub `vhub-centralus` (10.3.0.0/23, ASPath) | ✅ Succeeded | hubRoutingPreference=ASPath confirmed |
| VNet `spoke-east` + NSG + subnet | ✅ Succeeded | SSH from 47.187.109.111 allowed |
| VNet `spoke-west` + NSG + subnet | ✅ Succeeded | SSH from 47.187.109.111 allowed |
| VNet `spoke-central` + NSG + subnet | ✅ Succeeded | SSH from 47.187.109.111 allowed |
| VM `vm-spoke-east` | ❌ NOT CREATED | Eastus capacity restriction — ALL sizes blocked |
| VM `vm-spoke-west` (13.83.148.81) | ✅ Succeeded | Standard_DS1_v2 |
| VM `vm-spoke-central` (172.173.70.139) | ✅ Succeeded | Standard_DS1_v2 |
| ER circuit `er-vhub-eastus` (Washington DC, Megaport, 50 Mbps) | ✅ Succeeded | Service Key: 69ce114c-d9c2-4cd1-b61b-f3a9a94815fc |
| ER circuit `er-vhub-westus` (Silicon Valley, Megaport, 50 Mbps) | ✅ Succeeded | Service Key: 98843cf6-0a74-4472-910e-d672871ce388 |

---

## Decision: 3vhub-er-ri Resume Phases 8-15

**Date:** 2026-05-26  
**Author:** Naomi (Infrastructure Engineer)  
**Status:** Accepted

### Context

Daniel confirmed both Megaport ExpressRoute circuits were provisioned. The `3vhub-er-ri` lab deployment resumed in subscription `78216abe-8139-4b45-8715-6bab2010101e`, resource group `lab-3vhub-er-ri`.

### What Was Deployed (Phases 8–15)

| Resource | Status | Notes |
|----------|--------|-------|
| `vhub-eastus-ergw` | Succeeded | Scale unit 1 |
| `vhub-westus-ergw` | Succeeded | Scale unit 1 |
| `conn-er-eastus` | Succeeded | Connected to `er-vhub-eastus/AzurePrivatePeering` |
| `conn-er-westus` | Succeeded | Connected to `er-vhub-westus/AzurePrivatePeering` |
| `vhub-eastus-fwpolicy` | Succeeded | Basic SKU, allow-all network rule |
| `vhub-westus-fwpolicy` | Succeeded | Basic SKU, allow-all network rule |
| `vhub-centralus-fwpolicy` | Succeeded | Basic SKU, allow-all network rule |
| `vhub-eastus-azfw` | Succeeded | Basic hub firewall, private IP `10.1.0.132` |
| `vhub-westus-azfw` | Succeeded | Basic hub firewall, private IP `10.2.0.132` |
| `vhub-centralus-azfw` | Succeeded | Basic hub firewall, private IP `10.3.0.132` |
| `vhub-eastus-ri` | Succeeded | PrivateTraffic → firewall |
| `vhub-westus-ri` | Succeeded | PrivateTraffic → firewall |
| `vhub-centralus-ri` | Succeeded | PrivateTraffic → firewall |

---

## Decision: 3vhub-er-ri Deploy Speedup

**Date:** 2026-05-26T19:51:57-05:00  
**Author:** Naomi (Infrastructure Engineer)  
**Status:** Accepted

### Decision

Implement the approved Azure CLI wall-clock speedup by moving ExpressRoute circuit creation to the earliest point after resource group/vWAN creation, printing service keys immediately, and delaying the provider `Provisioned` poll until just before ER gateway creation.

### New Phase Order

1. Keep Phase 0 VM SKU availability pre-flight before deployment resources.
2. Create the resource group and Virtual WAN.
3. Create both ExpressRoute circuits in parallel and pause only for Megaport order placement.
4. Start all three vHubs with `--no-wait`.
5. Build spoke VNets, NSGs, rules, subnet associations, and VMs while vHubs provision.
6. Wait for vHub provisioning/routing readiness, then create spoke connections and poll all three together.
7. Poll Megaport/Azure provider state immediately before ER gateway creation.
8. Create ER gateways, ER gateway connections, firewall policies, firewalls, and Routing Intent with added parallelization opportunities.

### Rationale

This ordering exposes service keys as soon as possible so Megaport provisioning can run concurrently with vHub, spoke, VM, and connection work. The human handoff remains intact, but the long provider-state poll no longer blocks independent Azure deployment phases.

---

## Decision: svh-dynamic-er-ri Initial Architecture

**Date:** 2026-06-15  
**Author:** Naomi (Infra Dev)  
**Status:** Accepted

### Bicep Design Decisions

1. **`hubs` array (untyped)** — Maximizes portability across Bicep versions in Cloud Shell; optional per-hub override via `contains(hub, 'vmSize')?` pattern.

2. **vmSize is per-hub** — The reference `3vhub-er-ri` live deployment showed eastus had zero VM capacity. Per-hub vmSize isolates the failure to one region.

3. **adminPassword passed inline** — Passed as `--parameters adminPassword=...` on the CLI. Params file safe to inspect/commit; only secret is protected.

4. **ER gateway creation dual-path** — Bicep creates when `hub.deployErGateway=true`; CLI fallback when circuit mapped at interactive prompt.

5. **Spoke connections NOT in Bicep** — Scripts create after hub `routingState=Provisioned`. Prevents Bicep timing failures on ARM hub router readiness gate.

6. **Routing Intent NOT in Bicep** — CLI creation via `az network vhub routing-intent create` after firewalls `Succeeded`. Scripts poll separately.

7. **Naming contract enforced at main.bicep + script layer** — Scripts compute hub/spoke/fw names locally rather than parsing JSON outputs.

### Impact

- **Amos (validate):** Hub names follow `${labPrefix}-vhub${i}` 1-based; firewall names follow `${hubName}-azfw`; RI names follow `${hubName}-ri`.
- **Holden (routing/RI):** Routing intent mode is global (same on every hub); nextHop is always the local hub's firewall.
- **Alex (test):** KV secrets are `vm-admin-username` / `vm-admin-password`; password retrieval via `az keyvault secret show`.

---

## Decision: Fix missing `--internet-security true` on spoke VNet connections (internetOnly/both RI modes)

**Date**: 2026-06-15  
**Author**: Alex (Network Engineer)  
**Lab**: `svh-dynamic-er-ri`  
**Severity**: HIGH — silent functional failure

### Problem

`az network vhub connection create` defaults `internetSecurity = false` (Propagate Default Route: disabled).  
In Azure Virtual WAN, Routing Intent can only inject a `0.0.0.0/0` default route into a spoke VNet if the connection has `enableInternetSecurity = true`.  
Both `internetOnly` and `both` RI modes were silently broken for the CLI deploy path: internet traffic from Ubuntu VMs bypassed the hub Azure Firewall regardless of the selected RI mode.

The Bicep path (`infra/bicep/modules/spoke-vnet.bicep`) already sets `enableInternetSecurity: true` unconditionally; only the CLI script path was affected.

### Decision

Set `--internet-security true` **conditionally** on `az network vhub connection create` — only when `ri_mode` is `internetOnly` or `both`. For `privateOnly` mode, omit the flag (leave default `false`); private-only deployments do not need a default route injected into spokes and should not receive one.

### Files Changed

| File | Change |
|------|--------|
| `svh-dynamic-er-ri/scripts/deploy.sh` | Added `isec` variable before Phase 9 loop; conditionally adds `--internet-security true` to `az network vhub connection create` based on `$ri_mode`. |
| `svh-dynamic-er-ri/scripts/deploy.ps1` | Added `$isecArgs` array before Phase 9 loop; splatted into `az network vhub connection create` with `@isecArgs`. |
| `svh-dynamic-er-ri/scripts/validate.sh` | Added assertion in Section 11: for each hub with Internet RI policy, checks `enableInternetSecurity == true` on every spoke connection. |
| `svh-dynamic-er-ri/scripts/validate.ps1` | Same assertion in Section 11 (PowerShell). |
| `svh-dynamic-er-ri/docs/architecture.md` | Added notes on (a) conditional `enableInternetSecurity` flag, (b) double-inspection in multi-hub private RI, (c) Azure Firewall Basic ~250 Mbps throughput caveat. |

### Validation Approach

The assertion uses `az network vhub connection show ... --query enableInternetSecurity` (control-plane check). This is preferred over asserting `0.0.0.0/0` in effective routes because:
- Control-plane flag is available immediately after connection provisioning
- Effective route table population can be delayed post-RI activation (timing-dependent in CI)
- The flag is the root cause; the route is the downstream effect

### Verification

- `bash -n deploy.sh` and `bash -n validate.sh` both pass (WSL, LF-only)
- PowerShell parser reports 0 errors for `deploy.ps1` and `validate.ps1`
- No CRLF line endings introduced in `.sh` files

---

## Decision: Password-Only VM Authentication

**Date**: 2026-06-15  
**Author**: Naomi (Infrastructure Engineer)  
**Requested by**: Daniel Mauser (@dmauser)  
**Status**: Implemented  

### Context

The svh-dynamic-er-ri lab was requiring an SSH public key at deploy time (either supplied by the user or auto-generated as an ephemeral key). This created unnecessary friction because:

1. Lab VMs have **no public IP** by default — SSH from the internet was never a practical access path.
2. The only real access paths are **Azure Serial Console** and **VM-to-VM SSH within the lab** — both work with password.
3. The password was already auto-generated and stored in Key Vault at deploy time; SSH key was redundant.
4. Ephemeral key generation via `ssh-keygen` required the tool to be present and left private key files on disk.

### Decision

Remove SSH key authentication as a **requirement**. VMs authenticate with **username + auto-generated password** only. The password is stored in Key Vault (implementation was already in place).

SSH public key support is retained as an **optional, unused-by-default** parameter (`sshPublicKey = ''`) so that advanced users can still supply a key if desired, without breaking any existing automation that passes an empty string.

### Changes Made

| File | Change |
|------|--------|
| `infra/bicep/modules/ubuntu-vm.bicep` | `sshPublicKey` param default `''`; conditional `linuxConfiguration` omits `ssh.publicKeys` when empty; header comment updated |
| `infra/bicep/main.bicep` | `sshPublicKey` param default `''` |
| `scripts/deploy.sh` | Removed SSH key prompt + ephemeral keygen; `ssh_pub_key=""` always; updated deployment summary |
| `scripts/deploy.ps1` | Removed SSH key prompt + ephemeral keygen; `$SshPubKey = ""` always; updated deployment summary |
| `README.md` | Removed SSH key prerequisite, `--ssh-public-key` from all examples, updated auth description |
| `docs/troubleshooting.md` | Updated "No Public IP" section — removed NSG rule update workaround, added KV retrieval for username + password |
| `docs/architecture.md` | Updated auth description in VM section and Key Vault section |
| `docs/cost-control.md` | Removed `--ssh-public-key` from deploy examples |

### Authentication Flow (Post-Change)

1. Deploy script generates a random password (`admin_password`).
2. Bicep stores `vm-admin-username` and `vm-admin-password` as Key Vault secrets.
3. VMs are provisioned with `adminPassword` and `disablePasswordAuthentication: false`.
4. To access a VM:
   ```bash
   # Get credentials from Key Vault
   az keyvault secret show --vault-name <kvName> --name vm-admin-username --query value -o tsv
   az keyvault secret show --vault-name <kvName> --name vm-admin-password --query value -o tsv
   # Login via Azure Serial Console or VM-to-VM SSH with the password
   ```

### Verification

- `az bicep build --file main.bicep` → exit 0, no errors (1 pre-existing version upgrade warning)
- `[System.Management.Automation.Language.Parser]::ParseFile(deploy.ps1)` → 0 errors
- `bash -n deploy.sh` → PASSED
- deploy.sh CRLF check → 0 CRLF sequences (LF-only preserved)

---

## Decision: routing-intent --vhub fix, poll timeouts, SKU retry, timestamps

**Date:** 2026-06-15  
**Author:** Naomi (Infrastructure Engineer)  
**Triggered by:** Live deployment failure of svh-dynamic-er-ri against az CLI 2.83.0 + virtual-wan 1.0.1

### Context

A live deployment of the `svh-dynamic-er-ri` lab exposed three script bugs that caused an infinite hang, incorrect field polling, and a hard failure on VM SKU capacity. These were fixed across all four scripts: `deploy.ps1`, `deploy.sh`, `validate.ps1`, `validate.sh`.

### Decision 1 — `az network vhub routing-intent` uses `--vhub`, NOT `--vhub-name`

**Problem:** Every `routing-intent create/show` call passed `--vhub-name $hub`. The CLI rejects this flag silently (returns a help error), causing infinite polling loops in Phase 12.

**Evidence:** `az network vhub routing-intent create --help` lists `--vhub [Required]` — not `--vhub-name`. The `--vhub-name` parameter belongs to `az network vhub connection create` (a different subcommand family).

**Fix:** Changed all `routing-intent` subcommand invocations to `--vhub` in all 4 files. `vhub connection create` calls are **unchanged** — they correctly use `--vhub-name`.

**Rule going forward:** When writing any CLI call against `az network vhub routing-intent`, always use `--vhub`. When writing against `az network vhub connection`, use `--vhub-name`. These are different subcommand trees with different parameter names.

### Decision 2 — All poll loops must have a bounded max-iteration timeout

**Problem:** Every `do..while` / `while true` poll in both deploy scripts was unbounded. When the `routing-intent show` command errored (due to Bug 1), it returned an empty string which was never `"Succeeded"`, creating an infinite loop (200+ iterations observed).

**Fix:** Added an iteration counter and max-iteration guard to every poll loop in `deploy.ps1` and `deploy.sh`:

| Poll loop | File | Max iters × sleep | Effective timeout |
|---|---|---|---|
| Hub provisioningState | both | 40 × 15 s | 10 min |
| Hub routingState | both | 36 × 10 s | 6 min |
| Spoke connections | both | 40 × 30 s | 20 min |
| ER gateway | both | 40 × 15 s | 10 min |
| ER gateway connection | both | 40 × 30 s | 20 min |
| Azure Firewall | both | 80 × 15 s | 20 min |
| Routing Intent | both | 20 × 15 s | 5 min |

On timeout expiry the script logs `WARNING: ... timed out after N iterations` and breaks (does not exit). This allows the operator to inspect and continue rather than killing the process.

**Rule going forward:** No deploy script may contain an unbounded poll loop. Every `while true` / infinite `do..while` must have a documented max-iteration guard with a WARNING on expiry.

### Decision 3 — VM SKU selection must be resilient to Capacity Restrictions

**Problem:** `Pick-VmSku` / `pick_vm_sku` only checked `az vm list-skus .restrictions`. This returned empty for `Standard_B2s` in eastus, but the actual deployment failed with `SkuNotAvailable / Capacity Restrictions`. The pre-flight check gave false confidence.

**Fix:** 
1. Expanded `$VmSkuCandidates` from 3 to 5 entries: `Standard_B2s`, `Standard_B2ms`, `Standard_D2s_v3`, `Standard_D2as_v5`, `Standard_D2s_v5`.
2. Wrapped the `az deployment group create` call in a retry loop in both `deploy.ps1` and `deploy.sh`. If the deployment fails with `SkuNotAvailable` or `Capacity` in the error output, the loop advances `$SkuRetryIdx` / `$sku_retry_idx`, regenerates the params file with the next candidate SKU for all hubs, and retries. If all candidates are exhausted the script exits with a clear error listing all tried SKUs.
3. The pre-flight `Pick-VmSku` / `pick_vm_sku` still runs (for fast-fail on obviously restricted SKUs) but is now a best-effort hint, not a hard guarantee.

**Rule going forward:** Deployment-time SKU failures are expected in subscription types with capacity restrictions. Always wrap bicep deployments that include VMs in a SKU retry loop when the subscription may have eastus capacity limits.

### Decision 4 — All progress output is timestamped

**Problem:** Long-running phases (Azure Firewall ~30 min) and stuck poll loops produced output with no timing information, making it impossible to tell how long a step had been running.

**Fix:** Added a `Log` / `log` helper in all 4 scripts that prefixes every message with `[HH:mm:ss]`. All phase headers and poll-tick lines now go through this helper.

- PS1: `function Log([string]$m){ Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }`
- SH: `log(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }`

### Verification

- `az network vhub routing-intent create --help` → `--vhub [Required]` confirmed ✔
- `grep routing-intent.*--vhub-name` across all 4 scripts → 0 results (comments only) ✔
- `deploy.ps1` / `validate.ps1`: PowerShell Parser → 0 errors ✔
- `deploy.sh` / `validate.sh`: `bash -n` → PASSED; 0 CRLF sequences ✔

---

## Decision: VM capacity pre-flight probe (Phase 5b)

**Date:** 2026-06-15  
**Author:** Naomi (Infrastructure Engineer)  
**Triggered by:** svh-dynamic-er-ri live deployment failure — VM SkuNotAvailable/capacity in eastus, eastus2, centralus, westus2 discovered AFTER 30-min vWAN/vHub/Firewall provisioning completed.

### Problem

`az vm list-skus --query "[?name=='Standard_B2s'].restrictions"` returned an **empty** result in eastus and other regions for the DMAUSER-FDPO subscription, implying no restrictions. But the actual `az deployment group create` failed with `SkuNotAvailable / Capacity Restrictions` when it tried to allocate the VM. The entire 30+ minute firewall provisioning completed before the failure was discovered.

This is a known issue: `az vm list-skus` reports quota/policy restrictions but NOT live allocation capacity. Capacity blocks are invisible to it.

### Decision

**Replace the unreliable `az vm list-skus` pre-flight with a real synchronous allocation probe (`az vm create`) in a throw-away resource group, run BEFORE the main Bicep deployment.**

#### Why synchronous (no `--no-wait`)
Capacity errors only surface when Azure attempts the allocation. `--no-wait` returns immediately and the error surfaces asynchronously in the background job — by the time you poll it, the main deployment has already started. The probe MUST be synchronous to block on the error.

#### Why a throw-away RG
The probe VM (and its VNet, NIC, disk) must be isolated from the lab deployment. Using a dedicated `capcheck-<labPrefix>-<region>-<rand>` RG means the cleanup is a single `az group delete` that catches all artifacts including partial ones from failed VM creates.

#### Cleanup guarantee
- **Bash**: explicit `az group delete ... --no-wait || true` called before every `return` path.
- **PowerShell**: `try/finally` block ensures `az group delete ... --no-wait` is always called even when the function throws.

### Implementation

#### Functions
| File | Function name | Location |
|---|---|---|
| `deploy.ps1` | `Test-VmCapacity` | Helpers section (after `Build-RiPolicies`) |
| `deploy.sh` | `preflight_vm_capacity` | Helpers section (after `poll_until`) |

#### Phase placement
Phase 5b — inserted between Phase 5 (params file written, all hub regions and SKUs known) and Phase 6 (main `az deployment group create`). Only executes when VMs will be deployed (`deploy_vms=true` / `$DeployVms`).

#### Probe VNet CIDR
`10.250.0.0/24` with subnet `10.250.0.0/27` — chosen to not conflict with any lab hub address spaces (`10.N0.0.0/23`).

#### SKU fallback within probe
The probe iterates through `VM_SKU_CANDIDATES` / `$VmSkuCandidates` (same ordered list used by the deployment retry). Initial SKU is tried first. If a DIFFERENT SKU succeeds, it is propagated back to the hub configuration so the deployment uses it directly.

#### On total failure (all SKUs capacity-blocked)
- Timestamped error box printed with region, tried SKUs, raw Azure error line, and suggested alternate regions (`eastus eastus2 westus westus2 westus3 centralus southcentralus`).
- Script **exits non-zero immediately** (bash: `return 1` → caller `exit 1`; PS1: `throw`).
- **No vWAN/vHub resources have been deployed at this point** — safe to re-run with a different region.

### Escape Hatch

Bypass the probe when capacity is already known:
| Method | PS1 | Bash |
|---|---|---|
| CLI flag | `-SkipCapacityCheck` | `--skip-capacity-check` |
| Env var | `$env:LAB_SKIP_CAPACITY_CHECK=1` | `LAB_SKIP_CAPACITY_CHECK=1` |

When bypassed, a `[WARN]` line is printed informing the operator that a capacity error may still surface post-deployment.

### Verification

- `deploy.ps1` PS Parser → 0 errors ✔  
- `validate.ps1` PS Parser → 0 errors ✔  
- `deploy.sh` `bash -n` → PASS, 0 CRLF ✔  
- `validate.sh` `bash -n` → PASS, 0 CRLF ✔  

### Regions confirmed capacity-blocked (DMAUSER-FDPO, 2026-06-15)

Standard_B2s (and all other tested SKUs): eastus, eastus2, centralus, westus2 — all blocked by capacity restrictions. westus, westus3, southcentralus were not tested but are likely candidates to try.

---

## Decision: svh-dynamic-er-ri Script Hardening Standards

**Date:** 2026-06-16  
**Author:** Amos (Tester)  
**Status:** Accepted (applied to svh-dynamic-er-ri; recommend adopting for all future labs)  
**Requested by:** Daniel Mauser  

### Context

During live deployment validation of the 4-hub svh-dynamic-er-ri lab against `rg-svhdyn-4hub`, four classes of bugs were found and fixed in `validate.ps1`, `validate.sh`, `deploy.ps1`, and `deploy.sh`. These are general patterns that apply to any future lab using similar validation or deploy scripts.

### Decisions Made

#### 1. PS helper parameters must not shadow PS automatic variables

- **Rule**: Never name a PowerShell function parameter `$Args`, `$Input`, `$PSBoundParameters`, or any other [PS automatic variable](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables). Use `$AzArgs` or any other non-reserved name.
- **Rationale**: In `pwsh -File` (nested) execution `$Args` silently receives nothing, so `az @Args` runs bare `az` and prints group-help into captured output, corrupting all downstream checks.

#### 2. Az pre-warm block required in all capture-heavy scripts

- **Rule**: All validate/deploy scripts that capture `az` output into variables must include an up-front pre-warm block: install/update required CLI extensions, then call `az account show` to flush the one-time "Welcome to Azure CLI" banner before any query output is captured.
- **Rationale**: The banner is printed exactly once on first-ever invocation; without pre-warm it lands inside the first `$(az ...)` result and corrupts it.

#### 3. Safe integer parsing for az count queries in PowerShell

- **Rule**: Never cast az query output directly with `[int](...)`. Use a `To-Int` helper that calls `[int]::TryParse` after stripping non-digits, with a guard rejecting strings longer than 9 digits.
- **Rationale**: When `az` returns unexpected JSON blobs instead of a number (e.g., due to banner pollution), the naive cast throws `Int32 OverflowException` and aborts the script.

#### 4. Correct az CLI property names for vWAN and Firewall Policy

- **Rule (vWAN tier)**: Always use `--query typePropertiesType` (not `--query sku` or `--query type`) to retrieve the vWAN tier ("Standard"/"Basic"). The az CLI remaps ARM `properties.type` to `typePropertiesType`.
- **Rule (allow-all rule)**: Always use `ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]` (flatten with `[]` before filtering). The pattern `[0][0]` against a projected list-of-lists always returns null in az CLI JMESPath.

#### 5. Non-interactive guard for all blocking prompts in deploy scripts

- **Rule**: Any `Read-Host`/`read` prompt in deploy scripts that waits for operator action (e.g., ER provider provisioning) must be guarded by `$IsNonInteractive` (PowerShell) / `NON_INTERACTIVE=1` env var (Bash). When running non-interactively, print the manual-step guidance and skip the blocking call.
- **Rationale**: CI/automation pipelines and `pwsh -NonInteractive` invocations hang indefinitely at blocking prompts.

### Impact

- These five rules should be added to `docs/SCRIPT_CONVENTIONS.md` (Holden's domain) as PowerShell/Bash validation script standards.
- Existing labs are not required to retrofit immediately — apply on next edit (consistent with Documentation Standards decision).
- New lab validation scripts must follow rules 1–5 from day one.

### Trade-offs

- Pre-warm adds ~5–10 seconds per script run. Acceptable cost to guarantee clean output.
- `To-Int` is PowerShell-only. Bash's `[[ $n -gt 0 ]]` and `${n:-0}` are already safe.

---

## Decision: Canonical Prerequisite Checks in All Local Runner Scripts

**Date:** 2026-06-16  
**Author:** Coordinator (Naomi, Alex, Amos)  
**Status:** Accepted  
**Requested by:** Daniel Mauser

### Context

During this session, Naomi built the new `gcp-onprem/` Terraform lab with 6 runner scripts. Alex and Amos standardized prerequisite checks across 11 additional runner scripts. The team identified a gap: local runner scripts must explicitly detect missing CLIs and offer guidance before executing.

### Decision Made

**All local runner scripts in this repository must begin with a prerequisite check block** that:

1. **Detects required CLIs:** `az` (Azure CLI), `terraform` (Terraform), `gcloud` (Google Cloud CLI), `jq` (JSON processor), `openssl` (OpenSSL), `Az` PowerShell module
2. **For Bash scripts:** Use function `lab_require_tools` that lists missing tools and offers install guidance
3. **For PowerShell scripts:** Use cmdlet `Invoke-LabPrereqCheck` with the same semantics
4. **Fails gracefully:** Exit non-zero if a required tool is missing (operator can install and re-run)

### Scope

**Applies to:**
- All `.azcli` (bash) runner scripts
- All `.sh` (bash) runner scripts
- All `.ps1` (PowerShell) runner scripts

**Excludes:**
- On-device/appliance scripts (`OPNsense/`, `iptables/`, `linux-router/`, `mesh-sync/`)
- Internal helper functions
- ARM template `.json` files

### Standardized Implementations

#### Bash (lab_require_tools)
```bash
function lab_require_tools() {
  local missing=()
  for cmd in az terraform gcloud jq openssl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  echo "❌ Missing tools: ${missing[*]}"
  echo "Install from: https://docs.microsoft.com/cli/azure/install-azure-cli"
  exit 1
}
lab_require_tools
```

#### PowerShell (Invoke-LabPrereqCheck)
```powershell
function Invoke-LabPrereqCheck {
  $missing = @()
  foreach ($cmd in @('az', 'terraform', 'gcloud', 'jq', 'openssl')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      $missing += $cmd
    }
  }
  if ($missing) {
    Write-Host "❌ Missing tools: $($missing -join ', ')"
    exit 1
  }
}
Invoke-LabPrereqCheck
```

### Rationale

- **Reliability:** Catch missing CLIs at script start, not mid-deployment
- **Developer experience:** Clear error messages and install links reduce operator confusion
- **Consistency:** All runners follow the same pattern — predictable behavior
- **Early failure:** Prevents partial deployments or confusing error chains

### Impact

- 28 scripts now include canonical prerequisite checks (100% coverage of local runner scripts)
- Bash syntax validation (`bash -n`) passes on all 6 Bash scripts (gcp-onprem, unified-lab, others)
- PowerShell parser passes on all applicable PowerShell scripts
- `.gitignore` added to `gcp-onprem/terraform/` to exclude `.terraform/` directory

### Verification

- Naomi's `gcp-onprem/` scripts: `terraform fmt` and `terraform validate` pass
- Alex's 8 `svh-dynamic-er-ri` scripts: syntax validation pass
- Amos's 11 scripts (checkvmsize, misc/hub-reset, etc.): syntax validation pass
- All scripts committed as f3c1301 (NOT pushed)

---
