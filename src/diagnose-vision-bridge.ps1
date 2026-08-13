[CmdletBinding()]
param(
    [int]$CCSwitchPort = 15721
)

$ErrorActionPreference = "SilentlyContinue"
$expectedBridgeVersion = "0.2.1"

function Get-ProcessSetting {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, "Process")
}

$bridgeHost = Get-ProcessSetting "BRIDGE_HOST"
if ([string]::IsNullOrWhiteSpace($bridgeHost)) {
    $bridgeHost = "127.0.0.1"
}
$bridgePortText = Get-ProcessSetting "BRIDGE_PORT"
if ([string]::IsNullOrWhiteSpace($bridgePortText)) {
    $bridgePortText = "15720"
}
$bridgePort = 15720
$bridgePortValid = [int]::TryParse($bridgePortText, [ref]$bridgePort) -and $bridgePort -ge 1 -and $bridgePort -le 65535

$healthHost = $bridgeHost
if ($healthHost -eq "0.0.0.0") {
    $healthHost = "127.0.0.1"
} elseif ($healthHost -eq "::") {
    $healthHost = "::1"
}
if ($healthHost.Contains(":")) {
    $healthUri = "http://[$healthHost]:$bridgePort/health"
} else {
    $healthUri = "http://$healthHost`:$bridgePort/health"
}

$healthHeaders = @{}
$bridgeToken = Get-ProcessSetting "BRIDGE_AUTH_TOKEN"
if (-not [string]::IsNullOrWhiteSpace($bridgeToken)) {
    $healthHeaders["x-bridge-token"] = $bridgeToken
}

$bridgeListening = $false
$bridgeHealth = $false
$bridgeHealthDetail = "not checked"
if ($bridgePortValid) {
    $bridgeConnections = @(Get-NetTCPConnection -State Listen -LocalPort $bridgePort)
    $bridgeListening = $bridgeConnections.Count -gt 0
    try {
        $health = Invoke-RestMethod -Uri $healthUri -Headers $healthHeaders -TimeoutSec 3
        if ($health.ok -eq $true -and $health.service -eq "vision-bridge" -and $health.version -eq $expectedBridgeVersion) {
            $bridgeHealth = $true
            $bridgeHealthDetail = "healthy managed version $expectedBridgeVersion"
        } else {
            $bridgeHealthDetail = "response is not the managed bridge version"
        }
    } catch {
        $bridgeHealthDetail = "health request failed"
    }
}

$ccSwitchConnections = @(Get-NetTCPConnection -State Listen -LocalPort $CCSwitchPort)
$ccSwitchListening = $ccSwitchConnections.Count -gt 0

$claudeSettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
$claudeBaseUrl = ""
if (Test-Path -LiteralPath $claudeSettingsPath -PathType Leaf) {
    try {
        $claudeSettings = Get-Content -Raw -Encoding UTF8 -LiteralPath $claudeSettingsPath | ConvertFrom-Json
        $claudeBaseUrl = [string]$claudeSettings.env.ANTHROPIC_BASE_URL
    } catch {
        $claudeBaseUrl = "[unreadable]"
    }
}
$routeMatchesProxy = $false
$safeClaudeBaseUrl = "[missing]"
try {
    $routeUri = [Uri]$claudeBaseUrl
    $routeMatchesProxy = $routeUri.Host -eq "127.0.0.1" -and $routeUri.Port -eq $CCSwitchPort
    $safeClaudeBaseUrl = "{0}://{1}:{2}" -f $routeUri.Scheme, $routeUri.Host, $routeUri.Port
} catch {
    $routeMatchesProxy = $false
    if ($claudeBaseUrl) {
        $safeClaudeBaseUrl = "[invalid-url]"
    }
}

$ccSwitchSettingsPath = Join-Path $env:USERPROFILE ".cc-switch\settings.json"
$ccSwitchLaunchOnStartup = "unknown"
if (Test-Path -LiteralPath $ccSwitchSettingsPath -PathType Leaf) {
    try {
        $ccSwitchSettings = Get-Content -Raw -Encoding UTF8 -LiteralPath $ccSwitchSettingsPath | ConvertFrom-Json
        if ($ccSwitchSettings.launchOnStartup -eq $true) {
            $ccSwitchLaunchOnStartup = "enabled"
        } elseif ($ccSwitchSettings.launchOnStartup -eq $false) {
            $ccSwitchLaunchOnStartup = "disabled (enable in CC Switch if desired)"
        }
    } catch {
        $ccSwitchLaunchOnStartup = "[unreadable]"
    }
}

Write-Output "Vision Bridge / CC Switch diagnostic (read-only)"
[pscustomobject]@{
    Check = "Bridge health"
    Status = if ($bridgeHealth) { "PASS" } elseif ($bridgeListening) { "FAIL" } else { "FAIL" }
    Detail = "$healthUri; $bridgeHealthDetail"
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "CC Switch local proxy"
    Status = if ($ccSwitchListening) { "PASS" } else { "FAIL" }
    Detail = "127.0.0.1:$CCSwitchPort listening=$ccSwitchListening"
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "Claude Code route"
    Status = if ($routeMatchesProxy) { "PASS" } else { "WARN" }
    Detail = "ANTHROPIC_BASE_URL=$safeClaudeBaseUrl"
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "CC Switch login startup"
    Status = if ($ccSwitchLaunchOnStartup -eq "enabled") { "PASS" } else { "WARN" }
    Detail = $ccSwitchLaunchOnStartup
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "Required process configuration"
    Status = if ($bridgePortValid -and (Get-ProcessSetting "UPSTREAM") -and (Get-ProcessSetting "VISION_API_KEY")) { "PASS" } else { "FAIL" }
    Detail = "values are checked for presence only; no secret is displayed"
} | Format-Table -AutoSize

Write-Output "If Bridge health fails, repair the bridge bundle/startup entry first. If Bridge passes but CC Switch fails, start CC Switch. If both pass but requests bypass the bridge, inspect the active CC Switch app profile and provider target in its UI; this script never edits SQLite."

if (-not $bridgeHealth -or -not $ccSwitchListening -or -not $bridgePortValid) {
    exit 1
}
