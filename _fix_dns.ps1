# _fix_dns.ps1 - 修复被 DPI 封锁的订阅 DNS 服务器
# 用途：Clash 启动后自动替换 DNS 为 UDP DNS（快速）+ DoH fallback
# 可单独运行，也可被 _startup_guard.ps1 调用

param(
    [int]$MaxWait = 60,        # 最长等待 API 可用的秒数
    [switch]$Silent             # 静默模式（不输出到控制台）
)

$ErrorActionPreference = 'SilentlyContinue'
$h = @{ "Authorization" = "Bearer set-your-secret"; "Content-Type" = "application/json" }
$base = "http://127.0.0.1:9097"

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$ts [fix_dns] $msg"
    if (-not $Silent) { Write-Host $line }
    $line | Out-File -FilePath "D:\fixClashNet\logs\fix_dns.log" -Append -Encoding UTF8
}

# 1. 等待 Clash API 可用
Write-Log "Waiting for Clash API..."
$waited = 0
while ($waited -lt $MaxWait) {
    try {
        $null = Invoke-RestMethod -Uri "$base/configs" -Headers $h -TimeoutSec 3
        Write-Log "API ready after ${waited}s"
        break
    } catch {
        Start-Sleep -Seconds 2
        $waited += 2
    }
}
if ($waited -ge $MaxWait) {
    Write-Log "ERROR: API not available after ${MaxWait}s, aborting"
    exit 1
}

# 2. PATCH DNS 配置（UDP DNS 为主，DoH 仅作 fallback）
$dnsPayload = @{
    dns = @{
        nameserver = @(
            "119.29.29.29",
            "223.5.5.5"
        )
        fallback = @(
            "https://doh.pub/dns-query",
            "https://dns.alidns.com/dns-query"
        )
        'proxy-server-nameserver' = @(
            "119.29.29.29",
            "223.5.5.5"
        )
    }
} | ConvertTo-Json -Depth 5

try {
    Invoke-RestMethod -Uri "$base/configs" -Method PATCH -Headers $h -Body $dnsPayload -TimeoutSec 10
    Write-Log "DNS config patched successfully"
} catch {
    Write-Log "ERROR: DNS patch failed - $($_.Exception.Message)"
    exit 1
}

Start-Sleep -Seconds 3

# 3. 验证 DNS 配置已生效
try {
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Headers $h -TimeoutSec 5
    $nsStr = ($cfg.dns.nameserver | ConvertTo-Json -Compress)
    if ($nsStr -match '119\.29\.29\.29') {
        Write-Log "VERIFIED: DNS nameserver correctly set to UDP DNS"
    } else {
        Write-Log "WARNING: DNS nameserver may not be correctly patched: $nsStr"
    }
    # 检查是否还残留被封的 DNS
    if ($nsStr -match 'blasphemy|destitute|prolonged') {
        Write-Log "WARNING: Blocked DoH servers still present!"
    }
} catch {
    Write-Log "WARNING: Could not verify DNS config"
}

# 4. 快速连通性测试
Start-Sleep -Seconds 2
try {
    $r = Invoke-WebRequest -Uri "http://www.gstatic.com/generate_204" -Proxy "http://127.0.0.1:7897" -TimeoutSec 15 -UseBasicParsing
    Write-Log "Connectivity test: OK (status $($r.StatusCode))"
} catch {
    Write-Log "WARNING: Connectivity test failed - $($_.Exception.Message)"
}

Write-Log "DNS fix completed"
