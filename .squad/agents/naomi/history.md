# Naomi — History (Summarized)

## Career Overview

**Role:** Infra Dev for azure-virtualwan project (Azure CLI, Bicep, ARM, Bash/Shell)

### Phase Summaries
1. **Repository Foundations (2026-05-04):** Cataloged 30+ labs with LABS_INDEX.md, unified-lab Bicep framework, centralized type definitions
2. **SVH-Dynamic-ER-RI Lab (2026-06-15):** Production Bicep orchestrator (vwan, vhub, firewall, spoke, VM, KV, ER), deploy/cleanup scripts with correct phase sequencing, dual-path ER gateway, per-hub vmSize
3. **Bug Fix & Hardening (2026-06-16):** Fixed critical CLI bugs (z network vhub routing-intent --vhub vs --vhub-name), unbounded polls → counters+timeout, z vm list-skus → sync probe, timestamped output
4. **Live Deployment Round 2 (2026-06-16):** 75-min end-to-end 4-hub ER+AzFw+RI deploy, capacity probe patterns, Windows detached process learnings, VNet/subnet naming length constraints

### Key Bicep Learnings (nva-spoke-internet + paloalto variants)
- Conditional module null-safety (BCP318 non-null assertion !)
- "Always deploy, gate inside" pattern for conditional modules
- HA-ports ILB (protocol=All, ports=0, enableFloatingIP=true, static frontend)
- Public LB outbound rule coexistence (disableOutboundSnat=true on LB rules)
- Cloud-init base64 embedded at Bicep compile time
- 16-output contract discipline with exact naming

### Recent: nva-spoke-internet-paloalto (2026-07-27)
- Rebuilt nva-spoke-internet labs with Palo Alto VM-Series (vmseries-flex, BYOL)
- Added 3-subnet DMZ (mgmt/untrust/trust), PA-specific UDRs, 13-phase deploy script
- Marketplace plan block mandatory: plan: { name: 'byol', publisher: 'paloaltonetworks', product: 'vmseries-flex' }
- Preserved all 16 outputs; 
vaNames now PA firewall names instead of Linux NVAs
- Flow-validation script naming fix (pa-fw-0/pa-fw-1 instead of pa-nva-0/pa-nva-1)

**Status:** PA lab passed review gate (Amos PASS), live deploy ready (separate opt-in)

---

*Last update: 2026-07-27 (PA lab completed and validated)*
