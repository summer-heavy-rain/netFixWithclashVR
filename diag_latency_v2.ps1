Write-Host '=== Step 1: DOH DNS Resolution ===' -ForegroundColor Cyan

function Resolve-ViaDoH {
    param([string]$domain)
    try {
        $url = 'https://dns.alidns.com/resolve?name=' + $domain + '&type=A'
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        $json = $resp.Content | ConvertFrom-Json
        $ip = ($json.Answer | Where-Object { $_.type -eq 1 } | Select-Object -First 1).data
        return $ip
    } catch {
        return $null
    }
}

$hkIP = Resolve-ViaDoH '483d9a4d40.u8m1xiygn.sbs'
$usIP = Resolve-ViaDoH '355b84b5cf.shcgcbzwq.sbs'

if ($hkIP) {
    Write-Host ('HK01: IP {0} port 17553' -f $hkIP) -ForegroundColor Yellow
} else {
    Write-Host 'HK01: DNS failed' -ForegroundColor Red
}

if ($usIP) {
    Write-Host ('US_Seattle01: IP {0} port 17763' -f $usIP) -ForegroundColor Yellow
} else {
    Write-Host 'US_Seattle01: DNS failed' -ForegroundColor Red
}

Write-Host ''
Write-Host '=== Step 2: TCP Latency ===' -ForegroundColor Cyan

function Test-TcpLatency {
    param([string]$ip, [int]$port)
    $latencies = @()
    for ($i = 0; $i -lt 5; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($ip, $port, $null, $null)
            $success = $ar.AsyncWaitHandle.WaitOne(5000)
            $sw.Stop()
            if ($success) {
                $latencies += $sw.ElapsedMilliseconds
                Write-Host ('  Try {0}: {1}ms' -f ($i+1), $sw.ElapsedMilliseconds) -ForegroundColor Green
            } else {
                Write-Host ('  Try {0}: TIMEOUT' -f ($i+1)) -ForegroundColor Red
            }
        } catch {
            $sw.Stop()
            Write-Host ('  Try {0}: FAILED' -f ($i+1)) -ForegroundColor Red
        } finally {
            $tcp.Close()
        }
        Start-Sleep -Milliseconds 200
    }
    return $latencies
}

if ($hkIP) {
    Write-Host '=== HK01 Results ===' -ForegroundColor Yellow
    $hkLatencies = Test-TcpLatency $hkIP 17553
    if ($hkLatencies.Count -gt 0) {
        $avgHk = [math]::Round(($hkLatencies | Measure-Object -Average).Average)
        Write-Host ($hkLatencies -join 'ms, ') -ForegroundColor Green
        Write-Host ('Average: {0}ms' -f $avgHk) -ForegroundColor Cyan
    } else {
        Write-Host 'ALL TIMEOUT' -ForegroundColor Red
    }
    Write-Host ''
}

if ($usIP) {
    Write-Host '=== US_Seattle01 Results ===' -ForegroundColor Yellow
    $usLatencies = Test-TcpLatency $usIP 17763
    if ($usLatencies.Count -gt 0) {
        $avgUs = [math]::Round(($usLatencies | Measure-Object -Average).Average)
        Write-Host ($usLatencies -join 'ms, ') -ForegroundColor Green
        Write-Host ('Average: {0}ms' -f $avgUs) -ForegroundColor Cyan
    } else {
        Write-Host 'ALL TIMEOUT' -ForegroundColor Red
    }
    Write-Host ''
}
