<#
.SYNOPSIS
    Verify the GCP on-premises side of the ExpressRoute failover lab.

.DESCRIPTION
    Read-only. Checks the VPC, subnet, firewall rules, VM, Cloud Router ASN and
    advertisement configuration, the Partner Interconnect attachment state, and
    the BGP session once Megaport has built the VXC.

    Exits 1 if any check fails.

.PARAMETER Project
    GCP project ID. Falls back to $env:GCP_PROJECT, then `gcloud config`.

.PARAMETER Region
    GCP region. Default us-south1.

.PARAMETER Zone
    GCP zone. Defaults to "<Region>-a".

.PARAMETER NamePrefix
    Resource name prefix. Default 'erfo-onprem'.

.PARAMETER AdvertiseRange
    Supernet expected in the router's custom advertisement. Default 10.0.0.0/8.

.EXAMPLE
    .\gcp-validate.ps1 -Project my-project
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region = 'us-south1',
    [string]$Zone,
    [string]$NamePrefix = 'erfo-onprem',
    [string]$AdvertiseRange = '10.0.0.0/8'
)

$ErrorActionPreference = 'Continue'
$script:Failures = 0

function Pass { param($m) Write-Host "  [PASS] $m" -ForegroundColor Green }
function Fail { param($m) Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Failures++ }
function Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Info { param($m) Write-Host "  [INFO] $m" -ForegroundColor Cyan }

function Invoke-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    $out = & gcloud --project=$script:GcpProject --quiet @GArgs 2>$null
    $script:GCloudExit = $LASTEXITCODE
    return (($out -join "`n").Trim())
}

function Test-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    Invoke-GCloud @GArgs | Out-Null
    return ($script:GCloudExit -eq 0)
}

function ConvertTo-UInt32Ip {
    param([string]$Ip)
    $o = $Ip.Split('.')
    return ([uint32]$o[0] -shl 24) -bor ([uint32]$o[1] -shl 16) -bor ([uint32]$o[2] -shl 8) -bor [uint32]$o[3]
}

# True when $Inner (CIDR) is fully contained inside $Outer (CIDR).
function Test-CidrContains {
    param([string]$Outer, [string]$Inner)
    if ($Outer -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$' -or $Inner -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { return $false }
    $oParts = $Outer.Split('/'); $iParts = $Inner.Split('/')
    $oLen = [int]$oParts[1]; $iLen = [int]$iParts[1]
    if ($iLen -lt $oLen) { return $false }
    $mask = if ($oLen -eq 0) { [uint32]0 } else { [uint32]((0xFFFFFFFFL -shl (32 - $oLen)) -band 0xFFFFFFFFL) }
    return ((ConvertTo-UInt32Ip $oParts[0]) -band $mask) -eq ((ConvertTo-UInt32Ip $iParts[0]) -band $mask)
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Host 'gcloud is required.' -ForegroundColor Red
    exit 1
}

if (-not $Zone) { $Zone = "$Region-a" }

if (-not $Project) { $Project = $env:GCP_PROJECT }
if (-not $Project) {
    $Project = (& gcloud config get-value project 2>$null)
    if ($Project -eq '(unset)') { $Project = $null }
}
if (-not $Project) {
    Write-Host 'GCP project ID is required (-Project or $env:GCP_PROJECT).' -ForegroundColor Red
    exit 1
}
$script:GcpProject = $Project

$Network    = $NamePrefix
$Subnet     = "$NamePrefix-subnet"
$FwInternal = "$NamePrefix-allow-internal"
$FwIap      = "$NamePrefix-allow-iap"
$Vm         = "$NamePrefix-vm"
$Router     = "$NamePrefix-router"
$Attachment = "$NamePrefix-attach"

Write-Host ''
Write-Host '================================================================'
Write-Host "  GCP on-prem validation - project $Project, region $Region"
Write-Host '================================================================'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Network =='

if (Test-GCloud compute networks describe $Network) {
    $mode = Invoke-GCloud compute networks describe $Network --format='value(routingConfig.routingMode)'
    Pass "VPC $Network exists (routing mode: $(if ($mode) { $mode } else { 'unknown' }))"
    if ($mode -ne 'GLOBAL') {
        Warn "routing mode is '$mode'; GLOBAL is recommended so all regions see interconnect routes"
    }
} else {
    Fail "VPC $Network not found"
}

if (Test-GCloud compute networks subnets describe $Subnet --region=$Region) {
    $range = Invoke-GCloud compute networks subnets describe $Subnet --region=$Region --format='value(ipCidrRange)'
    $pga   = Invoke-GCloud compute networks subnets describe $Subnet --region=$Region --format='value(privateIpGoogleAccess)'
    Pass "subnet $Subnet exists ($range)"
    if (Test-CidrContains $AdvertiseRange $range) {
        Pass "subnet $range is inside the advertised supernet $AdvertiseRange"
    } else {
        Fail "subnet $range is OUTSIDE the advertised supernet $AdvertiseRange - the supernet would carry no real on-prem hosts; re-run gcp-deploy with a contained -SubnetCidr"
    }
    if ($pga -match '^(True|true)$') {
        Pass 'Private Google Access enabled'
    } else {
        Warn 'Private Google Access disabled - the VM cannot reach Google APIs without a public IP or Cloud NAT'
    }
} else {
    Fail "subnet $Subnet not found in $Region"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Firewall =='

if (Test-GCloud compute firewall-rules describe $FwInternal) {
    Pass "firewall $FwInternal exists (RFC1918 ingress)"
} else {
    Fail "firewall $FwInternal not found - Azure traffic over ExpressRoute will be dropped"
}

if (Test-GCloud compute firewall-rules describe $FwIap) {
    $src = Invoke-GCloud compute firewall-rules describe $FwIap --format='value(sourceRanges.list())'
    if ($src -like '*35.235.240.0/20*') {
        Pass "firewall $FwIap allows the IAP range 35.235.240.0/20"
    } else {
        Fail "firewall $FwIap does not include 35.235.240.0/20 - IAP SSH will fail (source: $src)"
    }
} else {
    Fail "firewall $FwIap not found - the VM has no public IP, so IAP SSH is the only way in"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== VM =='

if (Test-GCloud compute instances describe $Vm --zone=$Zone) {
    $status = Invoke-GCloud compute instances describe $Vm --zone=$Zone --format='value(status)'
    $mtype  = Invoke-GCloud compute instances describe $Vm --zone=$Zone --format='value(machineType.basename())'
    $privip = Invoke-GCloud compute instances describe $Vm --zone=$Zone --format='value(networkInterfaces[0].networkIP)'
    $extip  = Invoke-GCloud compute instances describe $Vm --zone=$Zone --format='value(networkInterfaces[0].accessConfigs[0].natIP)'

    if ($status -eq 'RUNNING') {
        Pass "VM $Vm is RUNNING ($mtype, $privip)"
    } else {
        Warn "VM $Vm is $status - start it with: gcloud compute instances start $Vm --zone=$Zone"
    }

    if (-not $extip) {
        Pass 'VM has no external IP (cost control + no internet exposure)'
    } else {
        Fail "VM has an external IP ($extip) - expected none"
    }
} else {
    Fail "VM $Vm not found in $Zone"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Cloud Router =='

if (Test-GCloud compute routers describe $Router --region=$Region) {
    $asn        = Invoke-GCloud compute routers describe $Router --region=$Region --format='value(bgp.asn)'
    $advMode    = Invoke-GCloud compute routers describe $Router --region=$Region --format='value(bgp.advertiseMode)'
    $advGroups  = Invoke-GCloud compute routers describe $Router --region=$Region --format='value(bgp.advertisedGroups.list())'
    $advRanges  = Invoke-GCloud compute routers describe $Router --region=$Region --format='value(bgp.advertisedIpRanges[].range)'

    if ($asn -eq '16550') {
        Pass "router $Router ASN is 16550 (required for Partner Interconnect)"
    } else {
        Fail "router $Router ASN is '$asn' - Partner Interconnect requires 16550"
    }

    if ($advMode -eq 'CUSTOM') {
        Pass 'advertisement mode is CUSTOM'
    } else {
        Fail "advertisement mode is '$advMode' - expected CUSTOM so $AdvertiseRange is advertised"
    }

    if ($advGroups -like '*ALL_SUBNETS*') {
        Pass 'ALL_SUBNETS is advertised'
    } else {
        Fail "ALL_SUBNETS missing from advertised groups ('$advGroups') - the VPC subnet will not reach Azure"
    }

    if ($advRanges -like "*$AdvertiseRange*") {
        Pass "supernet $AdvertiseRange is advertised (the failover probe prefix)"
    } else {
        Fail "supernet $AdvertiseRange not advertised (found: $(if ($advRanges) { $advRanges } else { 'none' }))"
    }
} else {
    Fail "Cloud Router $Router not found in $Region"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Partner Interconnect attachment =='

if (Test-GCloud compute interconnects attachments describe $Attachment --region=$Region) {
    $state    = Invoke-GCloud compute interconnects attachments describe $Attachment --region=$Region --format='value(state)'
    $pkey     = Invoke-GCloud compute interconnects attachments describe $Attachment --region=$Region --format='value(pairingKey)'
    $vlan     = Invoke-GCloud compute interconnects attachments describe $Attachment --region=$Region --format='value(vlanTag8021q)'
    $cloudRtr = Invoke-GCloud compute interconnects attachments describe $Attachment --region=$Region --format='value(cloudRouterIpAddress)'
    $peerIp   = Invoke-GCloud compute interconnects attachments describe $Attachment --region=$Region --format='value(customerRouterIpAddress)'

    switch ($state) {
        'ACTIVE' {
            Pass "attachment $Attachment is ACTIVE (VLAN $vlan)"
            Info "GCP side $cloudRtr  <->  MCR side $peerIp"
        }
        'PENDING_CUSTOMER' {
            Warn 'attachment is PENDING_CUSTOMER - Megaport has built the VXC, activate it:'
            Info "gcloud compute interconnects attachments partner update $Attachment ``"
            Info "  --region=$Region --project=$Project --admin-enabled"
        }
        'PENDING_PARTNER' {
            Warn 'attachment is PENDING_PARTNER - waiting for Megaport to build the VXC'
            if ($pkey) { Info "pairing key: $pkey" }
        }
        'DEFUNCT' {
            Fail 'attachment is DEFUNCT - Megaport deleted its side. Recreate with gcp-deploy.ps1'
        }
        default {
            Warn "attachment state: $(if ($state) { $state } else { 'unknown' })"
        }
    }
} else {
    Fail "attachment $Attachment not found in $Region"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== BGP session =='

if (Test-GCloud compute routers describe $Router --region=$Region) {
    $bgpState = Invoke-GCloud compute routers get-status $Router --region=$Region --format='value(result.bgpPeerStatus[].state)'
    $learned  = Invoke-GCloud compute routers get-status $Router --region=$Region --format='value(result.bgpPeerStatus[].numLearnedRoutes)'

    if (-not $bgpState) {
        Warn 'no BGP peer yet - the peer is auto-created only after the attachment is ACTIVE'
    } elseif ($bgpState -like '*Established*' -or $bgpState -like '*UP*') {
        Pass "BGP session established (learned routes: $(if ($learned) { $learned } else { '0' }))"
        if ($learned -and $learned -ne '0') {
            Pass 'routes are being learned from the MCR / Azure side'
        } else {
            Warn "BGP is up but no routes learned - check the MCR's advertisement toward GCP"
        }
    } else {
        Fail "BGP peer state: $bgpState"
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Next steps =='
Info "SSH:  gcloud compute ssh $Vm --zone=$Zone --project=$Project --tunnel-through-iap"
Info 'Ping Azure spokes from the VM:  ping 10.10.0.4   # erfo-vm-wus2'
Info '                                ping 10.20.0.4   # erfo-vm-scus'
Info 'Failover procedure: docs/failover-tests.md'

Write-Host ''
Write-Host '================================================================'
if ($script:Failures -eq 0) {
    Write-Host '  All checks passed.' -ForegroundColor Green
    Write-Host '================================================================'
    exit 0
} else {
    Write-Host "  $($script:Failures) check(s) failed." -ForegroundColor Red
    Write-Host '================================================================'
    exit 1
}
