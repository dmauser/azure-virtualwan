<#
.SYNOPSIS
    Deploy the GCP "on-premises" side of the ExpressRoute failover lab.

.DESCRIPTION
    Builds a single-VM GCP environment plus a Partner Interconnect VLAN
    attachment. The attachment is cross-connected through a Megaport MCR to the
    existing Azure ExpressRoute circuit 'erfo-er-dallas', which lands on the
    Virtual WAN hub 'erfo-hub-scus'.

    The Cloud Router advertises ALL_SUBNETS plus a 10.0.0.0/8 supernet. That
    supernet is the failover probe: Azure normally learns it over the Dallas
    circuit, and should relearn it via hub-to-hub transit when that circuit
    drops.

    COST: the VLAN attachment bills hourly from creation, active or not.
    Run gcp-cleanup.ps1 when you are done. See docs/gcp-onprem.md.

    WARNING - LAB ONLY. Not for production use.

.PARAMETER Project
    GCP project ID. Falls back to $env:GCP_PROJECT, then `gcloud config`.

.PARAMETER Region
    GCP region. Default us-south1 (physically Dallas, adjacent to the Dallas
    ExpressRoute peering location).

.PARAMETER Zone
    GCP zone. Defaults to "<Region>-a".

.PARAMETER NamePrefix
    Prefix for every created resource. Default 'erfo-onprem'.

.PARAMETER SubnetCidr
    Subnet range for the on-prem VPC. Default 10.100.0.0/24.

    This MUST sit inside -AdvertiseRange. The Cloud Router advertises the
    supernet, so Azure installs a single route for it and forwards on-prem
    traffic accordingly; a subnet outside that supernet would be advertised
    only by ALL_SUBNETS and would not be covered by the prefix the failover
    test actually watches. 10.100.0.0/24 is inside 10.0.0.0/8 and does not
    collide with any Azure prefix in this lab (10.0.0.0/23, 10.1.0.0/23,
    10.10.0.0/24, 10.20.0.0/24).

.PARAMETER AdvertiseRange
    Supernet advertised to the MCR in addition to ALL_SUBNETS.
    Default 10.0.0.0/8. -SubnetCidr must be inside this range.

.PARAMETER Spot
    Use a Spot VM. Much cheaper, but can be preempted at any time.

.PARAMETER WithNat
    Also create Cloud NAT so the VM has internet egress for package installs.
    Adds an hourly charge.

.PARAMETER Yes
    Skip confirmation prompts.

.EXAMPLE
    .\gcp-deploy.ps1 -Project my-project -Yes

.EXAMPLE
    .\gcp-deploy.ps1 -Project my-project -Spot -WithNat
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region = 'us-south1',
    [string]$Zone,
    [string]$NamePrefix = 'erfo-onprem',
    [string]$SubnetCidr = '10.100.0.0/24',
    [string]$AdvertiseRange = '10.0.0.0/8',
    [switch]$Spot,
    [switch]$WithNat,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Log  { param($m) Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }
function Info { param($m) Write-Host "  $m" }
function Ok   { param($m) Write-Host "  [OK]   $m"   -ForegroundColor Green }
function Warn { param($m) Write-Host "  [WARN] $m"   -ForegroundColor Yellow }
function Skip { param($m) Write-Host "  [SKIP] $m"   -ForegroundColor Cyan }
function Fail { param($m) Write-Host "  [FAIL] $m"   -ForegroundColor Red
    if ($script:GCloudOut) {
        Write-Host '  ---- gcloud output ----' -ForegroundColor Red
        $script:GCloudOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    exit 1 }

function Confirm-Step {
    param([string]$Prompt)
    if ($Yes) { return }
    $ans = Read-Host "$Prompt [y/N]"
    if ($ans -notmatch '^[Yy]$') { Write-Host 'Aborted.'; exit 0 }
}

# gcloud writes progress to stderr; with $ErrorActionPreference='Stop' that can
# surface as a terminating error. Route every call through this wrapper.
function Invoke-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & gcloud --project=$script:GcpProject --quiet @GArgs 2>&1
        $script:GCloudExit = $LASTEXITCODE
        $script:GCloudOut  = $out
        return $out
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Returns $true when the resource exists (describe succeeds).
function Test-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    Invoke-GCloud @GArgs | Out-Null
    return ($script:GCloudExit -eq 0)
}

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host '[prereq] Missing required tool: gcloud' -ForegroundColor Red
    Write-Host '  - Google Cloud SDK: https://cloud.google.com/sdk/docs/install'
    exit 1
}

if (-not $Zone) { $Zone = "$Region-a" }

# ---------------------------------------------------------------------------
# Derived resource names
# ---------------------------------------------------------------------------
$Network     = $NamePrefix
$Subnet      = "$NamePrefix-subnet"
$FwInternal  = "$NamePrefix-allow-internal"
$FwIap       = "$NamePrefix-allow-iap"
$Vm          = "$NamePrefix-vm"
$Router      = "$NamePrefix-router"
$Attachment  = "$NamePrefix-attach"
$Nat         = "$NamePrefix-nat"
$Tag         = $NamePrefix
$MachineType = 'e2-micro'

# VM private IP = .10 of the subnet
$octets = ($SubnetCidr -split '/')[0] -split '\.'
$VmIp   = "$($octets[0]).$($octets[1]).$($octets[2]).10"

# ---------------------------------------------------------------------------
# Guard: the on-prem subnet MUST sit inside the advertised supernet.
#
# The Cloud Router advertises $AdvertiseRange to the MCR, and that is the
# prefix the failover test watches swinging between circuits. If the subnet
# lives outside it, the supernet advertises address space nobody owns while
# the real host prefix rides along separately - which is exactly the bug this
# lab hit with the original 192.168.100.0/24 subnet.
# ---------------------------------------------------------------------------
function ConvertTo-UInt32Ip {
    param([string]$Ip)
    $b = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()
    [array]::Reverse($b)
    return [System.BitConverter]::ToUInt32($b, 0)
}

function Test-CidrContains {
    param([string]$Outer, [string]$Inner)
    $oParts = $Outer -split '/'; $iParts = $Inner -split '/'
    $oLen = [int]$oParts[1];     $iLen = [int]$iParts[1]
    if ($iLen -lt $oLen) { return $false }
    $mask = if ($oLen -eq 0) { [uint32]0 } else { [uint32]((0xFFFFFFFFL -shl (32 - $oLen)) -band 0xFFFFFFFFL) }
    return ((ConvertTo-UInt32Ip $oParts[0]) -band $mask) -eq ((ConvertTo-UInt32Ip $iParts[0]) -band $mask)
}

if (-not (Test-CidrContains -Outer $AdvertiseRange -Inner $SubnetCidr)) {
    Write-Host "  [FAIL] -SubnetCidr $SubnetCidr is not inside -AdvertiseRange $AdvertiseRange." -ForegroundColor Red
    Write-Host '         The advertised supernet must contain the on-prem subnet.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
Log 'Checking gcloud authentication...'
$activeAccount = (& gcloud config get-value account 2>$null)
if (-not $activeAccount -or $activeAccount -eq '(unset)') {
    Warn 'No active gcloud account. Running: gcloud auth login'
    & gcloud auth login
    $activeAccount = (& gcloud config get-value account 2>$null)
}
Ok "Active account: $activeAccount"

# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------
if (-not $Project) { $Project = $env:GCP_PROJECT }
if (-not $Project) {
    $Project = (& gcloud config get-value project 2>$null)
    if ($Project -eq '(unset)') { $Project = $null }
}
if (-not $Project -and -not $Yes) {
    $Project = Read-Host 'Enter your GCP Project ID'
}
if (-not $Project) { Fail 'GCP project ID is required (-Project or $env:GCP_PROJECT).' }
$script:GcpProject = $Project

$spotText = if ($Spot)    { 'yes' } else { 'no' }
$natText  = if ($WithNat) { 'yes (adds hourly cost)' } else { 'no' }

Write-Host ''
Write-Host '================================================================'
Write-Host '  GCP on-premises simulator - er-failover-dual-hub'
Write-Host '================================================================'
Info "Project           : $Project"
Info "Region / zone     : $Region / $Zone"
Info "VPC / subnet      : $Network / $SubnetCidr"
Info "VM                : $Vm @ $VmIp ($MachineType, no public IP)"
Info 'Cloud Router ASN  : 16550 (forced by GCP for Partner Interconnect)'
Info "Advertising       : ALL_SUBNETS + $AdvertiseRange"
Info "Attachment        : $Attachment (PARTNER, availability-domain-1)"
Info "Spot VM           : $spotText"
Info "Cloud NAT         : $natText"
Write-Host '----------------------------------------------------------------'
Warn 'The VLAN attachment bills hourly from creation, active or not.'
Warn 'Run gcp-cleanup.ps1 when finished. See docs/gcp-onprem.md.'
Write-Host '================================================================'
Write-Host ''
Confirm-Step "Deploy to GCP project '$Project'?"

# ---------------------------------------------------------------------------
# Enable APIs
# ---------------------------------------------------------------------------
Log 'Enabling compute.googleapis.com (no-op if already enabled)...'
Invoke-GCloud services enable compute.googleapis.com | Out-Null
if ($script:GCloudExit -ne 0) { Fail 'Could not enable the compute API.' }
Ok 'compute API enabled'

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
Log "VPC network '$Network'..."
if (Test-GCloud compute networks describe $Network) {
    Skip "network $Network already exists"
} else {
    Invoke-GCloud compute networks create $Network `
        --subnet-mode=custom `
        --bgp-routing-mode=global `
        --mtu=1460 `
        --description='on-prem simulator for er-failover-dual-hub' | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create network $Network" }
    Ok "network $Network created (global routing)"
}

# ---------------------------------------------------------------------------
# Subnet
#
# Reuse whatever subnet already exists in the VPC rather than keying off the
# derived name, so a lab re-addressed into "-subnet-v2" is not given a second,
# conflicting subnet on re-run.
# ---------------------------------------------------------------------------
$existingSubnets = @((Invoke-GCloud compute networks subnets list `
        --filter="network:$Network AND region:$Region" --format='value(name)') |
    Where-Object { $_ })
Log "Subnet '$Subnet' ($SubnetCidr)..."
if ($existingSubnets.Count -gt 0) {
    if ($existingSubnets -notcontains $Subnet) { $Subnet = $existingSubnets[0] }
    $existingCidr = Invoke-GCloud compute networks subnets describe $Subnet --region=$Region --format='value(ipCidrRange)'
    Skip "subnet $Subnet already exists ($existingCidr)"
    if ($existingCidr -and $existingCidr -ne $SubnetCidr) {
        Warn "existing subnet is $existingCidr, not the requested $SubnetCidr. A subnet's primary range cannot be renumbered in place - create a new subnet in the same VPC, move the VM, then delete the old one."
        $exOctets = ($existingCidr -split '/')[0] -split '\.'
        $VmIp     = "$($exOctets[0]).$($exOctets[1]).$($exOctets[2]).10"
        Info "VM IP adjusted to $VmIp to match the existing subnet"
    }
} else {
    # Private Google Access is free and lets the VM reach Google APIs without a
    # public IP or Cloud NAT.
    Invoke-GCloud compute networks subnets create $Subnet `
        --network=$Network `
        --region=$Region `
        --range=$SubnetCidr `
        --enable-private-ip-google-access | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create subnet $Subnet" }
    Ok "subnet $Subnet created"
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
Log "Firewall rule '$FwInternal' (RFC1918 ingress)..."
if (Test-GCloud compute firewall-rules describe $FwInternal) {
    Skip "firewall $FwInternal already exists"
} else {
    Invoke-GCloud compute firewall-rules create $FwInternal `
        --network=$Network `
        --direction=INGRESS `
        --action=ALLOW `
        --rules="tcp,udp,icmp" `
        --source-ranges="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" `
        --target-tags=$Tag `
        --description='allow RFC1918 (Azure spokes/hubs arrive over ExpressRoute)' | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create firewall $FwInternal" }
    Ok "firewall $FwInternal created"
}

Log "Firewall rule '$FwIap' (IAP SSH)..."
if (Test-GCloud compute firewall-rules describe $FwIap) {
    Skip "firewall $FwIap already exists"
} else {
    # 35.235.240.0/20 is the fixed IAP TCP-forwarding range - required because
    # the VM has no public IP.
    Invoke-GCloud compute firewall-rules create $FwIap `
        --network=$Network `
        --direction=INGRESS `
        --action=ALLOW `
        --rules="tcp:22" `
        --source-ranges="35.235.240.0/20" `
        --target-tags=$Tag `
        --description='allow SSH from Identity-Aware Proxy' | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create firewall $FwIap" }
    Ok "firewall $FwIap created"
}

# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------
Log "VM '$Vm' ($MachineType, no public IP)..."
if (Test-GCloud compute instances describe $Vm --zone=$Zone) {
    Skip "instance $Vm already exists"
} else {
    # Best-effort tooling. Without Cloud NAT this VM has no internet egress, so
    # these installs are expected to fail - that is intentional (cost control).
    # Ubuntu 22.04 already ships ping, ip, ss and nc, which cover the lab tests.
    $startup = @'
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-onprem.conf
DEBIAN_FRONTEND=noninteractive apt-get update -y || true
DEBIAN_FRONTEND=noninteractive apt-get install -y traceroute tcpdump mtr-tiny dnsutils || true
echo "erfo on-prem simulator ready" > /etc/motd
'@

    $startupFile = Join-Path ([IO.Path]::GetTempPath()) "erfo-startup-$PID.sh"
    [IO.File]::WriteAllText($startupFile, ($startup -replace "`r`n", "`n"))

    $vmArgs = @(
        'compute', 'instances', 'create', $Vm,
        "--zone=$Zone",
        "--machine-type=$MachineType",
        '--image-family=ubuntu-2204-lts',
        '--image-project=ubuntu-os-cloud',
        '--boot-disk-size=10GB',
        '--boot-disk-type=pd-standard',
        "--subnet=$Subnet",
        "--private-network-ip=$VmIp",
        '--no-address',
        "--tags=$Tag",
        "--metadata-from-file=startup-script=$startupFile",
        '--labels=lab=er-failover-dual-hub'
    )
    if ($Spot) {
        $vmArgs += '--provisioning-model=SPOT'
        $vmArgs += '--instance-termination-action=STOP'
    }

    Invoke-GCloud @vmArgs | Out-Null
    Remove-Item $startupFile -ErrorAction SilentlyContinue
    if ($script:GCloudExit -ne 0) { Fail "Failed to create instance $Vm" }
    Ok "instance $Vm created at $VmIp"
}

# ---------------------------------------------------------------------------
# Cloud Router
# ---------------------------------------------------------------------------
Log "Cloud Router '$Router' (ASN 16550)..."
if (Test-GCloud compute routers describe $Router --region=$Region) {
    Skip "router $Router already exists"
} else {
    # Partner Interconnect requires ASN 16550. Any other value is rejected.
    Invoke-GCloud compute routers create $Router `
        --network=$Network `
        --region=$Region `
        --asn=16550 `
        --description='on-prem simulator router for er-failover-dual-hub' | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create router $Router" }
    Ok "router $Router created"
}

# ---------------------------------------------------------------------------
# Route advertisement
#
# Set at ROUTER scope, not per-BGP-peer: the peer is auto-created only after
# Megaport activates the VXC, so a peer-scoped setting would have nothing to
# attach to at deploy time. CUSTOM mode replaces the default advertisement, so
# ALL_SUBNETS must be listed alongside the supernet.
# ---------------------------------------------------------------------------
Log "Advertising ALL_SUBNETS + $AdvertiseRange ..."
Invoke-GCloud compute routers update $Router `
    --region=$Region `
    --advertisement-mode=CUSTOM `
    --set-advertisement-groups="ALL_SUBNETS" `
    --set-advertisement-ranges="$AdvertiseRange" | Out-Null
if ($script:GCloudExit -ne 0) { Fail 'Failed to configure custom advertisement' }
Ok 'custom advertisement configured'

# ---------------------------------------------------------------------------
# Cloud NAT (optional)
# ---------------------------------------------------------------------------
if ($WithNat) {
    Log "Cloud NAT '$Nat'..."
    if (Test-GCloud compute routers nats describe $Nat --router=$Router --region=$Region) {
        Skip "Cloud NAT $Nat already exists"
    } else {
        Invoke-GCloud compute routers nats create $Nat `
            --router=$Router `
            --region=$Region `
            --auto-allocate-nat-external-ips `
            --nat-all-subnet-ip-ranges | Out-Null
        if ($script:GCloudExit -ne 0) { Fail "Failed to create Cloud NAT $Nat" }
        Ok "Cloud NAT $Nat created (billed hourly - delete when done)"
    }
}

# ---------------------------------------------------------------------------
# Partner VLAN attachment
# ---------------------------------------------------------------------------
Log "Partner VLAN attachment '$Attachment'..."
if (Test-GCloud compute interconnects attachments describe $Attachment --region=$Region) {
    Skip "attachment $Attachment already exists"
} else {
    Invoke-GCloud compute interconnects attachments partner create $Attachment `
        --region=$Region `
        --router=$Router `
        --edge-availability-domain=availability-domain-1 `
        --description='er-failover-dual-hub on-prem -> Megaport MCR -> erfo-er-dallas' | Out-Null
    if ($script:GCloudExit -ne 0) { Fail "Failed to create attachment $Attachment" }
    Ok "attachment $Attachment created"
}

# ---------------------------------------------------------------------------
# Wait for the pairing key
# ---------------------------------------------------------------------------
Log 'Waiting for the pairing key to be issued...'
$pairingKey = ''
for ($i = 1; $i -le 30; $i++) {
    $pairingKey = (Invoke-GCloud compute interconnects attachments describe $Attachment `
        --region=$Region --format='value(pairingKey)') -join ''
    if ($script:GCloudExit -eq 0 -and $pairingKey.Trim()) { $pairingKey = $pairingKey.Trim(); break }
    $pairingKey = ''
    Info "  (attempt $i/30) not yet available, retrying in 10s..."
    Start-Sleep -Seconds 10
}

$state = (Invoke-GCloud compute interconnects attachments describe $Attachment `
    --region=$Region --format='value(state)') -join ''
if ($script:GCloudExit -ne 0 -or -not $state.Trim()) { $state = 'UNKNOWN' } else { $state = $state.Trim() }

Write-Host ''
Write-Host '================================================================'
Write-Host '  PARTNER INTERCONNECT - PAIRING KEY'
Write-Host '================================================================'
if ($pairingKey) {
    Write-Host "  $pairingKey" -ForegroundColor Green
} else {
    Warn 'Pairing key not issued yet. Re-run gcp-validate.ps1 in a few minutes.'
}
Write-Host '----------------------------------------------------------------'
Write-Host "  Attachment state : $state"
Write-Host '================================================================'
Write-Host ''
Write-Host 'Next steps (Megaport portal):'
Write-Host '  1. Create / reuse an MCR in the Dallas metro.'
Write-Host '  2. VXC #1: MCR -> Google Cloud Partner Interconnect.'
Write-Host "       Paste the pairing key above. Pick region $Region."
Write-Host '       MCR peers BGP with GCP using ASN 16550.'
Write-Host '  3. VXC #2: MCR -> Azure ExpressRoute, service key'
Write-Host '       36186b16-fbf2-43f7-8fc3-76e1c7873e9b  (erfo-er-dallas)'
Write-Host '       MCR peers BGP with Azure using ASN 65001. Megaport assigns'
Write-Host '       the VLAN and both /30s and creates AzurePrivatePeering on'
Write-Host '       the circuit. Do NOT set the peering from Azure.'
Write-Host '  4. When Megaport finishes, the attachment moves to PENDING_CUSTOMER.'
Write-Host '     Activate it:'
Write-Host "       gcloud compute interconnects attachments partner update $Attachment ``"
Write-Host "         --region=$Region --project=$Project --admin-enabled"
Write-Host "  5. Verify with: .\gcp-validate.ps1 -Project $Project -Region $Region"
Write-Host ''
Write-Host 'SSH to the VM (no public IP - uses Identity-Aware Proxy):'
Write-Host "  gcloud compute ssh $Vm --zone=$Zone --project=$Project --tunnel-through-iap"
Write-Host ''
Write-Host "Cost: the VM is $MachineType on a 10 GB pd-standard disk (~`$0.20/day)."
Write-Host '  Stop it between test runs:'
Write-Host "    gcloud compute instances stop $Vm --zone=$Zone --project=$Project"
Write-Host "  Stopping the VM does NOT stop the VLAN attachment's hourly charge."
Write-Host '  Only gcp-cleanup.ps1 does.'
Write-Host ''
Write-Host 'Megaport is Layer 2 - it cannot bridge GCP to Azure with a single VXC.'
Write-Host 'An MCR (or physical port) must terminate BGP on both sides.'
Write-Host 'See docs/gcp-onprem.md.'
