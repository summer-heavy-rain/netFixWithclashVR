# Clash Verge Rev - Network Fix with Node Verification
# Proven fix: WLAN reset + Chrome fingerprint + UDP DNS + fake-ip-filter
# Must run as Administrator (auto-elevates). UTF-8 BOM.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step ($n,$t,$m) { Write-Host "" ; Write-Host "[$n/$t] $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad  ($m) { Write-Host "  [X]  $m" -ForegroundColor Red }
function Write-Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

$totalSteps = 13

# == PHASE 1: ENVIRONMENT ==
# Step 1: Admin elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad "Requires Administrator. Re-launching elevated..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Write-Step 1 $totalSteps "Admin privileges confirmed"

# Step 2: Locate Clash paths
Write-Step 2 $totalSteps "Locating Clash Verge Rev"
$vergeDataDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

$clashDir = $null
$svcInfo = Get-WmiObject Win32_Service -Filter "Name='clash_verge_service'" -ErrorAction SilentlyContinue
if ($svcInfo -and $svcInfo.PathName) {
    $svcPath = $svcInfo.PathName -replace '"',''
    $clashDir = Split-Path (Split-Path $svcPath)
}
if (-not $clashDir -or -not (Test-Path $clashDir)) {
    $candidates = @("D:\clash verge", "C:\Program Files\Clash Verge", "$env:LOCALAPPDATA\Programs\clash-verge", "$env:LOCALAPPDATA\clash-verge")
    foreach ($c in $candidates) {
        if (Test-Path "$c\clash-verge.exe") { $clashDir = $c; break }
    }
}
if (-not $clashDir) { Write-Bad "Cannot find Clash Verge Rev!"; pause; exit 1 }
Write-Ok "Install: $clashDir"
Write-Ok "Data:    $vergeDataDir"

# Step 3: Parse profiles.yaml
Write-Step 3 $totalSteps "Parsing profiles.yaml for merge/rules UID"
$profilesYamlPath = Join-Path $vergeDataDir "profiles.yaml"
$mergeUid = $null; $rulesUid = $null
if (Test-Path $profilesYamlPath) {
    $pyLines = Get-Content $profilesYamlPath
    $inOption = $false
    foreach ($line in $pyLines) {
        if ($line -match '^\s*option:') { $inOption = $true; continue }
        if ($inOption) {
            if ($line -match '^\s*merge:\s*(\S+)') { $mergeUid = $Matches[1] }
            if ($line -match '^\s*rules:\s*(\S+)') { $rulesUid = $Matches[1] }
            if ($line -match '^\S') { $inOption = $false }
        }
    }
}
if ($mergeUid) { Write-Ok "Merge UID: $mergeUid" } else { Write-Bad "No merge profile found!"; pause; exit 1 }
if ($rulesUid) { Write-Ok "Rules UID: $rulesUid" }

Write-Host ""
Write-Host "======================================================" -ForegroundColor White
Write-Host "  Clash Verge Rev - DPI Bypass & Node Fix" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor White
# == PHASE 2: NETWORK RESET (DPI bypass) ==
# Step 4: Stop all Clash processes
Write-Step 4 $totalSteps "Stopping Clash processes"
Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
& taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
& taskkill /F /IM verge-mihomo-alpha.exe 2>$null | Out-Null
$clashSvc = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($clashSvc -and $clashSvc.Status -eq 'Running') {
    Stop-Service clash_verge_service -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
}
& taskkill /F /IM clash-verge-service.exe 2>$null | Out-Null
Start-Sleep 2
Write-Ok "All Clash processes stopped"
# Step 5: WLAN adapter reset (clears DPI RST state cache)
Write-Step 5 $totalSteps "Resetting WLAN adapter (DPI bypass - CRITICAL)"
$wlan = Get-NetAdapter | Where-Object { $_.Name -match "Wi-Fi|WLAN" -and $_.Status -eq "Up" }
if ($wlan) {
    Write-Info "Disabling $($wlan.Name)..."
    Disable-NetAdapter -Name $wlan.Name -Confirm:$false
    Start-Sleep -Seconds 3
    Write-Info "Enabling $($wlan.Name)..."
    Enable-NetAdapter -Name $wlan.Name -Confirm:$false
    Start-Sleep -Seconds 5
    Write-Ok "WLAN adapter reset complete (DPI RST cache cleared)"
} else {
    Write-Warn "No active WLAN adapter found (Ethernet? Skipping reset)"
}
# Step 6: Flush DNS
Write-Step 6 $totalSteps "Flushing DNS cache"
& ipconfig /flushdns 2>$null | Out-Null
Write-Ok "DNS cache flushed"
# == PHASE 3: CONFIGURATION FIX ==
# Step 7: Write Merge Profile
Write-Step 7 $totalSteps "Writing Merge Profile (Chrome fingerprint + UDP DNS + fake-ip-filter)"
$mergeFilePath = Join-Path $vergeDataDir "profiles\$mergeUid.yaml"
$mergeLines = @(
    "# Clash Verge Rev - Merge Profile",
    "# DPI bypass: Chrome TLS fingerprint + safe UDP DNS",
    "",
    "global-client-fingerprint: chrome",
    "",
    "dns:",
    "  ipv6: false",
    "  enable: true",
    "  listen: 0.0.0.0:1053",
    "  enhanced-mode: fake-ip",
    "  use-hosts: false",
    "  default-nameserver:",
    "    - 119.29.29.29",
    "    - 223.5.5.5",
    "  nameserver:",
    "    - 119.29.29.29",
    "    - 223.5.5.5",
    "  fallback:",
    "    - https://doh.pub/dns-query",
    "    - https://dns.alidns.com/dns-query",
    "  fallback-filter:",
    "    geoip: true",
    "    geoip-code: CN",
    "    ipcidr:",
    "      - 240.0.0.0/4",
    "  fake-ip-range: 198.18.0.1/15",
    "  fake-ip-filter:",
    '    - "*.lan"',
    '    - "*.local"',
    '    - "*.localhost"',
    '    - "+.msftconnecttest.com"',
    '    - "+.msftncsi.com"',
    '    - "+.u8m1xiygn.sbs"',
    '    - "+.shcgcbzwq.sbs"',
    "  proxy-server-nameserver:",
    "    - 119.29.29.29",
    "    - 223.5.5.5",
    "",
    "sniffer:",
    "  enable: true",
    "  force-dns-mapping: true",
    "  parse-pure-ip: true",
    "  sniff:",
    "    TLS:",
    "      ports: [443, 8443]",
    "    HTTP:",
    "      ports: [80, 8080-8888]",
    "      override-destination: true",
    "",
    "tcp-concurrent: true",
    "unified-delay: true",
    "keep-alive-interval: 30",
    "keep-alive-idle: 600",
    "",
    "profile:",
    "  store-selected: true",
    "  store-fake-ip: true"
)
$mergeContent = $mergeLines -join "`n"
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($mergeFilePath, $mergeContent, $utf8Bom)
Write-Ok "Merge profile written: chrome fingerprint + UDP DNS + fake-ip-filter"
# Step 8: Fix verge.yaml
Write-Step 8 $totalSteps "Fixing verge.yaml (auto_launch, tun, sysproxy)"
$vergeFile = Join-Path $vergeDataDir "verge.yaml"
if (Test-Path $vergeFile) {
    $vf = Get-Content $vergeFile -Raw
    $vf = $vf -replace 'enable_auto_launch:\s*\w+', 'enable_auto_launch: true'
    $vf = $vf -replace 'enable_tun_mode:\s*\w+', 'enable_tun_mode: true'
    $vf = $vf -replace 'enable_system_proxy:\s*\w+', 'enable_system_proxy: true'
    $vf = $vf -replace 'enable_dns_settings:\s*\w+', 'enable_dns_settings: false'
    if ($vf -match 'prefer_sidecar') { $vf = $vf -replace 'prefer_sidecar:\s*\w+', 'prefer_sidecar: false' }
    Set-Content $vergeFile $vf -Encoding UTF8
    Write-Ok "verge.yaml: auto_launch=true, tun=true, sysproxy=true, dns_settings=false"
} else {
    Write-Bad "verge.yaml not found!"
}
# Step 9: Register startup guard
Write-Step 9 $totalSteps "Registering startup guard task"
$taskName = "ClashVergeStartupGuard"
$guardScript = "D:\fixClashNet\_startup_guard.ps1"
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guardScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Clash Verge Rev startup guard (DNS patch + config watch)" -Force | Out-Null
    Write-Ok "Startup guard registered (runs at logon)"
} catch {
    Write-Warn "Failed to register guard task: $_"
}

# Ensure service is set to auto start
$svcNow = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($svcNow) {
    Set-Service clash_verge_service -StartupType Automatic -ErrorAction SilentlyContinue
} else {
    $installSvc = Join-Path $clashDir "resources\install-service.exe"
    if (Test-Path $installSvc) {
        Start-Process $installSvc -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Sleep 2
        Set-Service clash_verge_service -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Ok "Service reinstalled"
    }
}

# == PHASE 4: START & VERIFY ==
# Step 10: Start Clash Verge Rev
Write-Step 10 $totalSteps "Starting Clash Verge Rev"
$exePath = Join-Path $clashDir "clash-verge.exe"
if (-not (Test-Path $exePath)) { Write-Bad "clash-verge.exe not found!"; pause; exit 1 }
Start-Process $exePath
Write-Ok "Clash Verge Rev launched"
Write-Info "Waiting 15s for initialization..."
Start-Sleep 15

# Step 11: Wait for API + DNS PATCH
Write-Step 11 $totalSteps "API ready check + DNS PATCH (runtime override)"
$apiBase = "http://127.0.0.1:9097"
$headers = @{ "Authorization" = "Bearer set-your-secret"; "Content-Type" = "application/json" }

$apiReady = $false
for ($w = 0; $w -lt 60; $w += 2) {
    try {
        $null = Invoke-RestMethod -Uri "$apiBase/configs" -Headers $headers -TimeoutSec 3
        $apiReady = $true; break
    } catch { Start-Sleep -Seconds 2 }
}
if (-not $apiReady) { Write-Bad "Clash API not available after 60s!"; pause; exit 1 }
Write-Ok "Clash API ready"

# DNS PATCH with global-client-fingerprint
$patchJson = @{
    "global-client-fingerprint" = "chrome"
    dns = @{
        enable = $true
        ipv6 = $false
        listen = "0.0.0.0:1053"
        "enhanced-mode" = "fake-ip"
        "use-hosts" = $false
        "default-nameserver" = @("119.29.29.29", "223.5.5.5")
        nameserver = @("119.29.29.29", "223.5.5.5")
        fallback = @("https://doh.pub/dns-query", "https://dns.alidns.com/dns-query")
        "fallback-filter" = @{ geoip = $true; "geoip-code" = "CN"; ipcidr = @("240.0.0.0/4") }
        "proxy-server-nameserver" = @("119.29.29.29", "223.5.5.5")
        "fake-ip-filter" = @("*.lan", "*.local", "*.localhost", "+.msftconnecttest.com", "+.msftncsi.com", "+.u8m1xiygn.sbs", "+.shcgcbzwq.sbs")
    }
} | ConvertTo-Json -Depth 5
try {
    Invoke-RestMethod -Uri "$apiBase/configs" -Method Patch -Headers $headers -Body $patchJson -TimeoutSec 10
    Write-Ok "DNS PATCH applied (chrome fingerprint + UDP DNS + fake-ip-filter)"
} catch {
    Write-Bad "DNS PATCH failed: $($_.Exception.Message)"
}
Start-Sleep 3

# Step 12: Node delay test (HK + US)
Write-Step 12 $totalSteps "Node delay testing (HK + US verification)"

# UTF-8 safe URL encoding (fixes PowerShell 5.1 emoji double-encoding bug)
function UrlEncode-Utf8($str) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($str)
    $result = ""
    foreach ($b in $bytes) {
        if (($b -ge 65 -and $b -le 90) -or ($b -ge 97 -and $b -le 122) -or ($b -ge 48 -and $b -le 57) -or $b -in @(45, 46, 95, 126)) {
            $result += [char]$b
        } else {
            $result += '%' + $b.ToString('X2')
        }
    }
    return $result
}

function Test-NodeDelay($nodeName) {
    $encoded = UrlEncode-Utf8 $nodeName
    $url = "$apiBase/proxies/$encoded/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("Authorization", "Bearer set-your-secret")
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $resp = $wc.DownloadString($url)
        $json = $resp | ConvertFrom-Json
        return $json.delay
    } catch {
        return -1
    }
}

function Test-Nodes {
    param([int]$Attempt)
    Write-Info "--- Attempt $Attempt ---"
    # MUST use WebClient with UTF-8 to fetch proxy list (Invoke-RestMethod has Latin-1 encoding bug in PS 5.1)
    $wcProxy = New-Object System.Net.WebClient
    $wcProxy.Headers.Add("Authorization", "Bearer set-your-secret")
    $wcProxy.Encoding = [System.Text.Encoding]::UTF8
    $proxyJson = $wcProxy.DownloadString("$apiBase/proxies")
    $proxies = $proxyJson | ConvertFrom-Json
    $allNodes = $proxies.proxies.PSObject.Properties | Where-Object { $_.Value.type -in @("trojan","ss","vmess","vless","hysteria2","hysteria") }
    Write-Info "Total proxy nodes found: $($allNodes.Count)"

    # Test HK nodes
    $hkNodes = $allNodes | Where-Object { $_.Name -match "(?i)(hong\s*kong|HK|hongkong)" } | Get-Random -Count 3
    $hkPass = 0
    Write-Info "Testing HK nodes..."
    foreach ($node in $hkNodes) {
        $name = $node.Name
        $delay = Test-NodeDelay $name
        if ($delay -gt 0 -and $delay -lt 500) {
            Write-Ok "  $name : ${delay}ms"
            $hkPass++
        } elseif ($delay -gt 0) {
            Write-Bad "  $name : ${delay}ms (abnormal)"
        } else {
            Write-Bad "  $name : TIMEOUT"
        }
    }

    # Test US nodes
    $usNodes = $allNodes | Where-Object { $_.Name -match "(?i)(united\s*states|US|Seattle|Los Angeles|San Jose)" } | Get-Random -Count 3
    $usPass = 0
    Write-Info "Testing US nodes..."
    foreach ($node in $usNodes) {
        $name = $node.Name
        $delay = Test-NodeDelay $name
        if ($delay -gt 0 -and $delay -lt 1000) {
            Write-Ok "  $name : ${delay}ms"
            $usPass++
        } elseif ($delay -gt 0) {
            Write-Bad "  $name : ${delay}ms (abnormal)"
        } else {
            Write-Bad "  $name : TIMEOUT"
        }
    }

    return @{ HK = $hkPass; US = $usPass; Total = ($hkPass + $usPass) }
}

$testResult = Test-Nodes -Attempt 1

# Retry logic if insufficient passes
if ($testResult.Total -lt 4) {
    Write-Warn "Only $($testResult.Total)/6 nodes passed. Retrying with adapter reset..."
    # Stop Clash
    Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
    & taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
    Start-Sleep 2
    # Re-reset WLAN
    $wlan2 = Get-NetAdapter | Where-Object { $_.Name -match "Wi-Fi|WLAN" -and $_.Status -eq "Up" }
    if ($wlan2) {
        Disable-NetAdapter -Name $wlan2.Name -Confirm:$false
        Start-Sleep -Seconds 3
        Enable-NetAdapter -Name $wlan2.Name -Confirm:$false
        Start-Sleep -Seconds 5
        Write-Ok "WLAN adapter reset again"
    }
    & ipconfig /flushdns 2>$null | Out-Null
    # Restart Clash
    Start-Process $exePath
    Start-Sleep 15
    # Wait for API
    for ($w = 0; $w -lt 60; $w += 2) {
        try { $null = Invoke-RestMethod -Uri "$apiBase/configs" -Headers $headers -TimeoutSec 3; break } catch { Start-Sleep 2 }
    }
    # Re-PATCH
    try { Invoke-RestMethod -Uri "$apiBase/configs" -Method Patch -Headers $headers -Body $patchJson -TimeoutSec 10 } catch {}
    Start-Sleep 3
    # Re-test
    $testResult = Test-Nodes -Attempt 2
}

# Step 13: Connectivity verification
Write-Step 13 $totalSteps "Proxy connectivity verification"
$connOk = $false
try {
    $connTest = Invoke-WebRequest -Uri "http://www.gstatic.com/generate_204" -Proxy "http://127.0.0.1:7897" -TimeoutSec 15 -UseBasicParsing
    if ($connTest.StatusCode -eq 204) {
        Write-Ok "Google 204 via proxy: OK"
        $connOk = $true
    }
} catch {
    Write-Bad "Google 204 via proxy: FAILED"
}

# == FINAL VERDICT ==

Write-Host ""
Write-Host "======================================================" -ForegroundColor White

if ($testResult.Total -ge 4 -and $connOk) {
    Write-Host "  FIX SUCCESSFUL!" -ForegroundColor Green
    Write-Host "  $($testResult.Total)/6 nodes responding | HK: $($testResult.HK)/3 | US: $($testResult.US)/3" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "  Applied fixes:" -ForegroundColor Cyan
    Write-Host "    - WLAN adapter reset (DPI RST cache cleared)" -ForegroundColor White
    Write-Host "    - global-client-fingerprint: chrome" -ForegroundColor White
    Write-Host "    - UDP DNS (119.29.29.29, 223.5.5.5)" -ForegroundColor White
    Write-Host "    - fake-ip-filter: +.u8m1xiygn.sbs, +.shcgcbzwq.sbs" -ForegroundColor White
    Write-Host "    - Startup guard registered" -ForegroundColor White
    Write-Host "  PASS" -ForegroundColor Green
} elseif ($testResult.Total -ge 4) {
    Write-Host "  PARTIAL SUCCESS" -ForegroundColor Yellow
    Write-Host "  Nodes OK ($($testResult.Total)/6) but proxy connectivity test failed" -ForegroundColor Yellow
    Write-Host "======================================================" -ForegroundColor White
    Write-Host "  Try: Switch to a different node in Clash UI" -ForegroundColor Yellow
} else {
    Write-Host "  FIX FAILED" -ForegroundColor Red
    Write-Host "  Only $($testResult.Total)/6 nodes passed after 2 attempts" -ForegroundColor Red
    Write-Host "======================================================" -ForegroundColor White
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "    1. Restart your router (power off 30s, then on)" -ForegroundColor White
    Write-Host "    2. Wait 2 minutes for network to stabilize" -ForegroundColor White
    Write-Host "    3. Run this script again" -ForegroundColor White
    Write-Host "    4. If still failing: your ISP may be actively blocking" -ForegroundColor White
    Write-Host "  FAIL" -ForegroundColor Red
}

Write-Host ""
pause
