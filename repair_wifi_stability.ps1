<#
.SYNOPSIS
    Windows Wi-Fi stability repair for Clash/TUN users.
.DESCRIPTION
    Repairs common Intel Wi-Fi instability patterns that can cause:
    - random "airplane mode like" disconnects
    - Clash/Mihomo TUN "default interface lost"
    - frequent WLAN reconnect loops after sleep/wake

    It applies conservative settings only:
    - restart WLAN stack
    - ensure key services are running
    - keep WLAN IPv6 enabled for compatibility
    - flush DNS / reset proxies
    - optional winsock reset (off by default)
    - export recent network events for post-check

    Must run as Administrator (auto-elevates).
#>

param(
    [switch]$WithWinsockReset,
    [int]$EventHours = 24
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Step($m) { Write-Host ""; Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad($m) { Write-Host "  [X]  $m" -ForegroundColor Red }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad "Requires Administrator. Re-launching elevated..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor White
Write-Host "  Wi-Fi Stability Repair (Windows)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor White

Write-Step "Check adapters and key services"
$wlan = Get-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue
if (-not $wlan) {
    Write-Bad "WLAN adapter not found. Stop here and check device manager."
    pause
    exit 1
}
Write-Ok "WLAN adapter detected: $($wlan.InterfaceDescription)"
Get-Service WlanSvc, NlaSvc, RmSvc | ForEach-Object {
    Write-Host ("       {0}: {1} ({2})" -f $_.Name, $_.Status, $_.StartType) -ForegroundColor Gray
}

Write-Step "Set conservative Wi-Fi/TCP baseline"
Enable-NetAdapterBinding -Name 'WLAN' -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
& netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null
& netsh int tcp set global rsc=enabled 2>$null | Out-Null
& netsh int tcp set global fastopen=enabled 2>$null | Out-Null
Write-Ok "IPv6 enabled on WLAN; TCP globals normalized"

Write-Step "Normalize proxy/DNS stack"
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $regPath -Name ProxyEnable -Value 0
Set-ItemProperty $regPath -Name ProxyServer -Value ''
& netsh winhttp reset proxy 2>$null | Out-Null
& ipconfig /flushdns 2>$null | Out-Null
Write-Ok "System proxy cleared; DNS cache flushed"

if ($WithWinsockReset) {
    Write-Step "Optional Winsock reset"
    & netsh winsock reset 2>$null | Out-Null
    Write-Warn "Winsock reset scheduled. A reboot is recommended."
}

Write-Step "Restart WLAN stack and awareness services"
Restart-Service WlanSvc -Force -ErrorAction SilentlyContinue
Set-Service NlaSvc -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service NlaSvc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Disable-NetAdapter -Name 'WLAN' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Enable-NetAdapter -Name 'WLAN' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Write-Ok "WLAN adapter restarted"

Write-Step "Quick connectivity verification"
try {
    $null = Invoke-WebRequest "https://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 10
    Write-Ok "Microsoft connectivity endpoint reachable"
} catch {
    Write-Warn "Microsoft connectivity endpoint check failed"
}
try {
    $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 10
    Write-Host ("       Exit IP: {0}  {1}, {2}" -f $geo.ip, $geo.city, $geo.country) -ForegroundColor Gray
    Write-Ok "Internet access confirmed"
} catch {
    Write-Warn "ipinfo check failed (network may still be recovering)"
}

Write-Step "Export recent network driver events"
$logDir = Join-Path $PSScriptRoot "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null
$outFile = Join-Path $logDir ("wifi_events_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$start = (Get-Date).AddHours(-1 * [Math]::Abs($EventHours))
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Netwaw|Netwtw|WLAN-AutoConfig|Tcpip|NDIS|NetAdapter|NetworkProfile|NetBT' } |
    Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
    Format-List | Out-File -FilePath $outFile -Encoding UTF8
Write-Ok "Event report exported: $outFile"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host "  Wi-Fi stability repair completed" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host "Recommendations:" -ForegroundColor Yellow
Write-Host "  1) Keep this window output and monitor for 2-4 hours" -ForegroundColor White
Write-Host "  2) If random drops persist, update/rollback Intel Wi-Fi driver" -ForegroundColor White
Write-Host "  3) If using sleep heavily, test once with sleep disabled" -ForegroundColor White
if ($WithWinsockReset) {
    Write-Host "  4) Reboot now to finish Winsock reset" -ForegroundColor White
}
Write-Host ""
pause
