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
