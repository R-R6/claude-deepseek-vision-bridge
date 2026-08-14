[CmdletBinding()]
param(
    [ValidateSet("User", "Process")]
    [string]$EnvironmentScope = "User",
    [switch]$BootstrapRollbackState
)

$ErrorActionPreference = "Stop"

$bridgeDir = Join-Path $env:USERPROFILE ".claude\bridge"
$bridgeScript = [IO.Path]::GetFullPath((Join-Path $bridgeDir "vision-bridge.js"))
$launcherScript = [IO.Path]::GetFullPath((Join-Path $bridgeDir "start-vision-bridge.ps1"))
$logPath = Join-Path $bridgeDir "restart-vision-bridge.log"
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
$expectedBridgeVersion = "0.2.1"
$environmentNames = @(
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

function Get-ScopedEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, $EnvironmentScope)
}

function Write-RestartFailure {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
        Add-Content -LiteralPath $errorLogPath -Value "$(Get-Date -Format o) RESTART-ERR $Message"
    } catch {
        # Keep the original error as the process result if logging is unavailable.
    }
    Write-Error $Message
}

function Write-RestartTrace {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        New-Item -ItemType Directory -Force -Path $bridgeDir | Out-Null
        Add-Content -LiteralPath $logPath -Value "$(Get-Date -Format o) RESTART $Message"
    } catch {
        # Diagnostics must not change restart behavior.
    }
}

function Test-LoopbackHost {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $normalized = $HostName.Trim("[", "]").ToLowerInvariant()
    if ($normalized -in @("localhost", "::1", "::ffff:127.0.0.1")) {
        return $true
    }
    return $normalized -match '^127(?:\.\d{1,3}){3}$'
}

function Get-BridgeSettings {
    $hostName = Get-ScopedEnvironmentValue "BRIDGE_HOST"
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $hostName = "127.0.0.1"
    }

    $portText = Get-ScopedEnvironmentValue "BRIDGE_PORT"
    if ([string]::IsNullOrWhiteSpace($portText)) {
        $portText = "15720"
    }
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "BRIDGE_PORT must be an integer between 1 and 65535."
    }

    $upstream = Get-ScopedEnvironmentValue "UPSTREAM"
    if ([string]::IsNullOrWhiteSpace($upstream)) {
        throw "UPSTREAM is not configured in the selected environment scope."
    }
    try {
        $upstreamUri = [Uri]$upstream
    } catch {
        throw "UPSTREAM must be a valid absolute URL."
    }
    if ($upstreamUri.Scheme -notin @("http", "https") -or [string]::IsNullOrWhiteSpace($upstreamUri.Host)) {
        throw "UPSTREAM must use an absolute http or https URL."
    }
    if ((Test-LoopbackHost $upstreamUri.Host) -and $upstreamUri.Port -eq $port) {
        throw "UPSTREAM must not point to the Vision Bridge listener."
    }

    $visionKey = Get-ScopedEnvironmentValue "VISION_API_KEY"
    if ([string]::IsNullOrWhiteSpace($visionKey)) {
        throw "VISION_API_KEY is not configured in the selected environment scope."
    }

    $startupTimeoutText = Get-ScopedEnvironmentValue "BRIDGE_STARTUP_TIMEOUT_MS"
    if ([string]::IsNullOrWhiteSpace($startupTimeoutText)) {
        $startupTimeoutText = "30000"
    }
    $startupTimeoutMs = 0
    if ((-not [int]::TryParse($startupTimeoutText, [ref]$startupTimeoutMs)) -or
        ($startupTimeoutMs -lt 1000) -or ($startupTimeoutMs -gt 120000)) {
        throw "BRIDGE_STARTUP_TIMEOUT_MS must be an integer between 1000 and 120000."
    }

    return [pscustomobject]@{
        Host = $hostName
        Port = $port
        StartupTimeoutMs = $startupTimeoutMs
    }
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

function Get-ManagedProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    if ($null -eq $cimProcess) {
        throw "The bridge process disappeared while it was being inspected."
    }
    if (([string]::IsNullOrWhiteSpace($cimProcess.CommandLine)) -or
        (-not (Test-ScriptArgument -CommandLine $cimProcess.CommandLine -ScriptPath $ScriptPath))) {
        throw "The bridge port is occupied by a process that is not the installed Vision Bridge."
    }
    if (([string]::IsNullOrWhiteSpace($cimProcess.ExecutablePath)) -or
        ([IO.Path]::GetFileName($cimProcess.ExecutablePath) -ine "node.exe")) {
        throw "The process occupying the bridge port is not node.exe."
    }

    $owner = Invoke-CimMethod -InputObject $cimProcess -MethodName GetOwner -ErrorAction Stop
    if (($owner.ReturnValue -ne 0) -or ([string]::IsNullOrWhiteSpace($owner.User)) -or
        ([string]::IsNullOrWhiteSpace($owner.Domain))) {
        throw "The bridge process owner could not be verified."
    }
    try {
        $ownerKey = Convert-OwnerToSid -Domain $owner.Domain -User $owner.User
    } catch {
        throw "The bridge process owner could not be resolved to the current Windows identity."
    }
    if ($ownerKey -ne (Get-CurrentOwnerKey)) {
        throw "The process occupying the bridge port belongs to a different Windows user."
    }

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $startTimeUtc = $process.StartTime.ToUniversalTime()
    # Open the process handle before the second snapshot so Kill uses this process object.
    $null = $process.Handle

    return [pscustomobject]@{
        Process = $process
        ProcessId = $ProcessId
        CommandLine = $cimProcess.CommandLine
        ExecutablePath = $cimProcess.ExecutablePath
        OwnerKey = $ownerKey
        StartTimeUtcTicks = $startTimeUtc.Ticks
    }
}

function Test-SameProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Left,
        [Parameter(Mandatory = $true)][object]$Right
    )

    return (
        ($Left.ProcessId -eq $Right.ProcessId) -and
        ($Left.CommandLine -ceq $Right.CommandLine) -and
        ($Left.ExecutablePath -ceq $Right.ExecutablePath) -and
        ($Left.OwnerKey -ceq $Right.OwnerKey) -and
        ($Left.StartTimeUtcTicks -eq $Right.StartTimeUtcTicks)
    )
}

function Get-ListeningProcessIds {
    param([Parameter(Mandatory = $true)][int]$Port)

    return @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object { [int]$_ }
    )
}

function Wait-BridgePortReleased {
    param([Parameter(Mandatory = $true)][int]$Port)

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        if ((Get-ListeningProcessIds -Port $Port).Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Bridge port $Port did not become available after the managed process stopped."
}

function Stop-VerifiedManagedBridge {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ScriptPath
    )

    $initialIds = @(Get-ListeningProcessIds -Port $Port)
    if ($initialIds.Count -eq 0) {
        return
    }
    $initialSnapshots = @()
    foreach ($processId in $initialIds) {
        $initialSnapshots += Get-ManagedProcessSnapshot -ProcessId $processId -ScriptPath $ScriptPath
    }

    try {
        $secondIds = @(Get-ListeningProcessIds -Port $Port)
        $initialIdKey = (@($initialIds | Sort-Object) -join ",")
        $secondIdKey = (@($secondIds | Sort-Object) -join ",")
        if ($secondIdKey -ne $initialIdKey) {
            throw "Bridge port ownership changed during rollback verification; refusing to stop any process."
        }
        $secondSnapshots = @()
        foreach ($processId in $secondIds) {
            $secondSnapshots += Get-ManagedProcessSnapshot -ProcessId $processId -ScriptPath $ScriptPath
        }
        foreach ($snapshot in $secondSnapshots) {
            $initialSnapshot = $initialSnapshots |
                Where-Object { $_.ProcessId -eq $snapshot.ProcessId } |
                Select-Object -First 1
            if ($null -eq $initialSnapshot -or -not (Test-SameProcessSnapshot -Left $initialSnapshot -Right $snapshot)) {
                throw "Bridge process identity changed during rollback verification; refusing to stop any process."
            }
        }
        foreach ($snapshot in $secondSnapshots) {
            try {
                $snapshot.Process.Kill()
                if (-not $snapshot.Process.WaitForExit(5000)) {
                    throw "Managed Vision Bridge process did not exit during rollback."
                }
            } finally {
                $snapshot.Process.Dispose()
            }
        }
        Wait-BridgePortReleased -Port $Port
    } finally {
        foreach ($snapshot in $initialSnapshots) {
            $snapshot.Process.Dispose()
        }
    }
}

function Get-PowerShellPath {
    $systemPowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $systemPowerShell -PathType Leaf) {
        return $systemPowerShell
    }
    $command = Get-Command powershell.exe -ErrorAction Stop
    return $command.Source
}

function Sync-ProcessEnvironment {
    foreach ($name in $environmentNames) {
        $value = Get-ScopedEnvironmentValue $name
        [Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

function Sync-ProcessPath {
    $pathValues = @(
        [Environment]::GetEnvironmentVariable("Path", "User"),
        [Environment]::GetEnvironmentVariable("Path", "Machine"),
        [Environment]::GetEnvironmentVariable("Path", "Process")
    )
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $entries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in $pathValues) {
        foreach ($entry in ([string]$value -split [IO.Path]::PathSeparator)) {
            $normalized = $entry.Trim()
            if ($normalized -and $seen.Add($normalized)) {
                $entries.Add($normalized)
            }
        }
    }
    if ($entries.Count -gt 0) {
        [Environment]::SetEnvironmentVariable("Path", ($entries -join [IO.Path]::PathSeparator), "Process")
    }
}

function Save-RollbackSnapshotFromProcess {
    $temporaryPath = "$rollbackStatePath.$PID.tmp"
    try {
        $snapshot = [ordered]@{}
        foreach ($name in $rollbackEnvironmentNames) {
            $snapshot[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }
        $json = $snapshot | ConvertTo-Json -Compress
        $secureSnapshot = ConvertTo-SecureString -String $json -AsPlainText -Force
        $encryptedSnapshot = ConvertFrom-SecureString -SecureString $secureSnapshot
        Set-Content -LiteralPath $temporaryPath -Value $encryptedSnapshot -Encoding ASCII -Force
        Move-Item -LiteralPath $temporaryPath -Destination $rollbackStatePath -Force
    } catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw "The new bridge is healthy, but its protected rollback state could not be saved."
    }
}

function Get-RollbackSnapshot {
    if (-not (Test-Path -LiteralPath $rollbackStatePath -PathType Leaf)) {
        return $null
    }

    try {
        $encryptedSnapshot = (Get-Content -Raw -Encoding ASCII -LiteralPath $rollbackStatePath).Trim()
        if ([string]::IsNullOrWhiteSpace($encryptedSnapshot)) {
            throw "protected rollback state is empty"
        }
        $secureSnapshot = ConvertTo-SecureString -String $encryptedSnapshot
        $snapshotPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSnapshot)
        try {
            $json = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($snapshotPointer)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($snapshotPointer)
        }
        $snapshot = $json | ConvertFrom-Json
        if ($null -eq $snapshot) {
            throw "protected rollback state did not contain an object"
        }
        foreach ($name in @("UPSTREAM", "VISION_API_KEY", "BRIDGE_HOST", "BRIDGE_PORT")) {
            $property = $snapshot.PSObject.Properties[$name]
            if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                throw "protected rollback state is missing required configuration"
            }
        }
        return $snapshot
    } catch {
        throw "Protected rollback state could not be read; refusing to stop the current bridge."
    }
}

function Get-RollbackValue {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Snapshot.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $null
    }
    return [string]$property.Value
}

function Set-ProcessEnvironmentFromSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    foreach ($name in $rollbackEnvironmentNames) {
        [Environment]::SetEnvironmentVariable(
            $name,
            (Get-RollbackValue -Snapshot $Snapshot -Name $name),
            "Process"
        )
    }
}

function Get-RollbackSettings {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $hostName = Get-RollbackValue -Snapshot $Snapshot -Name "BRIDGE_HOST"
    $portText = Get-RollbackValue -Snapshot $Snapshot -Name "BRIDGE_PORT"
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Protected rollback state contains an invalid bridge port."
    }

    $startupTimeoutText = Get-RollbackValue -Snapshot $Snapshot -Name "BRIDGE_STARTUP_TIMEOUT_MS"
    if ([string]::IsNullOrWhiteSpace($startupTimeoutText)) {
        $startupTimeoutText = "30000"
    }
    $startupTimeoutMs = 0
    if (-not [int]::TryParse($startupTimeoutText, [ref]$startupTimeoutMs) -or
        $startupTimeoutMs -lt 1000 -or $startupTimeoutMs -gt 120000) {
        throw "Protected rollback state contains an invalid startup timeout."
    }

    return [pscustomobject]@{
        Host = $hostName
        Port = $port
        StartupTimeoutMs = $startupTimeoutMs
    }
}

function Test-BridgeHealth {
    param([Parameter(Mandatory = $true)][object]$Settings)

    $healthHost = $Settings.Host
    if ($healthHost -eq "0.0.0.0") {
        $healthHost = "127.0.0.1"
    } elseif ($healthHost -eq "::") {
        $healthHost = "::1"
    }
    $healthUri = if ($healthHost.Contains(":")) {
        "http://[$healthHost]:$($Settings.Port)/health"
    } else {
        "http://$healthHost`:$($Settings.Port)/health"
    }
    $headers = @{}
    $token = [Environment]::GetEnvironmentVariable("BRIDGE_AUTH_TOKEN", "Process")
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        $headers["x-bridge-token"] = $token
    }
    try {
        $health = Invoke-RestMethod -Uri $healthUri -Headers $headers -TimeoutSec 2 -ErrorAction Stop
        return $health.ok -eq $true -and
            $health.service -eq "vision-bridge" -and
            $health.version -eq $expectedBridgeVersion
    } catch {
        return $false
    }
}

function Start-BridgeWithCurrentEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $false)][switch]$SyncSelectedEnvironment
    )

    if ($SyncSelectedEnvironment) {
        Sync-ProcessPath
        Sync-ProcessEnvironment
    }
    [Environment]::SetEnvironmentVariable("BRIDGE_HOST", $Settings.Host, "Process")
    [Environment]::SetEnvironmentVariable("BRIDGE_PORT", [string]$Settings.Port, "Process")
    [Environment]::SetEnvironmentVariable("BRIDGE_STARTUP_TIMEOUT_MS", [string]$Settings.StartupTimeoutMs, "Process")

    $powerShell = Get-PowerShellPath
    $argumentList = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        ('"' + $launcherScript + '"')
    )
    $launcherProcess = $null
    try {
        $launcherProcess = Start-Process `
            -FilePath $powerShell `
            -ArgumentList $argumentList `
            -WorkingDirectory $bridgeDir `
            -WindowStyle Hidden `
            -PassThru

        $deadline = [DateTime]::UtcNow.AddMilliseconds($Settings.StartupTimeoutMs + 10000)
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-BridgeHealth -Settings $Settings) {
                return
            }
            if ($launcherProcess.HasExited) {
                $exitCode = $launcherProcess.ExitCode
                throw "Vision Bridge launcher exited with code $exitCode. See $errorLogPath."
            }
            Start-Sleep -Milliseconds 250
        }
        throw "Vision Bridge did not pass health check within $($Settings.StartupTimeoutMs) ms. See $errorLogPath."
    } finally {
        if ($null -ne $launcherProcess) {
            $launcherProcess.Dispose()
        }
    }
}

$stoppedBridge = $false
$newBridgeHealthy = $false
$rollbackSnapshot = $null
$rollbackSettings = $null

try {
    Write-RestartTrace "begin"
    if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
        throw "Bridge script not found: $bridgeScript"
    }
    if (-not (Test-Path -LiteralPath $launcherScript -PathType Leaf)) {
        throw "Bridge launcher not found: $launcherScript"
    }

    $Settings = Get-BridgeSettings
    Write-RestartTrace "configuration validated"
    $initialIds = @(Get-ListeningProcessIds -Port $Settings.Port)
    Write-RestartTrace ("initial listener count=" + $initialIds.Count)

    if ($initialIds.Count -gt 0) {
        try {
            $rollbackSnapshot = Get-RollbackSnapshot
        } catch {
            if (-not $BootstrapRollbackState) {
                throw
            }
            Write-RestartTrace "existing protected rollback state is unreadable; bootstrapping a replacement"
            $rollbackSnapshot = $null
        }
        if ($null -ne $rollbackSnapshot) {
            $rollbackSettings = Get-RollbackSettings -Snapshot $rollbackSnapshot
            if ($rollbackSettings.Port -ne $Settings.Port -or
                $rollbackSettings.Host -ine $Settings.Host) {
                throw "Protected rollback state belongs to a different bridge listener; refusing to stop the current bridge."
            }
        } else {
            if (-not $BootstrapRollbackState) {
                throw "No protected previous configuration is available; refusing to stop the current bridge. For a pre-rollback-state installation, confirm the current user environment is the running bridge configuration, then retry with -BootstrapRollbackState; otherwise restart Windows first."
            }

            $bootstrapSnapshots = @()
            try {
                foreach ($processId in $initialIds) {
                    $bootstrapSnapshots += Get-ManagedProcessSnapshot -ProcessId $processId -ScriptPath $bridgeScript
                }
                Sync-ProcessPath
                Sync-ProcessEnvironment
                [Environment]::SetEnvironmentVariable("BRIDGE_HOST", $Settings.Host, "Process")
                [Environment]::SetEnvironmentVariable("BRIDGE_PORT", [string]$Settings.Port, "Process")
                [Environment]::SetEnvironmentVariable("BRIDGE_STARTUP_TIMEOUT_MS", [string]$Settings.StartupTimeoutMs, "Process")
                if (-not (Test-BridgeHealth -Settings $Settings)) {
                    throw "The existing managed Vision Bridge did not pass the health check with the selected environment; refusing to bootstrap rollback state."
                }
                Save-RollbackSnapshotFromProcess
                $rollbackSnapshot = Get-RollbackSnapshot
                $rollbackSettings = Get-RollbackSettings -Snapshot $rollbackSnapshot
            } finally {
                foreach ($snapshot in $bootstrapSnapshots) {
                    $snapshot.Process.Dispose()
                }
            }
        }
        Write-RestartTrace "stopping verified bridge process"
        Stop-VerifiedManagedBridge -Port $Settings.Port -ScriptPath $bridgeScript
        $stoppedBridge = $true
        Write-RestartTrace "port released"
    }

    Write-RestartTrace "starting bridge with selected environment"
    Start-BridgeWithCurrentEnvironment -Settings $Settings -SyncSelectedEnvironment
    Save-RollbackSnapshotFromProcess
    $newBridgeHealthy = $true
    Write-RestartTrace "launcher completed"
    Write-Output "Vision Bridge restarted and passed its startup health check on port $($Settings.Port)."
} catch {
    $failureMessage = $_.Exception.Message
    if ($stoppedBridge -and -not $newBridgeHealthy) {
        if ($null -ne $rollbackSnapshot) {
            try {
                Write-RestartTrace "attempting rollback to the previous protected configuration"
                Stop-VerifiedManagedBridge -Port $Settings.Port -ScriptPath $bridgeScript
                Set-ProcessEnvironmentFromSnapshot -Snapshot $rollbackSnapshot
                Start-BridgeWithCurrentEnvironment -Settings $rollbackSettings
                $failureMessage = "$failureMessage Previous Vision Bridge configuration was restored successfully."
                Write-RestartTrace "rollback completed"
            } catch {
                $failureMessage = "$failureMessage Rollback failed; the previous Vision Bridge configuration could not be restored."
                Write-RestartTrace "rollback failed"
            }
        } else {
            $failureMessage = "$failureMessage No protected previous configuration was available for rollback."
        }
    }
    Write-RestartFailure $failureMessage
    exit 1
}
