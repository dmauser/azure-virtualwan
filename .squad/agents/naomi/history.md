# Naomi — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Bicep, Azure CLI (.azcli), PowerShell, ARM JSON
- **Domain:** Azure Infrastructure (IaC, deployment automation, monitoring, configuration management)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-07-28 — Spoke Baseline NSG (nva-spoke-internet-paloalto)

**Task:** Added baseline NSG to both spoke workload subnets without disrupting live Palo Alto lab.

**NSG module pattern (spoke.bicep):**
- Resource: `Microsoft.Network/networkSecurityGroups@2023-11-01` (matches routeTable/vnet apiVersion in module).
- Named `nsg-${vnetName}-workload` — parameterized so both instantiations produce distinct names.
- One custom rule: Allow-SSH-Inbound (priority 100, TCP/22, source=VirtualNetwork, destination=VirtualNetwork).
- No custom Deny rules — outbound internet left to platform default AllowInternetOutBound (65001), required for spoke → PA ILB → Internet breakout.
- NSG declared BEFORE the vnet resource (dependency order), then referenced via `networkSecurityGroup: { id: nsg.id }` in snet-workload subnet properties alongside existing routeTable.
- Tags param threaded through to NSG resource.

**What-if blast-radius decision — chose SURGICAL approach:**
- Ran `az deployment group what-if` with live params (but placeholder adminPassword).
- Result: `+ CREATE` for 2 NSGs (correct) + `! Deploy` on 26 other resources (PA VMs, hub, LBs, NICs, UDRs, VNets).
- The `!` items were largely noise from the placeholder password causing drift detection.
- HOWEVER: the task gate requires "ONLY the two NSGs + subnet associations" — the output showed additional re-Deploy noise on hub/PA/LBs, failing the gate.
- Additional constraint: live adminPassword is SecureString — can't retrieve for a clean full deploy.
- **Decision: surgical CLI apply.** Bicep is the IaC source of truth for future clean deploys; live state applied via CLI.
- Confirmed spoke UDRs are empty (`routes: null`) in live Azure — matching Bicep `routes: []` — so spoke UDR route-wipe risk was zero regardless.

**Live verification result:**
- `az network vnet subnet show --query "networkSecurityGroup.id"` on snet-workload for both spokes → returned correct NSG resource IDs ✔
- `az vm run-command invoke vm-spoke1 "curl -s -m 10 ifconfig.me"` → returned `20.163.105.237` (Palo Alto Public LB SNAT IP) — internet breakout fully intact ✔

**apiVersion validated:** `Microsoft.Network/networkSecurityGroups@2023-11-01` confirmed via Microsoft Learn MCP (https://learn.microsoft.com/azure/templates/microsoft.network/networksecuritygroups).
**Default rules validated:** AllowVNetInBound 65000 / AllowAzureLoadBalancerInBound 65001 / DenyAllInbound 65500 (inbound) and AllowVnetOutBound 65000 / AllowInternetOutBound 65001 / DenyAllOutBound 65500 (outbound) confirmed at https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview#default-security-rules.

---

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

### 2026-07-29 — [Cross-agent] Baseline NSG deployment shipped via PR #15 (4a7b93d) — coordinated with Amos validation

---

## Legacy Learnings (Archived 2026-07-28)

**Phase summaries, historical PA deploy details, and pre-2026-07-28 technical documentation moved to history-archive.md for institutional reference.**
