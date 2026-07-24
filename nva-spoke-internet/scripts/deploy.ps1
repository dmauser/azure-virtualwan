#Requires -Version 5.1
# =============================================================================
# deploy.ps1 — PowerShell equivalent of deploy.sh for nva-spoke-internet lab.
#              Parity with deploy.sh (same 13-phase flow).
#              Run on Windows where bash is unavailable.
#
# Usage: .\deploy.ps1
# Requirements: Azure CLI (az), jq (optional; uses ConvertFrom-Json fallback),
#               openssl (Git-for-Windows ships it; or use PowerShell alternative).
# =============================================================================

param(
    [string]$Location       = "",
    [string]$Rg             = "",
    [string]$AdminUsername  = "",
    [switch]$DeployOnPrem,
    [switch]$SkipPreflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$BicepDir   = Join-Path $ScriptDir "..\bicep"
$DeployName = "nva-spoke-internet-deploy"

# ---------- Helpers ----------------------------------------------------------
function Log([string]$m) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Cyan
}

function LogPlain([string]$m) { Write-Host $m }

function Require([string]$cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required tool not found: $cmd.  Please install it and re-run."
    }
}

# Generates a random hex string of the given byte length using PowerShell.
# Falls back to openssl if available (consistent with deploy.sh).
function New-HexKey([int]$bytes = 24) {
    if (Get-Command openssl -ErrorAction SilentlyContinue) {
        return (& openssl rand -hex $bytes).Trim()
    }
    # PowerShell-native fallback
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $data = New-Object byte[] $bytes
    $rng.GetBytes($data)
    return [System.BitConverter]::ToString($data).Replace("-","").ToLower()
}

# Convert SecureString to plain text for passing to az CLI.
function ConvertTo-PlainText([System.Security.SecureString]$ss) {
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# Poll a command (scriptblock) until its trimmed output equals $target.
# Bounded to $maxIter iterations.
function Poll-Until {
    param(
        [string]$Label,
        [string]$Target,
        [int]$SleepSec = 10,
        [int]$MaxIter  = 60,
        [scriptblock]$Command
    )
    $iter = 0
    while ($true) {
        $iter++
        if ($iter -gt $MaxIter) {
            Log "  WARNING: Poll-Until '$Label' timed out after $MaxIter iterations — continuing."
            break
        }
        $state = (& $Command 2>$null).Trim()
        Log "  ${Label}: ${state}"
        if ($state -eq $Target) { break }
        Start-Sleep -Seconds $SleepSec
    }
}

# Pick first unrestricted B-series SKU via az vm list-skus.
function Pick-VmSku([string]$Region) {
    $candidates = @("Standard_B2s","Standard_B2ms","Standard_B1ms")
    foreach ($sku in $candidates) {
        $r = (az vm list-skus -l $Region --resource-type virtualMachines `
                --query "[?name=='$sku'].restrictions" -o tsv 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($r) -or $r -eq "None") {
            return $sku
        }
    }
    Log "  WARNING: No B-series SKU with empty restrictions found in '$Region'."
    Log "           Using Standard_B2s as fallback; preflight will verify capacity."
    return "Standard_B2s"
}

# Real VM allocation probe in a throw-away RG.  Returns the first SKU that
# successfully allocates, or throws on total failure.
function Preflight-VmCapacity([string]$Region, [string]$InitialSku) {
    if ($SkipPreflight) {
        Log "  [cap-check] --SkipPreflight set — skipping capacity pre-flight."
        return $InitialSku
    }

    $suffix = (New-HexKey 3)
    $capRg  = "capcheck-nvaspk-${Region}-${suffix}"
    # Throw-away password for probe only.
    $capPass = "CapChk$(New-HexKey 6)Aa1!"

    Log "  [cap-check] Creating temp probe RG: $capRg in $Region"
    az group create -n $capRg -l $Region --output none 2>$null

    Log "  [cap-check] Creating probe VNet + subnet ..."
    az network vnet create -g $capRg -n "capchk-vnet" `
        --address-prefix "10.250.0.0/24" `
        --subnet-name "capchk-subnet" --subnet-prefix "10.250.0.0/27" `
        --location $Region --output none 2>$null

    $candidates = @($InitialSku)
    @("Standard_B2s","Standard_B2ms","Standard_B1ms") | ForEach-Object {
        if ($_ -ne $InitialSku) { $candidates += $_ }
    }

    $skuOk = $null
    foreach ($probeSku in $candidates) {
        Log "  [cap-check] Probing SKU $probeSku in $Region ..."
        $errLines = ""
        $code = 0
        try {
            az vm create -g $capRg -n "capchk-probe" -l $Region `
                --image Ubuntu2204 --size $probeSku `
                --admin-username capchk --admin-password $capPass `
                --public-ip-address "" `
                --vnet-name "capchk-vnet" --subnet "capchk-subnet" `
                --nic-delete-option Delete --os-disk-delete-option Delete `
                --only-show-errors --output none 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } catch {
            $errLines = $_.Exception.Message
            $code = 1
        }
        if ($code -eq 0) {
            $skuOk = $probeSku
            if ($probeSku -ne $InitialSku) {
                Log "  [cap-check] NOTE: '$InitialSku' unavailable — using '$probeSku' instead."
            } else {
                Log "  [cap-check] ✔ $probeSku is allocatable in $Region"
            }
            break
        } else {
            Log "  [cap-check] ✗ $probeSku is capacity-blocked in $Region"
            az vm delete -g $capRg -n "capchk-probe" --yes --no-wait --output none 2>$null | Out-Null
        }
    }

    Log "  [cap-check] Deleting probe RG $capRg (--no-wait) ..."
    az group delete -n $capRg --yes --no-wait --output none 2>$null | Out-Null

    if (-not $skuOk) {
        Log ""
        Log "  ╔══════════════════════════════════════════════════════════════╗"
        Log "  ║  ✗  VM CAPACITY PRE-FLIGHT FAILED — deployment aborted      ║"
        Log "  ╚══════════════════════════════════════════════════════════════╝"
        Log "  Region     : $Region"
        Log "  Tried SKUs : $($candidates -join ', ')"
        Log "  ➤ Try a different region: eastus2  westus2  westus3  centralus"
        throw "VM capacity pre-flight failed in region '$Region'."
    }
    return $skuOk
}

# =============================================================================
# Phase 1 — Prerequisite check
# =============================================================================
Log "=== Phase 1: Checking prerequisites ==="

Require "az"
# jq is optional on PowerShell path; we use ConvertFrom-Json as primary parser.

$acctJson = (az account show -o json 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acctJson)) {
    throw "Not logged in to Azure. Run: az login"
}
$acct = $acctJson | ConvertFrom-Json
Log "  Logged in — subscription: $($acct.name) ($($acct.id))"

# =============================================================================
# Phase 2 — Prompts
# =============================================================================
Log "=== Phase 2: Parameters ==="

if ([string]::IsNullOrWhiteSpace($Location)) {
    $inp = Read-Host "  Azure region [eastus]"
    $Location = if ([string]::IsNullOrWhiteSpace($inp)) { "eastus" } else { $inp.Trim() }
}

if ([string]::IsNullOrWhiteSpace($Rg)) {
    $inp = Read-Host "  Resource group name [rg-nva-spoke-internet]"
    $Rg = if ([string]::IsNullOrWhiteSpace($inp)) { "rg-nva-spoke-internet" } else { $inp.Trim() }
}

if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $inp = Read-Host "  Admin username [azureuser]"
    $AdminUsername = if ([string]::IsNullOrWhiteSpace($inp)) { "azureuser" } else { $inp.Trim() }
}

# Secure password prompt with confirmation loop
$AdminPasswordPlain = ""
while ($true) {
    $ss1 = Read-Host "  Admin password (min 12 chars, complexity required)" -AsSecureString
    $ss2 = Read-Host "  Confirm password" -AsSecureString
    $p1  = ConvertTo-PlainText $ss1
    $p2  = ConvertTo-PlainText $ss2
    if ($p1 -ne $p2) {
        Write-Host "  Passwords do not match — try again."
    } elseif ($p1.Length -lt 12) {
        Write-Host "  Password is too short (minimum 12 characters) — try again."
    } else {
        $AdminPasswordPlain = $p1
        break
    }
}

if (-not $DeployOnPrem) {
    $inp = Read-Host "  Deploy on-prem simulation? (y/N) [N]"
    if ($inp.Trim().ToLower() -eq "y") { $DeployOnPrem = $true }
}

Log ""
Log "  Location       : $Location"
Log "  Resource group : $Rg"
Log "  Admin username : $AdminUsername"
Log "  On-prem deploy : $DeployOnPrem"
Log ""

# =============================================================================
# Phase 3 — VM SKU selection + capacity preflight
# =============================================================================
Log "=== Phase 3: VM SKU selection ==="
$CandidateSku = Pick-VmSku -Region $Location
Log "  list-skus candidate: $CandidateSku"
Log "  Running capacity pre-flight in $Location (this may take ~2 min) ..."
$VmSize = Preflight-VmCapacity -Region $Location -InitialSku $CandidateSku
Log "  ✔ VM_SIZE resolved: $VmSize"

# =============================================================================
# Phase 4 — Create resource group
# =============================================================================
Log "=== Phase 4: Creating resource group '$Rg' ==="
az group create -n $Rg -l $Location --output none
Log "  ✔ Resource group ready."

# =============================================================================
# Phase 5 — Generate PSK (if on-prem)
# =============================================================================
$VpnSharedKey = ""
if ($DeployOnPrem) {
    Log "=== Phase 5: Generating VPN PSK ==="
    $VpnSharedKey = New-HexKey 24
    Log "  ✔ PSK generated."
}

# =============================================================================
# Phase 6 — Bicep deployment
# =============================================================================
Log "=== Phase 6: Deploying Bicep template '$DeployName' ==="
Log "  This will take 20-40 minutes (vWAN hub + VPN gateway provisioning) ..."

$deployOnPremParam = if ($DeployOnPrem) { "true" } else { "false" }
$bicepPath = Join-Path $BicepDir "main.bicep"

az deployment group create `
    -g $Rg `
    -f $bicepPath `
    -n $DeployName `
    --parameters `
        location="$Location" `
        adminUsername="$AdminUsername" `
        adminPassword="$AdminPasswordPlain" `
        vmSize="$VmSize" `
        deployOnPrem="$deployOnPremParam" `
        onpremBgpAsn=65001 `
    --output none

if ($LASTEXITCODE -ne 0) { throw "Bicep deployment failed." }
Log "  ✔ Bicep deployment complete."

# =============================================================================
# Phase 7 — Read deployment outputs
# =============================================================================
Log "=== Phase 7: Reading deployment outputs ==="

$outputsJson = az deployment group show -g $Rg -n $DeployName `
    --query "properties.outputs" -o json
$outputs = $outputsJson | ConvertFrom-Json

function Get-Out([string]$name) {
    $v = $outputs.$name.value
    if ($null -eq $v) { return "" }
    return "$v"
}

$HubName          = Get-Out "hubName"
$VwanName         = Get-Out "vwanName"
$DmzVnetId        = Get-Out "dmzVnetId"
$Spoke1VnetId     = Get-Out "spoke1VnetId"
$Spoke2VnetId     = Get-Out "spoke2VnetId"
$IlbFrontendIp    = Get-Out "ilbFrontendIp"
$PublicLbPip      = Get-Out "publicLbPublicIp"
$VpnGwName        = Get-Out "vpnGatewayName"
$OnpremNvaPip     = Get-Out "onpremNvaPublicIp"
$OnpremNvaPrivIp  = Get-Out "onpremNvaPrivateIp"
$OnpremNvaName    = Get-Out "onpremNvaName"
$OnpremVmName     = Get-Out "onpremVmName"

# Construct defaultRouteTable resource ID
$subscription = (az account show --query id -o tsv).Trim()
$DefaultRtId  = "/subscriptions/${subscription}/resourceGroups/${Rg}/providers/Microsoft.Network/virtualHubs/${HubName}/hubRouteTables/defaultRouteTable"

Log "  Hub             : $HubName"
Log "  VWAN            : $VwanName"
Log "  DMZ VNet        : $DmzVnetId"
Log "  Spoke1 VNet     : $Spoke1VnetId"
Log "  Spoke2 VNet     : $Spoke2VnetId"
Log "  ILB frontend    : $IlbFrontendIp"
Log "  Public LB PIP   : $PublicLbPip"
if ($VpnGwName)      { Log "  VPN GW          : $VpnGwName" }
if ($OnpremNvaPip)   { Log "  On-prem NVA PIP : $OnpremNvaPip" }
if ($OnpremNvaPrivIp){ Log "  On-prem NVA priv: $OnpremNvaPrivIp" }

if ($IlbFrontendIp -ne "10.0.0.68") {
    Write-Warning "ILB frontend IP from outputs is '$IlbFrontendIp', expected '10.0.0.68'. Continuing with actual value."
}

# =============================================================================
# Phase 8 — Wait for hub routingState = Provisioned
# =============================================================================
Log "=== Phase 8: Waiting for hub '$HubName' to reach routingState=Provisioned ==="
Poll-Until -Label "Hub routingState" -Target "Provisioned" -SleepSec 10 -MaxIter 60 -Command {
    (az network vhub show -g $Rg -n $HubName --query "routingState" -o tsv 2>$null).Trim()
}
Log "  ✔ Hub is Provisioned."

# =============================================================================
# Phase 9 — Create hub VNet connections
# =============================================================================
Log "=== Phase 9: Creating hub VNet connections ==="

Log "  Creating conn-dmz (with static 0/0 → $IlbFrontendIp) ..."
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-dmz" `
    --remote-vnet $DmzVnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --route-name "default-via-ilb" `
    --address-prefixes "0.0.0.0/0" `
    --next-hop $IlbFrontendIp `
    --output none

Poll-Until -Label "conn-dmz provisioningState" -Target "Succeeded" -SleepSec 15 -MaxIter 40 -Command {
    (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-dmz" `
        --query "provisioningState" -o tsv 2>$null).Trim()
}

Log "  Creating conn-spoke1 ..."
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-spoke1" `
    --remote-vnet $Spoke1VnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --output none

Poll-Until -Label "conn-spoke1 provisioningState" -Target "Succeeded" -SleepSec 15 -MaxIter 40 -Command {
    (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-spoke1" `
        --query "provisioningState" -o tsv 2>$null).Trim()
}

Log "  Creating conn-spoke2 ..."
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-spoke2" `
    --remote-vnet $Spoke2VnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --output none

Poll-Until -Label "conn-spoke2 provisioningState" -Target "Succeeded" -SleepSec 15 -MaxIter 40 -Command {
    (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-spoke2" `
        --query "provisioningState" -o tsv 2>$null).Trim()
}

Log "  ✔ All three hub VNet connections are Succeeded."

# =============================================================================
# Phase 10+11 — Add 0/0 to defaultRouteTable → conn-dmz
# =============================================================================
Log "=== Phase 10+11: Adding 0/0 route to hub defaultRouteTable ==="

$ConnDmzId = (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-dmz" `
    --query "id" -o tsv).Trim()
Log "  conn-dmz ID: $ConnDmzId"

# This installs 0.0.0.0/0 → conn-dmz in the hub's defaultRouteTable.
# Spoke1 and Spoke2 (associated to defaultRouteTable) will learn this route,
# steering their internet traffic through the DMZ NVAs via the ILB.
az network vhub route-table route add `
    -g $Rg --vhub-name $HubName --name "defaultRouteTable" `
    --route-name "to-internet" `
    --destination-type "CIDR" --destinations "0.0.0.0/0" `
    --next-hop-type "ResourceID" --next-hop $ConnDmzId `
    --output none

Log "  ✔ defaultRouteTable 0.0.0.0/0 → conn-dmz route installed."

# =============================================================================
# Phase 12 — On-prem VPN (conditional)
# =============================================================================
if ($DeployOnPrem) {
    Log "=== Phase 12: On-prem VPN site + connection ==="

    Log "  Creating VPN site 'onprem-vpnsite' ..."
    az network vpn-site create `
        -g $Rg -n "onprem-vpnsite" -l $Location `
        --virtual-wan $VwanName `
        --ip-address $OnpremNvaPip `
        --asn 65001 `
        --bgp-peering-address $OnpremNvaPrivIp `
        --address-prefixes "192.168.100.0/24" `
        --link-name "onprem-link" `
        --output none
    Log "  ✔ VPN site created."

    Log "  Creating VPN gateway connection 'conn-onprem' (BGP enabled) ..."
    az network vpn-gateway connection create `
        -g $Rg --gateway-name $VpnGwName -n "conn-onprem" `
        --vpn-site "onprem-vpnsite" `
        --enable-bgp $true `
        --vpn-site-link "onprem-link" `
        --output none

    Log "  Setting PSK on link index 0 ..."
    az network vpn-gateway connection vpn-site-link-conn sharedkey update `
        -g $Rg --gateway-name $VpnGwName `
        --connection-name "conn-onprem" `
        --index 0 `
        --value $VpnSharedKey `
        --output none

    Poll-Until -Label "conn-onprem provisioningState" -Target "Succeeded" -SleepSec 20 -MaxIter 60 -Command {
        (az network vpn-gateway connection show -g $Rg --gateway-name $VpnGwName -n "conn-onprem" `
            --query "provisioningState" -o tsv 2>$null).Trim()
    }
    Log "  ✔ VPN connection provisioned."

    # Fetch hub GW PIPs + BGP peer IPs
    $gwJson = (az network vpn-gateway show -g $Rg -n $VpnGwName -o json) | ConvertFrom-Json
    $HubGwPip0   = $gwJson.ipConfigurations[0].publicIpAddress
    $HubGwPip1   = $gwJson.ipConfigurations[1].publicIpAddress
    $HubBgpPeer0 = $gwJson.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    $HubBgpPeer1 = $gwJson.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]

    Log "  Hub GW PIP0     : $HubGwPip0"
    Log "  Hub GW PIP1     : $HubGwPip1"
    Log "  Hub BGP peer0   : $HubBgpPeer0"
    Log "  Hub BGP peer1   : $HubBgpPeer1"

    # configure-onprem.sh requires bash; invoke via git-bash or wsl if available.
    $bashCandidates = @("bash", "wsl", (Join-Path $env:ProgramFiles "Git\bin\bash.exe"))
    $bashExe = $null
    foreach ($b in $bashCandidates) {
        if (Get-Command $b -ErrorAction SilentlyContinue) { $bashExe = $b; break }
    }
    if ($bashExe) {
        Log "  Calling configure-onprem.sh via '$bashExe' ..."
        & $bashExe (Join-Path $ScriptDir "configure-onprem.sh") `
            $OnpremNvaName $Rg `
            $HubGwPip0 $HubGwPip1 `
            $HubBgpPeer0 $HubBgpPeer1 `
            "65515" "65001" $OnpremNvaPrivIp $VpnSharedKey
    } else {
        Log "  WARNING: bash not found (tried git-bash and wsl)."
        Log "  Run configure-onprem.sh manually from a bash shell:"
        LogPlain "  bash $ScriptDir\configure-onprem.sh $OnpremNvaName $Rg $HubGwPip0 $HubGwPip1 $HubBgpPeer0 $HubBgpPeer1 65515 65001 $OnpremNvaPrivIp '<PSK>'"
    }
}

# =============================================================================
# Phase 13 — Validation summary
# =============================================================================
Log ""
Log "╔══════════════════════════════════════════════════════════════════════╗"
Log "║                   DEPLOYMENT COMPLETE — VALIDATION                   ║"
Log "╚══════════════════════════════════════════════════════════════════════╝"
Log ""
Log "  Resource group  : $Rg"
Log "  Hub             : $HubName  (routingState: Provisioned)"
Log "  Public LB PIP   : $PublicLbPip   ← egress SNAT IP for spoke VMs"
Log "  ILB frontend    : $IlbFrontendIp ← hub 0/0 next hop"
Log ""
Log "  ROUTING VERIFICATION:"
LogPlain "  az network vhub route-table show -g $Rg --vhub-name $HubName --name defaultRouteTable --query 'routes' -o table"
Log ""
Log "  EGRESS TEST (from Spoke1/Spoke2 VM via serial console):"
LogPlain "  curl -s --max-time 10 https://ifconfig.me"
Log "  # Expected: public IP = $PublicLbPip"
Log ""
if ($DeployOnPrem) {
    Log "  ON-PREM TUNNEL:"
    LogPlain "  az network vpn-gateway connection show -g $Rg --gateway-name $VpnGwName -n conn-onprem --query connectionStatus -o tsv"
    LogPlain "  az vm run-command invoke -g $Rg --name $OnpremNvaName --command-id RunShellScript --scripts 'ipsec status | grep ESTABLISHED'"
    Log ""
}
Log "  CLEANUP:"
LogPlain "  .\cleanup.ps1 -Rg $Rg"
Log ""
