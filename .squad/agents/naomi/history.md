# Naomi — History

**Last Updated:** 2026-07-28  
**Role:** Infra Dev for azure-virtualwan project (Azure CLI, Bicep, ARM, Bash/Shell)

---

## Career Overview

### Phase Summaries
1. **Repository Foundations (2026-05-04):** Cataloged 30+ labs with LABS_INDEX.md, unified-lab Bicep framework, centralized type definitions
2. **SVH-Dynamic-ER-RI Lab (2026-06-15):** Production Bicep orchestrator (vwan, vhub, firewall, spoke, VM, KV, ER), deploy/cleanup scripts, dual-path ER gateway
3. **Bug Fix & Hardening (2026-06-16):** Fixed critical CLI bugs (--vhub vs --vhub-name), unbounded polls → counters+timeout, timestamped output
4. **Live Deployment Round 2 (2026-06-16):** 75-min end-to-end 4-hub ER+AzFw+RI deploy, Windows detached process learnings
5. **nva-spoke-internet-paloalto rebuild (2026-07-27):** 3-subnet DMZ, Palo Alto VM-Series BYOL, 13-phase deploy script, 16-output contract, review gate PASS

### Key Bicep Learnings
- Conditional module null-safety (BCP318 non-null assertion !)
- "Always deploy, gate inside" pattern for conditional modules
- HA-ports ILB (protocol=All, ports=0, enableFloatingIP=true, static frontend)
- Public LB outbound rule coexistence (disableOutboundSnat=true)
- Cloud-init base64 embedded at Bicep compile time

---

## 2026-07-27 — PA Live Deploy Session (rg-nva-spoke-internet-pa)

**Region:** westus3 | **VM SKU:** Standard_DS3_v2 | **RG created:** 2026-07-27, **torn down:** 2026-07-27T22:07:16Z

**Health check results:** Infrastructure 100% deployed. Hub routingState=Provisioned. All 24 resources present (hub, vWAN, 3 VNets, 2 PAs, 2 workload VMs, LBs). ILB health probes PASSING. Both PA VMs running, config committed. Internet egress (spoke→PA→Internet) NOT confirmed; topology teardown occurred before egress test completed.

**Root cause of egress FAIL (planned fix, not applied):** Hub defaultRouteTable used ResourceId pointing to conn-dmz instead of explicit VirtualAppliance 10.0.0.68. Spoke traffic entering trust subnet saw conflicting UDR→VirtualAppliance route (resolved as None/drop), creating a silent drop condition. Planned fix: delete the conflicting UDR 0/0 routes and let vWAN hub VNG route handle propagation.

**Critical discovery:** DMAUSER-FDPO subscription enforces management-group policy llowSharedKeyAccess=false on ALL storage accounts. PA bootstrap Azure Files share cannot be populated via any available auth method. PAs boot factory-default. Workaround: apply PAN-OS config via XML API in Phase 7b (keygen → import → load → commit → poll job status).

**deploy.ps1 bugs fixed (2026-07-27):**
- Phase 5b storage operations lacked $LASTEXITCODE checks. Script logs "✔" for every operation even when all fail. Fix: remove | Out-Null, check $LASTEXITCODE immediately after each az call.
- Phase 10b UDR anti-pattern: vWAN spoke workload UDRs with VirtualAppliance pointing to cross-VNet ILB resolve as None/drop. Changed to no-op comment; let vWAN hub propagate 0/0 as VNG route (correct pattern).

---

## Key Learnings

### Silent Storage Failure Bug (| Out-Null swallows $LASTEXITCODE)
When piping external commands to | Out-Null, PowerShell pipeline resets $LASTEXITCODE to 0 regardless of actual exit code. Phase 5b had no checks at all, causing all storage ops to appear successful even on 403 Forbidden. Fix: remove pipes, check $LASTEXITCODE immediately.

### llowSharedKeyAccess=false Policy Detection + Graceful Skip
Management-group policy can enforce shared-key blocking on storage accounts. Detection via z storage account show --query allowSharedKeyAccess -o tsv returning false. Set a $SharedKeyBootstrapAvailable flag; wrap all SMB operations in conditional. Account creation still proceeds; phase 7b XML API config-push provides fallback.

### Phase 7b Post-Boot Config-Push Wiring
When Azure Files bootstrap blocked, Phase 7b runs immediately after Bicep deployment. PA management PIPs queried directly (resource names: pip-pa--mgmt). Script contract: pply-panos-config.ps1 -MgmtIps <string[]> -AdminUsername -AdminPassword [-TimeoutMinutes 20]. Idempotent; re-running on already-configured PA is safe.

### PA Bootstrap Is First-Boot-Only — VM Recreation Required
PAN-OS reads bootstrap.xml only at initial boot. Re-uploading to Azure Files after boot has zero effect. Workaround for config changes: apply-panos-config.ps1 XML API (Phase 7b) or delete+recreate VM.

### Fresh Password via $env:ADMIN_PASSWORD Redeploy Pattern
Generate strong password, store in $env:ADMIN_PASSWORD, save to .tmp file for cross-shell persistence. deploy.ps1 checks env var at Phase 2 and skips interactive prompt. Requires -DeployOnPrem:False for non-interactive mode.

### vWAN Hub Serializes Connection Operations
Hub allows only one VNet connection operation at a time. Attempting PUT/DELETE while Updating returns 400 AnotherOperationInProgress. Always poll previous connection to Succeeded before next one.

### Westus3 VM Capacity Constraints (July 2026)
- Dv2 SKUs blocked by capacity
- B2s/B2ms: pass list-skus but fail SkuNotAvailable at allocation
- D8s_v4/D8s_v5 allocatable; PA needs 4-NIC support (D4s variants only support 2)
- Use real allocation probe to detect capacity (list-skus unreliable)

### vWAN Spoke UDR Anti-Pattern: Do NOT Use VirtualAppliance Pointing to Cross-VNet ILB
Spoke UDRs with VirtualAppliance pointing to ILB in another vWAN-connected VNet resolve as None/drop. Correct pattern: leave spoke workload UDR tables empty; let hub defaultRouteTable propagate 0/0 as VirtualNetworkGateway route.

### AADSTS530004 Conditional Access Token Expiry
z CLI caches tokens that expire after ~60-90 min. Subsequent commands fail silently with AcceptCompliantDevice errors. Workaround: save token at shell start via z account get-access-token --query accessToken, use Invoke-RestMethod with bearer token for subsequent ARM operations.

### PA commit-force After apply-panos-config.ps1
PA may still be in auto-commit after fresh boot. commit API fails with "auto-commit not yet finished". Pattern: poll show jobs all for AutoCom job, then issue commit-force (succeeds even during auto-commit), poll job 3 for completion.

### Probe Route Visible Pre-Commit
After pply-panos-config.ps1 sets virtual-router config via ction=set, route 168.63.129.16/32 appears in show routing route immediately (PAN-OS installs candidate VR config into kernel FIB). Commit still required for persistence.

### az group delete --no-wait Race Condition
z group delete --no-wait queues async deletion. When z group show returns "not found" (20–30 min), ARM pipeline still processes child resources. Immediate re-deployment can cause new resources to be deleted by the lingering pipeline. Fix: wait additional 10 minutes post-disappearance before new deploy.

---

## 2026-07-28 — PALO-ALTO-CONFIG.md Canonical Reference

**Status:** Implemented & merged to main (commit d5e242a)

Coordinator authored 
va-spoke-internet-paloalto/PALO-ALTO-CONFIG.md (14,168 chars), authoritative over README's single-VR ASCII diagram. Dual-VR design is canonical fix for Active-Active + ELB/ILB deployments. All future Palo Alto Azure work must reference this document.
