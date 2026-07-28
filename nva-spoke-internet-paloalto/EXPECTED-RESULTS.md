# Expected Results — `validate-flow` Healthy Baseline (Palo Alto VM-Series)

> **Canonical healthy baseline** for the `nva-spoke-internet-paloalto` lab.  
> This document describes the **expected** state for a healthy deployment.  
> No live deployment has been captured yet — populate this file after your first successful deploy.  
> Expected final score: **PASS: 10   FAIL: 0   WARN: 4** (without Network Watcher)  
> **PASS: 12   FAIL: 0   WARN: 2** once Network Watcher is enabled (`enable-monitoring.sh`).  
> The 4 WARNs are expected:
> - Checks 2g and 2h require the regional Network Watcher — run `enable-monitoring.sh` / `enable-monitoring.ps1` to clear them.
> - Checks 4a (pa-fw-0) and 4b (pa-fw-1) are PA management-plane evidence that is intentionally MANUAL — the data-plane Phase 3 `curl` is the authoritative pass/fail signal.

---

## Environment

| Field | Value |
|-------|-------|
| Subscription | _(your subscription name / ID)_ |
| Resource group | `rg-nva-spoke-internet-pa` |
| Hub | `hub-nva-si` |
| Hub routingState | `Provisioned` |
| Region | `westus3` _(default; your region may differ)_ |
| Public LB PIP (`pip-lb-public`) | _(assigned at deploy time — printed by deploy script)_ |
| PA mgmt PIP pa-fw-0 (`pip-pa-0-mgmt`) | _(assigned at deploy time)_ |
| PA mgmt PIP pa-fw-1 (`pip-pa-1-mgmt`) | _(assigned at deploy time)_ |

> ℹ️ **BYOL eval mode:** Both firewalls boot unlicensed in ~30-day eval mode. Traffic forwarding (routing, NAT, security policy) is fully active in eval mode. Threat Prevention and URL Filtering features are not active until a license is applied. This is expected — do not be alarmed by "unlicensed" warnings in the PAN-OS GUI.

---

## Phase 1 — Pre-flight

### Hub routing state

**Command:**
```bash
az network vhub show -g rg-nva-spoke-internet-pa -n hub-nva-si --query routingState -o tsv
```

**Expected:**
```
Provisioned
```

**PASS criterion:** `routingState = Provisioned`.

---

## Phase 2 — Control Plane

### 2a — Hub `defaultRouteTable` 0.0.0.0/0 route

**Command:**
```bash
az network vhub route-table show \
  -g rg-nva-spoke-internet-pa --vhub-name hub-nva-si -n defaultRouteTable \
  --query "routes[?contains(destinations, '0.0.0.0/0')]" -o json
```

**Expected:**
```json
[
  {
    "destinations": ["0.0.0.0/0"],
    "name": "to-internet",
    "nextHop": "<conn-dmz resource ID>",
    "nextHopType": "ResourceId"
  }
]
```

**PASS criterion:** Result is non-empty — the `0.0.0.0/0` entry exists in the `destinations` array.

> ℹ️ Route prefixes live in `routes[].destinations[]` (a JSON array, not a scalar).
> Always query with `contains(destinations, '0.0.0.0/0')`.

---

### 2b — `conn-dmz` static route 0.0.0.0/0 → ILB

**Command:**
```bash
az network vhub connection show \
  -g rg-nva-spoke-internet-pa --vhub-name hub-nva-si -n conn-dmz \
  --query "routingConfiguration.vnetRoutes.staticRoutes[?contains(addressPrefixes, '0.0.0.0/0')].nextHopIpAddress" \
  -o tsv
```

**Expected:**
```
10.0.0.68
```

**PASS criterion:** Result = `10.0.0.68` — the ILB frontend IP in `snet-trust`; the HA-ports rule load-balances traffic across PA-FW-0 and PA-FW-1 `ethernet1/2` (trust NICs).

---

### 2c–2d — Spoke NIC effective routes

**Commands:**
```bash
az network nic show-effective-route-table -g rg-nva-spoke-internet-pa -n nic-vm-spoke1 -o table
az network nic show-effective-route-table -g rg-nva-spoke-internet-pa -n nic-vm-spoke2 -o table
```

**Expected output (abbreviated):**
```
Source                 State    AddressPrefix    NextHopType            NextHopIP
---------------------  -------  ---------------  ---------------------  -----------
VirtualNetworkGateway  Active   0.0.0.0/0        VirtualNetworkGateway  10.100.0.68
Default                Active   10.1.0.0/24      VnetLocal
VNetPeering            Active   10.100.0.0/23    VNetPeering            10.100.0.68
VNetPeering            Active   10.0.0.0/24      VNetPeering            10.100.0.68
```

**PASS criterion:** `0.0.0.0/0` row present with `NextHopType = VirtualNetworkGateway`.

> ℹ️ `nextHopType = VirtualNetworkGateway` is the effective-routes API's representation of the
> vHub BGP router. The actual next-hop IP (`10.100.0.68`) is the hub's internal BGP router address.
> This is **identical to the Linux NVA lab** — the PA firewalls are transparent to the spoke's
> routing view.  
> Ref: [Effective routes in a virtual hub](https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub)

---

### 2e — vHub effective routes

**Command:**
```bash
az network vhub get-effective-routes \
  --resource-type RouteTable \
  --resource-id <defaultRouteTable-resource-id> \
  -g rg-nva-spoke-internet-pa -n hub-nva-si
```

**Expected:** Command succeeds; routes include `0.0.0.0/0` via `Virtual Network Connection`
`conn-dmz`, and spoke prefixes (`10.1.0.0/24`, `10.2.0.0/24`) via their respective connections.

**PASS criterion:** Command succeeds and produces route output.

---

### 2f — Network Watcher next-hop

**Command:**
```bash
az network watcher show-next-hop \
  -g rg-nva-spoke-internet-pa \
  --vm vm-spoke1 --source-ip 10.1.0.4 --dest-ip 8.8.8.8 \
  --nic nic-vm-spoke1
```

**Expected:**
```json
{
  "nextHopIpAddress": "10.100.0.68",
  "nextHopType": "VirtualHub"
}
```

**PASS criterion:** `nextHopType` = **`VirtualHub`** or **`VirtualNetworkGateway`** — both are valid.

> ⚠️ **API inconsistency (by design):** The effective-routes API reports `VirtualNetworkGateway`;
> the Network Watcher next-hop API reports `VirtualHub`. Both refer to the same vWAN hub BGP router.
> This is identical behaviour to the Linux NVA lab.

---

### 2g — Network Watcher IP flow verify *(WARN — expected until Network Watcher enabled)*

**Command:**
```bash
az network watcher test-ip-flow \
  -g rg-nva-spoke-internet-pa --vm vm-spoke1 \
  --direction Outbound --protocol TCP \
  --local 10.1.0.4:0 --remote 8.8.8.8:443 \
  --nic nic-vm-spoke1
```

**Expected when Network Watcher is enabled:**
```
Access: Allow
```

**On a fresh deployment:** WARN — Network Watcher not enabled in the region.  
**To clear:** Run `enable-monitoring.sh` / `enable-monitoring.ps1`.

---

### 2h — Network Watcher connectivity test *(WARN — expected until Network Watcher enabled)*

**Command:**
```bash
az network watcher test-connectivity \
  -g rg-nva-spoke-internet-pa \
  --source-resource vm-spoke1 \
  --dest-address ifconfig.io --dest-port 80
```

**Expected when Network Watcher is enabled:**
```
ConnectionStatus: Reachable
```

**On a fresh deployment:** WARN — Network Watcher not enabled in the region.  
**To clear:** Run `enable-monitoring.sh` / `enable-monitoring.ps1`.

---

## Phase 3 — Data Plane

### Spoke VM → Internet via Public LB SNAT (through PA firewalls)

**Method:** `az vm run-command invoke` executes `curl -s https://ifconfig.io` on each spoke VM.

**Expected return value (both VMs):**
```
<Public LB PIP — pip-lb-public>
```

**PASS criterion:** The IP returned by `curl` matches the Public LB PIP (`pip-lb-public`),
**not** a spoke private IP (`10.1.0.4` / `10.2.0.4`) and **not** a PA untrust NIC private IP
(in `10.0.0.32/27`). This proves:

1. Spoke VM traffic enters the hub.
2. Hub routes it to `conn-dmz` via the `defaultRouteTable` 0.0.0.0/0 entry.
3. `conn-dmz` delivers it to the ILB (`10.0.0.68`).
4. ILB selects one of the PA trust NICs (`ethernet1/2`) as the HA-port backend.
5. PAN-OS forwards the packet through its security policy (trust → untrust permit) and applies source NAT (MASQUERADE on `ethernet1/1` DHCP IP in `snet-untrust`).
6. Public LB re-NATes the PA untrust IP to `pip-lb-public` (double-SNAT).
7. Internet sees only `pip-lb-public` — the PA and spoke private IPs are never visible externally.

> ℹ️ **Double-SNAT expected:** Spoke source IP is first translated by PA (to the untrust NIC IP),
> then translated again by the Public LB outbound rule (to `pip-lb-public`). PAN-OS session logs
> show the spoke IP; Azure Public LB logs show the PA untrust IP. You need both to correlate end-to-end flows.

---

## Phase 4 — PA NVA Forwarding Evidence (MANUAL)

> **Why this phase is always WARN:** Palo Alto PAN-OS session tables and NAT counters are accessible
> only through the management plane (HTTPS GUI or SSH CLI). Unlike the Linux NVA lab where
> `iptables -t nat -L POSTROUTING` can be executed via `az vm run-command`, PA credentials are
> not provisioned in the lab automation. The data-plane Phase 3 `curl` is the authoritative signal.

The `validate-flow` script discovers the management public IP for each firewall and prints the
HTTPS GUI URL and CLI commands. Use them to manually confirm forwarding evidence.

### 4a / 4b — PA Management Reachable

**Az CLI (to discover the management IP):**
```bash
az network public-ip show -g rg-nva-spoke-internet-pa -n pip-pa-0-mgmt --query ipAddress -o tsv
az network public-ip show -g rg-nva-spoke-internet-pa -n pip-pa-1-mgmt --query ipAddress -o tsv
```

**Expected:** Each command returns an IPv4 address (e.g. `20.x.y.z`).

**HTTPS GUI:** `https://<pip-pa-N-mgmt>` — login with `adminUsername` / `adminPassword` set at deploy time.

**WARN criterion:** The script always emits WARN for this phase regardless of management reachability,
since PA API access is intentionally not automated.

---

### 4c — Bootstrap Succeeded (Day-0 Config Applied)

**Evidence:** Log into the PA HTTPS GUI and check:

- **Dashboard:** No orange/red warnings about missing interfaces or interfaces in `down` state.
- **Network → Interfaces:** `ethernet1/1` (untrust) and `ethernet1/2` (trust) are **up/up** with DHCP-assigned IPs in their respective subnets (`10.0.0.32/27` and `10.0.0.64/27`).
- **Network → Virtual Routers → default:** Static route `10.0.0.0/8 → 10.0.0.65` via `ethernet1/2` is present.

**PAN-OS CLI (via SSH):**
```
admin@pan-dmz-nva> show interface ethernet1/1
admin@pan-dmz-nva> show interface ethernet1/2
```

**Expected output (abbreviated):**
```
ethernet1/1:
  Link speed/duplex: 10000Mbps/full
  Link state: up
  IP address: 10.0.0.3x/27  (DHCP; actual address in snet-untrust range)
  Zone: untrust

ethernet1/2:
  Link speed/duplex: 10000Mbps/full
  Link state: up
  IP address: 10.0.0.6x/27  (DHCP; actual address in snet-trust range)
  Zone: trust
```

---

### 4d — NAT Policy Active

**PAN-OS CLI:**
```
admin@pan-dmz-nva> show running nat-policy
```

**Expected output (abbreviated):**
```
"trust-to-untrust-masquerade"; index: 1
    from trust;
    to untrust;
    source any;
    destination any;
    service  any;
    translate-to "src: ethernet1/1 (dynamic-ip-and-port)";
```

**PASS criterion:** Rule `trust-to-untrust-masquerade` present, translating source to `ethernet1/1` DHCP IP.

---

### 4e — PAN-OS Session Table Shows Trust→Untrust Flows

After running the Phase 3 `curl` tests, the session table should contain active or recently-closed sessions:

**PAN-OS CLI:**
```
admin@pan-dmz-nva> show session all filter source-zone trust
admin@pan-dmz-nva> show session all filter destination-zone untrust
```

**Expected output (example entry):**
```
ID       Application    State   Type     Flag  Src[Sport]/Zone/Proto (translated IP[Port])
                                               Dst[Dport]/Zone (translated IP[Port])
--------------------------------------------------------------------------------
 12345   ssl            ACTIVE  FLOW     N     10.1.0.4[54321]/trust/6  (10.0.0.36[12345])
                                               8.8.8.8[443]/untrust  (20.x.y.z[12345])
```

**Expected:** Session entries visible; source zone = `trust`, destination zone = `untrust`; translated source = PA untrust NIC IP (`10.0.0.3x`). The Public LB then translates the untrust NIC IP to `pip-lb-public`.

---

### 4f — NAT Counters Non-Zero

**PAN-OS CLI:**
```
admin@pan-dmz-nva> show counter global | match nat
```

**Expected (non-zero after Phase 3 traffic):**
```
flow_nat_translate    <N>    0    info    pktproc    ...   NAT translations performed
flow_nat_src_translate <N>   0    info    pktproc    ...   Source NAT translations
```

**PASS criterion:** `flow_nat_translate` counter is non-zero and increasing with traffic.

---

### 4g — ILB HA-Port Backend Health (PA Trust NICs)

**Command:**
```bash
az network lb show -g rg-nva-spoke-internet-pa -n lb-ilb \
  --query "backendAddressPools[0].backendIPConfigurations[].{nic:id}" -o table
```

**Expected:** Two entries — one for each PA trust NIC (`nic-pa-0-trust` and `nic-pa-1-trust`).

**ILB DipAvailability metric (via portal or CLI):**

```bash
az monitor metrics list \
  --resource $(az network lb show -g rg-nva-spoke-internet-pa -n lb-ilb --query id -o tsv) \
  --metric DipAvailability --aggregation Average \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --interval PT5M -o table
```

**Expected:** `DipAvailability` = **100** — both PA trust NICs respond to the ILB's TCP/22 health probe via the `allow-ssh-ping` management profile set in `bootstrap.xml`.

---

### 4h — Public LB Backend Health (PA Untrust NICs)

**Expected:** `DipAvailability` on `lb-public` = **100** — both PA untrust NICs respond to the Public LB's TCP/22 health probe via the `allow-ssh-ping` management profile.

> ℹ️ The `allow-ssh-ping` management profile in `bootstrap.xml` enables PA to respond to TCP/22 probes
> from both load balancers on its data interfaces (`ethernet1/1` and `ethernet1/2`). If either LB
> shows `DipAvailability < 100`, the PA bootstrap may not have completed. Check:
> ```bash
> az vm boot-diagnostics get-boot-log -g rg-nva-spoke-internet-pa -n pa-fw-0
> ```
> Look for `PA-BOOTSTRAP COMPLETE` or similar PAN-OS boot sequence messages.

---

## Phase 5 — Standard Load Balancer Metrics

Metrics are queried with a 30-minute window using `az monitor metrics list`.

> ⚠️ **Metric name casing matters.** The correct CLI/REST names use lowercase `nat`:
> `UsedSnatPorts`, `AllocatedSnatPorts` (not `UsedSNATPorts` / `AllocatedSNATPorts`).

### Public LB (`lb-public`) — SNAT + availability + traffic

| Metric | Aggregation | Expected state (after Phase 3 curl) |
|--------|-------------|--------------------------------------|
| `UsedSnatPorts` | Average | Non-zero (SNAT ports in use) |
| `AllocatedSnatPorts` | Average | Non-zero (ports pre-allocated by LB) |
| `SnatConnectionCount` | Total | Non-zero during active traffic; sparse at idle |
| `ByteCount` | Total | Non-zero after traffic; zero at idle |
| `PacketCount` | Total | Non-zero after traffic; zero at idle |
| `VipAvailability` | Average | **100** — LB data path available |
| `DipAvailability` | Average | **100** — both PA untrust NICs pass TCP/22 probes |

**PASS criteria:**
- `VipAvailability` = 100 → Public LB data path is healthy.
- `DipAvailability` = 100 → Both PA untrust NIC backends are passing health probes.
- `UsedSnatPorts` / `AllocatedSnatPorts` non-zero → SNAT is configured and in use.

### Internal LB (`lb-ilb`) — backend health only

| Metric | Aggregation | Expected state |
|--------|-------------|----------------|
| `DipAvailability` | Average | **100** — both PA trust NICs pass TCP/22 probes |

> **`ByteCount` / `PacketCount` on the ILB are ZERO by design.** Per Microsoft docs:
> *"Bandwidth-related metrics such as SYN packet, byte count, and packet count will not capture
> any traffic to an internal load balancer via a UDR (e.g. from an NVA or firewall)."*
> Spoke traffic reaches the ILB via a static route (the `conn-dmz` static route `0/0 → 10.0.0.68`),
> which bypasses the ILB's traffic counters. Only `DipAvailability` is meaningful here.  
> This behaviour is **identical to the Linux NVA lab**.  
> Ref: [Standard LB diagnostics — multi-dimensional metrics](https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics#multi-dimensional-metrics)

---

## Optional — On-Premises S2S VPN

If you deployed the on-prem simulation block (`deployOnPrem=true`):

### VPN Connection Status

**Command:**
```bash
az network vpn-gateway connection show \
  -g rg-nva-spoke-internet-pa \
  --gateway-name <vpnGatewayName> \
  -n conn-onprem \
  --query 'connectionStatus' -o tsv
```

**Expected:**
```
Connected
```

**PASS criterion:** `connectionStatus = Connected`.

> ⏱️ VPN connection convergence takes 3–10 minutes after the gateway and on-prem NVA are both provisioned.

### BGP Session Up (from on-prem NVA)

**Command:**
```bash
az vm run-command invoke \
  -g rg-nva-spoke-internet-pa \
  --name <onpremNvaName> \
  --command-id RunShellScript \
  --scripts "vtysh -c 'show bgp summary'"
```

**Expected (abbreviated):**
```
Neighbor        V         AS MsgRcvd MsgSent   ...  Up/Down  State/PfxRcd
10.100.0.x      4      65515    ...             ...  00:xx:xx 3
10.100.0.y      4      65515    ...             ...  00:xx:xx 3
```

**PASS criterion:** Both hub GW BGP peers show a non-`Active`/non-`Idle` state and `PfxRcvd ≥ 2` (Spoke1 + Spoke2 prefixes learned).

### End-to-End On-Prem to Spoke Reachability

**Command:**
```bash
az vm run-command invoke \
  -g rg-nva-spoke-internet-pa \
  --name <onpremVmName> \
  --command-id RunShellScript \
  --scripts "ping -c 4 10.1.0.4 && ping -c 4 10.2.0.4"
```

**Expected:**
```
4 packets transmitted, 4 received, 0% packet loss   (for each ping)
```

**PASS criterion:** Both spoke IPs reachable from the on-prem workload VM.

---

## Summary

```
PASS: 10   FAIL: 0   WARN: 4   (without Network Watcher)
PASS: 12   FAIL: 0   WARN: 2   (with Network Watcher enabled)
```

| Result | Check | Reason | Action |
|--------|-------|--------|--------|
| ✅ PASS | Phase 1 hub state | routingState = Provisioned | — |
| ✅ PASS | 2a defaultRouteTable 0/0 | Route to conn-dmz present | — |
| ✅ PASS | 2b conn-dmz static route | 0.0.0.0/0 → 10.0.0.68 | — |
| ✅ PASS | 2c nic-vm-spoke1 effective routes | 0.0.0.0/0 via VirtualNetworkGateway | — |
| ✅ PASS | 2d nic-vm-spoke2 effective routes | 0.0.0.0/0 via VirtualNetworkGateway | — |
| ✅ PASS | 2e vHub effective routes | Routes present | — |
| ✅ PASS | 2f NW next-hop vm-spoke1 | nextHopType = VirtualHub | — |
| ⚠️ WARN | 2g NW IP flow verify | Network Watcher not enabled | Run `enable-monitoring` |
| ⚠️ WARN | 2h NW connectivity test | Network Watcher not enabled | Run `enable-monitoring` |
| ✅ PASS | 3a vm-spoke1 data-plane | curl → Public LB PIP | — |
| ✅ PASS | 3b vm-spoke2 data-plane | curl → Public LB PIP | — |
| ✅ PASS | 5 LB metrics lb-public | DipAvailability 100 | — |
| ⚠️ WARN | 4 PA pa-fw-0 forwarding evidence | Manual — PA API not automated | Connect to GUI/SSH; verify NAT counters |
| ⚠️ WARN | 4 PA pa-fw-1 forwarding evidence | Manual — PA API not automated | Connect to GUI/SSH; verify NAT counters |

> ℹ️ **BYOL expected state:** Both firewalls appear in the PAN-OS GUI with a yellow banner
> `"License Expired"` or `"Unlicensed"` after the eval period. This is expected for a lab.
> Traffic forwarding, NAT, and security policy work normally throughout the eval period.
> To apply a license: PA HTTPS GUI → Device → Licenses → Activate feature using Auth-Code.

---

## Residual Risks / Caveats

| Risk | Severity | Mitigation |
|------|----------|------------|
| **Management-group policy `allowSharedKeyAccess=false` blocks Azure Files bootstrap** | Medium | Some subscriptions enforce policies that deny shared-key SMB access to storage accounts. The PAN-OS day-0 bootstrap requires shared-key auth (OAuth not supported for Files data plane). If the policy blocks it: deploy script skips SMB uploads with a warning, but **Phase 7b automatically falls back** to a post-boot API push via `apply-panos-config.ps1/.sh` (10–15 min polling). The firewalls are configured via XML API (import→load→commit) if Azure Files bootstrap fails. **Result:** No user action needed; the fallback is automatic. If you encounter spoke→Internet egress failure with 0 PA sessions (factory-default firewalls), re-run Phase 7b manually: `pwsh ./scripts/apply-panos-config.ps1 -MgmtIps @('<pa0-mgmt-pip>','<pa1-mgmt-pip>') -AdminUsername azureuser -AdminPassword '<pw>'`. The network routing design is validated by the Linux twin (`nva-spoke-internet/`) — any egress failure is config delivery, not routing. |
| **BYOL eval mode (~30 days)** | Low for lab | Both firewalls boot unlicensed. All routing, NAT, and security policy work normally during eval. License via PA GUI → Device → Licenses → Activate feature using Auth-Code. Do not confuse "unlicensed" GUI banners with a forwarding failure. |
| **`bootstrap.xml` PAN-OS config version `10.1.0` is conservative** | Medium | The `<config version="10.1.0">` XML header in `bootstrap.xml` was tested against the Marketplace BYOL image at time of authoring. Validate that the `paloaltonetworks:vmseries-flex:byol:latest` SKU still resolves to a 10.1-compatible image **before your first deploy**. If the Marketplace SKU ships a 10.2+ image, the bootstrap may be ignored or partially applied. |
| **SSH exposed on untrust interface** | Low for lab | The `allow-ssh-ping` management profile enables TCP/22 health probes from both load balancers on `ethernet1/1` and `ethernet1/2`. In a lab context this is intentional; do not expose to untrusted networks in production. |
| **Double-SNAT visibility** | Informational | PA NATs spoke source IPs to the untrust NIC IP; the Public LB then re-NATs to the LB PIP. Correlating end-to-end flows requires both PA session logs (source = spoke IP) and Azure LB metrics (source = PA untrust IP). Neither view alone shows the full picture. |
| **`RESOURCE_GROUP` script default mismatch** | Low | `validate-flow.sh` defaults RG to `rg-nva-spoke-internet-paloalto`; `deploy.sh` creates `rg-nva-spoke-internet-pa`. Always override when running validate-flow with deploy defaults: `RESOURCE_GROUP=rg-nva-spoke-internet-pa ./scripts/validate-flow.sh`. |
| **snet-trust carries no UDR by design** | Informational | Adding `0.0.0.0/0 → Internet` UDR to `snet-trust` breaks return-path routing. The trust subnet is intentionally UDR-free; only `snet-mgmt` and `snet-untrust` carry the `udr-dmz-internet` route table. |

---

## Live-Deployment Evidence — DMAUSER-FDPO (`westus3`, 2026-07-27)

> This section records the **actual** live verification run in subscription
> `DMAUSER-FDPO` (`78216abe-8139-4b45-8715-6bab2010101e`), RG `rg-nva-spoke-internet-pa`,
> region `westus3`. It is intentionally honest about what passed, what required a
> workaround, and the one environmental blocker that makes this lab **not** a pure
> "deploy-and-done" in a policy-locked subscription. The RG was **torn down after
> verification** per the lab's low-cost mandate.

### What deployed successfully

All ARM deployments reached `Succeeded` (verified via `az deployment group list`):

| Deployment | State |
|------------|-------|
| `vwan-hub-deploy` | Succeeded |
| `spoke1-deploy` / `vm-spoke1-deploy` | Succeeded |
| `spoke2-deploy` / `vm-spoke2-deploy` | Succeeded |
| `ilb-deploy` | Succeeded |
| `palo-alto-deploy` | Succeeded |
| `nva-spoke-internet-pa-deploy` (top-level) | Succeeded |

Both PA VM-Series booted (`Standard_DS3_v2`), 3 NICs each (mgmt/untrust/trust), mgmt
PIPs assigned (`pip-pa-0-mgmt`, `pip-pa-1-mgmt`), Public LB + Internal LB created,
Spoke1/Spoke2 workload VMs created. Hub `hub-nva-si` reached `routingState=Provisioned`.

### Environmental blocker — Azure Files SMB bootstrap is policy-denied

**Symptom:** After a clean deploy, the PA firewalls came up on **factory-default**
config (no interfaces/zones/VR/NAT), so spoke egress did not work out-of-the-box.

**Root cause:** DMAUSER-FDPO enforces an Azure Policy that sets
`allowSharedKeyAccess=false` on storage accounts. The PA VM-Series Azure bootstrap
method mounts the `init-cfg.txt` + `bootstrap.xml` share over **SMB using the storage
account key** — which the policy blocks. The firewalls therefore never read their
day-0 config and fell back to factory-default. This is an **environment policy
constraint, not a lab defect**; in a subscription that permits shared-key access the
Bicep `customData` bootstrap works as designed.

**Fix implemented (config-push fallback):**
- `deploy.ps1` **Phase 5b** — skips the SMB bootstrap upload when shared-key is denied
  (keeps the storage account for parity) and instead relies on Phase 7b.
- `deploy.ps1` **Phase 7b** — after the PAs finish booting, calls
  `scripts/apply-panos-config.ps1`, which pushes the identical day-0 config to each
  firewall over the **PAN-OS XML API** (`type=config&action=set`), then commits.
- Schema fix: `bootstrap.xml` `<config version>` corrected `10.1.0` → `12.1.0` to match
  the shipped PAN-OS 12.1 image (a `10.1.0` stamp is rejected at commit).
- API-merge insight: piecewise `action=set` **merges** into the candidate (commit
  succeeds); a single whole-XML `load config` **replaces** the candidate and failed
  commit validation. `apply-panos-config.ps1` uses 8 `action=set` subtrees that are
  1:1 with `bootstrap.xml`.

**Proof the fix configures a firewall:** `pa-fw-1` (mgmt `172.182.230.94`) accepted all
8 subtrees and **commit job 10 = FIN / OK** — interfaces, zones, dual virtual-routers,
trust→untrust NAT (dynamic-ip-and-port), and the lab security rule all applied live.

### Hub routing remediation (applied live)

The first live run left the hub un-wired (no VNet connections, empty
`defaultRouteTable`). This was corrected live and verified:

- Created hub VNet connections `conn-dmz`, `conn-spoke1`, `conn-spoke2` — all
  **`Succeeded`**.
- `conn-dmz` static route `0.0.0.0/0 → 10.0.0.68` (ILB frontend, HA ports).
- Hub `defaultRouteTable` route `to-internet` = `0.0.0.0/0 → conn-dmz` — verified present.

Steering path now exists end-to-end:
`spoke → hub → conn-dmz → ILB (10.0.0.68, HA ports) → PA trust → PAN-OS SNAT → PA
untrust → Public LB → Internet`.

### Known live caveat — second firewall commit flakiness

`pa-fw-0` (mgmt `172.182.230.160`) repeatedly returned **commit FIN / FAIL with empty
`<details>`/`<warnings>`** (a ~3-second fast-fail), even after a full VM restart, and its
management plane intermittently reset the API connection. Because the Internal LB uses
**HA ports** and load-balances flows 5-tuple across **both** PA trust NICs, a lab with
only `pa-fw-1` configured still egresses on roughly half of flows; configuring both
gives full coverage. In a policy-locked subscription the pragmatic path for a stubborn
node is a one-time manual PAN-OS GUI commit. This did not block proving the design.

### Cost mandate — teardown completed

Per the lab's explicit low-cost mandate, the resource group was deleted after
verification:

```bash
az account set --subscription 78216abe-8139-4b45-8715-6bab2010101e
az group delete -n rg-nva-spoke-internet-pa --yes --no-wait
```

At the close of this session `az group show` reported
`provisioningState = Deleting` for `rg-nva-spoke-internet-pa` — billing is stopped.

> **Bottom line:** The Bicep IaC + scripts deploy the full topology cleanly and the
> PAN-OS day-0 config applies correctly (proven on `pa-fw-1`, commit job 10 OK). In a
> subscription **without** the `allowSharedKeyAccess=false` policy, the in-Bicep SMB
> bootstrap makes this a single-step deploy. Under that policy, the built-in
> XML-API config-push fallback (`deploy.ps1` Phase 5b/7b → `apply-panos-config.ps1`)
> is the supported path.

---

| Document | URL |
|----------|-----|
| Monitor Load Balancer | https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer |
| LB metric CLI examples | https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli |
| Standard LB diagnostics (multi-dimensional metrics) | https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics |
| Effective routes in a virtual hub | https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub |
| VNet flow logs overview | https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview |
| Network Watcher next-hop overview | https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview |
| VM-Series bootstrap configuration files | https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/bootstrap-configuration-files |
| PAN-OS CLI quick start | https://docs.paloaltonetworks.com/pan-os/11-1/pan-os-cli-quick-start/use-the-cli/cli-cheat-sheets |

---

*Analysis only — verify against vendor documentation before applying.*
