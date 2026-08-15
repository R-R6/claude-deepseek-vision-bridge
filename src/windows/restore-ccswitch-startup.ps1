[CmdletBinding()]
param(
    [string]$InstallUserProfile = $env:USERPROFILE,
    [string]$CCSwitchRunValueName = "CC Switch",
    [string]$CCSwitchRunKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
)

$ErrorActionPreference = "Stop"
$bridgeDir = Join-Path $InstallUserProfile ".claude\bridge"
$commandPath = Join-Path $bridgeDir "cc-switch-startup.command"
$coordinatorName = "start-ccswitch-after-bridge.vbs"

if (-not (Test-Path -LiteralPath $commandPath -PathType Leaf)) {
    throw "Managed CC Switch startup command was not found: $commandPath"
}

$currentProperties = Get-ItemProperty -LiteralPath $CCSwitchRunKeyPath -ErrorAction Stop
$currentProperty = $currentProperties.PSObject.Properties |
    Where-Object { $_.Name -eq $CCSwitchRunValueName } |
    Select-Object -First 1
if ($null -eq $currentProperty) {
    throw "CC Switch startup value '$CCSwitchRunValueName' was not found; refusing to create or overwrite it."
}
if ([string]$currentProperty.Value -notmatch [regex]::Escape($coordinatorName)) {
    throw "CC Switch startup value no longer points to the managed coordinator; refusing to overwrite it."
}

$originalCommand = (Get-Content -Raw -Encoding Unicode -LiteralPath $commandPath).Trim()
if ([string]::IsNullOrWhiteSpace($originalCommand)) {
    throw "Managed CC Switch startup command is empty: $commandPath"
}

Set-ItemProperty -LiteralPath $CCSwitchRunKeyPath -Name $CCSwitchRunValueName -Value $originalCommand
Write-Output "Restored CC Switch startup command from $commandPath."
Write-Output "The bridge files were not removed."
