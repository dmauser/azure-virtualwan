#Requires -Version 7.0
<#
.SYNOPSIS
  Standalone script to connect already-provisioned ExpressRoute circuits to vHub
  ER gateways — without re-running the full deploy.ps1.

.DESCRIPTION
  Discovers ER circuits and vHubs in the given resource group, then creates
  ExpressRoute gateway connections on the designated target hub(s). Safe to
  re-run: already-connected circuits are detected and skipped.

  Use this after the provider (e.g. Megaport) has provisioned the circuits and
  the serviceProviderProvisioningState shows "Provisioned".

.PARAMETER ResourceGroup
  Azure resource group containing the circuits and vHubs. Required.

.PARAMETER Subscription
  Azure subscription ID or name. Sets az context when provided.

.PARAMETER CircuitHubMap
  Comma-separated list of "circuit=hub" pairs for non-interactive operation.
  Example: "vwanlab-er1=vwanlab-vhub1,vwanlab-er2=vwanlab-vhub2"
  Also honoured via env var LAB_CIRCUIT_HUB_MAP.
  Providing this map implies -NonInteractive.

.PARAMETER NonInteractive
  Skip all prompts; use -CircuitHubMap (or $env:LAB_CIRCUIT_HUB_MAP) for mapping.
  Also honoured via env var LAB_NON_INTERACTIVE=1.

.PARAMETER MaxWaitMin
  Maximum minutes to wait for each connection to reach Succeeded. Default: 20.

.EXAMPLE
  .\connect-er.ps1 -ResourceGroup rg-svhdyn-4hub

.EXAMPLE
  .\connect-er.ps1 -ResourceGroup rg-svhdyn-4hub -Subscription 78216abe-xxxx `
    -NonInteractive -CircuitHubMap "vwanlab-er1=vwanlab-vhub1,vwanlab-er2=vwanlab-vhub2"
#>

param(
  [Parameter(Mandatory)]
  [string]$ResourceGroup,

  [string]$Subscription   = "",
  [string]$CircuitHubMap  = "",
  [switch]$NonInteractive,
  [int]   $MaxWaitMin     = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Ensure az CLI extensions land in a stable directory (avoids OneDrive/spaces path issues).
if (-not $env:AZURE_EXTENSION_DIR) { $env:AZURE_EXTENSION_DIR = "C:\Temp\azcliext" }

# Merge env-var fallbacks.
$IsNonInteractive = $NonInteractive -or ($env:LAB_NON_INTERACTIVE -eq "1")
if (-not $CircuitHubMap -and $env:LAB_CIRCUIT_HUB_MAP) { $CircuitHubMap = $env:LAB_CIRCUIT_HUB_MAP }
if ($CircuitHubMap) { $IsNonInteractive = $true }

# ---------- Helpers ----------------------------------------------------------

# Timestamp every progress line so stalls are obvious in terminal output.
function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Parse-CircuitHubMap([string]$mapStr) {
  $map = @{}
  foreach ($pair in ($mapStr -split ',')) {
    $pair = $pair.Trim()
    if ($pair -match '^([^=]+)=([^=]+)$') { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
  }
  return $map
}

function ConvertFrom-JsonSafe([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq 'null') { return @() }
  return ($raw | ConvertFrom-Json)
}

# ---------- Banner -----------------------------------------------------------

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗"
Write-Host "║   svh-dynamic-er-ri — Connect ER Circuits to vHub Gateways          ║"
Write-Host "║   Standalone post-provisioning script (idempotent)                  ║"
Write-Host "╚══════════════════════════════════════════════════════════════════════╝"
Write-Host ""

# ---------- Subscription context --------------------------------------------

if ($Subscription) {
  Log "Setting subscription: $Subscription"
  az account set --subscription $Subscription
}

# Pre-warm: consume any first-run az banner so it doesn't pollute captured output.
$null = az account show 2>&1

Log "Resource group : $ResourceGroup"
Write-Host ""

# ---------- Discover ER circuits --------------------------------------------

Log "Discovering ExpressRoute circuits in '$ResourceGroup'..."
$circuitsRaw = az network express-route list -g $ResourceGroup -o json 2>$null
$circuits    = ConvertFrom-JsonSafe $circuitsRaw

if (-not $circuits -or @($circuits).Count -eq 0) {
  Write-Host "  No ExpressRoute circuits found in '$ResourceGroup'. Nothing to do."
  exit 0
}
$circuits = @($circuits)
Write-Host "  Found $($circuits.Count) circuit(s): $(($circuits | Select-Object -ExpandProperty name) -join ', ')"
Write-Host ""

# ---------- Discover vHubs --------------------------------------------------

Log "Discovering vHubs in '$ResourceGroup'..."
$hubsRaw = az network vhub list -g $ResourceGroup -o json 2>$null
$hubs    = @(ConvertFrom-JsonSafe $hubsRaw)

if ($hubs.Count -eq 0) {
  Write-Host "  No vHubs found in '$ResourceGroup'. Cannot create connections."
  exit 1
}
Write-Host "  Found $($hubs.Count) hub(s): $(($hubs | Select-Object -ExpandProperty name) -join ', ')"
Write-Host ""

# ---------- Parse hub map ---------------------------------------------------

$hubMap = @{}
if ($CircuitHubMap) { $hubMap = Parse-CircuitHubMap $CircuitHubMap }

# ---------- Summary tracking ------------------------------------------------

$summary    = [System.Collections.Generic.List[PSCustomObject]]::new()
$hasFailure = $false

# ---------- Process each circuit --------------------------------------------

foreach ($circuit in $circuits) {
  $cn         = $circuit.name
  $provState  = $circuit.serviceProviderProvisioningState

  Write-Host "────────────────────────────────────────────────────────────────────"
  Log "Circuit: $cn  (serviceProviderProvisioningState = $provState)"

  if ($provState -ne "Provisioned") {
    Write-Host "  [WARN] Circuit $cn is '$provState' — provider side not complete yet, skipping."
    $summary.Add([PSCustomObject]@{
      Circuit = $cn; Hub = "-"; Gateway = "-"; Connection = "-"; Result = "Skipped ($provState)"
    })
    continue
  }

  # ----- Determine target hub -----
  $targetHub = $null
  if ($IsNonInteractive) {
    if ($hubMap.ContainsKey($cn)) {
      $targetHub = $hubMap[$cn]
      Write-Host "  Target hub (from map): $targetHub"
    } else {
      Write-Host "  [WARN] Circuit '$cn' not found in CircuitHubMap — skipping."
      $summary.Add([PSCustomObject]@{
        Circuit = $cn; Hub = "-"; Gateway = "-"; Connection = "-"
        Result  = "Skipped (no map entry)"
      })
      continue
    }
  } else {
    Write-Host ""
    Write-Host "  Available hubs:"
    for ($i = 0; $i -lt $hubs.Count; $i++) {
      Write-Host "    $($i+1)) $($hubs[$i].name) ($($hubs[$i].location))"
    }
    $hubChoice = Read-Host "  Connect $cn to which hub number? [1]"
    if ([string]::IsNullOrWhiteSpace($hubChoice)) { $hubChoice = "1" }
    $hi        = [int]$hubChoice - 1
    $targetHub = $hubs[$hi].name
    Write-Host "  Target hub: $targetHub"
  }

  $ergwName = "${targetHub}-ergw"
  $connName = "${targetHub}-conn-to-${cn}"

  # ----- Idempotency: check if connection already exists -----
  $existingRaw  = az network express-route gateway connection list `
    --gateway-name $ergwName -g $ResourceGroup -o json 2>$null
  $existingConns = @(ConvertFrom-JsonSafe $existingRaw)
  $alreadyExists = $existingConns | Where-Object {
    $_.name -eq $connName
  }
  if ($alreadyExists) {
    Write-Host "  Connection '$connName' already exists — skipping."
    $summary.Add([PSCustomObject]@{
      Circuit = $cn; Hub = $targetHub; Gateway = $ergwName
      Connection = $connName; Result = "AlreadyConnected"
    })
    continue
  }

  # ----- Ensure ER gateway exists -----
  $ergwState = (az network express-route gateway show -g $ResourceGroup -n $ergwName `
    --query provisioningState -o tsv 2>$null)
  if ($ergwState -ne "Succeeded") {
    $hubLocation = ($hubs | Where-Object { $_.name -eq $targetHub } | Select-Object -First 1).location
    Write-Host "  Creating ER gateway $ergwName in $targetHub ($hubLocation)..."
    az network express-route gateway create `
      -g $ResourceGroup -n $ergwName `
      --location $hubLocation `
      --min-val 1 `
      --virtual-hub $targetHub `
      -o none
    $ergwIter = 0; $ergwMax = 40   # 40 × 15 s = 10 min
    do {
      $ergwIter++
      if ($ergwIter -gt $ergwMax) {
        Log "  WARNING: ER-gateway poll timed out for $ergwName after $ergwMax iterations — continuing."
        break
      }
      $ergwState = (az network express-route gateway show -g $ResourceGroup -n $ergwName `
        --query provisioningState -o tsv 2>$null)
      Log "  $ergwName = $ergwState"
      if ($ergwState -ne "Succeeded") { Start-Sleep 15 }
    } while ($ergwState -ne "Succeeded")
  } else {
    Write-Host "  ER gateway $ergwName already Succeeded ✔"
  }

  # ----- Get peering id -----
  $peering = (az network express-route show -g $ResourceGroup -n $cn `
    --query 'peerings[0].id' -o tsv 2>$null)
  if ([string]::IsNullOrWhiteSpace($peering)) {
    Write-Host "  [WARN] No AzurePrivatePeering found on '$cn' — skipping."
    $summary.Add([PSCustomObject]@{
      Circuit = $cn; Hub = $targetHub; Gateway = $ergwName
      Connection = $connName; Result = "Failed (no peering)"
    })
    $hasFailure = $true
    continue
  }

  # ----- Get hub default route table id -----
  $rtid = (az network vhub route-table show `
    --name defaultRouteTable `
    --vhub-name $targetHub `
    -g $ResourceGroup `
    --query id -o tsv 2>$null)

  # ----- Create the ER gateway connection -----
  Log "  Creating connection: $connName..."
  az network express-route gateway connection create `
    --name $connName `
    -g $ResourceGroup `
    --gateway-name $ergwName `
    --peering $peering `
    --associated-route-table $rtid `
    --propagated-route-tables $rtid `
    --labels default `
    -o none
  $connCreateExit = $LASTEXITCODE

  if ($connCreateExit -ne 0) {
    Write-Host "  [ERROR] Connection create failed for '$connName' (exit $connCreateExit)."
    $summary.Add([PSCustomObject]@{
      Circuit = $cn; Hub = $targetHub; Gateway = $ergwName
      Connection = $connName; Result = "Failed (create error)"
    })
    $hasFailure = $true
    continue
  }

  # ----- Poll provisioningState to Succeeded -----
  $connPollMax = [Math]::Max(1, $MaxWaitMin * 2)   # iterations (30 s each)
  $erConnIter  = 0
  $connResult  = "Failed (timeout)"
  do {
    $erConnIter++
    if ($erConnIter -gt $connPollMax) {
      Log "  WARNING: ER-connection poll timed out for $connName after $connPollMax iterations — continuing."
      break
    }
    $connState = (az network express-route gateway connection show `
      --name $connName -g $ResourceGroup `
      --gateway-name $ergwName `
      --query provisioningState -o tsv 2>$null)
    Log "  $connName = $connState"
    if ($connState -eq "Succeeded") { $connResult = "Connected"; break }
    if ($connState -eq "Failed")    { $connResult = "Failed";    break }
    Start-Sleep 30
  } while ($true)

  Write-Host "  $connName → $connResult"
  if ($connResult -ne "Connected") { $hasFailure = $true }
  $summary.Add([PSCustomObject]@{
    Circuit = $cn; Hub = $targetHub; Gateway = $ergwName
    Connection = $connName; Result = $connResult
  })
}

# ---------- Summary table ---------------------------------------------------

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════════════"
Write-Host " Summary"
Write-Host "══════════════════════════════════════════════════════════════════════"
$summary | Format-Table -AutoSize
Write-Host ""

if ($hasFailure) {
  Log "Completed with one or more failures — check the rows marked 'Failed' above."
  exit 1
} else {
  Log "All circuits processed successfully."
  exit 0
}
