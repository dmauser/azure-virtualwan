# Troubleshooting

## Deployment

### `Microsoft.ContainerInstance` is not registered

The provider-wait poller runs as a `deploymentScripts` resource, which is backed by Azure Container Instances.

```
The subscription is not registered to use namespace 'Microsoft.ContainerInstance'
```

```bash
az provider register --namespace Microsoft.ContainerInstance --wait
```

### Role assignment fails with `AuthorizationFailed`

`script-identity.bicep` grants the poller identity **Reader** on the resource group. Creating a role assignment requires Owner or User Access Administrator.

If you only have Contributor, deploy with:

```bash
--parameters createRoleAssignment=false
```

…and have someone with the right permission assign Reader to `erfo-erwait-identity` on the resource group before the poller runs. Without that assignment the poller cannot read circuit state and will fail with an authorization error inside the container.

### The deployment appears hung

That is expected and is the whole point of the design. Each circuit's poller blocks until the connectivity provider provisions it. Check where it actually is:

```bash
az deployment group show -g $RG -n er-failover \
  --query "properties.provisioningState" -o tsv

az deployment operation group list -g $RG -n er-failover \
  --query "[?properties.provisioningState=='Running'].{res:properties.targetResource.resourceName, state:properties.provisioningState}" \
  -o table
```

If the running operation is `erfo-erwait-*`, it is waiting on your provider, not stuck.

### Poller fails with `KeyBasedAuthenticationNotPermitted`

```
DeploymentScriptOperationFailed
Key based authentication is not permitted on this storage account.
ErrorCode: KeyBasedAuthenticationNotPermitted   Status: 403
```

`Microsoft.Resources/deploymentScripts` provisions its own storage account and
file share, and mounts that share into the container **using shared keys**. If
your subscription enforces `allowSharedKeyAccess = false` (a common Azure Policy
baseline), the container can never mount its share and the poller fails before
running a single line of `wait-for-er-provisioned.sh`. The container log is
empty because the script never started.

There is no workaround inside the deployment-script model — supplying your own
storage account hits the same policy. Skip the gate instead:

```bash
./scripts/deploy.sh -g $RG --skip-provider-wait
```

```powershell
.\scripts\deploy.ps1 -ResourceGroup $RG -SkipProviderWait
```

That sets `waitForProvider=false`, which drops the poller **and** its managed
identity from the template, and the ExpressRoute connections are created
directly. Because nothing is gating them any more, **confirm both circuits are
already `Provisioned` first**:

```bash
./scripts/get-service-keys.sh -g $RG
```

Order the VXCs, wait for `Provisioned`, then deploy with the flag. Clean up any
failed poller resources left behind by an earlier attempt:

```bash
az deployment-scripts delete --resource-group $RG --name erfo-erwait-chicago --yes
az deployment-scripts delete --resource-group $RG --name erfo-erwait-dallas --yes
```

Note `az deployment-scripts` does not accept `-n`; spell out `--name`.

### The poller timed out

```
Timed out after 6600s waiting for provider provisioning
```

The circuit did not reach `Provisioned` inside the deadline. Read the container log:

```bash
az deployment-scripts show-log -g $RG -n erfo-erwait-dallas
```

`cleanupPreference` is `OnSuccess`, so a failed poller keeps its container and logs.

Then check the circuit directly:

```bash
az network express-route show -g $RG -n erfo-er-dallas \
  --query serviceProviderProvisioningState -o tsv
```

| Value | Meaning |
|---|---|
| `NotProvisioned` | No VXC ordered yet, or ordered against the wrong service key |
| `Provisioning` | Provider is working — raise `waitTimeoutSeconds` and redeploy |
| `Provisioned` | It completed after the poller gave up; just redeploy, the poller succeeds immediately |

Raise the deadline for slow providers:

```bash
--parameters waitTimeoutSeconds=21600   # 6 hours
```

The container itself is capped at `PT2H`, so if you need longer than ~110 minutes also raise `timeout` in `modules/er-wait.bicep`.

### Redeploying does not re-run the poller

It should — `forceUpdateTag` defaults to `utcNow()`. If you overrode it with a static value, change that value or remove the override.

### `Cannot find the private peering` when creating the ER connection

The connection references `.../peerings/AzurePrivatePeering`. The exact ARM error is:

```
ReferencedExpressRouteCircuitPeeringResourceNotFound
Express Route Circuit Peering resource .../expressRouteCircuits/erfo-er-dallas/peerings/AzurePrivatePeering
referenced by Express Route Connection ... not found.
```

The peering is **created by the connectivity provider**, never by this template.
A Megaport **MCR** terminates BGP on both sides, so Megaport pushes
`AzurePrivatePeering` onto the circuit — including the peer ASN, the VLAN and
both `/30` link subnets — when the ExpressRoute VXC is provisioned.

So this error means the VXC is not finished yet. Check:

```bash
az network express-route peering list -g $RG --circuit-name erfo-er-dallas -o table
```

If `peerings[]` is empty, the Megaport side is incomplete. A circuit can sit at
`ServiceProviderProvisioningState = Provisioned` with **zero** peerings
indefinitely — "Provisioned" only means the Layer 2 path exists.

Finish the VXC in the Megaport portal, then redeploy. `er-wait.bicep` polls
until the peering appears (`requirePrivatePeering = true`).

The values Megaport assigned in this lab — **read-only, do not set them in Azure**:

| Circuit | Primary `/30` | Secondary `/30` |
|---|---|---|
| `erfo-er-chicago` | `169.254.171.248/30` | `169.254.171.252/30` |
| `erfo-er-dallas` | `169.254.172.16/30` | `169.254.172.20/30` |

> **Never write the peering from Bicep or the CLI.** Overwriting Megaport's
> addressing tears down the live BGP sessions, and re-`PUT`ting a circuit that
> has a peering in use fails with `ConflictError: The specified bgp peering is
> in use` — which also leaves the circuit in `Failed`. Recover with a bare
> `az network express-route update -g $RG -n <circuit>`.

---

### Virtual hub fails with `InternalServerError`

```
ResourceDeploymentFailure  .../virtualHubs/erfo-hub-wus2
  InternalServerError: An error occurred.
```

Check the hub's routing state:

```bash
az network vhub show -g $RG -n erfo-hub-wus2 --query "{state:provisioningState,routing:routingState}" -o json
```

If `provisioningState` is `Failed` **and** `routingState` is `None`, the hub router never came up. Re-running the deployment re-PUTs the hub, which sometimes clears it — but if it fails a second time the hub is stuck and must be recreated:

```bash
az network vhub delete -g $RG -n erfo-hub-wus2 --yes
```

Then redeploy. Deletion is safe while `routingState` is `None`, because no gateway, connection or route table exists on it yet. It takes roughly 10–20 minutes. Delete any hub gateway or connection first if one did manage to attach.

If the *same* region fails three times in a row, stop retrying — it is a regional capacity problem, not a template problem. Move the hub to another region by editing the `key` and `region` fields of that hub entry in `main.bicepparam`. The circuit does **not** move with it (see the next section).

---

### ExpressRoute Gateway fails with `OperationFailureErrors`

```
OperationFailureErrors: The operation failed due to following errors:
  '["...'One or more operations failed'."]'
```

This error carries no usable detail. Work through it in this order:

1. **Confirm the hub is healthy.** The gateway create serializes behind hub router
   provisioning, so a half-provisioned hub surfaces as an opaque gateway failure.

   ```bash
   az network express-route gateway show -g $RG -n erfo-hub-wus2-ergw -o json
   az network vhub show -g $RG -n erfo-hub-wus2 \
     --query "{state:provisioningState,routing:routingState}" -o json
   ```

   Prefer `gateway show` over `gateway list` — `list` has been observed rendering
   blank rows for `provisioningState`.

2. **Delete the failed gateway and redeploy.** A re-PUT over a `Failed` gateway
   usually fails again; a clean create sometimes succeeds.

   ```bash
   az network express-route gateway delete -g $RG -n erfo-hub-wus2-ergw
   ```

3. **Try a direct CLI create** to rule the template out entirely:

   ```bash
   az network express-route gateway create -g $RG -n erfo-hub-wus2-ergw \
     --virtual-hub erfo-hub-wus2 --min-val 1 --max-val 2
   ```

4. **Check quota** — though in practice this is rarely the cause, because
   ExpressRoute Gateways do not appear in `az network list-usages` at all:

   ```bash
   az network list-usages -l westus2 -o table
   ```

If steps 2 and 3 both fail against a hub that reports `provisioningState=Succeeded`
and `routingState=Provisioned`, the region cannot currently place the gateway.
Relocate the hub. **If a second region fails identically, the problem is
subscription-wide** — open an Azure support case rather than relocating again.

> This lab originally ran its first hub in Central US, then North Central US, before
> settling on West US 2 for exactly this reason.

---

### Moving a hub to a different region

Hubs are relocatable; **circuits are not**. An ExpressRoute circuit cannot change
region, and re-creating one issues a new service key that the provider would have
to re-provision from scratch.

This is fine, because a circuit's `location` is ARM placement metadata only. A
**Standard**-SKU circuit can attach to any Virtual WAN hub in the same
geopolitical region. That is why `erfo-er-chicago` still lives in
`northcentralus` while the hub it feeds runs in `westus2` — the Chicago
ExpressRoute edge fronts the West US 2 hub without issue.

So when relocating a hub, change **only** the hub's `key` and `region` in
`main.bicepparam` and leave `circuitLocation` alone:

```bicep
key: 'wus2'
region: 'westus2'
circuit: {
  name: 'chicago'
  peeringLocation: 'Chicago'
  circuitLocation: 'northcentralus'  // unchanged — circuits cannot move
  ...
}
```

Then redeploy with `-SkipCircuits` (see below) and delete the old region's
leftovers: VM, disk, NIC, public IP, spoke VNet, NSG, gateway, and finally the hub.

---

### Circuit fails with `ConflictError: The specified bgp peering is in use`

```
ConflictError: The specified bgp peering is in use.
  .../expressRouteCircuits/erfo-er-dallas
```

This is a **re-PUT conflict, not configuration drift** — the live circuit can match
`main.bicepparam` exactly and still hit it.

The cause: `expressroute-circuit.bicep` declares the circuit without a `peerings`
array. On a redeploy ARM re-PUTs that body and tries to reconcile the existing
`AzurePrivatePeering` child away. The provider refuses because the peering is bound
to a live provider link, the circuit flips to `Failed`, **and the peering is
destroyed as collateral.**

**Remedy — never re-PUT a provisioned circuit.** Redeploy with circuit management
disabled:

```bash
./scripts/deploy.sh -g $RG --skip-provider-wait --skip-circuits
```

```powershell
.\scripts\deploy.ps1 -ResourceGroup $RG -Location centralus `
  -AdminPassword $pw -SkipProviderWait -SkipCircuits
```

This sets `manageCircuits=false`, so `main.bicep` skips the circuit module and reads
the circuits through `er-circuit-info.bicep` (an `existing` reference) instead.
Peerings, gateways and connections are **not** gated by the flag, so they are still
created and updated normally — a redeploy can add a missing peering or connection
without ever touching the circuit itself.

**Recovering a circuit already stuck in `Failed`:** a bare update re-reconciles it,
but only while it has no live peering. Clear the peering first if one survived.

```bash
az network express-route update -g $RG -n erfo-er-dallas
az network express-route show -g $RG -n erfo-er-dallas \
  --query "{prov:provisioningState,spps:serviceProviderProvisioningState}" -o json
```

Once it reports `Succeeded`, redeploy with `--skip-circuits` to recreate the peering.

---

## Connectivity

### The VM has no route to on-premises

Check the spoke's connection to the hub:

```bash
az network vhub connection list --vhub-name erfo-hub-scus -g $RG -o table
```

Then the effective routes on the VM's NIC:

```bash
az network nic show-effective-route-table \
  -g $RG -n nic-erfo-vm-scus -o table
```

If on-prem prefixes are missing, the ExpressRoute connection has not propagated to the hub's default route table. Confirm it exists and is associated:

```bash
az network express-route gateway connection show \
  --gateway-name erfo-hub-scus-ergw -g $RG -n erfo-erconn-dallas -o json
```

### A circuit's BGP session is `Idle` or `Active`

Check the neighbour state at the circuit — this is the first thing to run
whenever on-prem prefixes are missing or a hub is using the "wrong" path:

```bash
az network express-route list-route-tables-summary -g $RG \
  -n erfo-er-dallas --peering-name AzurePrivatePeering --path primary -o table
```

`statePfxRcd` is either a **prefix count** (session established) or a BGP state
name. Only a number means healthy:

| `statePfxRcd` | Meaning |
| --- | --- |
| `5`, `7`, … | Established — that many prefixes received |
| `Idle` | Session down; the far side is not responding or is administratively shut |
| `Active` | Azure is trying to open the session and getting no answer |
| `Connect` | TCP is up, BGP OPEN not yet exchanged |

Observed in this lab: `169.254.172.17 65001 Idle` on **both** paths of
`erfo-er-dallas`, with `10.0.0.0/8` absent from its learned routes and
`erfo-hub-scus` falling back to `Remote Hub` for the on-prem prefixes. The cause
turned out to be mundane — the **private peering had been administratively
disabled**. Re-enabling it restored the session and the local path within a
couple of minutes. Check the obvious first:

```bash
az network express-route peering list -g $RG --circuit-name erfo-er-dallas -o table
```

Rule out layer 2 next — check ARP on the same path:

```bash
az network express-route list-arp-tables -g $RG \
  -n erfo-er-dallas --peering-name AzurePrivatePeering --path primary -o table
```

If the on-prem `.17` address resolves to a MAC, the VXC and VLAN are fine and
the fault is in BGP configuration on the provider router (wrong peer IP, wrong
ASN, missing/incorrect MD5, or the neighbour shut). In this lab the on-prem MAC
was `025a.011e.0923` — the *same* MCR interface that was serving Chicago
correctly — confirming layer 2 was never the problem.

If the peering exists and ARP resolves, the remaining fault is BGP policy on the
MCR. Nothing in this repo can fix that state: peering and BGP policy are owned
by the MCR by design (see `architecture.md`). Fix it in the Megaport portal,
then re-run the check until `statePfxRcd` is a number.

> **Discard failover results captured while a session is down.** A dead peering
> produces the same hub-level symptom (`Remote Hub` for on-prem prefixes) as a
> genuine failover — see the peering pre-check in `failover-tests.md` step 1.

> If `-o table` prints nothing for these commands, re-run with `-o json`. The
> CLI intermittently emits an empty table for the ExpressRoute `list-*-tables*`
> family.

### Hub-to-hub failover does not happen

The single most common cause is branch-to-branch being disabled.

```bash
az network vwan show -g $RG -n erfo-vwan \
  --query allowBranchToBranchTraffic -o tsv
```

Must be `true`. If it is `false`, the hubs never exchange each other's ExpressRoute routes and there is nothing to fail over to.

Second cause: route preference not actually applied.

```bash
for k in wus2 scus; do
  az network vhub show -g $RG -n erfo-hub-$k --query "{hub:name, pref:hubRoutingPreference}" -o tsv
done
```

Both must report `ASPath`.

### Failover works but takes minutes

This is control-plane failover. Convergence time is governed by BGP hold timers on your CE router and the ExpressRoute edge. Shorten the hold timer on your side if you need faster detection — Azure's ExpressRoute default is 180 s hold / 60 s keepalive, and most providers allow tuning.

Deleting the Azure-side connection (test Option B) converges faster than a real link failure because the withdrawal is immediate rather than timer-driven. Do not use that measurement as your SLA number.

### Asymmetric routing after failover

On-prem is likely still advertising the same prefixes over both circuits with equal AS path, so return traffic may pick the wrong circuit. Prepend your AS on the standby circuit so the preferred direction is unambiguous, mirroring what the hubs do.

---

## VM access

The test VMs have **no public IP**. The only interactive access path is Azure
Serial Console, which works over the Azure control plane and therefore keeps
working while you are deliberately breaking the ExpressRoute data path.

### Connecting

```bash
az extension add --name serial-console    # one time
az serial-console connect -g $RG -n erfo-vm-scus
```

Log in with `azureuser` and the `adminPassword` you deployed with. Press
`Ctrl+]` then `q` to quit, or `Ctrl+]` then `h` for the shortcut list.

### Serial Console does not connect

1. **Boot diagnostics must be on.** Serial Console reads the VM's serial port
   through boot diagnostics. The template sets managed boot diagnostics
   (`diagnosticsProfile.bootDiagnostics.enabled = true` with no `storageUri`),
   which needs no storage account and no shared-key access:

   ```bash
   az vm show -g $RG -n erfo-vm-scus --query diagnosticsProfile.bootDiagnostics -o json
   ```

   Re-enable it in place if it somehow got turned off:

   ```bash
   az vm boot-diagnostics enable -g $RG -n erfo-vm-scus
   ```

2. **Serial Console can be disabled subscription-wide.** Check and re-enable:

   ```bash
   az rest --method get \
     --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.SerialConsole/consoleServices/default?api-version=2018-05-01"
   ```

3. **You need the Virtual Machine Contributor role** (or higher) on the VM.
   Reader is not enough.

4. **Password authentication must be enabled in the guest.** Serial Console has
   no SSH key exchange. The template deliberately leaves
   `disablePasswordAuthentication: false`, so `adminPassword` works. If you add
   an SSH key, do not also harden `sshd`/PAM to key-only — you will lock
   yourself out of the console.

### Reaching the VMs over the network instead

SSH works from anywhere in private space — the other spoke, or on-premises
across either ExpressRoute circuit — because the NSG allows RFC1918 inbound at
priority 200:

```bash
ssh azureuser@10.20.0.4    # from the other spoke or from on-prem
```

If you want a browser-based shell as well, deploy Azure Bastion into a spoke.
Bastion requires an `AzureBastionSubnet` of at least `/26`, which does not fit
the default `/27` VM subnet — widen the spoke subnet plan first.

---

## Cleanup

```bash
./scripts/cleanup.sh -g rg-er-failover-lab
```

Delete the ExpressRoute circuits **before** the resource group if you want a clean provider-side teardown — otherwise the VXC may linger on the Megaport side and keep billing.

```bash
az network express-route delete -g $RG -n erfo-er-dallas
az network express-route delete -g $RG -n erfo-er-chicago
az group delete -n $RG --yes --no-wait
```
