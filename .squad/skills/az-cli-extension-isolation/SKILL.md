# az CLI Extension Isolation (WinError 5 Workaround)

## Problem
`$env:AZURE_EXTENSION_DIR` may point to a directory containing a corrupt or locked extension
(e.g., `application-insights` dist-info). The az CLI crashes **during command-table load**,
before any command dispatches. Result: all subsequent az calls in that shell session return
wrong/empty output, but `$LASTEXITCODE` is never set, so scripts appear to succeed.

## Pattern — Isolate to a clean empty extension dir

Apply in any PowerShell script that uses **only CORE az commands** (no extensions needed):

```powershell
# After login/RG pre-checks pass, before first az write command:
$script:OrigExtDir = $env:AZURE_EXTENSION_DIR
$CleanExtDir = Join-Path ([System.IO.Path]::GetTempPath()) "azext-clean-$PID"
New-Item -ItemType Directory -Force -Path $CleanExtDir | Out-Null
$env:AZURE_EXTENSION_DIR = $CleanExtDir
Log "  Using isolated az extension dir: $CleanExtDir"

try {
    # ... all az commands here ...
} finally {
    if ($null -ne $script:OrigExtDir) { $env:AZURE_EXTENSION_DIR = $script:OrigExtDir }
    else { Remove-Item Env:\AZURE_EXTENSION_DIR -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force -Path $CleanExtDir -ErrorAction SilentlyContinue
}
```

## Requirements
- PS 5.1 compatible (no ternary `??`).
- `$script:OrigExtDir` uses `script:` scope so it's accessible inside `finally`.
- `$CleanExtDir` defined before `try`, so always accessible in `finally`.
- Pre-checks that call `az account show` / `az group show` can run BEFORE the isolation block
  (they are read-only and low-risk). Only isolate before write commands.

## When NOT to apply
If the script itself installs or manages az extensions (`az extension add/remove`), skip this
pattern — the isolation would break those operations.

## Complementary fix — always verify az write results
```powershell
az some resource create ... --output none
if ($LASTEXITCODE -ne 0) { Write-Error "Create failed (exit $LASTEXITCODE)."; exit 1 }
$ResourceId = "$(az some resource show --query id -o tsv 2>$null)".Trim()
if ([string]::IsNullOrWhiteSpace($ResourceId)) {
    Write-Error "Could not resolve resource ID — possible extension-dir crash."; exit 1
}
```

## az Command-Existence Trap — verify subcommands before scripting

Not all logical subcommands exist. Example: **`az network watcher create` does NOT exist** —
the Network Watcher command group has no `create` subcommand. Using a non-existent subcommand
emits `'create' is misspelled or not recognized`, sets `$LASTEXITCODE` non-zero, but the az
process still exits normally so the next line (e.g., `Log "Created."`) still runs.

**Correct command to enable Network Watcher for a region:**
```powershell
az network watcher configure -g NetworkWatcherRG -l <region> --enabled true --output none
```
This is idempotent — safe to re-run on an already-enabled region. Always follow with a
`$LASTEXITCODE` check + re-query (`az network watcher show`) to verify provisioning.

General rule: before scripting any `az <group> <verb>`, run `az <group> --help` to confirm
the subcommand exists. Do not assume CRUD symmetry (create/show/delete) in all az CLI groups.

## Diagnosis
If you see: `PermissionError: [WinError 5] Access is denied: 'C:\...\azcliext\<ext>\<ext>-x.y.z.dist-info'`
→ remove the bad extension: `az extension remove -n <ext-name>` or delete the folder, then re-run.
