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
- **Firewall policy RCG assertion**: Use `az network firewall policy rule-collection-group show ... --query "ruleCollections[?name=='allow-all-network'].rules[?name=='allow-all'] | [0][0]"` to extract a single rule object; then check `ipProtocols[0]==Any`, `sourceAddresses[0]==*`, `destinationAddresses[0]==*`, `destinationPorts[0]==*`.
- **ER gateway optional per hub**: Some hubs may be deployed without an ER gateway (private-only or no circuit). Always guard with `|| true` (bash) / `-replace '\s',''` pattern (PS) and emit `[WARN]` rather than `[FAIL]` for absence.
- **Routing Intent mode detection**: Query `length(routingPolicies[?contains(destinations,'PrivateTraffic')])` and `length(routingPolicies[?contains(destinations,'Internet')])` separately; combine to label Private/Internet/Both.
- **Windows cp1252 safety**: Used ASCII `[PASS]`/`[FAIL]`/`[WARN]` markers throughout; avoided Unicode arrows/checkmarks in loop output to prevent encoding errors on Windows terminals.
- **PowerShell az wrapper**: Wrap `az` calls in a helper `Invoke-Az` function (redirects stderr to $null); postprocess output with `-replace '\s',''` to strip trailing newlines before string comparisons.
- **Deliverables**: `svh-dynamic-er-ri/scripts/validate.sh` and `svh-dynamic-er-ri/scripts/validate.ps1` (feature-equivalent, 15 sections, dynamic loops).

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
