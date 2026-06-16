#Requires -Version 7.0
<#
.SYNOPSIS
  Interactive route-dump tool for the svh-dynamic-er-ri lab. Dumps routing
  information for the three core components of the lab:

    1. ExpressRoute circuits   — circuit summary + BGP route tables / ARP.
    2. Virtual Hubs            — Azure Firewall effective routes (the portal
                                 "Effective Routes / Azure Firewall" view) plus
                                 the current hub Route Preference.
    3. Virtual Machines        — NIC effective route table.

.DESCRIPTION
  Discovers the components in the given resource group, prompts you to pick a
  category and then which specific circuit / hub / VM to dump (or "all"), and
  prints the routes as readable tables.

  The Virtual Hub dump reproduces the Azure portal blade:
      <hub> | Effective Routes  ->  Resource type = "Azure Firewall"
  using:  az network vhub get-effective-routes --resource-type AzureFirewalls
  (note the plural "AzureFirewalls" — this is the value the portal sends; the
  singular "AzureFirewall" silently returns no routes). Columns match the portal:
      Prefix | Next Hop Type | Next Hop | Origin | AS path

  Read-only: this script never creates, changes or deletes any resource.

.PARAMETER ResourceGroup
  Azure resource group containing the lab. Required (prompted if omitted).

.PARAMETER Subscription
  Azure subscription ID or name. Sets az context when provided.

.PARAMETER Component
  Non-interactive category selector: er | vhub | vm | all. Default: prompted.
  Also honoured via env var LAB_DUMP_COMPONENT.

.PARAMETER Target
  Non-interactive resource selector: a specific resource name or "all".
  Default: all. Also honoured via env var LAB_DUMP_TARGET.

.PARAMETER Save
  Also write the raw JSON for every dump to .\route-dumps\ next to this script.

.PARAMETER NonInteractive
  Skip all prompts; use -Component / -Target (defaults: all / all).
  Also honoured via env var LAB_NON_INTERACTIVE=1.

.PARAMETER MaxAttempts
  How many times to query vHub firewall / VM NIC effective routes before giving
  up. These are async queries that can return an empty set or a transient error
  for a few minutes after a Hub Route Preference change (ExpressRoute <-> ASPath)
  while routes reprogram, so the dump retries until routes appear. Default: 4.

.PARAMETER RetryDelaySec
  Seconds to wait between effective-route retry attempts. Default: 20.

.EXAMPLE
  .\dump-routes.ps1 -ResourceGroup rg-svhdyn-4hub

.EXAMPLE
  .\dump-routes.ps1 -ResourceGroup rg-svhdyn-4hub -Component vhub -Target vwanlab-vhub2

.EXAMPLE
  .\dump-routes.ps1 -ResourceGroup rg-svhdyn-4hub -Component all -Target all -Save -NonInteractive
#>

param(
  [string]$ResourceGroup = "",
  [string]$Subscription  = "",
  [ValidateSet("", "er", "vhub", "vm", "all")]
  [string]$Component     = "",
  [string]$Target        = "",
  [switch]$Save,
  [switch]$NonInteractive,
  # Effective-route queries (vHub firewall / VM NIC) are async and can return an
  # empty set or a transient error for a few minutes right after a Hub Route
  # Preference change while routes reprogram. Retry up to this many times.
  [int]$MaxAttempts   = 4,
  [int]$RetryDelaySec = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Prerequisite check — verify required tooling is installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# ---------------------------------------------------------------------------
function Invoke-LabPrereqCheck {
    param([Parameter(Mandatory)][string[]]$Tools)

    $missing = foreach ($t in $Tools) {
        $present = if ($t -eq 'Az') {
            [bool](Get-Module -ListAvailable -Name Az.Accounts)
        } else {
            [bool](Get-Command $t -ErrorAction SilentlyContinue)
        }
        if (-not $present) { $t }
    }
    if (-not $missing) { return }

    Write-Host "[prereq] Missing required tool(s): $($missing -join ', ')" -ForegroundColor Yellow
    foreach ($t in $missing) {
        switch ($t) {
            'az'        { Write-Host '  - Azure CLI (az):    https://learn.microsoft.com/cli/azure/install-azure-cli' }
            'terraform' { Write-Host '  - Terraform:         https://developer.hashicorp.com/terraform/install' }
            'gcloud'    { Write-Host '  - Google Cloud SDK:  https://cloud.google.com/sdk/docs/install' }
            'jq'        { Write-Host '  - jq:                https://jqlang.github.io/jq/download/' }
            'Az'        { Write-Host '  - Az PowerShell:     Install-Module Az -Scope CurrentUser' }
            default     { Write-Host "  - ${t}: install via your OS package manager" }
        }
    }

    $interactive = $true
    if ($env:LAB_NON_INTERACTIVE -eq '1' -or -not [Environment]::UserInteractive) { $interactive = $false }
    if (-not $interactive) {
        Write-Host '[prereq] Non-interactive — install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }

    $ans = Read-Host '[prereq] Attempt to install the missing tool(s) now? [y/N]'
    if ($ans -notmatch '^[Yy]') {
        Write-Host '[prereq] Install the tool(s) above and re-run.' -ForegroundColor Red
        exit 1
    }

    foreach ($t in $missing) {
        Write-Host "[prereq] Installing '$t' ..."
        if ($t -eq 'Az') {
            try { Install-Module Az -Scope CurrentUser -Force -AllowClobber } catch { Write-Host $_ -ForegroundColor Red }
            continue
        }
        $wingetId = switch ($t) {
            'az'        { 'Microsoft.AzureCLI' }
            'terraform' { 'Hashicorp.Terraform' }
            'gcloud'    { 'Google.CloudSDK' }
            'jq'        { 'jqlang.jq' }
            default     { $null }
        }
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if ($wingetId) { winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements }
            else { winget install $t -e --accept-source-agreements --accept-package-agreements }
        } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
            choco install $t -y
        } else {
            Write-Host "[prereq] No winget/choco found — install '$t' manually (see link above)." -ForegroundColor Red
        }
    }

    $still = foreach ($t in $Tools) {
        $present = if ($t -eq 'Az') { [bool](Get-Module -ListAvailable -Name Az.Accounts) } else { [bool](Get-Command $t -ErrorAction SilentlyContinue) }
        if (-not $present) { $t }
    }
    if ($still) {
        Write-Host "[prereq] Still missing: $($still -join ', '). You may need to restart the shell after install, then re-run." -ForegroundColor Red
        exit 1
    }
}
Invoke-LabPrereqCheck -Tools @('az')

# Ensure az CLI extensions land in a stable directory (avoids OneDrive/spaces path issues).
if (-not $env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR = "C:\Temp\azcliext" }

# Merge env-var fallbacks.
$IsNonInteractive = $NonInteractive -or ($env:LAB_NON_INTERACTIVE -eq "1")
if (-not $Component -and $env:LAB_DUMP_COMPONENT) { $Component = $env:LAB_DUMP_COMPONENT }
if (-not $Target    -and $env:LAB_DUMP_TARGET)    { $Target    = $env:LAB_DUMP_TARGET }

# ---------- Helpers ----------------------------------------------------------

# Timestamp every progress line so stalls are obvious in terminal output.
function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

function ConvertFrom-JsonSafe([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq 'null') { return @() }
  try { $parsed = $raw | ConvertFrom-Json } catch { return @() }
  return @($parsed | Where-Object { $null -ne $_ })
}

# Extract the route array from a get-effective-routes / show-effective-route-table
# response. Both return an object shaped like { "value": [ ... ] }.
function Get-RouteValueArray($obj) {
  if ($obj -and @($obj).Count -gt 0 -and $obj[0].PSObject.Properties.Name -contains 'value') {
    return @($obj[0].value)
  }
  return @()
}

# Run an effective-routes az command (passed as a scriptblock that takes the
# stderr file path and returns the raw JSON string) and retry while the result
# is empty or the command errors. This rides out the async route-programming
# window that follows a Hub Route Preference change (ExpressRoute <-> ASPath),
# which is exactly when a single-shot query returns no routes. Returns a
# PSCustomObject with .Routes (array), .Raw (last raw json) and .Error (last
# stderr text, or $null on success).
function Invoke-EffectiveRoutes {
  param(
    [Parameter(Mandatory)][scriptblock]$AzCall,
    [string]$Label = "routes"
  )
  $routes  = @()
  $raw     = ""
  $lastErr = $null
  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $efErr = [System.IO.Path]::GetTempFileName()
    try {
      $raw = & $AzCall $efErr
    } catch {
      $raw = ""
      $lastErr = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $efErr) {
      $errTxt = (Get-Content -LiteralPath $efErr -Raw -ErrorAction SilentlyContinue)
      Remove-Item -LiteralPath $efErr -Force -ErrorAction SilentlyContinue
      if (-not [string]::IsNullOrWhiteSpace($errTxt)) { $lastErr = ($errTxt.Trim() -replace '\s+', ' ') }
    }
    $routes = @(Get-RouteValueArray (ConvertFrom-JsonSafe $raw))
    if ($routes.Count -gt 0) {
      return [PSCustomObject]@{ Routes = $routes; Raw = $raw; Error = $null; Attempts = $attempt }
    }
    if ($attempt -lt $MaxAttempts) {
      $why = if ($lastErr) { "error" } else { "empty result" }
      Write-Host ("  attempt {0}/{1}: {2} — {3} may still be reprogramming; retrying in {4}s..." `
                    -f $attempt, $MaxAttempts, $why, $Label, $RetryDelaySec) -ForegroundColor DarkGray
      if ($lastErr) { Write-Host ("    last error: {0}" -f $lastErr) -ForegroundColor DarkGray }
      Start-Sleep -Seconds $RetryDelaySec
    }
  }
  return [PSCustomObject]@{ Routes = @(); Raw = $raw; Error = $lastErr; Attempts = $MaxAttempts }
}

# Leaf (resource name) from an ARM resource id; pass-through for plain strings.
function Get-LeafName([string]$id) {
  if ([string]::IsNullOrWhiteSpace($id)) { return "-" }
  return ($id -split '/')[-1]
}

# Safe property read — returns $default when the property is absent (StrictMode-safe).
function Get-Prop($obj, [string]$name, $default = $null) {
  if ($null -eq $obj) { return $default }
  if ($obj.PSObject.Properties.Name -contains $name) {
    $v = $obj.$name
    if ($null -eq $v) { return $default }
    return $v
  }
  return $default
}

# Prompt the user to pick items from a named list. Returns the selected objects.
# Accepts: empty/"all"/"*" => all; comma/space separated indices (1-based) or names.
function Select-Items {
  param(
    [Parameter(Mandatory)][object[]]$Items,
    [Parameter(Mandatory)][string]$Label,
    [string]$Preselect = ""
  )
  $Items = @($Items)
  if ($Items.Count -eq 0) { return @() }

  $choice = $Preselect
  if (-not $choice -and -not $IsNonInteractive) {
    Write-Host ""
    Write-Host "  Available ${Label}:"
    for ($i = 0; $i -lt $Items.Count; $i++) {
      Write-Host ("    [{0}] {1}" -f ($i + 1), $Items[$i].name)
    }
    $choice = Read-Host "  Select $Label (number, comma-separated, name, or 'all')"
  }
  if (-not $choice -or $choice -match '^(all|\*)$') { return $Items }

  $selected = [System.Collections.Generic.List[object]]::new()
  foreach ($tok in ($choice -split '[,\s]+')) {
    $tok = $tok.Trim()
    if (-not $tok) { continue }
    if ($tok -match '^\d+$') {
      $idx = [int]$tok - 1
      if ($idx -ge 0 -and $idx -lt $Items.Count) { $selected.Add($Items[$idx]) }
    } else {
      $hit = $Items | Where-Object { $_.name -eq $tok }
      if ($hit) { foreach ($h in @($hit)) { $selected.Add($h) } }
    }
  }
  if ($selected.Count -eq 0) {
    Write-Host "  No matching $Label for '$choice'." -ForegroundColor Yellow
    return @()
  }
  return $selected.ToArray()
}

# Persist raw JSON for a dump when -Save is set.
$SaveDir = Join-Path $PSScriptRoot "route-dumps"
function Save-Raw([string]$kind, [string]$name, [string]$json) {
  if (-not $Save) { return }
  if (-not (Test-Path $SaveDir)) { New-Item -ItemType Directory -Path $SaveDir -Force | Out-Null }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $safe  = ($name -replace '[^A-Za-z0-9._-]', '_')
  $file  = Join-Path $SaveDir "$stamp-$kind-$safe.json"
  [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "  (saved raw JSON: $file)" -ForegroundColor DarkGray
}

# ---------- Banner -----------------------------------------------------------

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗"
Write-Host "║   svh-dynamic-er-ri — Route Dump (ER circuits / vHubs / VMs)          ║"
Write-Host "║   Read-only diagnostics — no resources are modified                   ║"
Write-Host "╚══════════════════════════════════════════════════════════════════════╝"
Write-Host ""

# ---------- Resource group / subscription -----------------------------------

if (-not $ResourceGroup) {
  if ($IsNonInteractive) { Write-Host "ResourceGroup is required." -ForegroundColor Red; exit 1 }
  $ResourceGroup = Read-Host "Enter resource group name"
}
if (-not $ResourceGroup) { Write-Host "ResourceGroup is required." -ForegroundColor Red; exit 1 }

if ($Subscription) {
  Log "Setting subscription: $Subscription"
  az account set --subscription $Subscription
}
# Pre-warm: consume any first-run az banner so it doesn't pollute captured output.
$null = az account show 2>&1

Log "Resource group : $ResourceGroup"

# ---------- Dump: ExpressRoute circuit --------------------------------------

function Dump-ExpressRoute {
  param([Parameter(Mandatory)][object]$Circuit)
  $cn = $Circuit.name
  Write-Host ""
  Write-Host "════════════════════════════════════════════════════════════════════"
  Write-Host "  ExpressRoute circuit: $cn"
  Write-Host "════════════════════════════════════════════════════════════════════"

  $sp = $Circuit.serviceProviderProperties
  $summary = [PSCustomObject][ordered]@{
    Name           = $cn
    SKU            = ("{0}/{1}" -f $Circuit.sku.tier, $Circuit.sku.family)
    Provider       = if ($sp) { $sp.serviceProviderName } else { "-" }
    PeeringLocation= if ($sp) { $sp.peeringLocation }     else { "-" }
    BandwidthMbps  = if ($sp) { $sp.bandwidthInMbps }     else { "-" }
    CircuitState   = $Circuit.circuitProvisioningState
    ProviderState  = $Circuit.serviceProviderProvisioningState
  }
  $summary | Format-List | Out-String -Width 512 | Write-Host
  Save-Raw "er-show" $cn ($Circuit | ConvertTo-Json -Depth 10)

  if ($Circuit.serviceProviderProvisioningState -ne "Provisioned") {
    Write-Host "  Circuit is not 'Provisioned' yet — BGP route tables are unavailable." -ForegroundColor Yellow
    return
  }

  $peering = "AzurePrivatePeering"
  foreach ($path in @("primary", "secondary")) {
    Write-Host "  --- Route table summary ($peering / $path) ---"
    try {
      $raw = az network express-route list-route-tables-summary -g $ResourceGroup -n $cn `
               --peering-name $peering --path $path -o json 2>$null
      $obj = ConvertFrom-JsonSafe $raw
      if ($obj -and @($obj).Count -gt 0 -and $obj[0].PSObject.Properties.Name -contains 'value') {
        @($obj[0].value) | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
      } elseif ($obj) {
        @($obj) | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
      } else {
        Write-Host "    (no summary returned)" -ForegroundColor DarkGray
      }
      Save-Raw "er-summary-$path" $cn $raw
    } catch {
      Write-Host "    (route table summary unavailable: $($_.Exception.Message))" -ForegroundColor DarkGray
    }

    Write-Host "  --- Route table ($peering / $path) ---"
    try {
      $raw = az network express-route list-route-tables -g $ResourceGroup -n $cn `
               --peering-name $peering --path $path -o json 2>$null
      $obj = ConvertFrom-JsonSafe $raw
      if ($obj -and @($obj).Count -gt 0 -and $obj[0].PSObject.Properties.Name -contains 'value') {
        @($obj[0].value) | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
      } elseif ($obj) {
        @($obj) | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
      } else {
        Write-Host "    (no routes returned)" -ForegroundColor DarkGray
      }
      Save-Raw "er-routetable-$path" $cn $raw
    } catch {
      Write-Host "    (route table unavailable: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
  }
}

# ---------- Dump: Virtual Hub (Azure Firewall effective routes) -------------

function Dump-VHub {
  param([Parameter(Mandatory)][object]$Hub)
  $hn = $Hub.name
  Write-Host ""
  Write-Host "════════════════════════════════════════════════════════════════════"
  Write-Host "  Virtual Hub: $hn"
  Write-Host "════════════════════════════════════════════════════════════════════"

  # Current hub routing preference (ExpressRoute / VpnGateway / ASPath).
  $pref = $null
  try { $pref = $Hub.hubRoutingPreference } catch { $pref = $null }
  if (-not $pref) {
    $rawHub = az network vhub show -g $ResourceGroup -n $hn -o json 2>$null
    $h2 = ConvertFrom-JsonSafe $rawHub
    if ($h2 -and @($h2).Count -gt 0) { $pref = $h2[0].hubRoutingPreference }
  }
  if (-not $pref) { $pref = "(unknown)" }
  Write-Host ("  Hub Route Preference : {0}" -f $pref)
  Write-Host ("  Address prefix       : {0}" -f $Hub.addressPrefix)
  Write-Host ""

  # Resolve the hub's Azure Firewall (naming: <hub>-azfw).
  $fwName = "$hn-azfw"
  $fwId = az network firewall show -g $ResourceGroup -n $fwName --query id -o tsv 2>$null
  if (-not $fwId) {
    # Fall back: find any firewall whose virtualHub points at this hub.
    $fwsRaw = az network firewall list -g $ResourceGroup -o json 2>$null
    $fws = ConvertFrom-JsonSafe $fwsRaw
    $match = $fws | Where-Object { $_.virtualHub -and $_.virtualHub.id -and ($_.virtualHub.id -split '/')[-1] -eq $hn }
    if ($match) { $fwId = @($match)[0].id; $fwName = @($match)[0].name }
  }
  if (-not $fwId) {
    Write-Host "  No Azure Firewall found for hub '$hn' — skipping firewall effective routes." -ForegroundColor Yellow
    return
  }

  Write-Host "  Effective Routes  ->  Resource type: Azure Firewall  ($fwName)"
  Log "Querying firewall effective routes (this can take ~30-60s; auto-retries while empty)..."

  # NOTE: the portal sends virtualWanResourceType="AzureFirewalls" (plural).
  # The singular form returns an empty set. get-effective-routes is an async
  # (long-running) operation; right after a Hub Route Preference change it can
  # return an empty set or a transient error while routes reprogram, so we retry.
  $res = Invoke-EffectiveRoutes -Label "firewall effective routes" -AzCall ({
           param($ef)
           az network vhub get-effective-routes -g $ResourceGroup --name $hn `
             --resource-type AzureFirewalls --resource-id $fwId -o json 2>$ef
         }).GetNewClosure()
  $routes = @($res.Routes)
  Save-Raw "vhub-fw-effective" $hn $res.Raw

  if ($routes.Count -eq 0) {
    Write-Host ("  (no effective routes returned after {0} attempt(s))" -f $MaxAttempts) -ForegroundColor Yellow
    if ($res.Error) { Write-Host ("  Last error: {0}" -f $res.Error) -ForegroundColor DarkGray }
    return
  }

  # Render the exact portal columns: Prefix | Next Hop Type | Next Hop | Origin | AS path
  $rows = foreach ($r in $routes) {
    $aps    = @(Get-Prop $r 'addressPrefixes')
    $prefix = if ($aps.Count -gt 0) { ($aps -join ", ") } else { "-" }
    $hops   = @(Get-Prop $r 'nextHops')
    $nh     = if ($hops.Count -gt 0 -and $hops[0]) { Get-LeafName $hops[0] } else { "-" }
    $asp    = Get-Prop $r 'asPath' "-"
    [PSCustomObject][ordered]@{
      "Prefix"        = $prefix
      "Next Hop Type" = (Get-Prop $r 'nextHopType' "-")
      "Next Hop"      = $nh
      "Origin"        = (Get-LeafName (Get-Prop $r 'routeOrigin'))
      "AS path"       = $asp
    }
  }
  $rows | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
  Write-Host ("  ({0} route(s))" -f $routes.Count)
}

# ---------- Dump: VM NIC effective route table ------------------------------

function Dump-VM {
  param([Parameter(Mandatory)][object]$Vm)
  $vn = $Vm.name
  Write-Host ""
  Write-Host "════════════════════════════════════════════════════════════════════"
  Write-Host "  Virtual Machine: $vn"
  Write-Host "════════════════════════════════════════════════════════════════════"

  # Power state — effective routes require the VM to be running.
  $power = az vm get-instance-view -g $ResourceGroup -n $vn `
             --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>$null
  Write-Host ("  Power state : {0}" -f ($(if ($power) { $power } else { "(unknown)" })))
  if ($power -and $power -ne "PowerState/running") {
    Write-Host "  VM is not running — effective routes are unavailable. Start the VM and retry." -ForegroundColor Yellow
    return
  }

  $nicId = az vm show -g $ResourceGroup -n $vn --query "networkProfile.networkInterfaces[0].id" -o tsv 2>$null
  if (-not $nicId) {
    Write-Host "  Could not resolve a NIC for VM '$vn'." -ForegroundColor Yellow
    return
  }

  Log "Querying NIC effective route table (this can take ~30-60s; auto-retries while empty)..."
  $res = Invoke-EffectiveRoutes -Label "NIC effective routes" -AzCall ({
           param($ef)
           az network nic show-effective-route-table --ids $nicId -o json 2>$ef
         }).GetNewClosure()
  $routes = @($res.Routes)
  Save-Raw "vm-effective" $vn $res.Raw

  if ($routes.Count -eq 0) {
    Write-Host ("  (no effective routes returned after {0} attempt(s))" -f $MaxAttempts) -ForegroundColor Yellow
    if ($res.Error) { Write-Host ("  Last error: {0}" -f $res.Error) -ForegroundColor DarkGray }
    return
  }

  $rows = foreach ($r in $routes) {
    $aps    = @(Get-Prop $r 'addressPrefix')
    $prefix = if ($aps.Count -gt 0) { ($aps -join ", ") } else { "-" }
    $nips   = @(Get-Prop $r 'nextHopIpAddress')
    $nhip   = if ($nips.Count -gt 0) { ($nips -join ", ") } else { "-" }
    [PSCustomObject][ordered]@{
      "Source"           = (Get-Prop $r 'source' "-")
      "State"            = (Get-Prop $r 'state' "-")
      "Address Prefix"   = $prefix
      "Next Hop Type"    = (Get-Prop $r 'nextHopType' "-")
      "Next Hop IP"      = $nhip
    }
  }
  $rows | Format-Table -AutoSize | Out-String -Width 512 | Write-Host
  Write-Host ("  ({0} route(s))" -f $routes.Count)
}

# ---------- Category selection ----------------------------------------------

if (-not $Component) {
  if ($IsNonInteractive) {
    $Component = "all"
  } else {
    Write-Host ""
    Write-Host "  What would you like to dump?"
    Write-Host "    [1] ExpressRoute circuit routes"
    Write-Host "    [2] Virtual Hub firewall effective routes (+ route preference)"
    Write-Host "    [3] VM effective routes (NIC)"
    Write-Host "    [4] All of the above"
    $sel = Read-Host "  Select [1-4]"
    switch ($sel) {
      "1" { $Component = "er" }
      "2" { $Component = "vhub" }
      "3" { $Component = "vm" }
      "4" { $Component = "all" }
      default { $Component = "all" }
    }
  }
}

$doER   = $Component -in @("er", "all")
$doHub  = $Component -in @("vhub", "all")
$doVM   = $Component -in @("vm", "all")

# ---------- ExpressRoute --------------------------------------------------

if ($doER) {
  Log "Discovering ExpressRoute circuits..."
  $circuits = @(ConvertFrom-JsonSafe (az network express-route list -g $ResourceGroup -o json 2>$null))
  if ($circuits.Count -eq 0) {
    Write-Host "  No ExpressRoute circuits found in '$ResourceGroup'." -ForegroundColor DarkGray
  } else {
    $pick = Select-Items -Items $circuits -Label "ExpressRoute circuit(s)" -Preselect ($(if ($Component -eq 'er') { $Target } else { "all" }))
    foreach ($c in $pick) { Dump-ExpressRoute -Circuit $c }
  }
}

# ---------- Virtual Hubs --------------------------------------------------

if ($doHub) {
  Log "Discovering Virtual Hubs..."
  $hubs = @(ConvertFrom-JsonSafe (az network vhub list -g $ResourceGroup -o json 2>$null))
  if ($hubs.Count -eq 0) {
    Write-Host "  No Virtual Hubs found in '$ResourceGroup'." -ForegroundColor DarkGray
  } else {
    $pick = Select-Items -Items $hubs -Label "Virtual Hub(s)" -Preselect ($(if ($Component -eq 'vhub') { $Target } else { "all" }))
    foreach ($h in $pick) { Dump-VHub -Hub $h }
  }
}

# ---------- VMs -----------------------------------------------------------

if ($doVM) {
  Log "Discovering Virtual Machines..."
  $vms = @(ConvertFrom-JsonSafe (az vm list -g $ResourceGroup -o json 2>$null))
  if ($vms.Count -eq 0) {
    Write-Host "  No Virtual Machines found in '$ResourceGroup'." -ForegroundColor DarkGray
  } else {
    $pick = Select-Items -Items $vms -Label "Virtual Machine(s)" -Preselect ($(if ($Component -eq 'vm') { $Target } else { "all" }))
    foreach ($v in $pick) { Dump-VM -Vm $v }
  }
}

Write-Host ""
Log "Done."
