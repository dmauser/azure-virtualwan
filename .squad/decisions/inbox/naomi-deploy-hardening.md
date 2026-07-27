# Decision: Harden `nva-spoke-internet-paloalto` Deploy Scripts

**Author:** Naomi  
**Date:** 2026-07-27T22:20:00Z  
**Status:** Implemented — commit `3a88aa7` on branch `dmauser-musical-guide`  
**Files changed:** `nva-spoke-internet-paloalto/scripts/deploy.ps1`, `nva-spoke-internet-paloalto/scripts/deploy.sh`

---

## Context

Live deployment of `nva-spoke-internet-paloalto/` to DMAUSER-FDPO subscription (westus3) showed 15/17 checks PASS but both Internet-egress checks FAIL (zero Palo Alto sessions). Root cause: DMAUSER-FDPO enforces a management-group policy `allowSharedKeyAccess=false` on all storage accounts. The PA Azure Files SMB bootstrap was silently blocked, firewalls booted factory-default, and the deploy script reported success throughout.

---

## Fix 1 — Silent Storage Failure in Phase 5b

**Problem:** All `az storage` data-plane operations in Phase 5b (`az storage share create`, `az storage directory create`, `az storage file upload`) had no `$LASTEXITCODE` checks. In `deploy.ps1`, the directory-create and file-upload calls were additionally piped to `| Out-Null`, which causes PowerShell to reset `$LASTEXITCODE` to 0 regardless of the actual az exit code. Result: every storage operation appeared successful even when returning 403 Forbidden.

**Decision:** 
1. Remove `| Out-Null` from all az storage data-plane calls so exit codes are visible.
2. Add `if ($LASTEXITCODE -ne 0)` checks (ps1) / `if ! az storage ...; then` pattern (sh) after every data-plane call.
3. Print `✔` only on genuine success; on failure log a WARNING and set `$SharedKeyBootstrapAvailable = $false` so Phase 7b handles it.

---

## Fix 2 — `allowSharedKeyAccess` Policy Detection + Graceful Fallback

**Problem:** `az storage account create` never set `--allow-shared-key-access true`, so the property was left at subscription default. Even with the flag set, management-group policy can override it to `false` post-create. There was no detection or graceful skip — the script would attempt (and silently fail) every SMB data-plane operation.

**Decision:** Implement a policy-detection guard immediately after account create:

```
az storage account create ... --allow-shared-key-access true
$effectiveSharedKey = az storage account show --query allowSharedKeyAccess -o tsv
if (policy returned false) → $SharedKeyBootstrapAvailable = $false + WARNING log
```

**Key design choices:**
- **Always create the storage account** (even in fallback mode) — `palo-alto.bicep` references it in `customData`; if account doesn't exist, Bicep fails.
- **Always retrieve the storage key** outside the data-plane guard — `az storage account keys list` is a management-plane ARM call that succeeds regardless of the shared-key policy. Key is still passed to Bicep.
- **Wrap all SMB ops** (`share create`, `dir create`, `file upload`) in `if ($SharedKeyBootstrapAvailable)` — they are skipped cleanly; no 403 spam, no misleading ✔.
- **Phase 7b is the authoritative fallback** — the skip is not an error state; it is an expected policy-compliant code path.

---

## Fix 3 — Phase 7b: Post-Boot PAN-OS Day-0 Config Push

**Problem:** When Azure Files bootstrap is blocked (or fails for any reason), there was no mechanism to configure the PA firewalls. They boot factory-default and egress never works.

**Decision:** Add Phase 7b immediately after Phase 7 (read deployment outputs). It always runs — whether or not Azure Files bootstrap succeeded.

**Implementation:**
- Query `pip-pa-0-mgmt` and `pip-pa-1-mgmt` PIPs directly by resource name (not from `main.bicep` outputs, which only contain `nvaNames`).
- Call Alex's `apply-panos-config.ps1` / `apply-panos-config.sh` (contract: `-MgmtIps`, `-AdminUsername`, `-AdminPassword`; exit non-zero if any firewall fails).
- Non-zero exit logs a WARNING but does NOT abort the deploy — routing phases 8–11 still run. Operator validates PA config state during egress check.
- Idempotent: safe to run against an already-configured PA.

**Timing:** Phase 7b runs before hub routing configuration (Phase 8). Alex's scripts handle PA boot-wait internally (default 20-min timeout).

---

## Alternatives Rejected

| Alternative | Reason rejected |
|---|---|
| Hard-throw on allowSharedKeyAccess=false | Would abort every deploy on DMAUSER-FDPO before Phase 6 (Bicep); no fallback possible |
| Modify `main.bicep` outputs to include PA mgmt PIPs | Changes bicep output contract; could break downstream callers; constraint was scripts-only |
| Add spoke UDRs to fix routing | Identical Linux lab (`nva-spoke-internet/`) passes egress with same routing — routing is NOT the problem; bootstrap failure is |

---

## Validation

- `deploy.ps1`: PowerShell parse `[ScriptBlock]::Create(...)` — **PASS**
- `deploy.sh`: `bash -n` via Git Bash — **PASS** (pre-existing CRLF endings; Git Bash handles correctly)
- `az bicep build -f nva-spoke-internet-paloalto/bicep/main.bicep` — **PASS** (exit 0; no bicep changes made)
