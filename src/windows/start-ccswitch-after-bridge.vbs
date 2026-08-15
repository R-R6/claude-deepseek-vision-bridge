Option Explicit

Const EXPECTED_BRIDGE_VERSION = "0.2.1"
Const DEFAULT_WAIT_MS = 120000
Const POLL_INTERVAL_MS = 250

Dim shell, fileSystem, processEnv
Dim bridgeDir, commandPath, logPath, healthUrl, bridgeToken
Dim waitMs, startedAt, originalCommand

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set processEnv = shell.Environment("PROCESS")

bridgeDir = shell.ExpandEnvironmentStrings("%USERPROFILE%\.claude\bridge")
commandPath = fileSystem.BuildPath(bridgeDir, "cc-switch-startup.command")
logPath = fileSystem.BuildPath(bridgeDir, "cc-switch-startup.log")

If Not fileSystem.FileExists(commandPath) Then
    LogMessage "STARTUP-ERR original CC Switch command file is missing"
    WScript.Quit 1
End If

originalCommand = ReadCommand(commandPath)
If Len(originalCommand) = 0 Then
    LogMessage "STARTUP-ERR original CC Switch command file is empty"
    WScript.Quit 1
End If

healthUrl = BuildHealthUrl(GetEnvironmentValue("BRIDGE_HOST", "127.0.0.1"), GetEnvironmentValue("BRIDGE_PORT", "15720"))
bridgeToken = GetEnvironmentValue("BRIDGE_AUTH_TOKEN", "")
waitMs = PositiveInteger(GetEnvironmentValue("BRIDGE_STARTUP_COORDINATOR_TIMEOUT_MS", ""), DEFAULT_WAIT_MS)
startedAt = Timer

Do While ElapsedMilliseconds(startedAt) < waitMs
    If BridgeIsHealthy(healthUrl, bridgeToken) Then
        LogMessage "Bridge is healthy; starting CC Switch"
        shell.Run originalCommand, 0, False
        WScript.Quit 0
    End If
    WScript.Sleep POLL_INTERVAL_MS
Loop

LogMessage "STARTUP-ERR bridge was not healthy within " & CStr(waitMs) & " ms; CC Switch was not started"
WScript.Quit 1

Function GetEnvironmentValue(name, fallback)
    Dim value
    value = ""
    On Error Resume Next
    value = processEnv(name)
    Err.Clear
    On Error GoTo 0
    If Len(Trim(value)) = 0 Then
        GetEnvironmentValue = fallback
    Else
        GetEnvironmentValue = value
    End If
End Function

Function PositiveInteger(value, fallback)
    Dim parsed
    parsed = fallback
    If IsNumeric(value) Then
        If CLng(value) >= 1000 And CLng(value) <= 300000 Then
            parsed = CLng(value)
        End If
    End If
    PositiveInteger = parsed
End Function

Function BuildHealthUrl(hostName, port)
    If hostName = "0.0.0.0" Then hostName = "127.0.0.1"
    If hostName = "::" Then hostName = "::1"
    If InStr(hostName, ":") > 0 Then
        BuildHealthUrl = "http://[" & hostName & "]:" & port & "/health"
    Else
        BuildHealthUrl = "http://" & hostName & ":" & port & "/health"
    End If
End Function

Function BridgeIsHealthy(url, token)
    Dim request, body
    BridgeIsHealthy = False
    On Error Resume Next
    Set request = CreateObject("WinHttp.WinHttpRequest.5.1")
    If Err.Number <> 0 Then
        Err.Clear
        On Error GoTo 0
        Exit Function
    End If
    request.Open "GET", url, False
    request.SetTimeouts 1000, 1000, 1000, 1000
    If Len(token) > 0 Then request.SetRequestHeader "x-bridge-token", token
    request.Send
    If Err.Number = 0 And request.Status = 200 Then
        body = LCase(request.ResponseText)
        BridgeIsHealthy = InStr(body, """ok"":true") > 0 _
            And InStr(body, """service"":""vision-bridge""") > 0 _
            And InStr(body, """version"":""" & LCase(EXPECTED_BRIDGE_VERSION) & """") > 0
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function ReadCommand(path)
    Dim file
    ReadCommand = ""
    On Error Resume Next
    Set file = fileSystem.OpenTextFile(path, 1, False, -1)
    If Err.Number = 0 Then
        ReadCommand = Trim(file.ReadAll)
        file.Close
    End If
    Err.Clear
    On Error GoTo 0
End Function

Function ElapsedMilliseconds(startTick)
    Dim currentTick
    currentTick = Timer
    If currentTick < startTick Then currentTick = currentTick + 86400
    ElapsedMilliseconds = CLng((currentTick - startTick) * 1000)
End Function

Sub LogMessage(message)
    Dim file
    On Error Resume Next
    Set file = fileSystem.OpenTextFile(logPath, 8, True, -1)
    If Err.Number = 0 Then
        file.WriteLine Now & " " & message
        file.Close
    End If
    Err.Clear
    On Error GoTo 0
End Sub
