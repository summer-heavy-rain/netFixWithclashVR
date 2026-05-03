$geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15
$geo | ConvertTo-Json
