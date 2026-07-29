# Session: Baseline NSG for Spoke Subnets

**Timestamp:** 2026-07-29T01:05:06Z  
**Session ID:** 274503b2-8535-4021-8ce3-c90e21d1658d  
**Project:** nva-spoke-internet-paloalto  
**Lab RG:** rg-nva-spoke-internet-pa (westus3, DMAUSER-FDPO)

---

## Summary

**Objective:** Apply baseline Network Security Group to spoke workload subnets without disrupting live Palo Alto lab.

**Outcome:** ✅ Complete  
- Naomi: IaC + surgical live deployment of NSGs to snet-workload on spoke1 + spoke2
- Amos: Full validation suite run — 12 PASS / 0 FAIL / 2 WARN / 0 SKIP — no regressions
- Coordination: Both agents validated NSG addition reverses prior "NSG-less by design" decision
- PR: #15 (4a7b93d) — synced main.json + merged 72e1954

**Status:** GO — approved for production

---

## Key Decisions Recorded

1. **Spoke Workload Subnets Now Carry Baseline NSG** — Naomi
2. **Post-NSG Baseline Validation (nva-spoke-internet-paloalto)** — Amos

---

## Agents Involved

- **Naomi** (Infra Dev): IaC + deployment
- **Amos** (Tester): Validation
- **Coordinator**: PR merge + main.json sync

---

## Files Changed in Lab

- `nva-spoke-internet-paloalto/bicep/modules/spoke.bicep` — added NSG resource + subnet association
- `nva-spoke-internet-paloalto/bicep/main.json` — synced (auto-compiled)

---

## Verification

- NSG resource IDs confirmed via CLI `az network vnet subnet show --query networkSecurityGroup.id`
- Internet breakout confirmed: vm-spoke1/vm-spoke2 egress = 20.163.105.237 (PA Public LB SNAT IP)
- Check [2g] IP flow verify: flipped from SKIP → PASS
- LB metrics: VipAvailability 99.97%, DipAvailability 100%

---

## Institutional Memory

This session reverses the "NSG-less by design" architectural decision for spoke workload subnets. Future changes to spoke security posture should reference the new baseline NSG rules documented in decisions.md.

