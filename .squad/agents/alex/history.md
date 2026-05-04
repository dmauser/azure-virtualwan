# Alex — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Session: unified-lab-phase1 (2026-05-04T17:02:00Z)

### Work Completed
- Built `main.bicep` orchestrator to drive Phase 1 topology decisions
- Implemented decision-tree logic selecting preset configuration based on user topology preference
- Created 2 connectivity modules:
  - `vnet-connection.bicep` — vWAN vNet connection with delegation and route propagation
  - `vpn-site.bicep` — VPN site provisioning with address prefix and link bandwidth config
- Established module composition pattern that allows main.bicep to call core modules (from Naomi) + connectivity modules as single declarative flow

### Key Insight
Orchestrator layer benefits from clear module interfaces (input parameters, output IDs). Decision-tree logic in main.bicep decouples topology selection from infrastructure details, enabling presets to drive deployment without orchestrator rewrites. Module interdependencies require careful dependency ordering (hubs before sites, connections after both).

## Learnings
