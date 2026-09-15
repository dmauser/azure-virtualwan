# Findings

Observations from running this lab against real Megaport circuits and a real GCP
on-premises simulator. Everything below is backed by a route capture taken with
[`scripts/dump-routes.ps1`](../scripts/dump-routes.ps1); reproduce it with:

```powershell
.\scripts\dump-routes.ps1 -ResourceGroup rg-er-failover-dual-hub -Label steady-state -SkipVms
```

| # | Severity | Area | Finding |
|---|----------|------|---------|
| 1 | 🔴 High | Routing | Megaport MCR transits Azure prefixes between the two circuits |
| 2 | 🟠 Medium | Resilience | ExpressRoute **secondary** BGP session is down on both circuits |
| 3 | 🟡 Low | Routing | `10.0.0.0/8` from GCP is a supernet of every Azure prefix in the lab |
| 4 | 🟡 Low | Cost | vHubs and ER gateways dominate the run rate and cannot be stopped |
| 5 | ⚪ Info | Security | Spoke NSG permits all protocols/ports from all RFC1918 |

---

## 1 — Megaport MCR transits Azure prefixes between the two circuits

Both ExpressRoute circuits terminate on the **same** MCR. The MCR re-advertises
what it learns from one Azure VXC onto the other, so each circuit receives the
*other* region's Azure prefixes back, with `12076` (Microsoft) already in the
AS-path:

```text
erfo-er-chicago learned routes
  10.1.0.0/23    169.254.171.249    65001 12076
  10.20.0.0/24   169.254.171.249    65001 12076

erfo-er-dallas learned routes
  10.0.0.0/23    169.254.172.17     65001 12076
  10.10.0.0/24   169.254.172.17     65001 12076
```

The effect is visible in the hub route tables:

```text
erfo-hub-wus2 defaultRouteTable
  10.1.0.0/23    -> ExpressRouteGateway    <-- the other hub's own address space
  10.20.0.0/24   -> Remote Hub

erfo-hub-scus defaultRouteTable
  10.0.0.0/23    -> ExpressRouteGateway    <-- mirror image
  10.10.0.0/24   -> Remote Hub
```

### Why Azure picks the ExpressRoute path

This is not an Azure bug — it is the documented algorithm doing exactly what it
should. With `hubRoutingPreference = ASPath`:

1. Prefer the shortest BGP AS-path, irrespective of the source of the route.
2. Prefer routes from local hub connections over routes learned from a remote hub.

The two candidate paths for `10.1.0.0/23` at `erfo-hub-wus2` are:

| Path | AS-path | Length |
|------|---------|--------|
| via ExpressRoute (hairpin through the MCR) | `65001 12076` | 2 |
| via branch-to-branch from `erfo-hub-scus`  | `65520 65520` | 2 |

Virtual WAN prepends `65520 65520` to every route it advertises hub-to-hub, so
the two paths **tie** on rule 1. Rule 2 then breaks the tie in favour of the
*local* ExpressRoute connection.

> Reference: [Virtual hub routing preference](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing-preference)

### Why it matters

- Hub-to-hub traffic leaves Azure, crosses Megaport and comes back, burning
  **metered** ExpressRoute bandwidth on both 50 Mbps circuits.
- It invalidates the failover test. You cannot distinguish "failed over to the
  remote hub" from "hairpinned through the MCR" by looking at reachability alone.
- The `169.254.x` peering /30s and the GCP `/29` are also being injected into
  Azure. Link-local space should never be routed.

### Fix

**Preferred — filter on the MCR.** Apply an export policy toward each Azure VXC
that denies any prefix whose AS-path contains `12076`, plus `169.254.0.0/16`.
This keeps Azure↔Azure on branch-to-branch and Azure↔GCP on the local circuit.

**Alternative — filter in Azure.** Apply a **route-map inbound** on each
ExpressRoute connection denying `10.0.0.0/23`, `10.1.0.0/23`, `10.10.0.0/24`,
`10.20.0.0/24` and `169.254.0.0/16`. Route-maps are supported on ExpressRoute
connections in both directions and can filter routes.

> ⚠️ Do **not** try to solve this with an *outbound* route-map. Best-path
> selection runs *before* outbound route-maps are applied, so an outbound map
> cannot influence which path a hub chooses.
>
> Reference: [Apply route-maps to connections](https://learn.microsoft.com/azure/virtual-wan/route-maps-about#apply-route-maps-to-connections)

---

## 2 — ExpressRoute secondary BGP session is down on both circuits

```text
erfo-er-chicago  secondary  169.254.171.253  65001  Active
erfo-er-dallas   secondary  169.254.172.21   65001  Active
```

`Active` is a BGP state, not a health status — it means the session is
repeatedly attempting to connect and has never reached `Established`. The
secondary ARP tables confirm it: they contain the Microsoft MAC only, with no
on-premises entry.

Each circuit is therefore **single-homed at the MCR**. Consequences:

- The ExpressRoute availability SLA, which assumes both links, does not apply.
- A "circuit down" test in this lab is really a *primary link down* test.

Either provision a second VXC per circuit on the MCR so both ExpressRoute links
come up, or treat this as a known limitation and say so in the test plan. The
hub-level failover this lab demonstrates is still valid; only the intra-circuit
redundancy is missing.

---

## 3 — `10.0.0.0/8` overlaps the entire Azure address plan

GCP advertises `10.0.0.0/8` alongside `192.168.100.0/24`. The `/8` is a supernet
of every Azure prefix here (`10.0.0.0/23`, `10.1.0.0/23`, `10.10.0.0/24`,
`10.20.0.0/24`).

Longest-prefix-match keeps this safe in steady state, and the `/8` is a
deliberately convenient single prefix to watch during failover. But it fails
*open* rather than closed: if a spoke's route ever stops propagating, traffic to
that spoke matches the `/8` and is sent to GCP instead of being dropped.

If you want a failover probe with no overlap, advertise something outside
`10.0.0.0/8` — `172.31.0.0/16` works and keeps the same "one prefix visibly
moves" property.

---

## 4 — Cost is dominated by resources that cannot be stopped

The lab already uses `Standard_B1s` VMs, Standard HDD disks and a nightly
auto-shutdown. That is correct, but it optimises the *smallest* line item.

The run rate is dominated by:

- 2 × Virtual WAN hub
- 2 × ExpressRoute gateway (1 scale unit each)
- 2 × 50 Mbps metered ExpressRoute circuit

None of these can be deallocated. Stopping the VMs changes very little; the hubs
and gateways bill hourly until they are **deleted**. Treat
[`scripts/cleanup.ps1`](../scripts/cleanup.ps1) as part of the test procedure,
not as an afterthought, and confirm current rates on the
[pricing calculator](https://azure.microsoft.com/pricing/calculator/) before
leaving the lab running.

The ExpressRoute gateway module now pins `autoScaleConfiguration.bounds.max`
equal to `min` so the gateway cannot silently autoscale past the requested scale
unit and bill for the extra capacity.

---

## 5 — Spoke NSG is intentionally permissive

`modules/spoke-vnet.bicep` creates `allow-private-rfc1918`, which permits **all
protocols on all ports** from `10.0.0.0/8`, `172.16.0.0/12` and
`192.168.0.0/16`. That is deliberate — it keeps the failover tests from being
confused by NSG drops.

It is worth knowing about if you copy this module into anything that is not a
throwaway lab. Tightening it to ICMP plus TCP 22 would cover everything the
lab's own tooling actually uses.
