$ErrorActionPreference = "Stop"

$bridgeDir = Join-Path $env:USERPROFILE ".claude\bridge"
$bridgeScript = Join-Path $bridgeDir "vision-bridge.js"
$clientScript = Join-Path $bridgeDir "vision-client.js"
$logPath = Join-Path $bridgeDir "vision-bridge.log"
$errorLogPath = Join-Path $bridgeDir "vision-bridge.err.log"
$rollbackStatePath = Join-Path $bridgeDir "bridge-rollback-state.dat"
$rollbackEnvironmentNames = @(
    "UPSTREAM",
    "VISION_API_KEY",
    "VISION_BASE_URL",
    "VISION_MODEL",
    "VISION_PROMPT",
    "VISION_TIMEOUT_MS",
    "VISION_MAX_RESPONSE_BYTES",
    "BRIDGE_HOST",
    "BRIDGE_PORT",
    "BRIDGE_AUTH_TOKEN",
    "BRIDGE_MAX_BODY_BYTES",
    "BRIDGE_MAX_IMAGES",
    "BRIDGE_MAX_CONCURRENT_VISION_REQUESTS",
    "BRIDGE_MAX_VISION_JOBS",
    "UPSTREAM_TIMEOUT_MS",
    "BRIDGE_HEADERS_TIMEOUT_MS",
    "BRIDGE_BODY_TIMEOUT_MS",
    "BRIDGE_TOTAL_REQUEST_TIMEOUT_MS",
    "BRIDGE_KEEP_ALIVE_TIMEOUT_MS",
    "BRIDGE_STARTUP_TIMEOUT_MS",
    "BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS",
    "ALLOW_INSECURE_HTTP"
)
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

function Save-RollbackSnapshot {
    param([Parameter(Mandatory = $true)][object]$Settings)

    $temporaryPath = "$rollbackStatePath.$PID.tmp"
    try {
        $snapshot = [ordered]@{}
        foreach ($name in $rollbackEnvironmentNames) {
            $snapshot[$name] = Get-ProcessSetting -Name $name
        }
        $snapshot["BRIDGE_HOST"] = $Settings.Host
        $snapshot["BRIDGE_PORT"] = [string]$Settings.Port
        $snapshot["BRIDGE_STARTUP_TIMEOUT_MS"] = [string]$Settings.StartupTimeoutMs
        $json = $snapshot | ConvertTo-Json -Compress
        $secureSnapshot = ConvertTo-SecureString -String $json -AsPlainText -Force
        $encryptedSnapshot = ConvertFrom-SecureString -SecureString $secureSnapshot
        Set-Content -LiteralPath $temporaryPath -Value $encryptedSnapshot -Encoding ASCII -Force
        Move-Item -LiteralPath $temporaryPath -Destination $rollbackStatePath -Force
        return $true
    } catch {
        try {
            Add-Content -LiteralPath $errorLogPath -Value "$(Get-Date -Format o) ROLLBACK-STATE-WARN unable to save protected rollback state"
        } catch {
            # The bridge is already healthy; a missing rollback snapshot must not stop it.
        }
        return $false
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
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

function Get-CurrentOwnerKey {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Convert-OwnerToSid {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$User
    )

    $account = New-Object System.Security.Principal.NTAccount($Domain, $User)
    return $account.Translate([Security.Principal.SecurityIdentifier]).Value
}

function Test-ScriptArgument {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $normalizedCommandLine = $CommandLine.Replace("/", "\")
    $normalizedScriptPath = $ScriptPath.Replace("/", "\")
    $pattern = '(?i)(^|[\s"])' + [Regex]::Escape($normalizedScriptPath) + '(["\s]|$)'
    return $normalizedCommandLine -match $pattern
}

function Test-ManagedBridgeProcess {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    try {
        $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
        if ($null -eq $cimProcess -or
            [string]::IsNullOrWhiteSpace($cimProcess.CommandLine) -or
            -not (Test-ScriptArgument -CommandLine $cimProcess.CommandLine -ScriptPath $ScriptPath) -or
            [string]::IsNullOrWhiteSpace($cimProcess.ExecutablePath) -or
            [IO.Path]::GetFileName($cimProcess.ExecutablePath) -ine "node.exe") {
            return $false
        }

        $owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner -ErrorAction Stop
        if ($owner.ReturnValue -ne 0 -or
            [string]::IsNullOrWhiteSpace($owner.User) -or
            [string]::IsNullOrWhiteSpace($owner.Domain)) {
            return $false
        }
        return (Convert-OwnerToSid -Domain $owner.Domain -User $owner.User) -eq (Get-CurrentOwnerKey)
    } catch {
        return $false
    }
}

function Get-ManagedListenerStatus {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
    $owners = @($connections | Select-Object -ExpandProperty OwningProcess -Unique)
    $unmanaged = @()
    foreach ($owner in $owners) {
        if (-not (Test-ManagedBridgeProcess -ProcessId ([int]$owner) -ScriptPath $ScriptPath)) {
            $unmanaged += Get-ProcessOwnerDescription -ProcessId ([int]$owner)
        }
    }
    return [pscustomobject]@{
        Listening = $owners.Count -gt 0
        Managed = $owners.Count -gt 0 -and $unmanaged.Count -eq 0
        Details = ($unmanaged -join "; ")
    }
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

    $listenerStatus = Get-ManagedListenerStatus -Port $port -ScriptPath $bridgeScript
    if ($listenerStatus.Listening) {
        if (-not $listenerStatus.Managed) {
            throw "Port $port is already in use by a process that is not the installed Vision Bridge; refusing to stop or reuse owners: $($listenerStatus.Details)."
        }
        if (Test-BridgeHealth) {
            Write-Output "Vision Bridge is already healthy on port $port."
            exit 0
        }
        throw "A managed Vision Bridge process is listening on port $port but did not pass the health check; refusing to start another process."
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
        $listenerStatus = Get-ManagedListenerStatus -Port $port -ScriptPath $bridgeScript
        if ($listenerStatus.Listening -and -not $listenerStatus.Managed) {
            throw "Port $port became occupied by a process that is not the installed Vision Bridge; refusing to reuse it: $($listenerStatus.Details)."
        }
        if ($listenerStatus.Managed -and (Test-BridgeHealth)) {
            $rollbackStateSaved = Save-RollbackSnapshot -Settings ([pscustomobject]@{
                Host = $hostName
                Port = $port
                StartupTimeoutMs = $startupTimeoutMs
            })
            if ($rollbackStateSaved) {
                Write-Output "Vision Bridge started and passed health check on port $port. Logs: $logPath"
            } else {
                Write-Warning "Vision Bridge started on port $port, but its protected rollback state was not saved. Restart Windows before changing bridge configuration."
            }
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
