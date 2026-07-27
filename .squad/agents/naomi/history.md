# Naomi — History (Summarized)

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Career Arc Summary

### Phase 1: Repository Foundations (2026-05-04)
- Cataloged 30+ labs with LABS_INDEX.md and learning path ordering (fundamentals → advanced → hybrid/migration)
- Architected unified-lab framework with centralized Bicep type definitions and modular composition
- **Key Insight:** Centralized types prevent drift; module composition enables simple-to-complex topology scaling from same codebase

### Phase 2: SVH-Dynamic-ER-RI Lab Delivery (2026-06-15)
- Authored production Bicep orchestrator + all supporting modules (vwan, vhub, firewall, spoke, VM, KV, ER diagnostics)
- Designed deploy/cleanup scripts with correct phase sequencing (hub provisioning → ER gateway → spoke connections → firewall → Routing Intent)
- Implemented dual-path ER gateway creation (Bicep + CLI fallback) and demand-driven gateway model
- **Key Decisions:** Per-hub vmSize for capacity resilience, admin password inline (params safe to commit), spoke connections/RI script-driven (ARM timing gates)
- **Integration:** Cross-team naming contracts with Amos (validate), Alex (routing-intent), Holden (docs)

### Phase 3: Bug Fix + Hardening (2026-06-15)
- **BUG 1 (CRITICAL):** `az network vhub routing-intent` uses `--vhub` (not `--vhub-name`). Fixed infinite polling in all 4 scripts.
- **BUG 2:** Unbounded poll loops → added iteration counters + timeout guards (7 poll loops, 5–20 min each)
- **BUG 3:** `az vm list-skus` unreliable for capacity checks → implemented synchronous probe (Phase 5b) with SKU retry loop + throw-away RG
- **Feature:** Timestamped output across all scripts (`[HH:mm:ss]` prefixes on every phase/poll tick)
- **Learning:** Always verify CLI parameter names with `--help` before new calls; routing-intent and vhub-connection are distinct subcommand trees

### Phase 4: Live Deployment Round 2 (2026-06-16)
- 75-minute end-to-end deployment of 4-hub secured vWAN (westus, westus2, westus3, eastus2) with ER, AzFw Basic, Routing Intent both-mode
- Pre-flight VM capacity probe passed all 4 regions (Standard_B2s), preventing post-provisioning failures
- **Learning 1:** Windows detached processes don't inherit CLI context → use async-attached for long deploys
- **Learning 2:** Subscription 78216abe lacks bring-your-own-public-IP capability; lab defaults (no public IP) correct
- **Learning 3:** Single-char VNet/subnet names fail capacity probe (`NetcfgInvalidVirtualNetworkSite`); probe uses 7+ char names

## Learnings
- grep `routing-intent.*--vhub-name` → 0 in all 4 scripts ✔
- PowerShell Parser `deploy.ps1` → 0 errors ✔
- PowerShell Parser `validate.ps1` → 0 errors ✔
- `bash -n deploy.sh` → PASSED ✔
- `bash -n validate.sh` → PASSED ✔
- `deploy.sh` LF-only (0 CRLF) ✔
- `validate.sh` LF-only (0 CRLF) ✔

## Learnings

### 2026-06-15 — Password-Only VM Auth (removed SSH key requirement)

- **Context**: VMs in the svh-dynamic-er-ri lab were deploying with both SSH key and password authentication. The SSH key was required at deploy time, causing friction. VMs have no public IP, so SSH key auth from the internet was never used in practice — password + Serial Console is the only real access path.

- **Decision**: Removed all SSH key prompts and ephemeral keygen logic from `deploy.sh` and `deploy.ps1`. `sshPublicKey` Bicep param now defaults to `''` (empty string). The `ubuntu-vm.bicep` module uses a ternary on `empty(sshPublicKey)` to conditionally include the `ssh.publicKeys` block — only if a key is actually provided. `disablePasswordAuthentication: false` is always set, ensuring Serial Console and password SSH always work.

- **Bicep pattern** for optional SSH key in `linuxConfiguration`:
  ```bicep
  linuxConfiguration: empty(sshPublicKey) ? {
    disablePasswordAuthentication: false
  } : {
    disablePasswordAuthentication: false
    ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
  }
  ```

- **Files changed**: `ubuntu-vm.bicep`, `main.bicep`, `deploy.sh`, `deploy.ps1`, `README.md`, `docs/troubleshooting.md`, `docs/architecture.md`, `docs/cost-control.md`.

- **Verification**: `az bicep build --file main.bicep` → 0 errors (1 pre-existing upgrade warning). `deploy.ps1` Parser → 0 errors. `bash -n deploy.sh` → PASSED. deploy.sh has 0 CRLF sequences (LF-only).

- **Key Vault storage** of `vm-admin-username` and `vm-admin-password` secrets was already implemented and is kept unchanged. The deployment summary in both scripts now prominently shows how to retrieve credentials with `az keyvault secret show`.



**New lab added:** `3vhub-er-ri/` — 3-region vWAN, ER on 2 hubs, AzFw Basic, Routing Intent (private only).

**Key CLI patterns used:**

- **Hub routing preference at create time:**
  ```bash
  az network vhub create ... --hub-routing-preference ASPath
  ```
  With fallback post-create if flag is silently ignored by older CLI extension:
  ```bash
  az network vhub update -g $rg -n $hubname --hub-routing-preference ASPath
  ```

- **Native CLI Routing Intent (private traffic only, no bicep):**
  ```bash
  fwid=$(az network firewall show -g $rg -n $hubname-azfw --query id -o tsv)
  az network vhub routing-intent create -g $rg --vhub-name $hubname -n $hubname-ri \
    --routing-policies '[{"name":"PrivateTraffic","destinations":["PrivateTraffic"],"nextHop":"'"$fwid"'"}]'
  ```
  Poll with:
  ```bash
  az network vhub routing-intent show -g $rg --vhub-name $hubname -n $hubname-ri \
    --query 'provisioningState' -o tsv
  ```

- **Azure Firewall Basic on vHub:**
  ```bash
  az network firewall create -g $rg -n $hubname-azfw \
    --sku AZFW_Hub --tier Basic --virtual-hub $hubname \
    --public-ip-count 1 --firewall-policy <policy-id> --location <region>
  ```
  Policy must also be Basic SKU: `az network firewall policy create ... --sku Basic`

- **ER service-key pause + poll pattern** (interactive script):
  1. Print service keys via `az network express-route show --query serviceKey -o tsv`
  2. Pause with `read -p "Press ENTER once circuits show Provisioned..."`
  3. Poll loop with configurable `MAX_WAIT_MIN=180`, `sleep 30`, abort with resume hint on timeout
  4. Timeout message includes instruction to re-run from Phase 9 onward

## Session: nva-spoke-internet Bicep IaC build (2026-07-24)

**Requested by:** Daniel Mauser  
**New lab:** `nva-spoke-internet/bicep/` — full Bicep IaC for the IPTables NVA internet-breakout lab.

### Files Created

| File | Description |
|------|-------------|
| `cloud-init/nva.yaml` | DMZ NVA: ip_forward, iptables MASQUERADE (eth0), FORWARD ACCEPT, SSH ACCEPT, netfilter-persistent save |
| `cloud-init/onprem-nva.yaml` | On-prem NVA: strongSwan + FRR install, ip_forward, bgpd enabled, services enabled |
| `cloud-init/workload.yaml` | Workload VM: ping, traceroute, tcpdump, curl, net-tools, dnsutils |
| `modules/vm.bicep` | Generic Ubuntu 22.04 VM: password auth, managed boot diagnostics (no storageUri), StandardSSD_LRS, optional cloud-init, IP forwarding, public IP, static private IP, LB pool membership |
| `modules/vwan-hub.bicep` | vWAN (vwan-nva-si) + vHub (hub-nva-si) + conditional VPN GW (vpngw-nva-si) |
| `modules/dmz.bicep` | DMZ VNet (10.0.0.0/24), snet-nva + snet-ilb, NSG, UDR (0/0→Internet on snet-nva) |
| `modules/public-lb.bicep` | Standard Public LB: PIP, TCP-22 probe, SSH LB rule (disableOutboundSnat=true), outbound SNAT rule |
| `modules/internal-lb.bicep` | Standard ILB: static frontend 10.0.0.68 in snet-ilb, HA-ports rule (All/0/0) |
| `modules/nva.bicep` | 2x NVA VMs (nva-dmz-0/1): loop, both in Public LB + ILB backend pools, cloud-init |
| `modules/spoke.bicep` | Parameterized spoke VNet + workload subnet + VM; used for Spoke1 (10.1) and Spoke2 (10.2) |
| `modules/onprem.bicep` | Always-deployed module with deployOnPrem gate; on-prem NVA (PIP + static IP) + workload VM + UDR |
| `main.bicep` | RG-scoped orchestrator; wires all modules; 16-output contract for Alex's deploy.sh |
| `main.bicepparam` | Sample params file (placeholder creds, deployOnPrem=false) |

### Compile Result

`az bicep build --file nva-spoke-internet/bicep/main.bicep` → **exit code 0, zero warnings** (after fixing BCP318 null-assertion and unused-var).

### Key Bicep Learnings

1. **Conditional module output null-safety (BCP318):** When accessing properties of a conditional (`if (cond)`) resource inside a conditional module or ternary output, Bicep warns BCP318. Fix: use the non-null assertion operator `resource!.property` — communicates to Bicep that you know the resource exists when the branch is evaluated. Example: `vnet!.properties.subnets[0].id`, `nvaOnprem!.outputs.publicIp`.

2. **"Always deploy, gate inside" pattern for conditional modules:** Instead of `module foo = if (cond)` at the call site (which forces all outputs to be nullable), deploy the module unconditionally and gate resources inside via `if (deployOnPrem)`. Outputs return `''` when not deployed. This avoids `reference()` on undeployed resources and removes BCP318 from caller. Trade-off: the module file always runs through ARM, but with no actual resources created.

3. **HA-ports ILB rule shape:** `protocol: 'All'`, `frontendPort: 0`, `backendPort: 0`, `enableFloatingIP: true`. Frontend IP MUST be static (`privateIPAllocationMethod: 'Static'`). API version `2024-05-01` required for LBs to access latest ARM schema cleanly.

4. **Public LB outbound rule coexistence:** LB rules MUST have `disableOutboundSnat: true` when an outbound rule is also defined on the same LB. Otherwise ARM rejects with a conflict error. The outbound rule uses `allocatedOutboundPorts: 0` (auto) and `enableTcpReset: true`.

5. **cloud-init path resolution:** `loadFileAsBase64('../cloud-init/nva.yaml')` is resolved at Bicep **compile time** relative to the module file location (not CWD). From `modules/nva.bicep`, `../cloud-init/` resolves correctly to `bicep/cloud-init/`. This means the built ARM JSON embeds the base64-encoded cloud-init inline — no runtime file access needed.

6. **customData conditional union pattern:** `union({osProfileBase}, empty(customData) ? {} : {customData: customData})` avoids sending an empty-string base64 blob as customData (which ARM accepts but is wasteful/confusing). Only include `customData` in `osProfile` when non-empty.

7. **LB backend pool membership in looping module:** Pass `lbBackendPoolRefs array = []` to `vm.bicep` as `[{id: poolId1}, {id: poolId2}]` from the calling module. No `[for ...]` loop needed in the NIC ipConfig — `loadBalancerBackendAddressPools: lbBackendPoolRefs` is set directly. Works cleanly with the `[for i in range(0, 2)]` module loop in `nva.bicep`.

8. **Unused param suppression via output:** If a param is needed post-deploy by scripts (e.g., `onpremBgpAsn`) but not used in any Bicep resource, emit it as a module output. This satisfies the Bicep linter and makes it available via `az deployment group show --query properties.outputs`.

9. **DMZ snet-nva UDR (0/0 → Internet):** Critical safety route. When the vHub later programs 0/0 → ILB into the spoke VNets, the NVA subnet must not also receive that propagated route (it would create a routing loop). The UDR with `nextHopType: Internet` on snet-nva pins the NVA's own egress to Internet, overriding any hub-propagated default. `disableBgpRoutePropagation: false` is intentional — we still want specific routes from the hub, just not the 0/0.

10. **Output contract discipline:** All 16 outputs in `main.bicep` have exact names matching Alex's `deploy.sh` `jq` queries. Any rename breaks the deploy chain silently. Documented in `.squad/decisions.md` via inbox entry.

### Address Plan Used

| Resource | CIDR / IP |
|----------|-----------|
| vWAN Hub | 10.100.0.0/23 |
| DMZ VNet | 10.0.0.0/24 |
| snet-nva (DMZ) | 10.0.0.0/26 |
| snet-ilb (DMZ) | 10.0.0.64/26 |
| ILB frontend (static) | 10.0.0.68 |
| Spoke1 VNet | 10.1.0.0/24 → snet-workload 10.1.0.0/26 |
| Spoke2 VNet | 10.2.0.0/24 → snet-workload 10.2.0.0/26 |
| On-prem VNet | 192.168.100.0/24 |
| snet-nva (on-prem) | 192.168.100.0/27 |
| snet-workload (on-prem) | 192.168.100.32/27 |
| On-prem NVA (static) | 192.168.100.4 |

---

## Team Update: 2026-07-24

**Lab Status:** nva-spoke-internet Bicep rebuild **COMPLETE & VALIDATED**

The team successfully rebuilt the nva-spoke-internet lab infrastructure as code. All agents contributed:
- naomi: 13 Bicep files
- alex: 6 deployment scripts
- holden: README + topology diagram
- amos: QA validation (8/8 PASS + 1 LOW defect fixed)

Lab is ready for end-to-end testing.

**2026-07-24 — DEPLOYMENT STATUS:** lab is LIVE in DMAUSER-FDPO (eastus2, B2s), 7/7 validation PASS — Alex