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
