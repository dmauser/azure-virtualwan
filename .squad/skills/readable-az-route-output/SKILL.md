# Skill: readable-az-route-output

**Registered:** 2026-07-28  
**Author:** Amos (Tester)  
**Applies to:** PowerShell 5.1 read-only validation scripts against Azure Virtual WAN

---

## Problem

`az ... -o table` for vWAN route objects (vHub route-tables, NIC effective routes, vHub get-effective-routes) produces 5–7 wide columns. In a normal terminal they wrap into multi-line spaghetti that is unreadable. Using `-o json` + `Format-Table -AutoSize` solves this.

---

## Pattern

### 1. Switch from `-o table` to `-o json`

```powershell
# BEFORE (unreadable wrap)
$output = az network nic show-effective-route-table -g $Rg -n nic-vm-spoke1 -o table 2>$null
Log $output

# AFTER (compact, aligned)
$output = az network nic show-effective-route-table -g $Rg -n nic-vm-spoke1 -o json 2>$null
Show-RouteTable -Json $output -Kind Nic
```

### 2. Add the `Show-RouteTable` helper (PS5.1 compatible)

```powershell
function Show-RouteTable {
    param(
        [string]$Json,
        [ValidateSet('Hub','Conn','Nic','VHub')]
        [string]$Kind
    )
    if ([string]::IsNullOrWhiteSpace($Json)) {
        Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return
    }
    $data = $null
    try { $data = $Json | ConvertFrom-Json } catch { }
    if ($null -eq $data) {
        Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return
    }
    try {
        switch ($Kind) {
            'Hub' {
                $arr = @($data)
                if ($arr.Count -eq 0) { Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return }
                $rows = $arr | ForEach-Object {
                    $dest = if ($_.destinations -is [array]) { $_.destinations -join ', ' } else { [string]$_.destinations }
                    $nh   = if ($_.nextHop) { ($_.nextHop.TrimEnd('/') -split '/')[-1] } else { '' }
                    [PSCustomObject]@{ Destinations = $dest; NextHopType = $_.nextHopType; NextHop = $nh }
                }
                $rows | Format-Table -AutoSize | Out-String | Write-Host
            }
            'Conn' {
                $arr = @($data)
                if ($arr.Count -eq 0) { Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return }
                $rows = $arr | ForEach-Object {
                    $pfx = if ($_.prefix -is [array]) { $_.prefix -join ', ' } else { [string]$_.prefix }
                    [PSCustomObject]@{ Name = $_.name; Prefix = $pfx; NextHop = $_.nextHop }
                }
                $rows | Format-Table -AutoSize | Out-String | Write-Host
            }
            'Nic' {
                $arr = $null
                if ($data.PSObject.Properties.Name -contains 'value') { $arr = @($data.value) } else { $arr = @($data) }
                if ($null -eq $arr -or $arr.Count -eq 0) { Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return }
                $rows = $arr | ForEach-Object {
                    $pfx  = if ($_.addressPrefix -is [array])    { $_.addressPrefix -join ', '    } else { [string]$_.addressPrefix }
                    $nhip = if ($_.nextHopIpAddress -is [array]) { $_.nextHopIpAddress -join ', ' } else { [string]$_.nextHopIpAddress }
                    if ([string]::IsNullOrWhiteSpace($nhip)) { $nhip = '-' }
                    [PSCustomObject]@{ Source = $_.source; State = $_.state; AddressPrefix = $pfx; NextHopType = $_.nextHopType; NextHopIP = $nhip }
                }
                $def   = @($rows | Where-Object { $_.AddressPrefix -like '*0.0.0.0/0*' })
                $other = @($rows | Where-Object { $_.AddressPrefix -notlike '*0.0.0.0/0*' })
                ($def + $other) | Format-Table -AutoSize | Out-String | Write-Host
            }
            'VHub' {
                $arr = $null
                if ($data.PSObject.Properties.Name -contains 'value') { $arr = @($data.value) } else { $arr = @($data) }
                if ($null -eq $arr -or $arr.Count -eq 0) { Write-Host "       (no routes returned)" -ForegroundColor DarkGray; return }
                $rows = $arr | ForEach-Object {
                    $pfx    = if ($_.addressPrefixes -is [array]) { $_.addressPrefixes -join ', ' } else { [string]$_.addressPrefixes }
                    $nhs    = if ($_.nextHops -is [array])        { $_.nextHops -join ', ' }        else { [string]$_.nextHops }
                    $origin = if ($_.PSObject.Properties.Name -contains 'routeOrigin') { [string]$_.routeOrigin } else { '' }
                    $asp    = if ($_.PSObject.Properties.Name -contains 'asPath')      { [string]$_.asPath }      else { '' }
                    [PSCustomObject]@{ AddressPrefixes = $pfx; NextHopType = $_.nextHopType; NextHops = $nhs; RouteOrigin = $origin; AsPath = $asp }
                }
                $rows | Format-Table -AutoSize | Out-String | Write-Host
            }
        }
    } catch {
        Write-Host "       (route render error: $_)" -ForegroundColor DarkGray
    }
}
```

---

## Kind reference

| Kind | az command | JSON wrapper | Columns |
|------|-----------|-------------|---------|
| `Hub`  | `vhub route-table show --query 'routes[].{destinations,nextHopType,nextHop}'` | Direct array | Destinations, NextHopType, NextHop |
| `Conn` | `vhub connection show --query 'staticRoutes[].{name,prefix:addressPrefixes,nextHop}'` | Direct array | Name, Prefix, NextHop |
| `Nic`  | `nic show-effective-route-table` | `{"value":[...]}` | Source, State, AddressPrefix, NextHopType, NextHopIP |
| `VHub` | `vhub get-effective-routes` | `{"value":[...]}` | AddressPrefixes, NextHopType, NextHops, RouteOrigin, AsPath |

---

## BEFORE / AFTER example (Spoke1 NIC effective routes)

**BEFORE** (`-o table`, wraps at ~100 chars):
```
Source                 State  Address Prefix          Next Hop Type          Next Hop IP
---------------------  ------  ----------------------  ---------------------  -----------
VirtualNetworkGateway  Active  0.0.0.0/0               VirtualNetworkGateway
Default                Active  10.1.0.0/24             VnetLocal
Default                Active  10.0.0.0/8              VirtualNetworkGateway
```
(In a real terminal, the `Address Prefix` and `Next Hop Type` columns cause the row to spill across 2-3 visual lines each.)

**AFTER** (`-o json` + `Show-RouteTable -Kind Nic`):
```
Source                State  AddressPrefix  NextHopType            NextHopIP
------                -----  -------------  -----------            ---------
VirtualNetworkGateway Active 0.0.0.0/0      VirtualNetworkGateway  -
Default               Active 10.1.0.0/24    VnetLocal              -
Default               Active 10.0.0.0/8     VirtualNetworkGateway  -
```
0.0.0.0/0 row sorted to top; columns auto-sized to data widths.

---

## Object-based VNG check with string fallback

```powershell
$eff1HasVng = $false
try {
    $eff1Obj    = $eff1Raw | ConvertFrom-Json
    if ($null -ne $eff1Obj) {
        $eff1Routes = if ($eff1Obj.PSObject.Properties.Name -contains 'value') { @($eff1Obj.value) } else { @($eff1Obj) }
        $eff1Match  = @($eff1Routes | Where-Object { $_.nextHopType -eq 'VirtualNetworkGateway' } |
                       Where-Object { (@($_.addressPrefix) | Where-Object { $_ -eq '0.0.0.0/0' }).Count -gt 0 })
        $eff1HasVng = ($eff1Match.Count -gt 0)
    }
} catch { $eff1HasVng = $false }
# String fallback: if JSON parse fails or shape is unexpected
if (-not $eff1HasVng) { $eff1HasVng = ($eff1Raw -match 'VirtualNetworkGateway') }
```

---

## PS5.1 constraints

- No ternary `? :` — use `if (cond) { 'A' } else { 'B' }` assignment.
- No `-AsHashtable` on `ConvertFrom-Json` — use PSCustomObject property access.
- No `??` null-coalescing operator — use explicit null guards.
- `@($collection)` wrapping always safe for Count.
- `PSObject.Properties.Name -contains 'propName'` pattern for optional property existence check (StrictMode-safe alternative to `$obj.propName -ne $null`).

---

## Colorization helpers

```powershell
function Banner([string]$m) {
    Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) -ForegroundColor Magenta
}
function CheckPass([string]$label) {
    Write-Host ("[{0:HH:mm:ss}]   [PASS] {1}" -f (Get-Date), $label) -ForegroundColor Green
    $script:Pass++
}
function CheckFail([string]$label) {
    Write-Host ("[{0:HH:mm:ss}]   [FAIL] {1}" -f (Get-Date), $label) -ForegroundColor Red
    $script:Fail++
}
function CheckWarn([string]$label) {
    Write-Host ("[{0:HH:mm:ss}]   [WARN] {1}" -f (Get-Date), $label) -ForegroundColor Yellow
    $script:Warn++
}
```

Summary row with per-count color using `-NoNewline`:
```powershell
$failColor = if ($script:Fail -gt 0) { "Red" } else { "Green" }
Write-Host "PASS: " -NoNewline -ForegroundColor Magenta
Write-Host "$($script:Pass)" -NoNewline -ForegroundColor Green
Write-Host "  FAIL: " -NoNewline -ForegroundColor Magenta
Write-Host "$($script:Fail)" -NoNewline -ForegroundColor $failColor
Write-Host "  WARN: " -NoNewline -ForegroundColor Magenta
Write-Host "$($script:Warn)" -ForegroundColor Yellow
```
