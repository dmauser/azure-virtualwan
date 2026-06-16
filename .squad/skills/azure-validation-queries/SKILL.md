# SKILL: azure-validation-queries

**Owner:** Amos (Tester)  
**Created:** 2026-06-16  
**Applies to:** All Azure Virtual WAN lab validate/deploy scripts  

---

## Purpose

Correct `az` CLI JMESPath patterns and property names for Azure Virtual WAN validation scripts. These were validated live against `rg-svhdyn-4hub` (svh-dynamic-er-ri lab, 2026-06-16). Use these patterns — do not improvise — to avoid the bugs documented below.

---

## Correct Query Patterns

### vWAN Tier / SKU

```bash
# WRONG — always returns empty string
az network vwan show -g $rg -n $vwan --query "sku" -o tsv

# CORRECT — returns "Standard" or "Basic"
az network vwan show -g $rg -n $vwan --query "typePropertiesType" -o tsv
```

**Why**: The az CLI remaps ARM `properties.type` to `typePropertiesType` to avoid colliding with the resource's top-level `type` field. The `sku` property does not exist on vWAN resources.

---

### Firewall Policy allow-all Rule Extraction

```bash
# WRONG — returns null (list-of-lists; [0][0] does not unwrap)
az network firewall policy rule-collection-group show \
  -g $rg --policy-name $policy -n DefaultNetworkRuleCollectionGroup \
  --query "ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]"

# CORRECT — flatten with [] first, then filter, then take first element
az network firewall policy rule-collection-group show \
  -g $rg --policy-name $policy -n DefaultNetworkRuleCollectionGroup \
  --query "ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]"
```

**Why**: A JMESPath projection (wildcard/filter) on a sub-array yields a list-of-lists. `| [0][0]` indexes the outer list (getting `[]`) then indexes that again — undefined/null. Flatten with `[]` before the filter to get a flat list, then `| [0]` extracts the object.

---

### Routing Intent Mode Detection

```bash
# Detect Private + Internet RI independently, then combine
private_count=$(az network vhub show -g $rg -n $hub \
  --query "length(routingPolicies[?contains(destinations,'PrivateTraffic')])" -o tsv)
internet_count=$(az network vhub show -g $rg -n $hub \
  --query "length(routingPolicies[?contains(destinations,'Internet')])" -o tsv)
```

---

### Hub Count Queries

```bash
# Bash — safe, no cast needed
conn_count=$(az network vhub connection list -g $rg --vhub-name $hub --query "length(@)" -o tsv 2>/dev/null || echo 0)
[[ "${conn_count:-0}" -gt 0 ]] && ...
```

```powershell
# PowerShell — use To-Int helper, NEVER cast directly
function To-Int {
    param([string]$s)
    $s = $s -replace '[^\d]',''
    if ([string]::IsNullOrEmpty($s) -or $s.Length -gt 9) { return 0 }
    $n = 0
    if ([int]::TryParse($s, [ref]$n)) { return $n }
    return 0
}
$connCount = To-Int (Invoke-Az network vhub connection list -g $rg --vhub-name $hub --query "length(@)" -o tsv)
```

**Why**: Naive `[int]($str -replace '\D','0')` throws `Int32 OverflowException` when `$str` contains a full JSON blob (regex removes all non-digits, leaving a >10-digit string).

---

## PowerShell az Wrapper — Parameter Naming

```powershell
# WRONG — $Args is a PS automatic variable; silently drops in pwsh -File execution
function Invoke-Az { param([string[]]$Args); az @Args 2>$null }

# CORRECT — use any non-reserved name
function Invoke-Az { param([string[]]$AzArgs); az @AzArgs 2>$null }
```

**Why**: In `pwsh -NonInteractive -File script.ps1`, `$Args` is pre-bound by the runtime to the script's own argument list (empty if none). The parameter declaration shadow is silently discarded, so `az @Args` runs bare `az` and prints CLI help into captured output.

**Reserved PS automatic variables to avoid as param names**: `$Args`, `$Input`, `$PSBoundParameters`, `$MyInvocation`, `$Error`, `$PSCmdlet`, `$PSScriptRoot`, `$PSCommandPath`, and all others in `about_Automatic_Variables`.

---

## Az Pre-Warm Block

Add this at the top of any script that captures `az` output into variables:

```powershell
# PowerShell — pre-warm az to flush one-time "Welcome" banner
Write-Host "[Pre-warm] Loading az extensions..."
az extension add --name azure-firewall --only-show-errors 2>$null
az extension add --name virtual-wan --only-show-errors 2>$null
az account show --query "id" -o tsv | Out-Null
```

```bash
# Bash — same purpose
echo "[Pre-warm] Loading az extensions..."
az extension add --name azure-firewall --only-show-errors 2>/dev/null || true
az extension add --name virtual-wan --only-show-errors 2>/dev/null || true
az account show --query "id" -o tsv > /dev/null
```

**Why**: The "Welcome to Azure CLI!" banner is printed exactly once on first-ever execution. Without pre-warm, it lands inside the first `$(az ...)` capture and corrupts the result.

---

## Non-Interactive Guard for Blocking Prompts

```powershell
# PowerShell
if (-not $IsNonInteractive) {
    Read-Host "Press Enter after ER provider provisioning completes..."
} else {
    Write-Host "[INFO] Non-interactive mode: skipping ER provisioning pause."
    Write-Host "       Manually verify circuits are in Provisioned state, then re-run."
}
```

```bash
# Bash
if [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
    read -rp "Press Enter after ER provider provisioning completes..."
else
    echo "[INFO] Non-interactive mode: skipping ER provisioning pause."
    echo "       Manually verify circuits are in Provisioned state, then re-run."
fi
```

---

## References

- Live validation: `svh-dynamic-er-ri/scripts/validate.ps1` and `validate.sh`, commit `1a74c44`
- Bug fix session: 2026-06-16, rg-svhdyn-4hub (sub 78216abe), 51/52 checks PASS
- Decisions: `.squad/decisions/inbox/amos-script-hardening.md`
