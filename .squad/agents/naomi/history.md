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

## Learnings
