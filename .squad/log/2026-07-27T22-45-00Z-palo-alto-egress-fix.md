# Session Log: Palo Alto Egress Fix

**Date:** 2026-07-27  
**Session ID:** 274503b2-8535-4021-8ce3-c90e21d1658d  
**Agents:** Alex (Config), Naomi (Deploy), Holden (Docs)  
**Focus:** PAN-OS bootstrap blocker + Phase 7b fallback + ILB probe fix

---

## Root Cause: PA Bootstrap Policy Blocker

**Problem:** PA firewalls on spoke subnets (nva-spoke-internet-paloalto) failed to configure. Result: factory-default PAN-OS with no routes → 0 sessions → all egress blocked.

**Why Bootstrap Failed:**
- Deploy script invokes `az storage file upload` to push `bootstrap.xml` to Azure Files share
- Azure storage account is protected by DMAUSER-FDPO management-group policy: `allowSharedKeyAccess=false`
- Azure Files data-plane requires SMB authentication via shared-key (OAuth not supported)
- Shared-key auth is blocked by policy → SMB upload always fails → bootstrap.xml never reaches PA

**Why Routing was NOT the Problem:**
- Identical Linux NVA lab (`nva-spoke-internet/`) uses exact same hub routing topology
- Linux lab has NO spoke UDRs; routes only via vWAN hub (0.0.0.0/0 → ResourceId next-hop)
- **Linux lab passes live egress validation**
- Conclusion: Routing design is sound; failure was bootstrap delivery, not routing

---

## Fix: Phase 5b Hardening + Phase 7b Fallback

**Phase 5b (Naomi):**
- Detect `allowSharedKeyAccess=false` policy on storage account
- Skip SMB upload when policy is detected (graceful degradation, not failure)
- Add explicit exit-code checks to prevent silent failures

**Phase 7b (Naomi):**
- After PA reaches running state, invoke Alex's `apply-panos-config.ps1/.sh` script
- This script sends bootstrap.xml to PA mgmt IP via XML API (HTTPS, not SMB)
- Idempotent: safe to invoke multiple times, skips if config already present
- Result: PA is fully configured regardless of SMB bootstrap outcome

**Secondary Fix (Alex):**
- Added `168.63.129.16/32 → trust` static route to bootstrap.xml
- Reason: ILB health probes originate from 168.63.129.16; without this route, probe responses exit different NIC, Azure SDN drops as spoofed
- Impact: Ensures symmetric routing for probe packets; LB marks PA NVA healthy

---

## Static Validation ✓

All scripts validated for correctness before deployment:

- `az bicep build templates/nva-paloalto.bicep` → exit 0
- `powershell -NoProfile -Command "& { . scripts/apply-panos-config.ps1 }"` → parse OK
- `bash -n scripts/apply-panos-config.sh` → syntax OK
- `powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content deploy.ps1 -Raw))"` → parse OK
- `bash -n deploy.sh` → syntax OK

---

## Live Re-Validation Status

**Current:** Static checks pass; code is ready.

**Pending:** User approval to re-deploy nva-spoke-internet-paloalto lab with Phase 5b + 7b and validate end-to-end egress.

**Expected Outcome:** PA firewalls boot factory-default → Phase 7b config push applies full config → LB health probes pass → spokes egress to Internet successfully via PA.

---

## Documentation Updated

- `nva-spoke-internet-paloalto/README.md` — explains bootstrap blocker + Phase 7b workaround
- `nva-spoke-internet-paloalto/EXPECTED-RESULTS.md` — documents Phase 7b behavior + operator expectations
- `.squad/decisions.md` — decision log merged + correction added clarifying routing is correct, UDRs not needed

---

## Key Learnings

1. **Management-group policies** can retroactively override storage-account properties (allowSharedKeyAccess) post-creation
2. **Azure Files** data-plane does NOT support OAuth bearer tokens; all auth requires shared-key or domain join (Kerberos)
3. **PAN-OS bootstrap** via custom-data has a single fallback: post-boot XML API if cloud-init fails
4. **vWAN hub ResourceId next-hop** does NOT propagate ILB IP address to spoke VNets; spokes apply their own routing rules
5. **Azure LB health probes** are extremely strict about symmetric routing; asymmetric return paths trigger spoofed-packet drop

---
