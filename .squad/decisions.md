# Decisions

> Team decisions log. Append-only.

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
