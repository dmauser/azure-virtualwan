# Failover validation

The goal: prove that when a region's local ExpressRoute circuit fails, that region keeps reaching on-premises **through the other region's circuit** over Virtual WAN hub-to-hub transit.

Replace `<onprem-ip>` throughout with a reachable address behind your ExpressRoute circuits, and `$RG` with your resource group.

---

## 0. Baseline

Confirm both connections are up before testing anything.

```bash
RG=rg-er-failover-dual-hub

# Both circuits should be Provisioned
az network express-route list -g $RG \
  --query "[].{name:name, provider:serviceProviderProperties.serviceProviderName, location:serviceProviderProperties.peeringLocation, state:serviceProviderProvisioningState, circuit:circuitProvisioningState}" \
  -o table

# Both ER connections should exist and be Succeeded
for k in wus2 scus; do
  az network express-route gateway connection list \
    --gateway-name erfo-hub-$k-ergw -g $RG \
    --query "[].{name:name, state:provisioningState}" -o table
done
```

Or run `./scripts/validate.sh -g $RG`.

---

## 1. Record the steady-state routes

The fastest way to capture everything at once — both circuits, both hubs, both
VMs and the GCP side — is the dump script:

```bash
cd scripts
./dump-routes.sh -g $RG --label before-failover
```

It writes `route-dumps/<timestamp>-before-failover/` containing per-section
`.json` / `.txt` files plus a combined `report.txt`. That folder is your
baseline; step 5 diffs against it.

If you only want the hub view by hand, the effective routes on each hub's
default route table are the source of truth for what the hub actually installed.

```bash
az network vhub get-effective-routes \
  --name erfo-hub-scus -g $RG \
  --resource-type RouteTable \
  --resource-id "$(az network vhub route-table show \
      --vhub-name erfo-hub-scus -g $RG -n defaultRouteTable --query id -o tsv)" \
  -o table
```

Repeat for `erfo-hub-wus2`.

**Expect:** each hub shows its on-prem prefixes with `nextHopType = ExpressRouteGateway` pointing at its **own** gateway, and a shorter AS path than the alternative learned via the peer hub.

Save both outputs — you will diff against them after the failure.

### Observed baseline in this lab

With both private peerings up, the expectation above holds on **both** hubs —
each one reaches on-premises over its own local ExpressRoute gateway:

| Hub | Prefix | nextHopType | Meaning |
| --- | --- | --- | --- |
| `erfo-hub-wus2` | `10.0.0.0/8` | `ExpressRouteGateway` | local, via Chicago |
| `erfo-hub-wus2` | `192.168.100.0/24` | `ExpressRouteGateway` | local, via Chicago |
| `erfo-hub-wus2` | `10.20.0.0/24` | `Remote Hub` | SCUS spoke, over branch-to-branch |
| `erfo-hub-wus2` | `10.1.0.0/23` | `ExpressRouteGateway` | SCUS hub prefix, **reflected by the MCR** |
| `erfo-hub-scus` | `10.0.0.0/8` | `ExpressRouteGateway` | local, via Dallas |
| `erfo-hub-scus` | `192.168.100.0/24` | `ExpressRouteGateway` | local, via Dallas |
| `erfo-hub-scus` | `10.10.0.0/24` | `Remote Hub` | WUS2 spoke, over branch-to-branch |
| `erfo-hub-scus` | `10.0.0.0/23` | `ExpressRouteGateway` | WUS2 hub prefix, **reflected by the MCR** |

That is the correct steady state and the one to record before you break
anything. Each hub prefers its own circuit; the peer hub's *spoke* prefix
arrives as `Remote Hub`, which is exactly what branch-to-branch is for.

> **Earlier revisions of this document reported that South Central US used
> `Remote Hub` for `10.0.0.0/8` at steady state, and attributed it to the shared
> MCR. That conclusion was wrong.** The Dallas private peering had been
> administratively disabled during those captures. Once it was re-enabled, South
> Central US converged onto its own gateway, as shown above. The route-reflection
> behaviour described below is real and still worth knowing about, but it does
> **not** stop a hub from preferring its local circuit. The stale dumps under
> `route-dumps/` are kept only as an example of the failure signature.

Both hubs are set to AS-path preference and both ER connections are wired to
`defaultRouteTable`:

```text
erfo-hub-scus  hubRoutingPreference=ASPath  10.1.0.0/23
erfo-hub-wus2  hubRoutingPreference=ASPath  10.0.0.0/23

erfo-erconn-dallas   Succeeded  weight 0  assoc/prop defaultRouteTable  label default
erfo-erconn-chicago  Succeeded  weight 0  assoc/prop defaultRouteTable  label default
```

Verify both peerings are established before recording anything:

```text
=== erfo-er-dallas  AzurePrivatePeering / primary ===
169.254.172.17    4    1m32s     7      <- established, 7 prefixes
=== erfo-er-chicago AzurePrivatePeering / primary ===
169.254.171.249   4    52m18s    7      <- established, 7 prefixes
```

(The `10.0.0.1x` / `10.1.0.1x` neighbours in the same output are the Microsoft
Enterprise Edge routers talking to the hub gateway — not the on-prem side.)

#### Caveat: one MCR means the two circuits are not fully independent

Both circuits hang off the *same* Megaport MCR in the same AS (65001), so the
MCR re-originates each circuit's prefixes into the other. Two tells:

1. `10.1.0.0/23` at WUS2 carries AS path `12076-65001-12076` — South Central
   US's own hub prefix comes *back* to West US 2 through the MCR with
   Microsoft's ASN already in the path.
2. The Dallas MSEE learns **West US 2's** prefixes from the MCR, again with
   Microsoft's ASN in the path:

   ```text
   10.0.0.0/23    169.254.172.17   65001 12076   <- WUS2 hub prefix, reflected
   10.10.0.0/24   169.254.172.17   65001 12076   <- WUS2 spoke, reflected
   ```

Azure drops routes whose AS path already contains its own ASN (12076), so some
of what the MCR offers each hub is discarded on arrival. This does **not**
prevent a hub from preferring its own circuit — as the baseline table above
shows, both hubs do. It does mean the two paths share a single physical failure
domain: an MCR-wide outage takes down *both* circuits at once and no failover is
possible. A production design would use two separate provider routers; a single
shared MCR is a deliberate cost compromise for this lab.

#### Check the peering is actually up before blaming anything else

A hub resolving on-prem prefixes via `Remote Hub` at steady state almost always
means **its own BGP session is down**, not that AS-path preference misbehaved.
That is exactly what happened in this lab: the Dallas private peering was
administratively disabled, which produced

```text
neighbor          as      upDown    statePfxRcd
169.254.172.17    65001   11m2s     Idle         <- primary down
169.254.172.21    65001   39m59s    Idle         <- secondary down
```

with `10.0.0.0/8` and `192.168.100.0/24` absent from the Dallas learned-route
table entirely, and South Central US falling back to `Remote Hub`. Layer 2 was
fine throughout — ARP still showed `169.254.172.17` at MAC `025a.011e.0923`, the
same MCR interface that serves Chicago. Re-enabling the peering restored the
local path within a couple of minutes.

**Always run this before recording a baseline or judging a failover:**

```bash
az network express-route list-route-tables-summary -g $RG \
  -n erfo-er-dallas --peering-name AzurePrivatePeering --path primary -o table
```

- `statePfxRcd` is a **number** → session is established; the hub should be
  using `ExpressRouteGateway` for on-prem prefixes.
- `statePfxRcd` is `Idle` / `Active` / `Connect` → the session is down. Fix it
  before drawing any conclusion about route preference, and discard any failover
  result captured in this state.

> If `-o table` prints nothing, re-run with `-o json` — the CLI occasionally
> emits an empty table for this command.

**What this means for the test.** Both hubs prefer their own circuit at steady
state, so failover is symmetric and you can break either side first:

- Break **Chicago** → WUS2 loses `ExpressRouteGateway` for `10.0.0.0/8` and
  picks up `Remote Hub` via South Central US and Dallas.
- Break **Dallas** → SCUS loses `ExpressRouteGateway` for `10.0.0.0/8` and picks
  up `Remote Hub` via West US 2 and Chicago.

Either direction exercises branch-to-branch transit. Run both (steps 3–7) to
prove the lab converges symmetrically.

> **Do not use "disable the private peering" as your break method** unless you
> intend to test exactly that. It works, but it is easy to forget it is still
> disabled and then misread the resulting `Remote Hub` routes as a preference
> bug. Prefer the reversible methods in step 3 and re-run the peering check
> above after every fail-back.

Both changes are made on the Megaport side — nothing in this repo's Bicep sets
AS path, by design (see `docs/architecture.md`).

---

## 2. Confirm the live data path

The VMs have no public IP. Open a shell with Serial Console (the exact command
is in the `serialConsoleCommands` deployment output):

```bash
az extension add --name serial-console    # one time
az serial-console connect -g $RG -n erfo-vm-scus
```

Log in as `azureuser` with the `adminPassword` you deployed with.

> Serial Console gives you one session, and the tests below want two panes. Run
> `tmux` inside the console and split with `Ctrl+b "`. Alternatively, SSH in
> from on-premises or from the other spoke — the NSG allows RFC1918 inbound —
> but be aware that an SSH session riding ExpressRoute will itself drop when you
> break the circuit. That is precisely why Serial Console is the reference path
> here: it rides the Azure control plane, not the data path under test.

Start a continuous path trace and leave it running in one pane:

```bash
sudo mtr --report-cycles 0 --interval 1 <onprem-ip>
```

In a second pane, a tight ping to timestamp the outage precisely:

```bash
ping -i 0.2 -D <onprem-ip> | tee /tmp/failover.log
```

**Expect:** the path exits via the **Dallas** circuit. Verify from the Azure side:

```bash
az network express-route list-route-table \
  -g $RG -n erfo-er-dallas \
  --peering-name AzurePrivatePeering --path primary -o table
```

---

## 3. Break a circuit

> **Which one to break first:** either — see *Observed baseline* in step 1. Both
> hubs prefer their own circuit at steady state, so failover is symmetric:
> breaking **Dallas** moves South Central US onto `Remote Hub`, and breaking
> **Chicago** moves West US 2 onto `Remote Hub`. Run both to prove the lab
> converges in each direction. The commands below use Dallas; swap
> `erfo-hub-scus-ergw`/`erfo-erconn-dallas`/`erfo-er-dallas` for
> `erfo-hub-wus2-ergw`/`erfo-erconn-chicago`/`erfo-er-chicago` to break Chicago.
>
> Confirm both private peerings are established (step 1) before you start —
> otherwise you are measuring a pre-existing outage, not your failover.

Pick one method. **Option A** is the cleanest simulation of a real circuit failure because it withdraws the BGP routes rather than tearing down Azure objects.

### Option A — disable the BGP session at the provider (recommended)

Shut the BGP session on your CE router, or shut down the VXC in the Megaport portal.

### Option B — disable the ExpressRoute connection in the hub

```bash
az network express-route gateway connection delete \
  --gateway-name erfo-hub-scus-ergw \
  -g $RG -n erfo-erconn-dallas
```

Fast and scriptable, but you must recreate the connection to fail back — redeploying the Bicep template does that.

### Option C — delete the private peering

```bash
az network express-route peering delete \
  -g $RG --circuit-name erfo-er-dallas -n AzurePrivatePeering
```

Closest to a provider-side fault. Recreate with the same ASN/VLAN/subnets to restore.

---

## 4. Observe convergence

Back in the VM panes:

- `ping` drops packets for a few seconds, then resumes.
- `mtr` shows the path change — additional hops appear as traffic transits the West US 2 hub.

Measure the outage from the ping log:

```bash
grep -c 'no answer\|Unreachable' /tmp/failover.log
awk '/bytes from/ {print $1}' /tmp/failover.log | head -1
awk '/bytes from/ {print $1}' /tmp/failover.log | tail -1
```

**Expect:** BGP-driven reconvergence, typically **10–60 seconds** depending on hold timers. There is no sub-second protection here — this is control-plane failover.

---

## 5. Confirm the new path in the control plane

Take a second dump and diff it against the baseline — this is the single most
convincing artefact the lab produces:

```bash
cd scripts
./dump-routes.sh -g $RG --label after-failover
diff -u ../route-dumps/*-before-failover/report.txt \
        ../route-dumps/*-after-failover/report.txt
```

**Expect:** `10.0.0.0/8` changes next hop and gains AS-path length at
`erfo-hub-scus`. Everything else should be near-identical — that narrowness is
the point.

To check a single hub by hand:

```bash
az network vhub get-effective-routes \
  --name erfo-hub-scus -g $RG \
  --resource-type RouteTable \
  --resource-id "$(az network vhub route-table show \
      --vhub-name erfo-hub-scus -g $RG -n defaultRouteTable --query id -o tsv)" \
  -o table
```

**Expect:** the on-prem prefixes now resolve through the **West US 2 hub** rather than the local ExpressRoute Gateway. The AS path is longer than the pre-failure value — that longer path is precisely why it was not selected before, and `ASPath` preference is why it is selected now.

Confirm the traffic is actually crossing Chicago:

```bash
az network express-route list-route-table \
  -g $RG -n erfo-er-chicago \
  --peering-name AzurePrivatePeering --path primary -o table
```

The South Central US spoke prefix `10.20.0.0/24` should now appear advertised over the Chicago circuit.

---

## 6. Fail back

Restore whatever you broke in step 3:

- **Option A** — no-shut the BGP session or re-enable the VXC.
- **Option B** — redeploy the template, or recreate the connection manually.
- **Option C** — recreate the peering with the original ASN, VLAN and subnets.

**Expect:** the direct Dallas path reappears with the shorter AS path and is preferred again. `mtr` returns to the original hop count. Failback is automatic — no intervention beyond restoring the circuit.

---

## 7. Repeat in the other direction

Run the identical sequence from `erfo-vm-wus2`, breaking the **Chicago** circuit instead. West US 2 should lose its `ExpressRouteGateway` next hop for `10.0.0.0/8` and pick up `Remote Hub` via South Central US, while South Central US keeps using its own Dallas gateway and simply becomes the transit hub.

The topology is *logically* symmetric, but as measured it is not symmetric at
steady state (step 1). Expect the Chicago break to move routes on **both** hubs
and the Dallas break to move none.

---

## What "pass" looks like

| Check | Pass criteria |
|---|---|
| Steady state | Each hub uses its own local circuit (`ExpressRouteGateway`) for `10.0.0.0/8` and `192.168.100.0/24`, and `Remote Hub` only for the peer hub's spoke prefix. Confirm both private peerings are established first — see step 1. |
| Failure detection | BGP withdraws the failed path within hold-timer |
| Reroute | Surviving hub's circuit is installed as the new next hop |
| Data plane | Ping resumes, typically inside 60 s |
| Failback | Original path is re-preferred automatically |
| Symmetry | Same behavior in both directions |

---

## Useful commands

```bash
# Circuit provider + circuit state
az network express-route show -g $RG -n erfo-er-dallas \
  --query "{provider:serviceProviderProvisioningState, circuit:circuitProvisioningState}" -o json

# BGP peering status and advertised/received counts
az network express-route peering show \
  -g $RG --circuit-name erfo-er-dallas -n AzurePrivatePeering -o json

# ARP table — proves layer 2 to the provider
az network express-route list-arp-tables \
  -g $RG -n erfo-er-dallas --peering-name AzurePrivatePeering --path primary -o table

# Routes the circuit is advertising to on-prem
az network express-route list-route-tables-summary \
  -g $RG -n erfo-er-dallas --peering-name AzurePrivatePeering --path primary -o table

# Hub-to-hub: what hub-wus2 knows about hub-scus prefixes
az network vhub get-effective-routes --name erfo-hub-wus2 -g $RG \
  --resource-type ExpressRouteGateway \
  --resource-id "$(az network express-route gateway show -g $RG -n erfo-hub-wus2-ergw --query id -o tsv)" \
  -o table
```
