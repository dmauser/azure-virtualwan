<#
.SYNOPSIS
    Dump the routing table from every point in the ExpressRoute failover lab.

.DESCRIPTION
    Read-only. Collects, for review in one place:

      1. ExpressRoute  - private peering config, BGP neighbour summary, learned
                         routes (primary + secondary path) and ARP tables for
                         both circuits.
      2. Virtual hubs  - effective routes on each hub's defaultRouteTable, plus
                         effective routes per ExpressRoute connection and per
                         spoke VNet connection.
      3. Azure VMs     - the in-guest kernel route table, pulled through
                         `az vm run-command` because the VMs deliberately have
                         no public IP.
      4. GCP           - Cloud Router BGP status (session state, advertised and
                         learned routes), VPC effective routes, the Partner
                         Interconnect attachment, and the on-prem VM's kernel
                         route table via IAP.

    Everything is written to a timestamped folder as individual .json / .txt
    files AND summarised to the console, so the dump can be diffed between a
    steady-state run and a failover run.

    Nothing is modified. Safe to run at any time.

.PARAMETER ResourceGroup
    Azure resource group holding the lab. Required.

.PARAMETER Prefix
    Azure resource name prefix. Default 'erfo'.

.PARAMETER OutputDir
    Where to write the dump. Default .\route-dumps\<UTC timestamp>.

.PARAMETER Label
    Optional tag folded into the folder name, e.g. 'before-failover'.

.PARAMETER GcpProject
    GCP project ID. Falls back to $env:GCP_PROJECT then `gcloud config`.

.PARAMETER GcpRegion
    GCP region. Default us-south1.

.PARAMETER GcpNamePrefix
    GCP resource name prefix. Default 'erfo-onprem'.

.PARAMETER SkipVms
    Skip the in-guest route dumps. These are the slow part (run-command takes
    roughly 30-60s per VM) so this is useful for a quick control-plane-only look.

.PARAMETER SkipGcp
    Skip the GCP section entirely.

.EXAMPLE
    .\dump-routes.ps1 -ResourceGroup rg-er-failover-dual-hub -Label before-failover

.EXAMPLE
    .\dump-routes.ps1 -ResourceGroup rg-er-failover-dual-hub -SkipVms -SkipGcp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResourceGroup,
    [string]$Prefix = 'erfo',
    [string]$OutputDir,
    [string]$Label,
    [string]$GcpProject,
    [string]$GcpRegion = 'us-south1',
    [string]$GcpNamePrefix = 'erfo-onprem',
    [switch]$SkipVms,
    [switch]$SkipGcp
)

$ErrorActionPreference = 'Continue'

# --------------------------------------------------------------------------
# Azure CLI preflight
#
# Some machines carry a corrupt Azure CLI extension cache where a *.dist-info
# entry is a directory rather than a wheel file. Every `az` invocation then dies
# with "PermissionError: [WinError 5] Access is denied" while loading the
# command table, which looks exactly like "resource not found" to this script.
# Extensions are not needed here, so fall back to an empty extension directory.
# --------------------------------------------------------------------------
$null = & az account show -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    $fallback = Join-Path ([System.IO.Path]::GetTempPath()) 'azext-empty'
    $null = New-Item -ItemType Directory -Force -Path $fallback
    $env:AZURE_EXTENSION_DIR = $fallback
    $null = & az account show -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Azure CLI is not usable - run 'az login' and retry." -ForegroundColor Red
        exit 1
    }
    Write-Host "note: azure cli extension cache was unreadable; using $fallback" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Output location
# --------------------------------------------------------------------------
if (-not $OutputDir) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $leaf  = if ($Label) { "$stamp-$Label" } else { $stamp }
    $OutputDir = Join-Path (Join-Path $PSScriptRoot '..\route-dumps') $leaf
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$OutputDir = (Resolve-Path $OutputDir).Path
$Report = Join-Path $OutputDir 'report.txt'

function Head {
    param($Text)
    $line = '=' * 74
    Write-Host ''
    Write-Host $line -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor DarkCyan
    Add-Content $Report "`n$line`n  $Text`n$line"
}

function Sub  { param($Text) Write-Host "`n-- $Text" -ForegroundColor Yellow; Add-Content $Report "`n-- $Text" }
function Note { param($Text) Write-Host "   $Text" -ForegroundColor DarkGray; Add-Content $Report "   $Text" }
function Warn { param($Text) Write-Host "   [warn] $Text" -ForegroundColor Red; Add-Content $Report "   [warn] $Text" }

# Emit a table to console + report, and stash the raw payload as JSON.
function Emit {
    param($Object, [string]$File, [string[]]$Columns)
    if ($File) { $Object | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir $File) }
    if (-not $Object) { Note '(none)'; return }
    $text = if ($Columns) { $Object | Format-Table $Columns -AutoSize | Out-String }
            else          { $Object | Format-Table -AutoSize | Out-String }
    $text = $text.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($text)) { Note '(none)'; return }
    Write-Host $text
    Add-Content $Report $text
}

# Run an az command that returns JSON; $null on any failure.
function AzJson {
    param([string[]]$AzArgs)
    $raw = & az @AzArgs -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

Set-Content $Report "ExpressRoute failover lab - route dump"
Add-Content $Report "generated : $((Get-Date).ToUniversalTime().ToString('u'))"
Add-Content $Report "rg        : $ResourceGroup"
Add-Content $Report "prefix    : $Prefix"

Write-Host "Writing dump to $OutputDir" -ForegroundColor Green

$circuits   = @("$Prefix-er-chicago", "$Prefix-er-dallas")
$hubKeys    = @('wus2', 'scus')
$circuitFor = @{ wus2 = 'chicago'; scus = 'dallas' }

# ==========================================================================
# 1. ExpressRoute
# ==========================================================================
Head 'EXPRESSROUTE CIRCUITS'

foreach ($ckt in $circuits) {
    Sub "$ckt - circuit state"
    $c = AzJson @('network','express-route','show','-g',$ResourceGroup,'-n',$ckt)
    if (-not $c) { Warn "circuit $ckt not found"; continue }
    Emit ([pscustomobject]@{
        name         = $c.name
        location     = $c.location
        provisioning = $c.provisioningState
        provider     = $c.serviceProviderProperties.serviceProviderName
        peeringLoc   = $c.serviceProviderProperties.peeringLocation
        bandwidthMbps= $c.serviceProviderProperties.bandwidthInMbps
        providerState= $c.serviceProviderProvisioningState
        sku          = $c.sku.name
    }) "er-$ckt-circuit.json"

    Sub "$ckt - private peering configuration"
    $p = AzJson @('network','express-route','peering','show','-g',$ResourceGroup,'--circuit-name',$ckt,'-n','AzurePrivatePeering')
    if ($p) {
        Emit ([pscustomobject]@{
            peerASN   = $p.peerASN
            vlanId    = $p.vlanId
            primary   = $p.primaryPeerAddressPrefix
            secondary = $p.secondaryPeerAddressPrefix
            azureASN  = $p.azureASN
            state     = $p.provisioningState
        }) "er-$ckt-peering.json"
    }
    else {
        Warn 'AzurePrivatePeering not present - the provider has not built it yet'
        continue
    }

    foreach ($path in @('primary', 'secondary')) {
        Sub "$ckt - BGP neighbours ($path)"
        $s = AzJson @('network','express-route','list-route-tables-summary','-g',$ResourceGroup,'-n',$ckt,'--peering-name','AzurePrivatePeering','--path',$path)
        Emit $s.value "er-$ckt-bgp-$path.json" @('neighbor','as','upDown','statePfxRcd','v')

        Sub "$ckt - learned routes ($path)"
        $r = AzJson @('network','express-route','list-route-tables','-g',$ResourceGroup,'-n',$ckt,'--peering-name','AzurePrivatePeering','--path',$path)
        Emit $r.value "er-$ckt-routes-$path.json" @('network','nextHop','path','locPrf','weight')

        Sub "$ckt - ARP ($path)"
        $a = AzJson @('network','express-route','list-arp-tables','-g',$ResourceGroup,'-n',$ckt,'--peering-name','AzurePrivatePeering','--path',$path)
        Emit $a.value "er-$ckt-arp-$path.json" @('ipAddress','macAddress','interface','age')
    }
}

# ==========================================================================
# 2. Virtual hubs
# ==========================================================================
Head 'VIRTUAL HUB EFFECTIVE ROUTES'

foreach ($key in $hubKeys) {
    $hub = "$Prefix-hub-$key"
    $h = AzJson @('network','vhub','show','-g',$ResourceGroup,'-n',$hub)
    if (-not $h) { Warn "hub $hub not found"; continue }

    Sub "$hub - hub properties"
    Emit ([pscustomobject]@{
        name        = $h.name
        location    = $h.location
        addressSpace= $h.addressPrefix
        routingPref = $h.hubRoutingPreference
        state       = $h.provisioningState
        routerAsn   = $h.virtualRouterAsn
        routerIps   = ($h.virtualRouterIps -join ', ')
    }) "hub-$key-properties.json"

    # Hub default route table
    $rtId = "$($h.id)/hubRouteTables/defaultRouteTable"
    Sub "$hub - defaultRouteTable effective routes"
    $eff = AzJson @('network','vhub','get-effective-routes','-g',$ResourceGroup,'-n',$hub,'--resource-type','RouteTable','--resource-id',$rtId)
    $rows = $eff.value | ForEach-Object {
        [pscustomobject]@{
            prefix     = ($_.addressPrefixes -join ',')
            nextHopType= $_.nextHopType
            nextHop    = ($_.nextHops -join ',')
            asPath     = $_.asPath
            origin     = $_.routeOrigin
        }
    }
    Emit $rows "hub-$key-routetable.json" @('prefix','nextHopType','nextHop','asPath','origin')

    # ExpressRoute connection
    $gw     = "$Prefix-hub-$key-ergw"
    $erconn = "$Prefix-erconn-$($circuitFor[$key])"
    $ec = AzJson @('network','express-route','gateway','connection','show','--gateway-name',$gw,'-g',$ResourceGroup,'-n',$erconn)
    if ($ec) {
        Sub "$hub - effective routes on ER connection $erconn"
        $eff2 = AzJson @('network','vhub','get-effective-routes','-g',$ResourceGroup,'-n',$hub,'--resource-type','ExpressRouteConnection','--resource-id',$ec.id)
        $rows2 = $eff2.value | ForEach-Object {
            [pscustomobject]@{
                prefix     = ($_.addressPrefixes -join ',')
                nextHopType= $_.nextHopType
                nextHop    = ($_.nextHops -join ',')
                asPath     = $_.asPath
                origin     = $_.routeOrigin
            }
        }
        Emit $rows2 "hub-$key-erconn-routes.json" @('prefix','nextHopType','nextHop','asPath','origin')
    }
    else { Warn "ER connection $erconn not found" }

    # Spoke VNet connection
    $vconn = "$Prefix-spoke-$key-conn"
    $vc = AzJson @('network','vhub','connection','show','--vhub-name',$hub,'-g',$ResourceGroup,'-n',$vconn)
    if ($vc) {
        Sub "$hub - effective routes on VNet connection $vconn"
        $eff3 = AzJson @('network','vhub','get-effective-routes','-g',$ResourceGroup,'-n',$hub,'--resource-type','HubVirtualNetworkConnection','--resource-id',$vc.id)
        $rows3 = $eff3.value | ForEach-Object {
            [pscustomobject]@{
                prefix     = ($_.addressPrefixes -join ',')
                nextHopType= $_.nextHopType
                nextHop    = ($_.nextHops -join ',')
                asPath     = $_.asPath
                origin     = $_.routeOrigin
            }
        }
        Emit $rows3 "hub-$key-vnetconn-routes.json" @('prefix','nextHopType','nextHop','asPath','origin')
    }
    else { Warn "VNet connection $vconn not found" }
}

# ==========================================================================
# 3. Azure VMs - NIC effective routes + in-guest kernel table
# ==========================================================================
Head 'AZURE VM ROUTES'

# Probe script handed to `az vm run-command` as a file (see the --scripts call
# below for why an inline string does not survive the CLI's argument parsing).
$GuestProbe = Join-Path ([System.IO.Path]::GetTempPath()) "erfo-guest-probe-$PID.sh"
@'
echo "### ip -4 route show"
ip -4 route show
echo
echo "### default route"
ip -4 route get 8.8.8.8 2>/dev/null
echo
echo "### addresses"
ip -4 -br addr
echo
echo "### neighbours"
ip -4 neigh
'@ -replace "`r`n", "`n" | Set-Content -LiteralPath $GuestProbe -NoNewline -Encoding ascii

foreach ($key in $hubKeys) {
    $vm  = "$Prefix-vm-$key"
    $nic = "nic-$vm"

    Sub "$vm - NIC effective routes (platform view)"
    $nr = AzJson @('network','nic','show-effective-route-table','-g',$ResourceGroup,'-n',$nic)
    if ($nr) {
        $rows = $nr.value | ForEach-Object {
            [pscustomobject]@{
                source     = $_.source
                state      = $_.state
                prefix     = ($_.addressPrefix -join ',')
                nextHopType= $_.nextHopType
                nextHop    = ($_.nextHopIpAddress -join ',')
            }
        }
        Emit $rows "vm-$key-nic-routes.json" @('source','state','prefix','nextHopType','nextHop')
    }
    else { Warn "could not read effective routes for $nic (VM may be deallocated)" }

    if ($SkipVms) { continue }

    Sub "$vm - in-guest kernel route table"
    $power = & az vm get-instance-view -g $ResourceGroup -n $vm `
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>$null
    if ($power -ne 'VM running') {
        Warn "$vm is '$power' - start it to capture in-guest routes"
        continue
    }

    Note 'running az vm run-command (this takes 30-60s)...'
    # --scripts is a space-separated list argument, so an inline one-liner gets
    # shredded into one token per line. Hand the CLI a file with @<path> instead.
    $out = & az vm run-command invoke -g $ResourceGroup -n $vm `
        --command-id RunShellScript --scripts "@$GuestProbe" -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) {
        $msg = ($out | ConvertFrom-Json).value[0].message
        $msg | Set-Content (Join-Path $OutputDir "vm-$key-guest-routes.txt")
        Write-Host $msg
        Add-Content $Report $msg
    }
    else { Warn "run-command failed on $vm" }
}

Remove-Item -LiteralPath $GuestProbe -ErrorAction SilentlyContinue

# ==========================================================================
# 4. GCP
# ==========================================================================
if ($SkipGcp) {
    Head 'GCP (skipped)'
}
else {
    Head 'GCP ON-PREMISES'

    if (-not $GcpProject) { $GcpProject = $env:GCP_PROJECT }
    if (-not $GcpProject) { $GcpProject = (& gcloud config get-value project 2>$null) }
    if ([string]::IsNullOrWhiteSpace($GcpProject) -or $GcpProject -eq '(unset)') {
        Warn 'no GCP project resolved - pass -GcpProject or set $env:GCP_PROJECT'
    }
    else {
        Note "project $GcpProject / region $GcpRegion"
        $router = "$GcpNamePrefix-router"
        $attach = "$GcpNamePrefix-attach"
        $vpc    = $GcpNamePrefix
        $vm     = "$GcpNamePrefix-vm"

        Sub "$attach - Partner Interconnect attachment"
        $raw = & gcloud compute interconnects attachments describe $attach `
            --region=$GcpRegion --project=$GcpProject --format=json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $a = $raw | ConvertFrom-Json
            $a | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir 'gcp-attachment.json')
            Emit ([pscustomobject]@{
                state        = $a.state
                adminEnabled = $a.adminEnabled
                vlan         = $a.vlanTag8021q
                cloudRouterIp= $a.cloudRouterIpAddress
                peerIp       = $a.customerRouterIpAddress
                partner      = $a.partnerMetadata.partnerName
                interconnect = $a.partnerMetadata.interconnectName
            })
        }
        else { Warn "attachment $attach not found" }

        Sub "$router - BGP session status"
        $raw = & gcloud compute routers get-status $router `
            --region=$GcpRegion --project=$GcpProject --format=json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $st = ($raw | ConvertFrom-Json).result
            $st | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir 'gcp-router-status.json')

            $peers = $st.bgpPeerStatus | ForEach-Object {
                [pscustomobject]@{
                    name    = $_.name
                    state   = $_.state
                    status  = $_.status
                    localIp = $_.ipAddress
                    peerIp  = $_.peerIpAddress
                    learned = $_.numLearnedRoutes
                    uptime  = $_.uptime
                }
            }
            Emit $peers $null @('name','state','status','localIp','peerIp','learned','uptime')

            Sub "$router - routes advertised TO the MCR"
            $adv = $st.bgpPeerStatus | ForEach-Object { $_.advertisedRoutes } | ForEach-Object {
                [pscustomobject]@{ prefix = $_.destRange; nextHop = $_.nextHopIp; priority = $_.priority }
            }
            Emit $adv 'gcp-advertised.json' @('prefix','nextHop','priority')

            Sub "$router - routes learned FROM the MCR"
            $learned = $st.bestRoutesForRouter | ForEach-Object {
                [pscustomobject]@{
                    prefix  = $_.destRange
                    nextHop = $_.nextHopIp
                    asPath  = ($_.asPaths | ForEach-Object { $_.asLists -join ' ' }) -join ' | '
                    status  = $_.routeStatus
                }
            }
            Emit $learned 'gcp-learned.json' @('prefix','nextHop','asPath','status')
        }
        else { Warn "router $router status unavailable" }

        Sub "$vpc - VPC route table"
        $raw = & gcloud compute routes list --project=$GcpProject `
            --filter="network:$vpc" --format=json 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $rt = $raw | ConvertFrom-Json
            $rt | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir 'gcp-vpc-routes.json')
            $rows = $rt | ForEach-Object {
                [pscustomobject]@{
                    name     = $_.name
                    prefix   = $_.destRange
                    priority = $_.priority
                    nextHop  = @($_.nextHopIp, $_.nextHopGateway, $_.nextHopIlb) |
                               Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] } |
                               Select-Object -First 1
                }
            }
            Emit $rows $null @('name','prefix','priority','nextHop')
        }
        else { Warn 'could not list VPC routes' }

        Sub "$vm - in-guest kernel route table (via IAP)"
        if ($SkipVms) {
            Note 'skipped (-SkipVms)'
        }
        else {
            Note 'running gcloud compute ssh --tunnel-through-iap ...'
            $guest = & gcloud compute ssh $vm --zone="$GcpRegion-a" --project=$GcpProject `
                --tunnel-through-iap --quiet `
                --command="echo '### ip -4 route show'; ip -4 route show; echo; echo '### addresses'; ip -4 -br addr" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $guest | Set-Content (Join-Path $OutputDir 'gcp-vm-guest-routes.txt')
                Write-Host $guest
                Add-Content $Report $guest
            }
            else {
                Warn 'IAP SSH failed - needs an allow rule for 35.235.240.0/20 on tcp:22 and roles/iap.tunnelResourceAccessor'
                Add-Content $Report $guest
            }
        }
    }
}

Head 'DONE'
Write-Host "Dump written to: $OutputDir" -ForegroundColor Green
Write-Host "Combined report: $Report" -ForegroundColor Green
Write-Host ''
Write-Host 'To compare a steady-state run against a failover run:' -ForegroundColor DarkGray
Write-Host '  .\dump-routes.ps1 -ResourceGroup <rg> -Label before' -ForegroundColor DarkGray
Write-Host '  # ...break the Dallas circuit...' -ForegroundColor DarkGray
Write-Host '  .\dump-routes.ps1 -ResourceGroup <rg> -Label after' -ForegroundColor DarkGray
Write-Host '  git diff --no-index .\route-dumps\<before>\report.txt .\route-dumps\<after>\report.txt' -ForegroundColor DarkGray
