# Emergency fix - no admin elevation needed for config files
# Just fix configs and let user restart Clash manually

$cfgDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

Write-Host "=== Emergency Config Fix ===" -ForegroundColor Cyan

# 1. Fix verge.yaml - turn OFF dns override
$vergeFile = Join-Path $cfgDir "verge.yaml"
$vf = Get-Content $vergeFile -Raw
$vf = $vf -replace 'enable_dns_settings:\s*\w+', 'enable_dns_settings: false'
$vf = $vf -replace 'enable_tun_mode:\s*\w+', 'enable_tun_mode: true'
$vf = $vf -replace 'enable_system_proxy:\s*\w+', 'enable_system_proxy: false'
$vf = $vf -replace 'enable_auto_launch:\s*\w+', 'enable_auto_launch: true'
Set-Content $vergeFile $vf -Encoding UTF8
Write-Host "[OK] DNS override: OFF" -ForegroundColor Green
Write-Host "[OK] TUN mode: ON" -ForegroundColor Green

# 2. Delete stale config.yaml so Clash regenerates fresh with merge
$configFile = Join-Path $cfgDir "config.yaml"
if (Test-Path $configFile) {
    Remove-Item $configFile -Force
    Write-Host "[OK] Deleted stale config.yaml" -ForegroundColor Green
}

# 3. Verify merge profile
$mergeFile = Join-Path $cfgDir "profiles\m6BhSgOOEO0Z.yaml"
$mc = Get-Content $mergeFile -Raw -ErrorAction SilentlyContinue
if ($mc -match 'tcp-concurrent') {
    Write-Host "[OK] Merge profile intact" -ForegroundColor Green
} else {
    Write-Host "[!] Rewriting merge profile..." -ForegroundColor Yellow
    @"
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

tcp-concurrent: true
keep-alive-interval: 15
keep-alive-idle: 120
unified-delay: true

profile:
  store-selected: true
  store-fake-ip: true
"@ | Set-Content $mergeFile -Encoding UTF8
    Write-Host "[OK] Merge profile rewritten" -ForegroundColor Green
}

# 4. Flush DNS
ipconfig /flushdns 2>$null | Out-Null
Write-Host "[OK] DNS flushed" -ForegroundColor Green

Write-Host ""
Write-Host "=== Config fixed. Now do this: ===" -ForegroundColor Yellow
Write-Host "1. Close Clash Verge completely (right-click tray icon -> Exit)" -ForegroundColor White
Write-Host "2. Reopen Clash Verge" -ForegroundColor White
Write-Host "3. DO NOT touch DNS override toggle!" -ForegroundColor Red
Write-Host ""
