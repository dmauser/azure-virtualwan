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

## Learnings
