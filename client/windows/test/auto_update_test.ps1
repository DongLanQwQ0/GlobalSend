[CmdletBinding()]
param([string]$Work = 'artifacts/tmp/windows-update103')
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $root $Work))
$fixture = Join-Path $workRoot 'fixture.exe'
$script = Join-Path $root 'client/assets/update/Install-WindowsUpdate.ps1'
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$caseRoot = Join-Path $workRoot ('run-' + [Guid]::NewGuid().ToString('N'))
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Make-Case([string]$Name) {
  $case = Join-Path $caseRoot $Name
  New-Item -ItemType Directory -Path $case -Force | Out-Null
  $installed = Join-Path $case 'installed'
  $package = Join-Path $case 'payload'
  foreach ($directory in @($installed,$package)) {
    New-Item -ItemType Directory -Path (Join-Path $directory 'data/flutter_assets') -Force | Out-Null
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $directory 'globalsend.exe')
    [IO.File]::WriteAllText((Join-Path $directory 'flutter_windows.dll'),'engine')
    [IO.File]::WriteAllText((Join-Path $directory 'data/app.so'),'old')
    [IO.File]::WriteAllText((Join-Path $directory 'data/icudtl.dat'),'icu')
    [IO.File]::WriteAllText((Join-Path $directory 'data/flutter_assets/AssetManifest.bin'),'manifest')
  }
  [IO.File]::WriteAllText((Join-Path $installed 'globalsend-data.json'),'preserved-local-pointer')
  [IO.File]::WriteAllText((Join-Path $installed 'notes.txt'),'preserved-user-file')
  [IO.File]::WriteAllText((Join-Path $installed 'data/user-note.txt'),'preserved-data-file')
  [IO.File]::WriteAllText((Join-Path $installed 'data/flutter_assets/obsolete.bin'),'retired')
  [IO.File]::WriteAllText((Join-Path $package 'data/app.so'),'new')
  return @{case=$case;installed=$installed;payload=$package;zip=(Join-Path $case 'update.zip')}
}
function Run-Case($Case,[string]$Version='1.2.3',[int]$ProcessId=2147483647) {
  Compress-Archive -Path ($Case.payload + '/*') -DestinationPath $Case.zip -Force
  $request = Join-Path $Case.case 'request.json'
  @{package=$Case.zip;installDirectory=$Case.installed;executable='globalsend.exe';version=$Version;build=400;processId=$ProcessId;window='0';background=$true} |
    ConvertTo-Json | Set-Content -LiteralPath $request -Encoding UTF8
  $prior = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -NonInteractive -File $script -RequestPath $request *> (Join-Path $Case.case 'helper.log')
    $code=$LASTEXITCODE
  } finally { $ErrorActionPreference=$prior }
  $result=Get-Content -LiteralPath (Join-Path $Case.case 'windows-update-result.json') -Raw | ConvertFrom-Json
  return @{code=$code;result=$result}
}
function Assert-Preserved($Case) {
  Assert ((Get-Content -LiteralPath (Join-Path $Case.installed 'globalsend-data.json') -Raw) -eq 'preserved-local-pointer') 'Local data pointer changed'
  Assert ((Get-Content -LiteralPath (Join-Path $Case.installed 'notes.txt') -Raw) -eq 'preserved-user-file') 'User root file changed'
  Assert ((Get-Content -LiteralPath (Join-Path $Case.installed 'data/user-note.txt') -Raw) -eq 'preserved-data-file') 'User data file changed'
}
$success=Make-Case 'success'
$source=Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 3') -WindowStyle Hidden -PassThru
try {
  $result=Run-Case $success '1.2.3' $source.Id
  Assert ($result.code -eq 0 -and $result.result.state -eq 'installed') ('Full bundle update failed: ' + $result.result.message)
  Assert ((Get-Content -LiteralPath (Join-Path $success.installed 'data/app.so') -Raw) -eq 'new') 'New AOT was not installed'
  Assert (-not (Test-Path -LiteralPath (Join-Path $success.installed 'data/flutter_assets/obsolete.bin'))) 'Retired Flutter assets survived'
  Assert ((Get-Content -LiteralPath (Join-Path $success.installed 'restart.txt') -Raw).Contains('--background')) 'Background restart option lost'
  Assert-Preserved $success
} finally { if (-not $source.HasExited) { $source.Kill(); $source.WaitForExit() }; $source.Dispose() }
$wrong=Make-Case 'wrong-version'
$source=Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
try {
  $result=Run-Case $wrong '9.9.9' $source.Id
  Assert ($result.code -ne 0 -and $result.result.state -eq 'failed') 'Wrong version was accepted'
  Assert (-not $source.HasExited) 'Extraction/validation failure closed the current process'
  Assert ((Get-Content -LiteralPath (Join-Path $wrong.installed 'data/app.so') -Raw) -eq 'old') 'Validation failure changed old bundle'
  Assert-Preserved $wrong
} finally { if (-not $source.HasExited) { $source.Kill(); $source.WaitForExit() }; $source.Dispose() }
$rollback=Make-Case 'rollback'
[IO.File]::WriteAllText((Join-Path $rollback.payload 'fail-first-frame.flag'),'fail')
$result=Run-Case $rollback
Assert ($result.code -ne 0 -and $result.result.state -eq 'rolled-back') ('Startup failure did not roll back: ' + $result.result.message)
Assert ((Get-Content -LiteralPath (Join-Path $rollback.installed 'data/app.so') -Raw) -eq 'old') 'Rollback did not restore old AOT'
Assert (Test-Path -LiteralPath (Join-Path $rollback.installed 'data/flutter_assets/obsolete.bin')) 'Rollback did not restore old assets'
Assert (-not (Test-Path -LiteralPath (Join-Path $rollback.installed 'fail-first-frame.flag'))) 'Rollback left the failed package entry'
Assert-Preserved $rollback
@{fullBundle=$true;backgroundRestart=$true;pointerAndUserFilesPreserved=$true;validationBeforeExit=$true;startupFailureRollback=$true} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workRoot 'result.json') -Encoding UTF8
Write-Output 'PASS: bundle replacement, retired assets, background restart, original data, pre-exit version failure, first-frame rollback'
