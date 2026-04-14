<#
.SYNOPSIS
    Clash Verge Rev 网络修复 + 性能调优 (Windows)
.DESCRIPTION
    一键诊断并修复 Clash Verge Rev / Mihomo TUN 模式常见网络问题：
    ① Clash 服务故障 (sidecar fallback / API 不响应)
    ② TUN stack 非最优 (gvisor → mixed)
    ③ TUN MTU 过小 (1500 → 9000)
    ④ tcp-concurrent / keep-alive 未启用
    ⑤ Merge profile 覆盖了机场自带 DNS → 代理服务器解析错误
    ⑥ IPv6 泄漏 / 双栈延迟
    ⑦ WiFi 适配器节能 / 频段未优化
    ⑧ 系统代理残留
    ⑨ Cursor/Claude 缺少 AI 分流规则
.NOTES
    必须以管理员权限运行（脚本自动提权）
    Clash Verge Rev 安装路径自动检测
#>

param(
    [switch]$DiagnoseOnly,
    [switch]$SkipRestart
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step ($n,$t,$m) { Write-Host "`n[$n/$t] $m" -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn ($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad  ($m) { Write-Host "  [X]  $m" -ForegroundColor Red }
function Write-Info ($m) { Write-Host "       $m" -ForegroundColor Gray }

# ── 自动管理员提权 ────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad "需要管理员权限，正在自动提权..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ── 自动检测路径 ──────────────────────────────────────────
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
    foreach ($c in $candidates) { if (Test-Path "$c\clash-verge.exe") { $clashDir = $c; break } }
}
if (-not $clashDir) { Write-Bad "未找到 Clash Verge Rev 安装目录，请检查安装"; pause; exit 1 }

$totalSteps = if ($DiagnoseOnly) { 8 } else { 14 }
$step = 0

Write-Host ""
Write-Host "================================================" -ForegroundColor White
Write-Host "  Clash Verge Rev 网络修复 + 性能调优 (Windows)" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor White
Write-Host "  安装目录: $clashDir" -ForegroundColor Gray
Write-Host "  数据目录: $vergeDataDir" -ForegroundColor Gray

# ══════════════════════════════════════════════════════════
#  阶段一：诊断
# ══════════════════════════════════════════════════════════

$step++; Write-Step $step $totalSteps "检查 Clash 进程 & 服务"
$clashUI   = Get-Process clash-verge -ErrorAction SilentlyContinue
$clashCore = Get-Process verge-mihomo -ErrorAction SilentlyContinue
$clashSvc  = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($clashUI)   { Write-Info "clash-verge.exe        PID $($clashUI.Id)" }
if ($clashCore) { Write-Info "verge-mihomo.exe       PID $($clashCore.Id)" }
if ($clashSvc)  { Write-Info "clash_verge_service    $($clashSvc.Status) / $($clashSvc.StartType)" }
$apiUp = netstat -ano 2>$null | Select-String ':9097|:9090'
if (-not $apiUp) { Write-Warn "Clash API 端口未监听（pipe 模式正常）" }

$step++; Write-Step $step $totalSteps "检查 TUN 网卡 & 路由"
$tunAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta Tunnel|wintun|Mihomo' }
if ($tunAdapter -and $tunAdapter.Status -eq 'Up') { Write-Ok "TUN 网卡: $($tunAdapter.Name) Up" } else { Write-Warn "TUN 网卡未就绪" }
$tunRoute = route print 0.0.0.0 2>$null | Select-String '198\.18\.'
if ($tunRoute) { Write-Info "TUN 路由已注入" }

$step++; Write-Step $step $totalSteps "检查运行时配置"
$configFile = Join-Path $vergeDataDir "config.yaml"
$issues = @()
if (Test-Path $configFile) {
    $cfg = Get-Content $configFile -Raw
    if ($cfg -match 'stack:\s*(\S+)' -and $Matches[1] -ne 'mixed') {
        Write-Bad "TUN stack: $($Matches[1]) → 应为 mixed"; $issues += "TUN_STACK"
    } elseif ($cfg -match 'stack:\s*mixed') { Write-Ok "TUN stack: mixed" }
    if ($cfg -match 'mtu:\s*(\d+)' -and [int]$Matches[1] -lt 9000) {
        Write-Warn "TUN MTU: $($Matches[1]) → 建议 9000"; $issues += "TUN_MTU"
    } elseif ($cfg -match 'mtu:\s*9000') { Write-Ok "TUN MTU: 9000" }
}
$vergeFile = Join-Path $vergeDataDir "verge.yaml"
if (Test-Path $vergeFile) {
    $vf = Get-Content $vergeFile -Raw
    if ($vf -match 'prefer_sidecar:\s*true') { Write-Bad "运行在 sidecar 模式（性能差）"; $issues += "SIDECAR" }
}

$step++; Write-Step $step $totalSteps "检查 DNS 配置"
$mergedCfg = Join-Path $vergeDataDir "clash-verge.yaml"
if (Test-Path $mergedCfg) {
    $mc = Get-Content $mergedCfg -Raw
    if ($mc -match 'nameserver:.*?wrecking|nameserver:.*?carrousel|nameserver:.*?simmering') {
        Write-Ok "DNS 使用机场自带 DOH（正确）"
    } elseif ($mc -match 'nameserver:.*?223\.5\.5\.5') {
        Write-Warn "DNS 被覆盖为国内 DNS → 代理服务器可能解析错误"; $issues += "DNS_OVERRIDE"
    }
}

$step++; Write-Step $step $totalSteps "检查系统网络参数"
$ipv6 = Get-NetAdapterBinding -Name 'WLAN' -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
if ($ipv6 -and $ipv6.Enabled) { Write-Warn "WLAN IPv6 已启用 → 双栈延迟"; $issues += "IPV6" }
else { Write-Ok "WLAN IPv6 已禁用" }

$step++; Write-Step $step $totalSteps "检查 WiFi 适配器"
$wlan = Get-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue
if ($wlan) {
    Write-Info "WiFi: $($wlan.InterfaceDescription) $($wlan.LinkSpeed)"
    $prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'RoamingPreferredBandType' -ErrorAction SilentlyContinue
    if ($prefBand -and $prefBand.RegistryValue -eq 1) { Write-Warn "WiFi 首选频段: 无首选"; $issues += "WIFI_BAND" }
    $tpBoost = Get-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'ThroughputBoosterEnabled' -ErrorAction SilentlyContinue
    if ($tpBoost -and $tpBoost.RegistryValue -eq 0) { Write-Warn "吞吐量增强器: 禁用"; $issues += "WIFI_BOOST" }
}

$step++; Write-Step $step $totalSteps "检查系统代理"
$regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyOn = (Get-ItemProperty $regPath -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
if ($proxyOn -eq 1) { Write-Warn "系统代理已开启 → TUN 模式下应关闭"; $issues += "SYSPROXY" }
else { Write-Ok "系统代理已关闭" }

$step++; Write-Step $step $totalSteps "检测出口 IP & 连通性"
try {
    $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
    Write-Info "IP: $($geo.ip)  地区: $($geo.city), $($geo.country)  机构: $($geo.org)"
    if ($geo.country -eq 'US') { Write-Ok "出口在美国" }
    else { Write-Warn "出口在 $($geo.country)" }
} catch { Write-Warn "无法检测出口 IP" }

Write-Host "`n──── 诊断汇总 ────" -ForegroundColor White
if ($issues.Count -eq 0) { Write-Ok "未发现可修复的问题" }
else { Write-Bad "发现 $($issues.Count) 个问题: $($issues -join ', ')" }
if ($DiagnoseOnly) { pause; exit }

# ══════════════════════════════════════════════════════════
#  阶段二：修复
# ══════════════════════════════════════════════════════════

$step++; Write-Step $step $totalSteps "彻底停止 Clash 所有组件"
Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
taskkill /F /IM verge-mihomo-alpha.exe 2>$null | Out-Null
$svc = Get-Service clash_verge_service -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') { Stop-Service clash_verge_service -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
taskkill /F /IM clash-verge-service.exe 2>$null | Out-Null
Start-Sleep 2
$alive = Get-Process clash-verge,verge-mihomo,clash-verge-service -ErrorAction SilentlyContinue
if (-not $alive) { Write-Ok "所有 Clash 进程已停止" } else { Write-Bad "部分进程无法停止: $($alive.ProcessName -join ', ')" }

$step++; Write-Step $step $totalSteps "重装 Clash 系统服务"
$uninstSvc  = Join-Path $clashDir "resources\uninstall-service.exe"
$installSvc = Join-Path $clashDir "resources\install-service.exe"
if ((Test-Path $uninstSvc) -and (Test-Path $installSvc)) {
    Start-Process $uninstSvc -Wait -NoNewWindow -ErrorAction SilentlyContinue; Start-Sleep 2
    Start-Process $installSvc -Wait -NoNewWindow -ErrorAction SilentlyContinue; Start-Sleep 2
    $newSvc = Get-Service clash_verge_service -ErrorAction SilentlyContinue
    if ($newSvc) { Set-Service clash_verge_service -StartupType Automatic; Write-Ok "服务重装完成 (Automatic)" }
    else { Write-Bad "服务安装失败" }
} else { Write-Warn "未找到服务安装工具 (预期: $clashDir\resources\)" }

if (Test-Path $vergeFile) {
    $vf = Get-Content $vergeFile -Raw
    $vf = $vf -replace 'prefer_sidecar:\s*true', 'prefer_sidecar: false'
    $vf = $vf -replace 'last_error:.*', 'last_error: null'
    $vf = $vf -replace 'enable_dns_settings:\s*true', 'enable_dns_settings: false'
    Set-Content $vergeFile $vf -Encoding UTF8 -NoNewline
    Write-Ok "verge.yaml: prefer_sidecar=false, enable_dns_settings=false"
}

$step++; Write-Step $step $totalSteps "优化 TUN 配置 (config.yaml)"
if (Test-Path $configFile) {
    $cfg = Get-Content $configFile -Raw
    $cfg = $cfg -replace 'stack:\s*\w+', 'stack: mixed'
    $cfg = $cfg -replace 'mtu:\s*\d+', 'mtu: 9000'
    if ($cfg -notmatch 'tcp://any:53') {
        $cfg = $cfg -replace '(dns-hijack:\s*\n\s*-\s*any:53)', "`$1`n  - tcp://any:53"
    }
    Set-Content $configFile $cfg -Encoding UTF8
    Write-Ok "config.yaml: stack=mixed, mtu=9000"
}

$step++; Write-Step $step $totalSteps "优化 Merge Profile (不覆盖 DNS)"
$profilesYaml = Join-Path $vergeDataDir "profiles.yaml"
$mergeUid = $null
if (Test-Path $profilesYaml) {
    $py = Get-Content $profilesYaml -Raw
    if ($py -match 'merge:\s*(\S+)') { $mergeUid = $Matches[1] }
}
if ($mergeUid) {
    $mergeFile = Join-Path $vergeDataDir "profiles\$mergeUid.yaml"
    @"
# 性能优化 Merge Profile (不覆盖机场 DNS)
# ⚠️ 不要在此添加 dns: 段，否则会覆盖机场自带的智能 DNS 导致代理服务器解析错误

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
keep-alive-interval: 30
keep-alive-idle: 600

profile:
  store-selected: true
  store-fake-ip: true
"@ | Set-Content $mergeFile -Encoding UTF8
    Write-Ok "Merge profile: tcp-concurrent, keep-alive, sniffer (DNS 保留机场原配置)"
}

# 注入 Cursor 分流规则
if (Test-Path $profilesYaml) {
    $py = Get-Content $profilesYaml -Raw
    if ($py -match 'rules:\s*(\S+)') {
        $rulesFile = Join-Path $vergeDataDir "profiles\$($Matches[1]).yaml"
        if (Test-Path $rulesFile) {
            $rc = Get-Content $rulesFile -Raw
            if ($rc -notmatch 'cursor\.sh') {
                @"
prepend:
  - DOMAIN-SUFFIX,cursor.sh,AI
  - DOMAIN-SUFFIX,cursor.com,AI
  - DOMAIN-SUFFIX,anysphere.com,AI
append: []
delete: []
"@ | Set-Content $rulesFile -Encoding UTF8
                Write-Ok "已注入 Cursor/Claude 分流规则"
            } else { Write-Ok "Cursor 分流规则已存在" }
        }
    }
}

$step++; Write-Step $step $totalSteps "系统网络优化"
netsh int tcp set global autotuninglevel=normal 2>$null | Out-Null
netsh int tcp set global rsc=enabled 2>$null | Out-Null
netsh int tcp set global timestamps=enabled 2>$null | Out-Null
netsh int tcp set global fastopen=enabled 2>$null | Out-Null
Write-Ok "TCP: AutoTuning, RSC, Timestamps, FastOpen"

Disable-NetAdapterBinding -Name 'WLAN' -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue
Write-Ok "WLAN IPv6 禁用"

Set-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'RoamingPreferredBandType' -RegistryValue 3 -ErrorAction SilentlyContinue
Set-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'ThroughputBoosterEnabled' -RegistryValue 1 -ErrorAction SilentlyContinue
Write-Ok "WiFi: 优先5GHz + 吞吐量增强"

powercfg /setacvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setdcvalueindex SCHEME_CURRENT 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
powercfg /setactive SCHEME_CURRENT 2>$null
Write-Ok "WiFi 电源: 最大性能"

Set-ItemProperty $regPath -Name ProxyEnable -Value 0
Set-ItemProperty $regPath -Name ProxyServer -Value ''
netsh winhttp reset proxy 2>$null | Out-Null
ipconfig /flushdns 2>$null | Out-Null
netsh winsock reset 2>$null | Out-Null
Write-Ok "代理清除 / DNS 刷新 / Winsock 重置"

net start w32time 2>$null | Out-Null
w32tm /resync /rediscover 2>$null | Out-Null
Write-Ok "系统时间已同步"

$step++; Write-Step $step $totalSteps "启动 Clash Verge Rev"
if (-not $SkipRestart) {
    $exePath = Join-Path $clashDir "clash-verge.exe"
    if (Test-Path $exePath) {
        Start-Process $exePath
        Write-Ok "Clash Verge Rev 已启动"
        Write-Info "等待 12 秒..."
        Start-Sleep 12
        $proxy = netstat -ano 2>$null | Select-String ':7897'
        if ($proxy) { Write-Ok "代理端口 7897 就绪" } else { Write-Warn "代理端口未就绪" }
        $tun = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta Tunnel' -and $_.Status -eq 'Up' }
        if ($tun) { Write-Ok "TUN 网卡就绪" } else { Write-Warn "TUN 网卡未就绪" }
        try {
            $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
            Write-Info "出口 IP: $($geo.ip) - $($geo.city), $($geo.country)"
        } catch {}
    }
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  修复完成!" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  已优化:" -ForegroundColor Cyan
Write-Host "    TUN stack=mixed  MTU=9000  tcp-concurrent=true" -ForegroundColor White
Write-Host "    keep-alive=30s  sniffer=on  DNS=机场原配置" -ForegroundColor White
Write-Host "    service模式  IPv6关  WiFi优先5GHz  吞吐量增强" -ForegroundColor White
Write-Host ""
Write-Host "  手动操作:" -ForegroundColor Yellow
Write-Host "    1. Clash UI 中确认 TUN 模式已开启" -ForegroundColor White
Write-Host "    2. AI / Proxies / Final 选择同一个美国节点" -ForegroundColor White
Write-Host "    3. 访问 https://ipinfo.io/json 验证地区" -ForegroundColor White
Write-Host ""
pause
