' Put this file in the Windows Startup folder after copying the source bundle
' to %USERPROFILE%\.claude\bridge. It starts the PowerShell launcher hidden.
Set shell = CreateObject("WScript.Shell")
launcher = shell.ExpandEnvironmentStrings("%USERPROFILE%\.claude\bridge\start-vision-bridge.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & launcher & """"
shell.Run command, 0, False

