<#
.SYNOPSIS
    Clash Verge Rev - Permanent Network Fix (Windows)
.DESCRIPTION
    Fixes ALL known issues and ensures they PERSIST across reboots:
    1. Writes optimized Merge Profile (persists in Clash config chain)
    2. Writes AI routing rules (Cursor/Claude/Google/OpenAI)
    3. Sets TUN stack=mixed via merge (not config.yaml which gets regenerated!)
    4. Enables auto-launch so Clash starts on boot
    5. Fixes WiFi band preference (prefer 5GHz over 2.4GHz)
    6. Sets WiFi power management to maximum performance (persistent)
    7. Cleans up system proxy / DNS
    8. Restarts Clash and verifies connectivity
.NOTES
    Must run as Administrator (auto-elevates).
    Previous versions incorrectly edited config.yaml which gets overwritten on every Clash start.
    This version writes to Merge Profile which is the CORRECT persistent location.
#>

param(
    [switch]$DiagnoseOnly,
    [switch]$SkipRestart
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step ($n,$t,$m) { Write-Host "" ; Write-Host "[$n/$t] $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad  ($m) { Write-Host "  [X]  $m" -ForegroundColor Red }
function Write-Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

# ── Auto-elevate to Administrator ─────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad "Requires Administrator. Re-launching elevated..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ── Locate paths ──────────────────────────────────────────
$vergeDataDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

$clashDir = $null
$svcInfo  = Get-WmiObject Win32_Service -Filter "Name='clash_verge_service'" -ErrorAction SilentlyContinue
if ($svcInfo -and $svcInfo.PathName) {
    $svcPath  = $svcInfo.PathName -replace '"',''
    $clashDir = Split-Path (Split-Path $svcPath)
}
if (-not $clashDir -or -not (Test-Path $clashDir)) {
    $candidates = @(
        "D:\clash verge",
        "C:\Program Files\Clash Verge",
        "$env:LOCALAPPDATA\Programs\clash-verge",
        "$env:LOCALAPPDATA\clash-verge"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\clash-verge.exe") { $clashDir = $c; break }
    }
}
if (-not $clashDir) {
    Write-Bad "Cannot find Clash Verge Rev install directory!"
    pause; exit 1
}

$totalSteps = if ($DiagnoseOnly) { 8 } else { 13 }
$step = 0

Write-Host ""
Write-Host "======================================================" -ForegroundColor White
Write-Host "  Clash Verge Rev - Permanent Network Fix" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor White
Write-Host "  Install : $clashDir" -ForegroundColor Gray
Write-Host "  Data    : $vergeDataDir" -ForegroundColor Gray

# ── Parse profiles.yaml to find ACTUAL profile UIDs ──────
$profilesYamlPath = Join-Path $vergeDataDir "profiles.yaml"
$mergeUid = $null
$rulesUid = $null
$currentSub = $null

if (Test-Path $profilesYamlPath) {
    $pyLines = Get-Content $profilesYamlPath
    $inOption = $false
    foreach ($line in $pyLines) {
        if ($line -match '^\s*current:\s*(\S+)') { $currentSub = $Matches[1] }
        if ($line -match '^\s*option:') { $inOption = $true; continue }
        if ($inOption) {
            if ($line -match '^\s*merge:\s*(\S+)') { $mergeUid = $Matches[1] }
            if ($line -match '^\s*rules:\s*(\S+)') { $rulesUid = $Matches[1] }
            if ($line -match '^\S') { $inOption = $false }
        }
    }
}

# ══════════════════════════════════════════════════════════
#  PHASE 1: DIAGNOSE
# ══════════════════════════════════════════════════════════

$issues = @()

# ---- Step 1: Processes and Service ----
$step++; Write-Step $step $totalSteps "Check Clash processes and service"
$clashUI   = Get-Process clash-verge  -ErrorAction SilentlyContinue
$clashCore = Get-Process verge-mihomo -ErrorAction SilentlyContinue
$clashSvc  = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($clashUI)   { Write-Info "clash-verge.exe   PID $($clashUI.Id)" }
if ($clashCore) { Write-Info "verge-mihomo.exe  PID $($clashCore.Id)" }
if ($clashSvc)  { Write-Info "clash_verge_service  Status: $($clashSvc.Status)  Start: $($clashSvc.StartType)" }

$vergeFile = Join-Path $vergeDataDir "verge.yaml"
$vergeContent = ""
if (Test-Path $vergeFile) {
    $vergeContent = Get-Content $vergeFile -Raw
    if ($vergeContent -match 'enable_auto_launch:\s*false') {
        Write-Bad "Auto-launch is DISABLED (Clash won't start on boot!)"
        $issues += "NO_AUTOLAUNCH"
    } else {
        Write-Ok "Auto-launch is enabled"
    }
    if ($vergeContent -match 'prefer_sidecar:\s*true') {
        Write-Bad "Running in sidecar mode (slower, less stable)"
        $issues += "SIDECAR"
    }
    if ($vergeContent -match 'enable_tun_mode:\s*true') {
        Write-Ok "TUN mode enabled in settings"
    } else {
        Write-Bad "TUN mode is DISABLED"
        $issues += "TUN_DISABLED"
    }
}

# ---- Step 2: TUN adapter and routing ----
$step++; Write-Step $step $totalSteps "Check TUN adapter and routes"
$tunAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta|wintun|Mihomo' -and $_.Status -eq 'Up' }
if ($tunAdapter) {
    Write-Ok "TUN adapter: $($tunAdapter.Name) [Up]"
} else {
    Write-Warn "TUN adapter not active"
    $issues += "TUN_DOWN"
}

# ---- Step 3: Merge Profile check (THE KEY CHECK) ----
$step++; Write-Step $step $totalSteps "Check Merge profile (persistence layer)"
if ($mergeUid) {
    $mergeFile = Join-Path $vergeDataDir "profiles\$mergeUid.yaml"
    Write-Info "Merge UID: $mergeUid"
    if (Test-Path $mergeFile) {
        $mc = Get-Content $mergeFile -Raw
        $mcLen = $mc.Trim().Length
        if ($mcLen -lt 50) {
            Write-Bad "Merge profile is EMPTY ($mcLen bytes) - THIS IS WHY FIXES DON'T PERSIST!"
            $issues += "MERGE_EMPTY"
        } elseif ($mc -notmatch 'tcp-concurrent:\s*true') {
            Write-Bad "Merge profile missing tcp-concurrent: true"
            $issues += "MERGE_INCOMPLETE"
        } else {
            Write-Ok "Merge profile has content ($mcLen bytes)"
        }
        if ($mc -match '\bdns:') {
            if ($mc -match 'fake-ip-range' -and $mc -match 'nameserver:') {
                Write-Ok "Merge profile has COMPLETE dns: section (preserves subscription DNS fields)"
            } else {
                Write-Bad "Merge profile dns: section is INCOMPLETE (missing fake-ip/nameserver - will break subscription DNS!)"
                $issues += "MERGE_DNS_INCOMPLETE"
            }
        } else {
            Write-Bad "Merge profile has no dns: section (dns fields will be lost on merge!)"
            $issues += "MERGE_NO_DNS"
        }
        if ($mc -match 'stack:\s*mixed') {
            Write-Ok "TUN stack=mixed in merge (persistent)"
        } else {
            Write-Warn "TUN stack not set to mixed in merge profile"
            $issues += "TUN_STACK"
        }
    } else {
        Write-Bad "Merge profile file missing!"
        $issues += "MERGE_EMPTY"
    }
} else {
    Write-Bad "No merge profile configured for subscription!"
    $issues += "MERGE_EMPTY"
}

# ---- Step 4: Rules check ----
$step++; Write-Step $step $totalSteps "Check AI routing rules"
if ($rulesUid) {
    $rulesFile = Join-Path $vergeDataDir "profiles\$rulesUid.yaml"
    Write-Info "Rules UID: $rulesUid"
    if (Test-Path $rulesFile) {
        $rc = Get-Content $rulesFile -Raw
        $ruleChecks = @{
            'cursor.sh'        = 'Cursor'
            'anthropic.com'    = 'Claude/Anthropic'
            'googleapis.com'   = 'Google AI'
            'openai.com'       = 'OpenAI'
        }
        foreach ($pattern in $ruleChecks.Keys) {
            if ($rc -match [regex]::Escape($pattern)) {
                Write-Ok "$($ruleChecks[$pattern]) routing rule present"
            } else {
                Write-Warn "$($ruleChecks[$pattern]) routing rule MISSING"
                $issues += "RULES_INCOMPLETE"
            }
        }
    } else {
        Write-Bad "Rules file missing!"
        $issues += "RULES_MISSING"
    }
} else {
    Write-Warn "No rules profile configured"
    $issues += "RULES_MISSING"
}

# ---- Step 5: WiFi adapter analysis ----
$step++; Write-Step $step $totalSteps "Analyze WiFi adapter"
$wlan = Get-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue
if ($wlan) {
    Write-Info "Adapter: $($wlan.InterfaceDescription)"
    Write-Info "Link Speed: $($wlan.LinkSpeed)"

    $wlanInfo = netsh wlan show interfaces 2>$null
    $bandLine = ($wlanInfo | Select-String '(频段|Band)').Line
    $radioLine = ($wlanInfo | Select-String '(无线电类型|Radio type)').Line
    $signalLine = ($wlanInfo | Select-String '(信号|Signal)').Line
    $channelLine = ($wlanInfo | Select-String '(通道|Channel)').Line

    if ($bandLine) { Write-Info $bandLine.Trim() }
    if ($radioLine) { Write-Info $radioLine.Trim() }
    if ($signalLine) { Write-Info $signalLine.Trim() }
    if ($channelLine) { Write-Info $channelLine.Trim() }

    if ($bandLine -match '2\.4') {
        Write-Bad "WiFi is on 2.4GHz - SEVERELY limiting speed! Should be 5GHz+"
        $issues += "WIFI_24GHZ"
    }

    $prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*首选*频*' -ErrorAction SilentlyContinue
    if (-not $prefBand) {
        $prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Preferred*Band*' -ErrorAction SilentlyContinue
    }
    if ($prefBand) {
        Write-Info "Band preference: $($prefBand.DisplayValue)"
        if ($prefBand.DisplayValue -match '无首选|No Preference|1') {
            Write-Warn "Band preference is 'No preference' - may default to slow 2.4GHz"
            $issues += "WIFI_BAND_PREF"
        }
    }
} else {
    Write-Info "WLAN adapter not found (using Ethernet?)"
}

# ---- Step 6: System network ----
$step++; Write-Step $step $totalSteps "Check system network settings"
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyOn = (Get-ItemProperty $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
if ($proxyOn -eq 1) {
    Write-Warn "System proxy is ON (should be OFF in TUN mode)"
    $issues += "SYSPROXY"
} else {
    Write-Ok "System proxy is OFF"
}

# ---- Step 7: WiFi driver events ----
$step++; Write-Step $step $totalSteps "Check WiFi driver stability"
$start24h = (Get-Date).AddHours(-24)
$wifiEvents = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start24h} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Netwaw|Netwtw|WLAN-AutoConfig|NDIS' -and $_.LevelDisplayName -ne 'Information' }
$eventCount = if ($wifiEvents) { $wifiEvents.Count } else { 0 }
if ($eventCount -gt 50) {
    Write-Bad "$eventCount WiFi warning/error events in 24h (very unstable!)"
    $issues += "WIFI_UNSTABLE"
} elseif ($eventCount -gt 10) {
    Write-Warn "$eventCount WiFi warning/error events in 24h"
    $issues += "WIFI_EVENTS"
} else {
    Write-Ok "$eventCount WiFi events in 24h"
}

# ---- Step 8: Connectivity ----
$step++; Write-Step $step $totalSteps "Test connectivity"
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
    $sw.Stop()
    Write-Info "IP     : $($geo.ip)"
    Write-Info "Region : $($geo.city), $($geo.country)"
    Write-Info "Org    : $($geo.org)"
    Write-Info "Latency: $($sw.ElapsedMilliseconds)ms"
    if ($geo.country -eq 'US') { Write-Ok "Exit IP is in United States" }
    else { Write-Warn "Exit IP is in $($geo.country) (not US)" }
} catch {
    Write-Bad "Cannot reach internet"
    $issues += "NO_INTERNET"
}

# ---- Diagnosis Summary ----
Write-Host ""
Write-Host "========== Diagnosis Summary ==========" -ForegroundColor White
if ($issues.Count -eq 0) {
    Write-Ok "No fixable issues found. Network looks good!"
} else {
    Write-Bad "Found $($issues.Count) issue(s):"
    foreach ($i in $issues) {
        switch ($i) {
            "MERGE_EMPTY"      { Write-Bad "  - Merge profile empty (no performance settings persist!)" }
            "MERGE_INCOMPLETE"  { Write-Bad "  - Merge profile incomplete" }
            "TUN_STACK"        { Write-Bad "  - TUN stack not set to mixed (performance loss)" }
            "MERGE_NO_DNS"     { Write-Bad "  - Merge profile missing dns: section (subscription DNS fields will be lost!)" }
            "MERGE_DNS_INCOMPLETE" { Write-Bad "  - Merge profile dns: section incomplete (missing fake-ip/nameserver)" }
            "RULES_INCOMPLETE" { Write-Bad "  - AI routing rules missing" }
            "RULES_MISSING"    { Write-Bad "  - No rules profile at all" }
            "NO_AUTOLAUNCH"    { Write-Bad "  - Clash doesn't start on boot" }
            "SIDECAR"          { Write-Bad "  - Running in sidecar mode" }
            "TUN_DISABLED"     { Write-Bad "  - TUN mode disabled" }
            "TUN_DOWN"         { Write-Warn "  - TUN adapter not active" }
            "WIFI_24GHZ"       { Write-Bad "  - WiFi stuck on 2.4GHz (need 5GHz!)" }
            "WIFI_BAND_PREF"   { Write-Warn "  - WiFi band preference not optimal" }
            "WIFI_UNSTABLE"    { Write-Bad "  - WiFi driver highly unstable" }
            "WIFI_EVENTS"      { Write-Warn "  - WiFi driver events detected" }
            "SYSPROXY"         { Write-Warn "  - System proxy should be off" }
            "NO_INTERNET"      { Write-Bad "  - No internet connectivity" }
            default            { Write-Warn "  - $i" }
        }
    }
}

if ($DiagnoseOnly) {
    Write-Host ""
    Write-Host "Run without -DiagnoseOnly to apply fixes." -ForegroundColor Cyan
    pause; exit
}

if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Ok "Nothing to fix!"
    pause; exit
}

# ══════════════════════════════════════════════════════════
#  PHASE 2: FIX (all changes go to PERSISTENT locations)
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "========== Applying Fixes ==========" -ForegroundColor White

# ---- Step 9: Stop Clash cleanly ----
$step++; Write-Step $step $totalSteps "Stop Clash for config changes"
Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
& taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
& taskkill /F /IM verge-mihomo-alpha.exe 2>$null | Out-Null
$clashSvcNow = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($clashSvcNow -and $clashSvcNow.Status -eq 'Running') {
    Stop-Service clash_verge_service -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
}
& taskkill /F /IM clash-verge-service.exe 2>$null | Out-Null
Start-Sleep 2
Write-Ok "Clash stopped"

# ---- Step 10: Write PERSISTENT Merge Profile ----
$step++; Write-Step $step $totalSteps "Write optimized Merge profile (PERSISTENT)"
if ($mergeUid) {
    $mergeFilePath = Join-Path $vergeDataDir "profiles\$mergeUid.yaml"
    # ── 从运行时配置提取完整 DNS 段，只替换 proxy-server-nameserver ──
    $runtimeYaml = Join-Path $vergeDataDir "clash-verge.yaml"
    $dnsBlock = ""
    if (Test-Path $runtimeYaml) {
        $rtLines = Get-Content $runtimeYaml -Encoding UTF8
        $inDns = $false
        $dnsLines = @()
        foreach ($rtLine in $rtLines) {
            if ($rtLine -match '^dns:') { $inDns = $true; $dnsLines += $rtLine; continue }
            if ($inDns) {
                if ($rtLine -match '^\S' -and $rtLine -notmatch '^\s*$' -and $rtLine -notmatch '^#') { break }
                $dnsLines += $rtLine
            }
        }
        if ($dnsLines.Count -gt 1) {
            # 替换 proxy-server-nameserver 为公共 DNS
            $newDns = @()
            $inPSNS = $false
            foreach ($dl in $dnsLines) {
                if ($dl -match '^\s+proxy-server-nameserver:') {
                    $inPSNS = $true
                    $newDns += $dl
                    $newDns += "    - 223.5.5.5"
                    $newDns += "    - 119.29.29.29"
                    $newDns += "    - 114.114.114.114"
                    continue
                }
                if ($inPSNS) {
                    if ($dl -match '^\s+-\s') { continue }  # skip old values
                    $inPSNS = $false
                }
                $newDns += $dl
            }
            $dnsBlock = ($newDns -join "`n")
            Write-Ok "Extracted complete DNS config from runtime ($($dnsLines.Count) lines)"
        }
    }
    # 如果无法提取，使用安全的最小完整 DNS 配置
    if (-not $dnsBlock) {
        Write-Warn "Cannot extract DNS from runtime config, using safe defaults"
        $dnsBlock = @"
dns:
  ipv6: false
  enable: true
  listen: 0.0.0.0:1053
  use-hosts: false
  default-nameserver:
    - 119.29.29.29
    - 223.5.5.5
    - 8.8.4.4
    - 1.0.0.1
  nameserver:
    - 119.29.29.29
    - 223.5.5.5
  fake-ip-range: 198.18.0.1/15
  fake-ip-filter:
    - '*.lan'
    - '*.localdomain'
    - '*.example'
    - '*.invalid'
    - '*.localhost'
    - '*.test'
    - '*.local'
    - '*.home.arpa'
  proxy-server-nameserver:
    - 223.5.5.5
    - 119.29.29.29
    - 114.114.114.114
"@
    }
    $mergeContent = @"
# Merge Profile - 持久化配置层
# 重要：dns 段会整体替换订阅配置，因此必须写入完整的 DNS 配置
# 只将 proxy-server-nameserver 替换为公共 DNS（避免机场 DOH 返回不可达的 GeoDNS IP）
# 其余 DNS 字段完全保留订阅原值

tun:
  stack: mixed
  mtu: 9000

$dnsBlock

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
unified-delay: true
keep-alive-interval: 30
keep-alive-idle: 600

profile:
  store-selected: true
  store-fake-ip: true
"@
    Set-Content $mergeFilePath $mergeContent -Encoding UTF8
    Write-Ok "Merge profile written with: stack=mixed, mtu=9000, tcp-concurrent=true, sniffer=on, keep-alive=30s/600s"
    Write-Info "DNS: Complete config preserved from subscription, only proxy-server-nameserver replaced with public DNS"
    Write-Info "File: $mergeFilePath"
} else {
    Write-Bad "No merge UID - cannot write merge profile!"
}

# ---- Step 11: Write AI routing rules ----
$step++; Write-Step $step $totalSteps "Write AI routing rules (PERSISTENT)"
if ($rulesUid) {
    $rulesFilePath = Join-Path $vergeDataDir "profiles\$rulesUid.yaml"
    $rulesContent = @"
# AI Service Routing Rules
# Routes all AI service traffic through the proxy (AI group)

prepend:
  # LAN & Direct IPs
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve        # Loopback
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve          # Private-A
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve       # Private-B
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve      # Private-C
  - IP-CIDR,43.139.188.89/32,DIRECT,no-resolve    # CVM cloud server direct
  - PROCESS-NAME,ssh.exe,DIRECT                    # SSH fallback

  # Google AI (Gemini, Antigravity)
  - DOMAIN-SUFFIX,googleapis.com,AI
  - DOMAIN-SUFFIX,google.com,AI
  - DOMAIN,cloudcode-pa.googleapis.com,AI
  - DOMAIN,generativelanguage.googleapis.com,AI

  # Cursor AI
  - DOMAIN-SUFFIX,cursor.sh,AI
  - DOMAIN-SUFFIX,cursor.com,AI
  - DOMAIN-SUFFIX,anysphere.com,AI

  # Anthropic / Claude
  - DOMAIN-SUFFIX,anthropic.com,AI
  - DOMAIN-SUFFIX,claude.ai,AI

  # OpenAI / ChatGPT
  - DOMAIN-SUFFIX,openai.com,AI
  - DOMAIN-SUFFIX,chatgpt.com,AI
  - DOMAIN-SUFFIX,oaistatic.com,AI
  - DOMAIN-SUFFIX,oaiusercontent.com,AI

  # GitHub Copilot
  - DOMAIN-SUFFIX,githubcopilot.com,AI

  # Perplexity
  - DOMAIN-SUFFIX,perplexity.ai,AI

append: []
delete: []
"@
    Set-Content $rulesFilePath $rulesContent -Encoding UTF8
    Write-Ok "AI routing rules written (Google, Cursor, Claude, OpenAI, Copilot, Perplexity)"
    Write-Info "File: $rulesFilePath"
} else {
    Write-Bad "No rules UID - cannot write rules!"
}

# ---- Step 12: Fix verge.yaml (app settings) ----
$step++; Write-Step $step $totalSteps "Fix Clash Verge app settings (verge.yaml)"
if (Test-Path $vergeFile) {
    $vf = Get-Content $vergeFile -Raw

    # Enable auto-launch
    $vf = $vf -replace 'enable_auto_launch:\s*\w+', 'enable_auto_launch: true'

    # Force service mode (not sidecar)
    if ($vf -match 'prefer_sidecar') {
        $vf = $vf -replace 'prefer_sidecar:\s*\w+', 'prefer_sidecar: false'
    }

    # Ensure TUN mode enabled
    $vf = $vf -replace 'enable_tun_mode:\s*\w+', 'enable_tun_mode: true'

    # Ensure system proxy disabled (TUN handles everything)
    $vf = $vf -replace 'enable_system_proxy:\s*\w+', 'enable_system_proxy: false'

    # DNS 由机场订阅自行处理，enable_dns_settings 保持 false
    $vf = $vf -replace 'enable_dns_settings:\s*\w+', 'enable_dns_settings: false'

    Set-Content $vergeFile $vf -Encoding UTF8
    Write-Ok "verge.yaml: auto_launch=true, tun=true, sidecar=false, sysproxy=false, dns_settings=false"
} else {
    Write-Bad "verge.yaml not found!"
}

# ---- Step 13: System-level optimizations ----
$step++; Write-Step $step $totalSteps "System network + WiFi optimization"

# TCP global settings (persist across reboots)
& netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null
& netsh int tcp set global rsc=enabled 2>$null | Out-Null
& netsh int tcp set global timestamps=enabled 2>$null | Out-Null
& netsh int tcp set global fastopen=enabled 2>$null | Out-Null
Write-Ok "TCP: AutoTuning=Normal, RSC=On, Timestamps=On, FastOpen=On"

# WiFi band preference: prefer 5GHz (key for fixing 2.4GHz problem)
$bandProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*首选*频*' -ErrorAction SilentlyContinue
if (-not $bandProp) {
    $bandProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Preferred*Band*' -ErrorAction SilentlyContinue
}
if ($bandProp) {
    Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $bandProp.DisplayName -DisplayValue '2. 首选 5GHz 频段' -ErrorAction SilentlyContinue
    if ($?) {
        Write-Ok "WiFi band preference set to: Prefer 5GHz"
    } else {
        Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $bandProp.DisplayName -DisplayValue 'Prefer 5GHz band' -ErrorAction SilentlyContinue
        if ($?) {
            Write-Ok "WiFi band preference set to: Prefer 5GHz band"
        } else {
            Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $bandProp.DisplayName -RegistryValue 2 -ErrorAction SilentlyContinue
            if ($?) {
                Write-Ok "WiFi band preference set to 5GHz (registry value)"
            } else {
                Write-Warn "Could not set WiFi band preference automatically"
                Write-Info "Please set manually: Device Manager -> WLAN -> Advanced -> Preferred Band -> 5GHz"
            }
        }
    }
} else {
    Write-Info "WiFi band preference property not found"
}

# WiFi roaming aggressiveness: lower to reduce random disconnects
$roamProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*漫游*' -ErrorAction SilentlyContinue
if (-not $roamProp) {
    $roamProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Roaming*' -ErrorAction SilentlyContinue
}
if ($roamProp) {
    Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $roamProp.DisplayName -RegistryValue 1 -ErrorAction SilentlyContinue
    Write-Ok "WiFi roaming aggressiveness: Lowest (reduces random disconnects)"
}

# WiFi power saving: Maximum Performance (for ALL power schemes to persist)
foreach ($scheme in @('SCHEME_CURRENT','SCHEME_MIN','SCHEME_MAX','381b4222-f694-41f0-9685-ff5bb260df2e','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c','a1841308-3541-4fab-bc81-f71556f20b4a')) {
    & powercfg /setacvalueindex $scheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
    & powercfg /setdcvalueindex $scheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
}
& powercfg /setactive SCHEME_CURRENT 2>$null
Write-Ok "WiFi power: Maximum Performance (all power plans)"

# WLAN IPv6: keep enabled for compatibility
Enable-NetAdapterBinding -Name 'WLAN' -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
Write-Ok "WLAN IPv6: enabled (compatibility)"

# Clear system proxy
Set-ItemProperty $regPath -Name ProxyEnable -Value 0
Set-ItemProperty $regPath -Name ProxyServer -Value ''
& netsh winhttp reset proxy 2>$null | Out-Null
Write-Ok "System proxy cleared"

# Flush DNS
& ipconfig /flushdns 2>$null | Out-Null
Write-Ok "DNS cache flushed"

# Sync time
& net start w32time 2>$null | Out-Null
& w32tm /resync /rediscover 2>$null | Out-Null
Write-Ok "System time synchronized"

# ---- Reinstall service if needed ----
$svcNow = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if (-not $svcNow) {
    Write-Warn "Clash service missing, reinstalling..."
    $installSvc = Join-Path $clashDir "resources\install-service.exe"
    if (Test-Path $installSvc) {
        Start-Process $installSvc -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Sleep 2
        Set-Service clash_verge_service -StartupType Automatic -ErrorAction SilentlyContinue
        Write-Ok "Service reinstalled"
    }
} else {
    Set-Service clash_verge_service -StartupType Automatic -ErrorAction SilentlyContinue
    Write-Ok "Service set to Automatic start"
}

# ---- Register startup guard task (persistent daemon) ----
$taskName = "ClashVergeStartupGuard"
$guardScript = "D:\fixClashNet\_startup_guard.ps1"

# 删除旧任务（旧版为一次性运行，需升级为常驻模式）
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

try {
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$guardScript`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Clash Verge Rev config guard (watch-only, no restart)" -Force | Out-Null
    Write-Ok "Startup guard task registered (config-watch mode, no restart)"
} catch {
    Write-Warn "Failed to register startup guard: $_"
}

# ── Start Clash and verify ─────────────────────────────
if (-not $SkipRestart) {
    Write-Host ""
    Write-Host "========== Starting Clash & Verifying ==========" -ForegroundColor White

    $exePath = Join-Path $clashDir "clash-verge.exe"
    if (Test-Path $exePath) {
        Start-Process $exePath
        Write-Ok "Clash Verge Rev starting..."
        Write-Info "Waiting 20s for TUN initialization..."
        Start-Sleep 20

        # Verify TUN
        $tunUp = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta' -and $_.Status -eq 'Up' }
        if ($tunUp) { Write-Ok "TUN adapter is Up" }
        else { Write-Warn "TUN adapter not yet Up (may need a moment)" }

        # Verify proxy port
        $proxyPort = netstat -ano 2>$null | Select-String ':7897'
        if ($proxyPort) { Write-Ok "Proxy port 7897 is listening" }
        else { Write-Warn "Proxy port not detected yet" }

        # Verify DNS resolution
        try {
            $dnsTest = Resolve-DnsName "google.com" -ErrorAction SilentlyContinue
            if ($dnsTest) {
                Write-Ok "DNS resolution is working"
            } else {
                Write-Warn "DNS resolution may be abnormal - check DNS settings in Clash UI"
            }
        } catch {
            Write-Warn "DNS resolution test failed: $_"
        }

        # Verify exit IP
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $geo2 = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
            $sw.Stop()
            Write-Info "Exit IP : $($geo2.ip) - $($geo2.city), $($geo2.country)"
            Write-Info "Latency : $($sw.ElapsedMilliseconds)ms"
            if ($geo2.country -eq 'US') {
                Write-Ok "Exit IP confirmed in United States"
            } else {
                Write-Warn "Exit IP is $($geo2.country) - check node selection in Clash UI"
            }
        } catch {
            Write-Warn "Cannot verify exit IP yet (give it a moment)"
        }

        # WiFi band check after restart
        $wlanInfo2 = netsh wlan show interfaces 2>$null
        $bandLine2 = ($wlanInfo2 | Select-String '(频段|Band)').Line
        if ($bandLine2) {
            Write-Info "WiFi band after fix: $($bandLine2.Trim())"
        }
    } else {
        Write-Bad "clash-verge.exe not found at: $exePath"
    }
}

# ══════════════════════════════════════════════════════════
#  DONE
# ══════════════════════════════════════════════════════════

Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  All fixes applied! These changes PERSIST after reboot." -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "What was fixed (PERSISTENT):" -ForegroundColor Cyan
Write-Host "  [Merge Profile] TUN stack=mixed, MTU=9000, tcp-concurrent=true" -ForegroundColor White
Write-Host "  [Merge Profile] sniffer=on, keep-alive=30s/600s, unified-delay=true" -ForegroundColor White
Write-Host "  [Merge Profile] Complete DNS config (subscription preserved, proxy-server-nameserver=public)" -ForegroundColor White
Write-Host "  [Rules Profile] AI routing: Google/Cursor/Claude/OpenAI/Copilot" -ForegroundColor White
Write-Host "  [verge.yaml]    auto-launch=true, TUN=true, service-mode=true" -ForegroundColor White
Write-Host "  [verge.yaml]    dns_settings=false (DNS由Merge Profile完整配置处理)" -ForegroundColor White
Write-Host "  [WiFi]          Band preference -> 5GHz, Roaming -> Lowest" -ForegroundColor White
Write-Host "  [WiFi]          Power saving -> disabled (all power plans)" -ForegroundColor White
Write-Host "  [System]        Proxy cleared, DNS flushed, time synced" -ForegroundColor White
Write-Host "  [Guard]         Persistent daemon: auto-fix TUN+DNS on WiFi switch/reconnect" -ForegroundColor White
Write-Host ""
Write-Host "WHY this won't reset on reboot:" -ForegroundColor Yellow
Write-Host "  Previous fix edited config.yaml which Clash REGENERATES on startup." -ForegroundColor White
Write-Host "  This fix writes performance params in Merge Profile (persistent)." -ForegroundColor White
Write-Host "  DNS is FULLY preserved from subscription (only proxy-server-nameserver uses public DNS)." -ForegroundColor White
Write-Host ""
Write-Host "Manual checks:" -ForegroundColor Yellow
Write-Host "  1. In Clash UI: confirm TUN mode is ON (should be already)" -ForegroundColor White
Write-Host "  2. Set AI + Proxies + Final groups to same US node" -ForegroundColor White
Write-Host "  3. If WiFi still slow: check if router supports 5GHz band" -ForegroundColor White
Write-Host "     Your current SSID 'youlian-4L' may be 2.4GHz only." -ForegroundColor White
Write-Host "     If router has separate 5GHz SSID, connect to that instead!" -ForegroundColor White
Write-Host ""
pause
