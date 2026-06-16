# Skill: vwan-dynamic-validate

## Purpose
Reusable patterns for writing dynamic validation scripts (Bash + PowerShell) for
Azure Virtual WAN labs that have 1..N secured vHubs with Azure Firewall + Routing Intent.

---

## Pattern 1 — Discover hubs dynamically

### Bash
```bash
hubs=()
while IFS= read -r h; do
    [[ -n "$h" ]] && hubs+=("$h")
done < <(az network vhub list -g "$rg" --query "[].name" -o tsv 2>/dev/null | sort)
```

### PowerShell
```powershell
$hubs = @((az network vhub list -g $rg --query '[].name' -o tsv 2>$null) |
           Where-Object { $_ -ne '' } | Sort-Object)
```

---

## Pattern 2 — Assert hubRoutingPreference

```bash
hrp=$(az network vhub show -g "$rg" -n "$hub" --query "hubRoutingPreference" -o tsv)
[[ "$hrp" == "ExpressRoute" ]] && echo "[PASS]" || echo "[FAIL] got $hrp"
```

---

## Pattern 3 — Assert firewall policy allow-all rule

```bash
rule_json=$(az network firewall policy rule-collection-group show \
    -g "$rg" --policy-name "$pol_name" -n "default-allow-all-rcg" \
    --query "ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]" \
    -o json)
# Then check ipProtocols[0]==Any, sourceAddresses[0]==*, destinationAddresses[0]==*, destinationPorts[0]==*
```

---

## Pattern 4 — Routing Intent mode detection

```bash
has_private=$(az network vhub routing-intent show -g "$rg" --vhub-name "$hub" -n "$hub-ri" \
    --query "length(routingPolicies[?contains(destinations,'PrivateTraffic')])" -o tsv)
has_internet=$(az network vhub routing-intent show -g "$rg" --vhub-name "$hub" -n "$hub-ri" \
    --query "length(routingPolicies[?contains(destinations,'Internet')])" -o tsv)
```

---

## Pattern 5 — Firewall effective routes per hub

```bash
for hub in "${hubs[@]}"; do
    fw_id=$(az network firewall show -g "$rg" -n "${hub}-azfw" --query "id" -o tsv)
    az network vhub get-effective-routes -g "$rg" -n "$hub" \
        --resource-type AzureFirewalls \
        --resource-id "$fw_id" \
        --query "value[].{addressPrefixes:addressPrefixes[0], asPath:asPath, nextHopType:nextHopType}" \
        --output table
done
```

---

## Pattern 6 — Optional ER gateway (skip if not deployed)

```bash
ergw_state=$(az network express-route gateway show -g "$rg" -n "${hub}-ergw" \
    --query "provisioningState" -o tsv 2>/dev/null || true)
if [[ -z "$ergw_state" ]]; then
    echo "[WARN] No ER gateway for $hub — skipping"
fi
```

---

## Windows / cp1252 safety rule
- Use `[PASS]` / `[FAIL]` / `[WARN]` ASCII markers in all output — avoids Windows cp1252 encoding
  errors when Unicode checkmarks (✔/✗) are used in pipe-to-file scenarios.
- In PowerShell, redirect `az` stderr: `az ... 2>$null`; strip trailing whitespace with `-replace '\s',''`.

---

## Naming contract (svh-dynamic-er-ri)
| Resource         | Name pattern           |
|------------------|------------------------|
| vWAN             | `${labPrefix}-vwan`    |
| vHub i           | `${labPrefix}-vhub${i}`|
| Azure Firewall   | `${hub}-azfw`          |
| Firewall policy  | `${hub}-fwpolicy`      |
| Routing Intent   | `${hub}-ri`            |
| ER Gateway       | `${hub}-ergw`          |
| Spoke VNet       | `${labPrefix}-spoke${i}`|
| VM               | `${labPrefix}-vm${i}`  |
