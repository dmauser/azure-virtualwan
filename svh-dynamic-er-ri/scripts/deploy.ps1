#Requires -Version 7.0
<#
.SYNOPSIS
  Interactive deployment for svh-dynamic-er-ri (Secured Virtual WAN lab).

.DESCRIPTION
  Deploys 1-4 secured vHubs, optional ER circuits/gateways, Azure Firewall
  Basic, and Routing Intent via Bicep + Azure CLI.

  WARNING — LAB-ONLY: every firewall policy includes an allow-all rule.
  WARNING — All hubs use Route Preference = ExpressRoute.
  NEVER use this configuration in production.

.PARAMETER AnswersFile
  Path to a PowerShell script file that sets env variables (. dot-sourced).
  When provided, interactive prompts are skipped.

.PARAMETER NonInteractive
  Skip all prompts; rely on $env:LAB_* variables for all values.

.EXAMPLE
  .\deploy.ps1
  .\deploy.ps1 -AnswersFile .\answers.ps1
  $env:LAB_NON_INTERACTIVE = "1"; .\deploy.ps1
#>

param(
  [string]$AnswersFile   = "",
  [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir  = $PSScriptRoot
$BicepDir   = Join-Path $ScriptDir "..\infra\bicep"
$ParamsDir  = Join-Path $ScriptDir "..\infra\parameters"
$VmSkuCandidates = @("Standard_B2s", "Standard_B2ms", "Standard_D2s_v3", "Standard_D2as_v5", "Standard_D2s_v5")
[int]$MaxWaitMin = if ($env:MAX_WAIT_MIN) { [int]$env:MAX_WAIT_MIN } else { 180 }
$IsNonInteractive = $NonInteractive -or ($env:LAB_NON_INTERACTIVE -eq "1")

# Dot-source answers file if provided
if ($AnswersFile -ne "") {
  . $AnswersFile
  $IsNonInteractive = $true
}

# ---------- Helpers ---------------------------------------------------------

function Ask-Default {
  param([string]$EnvVar, [string]$Prompt, [string]$Default)
  $existing = [System.Environment]::GetEnvironmentVariable($EnvVar)
  if ($IsNonInteractive -and $existing) {
    Write-Host "  ${Prompt}: $existing (env)"
    return $existing
  }
  $val = Read-Host "  $Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($val)) { $val = $Default }
  return $val
}

function Pick-VmSku {
  param([string]$Region)
  foreach ($sku in $VmSkuCandidates) {
    $restrictions = az vm list-skus -l $Region --resource-type virtualMachines `
      --query "[?name=='$sku'].restrictions" -o tsv 2>$null
    if ([string]::IsNullOrEmpty($restrictions)) { return $sku }
  }
  throw "No candidate VM SKU available in region '$Region'. Tried: $($VmSkuCandidates -join ', ')"
}

function New-LabPassword {
  # Generates a 24-char password that satisfies Azure complexity rules.
  $bytes = [byte[]]::new(24)
  [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $base = [Convert]::ToBase64String($bytes) -replace '[^A-Za-z0-9]',''
  # Prefix/suffix guarantee upper, lower, digit, symbol presence.
  return "Lab" + $base.Substring(0, [Math]::Min(16, $base.Length)) + "Aa1!"
}

# Timestamp every progress line so stalls are obvious in terminal output.
function Log([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Build-RiPolicies {
  param([string]$FwId, [string]$Mode)
  switch ($Mode) {
    "privateOnly"  { return '[{"name":"PrivateTraffic","destinations":["PrivateTraffic"],"nextHop":"' + $FwId + '"}]' }
    "internetOnly" { return '[{"name":"InternetTraffic","destinations":["Internet"],"nextHop":"' + $FwId + '"}]' }
    "both"         { return '[{"name":"PrivateTraffic","destinations":["PrivateTraffic"],"nextHop":"' + $FwId + '"},{"name":"InternetTraffic","destinations":["Internet"],"nextHop":"' + $FwId + '"}]' }
  }
}

# ---------- Banner ----------------------------------------------------------
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════════╗"
Write-Host "║       svh-dynamic-er-ri — Secured Virtual WAN Lab Deployment        ║"
Write-Host "╠══════════════════════════════════════════════════════════════════════╣"
Write-Host "║  ⚠️  LAB-ONLY: every firewall policy includes an allow-all rule.     ║"
Write-Host "║  ⚠️  All hubs use Route Preference = ExpressRoute.                   ║"
Write-Host "║  ⚠️  NEVER use this configuration in production.                     ║"
Write-Host "╚══════════════════════════════════════════════════════════════════════╝"
Write-Host ""

# ---------- Phase 0: Pre-flight ---------------------------------------------
Log "### Phase 0: Pre-flight checks ###"
az extension add --name virtual-wan --upgrade -o none 2>$null
az extension add --name azure-firewall --upgrade -o none 2>$null
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { throw "ERROR: Not logged in. Run 'az login' first." }
Write-Host "  CLI extensions OK."

# ---------- Phase 1: Interactive configuration ------------------------------
Write-Host ""
Log "### Phase 1: Configuration ###"
if (-not $IsNonInteractive) { Write-Host "  (Set `$env:LAB_NON_INTERACTIVE=1 to skip prompts)" }
Write-Host ""

$currentSub   = (az account show --query id -o tsv 2>$null)
$Subscription = Ask-Default "LAB_SUBSCRIPTION" "Azure Subscription ID"               $currentSub
$Rg           = Ask-Default "LAB_RG"           "Resource group name"                 "lab-svh-dynamic-er-ri"
$DeployLoc    = Ask-Default "LAB_LOCATION"     "Deployment region (vWAN/KV/RG)"      "eastus"
$LabPrefix    = Ask-Default "LAB_PREFIX"       "Lab prefix"                          "vwanlab"
$NumHubsStr   = Ask-Default "LAB_NUM_HUBS"     "Number of vHubs (1-4)"               "1"
$RiMode       = Ask-Default "LAB_RI_MODE"      "Routing Intent mode (privateOnly/internetOnly/both)" "privateOnly"

[int]$NumHubs = [int]$NumHubsStr
if ($NumHubs -lt 1 -or $NumHubs -gt 4) { throw "num_hubs must be 1-4." }
if ($RiMode -notin @("privateOnly","internetOnly","both")) { throw "ri_mode must be privateOnly, internetOnly, or both." }

az account set --subscription $Subscription

# Per-hub regions
$DefaultRegions = @("eastus","westus","centralus","southcentralus")
$HubRegions     = @()
for ($i = 1; $i -le $NumHubs; $i++) {
  $def = if ($i -le $DefaultRegions.Count) { $DefaultRegions[$i-1] } else { "eastus" }
  $HubRegions += Ask-Default "LAB_HUB${i}_REGION" "Hub $i region" $def
}

# Per-hub ER gateway
$HubHasErg = @()
for ($i = 1; $i -le $NumHubs; $i++) {
  $raw = Ask-Default "LAB_HUB${i}_ERGW" "Deploy ER Gateway in hub ${i}? (true/false)" "false"
  $HubHasErg += ($raw -in @("true","1","yes"))
}

$DeployVmsRaw  = Ask-Default "LAB_DEPLOY_VMS"         "Deploy Ubuntu VMs in spokes? (true/false)" "true"
$AttachPipRaw  = Ask-Default "LAB_ATTACH_PUBLIC_IP"   "Attach public IP to VMs? (true/false)"     "false"
$EnableDiagRaw = Ask-Default "LAB_ENABLE_DIAGNOSTICS" "Enable Log Analytics diagnostics? (true/false)" "false"
$DeployVms  = $DeployVmsRaw  -in @("true","1","yes")
$AttachPip  = $AttachPipRaw  -in @("true","1","yes")
$EnableDiag = $EnableDiagRaw -in @("true","1","yes")

# No SSH key — VMs authenticate with username/password stored in Key Vault
$SshPubKey = ""

# Caller public IP for NSG rule
try { $MyPip = (Invoke-WebRequest "https://ifconfig.io" -UseBasicParsing -TimeoutSec 5).Content.Trim() }
catch { $MyPip = "" }

# ER circuits
$NumErStr = Ask-Default "LAB_NUM_ER_CIRCUITS" "Number of ER circuits to create (0 to skip)" "0"
[int]$NumErCircuits = [int]$NumErStr
$ErProvider = ""; $ErBandwidth = ""; $ErSku = ""; $ErFamily = ""
$ErNames    = @(); $ErPerlocs  = @(); $ErRegions  = @()

if ($NumErCircuits -gt 0) {
  $ErProvider  = Ask-Default "LAB_ER_PROVIDER"  "ER provider (e.g. Megaport, Equinix)"         "Megaport"
  $ErBandwidth = Ask-Default "LAB_ER_BANDWIDTH" "ER bandwidth (Mbps)"                           "50"
  $ErSku       = Ask-Default "LAB_ER_SKU"       "ER SKU tier (Local/Standard/Premium)"          "Standard"
  $ErFamily    = Ask-Default "LAB_ER_FAMILY"    "ER billing family (MeteredData/UnlimitedData)" "MeteredData"
  for ($n = 1; $n -le $NumErCircuits; $n++) {
    $ErNames   += Ask-Default "LAB_ER${n}_NAME"   "ER circuit $n name"             "${LabPrefix}-er${n}"
    $ErPerlocs += Ask-Default "LAB_ER${n}_PERLOC" "ER circuit $n peering location" "Washington DC"
    $ErRegions += Ask-Default "LAB_ER${n}_REGION" "ER circuit $n Azure region"     $HubRegions[0]
  }
}

# ---------- Phase 2: Generate credentials -----------------------------------
Write-Host ""
Log "### Phase 2: Generating VM credentials ###"
$suffix = -join ((1..2) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })
$AdminUsername = "labadmin$suffix"
$AdminPassword = New-LabPassword
Write-Host "  Admin username : $AdminUsername"
Write-Host "  Admin password : <stored in Key Vault — not echoed>"

# ---------- Phase 3: VM SKU pre-flight per hub region -----------------------
Write-Host ""
Log "### Phase 3: VM SKU pre-flight ###"
$HubVmSkus    = @()
$RegionSkuMap = @{}
for ($i = 0; $i -lt $NumHubs; $i++) {
  $region = $HubRegions[$i]
  if ($DeployVms) {
    if (-not $RegionSkuMap.ContainsKey($region)) {
      $RegionSkuMap[$region] = Pick-VmSku -Region $region
    }
    $HubVmSkus += $RegionSkuMap[$region]
    Write-Host "  Hub $($i+1) ($region): $($RegionSkuMap[$region])"
  } else {
    $HubVmSkus += "Standard_B2s"
  }
}

# ---------- Phase 4: Resource group + Key Vault name ------------------------
Write-Host ""
Log "### Phase 4: Resource group ###"
az group create -n $Rg -l $DeployLoc --output none
Write-Host "  Resource group : $Rg ($DeployLoc)"

# KV name: labPrefix + "kv" + 4 random hex chars, lowercase alnum, max 24
$kvRand = -join ((1..2) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })
$kvRaw  = "${LabPrefix}kv${kvRand}"
$KvName = ($kvRaw -replace '[^a-z0-9]','').Substring(0, [Math]::Min(24, $kvRaw.Length))
Write-Host "  Key Vault name : $KvName"

$DeployerOid = (az ad signed-in-user show --query id -o tsv 2>$null)
$OwnerName   = (az account show --query user.name -o tsv 2>$null)

# ---------- Phase 5: Build hubs JSON array + write params file -------------
Write-Host ""
Log "### Phase 5: Building deployment parameters ###"
$hubsArr = @()
for ($i = 1; $i -le $NumHubs; $i++) {
  $idx = $i - 1
  $hubsArr += [ordered]@{
    region             = $HubRegions[$idx]
    hubAddressPrefix   = "10.$($i * 10).0.0/23"
    spokeAddressPrefix = "10.$($i * 10 + 1).0.0/24"
    subnetPrefix       = "10.$($i * 10 + 1).0.0/27"
    deployErGateway    = $HubHasErg[$idx]
    deployVm           = $DeployVms
    vmSize             = $HubVmSkus[$idx]
  }
}

$deployVmsBool  = $DeployVms.ToString().ToLower()
$attachPipBool  = $AttachPip.ToString().ToLower()
$enableDiagBool = $EnableDiag.ToString().ToLower()
$hubsJson       = ($hubsArr | ConvertTo-Json -Depth 5 -Compress)

$null = New-Item -ItemType Directory -Path $ParamsDir -Force
$ParamsFile = Join-Path $ParamsDir "generated-${LabPrefix}.json"

$tagsObj = [ordered]@{ owner = $OwnerName; labName = $LabPrefix }
$paramsDoc = [ordered]@{
  "`$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
  contentVersion  = "1.0.0.0"
  parameters      = [ordered]@{
    labPrefix          = @{ value = $LabPrefix }
    location           = @{ value = $DeployLoc }
    hubs               = @{ value = $hubsArr }
    tags               = @{ value = $tagsObj }
    adminUsername      = @{ value = $AdminUsername }
    sshPublicKey       = @{ value = $SshPubKey }
    vmSize             = @{ value = "Standard_B2s" }
    keyVaultName       = @{ value = $KvName }
    deployerObjectId   = @{ value = $DeployerOid }
    enableDiagnostics  = @{ value = $EnableDiag }
    allowedSshSourceIp = @{ value = $MyPip }
    attachPublicIp     = @{ value = $AttachPip }
  }
}
$paramsDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $ParamsFile -Encoding UTF8
Write-Host "  Parameters file: $ParamsFile"

# ---------- Phase 6: Deploy main.bicep (with VM SKU auto-retry) -------------
Write-Host ""
Log "### Phase 6: Deploying main Bicep template ###"
Log "  Template       : ${BicepDir}\main.bicep"
Log "  NOTE: Azure Firewall provisioning takes ~30-45 min. Please wait."
# SKU auto-retry: if the bicep deployment fails with SkuNotAvailable/Capacity
# the loop advances to the next candidate in $VmSkuCandidates, regenerates the
# params file for ALL hubs with that SKU, and retries.  Stops when a SKU works
# or when the list is exhausted.
$deployStart   = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$SkuRetryIdx   = 0   # index into $VmSkuCandidates; advanced on each SkuNotAvailable failure
$DeploySuccess = $false

while (-not $DeploySuccess) {
  # Rebuild hub array and params file with current SKU candidate for every hub.
  $currentSku = $VmSkuCandidates[$SkuRetryIdx]
  for ($ii = 0; $ii -lt $NumHubs; $ii++) { $HubVmSkus[$ii] = $currentSku }

  $retryHubsArr = @()
  for ($ii = 1; $ii -le $NumHubs; $ii++) {
    $hIdx = $ii - 1
    $retryHubsArr += [ordered]@{
      region             = $HubRegions[$hIdx]
      hubAddressPrefix   = "10.$($ii * 10).0.0/23"
      spokeAddressPrefix = "10.$($ii * 10 + 1).0.0/24"
      subnetPrefix       = "10.$($ii * 10 + 1).0.0/27"
      deployErGateway    = $HubHasErg[$hIdx]
      deployVm           = $DeployVms
      vmSize             = $currentSku
    }
  }
  $paramsDoc.parameters.hubs.value = $retryHubsArr
  $paramsDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $ParamsFile -Encoding UTF8

  $DeploymentName = "${LabPrefix}-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
  Log "  Deployment name: $DeploymentName  (VM SKU: $currentSku)"

  $rawDeployOut = az deployment group create `
    -g $Rg `
    -n $DeploymentName `
    --template-file "${BicepDir}\main.bicep" `
    --parameters "@$ParamsFile" `
                 adminPassword=$AdminPassword `
    --output none 2>&1

  if ($LASTEXITCODE -eq 0) {
    $DeploySuccess = $true
  } elseif (($rawDeployOut | Out-String) -match 'SkuNotAvailable|Capacity') {
    # VM SKU unavailable in this region — try the next candidate.
    $SkuRetryIdx++
    if ($SkuRetryIdx -ge $VmSkuCandidates.Count) {
      throw "All VM SKU candidates exhausted. Tried: $($VmSkuCandidates -join ', '). Last error:`n$($rawDeployOut | Out-String)"
    }
    Log "  [SKU-RETRY] SkuNotAvailable/Capacity detected — retrying with $($VmSkuCandidates[$SkuRetryIdx])..."
  } else {
    # Non-SKU failure: surface the error and abort.
    $rawDeployOut | ForEach-Object { Write-Host $_ }
    throw "Deployment failed (not a SKU availability error)."
  }
}
Log "  Bicep deployment complete."

# ---------- Phase 7: Compute hub/spoke/fw names from naming convention ------
$HubNames   = @(); $SpokeNames = @(); $FwNames = @()
for ($i = 1; $i -le $NumHubs; $i++) {
  $HubNames   += "${LabPrefix}-vhub${i}"
  $SpokeNames += "${LabPrefix}-spoke${i}"
  $FwNames    += "${LabPrefix}-vhub${i}-azfw"
}

# ---------- Phase 8: Poll hub provisioningState + routingPreference ---------
Write-Host ""
Log "### Phase 8: Waiting for vHubs to reach provisioningState=Succeeded ###"
$p8Iter = 0; $p8Max = 40   # 40 × 15 s = 10 min
do {
  $p8Iter++
  if ($p8Iter -gt $p8Max) { Log "  WARNING: hub provisioningState poll timed out after $p8Max iterations — continuing."; break }
  $allOk = $true
  foreach ($hub in $HubNames) {
    $state = (az network vhub show -g $Rg -n $hub --query provisioningState -o tsv 2>$null)
    Log "  $hub = $state"
    if ($state -ne "Succeeded") { $allOk = $false }
  }
  if (-not $allOk) { Start-Sleep 15 }
} while (-not $allOk)

Write-Host "  Verifying hubRoutingPreference=ExpressRoute..."
foreach ($hub in $HubNames) {
  $hrp = (az network vhub show -g $Rg -n $hub --query hubRoutingPreference -o tsv 2>$null)
  if ($hrp -ne "ExpressRoute") {
    Write-Host "  ${hub}: $hrp — applying fallback update..."
    az network vhub update -g $Rg -n $hub --hub-routing-preference ExpressRoute --output none
    Write-Host "  $hub updated to ExpressRoute."
  } else {
    Write-Host "  ${hub}: hubRoutingPreference=$hrp ✔"
  }
}

Log "  Waiting for routingState=Provisioned..."
foreach ($hub in $HubNames) {
  $rtIter = 0; $rtMax = 36   # 36 × 10 s = 6 min
  do {
    $rtIter++
    if ($rtIter -gt $rtMax) { Log "  WARNING: routingState poll timed out for $hub after $rtMax iterations — continuing."; break }
    $rtState = (az network vhub show -g $Rg -n $hub --query routingState -o tsv 2>$null)
    Log "  $hub routingState=$rtState"
    if ($rtState -ne "Provisioned") { Start-Sleep 10 }
  } while ($rtState -ne "Provisioned")
}

# ---------- Phase 9: Spoke VNet connections ---------------------------------
Write-Host ""
Log "### Phase 9: Creating spoke VNet connections ###"
# Enable Propagate Default Route (internetSecurity) when Routing Intent injects 0.0.0.0/0.
$isecArgs = if ($RiMode -in @('internetOnly', 'both')) { @('--internet-security', 'true') } else { @() }
for ($i = 0; $i -lt $NumHubs; $i++) {
  $hub   = $HubNames[$i]; $spoke = $SpokeNames[$i]
  Write-Host "  Connecting $spoke → $hub (--no-wait)..."
  az network vhub connection create `
    -n "${spoke}-conn" --remote-vnet $spoke `
    -g $Rg --vhub-name $hub @isecArgs --no-wait --output none
}

Write-Host "  Waiting for all spoke connections to Succeed..."
$p9Iter = 0; $p9Max = 40   # 40 × 30 s = 20 min
do {
  $p9Iter++
  if ($p9Iter -gt $p9Max) { Log "  WARNING: spoke-connection poll timed out after $p9Max iterations — continuing."; break }
  $allOk = $true
  for ($i = 0; $i -lt $NumHubs; $i++) {
    $hub   = $HubNames[$i]; $spoke = $SpokeNames[$i]
    $state = (az network vhub connection show -n "${spoke}-conn" `
      --vhub-name $hub -g $Rg --query provisioningState -o tsv 2>$null)
    Log "  ${spoke}-conn = $state"
    if ($state -ne "Succeeded") { $allOk = $false }
  }
  if (-not $allOk) { Start-Sleep 30 }
} while (-not $allOk)

# ---------- Phase 10: ER circuits -------------------------------------------
if ($NumErCircuits -gt 0) {
  Write-Host ""
  Write-Host "### Phase 10: Creating ExpressRoute circuits ###"
  $erJobs = @()
  for ($n = 0; $n -lt $NumErCircuits; $n++) {
    $en = $ErNames[$n]; $ep = $ErPerlocs[$n]; $er = $ErRegions[$n]
    Write-Host "  Creating $en ($ep, $er)..."
    $erJobs += Start-Job -ScriptBlock {
      param($en,$ep,$er,$ErProvider,$ErBandwidth,$ErSku,$ErFamily,$Rg)
      az network express-route create --bandwidth $ErBandwidth -n $en `
        --peering-location $ep -g $Rg --provider $ErProvider `
        -l $er --sku-family $ErFamily --sku-tier $ErSku -o none
    } -ArgumentList $en,$ep,$er,$ErProvider,$ErBandwidth,$ErSku,$ErFamily,$Rg
  }
  $erJobs | Wait-Job | Remove-Job

  Write-Host ""
  Write-Host "######################################################################"
  Write-Host "#         ExpressRoute Service Keys — hand these to the provider     #"
  Write-Host "######################################################################"
  for ($n = 0; $n -lt $NumErCircuits; $n++) {
    $en = $ErNames[$n]; $ep = $ErPerlocs[$n]
    $sk = (az network express-route show -g $Rg -n $en --query serviceKey -o tsv)
    Write-Host ""
    Write-Host "  Circuit     : $en  (Provider: $ErProvider / Location: $ep)"
    Write-Host "  Service Key : $sk"
  }
  Write-Host ""
  Write-Host "  Log in to the provider portal and place orders using the keys above."
  Read-Host "  Press ENTER once you have submitted the orders to $ErProvider"

  $maxErSecs = $MaxWaitMin * 60
  for ($n = 0; $n -lt $NumErCircuits; $n++) {
    $en        = $ErNames[$n]
    $pollStart = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Host ""
    Write-Host "  Polling $en (max ${MaxWaitMin} min)..."
    do {
      $elapsed = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $pollStart
      if ($elapsed -gt $maxErSecs) { throw "Timeout waiting for $en to be Provisioned." }
      $state = (az network express-route show -g $Rg -n $en `
        --query serviceProviderProvisioningState -o tsv 2>$null)
      Write-Host "  ${en}: $state  (elapsed: $([int]($elapsed/60))m / ${MaxWaitMin}m)"
      if ($state -ne "Provisioned") { Start-Sleep 30 }
    } while ($state -ne "Provisioned")
    Write-Host "  $en is Provisioned ✔"

    # Prompt which hub to connect to
    Write-Host ""
    Write-Host "  Available hubs:"
    for ($i = 0; $i -lt $NumHubs; $i++) {
      Write-Host "    $($i+1)) $($HubNames[$i]) ($($HubRegions[$i]))"
    }
    $hubChoice = Read-Host "  Connect $en to which hub number? [1]"
    if ([string]::IsNullOrWhiteSpace($hubChoice)) { $hubChoice = "1" }
    $hi            = [int]$hubChoice - 1
    $targetHub     = $HubNames[$hi]
    $targetRegion  = $HubRegions[$hi]
    $ergwName      = "${targetHub}-ergw"

    # Ensure ER gateway exists
    $ergwState = (az network express-route gateway show -g $Rg -n $ergwName `
      --query provisioningState -o tsv 2>$null)
    if ($ergwState -ne "Succeeded") {
      Write-Host "  Creating ER gateway $ergwName in $targetHub ($targetRegion)..."
      az network express-route gateway create `
        -g $Rg -n $ergwName `
        --location $targetRegion --min-val 1 `
        --virtual-hub $targetHub -o none
      $ergwIter = 0; $ergwMax = 40   # 40 × 15 s = 10 min
      do {
        $ergwIter++
        if ($ergwIter -gt $ergwMax) { Log "  WARNING: ER-gateway poll timed out for $ergwName after $ergwMax iterations — continuing."; break }
        $ergwState = (az network express-route gateway show -g $Rg -n $ergwName `
          --query provisioningState -o tsv 2>$null)
        Log "  $ergwName = $ergwState"
        if ($ergwState -ne "Succeeded") { Start-Sleep 15 }
      } while ($ergwState -ne "Succeeded")
    } else {
      Write-Host "  ER gateway $ergwName already Succeeded ✔"
    }

    # Create ER gateway connection
    $peering  = (az network express-route show -g $Rg -n $en --query 'peerings[0].id' -o tsv)
    $rtid     = (az network vhub route-table show --name defaultRouteTable `
      --vhub-name $targetHub -g $Rg --query id -o tsv)
    $connName = "${targetHub}-conn-to-${en}"
    Write-Host "  Creating ER gateway connection: $connName..."
    az network express-route gateway connection create `
      --name $connName -g $Rg --gateway-name $ergwName `
      --peering $peering `
      --associated-route-table $rtid `
      --propagated-route-tables $rtid `
      --labels default -o none

    $erConnIter = 0; $erConnMax = 40   # 40 × 30 s = 20 min
    do {
      $erConnIter++
      if ($erConnIter -gt $erConnMax) { Log "  WARNING: ER-connection poll timed out for $connName after $erConnMax iterations — continuing."; break }
      $connState = (az network express-route gateway connection show `
        --name $connName -g $Rg --gateway-name $ergwName `
        --query provisioningState -o tsv 2>$null)
      Log "  $connName = $connState"
      if ($connState -ne "Succeeded") { Start-Sleep 30 }
    } while ($connState -ne "Succeeded")
    Write-Host "  ER connection $connName Succeeded ✔"
  }
}

# ---------- Phase 11: Wait for firewalls ------------------------------------
Write-Host ""
Log "### Phase 11: Waiting for all Azure Firewalls to Succeed ###"
$p11Iter = 0; $p11Max = 80   # 80 × 15 s = 20 min (firewalls take ~15-20 min)
do {
  $p11Iter++
  if ($p11Iter -gt $p11Max) { Log "  WARNING: firewall poll timed out after $p11Max iterations — continuing."; break }
  $allOk = $true
  foreach ($fw in $FwNames) {
    $state = (az network firewall show -g $Rg -n $fw --query provisioningState -o tsv 2>$null)
    Log "  $fw = $state"
    if ($state -ne "Succeeded") { $allOk = $false }
  }
  if (-not $allOk) { Start-Sleep 15 }
} while (-not $allOk)

# ---------- Phase 12: Routing Intent ----------------------------------------
Write-Host ""
Log "### Phase 12: Creating Routing Intent (mode: $RiMode) ###"
$riJobs = @()
for ($i = 0; $i -lt $NumHubs; $i++) {
  $hub    = $HubNames[$i]; $fw = $FwNames[$i]
  $riName = "${hub}-ri"
  $fwId   = (az network firewall show -g $Rg -n $fw --query id -o tsv)
  $policies = Build-RiPolicies -FwId $fwId -Mode $RiMode
  Log "  Creating $riName (nextHop → $fw)..."
  $riJobs += Start-Job -ScriptBlock {
    param($Rg,$hub,$riName,$policies)
    # BUG FIX: routing-intent subcommands use --vhub (not --vhub-name)
    az network vhub routing-intent create -g $Rg --vhub $hub -n $riName `
      --routing-policies $policies --output none
  } -ArgumentList $Rg,$hub,$riName,$policies
}
$riJobs | Wait-Job | Remove-Job

Log "  Polling Routing Intent provisioningState..."
$p12Iter = 0; $p12Max = 20   # 20 × 15 s = 5 min max; empty/error counts toward limit
do {
  $p12Iter++
  if ($p12Iter -gt $p12Max) { Log "  WARNING: Routing Intent poll timed out after $p12Max iterations — continuing."; break }
  $allOk = $true
  for ($i = 0; $i -lt $NumHubs; $i++) {
    $hub    = $HubNames[$i]; $riName = "${hub}-ri"
    # BUG FIX: routing-intent subcommands use --vhub (not --vhub-name)
    $state  = (az network vhub routing-intent show -g $Rg --vhub $hub `
      -n $riName --query provisioningState -o tsv 2>$null)
    if ([string]::IsNullOrWhiteSpace($state)) { $state = "Unknown" }
    Log "  $riName = $state"
    if ($state -ne "Succeeded") { $allOk = $false }
  }
  if (-not $allOk) { Start-Sleep 15 }
} while (-not $allOk)

# ---------- Phase 13: Summary -----------------------------------------------
$deployEnd = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Write-Host ""
Log "######################################################################"
Log "#                    DEPLOYMENT COMPLETE                             #"
Log "######################################################################"
Write-Host ""
Write-Host "  Lab prefix     : $LabPrefix"
Write-Host "  Resource group : $Rg"
Write-Host "  Key Vault      : $KvName"
Write-Host "  Routing Intent : $RiMode (on all hubs)"
Write-Host "  Total duration : $([int](($deployEnd - $deployStart) / 60)) min"
Write-Host ""
Write-Host "=== Hub Summary ==="
for ($i = 0; $i -lt $NumHubs; $i++) {
  $hub = $HubNames[$i]; $fw = $FwNames[$i]; $spoke = $SpokeNames[$i]
  $fwip = (az network firewall show -g $Rg -n $fw `
    --query 'hubIPAddresses.privateIPAddress' -o tsv 2>$null)
  Write-Host "  Hub $($i+1): $hub | FW: $fw ($fwip) | Spoke: $spoke"
}

Write-Host ""
Write-Host "=== VM Private IPs ==="
$nics = (az network nic list -g $Rg --query '[].name' -o tsv 2>$null) -split "`n" | Where-Object { $_ }
foreach ($nic in $nics) {
  $pip = (az network nic show -g $Rg -n $nic `
    --query 'ipConfigurations[0].privateIPAddress' -o tsv 2>$null)
  Write-Host "  ${nic}: $pip"
}

Write-Host ""
Write-Host "=== VM Credentials (stored in Key Vault) ==="
Write-Host "  Authentication : username + password (no SSH key required)"
Write-Host "  Key Vault      : $KvName"
Write-Host "  Retrieve username:"
Write-Host "    az keyvault secret show --vault-name $KvName --name vm-admin-username --query value -o tsv"
Write-Host "  Retrieve password:"
Write-Host "    az keyvault secret show --vault-name $KvName --name vm-admin-password --query value -o tsv"
Write-Host "  Access via Azure Serial Console or VM-to-VM SSH with the password."

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗"
Write-Host "║  ⚠️  REMINDER: Firewall policy has a LAB-ONLY allow-all rule.   ║"
Write-Host "║  ⚠️  All hubs use Route Preference = ExpressRoute.               ║"
Write-Host "║  ⚠️  Run cleanup.ps1 when the lab is done to avoid charges.      ║"
Write-Host "╚══════════════════════════════════════════════════════════════════╝"
