#Requires -Version 7.0
<#
.SYNOPSIS
  Timestamped connectivity test (ping) for the svh-dynamic-er-ri lab.

.DESCRIPTION
  Prompts for a target IP/host (or takes -Target) and pings it on a loop,
  printing one timestamped line per probe:

      [2026-06-16 12:30:01] 10.10.1.4  Reply  time=2ms
      [2026-06-16 12:30:02] 10.10.1.4  Timeout

  Useful for watching connectivity come up/down while ExpressRoute circuits,
  Routing Intent or firewall rules converge. Press Ctrl+C to stop; a summary
  (sent / received / lost / min/avg/max latency) is printed on exit.

  Read-only: this script never creates, changes or deletes any resource.

.PARAMETER Target
  Target IP address or hostname. Prompted if omitted.

.PARAMETER Count
  Number of probes to send. 0 (default) = run until Ctrl+C.

.PARAMETER IntervalSeconds
  Seconds to wait between probes. Default: 1.

.PARAMETER TimeoutSeconds
  Per-probe timeout in seconds. Default: 2.

.PARAMETER LogFile
  Optional path to also append the timestamped output to. Default: none.

.EXAMPLE
  .\test-connectivity.ps1

.EXAMPLE
  .\test-connectivity.ps1 -Target 10.10.1.4

.EXAMPLE
  .\test-connectivity.ps1 -Target 192.168.100.10 -IntervalSeconds 2 -LogFile .\la-test.log
#>

param(
  [string]$Target          = "",
  [int]$Count              = 0,
  [int]$IntervalSeconds    = 1,
  [int]$TimeoutSeconds     = 2,
  [string]$LogFile         = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = Read-Host "Target IP address or hostname to test"
}
if ([string]::IsNullOrWhiteSpace($Target)) {
    Write-Host "[test-connectivity] No target provided. Exiting." -ForegroundColor Red
    exit 1
}

function Write-Line {
    param([string]$Text, [string]$Color = "Gray")
    Write-Host $Text -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -Path $LogFile -Value $Text
    }
}

$sent      = 0
$received  = 0
$latencies = [System.Collections.Generic.List[int]]::new()

$header = "[test-connectivity] Pinging $Target  (interval ${IntervalSeconds}s, timeout ${TimeoutSeconds}s). Ctrl+C to stop."
Write-Line $header "Cyan"

try {
    while ($Count -le 0 -or $sent -lt $Count) {
        $sent++
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $reply = $null
        try {
            $reply = Test-Connection -TargetName $Target -Count 1 -TimeoutSeconds $TimeoutSeconds -ErrorAction Stop
        } catch {
            $reply = $null
        }

        if ($null -ne $reply -and $reply.Status -eq "Success") {
            $received++
            $lat = [int]$reply.Latency
            $latencies.Add($lat)
            Write-Line ("[{0}] {1}  Reply  time={2}ms" -f $ts, $Target, $lat) "Green"
        } else {
            Write-Line ("[{0}] {1}  Timeout / no reply" -f $ts, $Target) "Red"
        }

        if ($Count -le 0 -or $sent -lt $Count) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
} finally {
    $lost = $sent - $received
    $lossPct = if ($sent -gt 0) { [math]::Round(($lost / $sent) * 100, 1) } else { 0 }
    Write-Line "" "Gray"
    Write-Line "--- $Target connectivity summary ---" "Cyan"
    Write-Line ("sent={0}  received={1}  lost={2} ({3}% loss)" -f $sent, $received, $lost, $lossPct) "Cyan"
    if ($latencies.Count -gt 0) {
        $min = ($latencies | Measure-Object -Minimum).Minimum
        $max = ($latencies | Measure-Object -Maximum).Maximum
        $avg = [math]::Round(($latencies | Measure-Object -Average).Average, 1)
        Write-Line ("rtt min/avg/max = {0}/{1}/{2} ms" -f $min, $avg, $max) "Cyan"
    }
}
