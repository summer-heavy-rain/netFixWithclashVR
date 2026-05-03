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

# 启动后自动修复被 DPI 封锁的订阅 DNS 服务器
Write-Log "[DNS] Running DNS fix..."
try {
    & "D:\fixClashNet\_fix_dns.ps1" -Silent
    Write-Log "[DNS] DNS fix script completed"
} catch {
    Write-Log "[DNS] DNS fix script failed: $_"
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
