# Amos — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-07-24 — nva-spoke-internet Bicep lab validation

**Scope:** Independent QA pass on Naomi's Bicep (bicep/) + Alex's scripts (scripts/) + Holden's README for the `nva-spoke-internet` lab scenario.

**Methodology:**
- `az bicep build --file main.bicep --stdout` — real compile, exit code checked
- `bash -n` via WSL on all 4 bash scripts — exit code + stderr checked
- Grep/view cross-checks for CIDRs, output names, CIDR references
- Read-only review of all Bicep modules, scripts, and cloud-init YAMLs

**Results (7 checks + cloud-init deep-dive):**

| Check | Result | Key Evidence |
|---|---|---|
| Compile (az bicep build) | PASS | Exit 0, 0 BCP diagnostics; bicep v0.42.1 (advisory to upgrade to v0.45.15) |
| Bash lint (bash -n) | PASS | All 4 scripts: exit 0, no error output |
| Contract cross-check | PASS + D1 | All 16 outputs in main.bicep/main.json; all get_output calls valid; no 10.200.0.0; ILB=10.0.0.68 consistent |
| Address plan audit | PASS | All CIDRs and ASNs match contract exactly |
| VM preflight review | PASS | pick_vm_sku + preflight_vm_capacity in Phase 3, Bicep in Phase 6; B-series fallback present |
| Routing sequencing | PASS | Phase 8 polls routingState; Phases 9-11 create connections post-Provisioned; Bicep has no connections |
| Boot diag / serial console | PASS | vm.bicep: `bootDiagnostics: { enabled: true }`, no storageUri; all VMs use vm.bicep |
| Cloud-init review | PASS | nva.yaml: ip_forward + MASQUERADE + SSH allowed; onprem-nva.yaml: strongSwan + FRR + ip_forward; workload.yaml: curl + ping |

**Defect found (LOW severity):**
- **D1 — dead variable `HUB_ID`** (`deploy.sh:155`): `HUB_ID="$(get_output hubId)"` is set but `DEFAULT_RT_ID` is constructed independently at line 169 via a separate `az account show` call. `HUB_ID` is never referenced anywhere downstream. Fix: `DEFAULT_RT_ID="${HUB_ID}/hubRouteTables/defaultRouteTable"` and remove the SUBSCRIPTION subshell — saves one API call and removes confusion.

**Notable observations (not defects):**
- `dmz.bicep:67`: `disableBgpRoutePropagation: false` on snet-nva UDR allows hub-propagated routes into NVA subnet, but the explicit `0/0 → Internet` UDR route correctly overrides any propagated 0/0. Setting `true` would be more defensive.
- `nvaNames` and `onpremVnetId` outputs exist per contract but are not consumed by deploy.sh (by design — available for post-deploy user inspection).
- ILB frontend IP is a hardcoded Bicep `var` (`10.0.0.68`), not read from ARM. This is correct since it's also statically assigned in ARM; the guard on deploy.sh:183 catches any drift.
- Floating IP (`enableFloatingIP: true`) on ILB HA-ports rule is required — preserves original destination IP through the NVA so iptables MASQUERADE works correctly.

**Test plan produced:** End-to-end test plan covering spoke internet egress, effective routes, HA failover, serial console, and on-prem BGP/IPsec reachability (see validation output and `amos-nva-spoke-internet-validation.md`).

**Key file paths:**
- `nva-spoke-internet/bicep/main.bicep` — 16 outputs (lines 144-194)
- `nva-spoke-internet/bicep/modules/vm.bicep` — boot diag (lines 112-115)
- `nva-spoke-internet/bicep/modules/internal-lb.bicep` — ILB frontend var (line 27), floating IP (line 77)
- `nva-spoke-internet/scripts/deploy.sh` — defect at line 155 (HUB_ID unused)
- `nva-spoke-internet/bicep/cloud-init/nva.yaml` — MASQUERADE + ip_forward + SSH INPUT rule
- `nva-spoke-internet/bicep/cloud-init/onprem-nva.yaml` — strongSwan + FRR + ip_forward
- `.squad/skills/vwan-nva-routing/SKILL.md` — updated with validation patterns



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

### 2026-07-27 — nva-spoke-internet-paloalto static review (UPDATED — full script audit)

**Scope:** Full technical-correctness review of the PA-based lab (`nva-spoke-internet-paloalto/`) including ALL scripts (deploy, validate, cleanup, enable-monitoring, bash+PowerShell parity).

**Methodology:**
- Read all Bicep modules (palo-alto.bicep, dmz.bicep, internal-lb.bicep, public-lb.bicep, main.bicep)
- Read bootstrap files (bootstrap.xml, init-cfg.txt)
- Read ALL scripts: deploy.sh, deploy.ps1, validate-flow.sh, validate-flow.ps1, cleanup.sh, cleanup.ps1, enable-monitoring.sh, enable-monitoring.ps1, functions.sh
- Grep scan for RG/HUB/NVA_NAMES defaults across all scripts
- Applied 6 trivial RG default fixes; `az bicep build` → exit 0 ✅
- `git status --porcelain nva-spoke-internet` → empty (original lab untouched) ✅

**Result:** PASS after 6 trivial RG default fixes applied in-place.

**NEW finding: Copy-paste script default mismatches (RG names)**

The canonical RG default from `deploy.sh:67` is `rg-nva-spoke-internet-pa`. Six scripts had wrong defaults that would break the copy-paste validate/cleanup/monitoring workflow:

| Script | Wrong Default | Risk |
|--------|--------------|------|
| validate-flow.sh, validate-flow.ps1 | `rg-nva-spoke-internet-paloalto` | Phase 1 pre-check fails silently |
| cleanup.sh, cleanup.ps1 | `rg-nva-spoke-internet` | **BLOCKING** — Linux lab RG, wrong resources targeted |
| enable-monitoring.sh, enable-monitoring.ps1 | `rg-nva-spoke-internet` | Monitoring setup targets wrong/absent RG |

All 6 fixed as trivial safe edits (single string literal). Bicep re-compiled clean.

**LESSON: Always grep for ALL script RG/HUB defaults — not just the primary deploy script.** Stale defaults from the source lab can survive copy-paste into a new lab's scripts without triggering a compile error. The cleanup.sh Linux-lab default is the most dangerous: it would silently target the wrong resource group on deletion. Always verify every script that takes `--rg`/`$Rg` against the deploy.sh canonical default.

**Correction: Prior C2 (NVA_NAMES) is already resolved.** The prior 2026-07-27 entry reported `NVA_NAMES="pa-nva-0 pa-nva-1"` as wrong, but the actual file at `validate-flow.sh:48` already has the correct value `pa-fw-0 pa-fw-1`. The caution was written against an intermediate draft. Both validate-flow.sh and validate-flow.ps1 have the correct NVA names in their defaults.

**Verdict written to:** `.squad/decisions/inbox/amos-pa-review.md`

---

## Team Update: 2026-07-24

**Lab Status:** nva-spoke-internet Bicep rebuild **COMPLETE & VALIDATED**

The team successfully rebuilt the nva-spoke-internet lab infrastructure as code. All agents contributed:
- naomi: 13 Bicep files
- alex: 6 deployment scripts
- holden: README + topology diagram
- amos: QA validation (8/8 PASS + 1 LOW defect fixed)

Lab is ready for end-to-end testing.

**2026-07-24 — DEPLOYMENT STATUS:** lab is LIVE in DMAUSER-FDPO (eastus2, B2s), 7/7 validation PASS — Alex
**2026-07-27:** PA lab (nva-spoke-internet-paloalto) passed review gate — Amos PASS verdict, live deploy ready (separate opt-in).
