# Amos — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-06-15 — svh-dynamic-er-ri validation scripts

- **Dynamic hub discovery**: Always use `az network vhub list -g $rg --query "[].name" -o tsv | sort` instead of hard-coding hub names. Wrap in a shell array (`hubs=()`) or PowerShell array (`$hubs = @(...)`).
- **Naming contract**: `${labPrefix}-vhub${i}` → `${hub}-azfw`, `${hub}-fwpolicy`, `${hub}-ri`, `${hub}-ergw`. Validation scripts derive all resource names from the hub name; no separate index variable needed.
- **hubRoutingPreference**: The vhub.bicep hard-codes `ExpressRoute`. The validation script asserts the live ARM value equals `ExpressRoute` (not `ASPath` or `VpnGateway`).
- **Firewall policy RCG assertion (CORRECTED 2026-06-16)**: The CORRECT query is `ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]` (flattened). The old pattern `[0][0]` always returns null because `.rules[?...]` produces a nested array and chained `[0][0]` does not unwrap it correctly in az CLI JMESPath.
- **ER gateway optional per hub**: Some hubs may be deployed without an ER gateway (private-only or no circuit). Always guard with `|| true` (bash) / `-replace '\s',''` pattern (PS) and emit `[WARN]` rather than `[FAIL]` for absence.
- **Routing Intent mode detection**: Query `length(routingPolicies[?contains(destinations,'PrivateTraffic')])` and `length(routingPolicies[?contains(destinations,'Internet')])` separately; combine to label Private/Internet/Both.
- **Windows cp1252 safety**: Used ASCII `[PASS]`/`[FAIL]`/`[WARN]` markers throughout; avoided Unicode arrows/checkmarks in loop output to prevent encoding errors on Windows terminals.
- **PowerShell az wrapper**: Wrap `az` calls in a helper `Invoke-Az` function (redirects stderr to $null); postprocess output with `-replace '\s',''` to strip trailing newlines before string comparisons.
- **Deliverables**: `svh-dynamic-er-ri/scripts/validate.sh` and `svh-dynamic-er-ri/scripts/validate.ps1` (feature-equivalent, 15 sections, dynamic loops).

### 2026-06-16 — svh-dynamic-er-ri script hardening (4 bug classes fixed)

- **$Args reserved-variable bug (PowerShell)**: NEVER name a function parameter `$Args` in PowerShell. `$Args` is a PS automatic variable; in `pwsh -File` (nested) execution it silently drops and `az @Args` runs bare `az`, printing group-help into captured output (banner pollution). Always use a distinct name like `$AzArgs`.
- **az first-run banner pollution**: Always add a pre-warm block at the top of validate/deploy scripts — install/update extensions and run a cheap `az account show` before any query whose output is captured. This flushes the "Welcome to Azure CLI" one-time banner before it can contaminate `$(...)`/`$()` results.
- **Int32 overflow on az count queries (PowerShell)**: `[int]($str -replace '\D','0')` throws OverflowException when `$str` contains a long JSON blob (the regex strips all non-digits, leaving a >10-digit number). Fix: use `[int]::TryParse` with a 9-digit guard — encapsulate as a `To-Int` helper. Bash avoids this because `[[ $n -gt 0 ]]` and `${n:-0}` never cast strings directly.
- **vWAN SKU/tier property**: `az network vwan show --query sku` is ALWAYS empty. The az CLI surfaces ARM `properties.type` (which holds "Standard"/"Basic") as `typePropertiesType` to avoid colliding with the resource `type` field. Use `--query typePropertiesType`.
- **allow-all rule JMESPath flatten**: `ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]` returns null. The inner `[?...]` on a projected array produces a list-of-lists; `[0][0]` does not unwrap it. Correct form: `ruleCollections[?name=='allow-all-network'].rules[] | [?name=='allow-all'] | [0]` — flatten with `[]` first, then filter, then take first element.
- **Non-interactive guard for blocking prompts**: Any `Read-Host`/`read` prompt in deploy scripts must be wrapped in an `$IsNonInteractive` / `NON_INTERACTIVE=1` guard. In CI/automation contexts, print manual-step guidance and skip the block; never hang waiting for input that will never come.

## Session: svh-dynamic-er-ri Lab Delivery (2026-06-15)

### Lab Delivered
**svh-dynamic-er-ri** — Dynamic 1–4 secured vHub lab. Authored comprehensive validation suite covering hub states, ER circuits, gateways, connections, firewalls, RI modes, and VM connectivity. Registered `vWAN-dynamic-validate` skill.

### Work Completed
- Authored `validate.sh` and `validate.ps1` with 15 validation sections: hub existence/state/routing-pref/RI, ER circuits, gateways, connections, firewall health/policy/tier, VM SSH/KV secret fallback, effective routes
- Authored `.squad/skills/vwan-dynamic-validate/SKILL.md` skill registry
- Designed test matrix for single-hub, multi-hub, ER-presence/absence, VM capacity fallback scenarios
- Implemented dynamic hub discovery (parse hub list from `az network vhub list`), naming contract verification, rule extraction patterns

### Key Patterns Established
- **Dynamic hub discovery** via `az network vhub list -g $rg --query "[].name" -o tsv | sort`
- **ER gateway optional per hub** — guard with `|| true` (bash) / silent patterns (PS), emit `[WARN]` for absence
- **Routing Intent mode detection** — separate PrivateTraffic and Internet destination counts, combine to label Private/Internet/Both
- **Firewall rule extraction** — use `query "ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]"` for single rule object
- **hubRoutingPreference assertion** — vhub.bicep hard-codes `ExpressRoute`; validate.sh asserts live ARM value

### Integration Points
- Naomi: deploy.sh/ps1 invoke validate post-deployment (validation readiness check)
- Alex: RI mode detection validates mode set by CLI in deploy scripts
- Holden: docs/validation.md documents expected check outputs and manual procedures
