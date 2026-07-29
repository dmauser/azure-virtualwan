# Amos — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-07-28 — [2g]/[2h] NW check messaging fix: SKIP tier + accurate error routing

**Root cause 1 -- [2g] NsgsNotAppliedOnNic:**
`az network watcher test-ip-flow` requires an NSG to be attached to the NIC to evaluate flow. This lab uses NO NSGs -- traffic governance is via vHub routing + the Palo Alto firewall. The previous `2>$null` discarded the real Azure error `(NsgsNotAppliedOnNic) No NSG applied on nic nic-vm-spoke1`, so the check fell into the generic "Network Watcher may not be enabled" WARN even though NW (NetworkWatcher_westus3 = Succeeded) was perfectly healthy. IP flow verify is **not applicable** in NSG-less topologies; it only evaluates NSG rules.

**Root cause 2 -- [2h] NetworkWatcherVmExtensionNotInstalled:**
`az network watcher test-connectivity` requires the NetworkWatcherAgent VM extension to be installed on the source VM. The extension was absent from vm-spoke1, producing error `(NetworkWatcherVmExtensionNotInstalled)`. Again discarded by `2>$null`, so the check emitted the misleading NW-disabled WARN. This is a real, actionable gap (fixed by running enable-monitoring.ps1 after Naomi adds the agent install step).

**Fix pattern -- SKIP tier + stderr capture:**
- Added `$script:Skip = 0` counter and `function CheckSkip` (DarkGray, does NOT count as WARN or FAIL).
- Changed both `az` calls from `2>$null` to `2>&1` so stderr is captured into the output variable.
- In the failure path, `$rawErr = ($ifvJson | ForEach-Object { "$_" }) -join " "` extracts the real error text; `Log "       $rawErr"` prints it inline before the result tag.
- [2g]: `-match 'NsgsNotAppliedOnNic'` -> `CheckSkip` (N/A in this topology); else `CheckWarn` (generic, no longer blames NW).
- [2h]: `-match 'NetworkWatcherVmExtensionNotInstalled'` -> `CheckWarn` with actionable "run enable-monitoring.ps1" message; NW-disabled fallback; generic fallback.
- Summary line extended: `PASS: N  FAIL: N  WARN: N  SKIP: N` (SKIP in DarkGray).

**PS5.1 / BOM:** `[System.Management.Automation.PSParser]::Tokenize` -> 0 errors. BOM EF BB BF intact.

### 2026-07-28 — [2h] connectivity test: ErrorRecord filter + --only-show-errors fixes WARNING JSON pollution

`az network watcher test-connectivity` emits an az preview WARNING to stderr; prior `2>&1` folded it into `$ctJson` causing `ConvertFrom-Json: Invalid JSON primitive: WARNING`. Fix: added `--only-show-errors` to suppress preview notices; separated stderr via `Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }` into `$ctErr` and stdout into `$ctJson`; added `try/catch` around `ConvertFrom-Json`; added `PSObject.Properties.Name` guards on `connectionStatus`/`avgLatencyInMs`. Real extension errors (`NetworkWatcherVmExtensionNotInstalled`) still surface via `$ctErr`. BOM preserved (EF BB BF), PS5.1 ParseErrors: 0.

### 2026-07-28 — vHub effective-routes RouteOrigin trimmed to short-name (display-only)

`$origin` in `Show-RouteTable` `'VHub'` branch now uses `([string]$_.routeOrigin).TrimEnd('/').Split('/')[-1]` (with null-guard) — same pattern as NextHops fix — so `RouteOrigin` column shows connection short-name instead of full resource ID. BOM preserved (EF BB BF), PS5.1 ParseErrors: 0.

### 2026-07-28 — vHub effective-routes NextHops trimmed to connection short-name

**Scope:** Display-only fix in `nva-spoke-internet-paloalto/scripts/validate-flow.ps1`, `'VHub'` branch of `Show-RouteTable`, line 150. READ-ONLY script; no az write verbs touched.

**Change:** The `$nhs` assignment previously joined raw nextHops values verbatim, emitting full Azure resource IDs (e.g. `/subscriptions/.../virtualHubs/hub-nva-si/hubVirtualNetworkConnections/conn-dmz`). Now maps each element to its last `/`-delimited segment before joining — matching the existing line-116 pattern `($_.nextHop.TrimEnd('/') -split '/')[-1]`.

Three cases handled safely:
- Array of nextHops → `ForEach-Object { if ($_){ ... TrimEnd('/') -split '/')[-1] } }` then `-join ', '`
- Single string → `$_.nextHops.ToString().TrimEnd('/') -split '/')[-1]`
- Empty/null → `''` (no error)

Result: `[2e]` table displays `conn-dmz`, `conn-spoke1`, `conn-spoke2` instead of full IDs. **Display-only change** — no logic, no az calls affected.

### 2026-07-28 — [Cross-agent] Naomi completed Phase 4b NetworkWatcherAgentLinux install

Coordination: [2h] check was failing `(NetworkWatcherVmExtensionNotInstalled)` on vm-spoke1. Naomi added Phase 4b to enable-monitoring.ps1 to install the agent on both spoke VMs. Live verification: enable-monitoring.ps1 exit 0, both VMs report Succeeded. Unblocks [2h] check and enables full connectivity diagnostic suite. Coordinated commit b1230bd, PR #14, merged 67812ca.

**Parse validation:** `[System.Management.Automation.Language.Parser]::ParseFile(...)` → 0 errors.

### 2026-07-28 — validate-flow.ps1 Phase 5 metrics output formatting (both labs)

**Scope:** Phase 5 output formatting fix in both `nva-spoke-internet-paloalto/scripts/validate-flow.ps1` and `nva-spoke-internet/scripts/validate-flow.ps1`. READ-ONLY script; no az write verbs touched.

**Root cause of unreadable output:** Phase 5 called `az monitor metrics list -o table 2>&1` and passed the result to `Log`. `Log` prepends one timestamp and stringifies the array — collapsing the whole multi-line table into a single space-joined line that wraps horribly across the terminal (e.g. "Timestamp Name Average ---- 2026-07-28T19:26:00Z Used SNAT Ports 2.6 ...").

**Fix:** Added a `Show-Metric` helper function (inserted after `Show-RouteTable` in PA, after `Get-IPv4` in nva-spoke-internet) and rewrote the Public LB metric loop and ILB DipAvailability call in both files (Steps 2 & 3).

**Show-Metric contract:**
- Takes `-Json` (raw JSON string from `-o json 2>$null`) and `-Agg` (aggregation name, e.g. "Average").
- Navigates `value[0].timeseries[0].data[]` defensively (every nested property access guarded with `PSObject.Properties.Name -contains`).
- Collects non-null numeric datapoints; computes latest/min/max/avg with `[math]::Round($v,2)`.
- Renders one line: `       latest <v> | min <v> | max <v> | avg <v>   [<n> pts, HH:mm-HH:mm]`
- Falls back to `       (no data points - idle)` for empty/null series, failed JSON parse, or missing timeseries.
- All timestamps parsed as `[datetime]` and rendered `.ToString('HH:mm')`; raw string fallback on parse failure.
- ASCII separators only (`|`, `[]`) — no Unicode middots/arrows — safe with PS5.1 console encoding.

**WinError 5 guard:** The `[WinError 5] Access is denied` from corrupt application-insights ext is neutralized by the Phase 1 `$env:AZURE_EXTENSION_DIR` clean-dir isolation added in the previous session. The new metric calls use `-o json 2>$null` (not `2>&1`), and `$LASTEXITCODE` is checked; failures emit `CheckWarn` and continue — no silent swallowing.

**PS5.1 constraints:**
- No ternary/`??`/null-conditional. All if/else explicit.
- All variables initialized before first use (`$obj = $null`, `$valArr = $null`, `$tsArr = $null`, `$dataArr = $null`, `$v = $null`, `$ts = $null`, `$points = @()`).
- `$fStr`/`$lStr` always set via if/else (both branches assign the variable).

**Parse validation:** `[System.Management.Automation.Language.Parser]::ParseFile(...)` → 0 errors on both files.

### 2026-07-28 — validate-flow.ps1 virtual-wan extension isolation (both labs)

**Scope:** Added `$env:AZURE_EXTENSION_DIR` isolation + try/finally to both `nva-spoke-internet-paloalto/scripts/validate-flow.ps1` and `nva-spoke-internet/scripts/validate-flow.ps1`. READ-ONLY: only `az extension add` (local client op) was added; zero Azure resource writes.

**Root cause of false FAILs:** All `az network vhub ...` commands require the **virtual-wan** CLI extension. Two failure modes caused vhub queries to silently return empty strings:
1. The extension was not installed in the user's shell session.
2. A corrupt `application-insights` extension in `$env:AZURE_EXTENSION_DIR` (`C:\Temp\azcliext`) crashed az's command-table load with `[WinError 5] Access is denied` before any command dispatched. Since the script used `2>$null`, stderr was swallowed, `$LASTEXITCODE` was never set to non-zero, so scripts appeared to succeed but returned empty output → false-negative FAILs.

**Fix pattern (mirror of Naomi's SKILL.md, with one adaptation):**
- After RG pre-check passes (early exits can still happen before the block), point `$env:AZURE_EXTENSION_DIR` at a stable per-user cache dir (`$env:TEMP\az-ext-vwan-lab`) — not per-PID, so we skip reinstall on subsequent runs.
- Idempotent `az extension show -n virtual-wan` → install only on first run.
- If still missing after install, `CheckWarn` (never `exit`) — let the existing graceful "(no routes returned)" handling in `Show-RouteTable` continue.
- **Adaptation vs SKILL.md:** do NOT delete the clean dir in `finally` — it's a reusable cache. The SKILL.md pattern (per-PID empty dir) is for write-only isolation; here we need a persistent extension.
- Wrap remainder of script in `try { } finally { restore }`. PowerShell's `finally` runs even when `exit` is called from inside `try`, so the env var is always restored on both the PASS and FAIL exit paths.

**NW WARN messages are expected:** The two NW WARNs ("IP flow verify failed / connectivity test failed — Network Watcher may not be enabled") are legitimate until `enable-monitoring.ps1` has been run. They are NOT bugs in the validator. Polish: appended " — run enable-monitoring.ps1 to enable Network Watcher" to both WARN messages in both files.

**PS5.1 constraints:**
- `$script:OrigExtDir = $null` and `$CleanExtDir = ""` initialized at top of script body so `Set-StrictMode -Version Latest` is satisfied before `finally` reads them.
- No ternary/`??`/null-conditional used.

**Parse validation:** `[System.Management.Automation.Language.Parser]::ParseFile(...)` → 0 errors on both files. try=1/finally=1 (Linux), outer try/finally pair present at expected lines (PA).

### 2026-07-28 — validate-flow.ps1 friendly output refactor (nva-spoke-internet-paloalto)

**Scope:** Presentation-only refactor of the 5 route-dump sections in validate-flow.ps1 plus status colorization. READ-ONLY script; no az write verbs touched. **Cross-ref:** Naomi's `.squad/skills/az-cli-extension-isolation/SKILL.md` (if this script is ever modified to include write operations, apply the `$env:AZURE_EXTENSION_DIR` isolation + try/finally pattern to prevent WinError 5 crashes from corrupt extensions).

**Pattern: `az -o table` → `-o json` + `Format-Table -AutoSize`**
- Azure CLI `-o table` for vWAN route objects produces 5-7 wide columns that wrap in normal terminals (Source / State / AddressPrefix / NextHop / NextHopType columns exceed 120 chars easily).
- Replace with `-o json`, pipe the captured string to `ConvertFrom-Json`, project to a `[PSCustomObject]` with only the meaningful columns, then `Format-Table -AutoSize | Out-String | Write-Host`. This always fits the terminal because AutoSize calculates column widths from actual data.
- Join array-valued fields (`addressPrefix[]`, `destinations[]`, `nextHops[]`) with `', '` — single-line compact form.
- Truncate long resourceId next-hops to their final segment: `($_.nextHop.TrimEnd('/') -split '/')[-1]`.
- Surface the 0.0.0.0/0 row first (NIC shape): filter into `$def`/`$other` then concatenate.

**`Show-RouteTable` helper — four shapes:**
| Kind | az command | Key `.value` wrapper? | Columns rendered |
|------|------------|----------------------|-----------------|
| Hub  | `vhub route-table show --query 'routes[].{...}'` | No (direct array) | Destinations, NextHopType, NextHop (last segment) |
| Conn | `vhub connection show --query 'staticRoutes[].{...}'` | No (direct array) | Name, Prefix, NextHop |
| Nic  | `nic show-effective-route-table` | Yes (`{"value":[...]}`) | Source, State, AddressPrefix, NextHopType, NextHopIP |
| VHub | `vhub get-effective-routes` | Yes (`{"value":[...]}`) | AddressPrefixes, NextHopType, NextHops, RouteOrigin, AsPath |

**PS5.1 constraints respected:**
- No ternary `? :` operator (PS7+); used `if (...) { 'Red' } else { 'Green' }` assignment.
- No `ConvertFrom-Json -AsHashtable` (PS6+); used property access on PSCustomObjects.
- `Set-StrictMode -Version Latest` compatible: all variables initialized before use; PSObject.Properties.Name guard for optional fields; outer try/catch in `Show-RouteTable` catches any property-access edge cases.
- `@($collection)` wrapping to ensure Count is always safe.

**Object-based VNG check with string fallback (2c/2d):**
```powershell
$eff1HasVng = $false
try {
    $eff1Obj    = $eff1Raw | ConvertFrom-Json
    if ($null -ne $eff1Obj) {
        $eff1Routes = if ($eff1Obj.PSObject.Properties.Name -contains 'value') { @($eff1Obj.value) } else { @($eff1Obj) }
        $eff1Match  = @($eff1Routes | Where-Object { $_.nextHopType -eq 'VirtualNetworkGateway' } |
                       Where-Object { (@($_.addressPrefix) | Where-Object { $_ -eq '0.0.0.0/0' }).Count -gt 0 })
        $eff1HasVng = ($eff1Match.Count -gt 0)
    }
} catch { $eff1HasVng = $false }
if (-not $eff1HasVng) { $eff1HasVng = ($eff1Raw -match 'VirtualNetworkGateway') }  # string fallback
```
- Primary: parse JSON, look for `nextHopType -eq 'VirtualNetworkGateway'` AND `addressPrefix[] -contains '0.0.0.0/0'`.
- Fallback: if parse fails or returns unexpected shape, string-match the raw JSON for 'VirtualNetworkGateway'. Never regresses.

**Colorization — PS5.1 `Write-Host -ForegroundColor`:**
- `Banner` function: Magenta — phase headers (`=== Phase N: ... ===`) and SUMMARY borders.
- `CheckPass`: Green; `CheckFail`: Red; `CheckWarn`: Yellow.
- SUMMARY counts: PASS always green; FAIL red when >0 else green; WARN yellow.
- `Log` (cyan) kept for all normal informational lines.

**Parse validation:** `[System.Management.Automation.Language.Parser]::ParseFile(...)` → 0 errors.
