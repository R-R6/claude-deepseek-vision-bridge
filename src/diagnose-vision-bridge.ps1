[CmdletBinding()]
param(
    [int]$CCSwitchPort = 15721,
    [switch]$SkipCCSwitch,
    [ValidateRange(0, 65535)]
    [int]$ExpectedRoutePort = 0,
    [switch]$SkipRouteCheck
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

$ccSwitchConnections = @()
$ccSwitchListening = $false
if (-not $SkipCCSwitch) {
    $ccSwitchConnections = @(Get-NetTCPConnection -State Listen -LocalPort $CCSwitchPort)
    $ccSwitchListening = $ccSwitchConnections.Count -gt 0
}

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
$expectedRoutePort = if ($SkipCCSwitch) { $bridgePort } else { $CCSwitchPort }
$expectedRoutePort = if ($ExpectedRoutePort -gt 0) { $ExpectedRoutePort } else { $expectedRoutePort }
$routeMatchesProxy = $false
$safeClaudeBaseUrl = "[missing]"
if (-not $SkipRouteCheck) {
    try {
        $routeUri = [Uri]$claudeBaseUrl
        $routeMatchesProxy = $routeUri.Host -eq "127.0.0.1" -and $routeUri.Port -eq $expectedRoutePort
        $safeClaudeBaseUrl = "{0}://{1}:{2}" -f $routeUri.Scheme, $routeUri.Host, $routeUri.Port
    } catch {
        $routeMatchesProxy = $false
        if ($claudeBaseUrl) {
            $safeClaudeBaseUrl = "[invalid-url]"
        }
    }
}

$ccSwitchSettingsPath = Join-Path $env:USERPROFILE ".cc-switch\settings.json"
$ccSwitchLaunchOnStartup = "unknown"
if (-not $SkipCCSwitch -and (Test-Path -LiteralPath $ccSwitchSettingsPath -PathType Leaf)) {
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

$upstream = Get-ProcessSetting "UPSTREAM"
$upstreamValid = $false
try {
    $upstreamUri = [Uri]$upstream
    $upstreamValid = $upstreamUri.Scheme -in @("http", "https") -and
        -not [string]::IsNullOrWhiteSpace($upstreamUri.Host)
    if ($upstreamValid -and $upstreamUri.Host -match "(?i)^(localhost|127(?:\.\d{1,3}){3}|::1)$") {
        $upstreamValid = $upstreamUri.Port -ne $bridgePort
    }
} catch {
    $upstreamValid = $false
}
$rollbackStatePath = Join-Path $env:USERPROFILE ".claude\bridge\bridge-rollback-state.dat"
$rollbackStateAvailable = Test-Path -LiteralPath $rollbackStatePath -PathType Leaf

Write-Output "Vision Bridge / CC Switch diagnostic (read-only)"
[pscustomobject]@{
    Check = "Bridge health"
    Status = if ($bridgeHealth) { "PASS" } elseif ($bridgeListening) { "FAIL" } else { "FAIL" }
    Detail = "$healthUri; $bridgeHealthDetail"
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "CC Switch local proxy"
    Status = if ($SkipCCSwitch) { "SKIP" } elseif ($ccSwitchListening) { "PASS" } else { "FAIL" }
    Detail = if ($SkipCCSwitch) { "skipped by -SkipCCSwitch" } else { "127.0.0.1:$CCSwitchPort listening=$ccSwitchListening" }
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = if ($SkipCCSwitch) { "Claude Code route to bridge" } else { "Claude Code route to CC Switch" }
    Status = if ($SkipRouteCheck) { "SKIP" } elseif ($routeMatchesProxy) { "PASS" } else { "WARN" }
    Detail = if ($SkipRouteCheck) {
        "route check skipped; verify the active router points to the bridge port"
    } else {
        "ANTHROPIC_BASE_URL=$safeClaudeBaseUrl; expected 127.0.0.1:$expectedRoutePort"
    }
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "CC Switch login startup"
    Status = if ($SkipCCSwitch) { "SKIP" } elseif ($ccSwitchLaunchOnStartup -eq "enabled") { "PASS" } else { "WARN" }
    Detail = if ($SkipCCSwitch) { "skipped by -SkipCCSwitch" } else { $ccSwitchLaunchOnStartup }
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "Required process configuration"
    Status = if ($bridgePortValid -and $upstreamValid -and (Get-ProcessSetting "VISION_API_KEY")) { "PASS" } else { "FAIL" }
    Detail = "UPSTREAM URL and required secret presence are checked; no secret or URL value is displayed"
} | Format-Table -AutoSize
[pscustomobject]@{
    Check = "Restart rollback state"
    Status = if ($rollbackStateAvailable) { "PASS" } else { "WARN" }
    Detail = if ($rollbackStateAvailable) {
        "protected state is available for configuration reload"
    } else {
        "missing; restart Windows before changing configuration, or use the documented bootstrap migration only when current settings are unchanged"
    }
} | Format-Table -AutoSize

if ($SkipCCSwitch) {
    Write-Output "CC Switch checks were skipped. Configure the actual router so requests reach the bridge port; this script never edits router configuration. Use -ExpectedRoutePort for a known Claude Code router port, or -SkipRouteCheck when that port is not known."
} else {
    Write-Output "If Bridge health fails, repair the bridge bundle/startup entry first. If Bridge passes but CC Switch fails, start CC Switch. If both pass but requests bypass the bridge, inspect the active CC Switch app profile and provider target in its UI; this script never edits SQLite."
}

if (-not $bridgeHealth -or (-not $SkipCCSwitch -and -not $ccSwitchListening) -or -not $bridgePortValid) {
    exit 1
}
