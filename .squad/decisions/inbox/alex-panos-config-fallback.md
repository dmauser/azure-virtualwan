# Decision: PAN-OS Day-0 Config Push Fallback

**Date:** 2026-07-27  
**Author:** Alex (Network Engineer)  
**Lab affected:** `nva-spoke-internet-paloalto/`  
**Status:** IMPLEMENTED

---

## Root Cause — Bootstrap blocked by allowSharedKeyAccess=false

The live deployment of `nva-spoke-internet-paloalto` to DMAUSER-FDPO passed 15/17
structure checks but failed both egress checks (spoke1 → Internet, spoke2 → Internet:
timed out, 0 PA sessions).

**Root cause confirmed:** Management-group policy `allowSharedKeyAccess=false` on
DMAUSER-FDPO blocks `az storage account keys list` (shared-key auth), which
`deploy.sh` Phase 5b uses to upload `bootstrap.xml` and `init-cfg.txt` to Azure
Files. PAN-OS Azure Files bootstrap requires shared-key SMB auth.  When the upload
is blocked, both firewalls boot **factory-default** — no interfaces configured,
no zones, no routes, no NAT → 0 PAN-OS sessions → all spoke egress fails.

---

## What is NOT the problem — Azure Routing is Correct

The Azure routing design for this lab is **not the problem** and must not be changed.

Evidence: The identical Linux NVA lab (`nva-spoke-internet/`) uses the **exact same**
hub routing topology:
- Hub default route: 0/0 → conn-dmz
- conn-dmz static route: 0/0 → ILB 10.0.0.68
- Spokes learn 0/0 → VirtualNetworkGateway (via Virtual WAN)
- **No spoke UDRs** are present or needed

The Linux lab live validation **passes egress**. Therefore:

> **Spoke UDRs are explicitly NOT the fix.** The routing design is proven correct.

---

## Fix — Idempotent Post-Boot API Config Push

Two self-contained scripts that apply the day-0 config to each firewall via the
PAN-OS XML API after the VMs boot, regardless of whether Azure Files bootstrap
succeeded:

| Script | Path |
|--------|------|
| PowerShell | `nva-spoke-internet-paloalto/scripts/apply-panos-config.ps1` |
| Bash | `nva-spoke-internet-paloalto/scripts/apply-panos-config.sh` |

### Approach: import + load + commit

Rather than hand-translating the 320-line `bootstrap.xml` into PAN-OS xpath `set`
commands (error-prone), the scripts upload the exact `bootstrap.xml` file directly:

1. **Poll keygen** — wait up to `TimeoutMinutes` (default 20) for PA API readiness
2. **Import** — `POST multipart type=import&category=configuration` uploads `bootstrap.xml`
3. **Load** — `op: <load><config><from>bootstrap.xml</from></config></load>` makes it candidate
4. **Commit** — push candidate to running; poll job until `FIN/OK`
5. **Verify** — confirm ethernet1/1 up, ethernet1/2 up, 0/0 route, 168.63.129.16/32 route

### Idempotency

If Azure Files bootstrap *did* succeed (future subscription or policy change) and the
scripts are also run, PAN-OS detects candidate = running → returns "no changes to
commit" → scripts complete successfully with no harm.

### Interface contract

Called by Naomi's `deploy.ps1` / `deploy.sh` (Alex does not modify those scripts):
- PowerShell: `-MgmtIps`, `-AdminUsername`, `-AdminPassword`, `-TimeoutMinutes`
- Bash: `--mgmt-ips`, `--admin-username`, `--admin-password`, `--timeout-minutes`

### Why 168.63.129.16/32 matters

The `bootstrap.xml` includes a static route `azure-probe-via-trust` for
168.63.129.16/32 → 10.0.0.65 via ethernet1/2 (trust).  Without it, Azure LB health
probe SYN-ACKs would exit ethernet1/1 (untrust) — Azure SDN drops asymmetric probe
replies as spoofed → ILB stays 0% healthy → spoke egress fails even with correct
routing.  The scripts verify this route is present post-commit.

---

## Files Changed

| File | Action |
|------|--------|
| `nva-spoke-internet-paloalto/scripts/apply-panos-config.ps1` | **Created** |
| `nva-spoke-internet-paloalto/scripts/apply-panos-config.sh` | **Created** |
| `nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml` | **Unchanged** (source of truth) |
| `.squad/agents/alex/history.md` | Updated with learnings |
