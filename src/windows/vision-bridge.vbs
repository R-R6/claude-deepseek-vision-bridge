' Put this file in the current user's Windows Startup folder. The installer
' copies the complete bundle to %USERPROFILE%\.claude\bridge first.
Set shell = CreateObject("WScript.Shell")
launcher = shell.ExpandEnvironmentStrings("%USERPROFILE%\.claude\bridge\start-vision-bridge.ps1")
powerShell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
quote = Chr(34)
command = quote & powerShell & quote & " -NoLogo -NoProfile -ExecutionPolicy Bypass -File " & quote & launcher & quote
shell.Run command, 0, False

