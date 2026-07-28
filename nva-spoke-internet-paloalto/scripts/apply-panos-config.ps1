#Requires -Version 5.1
# =============================================================================
# apply-panos-config.ps1 — Post-boot day-0 Palo Alto config push fallback.
#
# Applies the day-0 bootstrap configuration (bootstrap.xml) to each PA
# VM-Series firewall via the PAN-OS XML API after the VM boots.
#
# WHEN TO USE:
#   The Azure Files bootstrap (Phase 5b of deploy.ps1) requires shared-key
#   SMB auth on the storage account.  Management-group policy
#   allowSharedKeyAccess=false (e.g. DMAUSER-FDPO) blocks that upload, leaving
#   both firewalls at factory default with no interfaces/zones/routes/NAT.
#   This script is a subscription-portable fallback that pushes the identical
#   configuration via the PAN-OS management API after the VMs are running.
#
# BEHAVIOR:
#   1. Poll each mgmt IP until the PAN-OS XML API (keygen) responds.
#   2. Build the day-0 config PIECEWISE via type=config&action=set subtree calls
#      (interfaces, VRs, zones, NAT, security, etc.) that MERGE into the running
#      candidate, preserving all factory-default nodes.
#   3. Commit and poll the commit job to completion.
#   4. Verify: ethernet1/1 + ethernet1/2 up, 0.0.0.0/0 route present.
#   Idempotent: safe to re-run; re-applying the same config is a no-op commit.
#
# WHY action=set (NOT import + load config):
#   'load config from <file>' REPLACES the entire candidate with the uploaded
#   XML.  A partial bootstrap.xml lacks PAN-OS's required predefined/default
#   nodes, so the subsequent commit fails validation with EMPTY error detail on
#   PAN-OS 12.1.x (confirmed live on DMAUSER-FDPO).  Issuing the same config as
#   discrete action=set subtrees MERGES each fragment into the running candidate
#   without disturbing factory defaults, and the commit succeeds cleanly
#   ("Configuration committed successfully").  The subtree fragments below are a
#   1:1 mapping of bicep/bootstrap/bootstrap.xml.
#
# INTERFACE CONTRACT (called by deploy.ps1 — do not change param names):
#   -MgmtIps        <string[]>  one or more PA management public IPs / PIPs
#   -AdminUsername  <string>    VM admin username
#   -AdminPassword  <string>    VM admin password (plain; caller passes securely)
#   -TimeoutMinutes <int>       max wait per firewall for API readiness [20]
#
# EXAMPLE:
#   .\apply-panos-config.ps1 `
#       -MgmtIps @('20.118.168.153','20.106.77.50') `
#       -AdminUsername azureuser `
#       -AdminPassword 'MyP@ssw0rd123!' `
#       -TimeoutMinutes 25
#
# EXIT CODE: 0 = all firewalls configured OK.  Non-zero = one or more failed.
# =============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string[]]$MgmtIps,

    [Parameter(Mandatory = $true)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $true)]
    [string]$AdminPassword,

    [int]$TimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# bootstrap.xml lives two levels up from this script's directory.
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$BootstrapXml = [System.IO.Path]::GetFullPath(
    (Join-Path $ScriptDir "..\bicep\bootstrap\bootstrap.xml"))

$PsVer = $PSVersionTable.PSVersion.Major

# ── SSL certificate bypass ───────────────────────────────────────────────────
# PA management endpoint uses a self-signed cert.  On PS 5.x, override the
# ServicePointManager certificate policy (process-wide; harmless in a script).
# On PS 6+, -SkipCertificateCheck is passed to each Invoke-* call instead.
if ($PsVer -lt 6) {
    try {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class PanTrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
            WebRequest req, int problem) { return true; }
}
"@
    } catch { }   # Ignore if already defined in this PS session
    [System.Net.ServicePointManager]::CertificatePolicy =
        New-Object PanTrustAllCerts
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12
}

# ── Logging helpers ───────────────────────────────────────────────────────────
function Log([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan
}
function LogOk([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] OK  $m" -ForegroundColor Green
}
function LogWarn([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] WARN $m" -ForegroundColor Yellow
}
function LogErr([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ERR $m" -ForegroundColor Red
}
function LogDot([string]$m) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ... $m"
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────
# All PAN-OS API params (except the uploaded file) go in the URL query string;
# the body is empty for GET/POST non-import calls.

function Invoke-PanGet([string]$Uri) {
    if ($PsVer -ge 6) {
        (Invoke-WebRequest -Method GET -Uri $Uri -SkipCertificateCheck `
            -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop).Content
    } else {
        (New-Object System.Net.WebClient).DownloadString($Uri)
    }
}

function Invoke-PanPost([string]$Uri) {
    if ($PsVer -ge 6) {
        (Invoke-WebRequest -Method POST -Uri $Uri -SkipCertificateCheck `
            -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop).Content
    } else {
        $wc = New-Object System.Net.WebClient
        # Upload empty string as POST body; all params are in the URL.
        [System.Text.Encoding]::UTF8.GetString(
            $wc.UploadData($Uri, "POST", [byte[]]@()))
    }
}

# Multipart POST: uploads $FilePath as a form-data file field named "file".
# type/category/key are already encoded in the $Uri query string.
function Invoke-PanUpload([string]$Uri, [string]$FilePath) {
    if ($PsVer -ge 6) {
        # Some PAN-OS builds reject PowerShell's -Form multipart encoding with
        # "No file uploaded" (400). Build the multipart/form-data body manually,
        # which every tested PAN-OS build accepts. Field name MUST be "file".
        $boundary = [System.Guid]::NewGuid().ToString()
        $bytes    = [System.IO.File]::ReadAllBytes($FilePath)
        $enc      = [System.Text.Encoding]::GetEncoding('iso-8859-1')  # byte-preserving
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $LF       = "`r`n"
        $body =
            "--$boundary$LF" +
            "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`"$LF" +
            "Content-Type: application/octet-stream$LF$LF" +
            $enc.GetString($bytes) + $LF +
            "--$boundary--$LF"
        (Invoke-WebRequest -Method POST -Uri $Uri -Body $body `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -SkipCertificateCheck -TimeoutSec 120 -UseBasicParsing `
            -ErrorAction Stop).Content
    } else {
        # WebClient.UploadFile sends multipart/form-data with field name "file"
        # and the file basename as the filename in Content-Disposition.
        $wc = New-Object System.Net.WebClient
        [System.Text.Encoding]::UTF8.GetString(
            $wc.UploadFile($Uri, "POST", $FilePath))
    }
}

# ── XML parsing helpers ───────────────────────────────────────────────────────
function Get-XmlValue([string]$Xml, [string]$Tag) {
    if ($Xml -match "<$Tag>([^<]+)</$Tag>") { return $Matches[1] }
    return $null
}

function Test-PanSuccess([string]$Xml) {
    # PAN-OS XML API returns the outer attribute in varying forms across versions:
    #   status="success"  |  status='success'  |  status = 'success'  (spaces around =)
    # Match all quote styles and tolerate optional whitespace around the equals sign.
    return ($Xml -match "status\s*=\s*'success'" -or $Xml -match 'status\s*=\s*"success"')
}

# ── PAN-OS candidate-config builder (type=config, action=set) ─────────────────
# Device entry name is always "localhost.localdomain" on a factory VM-Series.
$DeviceBase = "/config/devices/entry[@name='localhost.localdomain']"

# Ordered list of config subtrees. Each is merged (action=set) into the running
# candidate at $DeviceBase + Xpath.  1:1 with bicep/bootstrap/bootstrap.xml.
# Order matters: interfaces/profiles/VRs before the vsys blocks that reference them.
$PanConfigSubtrees = @(
    @{ Label = 'setting/session tcp-reject-non-syn=no'
       Xpath = '/deviceconfig/setting'
       Element = '<session><tcp-reject-non-syn>no</tcp-reject-non-syn></session>' },

    @{ Label = 'interface-management-profile allow-ssh-ping'
       Xpath = '/network/profiles/interface-management-profile'
       Element = '<entry name="allow-ssh-ping"><ssh>yes</ssh><ping>yes</ping></entry>' },

    @{ Label = 'data interfaces ethernet1/1 (untrust) + ethernet1/2 (trust)'
       Xpath = '/network/interface/ethernet'
       Element = '<entry name="ethernet1/1"><comment>untrust - snet-untrust 10.0.0.32/27 - Public LB backend</comment><layer3><interface-management-profile>allow-ssh-ping</interface-management-profile><dhcp-client><enable>yes</enable><create-default-route>no</create-default-route><send-hostname><enable>yes</enable></send-hostname></dhcp-client></layer3></entry><entry name="ethernet1/2"><comment>trust - snet-trust 10.0.0.64/27 - ILB HA-ports backend</comment><layer3><interface-management-profile>allow-ssh-ping</interface-management-profile><dhcp-client><enable>yes</enable><create-default-route>no</create-default-route><send-hostname><enable>yes</enable></send-hostname></dhcp-client></layer3></entry>' },

    @{ Label = 'dual virtual-routers VR-Untrust + VR-Trust'
       Xpath = '/network/virtual-router'
       Element = '<entry name="VR-Untrust"><interface><member>ethernet1/1</member></interface><routing-table><ip><static-route><entry name="default-via-untrust"><destination>0.0.0.0/0</destination><nexthop><ip-address>10.0.0.33</ip-address></nexthop><interface>ethernet1/1</interface><metric>10</metric></entry><entry name="rfc1918-10-to-vr-trust"><destination>10.0.0.0/8</destination><nexthop><next-vr>VR-Trust</next-vr></nexthop><metric>20</metric></entry></static-route></ip></routing-table></entry><entry name="VR-Trust"><interface><member>ethernet1/2</member></interface><routing-table><ip><static-route><entry name="azure-probe-via-trust"><destination>168.63.129.16/32</destination><nexthop><ip-address>10.0.0.65</ip-address></nexthop><interface>ethernet1/2</interface><metric>10</metric></entry><entry name="rfc1918-10-via-trust"><destination>10.0.0.0/8</destination><nexthop><ip-address>10.0.0.65</ip-address></nexthop><interface>ethernet1/2</interface><metric>10</metric></entry><entry name="default-to-vr-untrust"><destination>0.0.0.0/0</destination><nexthop><next-vr>VR-Untrust</next-vr></nexthop><metric>10</metric></entry></static-route></ip></routing-table></entry>' },

    @{ Label = 'vsys1 interface import (eth1/1 + eth1/2)'
       Xpath = "/vsys/entry[@name='vsys1']/import"
       Element = '<network><interface><member>ethernet1/1</member><member>ethernet1/2</member></interface></network>' },

    @{ Label = 'vsys1 zones untrust + trust'
       Xpath = "/vsys/entry[@name='vsys1']/zone"
       Element = '<entry name="untrust"><network><layer3><member>ethernet1/1</member></layer3></network></entry><entry name="trust"><network><layer3><member>ethernet1/2</member></layer3></network></entry>' },

    @{ Label = 'vsys1 NAT trust->untrust dynamic-ip-and-port (MASQUERADE)'
       Xpath = "/vsys/entry[@name='vsys1']/rulebase/nat/rules"
       Element = '<entry name="trust-to-untrust-masquerade"><from><member>trust</member></from><to><member>untrust</member></to><source><member>any</member></source><destination><member>any</member></destination><service>any</service><source-translation><dynamic-ip-and-port><interface-address><interface>ethernet1/1</interface></interface-address></dynamic-ip-and-port></source-translation></entry>' },

    @{ Label = 'vsys1 security permit trust->untrust (lab-only)'
       Xpath = "/vsys/entry[@name='vsys1']/rulebase/security/rules"
       Element = '<entry name="permit-trust-to-untrust"><from><member>trust</member></from><to><member>untrust</member></to><source><member>any</member></source><destination><member>any</member></destination><source-user><member>any</member></source-user><category><member>any</member></category><application><member>any</member></application><service><member>any</member></service><action>allow</action><log-start>no</log-start><log-end>yes</log-end><description>LAB ONLY - permit all trust to untrust for internet egress</description></entry>' }
)

# Issue a single action=set call: merge $Element into the candidate at $DeviceBase+$Xpath.
function Set-PanNode([string]$BaseUrl, [string]$KeyEnc, [string]$Xpath, [string]$Element) {
    $xpEnc  = [uri]::EscapeDataString($DeviceBase + $Xpath)
    $elEnc  = [uri]::EscapeDataString($Element)
    $setUri = "${BaseUrl}/api/?type=config&action=set&key=${KeyEnc}&xpath=${xpEnc}&element=${elEnc}"
    return Invoke-PanPost $setUri
}

# ── Per-firewall configuration logic ─────────────────────────────────────────
function Configure-Firewall([string]$Ip) {

    $baseUrl  = "https://$Ip"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    # ── Step 1: Poll PAN-OS API (keygen) until ready ──────────────────────────
    Log "[$Ip] Waiting for PAN-OS API readiness (timeout ${TimeoutMinutes} min) ..."
    Log "[$Ip] Note: PA VM typically takes 10-15 min post-provisioning to be API-ready."

    $apiKey  = $null
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $userEnc = [uri]::EscapeDataString($AdminUsername)
            $passEnc = [uri]::EscapeDataString($AdminPassword)
            $kUri = "${baseUrl}/api/?type=keygen&user=${userEnc}&password=${passEnc}"
            $resp = Invoke-PanGet $kUri
            if ((Test-PanSuccess $resp)) {
                $apiKey = Get-XmlValue $resp "key"
                if ($apiKey) {
                    LogOk "[$Ip] API ready (attempt $attempt) — API key obtained."
                    break
                }
            }
        } catch { }

        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        if ($remaining -le 0) { break }
        $sleep = [Math]::Min(30, $remaining)
        LogDot "[$Ip] Not ready (attempt $attempt) — retrying in ${sleep}s ..."
        Start-Sleep -Seconds $sleep
    }

    if (-not $apiKey) {
        LogErr "[$Ip] TIMEOUT: PAN-OS API not reachable after ${TimeoutMinutes} minutes."
        return $false
    }

    $keyEnc = [uri]::EscapeDataString($apiKey)

    # ── Step 2: Build the candidate config PIECEWISE (action=set subtrees) ─────
    # Each subtree MERGES into the running candidate without disturbing factory
    # defaults, so the commit passes validation (unlike import + load config).
    Log "[$Ip] Building day-0 candidate config via $($PanConfigSubtrees.Count) action=set subtrees ..."
    $setIndex = 0
    foreach ($node in $PanConfigSubtrees) {
        $setIndex++
        try {
            $setResp = Set-PanNode -BaseUrl $baseUrl -KeyEnc $keyEnc `
                -Xpath $node.Xpath -Element $node.Element
            if (-not (Test-PanSuccess $setResp)) {
                LogErr "[$Ip] set subtree ${setIndex}/$($PanConfigSubtrees.Count) FAILED ($($node.Label)): $setResp"
                return $false
            }
            LogDot "[$Ip] set ${setIndex}/$($PanConfigSubtrees.Count) OK — $($node.Label)"
        } catch {
            LogErr "[$Ip] set subtree ${setIndex} exception ($($node.Label)): $_"
            return $false
        }
    }
    LogOk "[$Ip] All $($PanConfigSubtrees.Count) config subtrees merged into candidate."

    # ── Step 4: Commit ────────────────────────────────────────────────────────
    $commitCmd    = "<commit></commit>"
    $commitCmdEnc = [uri]::EscapeDataString($commitCmd)
    Log "[$Ip] Committing configuration ..."
    $jobId = $null
    try {
        $commitUri  = "${baseUrl}/api/?type=commit&key=${keyEnc}&cmd=${commitCmdEnc}"
        $commitResp = Invoke-PanPost $commitUri

        if (-not (Test-PanSuccess $commitResp)) {
            LogErr "[$Ip] Commit request failed: $commitResp"
            return $false
        }

        # "No changes" = config already matches running (idempotent re-run)
        if ($commitResp -match "no changes") {
            LogOk "[$Ip] Commit: no changes to commit — configuration already applied (idempotent)."
        } else {
            $jobId = Get-XmlValue $commitResp "job"
            if (-not $jobId) {
                LogErr "[$Ip] Commit response contained no job ID: $commitResp"
                return $false
            }
            LogDot "[$Ip] Commit job ID: $jobId — polling for completion ..."
        }
    } catch {
        LogErr "[$Ip] Commit exception: $_"
        return $false
    }

    # ── Step 5: Poll commit job ───────────────────────────────────────────────
    if ($jobId) {
        $jobDeadline = (Get-Date).AddMinutes(10)
        $commitOk    = $false

        while ((Get-Date) -lt $jobDeadline) {
            Start-Sleep -Seconds 10
            try {
                $jobCmdEnc = [uri]::EscapeDataString(
                    "<show><jobs><id>$jobId</id></jobs></show>")
                $jobUri  = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${jobCmdEnc}"
                $jobResp = Invoke-PanGet $jobUri

                $jStatus  = Get-XmlValue $jobResp "status"
                $jResult  = Get-XmlValue $jobResp "result"
                $jProgress= Get-XmlValue $jobResp "progress"
                LogDot "[$Ip] Job ${jobId}: status=$jStatus result=$jResult progress=${jProgress}%"

                if ($jStatus -eq "FIN") {
                    if ($jResult -eq "OK") {
                        LogOk "[$Ip] Commit job $jobId completed successfully."
                        $commitOk = $true
                    } else {
                        $details = Get-XmlValue $jobResp "details"
                        LogErr "[$Ip] Commit job $jobId FAILED: $details"
                    }
                    break
                }
            } catch {
                LogDot "[$Ip] Job poll error (will retry): $_"
            }
        }

        if (-not $commitOk) {
            if ((Get-Date) -ge $jobDeadline) {
                LogErr "[$Ip] Commit job timed out after 10 minutes."
            }
            return $false
        }
    }

    # ── Step 6: Post-commit verification ─────────────────────────────────────
    Log "[$Ip] Verifying post-commit state (brief pause for DHCP) ..."
    Start-Sleep -Seconds 8

    # Verify ethernet1/1 (untrust) — expect DHCP IP in snet-untrust 10.0.0.32/27
    try {
        $i11CmdEnc = [uri]::EscapeDataString("<show><interface>ethernet1/1</interface></show>")
        $i11Uri    = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${i11CmdEnc}"
        $i11Resp   = Invoke-PanGet $i11Uri
        if ($i11Resp -match "10\.0\.0\.\d+" -or $i11Resp -match "<state>up</state>") {
            LogOk "[$Ip] ethernet1/1 (untrust) — UP with DHCP address."
        } else {
            LogWarn "[$Ip] ethernet1/1 may still be awaiting DHCP; verify manually."
        }
    } catch {
        LogWarn "[$Ip] Could not query ethernet1/1 state: $_"
    }

    # Verify ethernet1/2 (trust) — expect DHCP IP in snet-trust 10.0.0.64/27
    try {
        $i12CmdEnc = [uri]::EscapeDataString("<show><interface>ethernet1/2</interface></show>")
        $i12Uri    = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${i12CmdEnc}"
        $i12Resp   = Invoke-PanGet $i12Uri
        if ($i12Resp -match "10\.0\.0\.\d+" -or $i12Resp -match "<state>up</state>") {
            LogOk "[$Ip] ethernet1/2 (trust) — UP with DHCP address."
        } else {
            LogWarn "[$Ip] ethernet1/2 may still be awaiting DHCP; verify manually."
        }
    } catch {
        LogWarn "[$Ip] Could not query ethernet1/2 state: $_"
    }

    # Verify virtual-router default route 0.0.0.0/0 (via ethernet1/1 → 10.0.0.33)
    try {
        $rtCmdEnc = [uri]::EscapeDataString(
            "<show><routing><route></route></routing></show>")
        $rtUri  = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${rtCmdEnc}"
        $rtResp = Invoke-PanGet $rtUri
        if ($rtResp -match "0\.0\.0\.0/0") {
            LogOk "[$Ip] Virtual-router has 0.0.0.0/0 default route (via ethernet1/1 → 10.0.0.33)."
        } else {
            LogWarn "[$Ip] 0.0.0.0/0 route not yet visible — may appear once DHCP assigns ethernet1/1 IP."
        }
    } catch {
        LogWarn "[$Ip] Could not query routing table: $_"
    }

    # Verify the 168.63.129.16/32 probe-return route (critical for ILB health probes)
    try {
        $prCmdEnc = [uri]::EscapeDataString(
            "<show><routing><route><destination>168.63.129.16/32</destination></route></routing></show>")
        $prUri  = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${prCmdEnc}"
        $prResp = Invoke-PanGet $prUri
        if ($prResp -match "168\.63\.129\.16") {
            LogOk "[$Ip] 168.63.129.16/32 probe-return route present (ILB health probe symmetric path)."
        } else {
            LogWarn "[$Ip] 168.63.129.16/32 route not yet visible — this is critical for ILB health probes."
        }
    } catch {
        LogWarn "[$Ip] Could not verify 168.63.129.16/32 probe route: $_"
    }

    LogOk "[$Ip] ══ PASS — Day-0 configuration applied and committed. ══"
    return $true
}

# ── Main ──────────────────────────────────────────────────────────────────────

# The day-0 config is now embedded as action=set subtrees ($PanConfigSubtrees),
# a 1:1 mapping of bootstrap.xml, so the file itself is no longer uploaded.
# We still surface its presence for traceability (it remains the source-of-truth doc).
if (Test-Path $BootstrapXml) {
    Log "bootstrap.xml reference present: $BootstrapXml"
} else {
    LogWarn "bootstrap.xml reference not found at $BootstrapXml (config is embedded; continuing)."
}

Log "=============================================="
Log "PAN-OS day-0 config push  (post-boot fallback)"
Log "=============================================="
Log "  config source : embedded action=set subtrees (1:1 with bootstrap.xml)"
Log "  Firewalls     : $($MgmtIps -join ', ')"
Log "  Timeout/FW    : $TimeoutMinutes min"
Log "  PS version    : $($PSVersionTable.PSVersion)"
Log ""

$failCount = 0
$passIps   = [System.Collections.ArrayList]::new()
$failIps   = [System.Collections.ArrayList]::new()

foreach ($ip in $MgmtIps) {
    Log "══════════ Configuring $ip ══════════"
    $ok = $false
    try {
        $ok = Configure-Firewall -Ip $ip
    } catch {
        LogErr "[$ip] Unhandled exception: $_"
        $ok = $false
    }

    if ($ok) {
        [void]$passIps.Add($ip)
    } else {
        [void]$failIps.Add($ip)
        $failCount++
    }
    Log ""
}

# ── Summary ───────────────────────────────────────────────────────────────────
Log "=============================================="
Log "RESULT SUMMARY"
Log "=============================================="
foreach ($ip in $passIps) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')]   PASS  $ip" -ForegroundColor Green
}
foreach ($ip in $failIps) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')]   FAIL  $ip" -ForegroundColor Red
}
Log ""

if ($failCount -eq 0) {
    LogOk "All $($MgmtIps.Count) firewall(s) configured successfully."
    exit 0
} else {
    LogErr "$failCount of $($MgmtIps.Count) firewall(s) FAILED configuration."
    LogErr "Check the per-firewall log above for details."
    exit 1
}
