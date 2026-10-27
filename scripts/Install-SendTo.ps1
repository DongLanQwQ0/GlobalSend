[CmdletBinding()]
param([string]$Executable = 'E:\Programs\GlobalSend\globalsend.exe')
$ErrorActionPreference = 'Stop'
$Executable = [IO.Path]::GetFullPath($Executable)
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw "GlobalSend not installed: $Executable" }
$folder = [Environment]::GetFolderPath('SendTo')
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path $folder 'GlobalSend.lnk'))
$shortcut.TargetPath = $Executable
$shortcut.WorkingDirectory = Split-Path -Parent $Executable
$shortcut.Arguments = ''
$shortcut.IconLocation = "$Executable,0"
$shortcut.Description = '加入 GlobalSend 待发'
$shortcut.Save()
Write-Output (Join-Path $folder 'GlobalSend.lnk')
