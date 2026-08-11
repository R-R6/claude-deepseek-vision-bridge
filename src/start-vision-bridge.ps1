$ErrorActionPreference = "Stop"

$bridgeDir = Join-Path $env:USERPROFILE ".claude\bridge"
$bridgeScript = Join-Path $bridgeDir "vision-bridge.js"
$logPath = Join-Path $bridgeDir "vision-bridge.log"
$errorLogPath = Join-Path $bridgeDir "vision-bridge.err.log"

if (-not (Test-Path -LiteralPath $bridgeScript)) {
    throw "Bridge script not found: $bridgeScript"
}

$node = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $node) {
    throw "Node.js was not found in PATH. Install Node.js 18+ and reopen the terminal."
}

if (-not $env:UPSTREAM) {
    throw "UPSTREAM is not configured. Set it to the original DeepSeek provider base URL."
}

if (-not $env:VISION_API_KEY) {
    throw "VISION_API_KEY is not configured."
}

$port = if ($env:BRIDGE_PORT) { [int]$env:BRIDGE_PORT } else { 15720 }
$existing = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($existing) {
    Write-Output "Vision Bridge is already listening on port $port."
    exit 0
}

Start-Process `
    -FilePath $node.Source `
    -ArgumentList @($bridgeScript) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $logPath `
    -RedirectStandardError $errorLogPath

Write-Output "Vision Bridge started on port $port. Logs: $logPath"

