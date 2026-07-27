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
#   2. Import bootstrap.xml to the device as a named candidate config.
#   3. Load the imported file as the active candidate config.
#   4. Commit and poll the commit job to completion.
#   5. Verify: ethernet1/1 + ethernet1/2 up, 0.0.0.0/0 route present.
#   Idempotent: safe to re-run; re-applying the same config is a no-op commit.
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
        $form = @{ file = Get-Item -LiteralPath $FilePath }
        (Invoke-WebRequest -Method POST -Uri $Uri -Form $form `
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
    return ($Xml -match "status='success'" -or $Xml -match 'status="success"')
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

    # ── Step 2: Import bootstrap.xml as a named configuration file ────────────
    Log "[$Ip] Importing bootstrap.xml to device configuration store ..."
    try {
        $importUri = "${baseUrl}/api/?type=import&category=configuration&key=${keyEnc}"
        $importResp = Invoke-PanUpload -Uri $importUri -FilePath $BootstrapXml
        if (-not (Test-PanSuccess $importResp)) {
            LogErr "[$Ip] Import API call failed: $importResp"
            return $false
        }
        LogOk "[$Ip] bootstrap.xml imported successfully."
    } catch {
        LogErr "[$Ip] Import exception: $_"
        return $false
    }

    # ── Step 3: Load the imported file as candidate configuration ─────────────
    # bootstrap.xml is now stored on the device under the filename "bootstrap.xml".
    # "load config from" replaces the running candidate with that file.
    $loadCmd = "<load><config><from>bootstrap.xml</from></config></load>"
    $loadCmdEnc = [uri]::EscapeDataString($loadCmd)
    Log "[$Ip] Loading bootstrap.xml as candidate configuration ..."
    try {
        $loadUri  = "${baseUrl}/api/?type=op&key=${keyEnc}&cmd=${loadCmdEnc}"
        $loadResp = Invoke-PanGet $loadUri
        if (-not (Test-PanSuccess $loadResp)) {
            LogErr "[$Ip] Load config failed: $loadResp"
            return $false
        }
        LogOk "[$Ip] Candidate configuration loaded from bootstrap.xml."
    } catch {
        LogErr "[$Ip] Load exception: $_"
        return $false
    }

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

# Validate bootstrap.xml exists before touching any firewall
if (-not (Test-Path $BootstrapXml)) {
    Write-Error "bootstrap.xml not found at: $BootstrapXml`nExpected path: nva-spoke-internet-paloalto/bicep/bootstrap/bootstrap.xml"
    exit 1
}

Log "=============================================="
Log "PAN-OS day-0 config push  (post-boot fallback)"
Log "=============================================="
Log "  bootstrap.xml : $BootstrapXml"
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
