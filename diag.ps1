$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$cfgDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

Write-Host "========================================" -ForegroundColor White
Write-Host "  Clash Verge Config Verification" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor White
Write-Host ""

# 1. Service
$svc = Get-Service clash_verge_service -ErrorAction SilentlyContinue
$status = if ($svc -and $svc.Status -eq 'Running') { "[OK] Running" } else { "[X]  NOT Running" }
Write-Host "Service     : $status" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' })

# 2. Process
$core = Get-Process verge-mihomo -ErrorAction SilentlyContinue
$pStatus = if ($core) { "[OK] PID $($core.Id)" } else { "[X]  Not found" }
Write-Host "verge-mihomo: $pStatus" -ForegroundColor $(if ($core) { 'Green' } else { 'Red' })

# 3. Merge profile - must NOT have dns:
$mp = Get-Content (Join-Path $cfgDir "profiles\mndPM2C5egWr.yaml") -Raw
$hasDns = $mp -match '^dns:' -or $mp -match '`ndns:'
Write-Host "Merge no-dns: $(if (-not $hasDns) { '[OK] Clean (no dns override)' } else { '[X]  Has dns: section!' })" -ForegroundColor $(if (-not $hasDns) { 'Green' } else { 'Red' })

# 4. dns_config.yaml has proxy-server-nameserver
$dns = Get-Content (Join-Path $cfgDir "dns_config.yaml") -Raw
$hasProxySrv = $dns -match 'proxy-server-nameserver'
Write-Host "DNS pxy-srv : $(if ($hasProxySrv) { '[OK] proxy-server-nameserver present' } else { '[X]  MISSING!' })" -ForegroundColor $(if ($hasProxySrv) { 'Green' } else { 'Red' })

# 5. enable_dns_settings
$verge = Get-Content (Join-Path $cfgDir "verge.yaml") -Raw
$dnsOn = $verge -match 'enable_dns_settings:\s*true'
Write-Host "DNS override: $(if ($dnsOn) { '[OK] true (dns_config.yaml active)' } else { '[X]  false!' })" -ForegroundColor $(if ($dnsOn) { 'Green' } else { 'Red' })

# 6. TUN mode
$tunOn = $verge -match 'enable_tun_mode:\s*true'
Write-Host "TUN mode    : $(if ($tunOn) { '[OK] enabled' } else { '[X]  disabled' })" -ForegroundColor $(if ($tunOn) { 'Green' } else { 'Red' })

# 7. Runtime config TUN stack
$cfg = Get-Content (Join-Path $cfgDir "config.yaml") -Raw
if ($cfg -match 'stack:\s*(\S+)') { $stack = $Matches[1] } else { $stack = 'unknown' }
if ($cfg -match 'mtu:\s*(\d+)') { $mtu = $Matches[1] } else { $mtu = 'unknown' }
Write-Host "TUN stack   : $(if ($stack -eq 'mixed') { "[OK] $stack" } else { "[!]  $stack (should be mixed)" })" -ForegroundColor $(if ($stack -eq 'mixed') { 'Green' } else { 'Yellow' })
Write-Host "TUN MTU     : $(if ($mtu -eq '9000') { "[OK] $mtu" } else { "[!]  $mtu (should be 9000)" })" -ForegroundColor $(if ($mtu -eq '9000') { 'Green' } else { 'Yellow' })

# 8. Rules - Cursor + Google AI
$rules = Get-Content (Join-Path $cfgDir "profiles\rRikew9veFiq.yaml") -Raw
$hasCursor = $rules -match 'cursor\.sh'
$hasGoogle = $rules -match 'googleapis\.com'
Write-Host "Rules cursor: $(if ($hasCursor) { '[OK]' } else { '[X]  Missing' })" -ForegroundColor $(if ($hasCursor) { 'Green' } else { 'Red' })
Write-Host "Rules google: $(if ($hasGoogle) { '[OK]' } else { '[X]  Missing' })" -ForegroundColor $(if ($hasGoogle) { 'Green' } else { 'Red' })

# 9. Exit IP
Write-Host ""
Write-Host "--- Network test ---" -ForegroundColor White
try {
    $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 10
    $color = if ($geo.country -eq 'US') { 'Green' } else { 'Yellow' }
    Write-Host "Exit IP     : $($geo.ip)  $($geo.city), $($geo.country)" -ForegroundColor $color
} catch {
    Write-Host "Exit IP     : Cannot reach (check Clash UI node selection)" -ForegroundColor Red
}

# 10. Latency
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $null = Invoke-WebRequest "https://www.google.com" -UseBasicParsing -TimeoutSec 10
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    $color = if ($ms -lt 500) { 'Green' } elseif ($ms -lt 1500) { 'Yellow' } else { 'Red' }
    Write-Host "google.com  : $ms ms" -ForegroundColor $color
} catch {
    $sw.Stop()
    Write-Host "google.com  : FAILED after $($sw.ElapsedMilliseconds)ms" -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  Action required in Clash UI:" -ForegroundColor Yellow
Write-Host "  - Click 'Reload' on your subscription" -ForegroundColor White
Write-Host "  - Set AI, Proxies, Final to same US node" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White
