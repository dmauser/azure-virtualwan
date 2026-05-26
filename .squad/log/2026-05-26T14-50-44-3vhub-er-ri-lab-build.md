# Session Log: 3vhub-er-ri Lab Build

**Date:** 2026-05-26  
**Time:** 2026-05-26T14:50:44-05:00  
**User Request:** Daniel Mauser  
**Lab Built:** 3vhub-er-ri

## Summary

Daniel requested a new lab demonstrating 3-region Virtual WAN topology with:
- 3 hubs (eastus, westus, centralus)
- ExpressRoute on East and West hubs (Megaport Washington DC + Silicon Valley)
- Azure Firewall Basic on all 3 hubs
- Routing Intent (private traffic only) on all 3 hubs
- ASPath hub routing preference

## Delivery

1. **Plan Created:** Scoped the lab architecture, single-script approach with ER pause pattern, and native CLI for Routing Intent.

2. **Naomi Spawned:** Background agent (sonnet-4.6) tasked to build lab files.

3. **Files Delivered:**
   - 3vhub-er-ri-deploy.azcli (24 KB) — Main interactive script
   - 3vhub-er-ri-validate.azcli (9 KB) — Validation script
   - 3vhub-er-ri-cleanup.azcli (1 KB) — Cleanup script
   - README.md (7 KB) — Lab documentation

4. **Artifacts Updated:**
   - LABS_INDEX.md — New lab row added (✅ Complete)

5. **Verification:** Files reviewed and confirmed; decision entry merged to decisions.md.

## Notes

- Single interactive script reduces context-switching for operators
- Pause-poll pattern for ER provisioning matches Megaport manual handoff workflow
- Native CLI for Routing Intent (no Bicep) aligns with current extension capabilities
- Azure Firewall Basic SKU on all hubs demonstrates cost-optimized security posture
