# Amos — History

## Project Context
- **Project:** azure-virtualwan — Azure Virtual WAN lab scenarios and deployment scripts
- **Stack:** Azure CLI (.azcli), Bicep, ARM JSON, Bash/Shell
- **Domain:** Azure Networking (Virtual WAN, VPN, ExpressRoute, BGP, NVAs, Azure Firewall, Secured Virtual Hubs, Routing Intent)
- **User:** Daniel Mauser
- **Created:** 2026-05-04

## Learnings

### 2026-07-28 — [2g]/[2h] NW check messaging fix: SKIP tier + accurate error routing

[2g] NsgsNotAppliedOnNic → SKIP (N/A in NSG-less topology until 2026-07-28). [2h] NetworkWatcherVmExtensionNotInstalled → actionable WARN. Added `$script:Skip` counter; changed `2>$null` to `2>&1`; extracted real error text; added SKIP to summary line. PS5.1 parse validation → 0 errors. See history-archive.md for verbose details.

### 2026-07-28 — [2h] connectivity test: ErrorRecord filter + --only-show-errors fixes WARNING JSON pollution

Added `--only-show-errors` flag; separated stderr via `Where-Object { $_ -is [ErrorRecord] }` from stdout; guarded property access with `PSObject.Properties.Name` checks. Real extension errors still surface. PS5.1 parse validation → 0 errors. See history-archive.md.

### 2026-07-28 — vHub effective-routes routing trimmed to short-names

Display-only fix: `RouteOrigin` and `NextHops` now show last `/`-delimited segment (e.g. `conn-dmz`) instead of full resource IDs. Three cases safely handled: array, single string, empty/null. No logic or az call changes. See history-archive.md.

### 2026-07-28 — validate-flow.ps1 Phase 5 metrics output formatting (both labs)

Added `Show-Metric` helper to replace `-o table` wrapping. Renders: `latest <v> | min <v> | max <v> | avg <v> [<n> pts, HH:mm-HH:mm]`. Fallback to "(no data points)" for empty/null series. ASCII separators only (PS5.1 safe). PS5.1 parse validation → 0 errors. See history-archive.md.

### 2026-07-28 — validate-flow.ps1 virtual-wan extension isolation (both labs)

Added `$env:AZURE_EXTENSION_DIR` → `$env:TEMP\az-ext-vwan-lab` isolation + try/finally to prevent corrupt extension crashes. Idempotent `az extension show -n virtual-wan` → install only on first run. Cache is reusable (per-user, not per-PID). `finally` restores env on both PASS and FAIL. PS5.1 constraints respected. Parse validation → 0 errors. See history-archive.md.

### 2026-07-28 — [Cross-agent] Naomi completed Phase 4b NetworkWatcherAgentLinux install

[2h] was failing `NetworkWatcherVmExtensionNotInstalled` on vm-spoke1. Naomi added Phase 4b to enable-monitoring.ps1. Live verification: exit 0, both VMs Succeeded. Unblocked [2h] and enabled full connectivity suite. Coordinated commit b1230bd, PR #14, merged 67812ca.

### 2026-07-28 — validate-flow.ps1 friendly output refactor (nva-spoke-internet-paloalto)

Pattern: `az -o table` → `-o json` + `Format-Table -AutoSize` to prevent terminal wrapping. Added `Show-RouteTable` helper (four shapes: Hub/Conn/Nic/VHub). Object-based VNG check with string fallback. Colorization (Magenta/Green/Red/Yellow/Cyan). PS5.1 no ternary/null-conditional; all variables initialized. Parse validation → 0 errors. See history-archive.md.

### 2026-07-29 — [Cross-agent] Baseline NSG validation: 12 PASS / 0 FAIL / 2 WARN / 0 SKIP — GO via PR #15 (4a7b93d) — coordinated with Naomi deployment


