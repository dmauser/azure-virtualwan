# Decision: nva-spoke-internet Flow Validation + Monitoring Enablement

**Author:** Alex (Network Engineer)  
**Date:** 2026-07-27  
**Status:** Accepted  
**Lab:** `nva-spoke-internet`

---

## Context

The `nva-spoke-internet` lab successfully deployed and validated manually on 2026-07-24. The team needed a repeatable, documented way to:

1. **Prove** the Spoke VM → vHub → DMZ connection → ILB → NVA → Public LB → Internet path is functioning correctly (control-plane + data-plane + NVA forwarding + LB metrics).
2. **Optionally** enable persistent flow logs and LB metric streaming for deeper observability.

---

## Decision (a): 4-phase validation approach

### Approach

The `validate-flow.sh` / `validate-flow.ps1` scripts trace the end-to-end breakout across four evidence tiers:

| Phase | Tier | Key commands | What it proves |
|-------|------|-------------|----------------|
| 2 | Control-plane | `az network vhub route-table show`, `az network vhub connection show`, `az network nic show-effective-route-table`, `az network vhub get-effective-routes`, `az network watcher show-next-hop`, `az network watcher test-ip-flow`, `az network watcher test-connectivity` | Route programming is correct end-to-end; vHub, connection, and NIC all agree |
| 3 | Data-plane | `az vm run-command invoke` → `curl https://ifconfig.io` on vm-spoke1 + vm-spoke2 | Actual egress IP matches `pip-lb-public` (SNAT proof) |
| 4 | NVA forwarding | `iptables -t nat -L POSTROUTING`, `conntrack -L`, concurrent `tcpdump` on nva-dmz-0 | NVA is the active MASQUERADE hop; packet capture confirms forwarding |
| 5 | LB metrics | `az monitor metrics list` — 7 metrics on lb-public, 3 on lb-ilb | SNAT port consumption, health probe status, byte/packet counters visible |

### Rationale

- **Control-plane first**: route programming failures (missing static route, wrong next-hop type) surface immediately before any VM traffic is generated.
- **Data-plane second**: `curl ifconfig.io` from both spoke VMs is the definitive SNAT proof — the returned IP must equal `pip-lb-public`.
- **NVA evidence third**: iptables + conntrack + tcpdump provide per-hop forensics when the data-plane check fails or is inconclusive.
- **Metrics last**: metrics confirm sustained activity and SNAT port allocation; they require traffic to have passed through, so they are most useful after phases 2–4 pass.

### Key expected values

- Spoke NIC effective route: `0.0.0.0/0 → nextHopType = VirtualNetworkGateway` (vHub BGP router at 10.100.x.68). This is documented behaviour for vWAN-connected spoke VNets. Ref: https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
- `curl ifconfig.io` from spoke VMs must return the Public LB PIP (`pip-lb-public`, 20.65.77.169 in the live deploy).
- `iptables -t nat -L POSTROUTING` on each NVA must show a `MASQUERADE` rule (provisioned by cloud-init).

---

## Decision (b): Use VNet flow logs — NOT NSG flow logs

### Decision

All `enable-monitoring` scripts create **VNet flow logs**, not NSG flow logs.

### Rationale

| Factor | NSG flow logs | VNet flow logs |
|--------|--------------|----------------|
| New creation blocked | **After June 30, 2025** | ✅ Still available |
| Retirement date | **September 30, 2027** | No announced retirement |
| Scope | Per-NSG | Per-VNet (broader coverage) |
| Traffic Analytics support | Yes (legacy) | Yes (current) |

NSG flow logs are being retired. After 2025-06-30 new NSG flow logs cannot be created. Using VNet flow logs future-proofs the lab and aligns with Microsoft's current guidance.

**Sources:**
- https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
- https://learn.microsoft.com/azure/network-watcher/traffic-analytics

---

## Decision (c): Separate `enable-monitoring` script

### Decision

Monitoring-stack provisioning (`enable-monitoring.sh` / `enable-monitoring.ps1`) is a **separate, optional, standalone script** — not part of `deploy.sh` / `deploy.ps1`.

### Rationale

1. **Cost surprise prevention.** Log Analytics ingestion, Traffic Analytics, and storage for flow logs incur ongoing cost. Including them in the core deploy would create surprise charges for users who just want to spin up the lab topology.
2. **Validate-flow is read-only.** The validate-flow scripts are deliberately zero-side-effect — they must be safe to run at any time without provisioning resources or incurring cost. Monitoring enablement requires resource creation (workspace, storage account, flow log resources, diagnostic settings) and must be in a separate script with an explicit user opt-in.
3. **Idempotency boundary.** Each script has a clean idempotency guarantee: `validate-flow` never writes anything; `enable-monitoring` checks-then-creates each resource individually. Mixing them would make the idempotency logic more complex and the cost contract ambiguous.
4. **Operational lifecycle.** Users may want to enable monitoring mid-session (e.g. to capture a specific traffic pattern) without re-running the full deployment. A standalone script supports this workflow.

### Resources created by `enable-monitoring`

| Resource | Name | Notes |
|----------|------|-------|
| Log Analytics workspace | `log-nva-spoke-internet` | 30-day retention |
| Storage account | `stnvaspk<sub-8-chars>` | Standard_LRS, globally unique |
| Network Watcher | `NetworkWatcher_<region>` | `NetworkWatcherRG` |
| VNet flow log | `flow-vnet-dmz` | Traffic Analytics on |
| VNet flow log | `flow-vnet-spoke1` | Traffic Analytics on |
| VNet flow log | `flow-vnet-spoke2` | Traffic Analytics on |
| LB diagnostic settings | `diag-lb-public` | AllMetrics → workspace |
| LB diagnostic settings | `diag-lb-ilb` | AllMetrics → workspace |

---

## References

- https://learn.microsoft.com/azure/virtual-wan/effective-routes-virtual-hub
- https://learn.microsoft.com/azure/virtual-network/manage-route-table
- https://learn.microsoft.com/azure/network-watcher/network-watcher-next-hop-overview
- https://learn.microsoft.com/azure/network-watcher/network-watcher-ip-flow-verify-overview
- https://learn.microsoft.com/azure/network-watcher/network-watcher-connectivity-overview
- https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer
- https://learn.microsoft.com/azure/load-balancer/monitor-load-balancer-reference
- https://learn.microsoft.com/azure/load-balancer/troubleshoot-outbound-connection
- https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-migrate
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview
- https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-manage
- https://learn.microsoft.com/azure/network-watcher/traffic-analytics
