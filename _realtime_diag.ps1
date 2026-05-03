$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

Write-Host "============================================" -ForegroundColor White
Write-Host "  Real-Time Network Diagnosis" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
Write-Host "============================================" -ForegroundColor White

# 1. WiFi connection status
Write-Host "`n=== WiFi Status ===" -ForegroundColor Cyan
$wlanInfo = netsh wlan show interfaces
$wlanInfo | ForEach-Object { Write-Host "  $_" }

# 2. Check if WiFi has been disconnecting recently
Write-Host "`n=== WiFi Disconnect Events (last 1 hour) ===" -ForegroundColor Cyan
$start1h = (Get-Date).AddHours(-1)
$disconnects = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start1h; Id=@(8001,8002,8003,11000,11001,11002,11004,11005,11006)} -ErrorAction SilentlyContinue
$autoConfigEvents = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; StartTime=$start1h} -ErrorAction SilentlyContinue
$wlanDisconnects = $autoConfigEvents | Where-Object { $_.Id -in @(8001,8002,8003) }
$wlanConnects = $autoConfigEvents | Where-Object { $_.Id -in @(8000) }

if ($wlanDisconnects) {
    Write-Host "  WLAN disconnect events: $($wlanDisconnects.Count)" -ForegroundColor Red
    $wlanDisconnects | Select-Object -First 5 | ForEach-Object {
        Write-Host "    [$($_.TimeCreated.ToString('HH:mm:ss'))] EventID=$($_.Id) $($_.Message.Substring(0,[Math]::Min($_.Message.Length,80)))" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No WLAN disconnect events in last hour" -ForegroundColor Green
}
if ($wlanConnects) {
    Write-Host "  WLAN connect events: $($wlanConnects.Count)" -ForegroundColor Yellow
    $wlanConnects | Select-Object -First 3 | ForEach-Object {
        Write-Host "    [$($_.TimeCreated.ToString('HH:mm:ss'))] Connected" -ForegroundColor Yellow
    }
}

# Driver-level events
Write-Host "`n=== WiFi Driver Events (last 1 hour) ===" -ForegroundColor Cyan
$driverEvents = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start1h} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Netwaw|Netwtw|NDIS' }
if ($driverEvents) {
    Write-Host "  Driver events: $($driverEvents.Count)" -ForegroundColor Yellow
    $driverEvents | Select-Object -First 8 | ForEach-Object {
        $lvl = $_.LevelDisplayName
        $color = if ($lvl -eq 'Warning') {'Yellow'} elseif ($lvl -eq 'Error') {'Red'} else {'Gray'}
        Write-Host "    [$($_.TimeCreated.ToString('HH:mm:ss'))] [$lvl] $($_.ProviderName): $($_.Message.Substring(0,[Math]::Min($_.Message.Length,100)))" -ForegroundColor $color
    }
} else {
    Write-Host "  No driver events" -ForegroundColor Green
}

# 3. Clash process and TUN status
Write-Host "`n=== Clash Status ===" -ForegroundColor Cyan
$procs = @('clash-verge','verge-mihomo','clash-verge-service')
foreach ($p in $procs) {
    $proc = Get-Process $p -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "  $p : PID=$($proc.Id) Running since $($proc.StartTime.ToString('HH:mm:ss'))" -ForegroundColor Green
    } else {
        Write-Host "  $p : NOT RUNNING" -ForegroundColor Red
    }
}

$tunAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta' }
if ($tunAdapter -and $tunAdapter.Status -eq 'Up') {
    Write-Host "  TUN adapter: $($tunAdapter.Name) [Up]" -ForegroundColor Green
} else {
    Write-Host "  TUN adapter: DOWN or missing!" -ForegroundColor Red
}

# 4. Check verge.yaml current DNS settings
Write-Host "`n=== Clash Settings Check ===" -ForegroundColor Cyan
$cfgDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$vergeYaml = Get-Content "$cfgDir\verge.yaml" -Raw
if ($vergeYaml -match 'enable_dns_settings:\s*(\w+)') {
    $dnsOverride = $Matches[1]
    if ($dnsOverride -eq 'true') {
        Write-Host "  enable_dns_settings: TRUE  <-- WARNING: DNS override is ON!" -ForegroundColor Red
    } else {
        Write-Host "  enable_dns_settings: false (correct)" -ForegroundColor Green
    }
}
if ($vergeYaml -match 'enable_tun_mode:\s*(\w+)') {
    Write-Host "  enable_tun_mode: $($Matches[1])" -ForegroundColor $(if($Matches[1] -eq 'true'){'Green'}else{'Red'})
}

# 5. Check runtime config.yaml TUN section
Write-Host "`n=== Runtime Config (config.yaml) ===" -ForegroundColor Cyan
$configYaml = Get-Content "$cfgDir\config.yaml" -Raw
if ($configYaml -match 'stack:\s*(\w+)') { Write-Host "  tun.stack: $($Matches[1])" -ForegroundColor $(if($Matches[1] -eq 'mixed'){'Green'}else{'Yellow'}) }
if ($configYaml -match 'tun:[\s\S]*?enable:\s*(\w+)') { Write-Host "  tun.enable: $($Matches[1])" -ForegroundColor $(if($Matches[1] -eq 'true'){'Green'}else{'Red'}) }
if ($configYaml -match 'tcp-concurrent:\s*(\w+)') { Write-Host "  tcp-concurrent: $($Matches[1])" -ForegroundColor Green } else { Write-Host "  tcp-concurrent: NOT SET" -ForegroundColor Red }

# 6. Check merge profile still intact
Write-Host "`n=== Merge Profile Check ===" -ForegroundColor Cyan
$mergeFile = Get-Content "$cfgDir\profiles\m6BhSgOOEO0Z.yaml" -Raw
$mergeLen = $mergeFile.Trim().Length
if ($mergeLen -gt 100) {
    Write-Host "  Merge profile: OK ($mergeLen bytes)" -ForegroundColor Green
    if ($mergeFile -match 'stack:\s*mixed') { Write-Host "  Contains: stack=mixed" -ForegroundColor Green }
    if ($mergeFile -match 'tcp-concurrent') { Write-Host "  Contains: tcp-concurrent" -ForegroundColor Green }
} else {
    Write-Host "  Merge profile: EMPTY or CORRUPTED ($mergeLen bytes)" -ForegroundColor Red
}

# 7. Connectivity tests with timing
Write-Host "`n=== Connectivity Tests ===" -ForegroundColor Cyan
$tests = @(
    @{Name='ipinfo.io'; Url='https://ipinfo.io/json'},
    @{Name='google.com'; Url='https://www.google.com'},
    @{Name='cursor API'; Url='https://api2.cursor.sh'},
    @{Name='cloudflare'; Url='https://1.1.1.1/cdn-cgi/trace'}
)
foreach ($t in $tests) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest $t.Url -UseBasicParsing -TimeoutSec 10
        $sw.Stop()
        $color = if ($sw.ElapsedMilliseconds -lt 500) {'Green'} elseif ($sw.ElapsedMilliseconds -lt 2000) {'Yellow'} else {'Red'}
        Write-Host ("  {0,-15} {1,6}ms  [OK]" -f $t.Name, $sw.ElapsedMilliseconds) -ForegroundColor $color
    } catch {
        $sw.Stop()
        Write-Host ("  {0,-15} {1,6}ms  [FAILED]" -f $t.Name, $sw.ElapsedMilliseconds) -ForegroundColor Red
    }
}

# 8. Check Clash API for node latencies
Write-Host "`n=== Clash API - Proxy Groups ===" -ForegroundColor Cyan
try {
    $headers = @{}
    if ($configYaml -match 'secret:\s*(\S+)') {
        $secret = $Matches[1]
        if ($secret -ne 'set-your-secret' -and $secret -ne '') {
            $headers['Authorization'] = "Bearer $secret"
        }
    }
    $proxies = Invoke-RestMethod 'http://127.0.0.1:9097/proxies' -Headers $headers -TimeoutSec 5
    $aiGroup = $proxies.proxies.AI
    if ($aiGroup) {
        Write-Host "  AI group current: $($aiGroup.now)" -ForegroundColor White
    }
    $proxiesGroup = $proxies.proxies.Proxies
    if ($proxiesGroup) {
        Write-Host "  Proxies group current: $($proxiesGroup.now)" -ForegroundColor White
    }
    # Show some node delays
    $usNodes = $proxies.proxies.PSObject.Properties | Where-Object { $_.Name -match 'USA|US |美国' } | Select-Object -First 6
    foreach ($node in $usNodes) {
        $delay = $node.Value.history | Select-Object -Last 1
        $delayMs = if ($delay) { $delay.delay } else { 'N/A' }
        $color = if ($delayMs -eq 'N/A' -or $delayMs -eq 0) {'Red'} elseif ($delayMs -lt 200) {'Green'} elseif ($delayMs -lt 500) {'Yellow'} else {'Red'}
        Write-Host ("  {0,-45} delay={1}ms" -f $node.Name, $delayMs) -ForegroundColor $color
    }
} catch {
    Write-Host "  Cannot reach Clash API at 127.0.0.1:9097" -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
}

# 9. Network adapter reset count
Write-Host "`n=== Network Interface Statistics ===" -ForegroundColor Cyan
$wlanStats = Get-NetAdapterStatistics -Name 'WLAN' -ErrorAction SilentlyContinue
if ($wlanStats) {
    Write-Host "  Received: $([Math]::Round($wlanStats.ReceivedBytes/1MB,1)) MB   Sent: $([Math]::Round($wlanStats.SentBytes/1MB,1)) MB"
    Write-Host "  Recv Errors: $($wlanStats.ReceivedPacketErrors)   Send Errors: $($wlanStats.OutboundPacketErrors)"
    if ($wlanStats.ReceivedPacketErrors -gt 100 -or $wlanStats.OutboundPacketErrors -gt 100) {
        Write-Host "  HIGH PACKET ERROR COUNT - WiFi link is unstable!" -ForegroundColor Red
    }
}

Write-Host "`n============================================" -ForegroundColor White
Write-Host "  Diagnosis complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor White
