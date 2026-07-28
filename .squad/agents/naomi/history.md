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

---

## Phase 5 — PA Live Deploy (2026-07-27)

### Session: nva-spoke-internet-paloalto live deploy to DMAUSER-FDPO / westus3

**Region:** westus3  
**VM SKU:** Standard_DS3_v2 (auto-selected by preflight, allocatable in westus3)  
**Subscription:** DMAUSER-FDPO (78216abe-8139-4b45-8715-6bab2010101e)  
**RG:** rg-nva-spoke-internet-pa  
**Outcome:** Infrastructure 100% deployed, PA config applied via XML API, ILB health probes PASSING. Internet egress (spoke→PA→Internet) NOT confirmed before user tore down the RG.

**PASS/WARN/FAIL (manual evidence, validate-flow.ps1 NOT run):**
- PASS: Hub routingState=Provisioned
- PASS: defaultRouteTable 0.0.0.0/0 → conn-dmz (ResourceId) present
- PASS: conn-dmz staticRoute 0.0.0.0/0 → 10.0.0.68 present
- PASS: Spoke1 effective routes 0.0.0.0/0 → VirtualNetworkGateway (hub)
- PASS: Hub effective routes include 0.0.0.0/0 → conn-dmz
- PASS: Network Watcher next-hop from spoke1 → 1.1.1.1 = 10.100.0.68 (VirtualNetworkGateway)
- PASS: ILB lb-ilb frontend=10.0.0.68, HA-ports, floatingIP=true
- PASS: Public LB lb-public PIP=57.154.34.6, outbound SNAT rule
- PASS: ILB health probes PASSING (active SSH sessions from 168.63.129.16 → trust NICs)
- PASS: PA-FW-0 + PA-FW-1 both running, config committed
- PASS: PA interfaces eth1/1 (untrust DHCP), eth1/2 (trust DHCP) up
- PASS: PA static routes: 0/0 → untrust-GW, 10/8 → trust-GW
- PASS: PA NAT rule trust-to-untrust-masquerade active
- PASS: PA security rule permit-trust-to-untrust (any→any) active
- FAIL: Internet egress spoke1 → curl ifconfig.io timed out (zero PA sessions observed)
- FAIL: Internet egress spoke2 → curl ifconfig.io timed out (zero PA sessions observed)

**Root cause of egress FAIL:** Hub defaultRouteTable uses `nextHopType=ResourceId` pointing to conn-dmz, which routes packets into DMZ VNet without specifying 10.0.0.68 as the physical forwarding IP. When packets enter snet-trust, the trust subnet's effective route `0.0.0.0/0 → hub (VirtualNetworkGateway)` sends them back to hub → routing loop, packets dropped. The conn-dmz `vnetRoutes.staticRoutes` (0.0.0.0/0 → 10.0.0.68, propagateStaticRoutes=true) was intended to solve this but the explicit ResourceId route in defaultRouteTable supersedes it.

**Planned fix (not applied before teardown):** Add `0.0.0.0/0 → VirtualAppliance 10.0.0.68` to spoke workload UDR tables (`udr-vnet-spoke1-workload`, `udr-vnet-spoke2-workload`). This forces spoke traffic directly to the ILB IP, bypassing the vWAN hub routing ambiguity.

**Critical discovery — bootstrap key-auth policy:** DMAUSER-FDPO subscription has a management-group policy enforcing `allowSharedKeyAccess=false` on ALL storage accounts. The bootstrap file share cannot be populated via any available tool. PA VMs boot factory-default. Workaround: apply PAN-OS config via XML API (see naomi-pa-live-deploy.md for full playbook).

**deploy.ps1 Phase 5b bug:** All `az storage` operations (share create, dir create, file upload) in Phase 5b do NOT check `$LASTEXITCODE`. Script logs "✔" for every storage op even when all silently fail. Fix: add `if ($LASTEXITCODE -ne 0) { throw }` after each storage call.

**RG torn down:** User (dmauser@microsoft.com) manually deleted rg-nva-spoke-internet-pa at 2026-07-27T22:07:16Z before egress fix could be applied.

---

## Learnings

### Silent Storage Failure Bug (`| Out-Null` swallows `$LASTEXITCODE` in PowerShell)

In PowerShell, when you pipe an external command to `| Out-Null` (e.g. `az storage directory create ... | Out-Null`), the pipeline internally resets `$LASTEXITCODE` to `0` after the pipe stage completes, regardless of the actual exit code returned by `az`. Additionally, Phase 5b in `deploy.ps1` originally had no `$LASTEXITCODE` checks at all for `az storage share create`, `az storage directory create`, or `az storage file upload`. The combined effect: every storage operation appeared to succeed (the script printed "✔ Bootstrap storage ready") even when all data-plane ops were returning 403 Forbidden due to policy. Fix: (1) remove `| Out-Null` from each az command so the process is directly awaited, then (2) check `$LASTEXITCODE` immediately after the call — before any other statement can overwrite it.

### `allowSharedKeyAccess=false` Policy Detection + Graceful Skip Pattern

Azure management-group policy can enforce `allowSharedKeyAccess=false` on all storage accounts in a subscription. When this policy is active, `az storage account create --allow-shared-key-access true` succeeds at the ARM management-plane level, but the policy immediately overrides the property back to `false`. Key observations for the fallback pattern:

1. **Management-plane vs data-plane split:** `az storage account keys list` is a management-plane ARM call and succeeds regardless of the `allowSharedKeyAccess` property. The storage key can always be retrieved and passed to Bicep `customData` parameters — so the bootstrap storage account should always be created and the key always retrieved, even in fallback mode.
2. **Effective-setting query:** Immediately after account create, run `az storage account show --query allowSharedKeyAccess -o tsv`. If it returns `false` (or the query fails), the subscription policy is blocking shared-key access.
3. **`$SharedKeyBootstrapAvailable` flag:** Set to `$false` on policy detection; wrap all SMB data-plane operations (share create, directory create, file upload) in an `if ($SharedKeyBootstrapAvailable)` block. The account is still created and the key still passed to Bicep so customData string interpolation resolves correctly.
4. **Bash equivalent:** Use `SHARED_KEY_BOOTSTRAP_AVAILABLE=true/false`; guard with `[[ "$SHARED_KEY_BOOTSTRAP_AVAILABLE" == "true" ]]`; use `|| true` on the effective-key query to prevent `set -euo pipefail` from aborting.
5. **Downgrade unexpected storage failures:** Even when `$SharedKeyBootstrapAvailable` is `$true`, az data-plane ops can still fail (race, transient auth). On failure: log a WARNING, set `$SharedKeyBootstrapAvailable = $false`, and continue — Phase 7b will configure the PAs regardless.

### Phase 7b Post-Boot Config-Push Wiring + `apply-panos-config` Contract

When Azure Files bootstrap is blocked (or for any other reason the PA boots factory-default), Phase 7b provides a universal safety net that always runs after Bicep deployment:

- **Timing:** Phase 7b runs immediately after Phase 7 (read deployment outputs), before Phase 8 (hub routing state poll). The PA VMs may still be booting; Alex's `apply-panos-config.*` scripts handle the boot-wait/retry internally via their `-TimeoutMinutes` / `--timeout-minutes` parameter (default 20 min).
- **PIP lookup:** `main.bicep` outputs only the `nvaNames` array — PA management PIP addresses are NOT in the output contract. Query them directly: `az network public-ip show -g $Rg -n "pip-pa-0-mgmt" --query ipAddress -o tsv` (resource names are `pip-pa-${i}-mgmt`, loop i=0,1 in `palo-alto.bicep`). This avoids any bicep output contract change.
- **Contract (call only — Alex owns implementation):**
  - PowerShell: `apply-panos-config.ps1 -MgmtIps <string[]> -AdminUsername <string> -AdminPassword <string> [-TimeoutMinutes 20]`
  - Bash: `apply-panos-config.sh --mgmt-ips "ip1,ip2" --admin-username U --admin-password P [--timeout-minutes 20]`
  - Exit non-zero if any firewall fails.
- **Error handling:** Non-zero exit from `apply-panos-config` logs a WARNING but does not abort the deploy. Phases 8–11 (routing, VPN, connections) are still performed. The operator checks PA config/commit state during egress validation. This keeps the deploy non-destructive even when the first post-boot PA push encounters a still-booting firewall.
- **Idempotent:** Because `apply-panos-config` is designed as verify+repair, re-running Phase 7b on an already-configured PA is safe.

### PA VM-Series Bootstrap Is First-Boot-Only — VM Recreation Required for Config Changes

PAN-OS on Azure VM-Series reads its bootstrap config (bootstrap.xml) **only at initial boot** from the Azure Files share referenced in VM customData. Re-uploading bootstrap.xml to the share after the VM has already booted has **zero effect** — the firewall will not re-apply the config. The only way to deliver a new bootstrap.xml to an already-running PA VM is to **delete and recreate the VM** so it re-bootstraps on the next boot. This applies to any bootstrap.xml change (routing, policies, NAT rules, etc.). Workaround for running VMs: use `apply-panos-config.ps1` (Phase 7b) to push config via PAN-OS XML API.

### Fresh Password via `$env:ADMIN_PASSWORD` Redeploy Pattern

When redeploying the PA lab to pick up a bootstrap.xml change:
1. Generate a strong password and store it in `$env:ADMIN_PASSWORD` (≥12 chars, upper/lower/digit/symbol): `$env:ADMIN_PASSWORD = 'PaLab!' + [guid]::NewGuid().ToString('N').Substring(0,14)`
2. Save to a temp file for cross-shell persistence: `Set-Content -Path .squad/agents/naomi/deploy-pw.tmp -Value $env:ADMIN_PASSWORD -NoNewline`
3. Run `deploy.ps1` from the `nva-spoke-internet-paloalto/` directory with `-DeployOnPrem:$false` (required to suppress `Read-Host` in non-interactive mode)
4. deploy.ps1 checks `$env:ADMIN_PASSWORD` at Phase 2 and skips the interactive password prompt
5. Report the password to the user at the end (needed to SSH to spokes and reach PA GUI)

### `az group delete --no-wait` Race Condition with Immediate Recreation

**Critical pitfall:** `az group delete --no-wait` queues an asynchronous deletion. When `az group show` returns "not found" (typically 20-30 min later), the Azure ARM deletion pipeline is still processing child resources in the background — especially slow resources like vWAN hubs. If you immediately re-deploy into the same RG, the new resources can have the same names as resources still being deleted by the ARM pipeline. The ARM pipeline will then **delete your newly created resources** even though they were created after the group deletion was initiated.

**Fix:** After the RG disappears from `az group show`, wait an additional **10 minutes** before starting any new deployment in that RG to ensure the ARM deletion pipeline is fully cleared.

### AADSTS530004 Conditional Access Token Expiry — Use REST API with Bearer Token

In DMAUSER-FDPO (tenant `16b3c013-d300-468d-ac64-7eda0820b6d3`), the `az` CLI silently uses cached tokens that expire after ~60-90 minutes. After the first command in a shell completes, subsequent `az` commands can fail with `AADSTS530004 AcceptCompliantDevice setting isn't configured for this organization`. The CLI retries silently and returns `ResourceNotFound` or similar errors rather than the real auth error — difficult to diagnose.

**Workaround for long-running deploys:** At shell start, run `az account get-access-token --query accessToken -o tsv` once and save the token. For all subsequent ARM operations, use `Invoke-RestMethod` with the bearer token directly instead of `az` CLI commands. This bypasses the CA-aware silent token refresh. Token validity is typically ~60 min from issuance — save a timestamp; regenerate before it expires.

### vWAN Hub Serializes Connection Operations

Azure vWAN hub only allows one hub VNet connection operation at a time. Attempting to `PUT` or `DELETE` a connection while another is in `Updating` state returns `400 AnotherOperationInProgress`. Always poll the previous connection to `Succeeded` before starting the next one. This applies to both `az network vhub connection create` (which doesn't serialize automatically) and REST API PUTs.

### PA commit-force After apply-panos-config.ps1

When `apply-panos-config.ps1` runs immediately after a fresh PA boot, the PA may still be in the middle of auto-commit (job type `AutoCom`). The `commit` API call will fail with `auto-commit not yet finished — use commit force`. Pattern:
1. Poll `show jobs all` until job type `AutoCom` shows `status=FIN result=OK`
2. Then issue `commit-force` (cmd `<commit-force></commit-force>`) — this succeeds even while auto-commit is finishing
3. Poll job 3 for `status=FIN result=OK` before verifying live routing table

### Probe Route Visible in Routing Table Before Commit (VR config side-effect)

After `apply-panos-config.ps1` sets the virtual-router config via `action=set`, the route `168.63.129.16/32 → 10.0.0.65` appears in `show routing route` immediately — even before the commit completes. This is because PAN-OS installs candidate VR config into the kernel's FIB on `set`. However, commit is still needed to make the config persistent across reboots.

### vWAN Spoke UDR Anti-Pattern: Do NOT Use `VirtualAppliance` Pointing to ILB in Another VNet

In a vWAN topology, spoke workload subnet UDRs with `nextHopType=VirtualAppliance` pointing to an ILB frontend IP (e.g. `10.0.0.68`) in the DMZ VNet (connected to the hub but not directly peered to the spoke) resolve as `nextHopType=None` in the spoke's effective route table. Azure treats `None` as a null/drop route — spoke egress is silently dropped.

**Correct pattern:** Leave spoke workload UDR tables empty (`routes: []`). The vWAN hub's `defaultRouteTable` propagates `0/0 → conn-dmz` to connected spoke VNets as a `VirtualNetworkGateway` route (source: VirtualNetworkGateway, nextHop: hub gateway IP). This route correctly routes spoke traffic via the hub → DMZ VNet → ILB → PA NVA without any UDR intervention. Adding a conflicting User route overrides the VNG route and marks it Invalid.

**Signal to look for:** If `az network nic show-effective-route-table` shows `"source": "User", "state": "Active", "nextHopType": "None"` for a UDR with `nextHopType: VirtualAppliance`, the next-hop IP is not resolvable as a virtual appliance in the local VNet context — traffic will be dropped.

**deploy.ps1 fix:** Phase 10b was changed from adding `0/0 → VirtualAppliance → ILB` to a no-op comment. Do not add spoke UDR routes in vWAN deployments where hub routing handles the 0/0 propagation.

### Westus3 VM Capacity Constraints (July 2026)

- All Dv2 SKUs (DS3_v2, DS4_v2, etc.) blocked by capacity in westus3
- B2s, B2ms: pass `az vm list-skus` restriction check but fail SkuNotAvailable at allocation time — `list-skus` is unreliable for capacity
- D8s_v4, D2s_v3: allocatable in westus3 as of July 2026
- D4s_v4/D4_v4/D4s_v5/D4_v5: only support 2 NICs — cannot be used for PA NVA (needs 3 NICs). Must use D8s variants (D8s_v4, D8s_v5, D8_v4, D8_v5) which support 4 NICs.
- Use real allocation probe (`az vm create` in throw-away RG) to detect spoke VM capacity — `list-skus` gives false positives.

### Full Deploy/Egress Cycle (Cycles 1-5) — Final Outcome 2026-07-27

Multi-cycle deploy to resolve PA egress for rg-nva-spoke-internet-pa:
- **Cycle 1 (single-VR):** ILB 100%, egress broken — UDR missing
- **Cycles 2-4:** Blocked by Dv2 capacity; D4s 2-NIC limit discovered; SKU candidates updated
- **Cycle 5 (dual-VR + Phase 10b UDR):** Bicep ✅, hub ✅, connections ✅, both LBs 100% — but egress STILL broken because Phase 10b UDR's `VirtualAppliance` cross-hub next-hop resolved as None/drop
- **Fix (post-cycle 5):** Deleted conflicting UDR 0/0 routes; vWAN hub VNG route became Active; spoke egress immediately passed — both spokes returned `172.182.236.138` (lb-public PIP) ✅

*Last update: 2026-07-27T18:00:00-05:00*
