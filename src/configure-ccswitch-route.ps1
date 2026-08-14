[CmdletBinding()]
param(
    [string]$CCSwitchDirectory = (Join-Path $env:USERPROFILE ".cc-switch"),
    [string]$SettingsPath,
    [string]$DatabasePath,
    [string]$SQLitePath = "sqlite3.exe",
    [ValidateSet("claude", "claude-desktop")]
    [string]$AppType,
    [string]$ProviderId,
    [string]$BridgeHost = "127.0.0.1",
    [ValidateRange(1, 65535)]
    [int]$BridgePort = 15720,
    [ValidateRange(1, 65535)]
    [int]$CCSwitchPort = 15721,
    [ValidateRange(1, 60)]
    [int]$CCSwitchStartupTimeoutSeconds = 20,
    [string]$CCSwitchProcessName = "cc-switch",
    [string]$BackupDirectory,
    [switch]$ForceCloseCCSwitch,
    [switch]$SkipCCSwitchRestart
)

$ErrorActionPreference = "Stop"

function Test-LoopbackHost {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $normalized = $HostName.Trim("[", "]").ToLowerInvariant()
    return $normalized -in @("localhost", "::1", "::ffff:127.0.0.1") -or
        $normalized -match '^127(?:\.\d{1,3}){3}$'
}

function Get-CurrentOwnerSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-ProcessOwnerSid {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    $owner = Invoke-CimMethod -InputObject $processInfo -MethodName GetOwner -ErrorAction Stop
    if ($owner.ReturnValue -ne 0 -or
        [string]::IsNullOrWhiteSpace($owner.Domain) -or
        [string]::IsNullOrWhiteSpace($owner.User)) {
        throw "CC Switch process ownership could not be verified."
    }
    $account = New-Object System.Security.Principal.NTAccount($owner.Domain, $owner.User)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Get-VerifiedCCSwitchProcess {
    param([Parameter(Mandatory = $true)][string]$ProcessName)

    if ($ProcessName -notmatch '^[A-Za-z0-9_-]+$') {
        throw "CCSwitchProcessName contains unsupported characters."
    }
    $processes = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return $null
    }
    if ($processes.Count -ne 1) {
        throw "Multiple CC Switch processes were found; refusing to stop an ambiguous process set."
    }

    $process = $processes[0]
    $path = [string]$process.Path
    if ([string]::IsNullOrWhiteSpace($path) -or
        [IO.Path]::GetFileName($path) -ine "$ProcessName.exe" -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The detected CC Switch process executable could not be verified."
    }
    if ((Get-ProcessOwnerSid -ProcessId $process.Id) -ne (Get-CurrentOwnerSid)) {
        throw "The detected CC Switch process belongs to a different Windows user."
    }

    return [pscustomobject]@{
        Process = $process
        Path = $path
    }
}

function Stop-VerifiedCCSwitch {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    if (-not $ForceCloseCCSwitch) {
        throw "CC Switch is running. Re-run with -ForceCloseCCSwitch to close and restart only this verified process."
    }

    $process = $Snapshot.Process
    if ($process.MainWindowHandle -ne 0) {
        $null = $process.CloseMainWindow()
        if ($process.WaitForExit(5000)) {
            $process.Dispose()
            return
        }
    }
    if (-not $process.HasExited) {
        $process.Kill()
        if (-not $process.WaitForExit(5000)) {
            $process.Dispose()
            throw "Verified CC Switch process did not exit."
        }
    }
    $process.Dispose()
}

function Get-SqliteExecutable {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
        return [IO.Path]::GetFullPath($Candidate)
    }
    $command = Get-Command -Name $Candidate -CommandType Application -ErrorAction Stop
    return $command.Source
}

function Get-NodeExecutable {
    $command = Get-Command -Name "node.exe" -CommandType Application -ErrorAction Stop
    return $command.Source
}

function Invoke-NodeSqlite {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("backup", "scalar", "rows", "execute")][string]$Operation,
        [Parameter(Mandatory = $false)][string]$Sql,
        [Parameter(Mandatory = $false)][string]$BackupPath
    )

    $request = [ordered]@{
        operation = $Operation
        databasePath = $script:resolvedDatabasePath
        sql = $Sql
        backupPath = $BackupPath
    } | ConvertTo-Json -Compress
    $output = @($request | & $script:nodeExecutable $script:nodeSqliteHelper 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Node built-in SQLite command failed."
    }
    return @(
        $output |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Invoke-SqliteRows {
    param([Parameter(Mandatory = $true)][string]$Sql)

    if ($script:sqliteEngine -eq "node") {
        return Invoke-NodeSqlite -Operation "rows" -Sql $Sql
    }
    $output = @(& $script:sqliteExecutable -batch -noheader $script:resolvedDatabasePath $Sql 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "CC Switch database command failed."
    }
    return @(
        $output |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-SqliteScalar {
    param([Parameter(Mandatory = $true)][string]$Sql)

    if ($script:sqliteEngine -eq "node") {
        $rows = @(Invoke-NodeSqlite -Operation "scalar" -Sql $Sql)
    } else {
        $rows = @(Invoke-SqliteRows -Sql $Sql)
    }
    if ($rows.Count -ne 1) {
        throw "CC Switch database returned an unexpected result."
    }
    return $rows[0]
}

function Backup-SqliteDatabase {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    if ($script:sqliteEngine -eq "node") {
        Invoke-NodeSqlite -Operation "backup" -BackupPath $BackupPath | Out-Null
        return
    }
    $escapedBackupPath = $BackupPath.Replace("'", "''")
    Invoke-SqliteRows -Sql ".backup '$escapedBackupPath'" | Out-Null
}

function Update-SqliteProviderRoute {
    param([Parameter(Mandatory = $true)][string]$Sql)

    if ($script:sqliteEngine -eq "node") {
        $rows = @(Invoke-NodeSqlite -Operation "execute" -Sql $Sql)
        if ($rows.Count -ne 1) {
            throw "CC Switch database route update returned an unexpected result."
        }
        return $rows[0]
    }
    return Get-SqliteScalar -Sql "BEGIN IMMEDIATE; $Sql SELECT changes(); COMMIT;"
}

function Get-BridgeHealth {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Port
    )

    $healthHost = if ($HostName -eq "0.0.0.0") { "127.0.0.1" } elseif ($HostName -eq "::") { "::1" } else { $HostName }
    $healthUri = if ($healthHost.Contains(":")) {
        "http://[$healthHost]:$Port/health"
    } else {
        "http://$healthHost`:$Port/health"
    }
    $headers = @{}
    $bridgeToken = [Environment]::GetEnvironmentVariable("BRIDGE_AUTH_TOKEN", "User")
    if (-not [string]::IsNullOrWhiteSpace($bridgeToken)) {
        $headers["x-bridge-token"] = $bridgeToken
    }

    try {
        $health = Invoke-RestMethod -Uri $healthUri -Headers $headers -TimeoutSec 2 -ErrorAction Stop
        return $health.ok -eq $true -and $health.service -eq "vision-bridge"
    } catch {
        return $false
    }
}

function Wait-ForPortListener {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count -gt 0) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Restore-DatabaseSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$DatabaseFile,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )

    $failedDirectory = Join-Path $DestinationDirectory "failed-state"
    New-Item -ItemType Directory -Force -Path $failedDirectory | Out-Null
    foreach ($suffix in @("", "-wal", "-shm")) {
        $source = "$DatabaseFile$suffix"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Move-Item -LiteralPath $source -Destination (Join-Path $failedDirectory ([IO.Path]::GetFileName($source))) -Force
        }
    }
    Copy-Item -LiteralPath $BackupPath -Destination $DatabaseFile -Force
}

function Get-SettingsCurrentProviderId {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }
    try {
        $settings = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    } catch {
        throw "CC Switch settings.json could not be parsed."
    }
    foreach ($propertyName in @("currentProviderClaude", "currentProviderClaudeDesktop")) {
        $property = $settings.PSObject.Properties[$propertyName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    return ""
}

function Assert-SafeIdentifier {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Value -notmatch '^[A-Za-z0-9._:-]+$') {
        throw "$Label contains unsupported characters."
    }
}

if (-not (Test-LoopbackHost -HostName $BridgeHost)) {
    throw "BridgeHost must be a loopback address."
}
if (-not (Get-BridgeHealth -HostName $BridgeHost -Port $BridgePort)) {
    throw "Vision Bridge is not healthy on the requested listener; the CC Switch route was not changed."
}

$resolvedSettingsPath = if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    Join-Path $CCSwitchDirectory "settings.json"
} else {
    $SettingsPath
}
$script:resolvedDatabasePath = if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
    Join-Path $CCSwitchDirectory "cc-switch.db"
} else {
    $DatabasePath
}
if (-not (Test-Path -LiteralPath $script:resolvedDatabasePath -PathType Leaf)) {
    throw "CC Switch database was not found."
}
$script:resolvedDatabasePath = [IO.Path]::GetFullPath($script:resolvedDatabasePath)
try {
    $script:sqliteExecutable = Get-SqliteExecutable -Candidate $SQLitePath
    $script:sqliteEngine = "cli"
} catch {
    $script:nodeExecutable = Get-NodeExecutable
    $script:nodeSqliteHelper = Join-Path $PSScriptRoot "cc-switch-sqlite.js"
    if (-not (Test-Path -LiteralPath $script:nodeSqliteHelper -PathType Leaf)) {
        throw "sqlite3.exe was not found and the Node SQLite helper is unavailable."
    }
    $null = @(& $script:nodeExecutable -e "require('node:sqlite')" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3.exe was not found and this Node.js version does not provide node:sqlite."
    }
    $script:sqliteEngine = "node"
}

if ([string]::IsNullOrWhiteSpace($ProviderId)) {
    $ProviderId = Get-SettingsCurrentProviderId -Path $resolvedSettingsPath
}
if ([string]::IsNullOrWhiteSpace($ProviderId)) {
    $currentProviderIds = @(Invoke-SqliteRows -Sql "SELECT DISTINCT id FROM providers WHERE app_type IN ('claude', 'claude-desktop') AND is_current = 1 ORDER BY id;")
    if ($currentProviderIds.Count -ne 1) {
        throw "The active Claude provider could not be identified; supply -ProviderId and -AppType explicitly."
    }
    $ProviderId = $currentProviderIds[0]
}
Assert-SafeIdentifier -Value $ProviderId -Label "ProviderId"

if ([string]::IsNullOrWhiteSpace($AppType)) {
    $appTypes = @(Invoke-SqliteRows -Sql "SELECT app_type FROM providers WHERE id = '$ProviderId' AND app_type IN ('claude', 'claude-desktop') ORDER BY app_type;")
    if ($appTypes.Count -eq 0) {
        throw "The active Claude provider does not have a supported app type; the route was not changed."
    }
} else {
    $appTypes = @($AppType)
}
$appTypePredicate = ($appTypes | ForEach-Object { "'$_'" }) -join ", "

$providerShape = Get-SqliteScalar -Sql @"
SELECT CASE
    WHEN COUNT(*) <> $($appTypes.Count) THEN 0
    WHEN MIN(CASE
        WHEN json_valid(settings_config) <> 1 THEN 0
        WHEN json_type(settings_config, '$.env') <> 'object' THEN 0
        WHEN json_type(settings_config, '$.env.ANTHROPIC_BASE_URL') <> 'text' THEN 0
        ELSE 1
    END) <> 1 THEN 0
    ELSE 1
END
FROM providers
WHERE id = '$ProviderId' AND app_type IN ($appTypePredicate);
"@
if ($providerShape -ne "1") {
    throw "The active Claude provider does not have a supported Anthropic base URL field; the route was not changed."
}

$routeUrl = if ($BridgeHost.Contains(":")) {
    "http://[$BridgeHost]:$BridgePort"
} else {
    "http://$BridgeHost`:$BridgePort"
}
$currentRoutes = @(Invoke-SqliteRows -Sql "SELECT json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') FROM providers WHERE id = '$ProviderId' AND app_type IN ($appTypePredicate) ORDER BY app_type;")
if (@($currentRoutes | Where-Object { $_ -ne $routeUrl }).Count -eq 0) {
    Write-Output "CC Switch active Claude provider already targets the healthy Vision Bridge."
    return
}

$ccSwitch = Get-VerifiedCCSwitchProcess -ProcessName $CCSwitchProcessName
if ($null -ne $ccSwitch -and $SkipCCSwitchRestart) {
    throw "-SkipCCSwitchRestart cannot be used while CC Switch is running."
}

$operationId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$backupRoot = if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    Join-Path $env:USERPROFILE ".claude\bridge\backups\cc-switch-route-$operationId"
} else {
    $BackupDirectory
}
$backupRoot = [IO.Path]::GetFullPath($backupRoot)
$backupDatabasePath = Join-Path $backupRoot "cc-switch.db"
$databaseChanged = $false
$ccSwitchStopped = $false
$ccSwitchStarted = $false

try {
    if ($null -ne $ccSwitch) {
        Stop-VerifiedCCSwitch -Snapshot $ccSwitch
        $ccSwitchStopped = $true
    }

    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Backup-SqliteDatabase -BackupPath $backupDatabasePath
    if (-not (Test-Path -LiteralPath $backupDatabasePath -PathType Leaf)) {
        throw "CC Switch database backup was not created."
    }

    $updatedRows = Update-SqliteProviderRoute -Sql @"
UPDATE providers
SET settings_config = json_set(settings_config, '$.env.ANTHROPIC_BASE_URL', '$routeUrl')
WHERE id = '$ProviderId' AND app_type IN ($appTypePredicate);
"@
    if ($updatedRows -ne [string]$appTypes.Count) {
        throw "The active Claude provider was not updated for every selected app type."
    }
    $databaseChanged = $true

    $verifiedRoutes = @(Invoke-SqliteRows -Sql "SELECT json_extract(settings_config, '$.env.ANTHROPIC_BASE_URL') FROM providers WHERE id = '$ProviderId' AND app_type IN ($appTypePredicate) ORDER BY app_type;")
    if (@($verifiedRoutes | Where-Object { $_ -ne $routeUrl }).Count -ne 0) {
        throw "CC Switch database route verification failed."
    }

    if ($ccSwitchStopped) {
        $started = Start-Process -FilePath $ccSwitch.Path -WorkingDirectory (Split-Path -Parent $ccSwitch.Path) -WindowStyle Hidden -PassThru
        $ccSwitchStarted = $true
        $started.Dispose()
        if (-not (Wait-ForPortListener -Port $CCSwitchPort -TimeoutSeconds $CCSwitchStartupTimeoutSeconds)) {
            throw "CC Switch did not resume its local proxy listener after the route update."
        }
    }

    Write-Output "CC Switch active Claude provider now targets the healthy Vision Bridge."
    Write-Output "CC Switch database backup: $backupDatabasePath"
} catch {
    $failureMessage = $_.Exception.Message
    if ($databaseChanged) {
        try {
            if ($ccSwitchStarted) {
                $replacement = Get-VerifiedCCSwitchProcess -ProcessName $CCSwitchProcessName
                if ($null -ne $replacement) {
                    $originalForceClose = $ForceCloseCCSwitch
                    $ForceCloseCCSwitch = $true
                    Stop-VerifiedCCSwitch -Snapshot $replacement
                    $ForceCloseCCSwitch = $originalForceClose
                }
            }
            Restore-DatabaseSnapshot -BackupPath $backupDatabasePath -DatabaseFile $script:resolvedDatabasePath -DestinationDirectory $backupRoot
            $failureMessage = "$failureMessage CC Switch database route was restored from its backup."
        } catch {
            $failureMessage = "$failureMessage CC Switch database route rollback failed."
        }
    }
    if ($ccSwitchStopped) {
        try {
            $current = Get-VerifiedCCSwitchProcess -ProcessName $CCSwitchProcessName
            if ($null -eq $current) {
                $restarted = Start-Process -FilePath $ccSwitch.Path -WorkingDirectory (Split-Path -Parent $ccSwitch.Path) -WindowStyle Hidden -PassThru
                $restarted.Dispose()
            }
        } catch {
            $failureMessage = "$failureMessage CC Switch could not be restarted automatically."
        }
    }
    throw $failureMessage
}
