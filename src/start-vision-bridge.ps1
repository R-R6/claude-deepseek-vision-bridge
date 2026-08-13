$ErrorActionPreference = "Stop"

$bridgeDir = Join-Path $env:USERPROFILE ".claude\bridge"
$bridgeScript = Join-Path $bridgeDir "vision-bridge.js"
$clientScript = Join-Path $bridgeDir "vision-client.js"
$logPath = Join-Path $bridgeDir "vision-bridge.log"
$errorLogPath = Join-Path $bridgeDir "vision-bridge.err.log"
$expectedVersion = "0.2.1"
$bridgeProcess = $null

function Write-StartupFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
        $stamp = [DateTime]::UtcNow.ToString("o")
        Add-Content -LiteralPath $errorLogPath -Value "$stamp STARTUP-ERR $Message"
    } catch {
        # Preserve the original failure even if the log path is unavailable.
    }
    Write-Error $Message
    exit 1
}

function Get-ProcessSetting {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, "Process")
}

function Get-ProcessOwnerDescription {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $processInfo) {
        return "$ProcessId [process details unavailable]"
    }
    $name = if ($processInfo.Name) { $processInfo.Name } else { "[name unavailable]" }
    $path = if ($processInfo.ExecutablePath) { $processInfo.ExecutablePath } else { "[path unavailable]" }
    return "$ProcessId $name $path"
}

function Stop-StartedBridge {
    param([Parameter(Mandatory = $false)][object]$StartedProcess)

    if ($null -eq $StartedProcess) {
        return
    }
    try {
        if (-not $StartedProcess.HasExited) {
            Stop-Process -Id $StartedProcess.Id -Force -ErrorAction SilentlyContinue
            $null = $StartedProcess.WaitForExit(5000)
        }
    } catch {
        # The original startup error is more useful than a cleanup error.
    }
}

function Get-HealthUri {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $healthHost = $HostName
    if ($HostName -eq "0.0.0.0") {
        $healthHost = "127.0.0.1"
    } elseif ($HostName -eq "::") {
        $healthHost = "::1"
    }
    if ($healthHost.Contains(":")) {
        return "http://[$healthHost]:$Port/health"
    }
    return "http://$healthHost`:$Port/health"
}

try {
    if (-not (Test-Path -LiteralPath $bridgeScript)) {
        throw "Bridge script not found: $bridgeScript"
    }
    if (-not (Test-Path -LiteralPath $clientScript)) {
        throw "Bridge dependency not found: $clientScript"
    }

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        throw "Node.js was not found in PATH. Install Node.js 18+ and reopen the session."
    }

    $upstream = Get-ProcessSetting "UPSTREAM"
    if ([string]::IsNullOrWhiteSpace($upstream)) {
        throw "UPSTREAM is not configured in this process. Set it to the original DeepSeek provider base URL, then log out and in or reopen the launcher session."
    }

    $visionKey = Get-ProcessSetting "VISION_API_KEY"
    if ([string]::IsNullOrWhiteSpace($visionKey)) {
        throw "VISION_API_KEY is not configured in this process."
    }

    $hostName = Get-ProcessSetting "BRIDGE_HOST"
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $hostName = "127.0.0.1"
    }

    $portText = Get-ProcessSetting "BRIDGE_PORT"
    if ([string]::IsNullOrWhiteSpace($portText)) {
        $portText = "15720"
    }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "BRIDGE_PORT must be an integer between 1 and 65535."
    }

    $startupTimeoutText = Get-ProcessSetting "BRIDGE_STARTUP_TIMEOUT_MS"
    if ([string]::IsNullOrWhiteSpace($startupTimeoutText)) {
        $startupTimeoutText = "30000"
    }
    $startupTimeoutMs = 0
    if (-not [int]::TryParse($startupTimeoutText, [ref]$startupTimeoutMs) -or $startupTimeoutMs -lt 1000 -or $startupTimeoutMs -gt 120000) {
        throw "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000."
    }

    $healthUri = Get-HealthUri -HostName $hostName -Port $port
    $healthHeaders = @{}
    $bridgeToken = Get-ProcessSetting "BRIDGE_AUTH_TOKEN"
    if (-not [string]::IsNullOrWhiteSpace($bridgeToken)) {
        $healthHeaders["x-bridge-token"] = $bridgeToken
    }

    function Test-BridgeHealth {
        try {
            $health = Invoke-RestMethod -Uri $healthUri -Headers $healthHeaders -TimeoutSec 2
            return ($health.ok -eq $true -and $health.service -eq "vision-bridge" -and $health.version -eq $expectedVersion)
        } catch {
            return $false
        }
    }

    if (Test-BridgeHealth) {
        Write-Output "Vision Bridge is already healthy on port $port."
        exit 0
    }

    $existing = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $owners = @($existing | Select-Object -ExpandProperty OwningProcess -Unique)
        $ownerDetails = ($owners | ForEach-Object { Get-ProcessOwnerDescription -ProcessId ([int]$_) }) -join "; "
        throw "Port $port is already in use by a process that is not a healthy Vision Bridge version; refusing to stop owners: $ownerDetails."
    }

    New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
    $quotedBridgeScript = '"' + $bridgeScript + '"'
    $bridgeProcess = Start-Process `
        -FilePath $node.Source `
        -ArgumentList @($quotedBridgeScript) `
        -WorkingDirectory $bridgeDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $logPath `
        -RedirectStandardError $errorLogPath `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddMilliseconds($startupTimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-BridgeHealth) {
            Write-Output "Vision Bridge started and passed health check on port $port. Logs: $logPath"
            exit 0
        }
        if ($bridgeProcess.HasExited) {
            $exitCode = $bridgeProcess.ExitCode
            throw "Vision Bridge exited during startup with code $exitCode. See $errorLogPath."
        }
        Start-Sleep -Milliseconds 250
    }

    throw "Vision Bridge did not pass health check within $startupTimeoutMs ms. See $errorLogPath."
} catch {
    Stop-StartedBridge -StartedProcess $bridgeProcess
    Write-StartupFailure $_.Exception.Message
}
