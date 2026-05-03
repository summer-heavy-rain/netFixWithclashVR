$ErrorActionPreference = 'SilentlyContinue'

Write-Host "=== Network Latency Tests ===" -ForegroundColor Cyan
foreach ($url in @('https://www.google.com','https://api2.cursor.sh','https://api.anthropic.com','https://www.youtube.com')) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 10
        $sw.Stop()
        $color = if ($sw.ElapsedMilliseconds -lt 500) {'Green'} elseif ($sw.ElapsedMilliseconds -lt 2000) {'Yellow'} else {'Red'}
        Write-Host ("  {0,-35} {1,6} ms" -f $url, $sw.ElapsedMilliseconds) -ForegroundColor $color
    } catch {
        $sw.Stop()
        Write-Host ("  {0,-35} FAILED ({1} ms)" -f $url, $sw.ElapsedMilliseconds) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== TUN Adapter ===" -ForegroundColor Cyan
Get-NetAdapter | Where-Object { $_.InterfaceDescription -match 'Meta|wintun|Mihomo|Tunnel' } | Format-Table Name,InterfaceDescription,Status,LinkSpeed -AutoSize

Write-Host "=== TUN Routes ===" -ForegroundColor Cyan
route print | Select-String '198\.18\.|0\.0\.0\.0.*0\.0\.0\.0' | ForEach-Object { $_.Line.Trim() }

Write-Host ""
Write-Host "=== WiFi Signal ===" -ForegroundColor Cyan
netsh wlan show interfaces

Write-Host ""
Write-Host "=== Recent WiFi Disconnect Events (24h) ===" -ForegroundColor Cyan
$start = (Get-Date).AddHours(-24)
$events = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$start} -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Netwaw|Netwtw|WLAN-AutoConfig|NDIS' -and $_.LevelDisplayName -ne 'Information' }
if ($events) {
    Write-Host "  Found $($events.Count) warning/error events:" -ForegroundColor Yellow
    $events | Select-Object -First 10 | ForEach-Object {
        Write-Host ("  [{0}] {1} - {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.ProviderName, $_.Message.Substring(0,[Math]::Min($_.Message.Length,100))) -ForegroundColor Yellow
    }
} else {
    Write-Host "  No WiFi driver warning/error events" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== DNS Resolution Test ===" -ForegroundColor Cyan
foreach ($domain in @('www.google.com','api2.cursor.sh','api.anthropic.com')) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $result = Resolve-DnsName $domain -Type A -DnsOnly -ErrorAction Stop
        $sw.Stop()
        $ip = ($result | Where-Object { $_.QueryType -eq 'A' } | Select-Object -First 1).IPAddress
        Write-Host ("  {0,-30} -> {1,-18} ({2}ms)" -f $domain, $ip, $sw.ElapsedMilliseconds) -ForegroundColor Green
    } catch {
        $sw.Stop()
        Write-Host ("  {0,-30} -> FAILED ({1}ms)" -f $domain, $sw.ElapsedMilliseconds) -ForegroundColor Red
    }
}
