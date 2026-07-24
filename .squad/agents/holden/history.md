# Holden — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: repo-improvements (2026-05-04T21:44:17Z)

### Work Completed
- Expanded `README.md` to 35 links covering all 34 lab/resource folders
- Created `docs/SCRIPT_CONVENTIONS.md` — standardized script structure, naming, and error handling
- Created `docs/LAB_README_TEMPLATE.md` — consistent lab documentation sections and format
- Established conventions for future lab development (chosen `.azcli` pattern, optional template adoption)

### Decision Accepted
- **Documentation Standards for azure-virtualwan** — defined conventions for scripts and lab documentation

### Key Insight
Consistency at scale requires clear templates and conventions. Flexible adoption model allows existing labs to update incrementally while new labs follow standards immediately.

## Session: unified-iac-analysis (2026-05-04T16:51:00Z)

### Work Completed
- Deep architectural analysis of ALL 30+ lab scenarios for unified Bicep consolidation
- Cataloged every scenario's resources, routing config, connectivity model, and complexity
- Researched Azure Verified Modules (AVM) — identified 14 relevant resource modules + 1 pattern module
- Identified 7 critical gaps in AVM coverage (Hub BGP Connections, Route Maps, NVA deployment, etc.)
- Produced full architecture proposal with module hierarchy, effort estimation, and risk assessment
- Analysis delivered directly to Daniel as comprehensive report

### Key Findings
- AVM `avm/ptn/network/virtual-wan` pattern module covers ~60% of base infrastructure needs
- Critical gap: No AVM module for `Microsoft.Network/virtualHubs/bgpConnections` (needed by 8+ labs)
- NVA scenarios (OPNsense, Linux FRR) require fully custom modules — no AVM coverage
- Recommended hybrid approach: AVM for core VWAN infra + custom modules for NVA/BGP/advanced routing
- Estimated total effort: XL (16-20 weeks for 2 engineers)

### Decision Proposed
- **Unified IaC Framework Architecture** — hybrid AVM + custom Bicep approach with scenario selection

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Created 3 deployment presets via `.bicepparam` files:
  - `single-hub-vpn.bicepparam` — minimal topology (1 hub, 1 branch, VPN-only)
  - `any-to-any.bicepparam` — full mesh (2+ hubs, 2+ spokes, bidirectional routing)
  - `secured-vhub.bicepparam` — secured hub variant (Azure Firewall, policy routing)

## Session: svh-dynamic-er-ri Lab Delivery (2026-06-15)

### Lab Delivered
**svh-dynamic-er-ri** — Dynamic 1–4 secured vHub lab with full documentation suite. Authored README, architecture.md, validation.md, troubleshooting.md, cost-control.md. Matches repo voice and structure from 3vhub-er-ri reference.

### Work Completed
- **README.md**: Dynamic N-hub Mermaid diagram, address plan table, per-hub component table, Considerations (ExpressRoute preference, allow-all rule, Basic SKU caveat), Parameters table, 7 deployment scenario examples, validate/cleanup steps, cost estimates
- **architecture.md**: Bicep module mapping, address plan formula, routing design (ExpressRoute rationale, RI modes, Bicep-vs-script sequencing), demand-driven ER gateway model, KV secret handling, resource tagging, divergence from 3vhub-er-ri
- **validation.md**: Per-check descriptions (hub states, ER, firewall, RI, connectivity), effective routes reading, VNet connection status, 5 manual test scenarios, Serial Console access
- **troubleshooting.md**: 8 common issues (ER provider slow, firewall 30-45 min, RI not Provisioned, Internet+Basic caveat, spoke connection failed, VM SKU restrictions, no public IP, KV 403)
- **cost-control.md**: Per-resource cost breakdown, monthly estimates (1-hub $750–800, 3-hub $2000–2200), reduction strategy, 5 staged options (A-E), cleanup instructions, allow-all production warning

### Key Design Choices Documented
1. **ExpressRoute preference (not ASPath)**: Simpler for single-ER-per-hub; documented divergence from 3vhub-er-ri
2. **Explicit allow-all warnings**: Belt-and-suspenders redundancy (README intro, architecture.md, troubleshooting.md, cost-control.md) — labs forked/copied; isolated warnings miss
3. **Script-driven RI/connections**: Sequencing constraints that Bicep `dependsOn` cannot reliably enforce in multi-hub
4. **ER gateway demand model**: Prominent cost lever in README Considerations, architecture.md, cost-control.md
5. **Production caveat on Basic SKU**: Internet inspection limitations clearly labeled

### Integration Points
- Naomi: deploy scripts implement all documented parameters and sequencing
- Alex: routing design documented with RI JSON examples matching routing-intent.bicep
- Amos: validate scripts implement all documented checks and procedures
- Daniel: 7 scenario examples and cost breakdown enable quick deployment decision-making
- Authored comprehensive `README.md` with:
  - Decision tree for topology selection (how to choose preset)
  - Setup instructions (prerequisites, deployment sequence)
  - Testing/validation procedures
  - Roadmap for Phase 2 enhancements
- Implemented cross-platform deployment automation:
  - `deploy.sh` (Bash) + `deploy.ps1` (PowerShell) — parallel scripts with identical logic
  - `cleanup.sh` (Bash) + `cleanup.ps1` (PowerShell) — idempotent resource teardown
- Designed scripts to accept preset via command-line parameter, enabling one-liner deployments

### Key Insight
Parameter files (.bicepparam) reduce preset-to-preset duplication while maintaining readability. Cross-platform scripts (Bash/PowerShell with shared logic) maximize team adoption across Windows/Unix workflows. Decision tree in README acts as CMS for preset selection, reducing support overhead. Cleanup scripts with explicit resource group deletion enable safe lab resets for classroom/sandbox environments.

## Learnings

- `hubRoutingPreference = ExpressRoute` is a hard lab-wide constraint in `svh-dynamic-er-ri` (set in `vhub.bicep`); validation scripts assert it. Never silently change to ASPath/VpnGateway.
- Azure Firewall Basic + Routing Intent Internet mode has documented limitations in Secured Hub topology. Always flag this in README and troubleshooting for any lab combining Basic SKU + `internetOnly`/`both` RI mode.
- Routing Intent must be created **after** the hub firewall reaches `Succeeded` state (~30-45 min). In multi-hub Bicep deployments, this sequencing risk is best handled by script-driven RI creation (post-firewall poll), not Bicep `dependsOn`.
- Spoke VNet hub connections should also be script-driven (after hub `routingState = Provisioned`) rather than in Bicep, for the same sequencing reliability.
- ER gateways are the most impactful optional cost lever in this lab — document demand-driven model prominently.
- Key Vault soft-delete (7-day retention) can block redeployments with the same vault name; document the `az keyvault purge` mitigation prominently.
- All five docs (README, architecture.md, validation.md, troubleshooting.md, cost-control.md) for `svh-dynamic-er-ri` authored in session 2026-06-15.

## Session: nva-spoke-internet Bicep Lab Documentation (2026-07-24)

### Work Completed
- Rewrote `nva-spoke-internet/README.md` — full Bicep-era lab documentation replacing the old azcli script dump.
- Created `media/nva-spoke-internet.excalidraw` at repo root — valid Excalidraw v2 JSON (45 elements: 16 rectangles/ellipses, 16 text labels, 11 arrows, 2 annotation notes).

### Lab Architecture Documented
- **vWAN hub** `10.100.0.0/23` — Standard tier, single scale unit.
- **DMZ VNet** `10.0.0.0/24`: `snet-nva` `10.0.0.0/26` (2× Ubuntu IPTables NVAs) + `snet-ilb` `10.0.0.64/26` (ILB frontend `10.0.0.68`).
- **Spoke1** `10.1.0.0/24`, **Spoke2** `10.2.0.0/24` — workload VMs, default route from hub.
- **On-prem simulation** (optional) `192.168.100.0/24`: strongSwan/FRR NVA (BGP ASN 65001) + workload VM, connected via BGP-over-IPsec to vHub VPN Gateway (BGP ASN 65515).
- **Traffic path**: Spoke VM → hub defaultRouteTable (0/0 → DMZ connection) → ILB (HA-port, VIP 10.0.0.68) → NVA-0 or NVA-1 (iptables MASQUERADE) → Public LB (SNAT out) → Internet.
- NVA subnet carries UDR `0/0 → Internet` to prevent NVAs from being caught by their own propagated default.

### Doc Structure Decisions
- Followed `svh-dynamic-er-ri/README.md` style: `##` sections, callout boxes with emojis, address plan tables, ASCII traffic-flow diagram.
- Section order: Overview → Architecture → Address Plan → How Default Route Works → Optional On-Prem → Prerequisites → Deploy (Bash + PS) → Validation → Cleanup → Files.
- Image reference `../media/nva-spoke-internet.png` (root-level media/; export from excalidraw) + source link to `.excalidraw`.
- Hub routing sequencing warning called out explicitly — connections/routes are script-driven post-`routingState=Provisioned`.

### Diagram Layout Decisions
- Traffic flows **upward** in Y-axis: Internet (top) → PLB → NVA-0/1 → ILB → Hub (center) → Spoke1/Spoke2 (sides) → On-prem (bottom, dashed).
- Color coding: blue=hub, amber/yellow=DMZ, green=spokes, purple=internet, red-dashed=on-prem optional, blue-dashed=VPN GW optional.
- Root-level `media/` folder (not inside lab subfolder) — README uses `../media/` reference; matches task instructions.
- 45 elements total: roughness=0 throughout for clean look; no element binding (startBinding/endBinding: null) for simplicity.

## Learnings

- `nva-spoke-internet` uses **active/active** NVA pair — not active/passive — behind an ILB with HA-port rule. Both NVAs handle traffic simultaneously; no failover quorum needed.
- The ILB `0/0 → 10.0.0.68` static route lives on the **DMZ VNet connection** (not on the hub route table). The hub defaultRouteTable points to the DMZ connection resource ID. Two-hop static route design.
- UDR `0/0 → Internet` on `snet-nva` is critical and easily forgotten — without it, NVAs would try to egress via the ILB they themselves back, creating a routing loop.
- Hub VNet connections and route-table programming must be script-driven **after** `routingState = Provisioned`. Consistent pattern across all complex labs.
- Excalidraw v2 arrows with `points` arrays and no element binding are the most portable format — avoids broken arrow rendering when IDs drift.
- Root-level `media/` folder at repo root (not inside lab subfolder) is the right pattern for diagrams that may be referenced from multiple README files.

## Team Update: 3vhub-er-ri Lab (2026-05-26)
- Naomi delivered new `3vhub-er-ri/` lab: 3-region vWAN with ER (East+West via Megaport), AzFw Basic all hubs, RI (private). Uses native CLI for RI (no Bicep), ASPath hub preference, single interactive script with ER pause-poll pattern. LABS_INDEX.md updated.

---

## Team Update: 2026-07-24

**Lab Status:** nva-spoke-internet Bicep rebuild **COMPLETE & VALIDATED**

The team successfully rebuilt the nva-spoke-internet lab infrastructure as code. All agents contributed:
- naomi: 13 Bicep files
- alex: 6 deployment scripts
- holden: README + topology diagram
- amos: QA validation (8/8 PASS + 1 LOW defect fixed)

Lab is ready for end-to-end testing.

**2026-07-24 — DEPLOYMENT STATUS:** lab is LIVE in DMAUSER-FDPO (eastus2, B2s), 7/7 validation PASS — Alex