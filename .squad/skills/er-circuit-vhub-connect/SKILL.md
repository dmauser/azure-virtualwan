# SKILL: er-circuit-vhub-connect

**Owner:** Naomi (Infra Dev)
**Created:** 2026-06-16
**Applies to:** svh-dynamic-er-ri and any lab that connects ER circuits to Virtual WAN vHub ER gateways

---

## Purpose

Canonical az CLI pattern for connecting an already-provisioned ExpressRoute circuit to a
Virtual WAN vHub ExpressRoute gateway. Validated live against `rg-svhdyn-4hub` (2026-06-16).

---

## Prerequisites

- Circuit `serviceProviderProvisioningState` must be `"Provisioned"` (provider side complete).
- The target vHub must exist and be in `Succeeded` state.
- `az` extension `virtual-wan` must be installed.

---

## Full Connection Sequence

### 1. Check provider state

```bash
az network express-route show -g "$rg" -n "$circuit_name" \
  --query serviceProviderProvisioningState -o tsv
# Must return "Provisioned" before proceeding.
```

### 2. Ensure ER gateway exists on target hub

```bash
ergw_name="${hub_name}-ergw"

ergw_state=$(az network express-route gateway show -g "$rg" -n "$ergw_name" \
  --query provisioningState -o tsv 2>/dev/null || echo "NotFound")

if [[ "$ergw_state" != "Succeeded" ]]; then
  az network express-route gateway create \
    -g "$rg" -n "$ergw_name" \
    --location "$hub_location" \
    --min-val 1 \
    --virtual-hub "$hub_name" \
    -o none
  # Poll to Succeeded (40 × 15 s = 10 min max)
fi
```

> **Note:** `az network express-route gateway list -g <rg>` returns empty (az quirk).
> Always use `gateway show -n <name>` to check existence.

### 3. Idempotency check (before create)

```bash
conn_name="${hub_name}-conn-to-${circuit_name}"

existing=$(az network express-route gateway connection list \
  --gateway-name "$ergw_name" -g "$rg" \
  --query "[?name=='${conn_name}'] | [0].name" -o tsv 2>/dev/null || true)

[[ -n "$existing" ]] && echo "already connected — skip" && continue
```

### 4. Get AzurePrivatePeering id

```bash
peering=$(az network express-route show -g "$rg" -n "$circuit_name" \
  --query 'peerings[0].id' -o tsv)
```

### 5. Get hub default route table id

```bash
rtid=$(az network vhub route-table show \
  --name defaultRouteTable \
  --vhub-name "$hub_name" \
  -g "$rg" \
  --query id -o tsv)
```

### 6. Create the connection

```bash
az network express-route gateway connection create \
  --name "$conn_name" \
  -g "$rg" \
  --gateway-name "$ergw_name" \
  --peering "$peering" \
  --associated-route-table "$rtid" \
  --propagated-route-tables "$rtid" \
  --labels default \
  -o none
```

**Connection name convention:** `${hub_name}-conn-to-${circuit_name}`

**Route table flags:** both `--associated-route-table` and `--propagated-route-tables` must be
the `defaultRouteTable` id; `--labels default` is required.

### 7. Poll to Succeeded

```bash
er_conn_iter=0; er_conn_max=40   # 40 × 30 s = 20 min
while true; do
  er_conn_iter=$((er_conn_iter + 1))
  [[ $er_conn_iter -gt $er_conn_max ]] && echo "WARNING: poll timeout — continuing" && break
  conn_state=$(az network express-route gateway connection show \
    --name "$conn_name" -g "$rg" --gateway-name "$ergw_name" \
    --query provisioningState -o tsv 2>/dev/null || echo "Unknown")
  [[ "$conn_state" == "Succeeded" ]] && break
  [[ "$conn_state" == "Failed" ]]    && break
  sleep 30
done
```

---

## PowerShell Equivalent (key differences)

```powershell
# Step 4 — peering id
$peering = (az network express-route show -g $Rg -n $en --query 'peerings[0].id' -o tsv)

# Step 5 — route table id
$rtid = (az network vhub route-table show --name defaultRouteTable `
  --vhub-name $targetHub -g $Rg --query id -o tsv)

# Step 6 — create
az network express-route gateway connection create `
  --name $connName -g $Rg --gateway-name $ergwName `
  --peering $peering `
  --associated-route-table $rtid `
  --propagated-route-tables $rtid `
  --labels default -o none
```

---

## Common Pitfalls

| Pitfall | Fix |
|---------|-----|
| `az network express-route gateway list` returns empty | Use `gateway show -n <name>` instead |
| Creating connection before circuit is `Provisioned` | Check `serviceProviderProvisioningState` first |
| Missing `--labels default` | Required — omitting it causes route propagation issues |
| Using `--associated-route-table` without `--propagated-route-tables` | Both needed for full hub routing |
| Creating connection while gateway `provisioningState != Succeeded` | Poll gateway first |

---

## Standalone Script

`svh-dynamic-er-ri/scripts/connect-er.ps1` and `connect-er.sh` implement the full sequence
above with interactive hub selection, non-interactive map mode, idempotency, and summary table.
