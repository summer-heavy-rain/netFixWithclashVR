# Wait for TUN initialization
Write-Host "Waiting 15 seconds for TUN initialization..."
Start-Sleep -Seconds 15

Write-Host "`n=== Verification after restart ==="

# 1. Check processes
$procs = Get-Process -Name "*clash*","*verge*","*mihomo*" -ErrorAction SilentlyContinue
Write-Host "Running processes: $($procs | ForEach-Object { "$($_.ProcessName)($($_.Id))" })"

# 2. Check TUN adapter
Write-Host "`n--- Network Adapters (Up) ---"
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Format-Table Name, InterfaceDescription, Status, LinkSpeed -AutoSize

# 3. Check mihomo listening ports
$mihomo = Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue
if ($mihomo) {
    Write-Host "--- mihomo (PID $($mihomo.Id)) listening ports ---"
    Get-NetTCPConnection -OwningProcess $mihomo.Id -ErrorAction SilentlyContinue |
        Where-Object { $_.State -eq 'Listen' } |
        Format-Table LocalAddress, LocalPort, State -AutoSize
}

# 4. Check runtime config.yaml TUN status
Write-Host "`n--- Runtime config.yaml TUN ---"
$configPath = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\config.yaml"
if (Test-Path $configPath) {
    $lines = Get-Content $configPath
    $inTun = $false
    foreach ($line in $lines) {
        if ($line -match "^tun:") { $inTun = $true }
        if ($inTun) {
            Write-Host $line
            if ($line -match "^[a-z]" -and $line -notmatch "^tun:") { break }
        }
    }
}

# 5. Check verge.yaml to confirm TUN is still true
Write-Host "`n--- verge.yaml TUN ---"
$vergePath = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\verge.yaml"
Get-Content $vergePath | Select-String "enable_tun_mode"

# 6. Try API
Write-Host "`n--- API test (multiple ports) ---"
foreach ($port in @(9090, 9097)) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:${port}/configs" -UseBasicParsing -TimeoutSec 3
        Write-Host "Port $port (no auth): OK"
    } catch {
        try {
            $headers = @{ "Authorization" = "Bearer set-your-secret" }
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:${port}/configs" -UseBasicParsing -TimeoutSec 3 -Headers $headers
            Write-Host "Port $port (with auth): OK - $($r.Content.Substring(0, [Math]::Min(300, $r.Content.Length)))"
        } catch {
            Write-Host "Port $port : $($_.Exception.Message)"
        }
    }
}

# 7. Quick connectivity test
Write-Host "`n--- Connectivity test ---"
try {
    $r = Invoke-WebRequest -Uri "http://www.gstatic.com/generate_204" -UseBasicParsing -TimeoutSec 10
    Write-Host "gstatic 204: Status $($r.StatusCode) - OK!"
} catch {
    Write-Host "gstatic 204: $($_.Exception.Message)"
}

try {
    $r = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 10
    Write-Host "google.com: Status $($r.StatusCode) - OK!"
} catch {
    Write-Host "google.com: $($_.Exception.Message)"
}
