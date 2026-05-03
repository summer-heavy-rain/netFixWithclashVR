# Clash Verge Rev 开机守护脚本（后台常驻）
# 功能：监控 verge.yaml 配置项，防止被 UI 重置
# 注意：只修改配置文件，不杀进程、不重启 Clash
# 不检查/不修改 Merge Profile DNS 配置（机场订阅自带智能 DNS）

$ErrorActionPreference = 'SilentlyContinue'
$logDir = "D:\fixClashNet\logs"
$logFile = "$logDir\startup_guard.log"
$vergeYaml = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\verge.yaml"
$checkInterval = 30  # 每 30 秒检查一次（不需要太频繁）

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

# 日志轮转（>1MB 保留最后 500 行）
function Rotate-Log {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) {
        $tail = Get-Content $logFile -Tail 500
        Set-Content -Path $logFile -Value $tail -Encoding UTF8
        Write-Log "[ROTATE] Log rotated"
    }
}

# 防止多实例
$mutexName = "Global\ClashVergeStartupGuard"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    exit 0
}

Write-Log "=== Guard started (config-watch mode) ==="

# 初始等待，让 Clash 完成启动
Start-Sleep -Seconds 15

# 启动后自动修复被 DPI 封锁的订阅 DNS 服务器（内联逻辑，不依赖外部脚本）
Write-Log "[DNS] Starting inline DNS fix..."
$apiBase = "http://127.0.0.1:9097"
$apiHeaders = @{ "Authorization" = "Bearer set-your-secret"; "Content-Type" = "application/json" }

# 等待 Clash API 可用（最长 60 秒）
$apiWaited = 0; $apiMaxWait = 60; $apiReady = $false
while ($apiWaited -lt $apiMaxWait) {
    try {
        $null = Invoke-RestMethod -Uri "$apiBase/configs" -Headers $apiHeaders -TimeoutSec 3
        Write-Log "[DNS] API ready after ${apiWaited}s"
        $apiReady = $true
        break
    } catch {
        Start-Sleep -Seconds 2
        $apiWaited += 2
    }
}

if (-not $apiReady) {
    Write-Log "[DNS] ERROR: API not available after ${apiMaxWait}s, skipping DNS patch"
} else {
    # PATCH DNS: UDP DNS 为主，DoH 仅作 fallback
    $dnsPatchPayload = @{
        dns = @{
            nameserver = @("119.29.29.29", "223.5.5.5")
            fallback = @("https://doh.pub/dns-query", "https://dns.alidns.com/dns-query")
            'proxy-server-nameserver' = @("119.29.29.29", "223.5.5.5")
        }
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-RestMethod -Uri "$apiBase/configs" -Method PATCH -Headers $apiHeaders -Body $dnsPatchPayload -TimeoutSec 10
        Write-Log "[DNS] DNS config patched: UDP DNS primary, DoH fallback"
    } catch {
        Write-Log "[DNS] ERROR: DNS patch failed - $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 3

    # 验证 DNS 配置
    try {
        $cfg = Invoke-RestMethod -Uri "$apiBase/configs" -Headers $apiHeaders -TimeoutSec 5
        $nsStr = ($cfg.dns.nameserver | ConvertTo-Json -Compress)
        if ($nsStr -match '119\.29\.29\.29') {
            Write-Log "[DNS] Verified: nameserver correctly set to UDP DNS"
        } else {
            Write-Log "[DNS] WARNING: nameserver may not be patched: $nsStr"
        }
    } catch {
        Write-Log "[DNS] WARNING: Could not verify DNS config"
    }

    # 快速连通性测试
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest -Uri "http://www.gstatic.com/generate_204" -Proxy "http://127.0.0.1:7897" -TimeoutSec 15 -UseBasicParsing
        Write-Log "[DNS] Connectivity test: OK (status $($r.StatusCode))"
    } catch {
        Write-Log "[DNS] WARNING: Connectivity test failed - $($_.Exception.Message)"
    }

    Write-Log "[DNS] DNS fix completed"
}

while ($true) {
    try {
        Rotate-Log

        if (Test-Path $vergeYaml) {
            $content = Get-Content $vergeYaml -Raw
            $needsFix = $false
            $fixes = @()

            # 检查 enable_tun_mode（必须为 true）
            if ($content -match 'enable_tun_mode:\s*false') {
                $content = $content -replace 'enable_tun_mode:\s*false', 'enable_tun_mode: true'
                $needsFix = $true
                $fixes += "enable_tun_mode: false -> true"
            }

            # 检查 enable_dns_settings（必须为 false）
            if ($content -match 'enable_dns_settings:\s*true') {
                $content = $content -replace 'enable_dns_settings:\s*true', 'enable_dns_settings: false'
                $needsFix = $true
                $fixes += "enable_dns_settings: true -> false"
            }

            if ($needsFix) {
                Set-Content -Path $vergeYaml -Value $content -Encoding UTF8 -NoNewline
                Write-Log "[FIXED] $($fixes -join '; ')"
                # 注意：只修改文件，不重启 Clash
                # 用户需要手动重启 Clash 或等下次启动生效
            }
        }
    }
    catch {
        Write-Log "[ERROR] $_"
    }

    Start-Sleep -Seconds $checkInterval
}
