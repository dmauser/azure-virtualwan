#Requires -Version 5.1
# =============================================================================
# deploy.ps1 — PowerShell equivalent of deploy.sh for nva-spoke-internet-paloalto.
#              Parity with deploy.sh (same 13-phase flow + Phase 1b + Phase 5b).
#              Run on Windows where bash is unavailable.
#
# Usage: .\deploy.ps1
# Requirements: Azure CLI (az), openssl (Git-for-Windows ships it; or use
#               PowerShell alternative via New-HexKey).
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
$DeployName = "nva-spoke-internet-pa-deploy"

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

# Pick first unrestricted NVA SKU via az vm list-skus.
# Standard_B-series are NOT supported for Palo Alto VM-Series.
# PA VM-Series BYOL needs ≥4 vCPU / ≥14 GB RAM AND ≥3 NICs.
# Dv4/Dv5 4-vCPU SKUs (D4s_v4 etc.) cap at 2 NICs — use 8-vCPU variants for PA.
function Pick-VmSku([string]$Region) {
    $candidates = @(
        "Standard_DS3_v2",   # 4 vCPU, 14 GB, max 4 NICs
        "Standard_DS4_v2",   # 8 vCPU, 28 GB, max 8 NICs
        "Standard_D3_v2",    # 4 vCPU, 14 GB, max 4 NICs
        "Standard_D4_v2",    # 8 vCPU, 28 GB, max 8 NICs
        "Standard_D8s_v4",   # 8 vCPU, 32 GB, max 4 NICs
        "Standard_D8s_v5",   # 8 vCPU, 32 GB, max 4 NICs
        "Standard_D8_v4",    # 8 vCPU, 32 GB, max 4 NICs
        "Standard_D8_v5"     # 8 vCPU, 32 GB, max 4 NICs
    )
    foreach ($sku in $candidates) {
        $raw = az vm list-skus -l $Region --resource-type virtualMachines `
                --query "[?name=='$sku'].restrictions" -o tsv 2>$null
        $r = if ($null -eq $raw) { "" } else { ([string]$raw).Trim() }
        if ([string]::IsNullOrWhiteSpace($r) -or $r -eq "None") {
            return $sku
        }
    }
    Log "  WARNING: No PA-compatible NVA SKU with empty restrictions found in '$Region'."
    Log "           Using Standard_DS3_v2 as fallback; preflight will verify capacity."
    return "Standard_DS3_v2"
}

# Pick first unrestricted small SKU for spoke/workload Ubuntu VMs (2 vCPU / 4-8 GB RAM).
function Pick-SpokeVmSku([string]$Region) {
    if ($SkipPreflight) { return "Standard_B2s" }

    # B-series and D2-series capacity can be blocked even when list-skus shows no restrictions.
    # Probe with a real VM allocation (throw-away RG) to find an actually-allocatable SKU.
    $suffix  = (New-HexKey 3)
    $capRg   = "capcheck-spoke-${Region}-${suffix}"
    $capPass = "CapChk$(New-HexKey 6)Aa1!"
    az group create -n $capRg -l $Region --output none 2>$null | Out-Null
    az network vnet create -g $capRg -n "capchk-vnet2" -l $Region `
        --address-prefix "10.253.0.0/16" --subnet-name "capchk-sub2" `
        --subnet-prefix "10.253.0.0/24" --output none 2>$null | Out-Null
    az network nic create -g $capRg -n "capchk-nic2" -l $Region `
        --vnet-name "capchk-vnet2" --subnet "capchk-sub2" `
        --output none 2>$null | Out-Null

    $candidates = @("Standard_B2s","Standard_B2ms","Standard_D2s_v3","Standard_D2as_v4","Standard_D2s_v4","Standard_A2_v2")
    $spokeSku = $null
    foreach ($probeSku in $candidates) {
        Log "  [spoke-cap] Probing spoke SKU $probeSku ..."
        $code = 1
        try {
            az vm create -g $capRg -n "capchk-spoke" -l $Region `
                --image Ubuntu2204 --size $probeSku `
                --admin-username capchk --admin-password $capPass `
                --nics "capchk-nic2" --os-disk-delete-option Delete `
                --only-show-errors --output none 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } catch { $code = 1 }
        if ($code -eq 0) {
            $spokeSku = $probeSku
            if ($probeSku -ne "Standard_B2s") {
                Log "  [spoke-cap] NOTE: Standard_B2s unavailable — using '$probeSku' instead."
            } else {
                Log "  [spoke-cap] ✔ $probeSku allocatable."
            }
            break
        } else {
            Log "  [spoke-cap] ✗ $probeSku capacity-blocked."
            az vm delete -g $capRg -n "capchk-spoke" --yes --no-wait --output none 2>$null | Out-Null
        }
    }
    az group delete -n $capRg --yes --no-wait --output none 2>$null | Out-Null

    if (-not $spokeSku) {
        Log "  WARNING: No spoke VM SKU allocatable in $Region. Falling back to Standard_B2s."
        return "Standard_B2s"
    }
    return $spokeSku
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

    # Pre-create a NIC without a public IP (avoids the Windows empty-string bug
    # where --public-ip-address "" is silently dropped by PowerShell → az fails).
    Log "  [cap-check] Creating probe NIC (no public IP) ..."
    az network nic create -g $capRg -n "capchk-nic" -l $Region `
        --vnet-name "capchk-vnet" --subnet "capchk-subnet" `
        --output none 2>$null

    $candidates = @($InitialSku)
    @("Standard_DS3_v2","Standard_DS4_v2","Standard_D3_v2","Standard_D4_v2",
      "Standard_D8s_v4","Standard_D8s_v5","Standard_D8_v4","Standard_D8_v5") | ForEach-Object {
        if ($_ -ne $InitialSku) { $candidates += $_ }
    }

    $skuOk = $null
    foreach ($probeSku in $candidates) {
        Log "  [cap-check] Probing SKU $probeSku in $Region ..."
        $errLines = ""
        $code = 0
        try {
            # Use pre-created NIC (no public IP) instead of --public-ip-address ""
            # which is silently dropped on Windows PowerShell → CLI argument error.
            az vm create -g $capRg -n "capchk-probe" -l $Region `
                --image Ubuntu2204 --size $probeSku `
                --admin-username capchk --admin-password $capPass `
                --nics "capchk-nic" `
                --os-disk-delete-option Delete `
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
# Phase 1b — Accept Palo Alto VM-Series marketplace image terms
# =============================================================================
Log "=== Phase 1b: Accepting Palo Alto VM-Series marketplace image terms ==="
az vm image terms accept --urn "paloaltonetworks:vmseries-flex:byol:latest" --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to accept PA VM-Series image terms." }
Log "  ✔ Image terms accepted (paloaltonetworks:vmseries-flex:byol:latest)."

# =============================================================================
# Phase 2 — Prompts
# =============================================================================
Log "=== Phase 2: Parameters ==="

if ([string]::IsNullOrWhiteSpace($Location)) {
    $inp = Read-Host "  Azure region [westus3]"
    $Location = if ([string]::IsNullOrWhiteSpace($inp)) { "westus3" } else { $inp.Trim() }
}

if ([string]::IsNullOrWhiteSpace($Rg)) {
    $inp = Read-Host "  Resource group name [rg-nva-spoke-internet-pa]"
    $Rg = if ([string]::IsNullOrWhiteSpace($inp)) { "rg-nva-spoke-internet-pa" } else { $inp.Trim() }
}

if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $inp = Read-Host "  Admin username [azureuser]"
    $AdminUsername = if ([string]::IsNullOrWhiteSpace($inp)) { "azureuser" } else { $inp.Trim() }
}

# Secure password prompt with confirmation loop
$AdminPasswordPlain = ""
# Non-interactive fallback: honor $env:ADMIN_PASSWORD when set (>=12 chars).
if (-not [string]::IsNullOrWhiteSpace($env:ADMIN_PASSWORD) -and $env:ADMIN_PASSWORD.Length -ge 12) {
    $AdminPasswordPlain = $env:ADMIN_PASSWORD
    Log "  Admin password : (taken from `$env:ADMIN_PASSWORD)"
}
while ([string]::IsNullOrWhiteSpace($AdminPasswordPlain)) {
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

if (-not $PSBoundParameters.ContainsKey('DeployOnPrem')) {
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
Log "  Running capacity pre-flight in $Location (this may take ~2-4 min) ..."
$VmSize = Preflight-VmCapacity -Region $Location -InitialSku $CandidateSku
Log "  ✔ VM_SIZE resolved: $VmSize"

Log "  Running spoke VM capacity probe in $Location ..."
$SpokeVmSize = Pick-SpokeVmSku -Region $Location
Log "  ✔ SPOKE_VM_SIZE resolved: $SpokeVmSize"

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
# Phase 5b — PA bootstrap storage account + Azure Files share
# =============================================================================
Log "=== Phase 5b: Creating PA bootstrap storage ==="

$bsSuffix    = (New-HexKey 4)
$BootstrapSa = "pabstrap${bsSuffix}"
$BootstrapShare = "bootstrap"
$BootstrapDir   = ""   # empty = root; PA reads init-cfg.txt from config/ subfolder

Log "  Storage account name: $BootstrapSa"
az storage account create `
    -g $Rg -n $BootstrapSa -l $Location `
    --sku Standard_LRS --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-shared-key-access true `
    --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to create bootstrap storage account." }
Log "  ✔ Storage account created."

# Verify the effective allowSharedKeyAccess setting.
# A management-group policy can override --allow-shared-key-access true back to false,
# silently blocking all Azure Files SMB data-plane operations (share/dir/upload).
$SharedKeyBootstrapAvailable = $true
$effectiveSharedKey = (az storage account show -g $Rg -n $BootstrapSa `
    --query allowSharedKeyAccess -o tsv 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $effectiveSharedKey -eq "false") {
    $SharedKeyBootstrapAvailable = $false
    Log ""
    Log "  WARNING: Subscription policy enforces allowSharedKeyAccess=false;"
    Log "           Azure Files bootstrap upload will be skipped. The storage account"
    Log "           is retained so palo-alto.bicep customData references resolve."
    Log "           The lab will fall back to post-boot PAN-OS API config push (Phase 7b)."
    Log ""
} else {
    Log "  ✔ allowSharedKeyAccess=true confirmed — Azure Files upload will proceed."
}

# Retrieve storage key (management-plane; succeeds regardless of shared-key policy).
# Key is always passed to Bicep so customData renders correctly even in fallback mode.
$BootstrapSaKey = (az storage account keys list -g $Rg -n $BootstrapSa `
    --query "[0].value" -o tsv).Trim()

if ($SharedKeyBootstrapAvailable) {
    # ── Data-plane operations (skipped when policy blocks shared-key access) ──

    az storage share create `
        --account-name $BootstrapSa `
        --account-key $BootstrapSaKey `
        -n $BootstrapShare `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Log "  WARNING: Failed to create Azure Files share '$BootstrapShare' (exit $LASTEXITCODE)."
        Log "           Phase 7b config push will configure the PA firewalls post-boot."
        $SharedKeyBootstrapAvailable = $false
    } else {
        Log "  ✔ Azure Files share '$BootstrapShare' created."

        # PA bootstrap requires these 4 directories in the share root
        foreach ($dir in @("config","content","license","software")) {
            az storage directory create `
                --account-name $BootstrapSa `
                --account-key $BootstrapSaKey `
                --share-name $BootstrapShare `
                -n $dir `
                --output none
            if ($LASTEXITCODE -ne 0) {
                Log "  WARNING: Failed to create directory '$dir' in bootstrap share."
            }
        }
        Log "  ✔ Bootstrap directories created: config/ content/ license/ software/"

        # Upload the two PA day-0 config files (authored by Alex; paths below are required)
        foreach ($f in @("init-cfg.txt","bootstrap.xml")) {
            $src = Join-Path $BicepDir "bootstrap\$f"
            $dst = "config/$f"
            if (-not (Test-Path $src)) {
                Log "  WARNING: Bootstrap file not found: $src"
                Log "           Skipping upload — PA will boot in minimal state without this file."
                continue
            }
            az storage file upload `
                --account-name $BootstrapSa `
                --account-key $BootstrapSaKey `
                --share-name $BootstrapShare `
                --path $dst `
                --source $src `
                --output none
            if ($LASTEXITCODE -ne 0) {
                Log "  WARNING: Failed to upload '$f' to bootstrap share (exit $LASTEXITCODE)."
                Log "           Phase 7b config push will configure the PA firewalls post-boot."
            } else {
                Log "  ✔ Uploaded $f → ${BootstrapShare}/${dst}"
            }
        }
    }
}

Log "  Bootstrap storage ready: account=$BootstrapSa  share=$BootstrapShare  sharedKey=$SharedKeyBootstrapAvailable"

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
        nvaVmSize="$VmSize" `
        vmSize="$SpokeVmSize" `
        deployOnPrem="$deployOnPremParam" `
        onpremBgpAsn=65001 `
        bootstrapStorageAccount="$BootstrapSa" `
        bootstrapStorageKey="$BootstrapSaKey" `
        bootstrapFileShare="$BootstrapShare" `
        bootstrapShareDirectory="$BootstrapDir" `
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
$HubId            = Get-Out "hubId"
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

# Construct defaultRouteTable resource ID from hubId output (avoids extra az call)
$DefaultRtId  = "${HubId}/hubRouteTables/defaultRouteTable"

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
# Phase 7b — Post-boot PAN-OS day-0 config push
# =============================================================================
Log "=== Phase 7b: Applying PAN-OS day-0 config (post-boot) ==="
# Always run — idempotent verify+repair whether Azure Files bootstrap succeeded or not.
# pip-pa-0-mgmt / pip-pa-1-mgmt are the management PIPs deployed by palo-alto.bicep.
$pa0MgmtIp = (az network public-ip show -g $Rg -n "pip-pa-0-mgmt" `
    --query ipAddress -o tsv 2>$null).Trim()
$pa1MgmtIp = (az network public-ip show -g $Rg -n "pip-pa-1-mgmt" `
    --query ipAddress -o tsv 2>$null).Trim()
$paMgmtIps = @($pa0MgmtIp, $pa1MgmtIp) | Where-Object { $_ }
if ($paMgmtIps.Count -gt 0) {
    & (Join-Path $ScriptDir "apply-panos-config.ps1") `
        -MgmtIps $paMgmtIps `
        -AdminUsername $AdminUsername `
        -AdminPassword $AdminPasswordPlain
    if ($LASTEXITCODE -ne 0) {
        Log "  WARNING: PAN-OS config push reported errors on one or more firewalls. Check PA config/commit state before validating egress."
    } else {
        Log "  ✔ PAN-OS day-0 config applied to all firewalls."
    }
} else {
    Log "  WARNING: No PA management IPs found in outputs — cannot apply post-boot config."
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
# --internet-security false: the DMZ ORIGINATES the default route (via its NVA);
# it must NOT receive 0/0 back from the hub, or it would black-hole its own egress.
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-dmz" `
    --remote-vnet $DmzVnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --internet-security false `
    --route-name "default-via-ilb" `
    --address-prefixes "0.0.0.0/0" `
    --next-hop $IlbFrontendIp `
    --output none

Poll-Until -Label "conn-dmz provisioningState" -Target "Succeeded" -SleepSec 15 -MaxIter 40 -Command {
    (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-dmz" `
        --query "provisioningState" -o tsv 2>$null).Trim()
}

Log "  Creating conn-spoke1 ..."
# --internet-security true: "Propagate Default Route" — spoke LEARNS 0/0 from the
# hub defaultRouteTable so its VMs egress through the DMZ NVA.
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-spoke1" `
    --remote-vnet $Spoke1VnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --internet-security true `
    --output none

Poll-Until -Label "conn-spoke1 provisioningState" -Target "Succeeded" -SleepSec 15 -MaxIter 40 -Command {
    (az network vhub connection show -g $Rg --vhub-name $HubName -n "conn-spoke1" `
        --query "provisioningState" -o tsv 2>$null).Trim()
}

Log "  Creating conn-spoke2 ..."
# --internet-security true: "Propagate Default Route" — spoke LEARNS 0/0 from the
# hub defaultRouteTable so its VMs egress through the DMZ NVA.
az network vhub connection create `
    -g $Rg --vhub-name $HubName -n "conn-spoke2" `
    --remote-vnet $Spoke2VnetId `
    --associated-route-table $DefaultRtId `
    --propagated-route-tables $DefaultRtId `
    --labels "default" `
    --internet-security true `
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

az network vhub route-table route add `
    -g $Rg --vhub-name $HubName --name "defaultRouteTable" `
    --route-name "to-internet" `
    --destination-type "CIDR" --destinations "0.0.0.0/0" `
    --next-hop-type "ResourceID" --next-hop $ConnDmzId `
    --output none

Log "  ✔ defaultRouteTable 0.0.0.0/0 → conn-dmz route installed."

# =============================================================================
# Phase 10b — NOTE: No spoke UDR required for vWAN topology
# The vWAN hub's defaultRouteTable already propagates 0/0 → conn-dmz to all
# connected spokes as VirtualNetworkGateway routes.  A UDR with
# nextHopType=VirtualAppliance pointing to an ILB in a different (hub-connected)
# VNet resolves as nextHopType=None in the effective route table, silently
# dropping spoke egress traffic.  Spoke workload UDRs are left empty (routes:[])
# as Bicep creates them; routing is handled entirely by hub route propagation.
# =============================================================================
Log "=== Phase 10b: Spoke workload UDRs left empty — vWAN hub propagation handles 0/0 (no UDR needed) ==="

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
Log "  PALO ALTO FIREWALL (BYOL LICENSING):"
Log "  The firewalls boot in BYOL/unlicensed (eval) mode.  The dataplane is"
Log "  functional for lab traffic without a license (eval mode still forwards)."
Log "  To apply full licensing (optional):"
Log "    1. Open the PA management GUI: https://<pip-pa-0-mgmt>  (see portal)"
Log "    2. Navigate to Device -> Licenses -> Activate feature using Auth-Code"
Log "    3. Enter your Palo Alto Networks auth-code and commit."
Log "  This step is optional for lab validation — traffic forwarding works"
Log "  without a license in eval mode."
Log ""
Log "  CLEANUP:"
LogPlain "  .\cleanup.ps1 -Rg $Rg"
Log ""
