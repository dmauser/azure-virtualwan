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

# ---------------------------------------------------------------------------
# Prerequisite check — verify required tooling is installed; offer to install
# any that are missing, otherwise print install guidance and exit.
# Lab helper: safe to keep in any runner script.
# Use 'Az' (PowerShell module) for scripts that use Connect-AzAccount/Az cmdlets,
# 'az' for Azure CLI, plus 'terraform' / 'gcloud' / 'jq' as needed.
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
  $parsed = $raw | ConvertFrom-Json
  return @($parsed | Where-Object { $null -ne $_ })
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
    $_ -and $_.PSObject.Properties['name'] -and $_.name -eq $connName
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

  # ----- Detect Routing Intent on the hub -----
  # When a hub has Routing Intent configured, the ER connection MUST be created
  # WITHOUT associated/propagated route-table or labels — Routing Intent
  # auto-populates the routing configuration. Passing them triggers
  # ConnectionRoutingConfigConflictsWithRoutingIntent. Every hub in this lab uses
  # Routing Intent, so we branch on its presence to stay correct either way.
  $riName  = "${targetHub}-ri"
  $riState = (az network vhub routing-intent show `
    -g $ResourceGroup --vhub $targetHub -n $riName `
    --query provisioningState -o tsv 2>$null)
  $hasRoutingIntent = -not [string]::IsNullOrWhiteSpace($riState)

  # ----- Create the ER gateway connection -----
  Log "  Creating connection: $connName..."
  if ($hasRoutingIntent) {
    Write-Host "  Routing Intent detected on $targetHub — leaving route config empty (auto-populated)."
    az network express-route gateway connection create `
      --name $connName `
      -g $ResourceGroup `
      --gateway-name $ergwName `
      --peering $peering `
      -o none
  } else {
    # No Routing Intent — explicitly associate/propagate the default route table.
    $rtid = (az network vhub route-table show `
      --name defaultRouteTable `
      --vhub-name $targetHub `
      -g $ResourceGroup `
      --query id -o tsv 2>$null)
    az network express-route gateway connection create `
      --name $connName `
      -g $ResourceGroup `
      --gateway-name $ergwName `
      --peering $peering `
      --associated-route-table $rtid `
      --propagated-route-tables $rtid `
      --labels default `
      -o none
  }
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
