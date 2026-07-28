# Naomi — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Bicep, Azure CLI (.azcli), PowerShell, ARM JSON
- **Domain:** Azure Infrastructure (IaC, deployment automation, monitoring, configuration management)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-07-27 — PA Live Deploy Session (nva-spoke-internet-paloalto)

Completed full Palo Alto virtual WAN lab deployment in westus3 (rg-nva-spoke-internet-pa). Validated all scripts (deploy.ps1, validate-flow.ps1, enable-monitoring.ps1) in live environment. Result: 7/7 validation PASS, infrastructure stable. Key findings documented in decisions.md.

### 2026-07-28 — [Cross-agent] Phase 4b NetworkWatcherAgentLinux: Coordination with Amos validate-flow.ps1

**Context:** Amos found that validate-flow.ps1 check [2h] (test-connectivity) was failing with `(NetworkWatcherVmExtensionNotInstalled)` on vm-spoke1. The agent extension was absent from enable-monitoring.ps1.

**Decision:** Added Phase 4b block to enable-monitoring.ps1 installing `Microsoft.Azure.NetworkWatcher` (v1.4, auto-upgrade) on vm-spoke1 and vm-spoke2.

**Idempotency fix:** Changed probe from `az vm extension show` (ResourceNotFound → stderr terminates) to `az vm extension list --query "length([?name=='NetworkWatcherAgentLinux'])"` (exits 0, returns 0 when absent).

**Live verification:** enable-monitoring.ps1 exit 0, both spoke VMs report extension provisioning state = Succeeded. [2h] now passes in validate-flow.ps1. Coordinated commit b1230bd, PR #14, merged 67812ca.

---

## Key Technical Learnings (2026-07-28)

**NetworkWatcherAgentLinux:** Required on SOURCE VM for test-connectivity; free; idempotent probe via `az vm extension list` (exits 0, returns 0 when absent).

**az network watcher flow-log:** Location-keyed, never `-g`; correct query: `az network watcher flow-log list --location <region>`.

**Phase 4/5 verified-create pattern:** After any az write, check `$LASTEXITCODE` immediately and re-query; unconditional `Log "Created."` is a bug.

**Extension isolation:** $env:AZURE_EXTENSION_DIR → $env:TEMP\az-ext-vwan-lab wrapped in try/finally; required because user's C:\Temp\azcliext has corrupt application-insights ext that crashes az with WinError 5.

---

## Legacy Learnings (Archived 2026-07-28)

**Phase summaries, historical PA deploy details, and pre-2026-07-28 technical documentation moved to history-archive.md for institutional reference.**
