# Expected Results — `validate-flow` Healthy Baseline

> **Canonical healthy baseline** for the `nva-spoke-internet` lab.  
> Captured **2026-07-27** against the live **DMAUSER-FDPO** deployment.  
> Expected final score: **PASS: 12   FAIL: 0   WARN: 2**  
> The 2 WARNs (checks 2g and 2h) require the regional Network Watcher to be enabled —
> run `enable-monitoring.sh` / `enable-monitoring.ps1` to provision it and clear them.

## Environment

| Field | Value |
|-------|-------|
| Subscription | DMAUSER-FDPO (`78216abe-8139-4b45-8715-6bab2010101e`) |
| Resource group | `rg-nva-spoke-internet` |
| Hub | `hub-nva-si` |
| Hub routingState | `Provisioned` |
| Region | `eastus2` |
| Public LB PIP (`pip-lb-public`) | `20.65.77.169` |

---

## Phase 1 — Pre-flight

### Hub routing state

**Command:**
```bash
az network vhub show -g rg-nva-spoke-internet -n hub-nva-si --query routingState -o tsv
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
  -g rg-nva-spoke-internet --vhub-name hub-nva-si -n defaultRouteTable \
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
> Table output does not reliably render array elements — always query with
> `contains(destinations, '0.0.0.0/0')`.

---

### 2b — `conn-dmz` static route 0.0.0.0/0 → ILB

**Command:**
```bash
az network vhub connection show \
  -g rg-nva-spoke-internet --vhub-name hub-nva-si -n conn-dmz \
  --query "routingConfiguration.vnetRoutes.staticRoutes[?contains(addressPrefixes, '0.0.0.0/0')].nextHopIpAddress" \
  -o tsv
```

**Expected:**
```
10.0.0.68
```

**PASS criterion:** Result = `10.0.0.68` — the ILB frontend IP; the HA-ports rule forwards traffic to the active/active NVA pair.

---

### 2c–2d — Spoke NIC effective routes

**Commands:**
```bash
az network nic show-effective-route-table -g rg-nva-spoke-internet -n nic-vm-spoke1 -o table
az network nic show-effective-route-table -g rg-nva-spoke-internet -n nic-vm-spoke2 -o table
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
> Ref: [Effective routes in a virtual hub](https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub)

---

### 2e — vHub effective routes

**Command:**
```bash
az network vhub get-effective-routes \
  --resource-type RouteTable \
  --resource-id <defaultRouteTable-resource-id> \
  -g rg-nva-spoke-internet -n hub-nva-si
```

**Expected:** Command succeeds; routes include `0.0.0.0/0` via `Virtual Network Connection`
`conn-dmz`, and spoke prefixes (`10.1.0.0/24`, `10.2.0.0/24`) via their respective connections.

**PASS criterion:** Command succeeds and produces route output.

---

### 2f — Network Watcher next-hop

**Command:**
```bash
az network watcher show-next-hop \
  -g rg-nva-spoke-internet \
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

> ⚠️ **API inconsistency (by design):** The effective-routes API (`nic show-effective-route-table`)
> reports `VirtualNetworkGateway` for the vHub router; the Network Watcher next-hop API
> (`show-next-hop`) reports `VirtualHub` for the same traffic path. Both refer to the same
> vWAN hub BGP router at `10.100.0.68`. This is expected Azure platform behaviour for
> vWAN-connected spokes.  
> Ref: [Network Watcher next-hop overview](https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview)
> · [Effective routes in a virtual hub](https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub)

---

### 2g — Network Watcher IP flow verify *(WARN — expected until Network Watcher enabled)*

**Command:**
```bash
az network watcher test-ip-flow \
  -g rg-nva-spoke-internet --vm vm-spoke1 \
  --direction Outbound --protocol TCP \
  --local 10.1.0.4:0 --remote 8.8.8.8:443 \
  --nic nic-vm-spoke1
```

**Expected when Network Watcher is enabled:**
```
Access: Allow
```

**On this clean run:** WARN — Network Watcher not enabled in `eastus2`.  
**To clear:** Run `enable-monitoring.sh` / `enable-monitoring.ps1`.

---

### 2h — Network Watcher connectivity test *(WARN — expected until Network Watcher enabled)*

**Command:**
```bash
az network watcher test-connectivity \
  -g rg-nva-spoke-internet \
  --source-resource vm-spoke1 \
  --dest-address ifconfig.io --dest-port 80
```

**Expected when Network Watcher is enabled:**
```
ConnectionStatus: Reachable
```

**On this clean run:** WARN — Network Watcher not enabled in `eastus2`.  
**To clear:** Run `enable-monitoring.sh` / `enable-monitoring.ps1`.

---

## Phase 3 — Data Plane

### Spoke VM → Internet via Public LB SNAT

**Method:** `az vm run-command invoke` executes `curl -s https://ifconfig.io` on each spoke VM.

**Expected return value (both VMs):**
```
20.65.77.169
```

**PASS criterion:** The IP returned by `curl` matches the Public LB PIP (`pip-lb-public` =
`20.65.77.169`), **not** a spoke private IP (`10.1.0.4` / `10.2.0.4`). This proves that
internet egress is SNAT'd through the NVA pair and out the Public LB — the spoke VM is
not bypassing the DMZ path.

---

## Phase 4 — NVA Forwarding Evidence

### iptables MASQUERADE (on `nva-dmz-0` and `nva-dmz-1`)

**Command:**
```bash
sudo iptables -t nat -L POSTROUTING -v -n
```

**Expected output (example from nva-dmz-0, 2026-07-27 ~17:00Z):**
```
Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
 3900  274K MASQUERADE  all  --  *      eth0    0.0.0.0/0            0.0.0.0/0
```

**PASS criterion:** `MASQUERADE` rule present on `POSTROUTING`; `pkts` and `bytes` counters
non-zero and growing with traffic. Both NVAs showed ~3,900 pkts / ~274 KB on the live run.

---

### tcpdump on `nva-dmz-0` (concurrent with spoke `curl`)

**Command:**
```bash
sudo timeout 5 tcpdump -ni any "host 8.8.8.8 or port 443" -c 20
```

**Expected:** Packets captured in the 5-second window showing spoke traffic in-flight through the NVA.

**PASS criterion:** tcpdump exits with non-empty output (not `ERROR`).

---

## Phase 5 — Standard Load Balancer Metrics

Metrics are queried with a 30-minute window: `--start-time` = now−30m, `--end-time` = now,
`--interval PT5M`. The script uses `az monitor metrics list` against the LB resource IDs.

> Ref: [Monitor Load Balancer](https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer)
> · [LB metric CLI examples](https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli)

> ⚠️ **Metric name casing matters.** The correct CLI/REST names use lowercase `nat`:
> `UsedSnatPorts`, `AllocatedSnatPorts` (not `UsedSNATPorts` / `AllocatedSNATPorts`).
> Incorrect casing silently returns no data points.

### Public LB (`lb-public`) — SNAT + availability + traffic

| Metric | Aggregation | Live value (2026-07-27, light traffic) |
|--------|-------------|----------------------------------------|
| `UsedSnatPorts` | Average | ~1.0–1.6 |
| `AllocatedSnatPorts` | Average | 4,096 |
| `SnatConnectionCount` | Total | ~126–136 per 5-min bin |
| `ByteCount` | Total | Non-zero (tens of KB to ~116 MB in active bins) |
| `PacketCount` | Total | Non-zero (~124–101,000 per bin) |
| `VipAvailability` | Average | 100 |
| `DipAvailability` | Average | 100 |

**PASS criteria:**
- `VipAvailability` = 100 → data path to the public LB is available.
- `DipAvailability` = 100 → both NVA backends pass health probes.
- `UsedSnatPorts` / `AllocatedSnatPorts` non-zero → SNAT is configured and in use.
- `ByteCount` / `PacketCount` non-zero → traffic is actively flowing. Zero is normal when
  the lab is idle (no spoke VM generating outbound traffic).
- `SnatConnectionCount` sparse or zero → normal; this counter tracks only **new** SNAT connections
  per interval and is frequently sparse under light traffic.

### Internal LB (`lb-ilb`) — backend health only

| Metric | Aggregation | Live value |
|--------|-------------|-----------|
| `DipAvailability` | Average | 100 |

> **`ByteCount` / `PacketCount` on the ILB are ZERO by design.** Per Microsoft docs:
> *"Bandwidth-related metrics such as SYN packet, byte count, and packet count will not capture
> any traffic to an internal load balancer via a UDR (e.g. from an NVA or firewall)."*
> This is expected behaviour — spoke traffic reaches the ILB via a static route / UDR, which
> bypasses the ILB's traffic counters. Only `DipAvailability` is meaningful here.  
> Ref: [Standard LB diagnostics — multi-dimensional metrics](https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics#multi-dimensional-metrics)

---

## Summary

```
PASS: 12   FAIL: 0   WARN: 2
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
| ✅ PASS | 3 vm-spoke1 data-plane | curl → 20.65.77.169 (PIP) | — |
| ✅ PASS | 3 vm-spoke2 data-plane | curl → 20.65.77.169 (PIP) | — |
| ✅ PASS | 4 iptables MASQUERADE | Rule present, counters non-zero | — |
| ✅ PASS | 4 tcpdump nva-dmz-0 | Packets captured | — |
| ✅ PASS | 5 LB metrics lb-public | DipAvailability 100, traffic non-zero | — |

---

## Cited References

| Document | URL |
|----------|-----|
| Monitor Load Balancer | https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer |
| LB metric CLI examples | https://learn.microsoft.com/azure/load-balancer/load-balancer-monitor-metrics-cli |
| Standard LB diagnostics (multi-dimensional metrics) | https://learn.microsoft.com/azure/load-balancer/load-balancer-standard-diagnostics |
| Effective routes in a virtual hub | https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub |
| VNet flow logs overview | https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview |

---

*Analysis only — verify against vendor documentation before applying.*
