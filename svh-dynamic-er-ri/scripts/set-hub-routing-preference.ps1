#Requires -Version 7.0
<#
.SYNOPSIS
  Dump and (optionally) change the Hub Routing Preference on every Virtual Hub
  in the svh-dynamic-er-ri lab.

.DESCRIPTION
  1. Discovers all Virtual Hubs in the resource group and prints each hub's
     current `hubRoutingPreference` (ExpressRoute / VpnGateway / ASPath).
  2. Offers to change ALL hubs to a target preference (default: ASPath).
  3. Applies the change with `az network vhub update --hub-routing-preference`.
  4. Re-reads every hub and confirms the change is effective, printing a
     before/after table.

  NOTE: This lab is designed around Route Preference = ExpressRoute (hard-coded
  in vhub.bicep and asserted by the validation scripts). Switching to ASPath is
  a deliberate, runtime-only override for testing BGP AS-path-based selection;
  it does not change the Bicep. Re-running deploy/validate will report/restore
  ExpressRoute. Use this only for connectivity experiments.

.PARAMETER ResourceGroup
  Azure resource group containing the lab. Required (prompted if omitted).

.PARAMETER Subscription
  Azure subscription ID or name. Sets az context when provided.

.PARAMETER Preference
  Target preference to switch the selected hubs to: ExpressRoute | VpnGateway | ASPath.
  Default: ASPath.

.PARAMETER Hubs
  Which hubs to change: "all" (default) or a comma/space-separated list of
  names or suffixes, e.g. "vhub1,vhub2,vhub4" (matches vwanlab-vhub1, etc.).
  The dump always lists every hub; only the selected hubs are changed.

.PARAMETER DumpOnly
  Only print the current preference for every hub; make no changes.

.PARAMETER Yes
  Skip the confirmation prompt and apply the change. Also honoured via
  env var LAB_NON_INTERACTIVE=1.

.EXAMPLE
  .\set-hub-routing-preference.ps1 -ResourceGroup rg-svhdyn-4hub

.EXAMPLE
  .\set-hub-routing-preference.ps1 -ResourceGroup rg-svhdyn-4hub -DumpOnly

.EXAMPLE
  .\set-hub-routing-preference.ps1 -ResourceGroup rg-svhdyn-4hub -Preference ASPath -Hubs "vhub1,vhub2,vhub4" -Yes
#>

param(
  [string]$ResourceGroup = "",
  [string]$Subscription  = "",
  [ValidateSet("ExpressRoute", "VpnGateway", "ASPath")]
  [string]$Preference    = "ASPath",
  [string]$Hubs          = "all",
  [switch]$DumpOnly,
  [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Prerequisite check — verify required tooling is installed.
# ---------------------------------------------------------------------------
function Invoke-LabPrereqCheck {
    param([Parameter(Mandatory)][string[]]$Tools)
    $missing = foreach ($t in $Tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $t }
    }
    if (-not $missing) { return }

    Write-Host "[prereq] Missing required tool(s): $($missing -join ', ')" -ForegroundColor Yellow
    foreach ($t in $missing) {
        switch ($t) {
            'az' { Write-Host '  - Azure CLI (az): https://learn.microsoft.com/cli/azure/install-azure-cli' }
            default { Write-Host "  - ${t}: install via your OS package manager" }
        }
    }
    if ($env:LAB_NON_INTERACTIVE -eq '1' -or -not [Environment]::UserInteractive) {
        Write-Host '[prereq] Non-interactive — install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }
    $ans = Read-Host '[prereq] Attempt to install the missing tool(s) now? [y/N]'
    if ($ans -notmatch '^[Yy]') {
        Write-Host '[prereq] Install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }
    foreach ($t in $missing) {
        $wingetId = if ($t -eq 'az') { 'Microsoft.AzureCLI' } else { $null }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if ($wingetId) { winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements }
            else { winget install $t -e --accept-source-agreements --accept-package-agreements }
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install $t -y
        } else {
            Write-Host "[prereq] No winget/choco found — install '$t' manually." -ForegroundColor Red
        }
    }
    $stillMissing = foreach ($t in $Tools) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $t }
    }
    if ($stillMissing) {
        Write-Host "[prereq] Still missing tools. Restart the shell after install, then re-run." -ForegroundColor Red
        exit 1
    }
}
Invoke-LabPrereqCheck -Tools @('az')

# Stable az extension dir (avoids OneDrive/spaces path issues).
if (-not $env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR = "C:\Temp\azcliext" }

$IsNonInteractive = $Yes -or ($env:LAB_NON_INTERACTIVE -eq "1")

function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    $ResourceGroup = Read-Host "Resource group containing the lab"
}
if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    Write-Host "[set-hub-routing-preference] No resource group provided. Exiting." -ForegroundColor Red
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
    Log "Setting subscription context: $Subscription"
    az account set --subscription $Subscription | Out-Null
}

# ---------------------------------------------------------------------------
# Discover hubs
# ---------------------------------------------------------------------------
Log "Discovering Virtual Hubs in resource group '$ResourceGroup'..."
$hubsRaw = az network vhub list -g $ResourceGroup --query "[].name" -o tsv 2>$null
$hubsList = [System.Collections.Generic.List[string]]::new()
foreach ($line in @($hubsRaw)) {
    $s = "$line".Trim()
    if ($s) { $hubsList.Add($s) }
}
if ($hubsList.Count -eq 0) {
    Write-Host "[set-hub-routing-preference] No Virtual Hubs found in '$ResourceGroup'." -ForegroundColor Red
    exit 1
}

function Get-HubPref([string]$hub) {
    $p = az network vhub show -g $ResourceGroup -n $hub --query hubRoutingPreference -o tsv 2>$null
    if ($null -eq $p) { return "(unknown)" }
    return ("$p" -replace '\s', '')
}

function Show-Table {
    param(
        [string]$Title,
        [System.Collections.Generic.List[string]]$HubList,
        [hashtable]$Map,
        [System.Collections.Generic.List[string]]$Targets
    )
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("  {0,-30} {1,-18} {2}" -f "Virtual Hub", "Route Preference", "Targeted")
    Write-Host ("  {0,-30} {1,-18} {2}" -f "-----------", "----------------", "--------")
    foreach ($h in $HubList) {
        $val = $Map[$h]
        $isTarget = $Targets.Contains($h)
        $color = if ($val -eq $Preference) { "Green" } else { "Gray" }
        Write-Host ("  {0,-30} {1,-18} {2}" -f $h, $val, $(if ($isTarget) { "yes" } else { "-" })) -ForegroundColor $color
    }
}

# ---------------------------------------------------------------------------
# Resolve which hubs to change. -Hubs accepts "all" (default) or a
# comma/space-separated list of names or suffixes (e.g. "vhub1,vhub2,vhub4"
# matches vwanlab-vhub1 / vwanlab-vhub2 / vwanlab-vhub4).
# ---------------------------------------------------------------------------
$targetList = [System.Collections.Generic.List[string]]::new()
if ([string]::IsNullOrWhiteSpace($Hubs) -or $Hubs -match '^(all|\*)$') {
    foreach ($h in $hubsList) { $targetList.Add($h) }
} else {
    foreach ($tok in ("$Hubs" -split '[,\s]+')) {
        $tok = $tok.Trim()
        if (-not $tok) { continue }
        $matched = $false
        foreach ($h in $hubsList) {
            if ($h -eq $tok -or $h -like "*$tok") {
                if (-not $targetList.Contains($h)) { $targetList.Add($h) }
                $matched = $true
            }
        }
        if (-not $matched) { Write-Host "[set-hub-routing-preference] No hub matches '$tok' — ignoring." -ForegroundColor Yellow }
    }
    if ($targetList.Count -eq 0) {
        Write-Host "[set-hub-routing-preference] No hubs matched -Hubs '$Hubs'. Exiting." -ForegroundColor Red
        exit 1
    }
}

$hubCount    = $hubsList.Count
$targetCount = $targetList.Count

# Current state
$before = @{}
foreach ($h in $hubsList) { $before[$h] = Get-HubPref $h }
Show-Table -Title "Current Hub Route Preference ($hubCount hub(s), $targetCount targeted):" -HubList $hubsList -Map $before -Targets $targetList

if ($DumpOnly) {
    Log "DumpOnly specified — no changes made."
    exit 0
}

# Already at target (among targeted hubs)?
$needChange = 0
foreach ($h in $targetList) { if ($before[$h] -ne $Preference) { $needChange++ } }
if ($needChange -eq 0) {
    Log "All targeted hub(s) are already set to '$Preference'. Nothing to change."
    exit 0
}

# Confirm
if (-not $IsNonInteractive) {
    Write-Host ""
    Write-Host ("About to change {0} targeted hub(s) [{1}] to Route Preference = {2}." -f $targetCount, ($targetList -join ", "), $Preference) -ForegroundColor Yellow
    $ans = Read-Host "Proceed? [y/N]"
    if ($ans -notmatch '^[Yy]') {
        Log "Cancelled by user. No changes made."
        exit 0
    }
}

# Apply
foreach ($h in $targetList) {
    if ($before[$h] -eq $Preference) {
        Log "$h already '$Preference' — skipping."
        continue
    }
    Log "Updating $h : $($before[$h]) -> $Preference ..."
    az network vhub update -g $ResourceGroup -n $h --hub-routing-preference $Preference --output none
}

# ---------------------------------------------------------------------------
# Re-check that the change is effective
# ---------------------------------------------------------------------------
Log "Re-checking hub Route Preference after update..."
$after = @{}
foreach ($h in $hubsList) { $after[$h] = Get-HubPref $h }
Show-Table -Title "Updated Hub Route Preference:" -HubList $hubsList -Map $after -Targets $targetList

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($h in $targetList) { if ($after[$h] -ne $Preference) { $failed.Add($h) } }
Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "All $targetCount targeted hub(s) now report Route Preference = $Preference." -ForegroundColor Green
    exit 0
} else {
    Write-Host "The following hub(s) did NOT apply '$Preference':" -ForegroundColor Red
    foreach ($h in $failed) { Write-Host ("    {0} = {1}" -f $h, $after[$h]) -ForegroundColor Red }
    exit 1
}
