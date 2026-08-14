[CmdletBinding()]
param(
    [string]$InstallUserProfile = $env:USERPROFILE,
    [string]$StartupDirectory = [Environment]::GetFolderPath("Startup"),
    [string]$CCSwitchRunValueName = "CC Switch",
    [string]$CCSwitchRunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    [switch]$SkipCCSwitchStartupCoordination,
    [switch]$ConfigureCCSwitchRoute
)

$ErrorActionPreference = "Stop"

$sourceDir = $PSScriptRoot
$bridgeDir = Join-Path $InstallUserProfile ".claude\bridge"
$skillDir = Join-Path $InstallUserProfile ".claude\skills\vision"
$startupDir = $StartupDirectory
$ccSwitchCommandPath = Join-Path $bridgeDir "cc-switch-startup.command"
$ccSwitchCoordinatorPath = Join-Path $bridgeDir "start-ccswitch-after-bridge.vbs"
$installId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) "claude-deepseek-vision-bridge-$installId"
$backupRoot = Join-Path $bridgeDir "backups\install-$installId"

$sourceItems = @(
    [pscustomobject]@{
        Source = Join-Path $sourceDir "vision-bridge.js"
        Destination = Join-Path $bridgeDir "vision-bridge.js"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "vision-client.js"
        Destination = Join-Path $bridgeDir "vision-client.js"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "start-vision-bridge.ps1"
        Destination = Join-Path $bridgeDir "start-vision-bridge.ps1"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "restart-vision-bridge.ps1"
        Destination = Join-Path $bridgeDir "restart-vision-bridge.ps1"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "start-ccswitch-after-bridge.vbs"
        Destination = Join-Path $bridgeDir "start-ccswitch-after-bridge.vbs"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "restore-ccswitch-startup.ps1"
        Destination = Join-Path $bridgeDir "restore-ccswitch-startup.ps1"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "diagnose-vision-bridge.ps1"
        Destination = Join-Path $bridgeDir "diagnose-vision-bridge.ps1"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "configure-ccswitch-route.ps1"
        Destination = Join-Path $bridgeDir "configure-ccswitch-route.ps1"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "cc-switch-sqlite.js"
        Destination = Join-Path $bridgeDir "cc-switch-sqlite.js"
        Label = "bridge"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "vision.js"
        Destination = Join-Path $skillDir "vision.js"
        Label = "skill"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "vision-client.js"
        Destination = Join-Path $skillDir "vision-client.js"
        Label = "skill"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "SKILL.md.template"
        Destination = Join-Path $skillDir "SKILL.md"
        Label = "skill"
    }
    [pscustomobject]@{
        Source = Join-Path $sourceDir "vision-bridge.vbs"
        Destination = Join-Path $startupDir "vision-bridge.vbs"
        Label = "startup"
    }
)

$stagedItems = @()
$backupRecords = @()
$registryChanged = $false
$ccSwitchRunExisted = $false
$ccSwitchOriginalCommand = ""
$ccSwitchCoordinationEnabled = $false
$ccSwitchCommandExisted = $false
$ccSwitchCommandBackupPath = Join-Path $backupRoot "bridge\cc-switch-startup.command"

function Get-RunValue {
    param(
        [Parameter(Mandatory = $true)][string]$KeyPath,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        return $null
    }
    $properties = Get-ItemProperty -LiteralPath $KeyPath
    return $properties.PSObject.Properties |
        Where-Object { $_.Name -eq $ValueName } |
        Select-Object -First 1
}

function Get-OriginalCCSwitchCommand {
    param([Parameter(Mandatory = $false)][object]$RunValue)

    if ($null -eq $RunValue) {
        return ""
    }
    $currentCommand = [string]$RunValue.Value
    if ($currentCommand -match "(?i)start-ccswitch-after-bridge\.vbs") {
        if (-not (Test-Path -LiteralPath $ccSwitchCommandPath -PathType Leaf)) {
            throw "CC Switch startup is already managed, but the original command file is missing: $ccSwitchCommandPath"
        }
        return (Get-Content -Raw -Encoding Unicode -LiteralPath $ccSwitchCommandPath).Trim()
    }
    if ($currentCommand -notmatch "(?i)cc[-_ ]?switch") {
        return ""
    }
    return $currentCommand
}

try {
    if ([string]::IsNullOrWhiteSpace($startupDir)) {
        throw "Windows Startup folder could not be resolved."
    }
    foreach ($item in $sourceItems) {
        if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
            throw "Installer source file not found: $($item.Source)"
        }
    }

    if (-not $SkipCCSwitchStartupCoordination) {
        $ccSwitchRunValue = Get-RunValue -KeyPath $CCSwitchRunKeyPath -ValueName $CCSwitchRunValueName
        if ($null -ne $ccSwitchRunValue) {
            $ccSwitchRunExisted = $true
            $ccSwitchOriginalCommand = Get-OriginalCCSwitchCommand -RunValue $ccSwitchRunValue
            $ccSwitchCoordinationEnabled = -not [string]::IsNullOrWhiteSpace($ccSwitchOriginalCommand)
        }
    }

    New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

    # Stage and hash every source before changing the user's installation.
    $stageIndex = 0
    foreach ($item in $sourceItems) {
        $stageIndex += 1
        $stagePath = Join-Path $stagingRoot ("{0}-{1}" -f $stageIndex, [IO.Path]::GetFileName($item.Source))
        Copy-Item -LiteralPath $item.Source -Destination $stagePath -Force
        $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.Source).Hash
        $stageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagePath).Hash
        if ($sourceHash -ne $stageHash) {
            throw "Staged installer file failed verification: $($item.Source)"
        }
        $stagedItems += [pscustomobject]@{
            Source = $item.Source
            Stage = $stagePath
            Destination = $item.Destination
            Label = $item.Label
            Hash = $sourceHash
        }
    }

    New-Item -ItemType Directory -Force -Path $bridgeDir, $skillDir, $startupDir | Out-Null
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

    if ($ccSwitchCoordinationEnabled) {
        $ccSwitchCommandExisted = Test-Path -LiteralPath $ccSwitchCommandPath -PathType Leaf
        if ($ccSwitchCommandExisted) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ccSwitchCommandBackupPath) | Out-Null
            Copy-Item -LiteralPath $ccSwitchCommandPath -Destination $ccSwitchCommandBackupPath -Force
        }
        $backupRecords += [pscustomobject]@{
            Destination = $ccSwitchCommandPath
            Backup = $ccSwitchCommandBackupPath
            Existed = $ccSwitchCommandExisted
        }
    }

    foreach ($item in $stagedItems) {
        $destinationExists = Test-Path -LiteralPath $item.Destination
        if ($destinationExists -and -not (Test-Path -LiteralPath $item.Destination -PathType Leaf)) {
            throw "Refusing to overwrite a non-file managed destination: $($item.Destination)"
        }
        $backupDir = Join-Path $backupRoot $item.Label
        $backupPath = Join-Path $backupDir ([IO.Path]::GetFileName($item.Destination))
        if ($destinationExists) {
            $destinationInfo = Get-Item -LiteralPath $item.Destination -Force
            if (($destinationInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to overwrite a reparse point: $($item.Destination)"
            }
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Copy-Item -LiteralPath $item.Destination -Destination $backupPath -Force
        }
        $backupRecords += [pscustomobject]@{
            Destination = $item.Destination
            Backup = $backupPath
            Existed = $destinationExists
        }
    }

    $backupRecords | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $backupRoot "manifest.json") -Encoding UTF8

    # Install the runtime and skill first. Replace the Startup entry last.
    foreach ($item in ($stagedItems | Where-Object { $_.Label -ne "startup" })) {
        Copy-Item -LiteralPath $item.Stage -Destination $item.Destination -Force
    }
    foreach ($item in ($stagedItems | Where-Object { $_.Label -eq "startup" })) {
        Copy-Item -LiteralPath $item.Stage -Destination $item.Destination -Force
    }

    if ($ccSwitchCoordinationEnabled) {
        Set-Content -LiteralPath $ccSwitchCommandPath -Value $ccSwitchOriginalCommand -Encoding Unicode
        Set-ItemProperty -LiteralPath $CCSwitchRunKeyPath -Name $CCSwitchRunValueName -Value (
            '"' + (Join-Path $env:SystemRoot "System32\wscript.exe") + '" //B //NoLogo "' + $ccSwitchCoordinatorPath + '"'
        )
        $registryChanged = $true
    }

    foreach ($item in $stagedItems) {
        $installedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.Destination).Hash
        if ($installedHash -ne $item.Hash) {
            throw "Installed file failed verification: $($item.Destination)"
        }
    }

    if ($ccSwitchCoordinationEnabled) {
        $installedRunValue = Get-RunValue -KeyPath $CCSwitchRunKeyPath -ValueName $CCSwitchRunValueName
        if ($null -eq $installedRunValue -or [string]$installedRunValue.Value -notmatch "(?i)start-ccswitch-after-bridge\.vbs") {
            throw "CC Switch startup coordination was not installed as expected."
        }
    }

    Write-Output "Vision Bridge runtime and Vision Skill installed."
    Write-Output "Startup entry installed: $($stagedItems | Where-Object { $_.Label -eq 'startup' } | Select-Object -ExpandProperty Destination)"
    if ($ccSwitchCoordinationEnabled) {
        Write-Output "CC Switch startup now waits for the bridge health check; original command backed up at $ccSwitchCommandPath."
    } elseif ($SkipCCSwitchStartupCoordination) {
        Write-Output "CC Switch startup coordination was skipped by request."
    } else {
        Write-Output "No recognizable CC Switch startup entry was found; CC Switch startup was not changed."
    }
    Write-Output "Backup manifest: $(Join-Path $backupRoot 'manifest.json')"
    Write-Output "No environment variables, API keys, CC Switch database entries, providers, or routes were changed."
    Write-Output "An existing bridge process was not stopped; run the launcher after stopping only a verified old bridge process."
} catch {
    if ($registryChanged) {
        try {
            if ($ccSwitchRunExisted -and -not [string]::IsNullOrWhiteSpace($ccSwitchOriginalCommand)) {
                Set-ItemProperty -LiteralPath $CCSwitchRunKeyPath -Name $CCSwitchRunValueName -Value $ccSwitchOriginalCommand
            }
        } catch {
            Write-Error "Installer rollback failed for CC Switch startup: $($_.Exception.Message)"
        }
    }
    foreach ($record in @($backupRecords | Sort-Object -Property Destination -Descending)) {
        try {
            if ($record.Existed) {
                Copy-Item -LiteralPath $record.Backup -Destination $record.Destination -Force
            } elseif (Test-Path -LiteralPath $record.Destination) {
                Remove-Item -LiteralPath $record.Destination -Force
            }
        } catch {
            Write-Error "Installer rollback failed for $($record.Destination): $($_.Exception.Message)"
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

if ($ConfigureCCSwitchRoute) {
    $installedRestartScript = Join-Path $bridgeDir "restart-vision-bridge.ps1"
    $installedRouteScript = Join-Path $bridgeDir "configure-ccswitch-route.ps1"
    Write-Output "Starting the Vision Bridge before updating the active CC Switch provider route."
    & $installedRestartScript -EnvironmentScope User
    Write-Output "Updating the active CC Switch provider route with a reversible database backup."
    & $installedRouteScript -ForceCloseCCSwitch
}
