<#
.SYNOPSIS
    Delete the GCP on-premises side of the ExpressRoute failover lab.

.DESCRIPTION
    Deletes in reverse dependency order:
      VLAN attachment -> Cloud NAT -> Cloud Router -> VM -> firewall -> subnet -> VPC

    IMPORTANT: delete the Megaport VXC that pairs with this attachment FIRST.
    Deleting the GCP attachment while the VXC is live leaves the Megaport side
    billing and stranded.

    WARNING - LAB ONLY. This deletes resources. There is no undo.

.PARAMETER Project
    GCP project ID. Falls back to $env:GCP_PROJECT, then `gcloud config`.

.PARAMETER Region
    GCP region. Default us-south1.

.PARAMETER Zone
    GCP zone. Defaults to "<Region>-a".

.PARAMETER NamePrefix
    Resource name prefix. Default 'erfo-onprem'.

.PARAMETER Yes
    Skip confirmation prompts.

.EXAMPLE
    .\gcp-cleanup.ps1 -Project my-project -Yes
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Region = 'us-south1',
    [string]$Zone,
    [string]$NamePrefix = 'erfo-onprem',
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'

function Log  { param($m) Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }
function Info { param($m) Write-Host "  $m" }
function Ok   { param($m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Skip { param($m) Write-Host "  [SKIP] $m" -ForegroundColor Cyan }

function Confirm-Step {
    param([string]$Prompt)
    if ($Yes) { return }
    $ans = Read-Host "$Prompt [y/N]"
    if ($ans -notmatch '^[Yy]$') { Write-Host 'Aborted.'; exit 0 }
}

function Invoke-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    $out = & gcloud --project=$script:GcpProject --quiet @GArgs 2>&1
    $script:GCloudExit = $LASTEXITCODE
    return $out
}

function Test-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GArgs)
    Invoke-GCloud @GArgs | Out-Null
    return ($script:GCloudExit -eq 0)
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
$Nat        = "$NamePrefix-nat"

Write-Host ''
Write-Host '================================================================'
Write-Host '  DELETE the GCP on-prem simulator - er-failover-dual-hub'
Write-Host '================================================================'
Info "Project : $Project"
Info "Region  : $Region / $Zone"
Info "Prefix  : $NamePrefix"
Write-Host '----------------------------------------------------------------'
Warn 'DELETE THE MEGAPORT VXC FIRST.'
Warn 'Removing the GCP attachment while the VXC is live leaves the'
Warn 'Megaport side stranded and still billing.'
Write-Host '----------------------------------------------------------------'
Write-Host 'Will delete, in order:'
Write-Host "  1. VLAN attachment  $Attachment"
Write-Host "  2. Cloud NAT        $Nat         (if present)"
Write-Host "  3. Cloud Router     $Router"
Write-Host "  4. VM               $Vm"
Write-Host "  5. Firewall rules   $FwInternal, $FwIap"
Write-Host "  6. Subnet           $Subnet"
Write-Host "  7. VPC network      $Network"
Write-Host '================================================================'
Write-Host ''
Confirm-Step 'Have you already deleted the Megaport VXC?'
Confirm-Step "Permanently delete all of the above from '$Project'?"

# ---------------------------------------------------------------------------
Log "1/7  VLAN attachment '$Attachment'..."
if (Test-GCloud compute interconnects attachments describe $Attachment --region=$Region) {
    Invoke-GCloud compute interconnects attachments delete $Attachment --region=$Region | Out-Null
    if ($script:GCloudExit -eq 0) { Ok 'attachment deleted (hourly billing stops now)' }
    else { Warn "failed to delete attachment $Attachment" }
} else {
    Skip "attachment $Attachment not found"
}

# ---------------------------------------------------------------------------
Log "2/7  Cloud NAT '$Nat'..."
if (Test-GCloud compute routers nats describe $Nat --router=$Router --region=$Region) {
    Invoke-GCloud compute routers nats delete $Nat --router=$Router --region=$Region | Out-Null
    if ($script:GCloudExit -eq 0) { Ok 'Cloud NAT deleted' }
    else { Warn "failed to delete Cloud NAT $Nat" }
} else {
    Skip "Cloud NAT $Nat not found"
}

# ---------------------------------------------------------------------------
Log "3/7  Cloud Router '$Router'..."
if (Test-GCloud compute routers describe $Router --region=$Region) {
    Invoke-GCloud compute routers delete $Router --region=$Region | Out-Null
    if ($script:GCloudExit -eq 0) { Ok 'router deleted' }
    else { Warn "failed to delete router $Router (is the attachment really gone?)" }
} else {
    Skip "router $Router not found"
}

# ---------------------------------------------------------------------------
Log "4/7  VM '$Vm'..."
if (Test-GCloud compute instances describe $Vm --zone=$Zone) {
    Invoke-GCloud compute instances delete $Vm --zone=$Zone | Out-Null
    if ($script:GCloudExit -eq 0) { Ok 'instance deleted (boot disk goes with it)' }
    else { Warn "failed to delete instance $Vm" }
} else {
    Skip "instance $Vm not found"
}

# ---------------------------------------------------------------------------
Log '5/7  Firewall rules...'
foreach ($rule in @($FwInternal, $FwIap)) {
    if (Test-GCloud compute firewall-rules describe $rule) {
        Invoke-GCloud compute firewall-rules delete $rule | Out-Null
        if ($script:GCloudExit -eq 0) { Ok "firewall $rule deleted" }
        else { Warn "failed to delete firewall $rule" }
    } else {
        Skip "firewall $rule not found"
    }
}

# ---------------------------------------------------------------------------
# Delete every subnet in the VPC, not just "$NamePrefix-subnet". A lab whose
# subnet was re-created under another name (e.g. "-subnet-v2" after a
# re-addressing) would otherwise leave an orphan that blocks the VPC delete.
Log '6/7  Subnets...'
$subnetNames = @((Invoke-GCloud compute networks subnets list `
        --filter="network:$Network AND region:$Region" --format='value(name)') |
    Where-Object { $_ })
if ($subnetNames.Count -eq 0) {
    Skip "no subnets found in VPC $Network / $Region"
} else {
    foreach ($s in $subnetNames) {
        Invoke-GCloud compute networks subnets delete $s --region=$Region | Out-Null
        if ($script:GCloudExit -eq 0) { Ok "subnet $s deleted" }
        else { Warn "failed to delete subnet $s" }
    }
}

# ---------------------------------------------------------------------------
Log "7/7  VPC network '$Network'..."
if (Test-GCloud compute networks describe $Network) {
    Invoke-GCloud compute networks delete $Network | Out-Null
    if ($script:GCloudExit -eq 0) { Ok 'network deleted' }
    else { Warn "failed to delete network $Network" }
} else {
    Skip "network $Network not found"
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Verification =='
$leftover = 0

$checks = @(
    @{ Label = "attachment $Attachment"; Args = @('compute','interconnects','attachments','describe',$Attachment,"--region=$Region") },
    @{ Label = "router $Router";         Args = @('compute','routers','describe',$Router,"--region=$Region") },
    @{ Label = "instance $Vm";           Args = @('compute','instances','describe',$Vm,"--zone=$Zone") },
    @{ Label = "subnet $Subnet";         Args = @('compute','networks','subnets','describe',$Subnet,"--region=$Region") },
    @{ Label = "network $Network";       Args = @('compute','networks','describe',$Network) }
)

foreach ($c in $checks) {
    if (Test-GCloud @($c.Args)) {
        Warn "$($c.Label) still exists"
        $leftover++
    } else {
        Ok "$($c.Label) gone"
    }
}

Write-Host ''
Write-Host '================================================================'
if ($leftover -eq 0) {
    Write-Host '  Cleanup complete. No GCP charges remain for this lab.' -ForegroundColor Green
} else {
    Write-Host "  $leftover resource(s) still present - re-run in a minute." -ForegroundColor Yellow
    Write-Host '  GCP deletes are eventually consistent; dependencies can lag.'
}
Write-Host '----------------------------------------------------------------'
Write-Host '  The Azure side is untouched. To remove it too:'
Write-Host '    .\cleanup.ps1 -ResourceGroup rg-er-failover-dual-hub'
Write-Host '================================================================'
