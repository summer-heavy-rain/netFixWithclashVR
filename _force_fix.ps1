<#
    Force fix: turn off DNS override, kill Clash completely, restart, verify merge applied
    Must run as Administrator
#>

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  [X] Requires Admin. Re-launching..." -ForegroundColor Red
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$cfgDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  Force Fix - DNS Override + Restart" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor White

# ---- Step 1: Kill Clash completely ----
Write-Host "`n[1/5] Killing ALL Clash processes..." -ForegroundColor Cyan
Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
Start-Sleep 1
taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
taskkill /F /IM verge-mihomo-alpha.exe 2>$null | Out-Null
taskkill /F /IM clash-verge-service.exe 2>$null | Out-Null
Stop-Service clash_verge_service -Force -ErrorAction SilentlyContinue
Start-Sleep 3

$alive = Get-Process clash-verge,verge-mihomo,clash-verge-service -ErrorAction SilentlyContinue
if ($alive) {
    Write-Host "  [!] Force killing remaining: $($alive.ProcessName -join ', ')" -ForegroundColor Yellow
    $alive | Stop-Process -Force
    Start-Sleep 2
}
Write-Host "  [OK] All Clash processes killed" -ForegroundColor Green

# ---- Step 2: Fix verge.yaml ----
Write-Host "`n[2/5] Fixing verge.yaml (DNS override OFF)..." -ForegroundColor Cyan
$vergeFile = Join-Path $cfgDir "verge.yaml"
$vf = Get-Content $vergeFile -Raw

# Turn OFF DNS override - THIS IS CRITICAL
$vf = $vf -replace 'enable_dns_settings:\s*\w+', 'enable_dns_settings: false'
$vf = $vf -replace 'enable_tun_mode:\s*\w+', 'enable_tun_mode: true'
$vf = $vf -replace 'enable_system_proxy:\s*\w+', 'enable_system_proxy: false'
$vf = $vf -replace 'enable_auto_launch:\s*\w+', 'enable_auto_launch: true'

Set-Content $vergeFile $vf -Encoding UTF8
Write-Host "  [OK] enable_dns_settings: false (DNS override OFF)" -ForegroundColor Green
Write-Host "  [OK] enable_tun_mode: true" -ForegroundColor Green

# ---- Step 3: Verify merge profile is correct ----
Write-Host "`n[3/5] Verifying Merge profile..." -ForegroundColor Cyan
$mergeFile = Join-Path $cfgDir "profiles\m6BhSgOOEO0Z.yaml"
$mc = Get-Content $mergeFile -Raw
if ($mc -match 'stack:\s*mixed' -and $mc -match 'tcp-concurrent:\s*true') {
    Write-Host "  [OK] Merge profile intact (stack=mixed, tcp-concurrent=true)" -ForegroundColor Green
} else {
    Write-Host "  [!] Merge profile damaged, rewriting..." -ForegroundColor Yellow
    $mergeContent = @"
# Clash Verge Rev - Optimized Merge Profile
# PERSISTS across reboots. Do NOT add dns: section.

tun:
  stack: mixed
  mtu: 9000

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    TLS:
      ports: [443, 8443]
    HTTP:
      ports: [80, 8080-8888]
      override-destination: true
  skip-domain:
    - "Mijia Cloud"
    - "+.apple.com"
    - "+.icloud.com"

tcp-concurrent: true

keep-alive-interval: 15
keep-alive-idle: 120

unified-delay: true

profile:
  store-selected: true
  store-fake-ip: true
"@
    Set-Content $mergeFile $mergeContent -Encoding UTF8
    Write-Host "  [OK] Merge profile rewritten" -ForegroundColor Green
}

# ---- Step 4: Delete config.yaml so Clash regenerates it fresh ----
Write-Host "`n[4/5] Deleting stale config.yaml (Clash will regenerate with merge)..." -ForegroundColor Cyan
$configFile = Join-Path $cfgDir "config.yaml"
if (Test-Path $configFile) {
    Remove-Item $configFile -Force
    Write-Host "  [OK] config.yaml deleted (will be regenerated fresh)" -ForegroundColor Green
} else {
    Write-Host "  [OK] config.yaml already absent" -ForegroundColor Green
}

# Also flush DNS and reset proxy
ipconfig /flushdns 2>$null | Out-Null
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $regPath -Name ProxyEnable -Value 0
Set-ItemProperty $regPath -Name ProxyServer -Value ''
netsh winhttp reset proxy 2>$null | Out-Null
Write-Host "  [OK] DNS flushed, system proxy cleared" -ForegroundColor Green

# ---- Step 5: Start Clash fresh ----
Write-Host "`n[5/5] Starting Clash Verge Rev..." -ForegroundColor Cyan

# Find Clash exe
$clashDir = $null
$svcInfo = Get-WmiObject Win32_Service -Filter "Name='clash_verge_service'" -ErrorAction SilentlyContinue
if ($svcInfo -and $svcInfo.PathName) {
    $svcPath = $svcInfo.PathName -replace '"',''
    $clashDir = Split-Path (Split-Path $svcPath)
}
if (-not $clashDir) {
    $candidates = @("D:\clash verge","C:\Program Files\Clash Verge","$env:LOCALAPPDATA\Programs\clash-verge")
    foreach ($c in $candidates) { if (Test-Path "$c\clash-verge.exe") { $clashDir = $c; break } }
}

if ($clashDir) {
    Start-Service clash_verge_service -ErrorAction SilentlyContinue
    Start-Sleep 2
    Start-Process (Join-Path $clashDir "clash-verge.exe")
    Write-Host "  [OK] Clash Verge started" -ForegroundColor Green
    Write-Host "  Waiting 25 seconds for full initialization..." -ForegroundColor Gray
    Start-Sleep 25

    # Verify
    Write-Host "`n========================================" -ForegroundColor White
    Write-Host "  Verification" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor White

    # Check config.yaml was regenerated with merge applied
    if (Test-Path $configFile) {
        $newCfg = Get-Content $configFile -Raw
        if ($newCfg -match 'stack:\s*(\w+)') {
            $stack = $Matches[1]
            $color = if ($stack -eq 'mixed') {'Green'} else {'Red'}
            Write-Host "  tun.stack: $stack" -ForegroundColor $color
        }
        if ($newCfg -match 'tcp-concurrent:\s*(\w+)') {
            Write-Host "  tcp-concurrent: $($Matches[1])" -ForegroundColor Green
        } else {
            Write-Host "  tcp-concurrent: NOT SET (merge may not be applied!)" -ForegroundColor Red
        }
        if ($newCfg -match 'sniffer:') {
            Write-Host "  sniffer: present" -ForegroundColor Green
        } else {
            Write-Host "  sniffer: MISSING" -ForegroundColor Red
        }
    } else {
        Write-Host "  config.yaml not generated yet" -ForegroundColor Yellow
    }

    # Check DNS override stayed off
    $vfCheck = Get-Content $vergeFile -Raw
    if ($vfCheck -match 'enable_dns_settings:\s*true') {
        Write-Host "  DNS override: ON (something turned it back on!)" -ForegroundColor Red
    } else {
        Write-Host "  DNS override: OFF (correct)" -ForegroundColor Green
    }

    # TUN
    $tunUp = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta' -and $_.Status -eq 'Up' }
    if ($tunUp) { Write-Host "  TUN adapter: Up" -ForegroundColor Green }
    else { Write-Host "  TUN adapter: not up yet" -ForegroundColor Yellow }

    # Connectivity
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
        $sw.Stop()
        Write-Host "  Exit IP: $($geo.ip) - $($geo.city), $($geo.country) ($($sw.ElapsedMilliseconds)ms)" -ForegroundColor $(if($geo.country -eq 'US'){'Green'}else{'Yellow'})
    } catch {
        Write-Host "  Cannot reach internet yet" -ForegroundColor Red
    }

    # Clash API
    try {
        $proxies = Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -TimeoutSec 5
        Write-Host "  Clash API: reachable" -ForegroundColor Green
    } catch {
        Write-Host "  Clash API: not reachable (may need more time)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [X] Cannot find Clash Verge install directory!" -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Done!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "IMPORTANT RULES:" -ForegroundColor Yellow
Write-Host "  1. DO NOT toggle 'DNS Override' in Clash UI (keep it OFF)" -ForegroundColor White
Write-Host "  2. DO NOT toggle 'System Proxy' in Clash UI (keep it OFF)" -ForegroundColor White
Write-Host "  3. ONLY use TUN mode" -ForegroundColor White
Write-Host "  4. AI + Proxies + Final must point to the SAME US node" -ForegroundColor White
Write-Host ""
pause
