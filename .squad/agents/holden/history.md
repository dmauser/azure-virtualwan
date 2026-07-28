
---

## 2026-07-28 — PALO-ALTO-CONFIG.md Canonical Reference (Scribe session 274503b2)

**Status:** Implemented & merged to main (commit d5e242a)

Coordinator authored a single canonical Palo Alto configuration reference document: 
va-spoke-internet-paloalto/PALO-ALTO-CONFIG.md (14,168 chars). This document is **authoritative** over:
- README.md's single-VR ASCII diagram (now outdated)
- All single-VR host-route approaches elsewhere
- Partial probe-fix references scattered in prior decision entries

**Content:**
- Azure Standard LB config (ILB HA-ports 10.0.0.68, Public SNAT PIP, TCP/22 probes from 168.63.129.16)
- PAN-OS day-0 bootstrap: dual-VR design (VR-Untrust + VR-Trust), critical 168.63.129.16/32 host route for probe symmetry, NAT masquerade, security policy
- End-to-end egress packet walk (spoke→hub→ILB→PA trust→PA untrust→Public LB SNAT→Internet)
- Verification commands (Azure CLI, PAN-OS API, data-plane curl)
- Azure Learn citations

**Key design decisions reflected:**
- Dual virtual-router pattern (canonical fix for Active-Active VM-Series with both ELB + ILB)
- 168.63.129.16/32 symmetric probe-return route
- HA-ports floating IP + non-syn-tcp=yes session handling
- SNAT-all on Public LB + double-SNAT design
- Bootstrap fallback via XML API (Phase 7b), no user action needed

**Note for future agents:** This document is the living reference. Troubleshoot Palo Alto Azure deployments using this canonical config, not earlier scattered notes.

---

## 2026-07-28 — README Professional Polish (Coordinator lightweight session)

**Status:** Merged to main (commit 27e1704, PR #11)

Coordinator applied professional formatting to nva-spoke-internet-paloalto/README.md:
- Added shields.io badges (build, status, license)
- Variant callout box (Palo Alto VM-Series focus)
- Horizontal rules for visual section breaks
- Table of Contents with anchor links

Technical content unchanged; README now serves as public-facing entry point coordinating with PALO-ALTO-CONFIG.md (canonical technical reference).

