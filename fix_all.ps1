<#
.SYNOPSIS
    终极修复：Clash服务 + WiFi频段 + 驱动稳定性 + 持久化
.DESCRIPTION
    解决三大问题：
    1. Clash服务未启动/开机不自启
    2. WiFi锁死在2.4GHz（首选频带未设置）
    3. Intel WiFi驱动崩溃残留状态
#>

param([switch]$DiagnoseOnly)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

function Write-Step($m) { Write-Host ""; Write-Host "[>] $m" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m){ Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad($m) { Write-Host "  [X]  $m" -ForegroundColor Red }
function Write-Info($m){ Write-Host "       $m" -ForegroundColor Gray }

# ── 管理员检查 ─────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Bad "需要管理员权限，正在提升..."
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

# ── 路径定位 ───────────────────────────────
$clashDir = $null
$svcInfo = Get-WmiObject Win32_Service -Filter "Name='clash_verge_service'" -ErrorAction SilentlyContinue
if ($svcInfo -and $svcInfo.PathName) {
    $svcPath = $svcInfo.PathName -replace '"',''
    $clashDir = Split-Path (Split-Path $svcPath)
}
if (-not $clashDir -or -not (Test-Path $clashDir)) {
    $candidates = @(
        "C:\Users\$env:USERNAME\Clash Verge",
        "D:\clash verge",
        "C:\Program Files\Clash Verge",
        "$env:LOCALAPPDATA\Programs\clash-verge",
        "$env:LOCALAPPDATA\clash-verge"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\clash-verge.exe") { $clashDir = $c; break }
    }
}

$vergeDataDir = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

Write-Host ""
Write-Host "========================================" -ForegroundColor White
Write-Host "  终极网络修复" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor White
Write-Info "Clash目录: $clashDir"
Write-Info "数据目录: $vergeDataDir"

# ════════════════════════════════════════════
#  PHASE 1: 诊断
# ════════════════════════════════════════════

$issues = @()

# ---- 1. Clash进程/服务状态 ----
Write-Step "诊断 Clash 服务状态"
$clashUI = Get-Process clash-verge -ErrorAction SilentlyContinue
$clashCore = Get-Process verge-mihomo -ErrorAction SilentlyContinue
$clashSvc = Get-Service clash_verge_service -ErrorAction SilentlyContinue

if ($clashUI)   { Write-Info "UI进程:  clash-verge.exe   PID $($clashUI.Id)" } else { Write-Bad "UI进程未运行"; $issues += "NO_UI" }
if ($clashCore) { Write-Info "核心:    verge-mihomo.exe  PID $($clashCore.Id)" } else { Write-Bad "核心进程未运行!"; $issues += "NO_CORE" }
if ($clashSvc)  { Write-Info "服务:    $($clashSvc.Status) (启动类型: $($clashSvc.StartType))" } else { Write-Bad "服务不存在!"; $issues += "NO_SVC" }

if ($clashSvc -and $clashSvc.Status -ne 'Running') {
    Write-Bad "clash_verge_service 服务未运行!"
    $issues += "SVC_STOPPED"
}

# ---- 2. WiFi频段诊断 ----
Write-Step "诊断 WiFi 频段"
$wlanInfo = netsh wlan show interfaces 2>$null
$bandLine = ($wlanInfo | Select-String '波段|Band').Line
$radioLine = ($wlanInfo | Select-String '无线电类型|Radio type').Line
$signalLine = ($wlanInfo | Select-String '信号|Signal').Line
$rateLine = ($wlanInfo | Select-String '传输速率|Transmit rate').Line

if ($bandLine)   { Write-Info $bandLine.Trim() }
if ($radioLine)  { Write-Info $radioLine.Trim() }
if ($signalLine) { Write-Info $signalLine.Trim() }
if ($rateLine)   { Write-Info $rateLine.Trim() }

if ($bandLine -match '2\.4') {
    Write-Bad "WiFi在2.4GHz频段! 速度被严重限制!"
    $issues += "WIFI_24GHZ"
} elseif ($bandLine -match '5') {
    Write-Ok "WiFi在5GHz频段"
} elseif ($bandLine -match '6') {
    Write-Ok "WiFi在6GHz频段"
}

# 检查首选频带设置
$prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*首选频带*' -ErrorAction SilentlyContinue
if (-not $prefBand) { $prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Preferred*Band*' -ErrorAction SilentlyContinue }
if ($prefBand) {
    Write-Info "当前首选频带: $($prefBand.DisplayValue)"
    if ($prefBand.RegistryValue -eq 1 -or $prefBand.DisplayValue -match '无首选项|No Preference') {
        Write-Bad "首选频带是'无首选项'，路由器会把你踢到2.4GHz"
        $issues += "WIFI_NO_PREF"
    }
}

# ---- 3. 路由表检查 ----
Write-Step "诊断路由表"
$metaRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -match 'Meta' }
$wlanRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq 'WLAN' }
if ($metaRoute -and -not $clashCore) {
    Write-Warn "Meta默认路由残留，但核心未运行（流量可能混乱）"
    $issues += "ROUTE_LEAK"
}
if ($metaRoute -and $wlanRoute) {
    Write-Warn "存在两条默认路由，可能导致流量竞争"
    $issues += "DUAL_ROUTE"
}

# ---- 4. 网络连通性 ----
Write-Step "诊断网络连通性"
try {
    $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 10
    Write-Info "出口IP: $($geo.ip) / $($geo.city), $($geo.country)"
    if ($geo.country -eq 'CN') {
        Write-Warn "出口在中国，代理未生效"
        $issues += "NO_PROXY"
    } else {
        Write-Ok "代理已生效，出口: $($geo.country)"
    }
} catch {
    Write-Bad "无法访问互联网"
    $issues += "NO_INET"
}

# ---- 诊断总结 ----
Write-Host ""
Write-Host "========== 诊断总结 ==========" -ForegroundColor White
if ($issues.Count -eq 0) {
    Write-Ok "所有检查通过，网络正常!"
} else {
    Write-Bad "发现 $($issues.Count) 个问题需要修复:"
    foreach ($i in $issues) {
        switch ($i) {
            "NO_UI"        { Write-Bad "  - Clash UI未运行" }
            "NO_CORE"      { Write-Bad "  - Clash核心(verge-mihomo)未运行" }
            "NO_SVC"       { Write-Bad "  - Clash服务不存在" }
            "SVC_STOPPED"  { Write-Bad "  - Clash服务已停止" }
            "WIFI_24GHZ"   { Write-Bad "  - WiFi在2.4GHz，速度受限" }
            "WIFI_NO_PREF" { Write-Bad "  - WiFi首选频带未设置为5GHz" }
            "ROUTE_LEAK"   { Write-Warn "  - 残留Meta路由" }
            "DUAL_ROUTE"   { Write-Warn "  - 双默认路由冲突" }
            "NO_PROXY"     { Write-Bad "  - 代理未生效（出口在中国）" }
            "NO_INET"      { Write-Bad "  - 无互联网连接" }
        }
    }
}

if ($DiagnoseOnly) {
    Write-Host ""
    Write-Host "运行时不加 -DiagnoseOnly 来执行修复。" -ForegroundColor Cyan
    pause; exit
}

if ($issues.Count -eq 0) {
    Write-Host ""; Write-Ok "无需修复"; pause; exit
}

# ════════════════════════════════════════════
#  PHASE 2: 修复
# ════════════════════════════════════════════

Write-Host ""
Write-Host "========== 开始修复 ==========" -ForegroundColor White

# ---- Step 1: 彻底关闭Clash并清理残留 ----
Write-Step "[1/8] 彻底关闭Clash并清理残留状态"
Stop-Process -Name clash-verge -Force -ErrorAction SilentlyContinue
& taskkill /F /IM verge-mihomo.exe 2>$null | Out-Null
& taskkill /F /IM verge-mihomo-alpha.exe 2>$null | Out-Null
& taskkill /F /IM clash-verge-service.exe 2>$null | Out-Null
Start-Sleep 2

# 删除残留Meta路由
$metaRoutes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -match 'Meta|Mihomo' }
foreach ($r in $metaRoutes) {
    Remove-NetRoute -DestinationPrefix $r.DestinationPrefix -NextHop $r.NextHop -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok "已删除残留Meta路由"
}

# 禁用再启用TUN适配器以清理状态
$metaAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta|Mihomo' }
if ($metaAdapter) {
    Disable-NetAdapter -Name $metaAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    Start-Sleep 1
    Enable-NetAdapter -Name $metaAdapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    Write-Ok "Meta适配器已重置"
}
Write-Ok "Clash已彻底关闭，残留已清理"

# ---- Step 2: 修复WiFi频段设置 ----
Write-Step "[2/8] 修复WiFi频段设置（关键！）"

# 首选频带 -> 5GHz
$prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*首选频带*' -ErrorAction SilentlyContinue
if (-not $prefBand) { $prefBand = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Preferred*Band*' -ErrorAction SilentlyContinue }
if ($prefBand) {
    $set = $false
    $tryValues = @('2. 首选 5GHz 频段', 'Prefer 5GHz band', '5GHz only', '3. Prefer 5GHz')
    foreach ($v in $tryValues) {
        Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $prefBand.DisplayName -DisplayValue $v -ErrorAction SilentlyContinue
        if ($?) { $set = $true; Write-Ok "首选频带已设为: $v"; break }
    }
    if (-not $set) {
        Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $prefBand.DisplayName -RegistryValue 2 -ErrorAction SilentlyContinue
        if ($?) { Write-Ok "首选频带已设为5GHz (registry)" } else { Write-Warn "无法自动设置首选频带，请手动设置" }
    }
} else {
    Write-Warn "找不到首选频带属性"
}

# 漫游主动性 -> 最低（防止随机断连）
$roamProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*漫游主动性*' -ErrorAction SilentlyContinue
if (-not $roamProp) { $roamProp = Get-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName '*Roaming*Aggressiveness*' -ErrorAction SilentlyContinue }
if ($roamProp) {
    Set-NetAdapterAdvancedProperty -Name 'WLAN' -DisplayName $roamProp.DisplayName -RegistryValue 1 -ErrorAction SilentlyContinue
    if ($?) { Write-Ok "漫游主动性已设为最低（减少随机断连）" } else { Write-Warn "无法设置漫游主动性" }
} else {
    Write-Warn "找不到漫游主动性属性"
}

# 电源管理 -> 最高性能
foreach ($scheme in @('SCHEME_CURRENT','SCHEME_MAX','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
    & powercfg /setacvalueindex $scheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
    & powercfg /setdcvalueindex $scheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>$null
}
& powercfg /setactive SCHEME_CURRENT 2>$null
Write-Ok "WiFi电源管理已设为最高性能"

# ---- Step 3: 重置WLAN适配器以应用WiFi设置 ----
Write-Step "[3/8] 重置WLAN适配器"
Disable-NetAdapter -Name 'WLAN' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 2
Enable-NetAdapter -Name 'WLAN' -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 4
Write-Ok "WLAN适配器已重置"

# 等待重新连接
$connected = $false
for ($i = 0; $i -lt 15; $i++) {
    $wlanStatus = Get-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue
    if ($wlanStatus -and $wlanStatus.Status -eq 'Up') { $connected = $true; break }
    Start-Sleep 1
}
if ($connected) { Write-Ok "WiFi已重新连接" } else { Write-Warn "WiFi尚未连接，继续..." }

# ---- Step 4: 修复Clash verge.yaml设置 ----
Write-Step "[4/8] 修复Clash应用设置"
$vergeFile = Join-Path $vergeDataDir "verge.yaml"
if (Test-Path $vergeFile) {
    $vf = Get-Content $vergeFile -Raw
    $vf = $vf -replace 'enable_auto_launch:\s*\w+', 'enable_auto_launch: true'
    $vf = $vf -replace 'prefer_sidecar:\s*\w+', 'prefer_sidecar: false'
    $vf = $vf -replace 'enable_tun_mode:\s*\w+', 'enable_tun_mode: true'
    $vf = $vf -replace 'enable_system_proxy:\s*\w+', 'enable_system_proxy: false'
    $vf = $vf -replace 'enable_dns_settings:\s*\w+', 'enable_dns_settings: false'
    Set-Content $vergeFile $vf -Encoding UTF8
    Write-Ok "verge.yaml: 自启=TUN=开, 系统代理=关, DNS