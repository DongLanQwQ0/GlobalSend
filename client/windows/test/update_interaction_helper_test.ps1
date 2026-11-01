# A long native operation holds one prepared helper; cancellation releases it.
[CmdletBinding()]
param([int]$HoldSeconds=31)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root ('artifacts/tmp/update-interaction104/helper-' + [Guid]::NewGuid().ToString('N'))
$installed=Join-Path $work 'installed';$payload=Join-Path $work 'payload'
$fixture=Join-Path $root 'artifacts/tmp/windows-update103/fixture.exe'
foreach($folder in @($installed,$payload)) {
  New-Item -ItemType Directory -Path (Join-Path $folder 'data/flutter_assets') -Force|Out-Null
  Copy-Item -LiteralPath $fixture -Destination (Join-Path $folder 'globalsend.exe')
  foreach($name in @('flutter_windows.dll','data/app.so','data/icudtl.dat','data/flutter_assets/AssetManifest.bin')) {
    [IO.File]::WriteAllText((Join-Path $folder $name),'unchanged fixture')
  }
}
$archive=Join-Path $work 'update.zip';Compress-Archive -Path ($payload+'/*') -DestinationPath $archive
$token='Local\GlobalSend.InteractionFixture.'+[Guid]::NewGuid().ToString('N')
$ready=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,($token+'.ready'))
$proceed=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,($token+'.proceed'))
$cancel=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,($token+'.cancel'))
$source=Start-Process powershell.exe -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 90') -WindowStyle Hidden -PassThru
$helper=$null
try {
  $request=Join-Path $work 'request.json'
  @{package=$archive;installDirectory=$installed;executable='globalsend.exe';version='1.2.3';build=400;
    processId=$source.Id;window='0';background=$true;readyEvent=$token+'.ready';proceedEvent=$token+'.proceed';cancelEvent=$token+'.cancel'}|
    ConvertTo-Json|Set-Content -LiteralPath $request -Encoding UTF8
  $script=Join-Path $root 'client/assets/update/Install-WindowsUpdate.ps1'
  $helper=Start-Process powershell.exe -ArgumentList ('-NoProfile -NonInteractive -File "'+$script+'" -RequestPath "'+$request+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $work 'stdout.log') -RedirectStandardError (Join-Path $work 'stderr.log')
  if(-not $ready.WaitOne(10000)){throw 'Helper did not complete its startup handshake'}
  [void]$proceed.Set()
  $receipt=Join-Path $work 'windows-update-result.json';$watch=[Diagnostics.Stopwatch]::StartNew()
  do {
    Start-Sleep -Milliseconds 50
    $state=if(Test-Path -LiteralPath $receipt){Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json}else{$null}
    if($watch.Elapsed.TotalSeconds -gt 10){throw 'Helper did not finish preparing'}
  } while($state.state -ne 'prepared')
  Start-Sleep -Seconds $HoldSeconds
  if($helper.HasExited){throw 'The same prepared helper timed out during a long operation'}
  if($source.HasExited){throw 'The source process was interrupted'}
  [void]$cancel.Set()
  if(-not $helper.WaitForExit(10000)){throw 'Cancellation did not release the waiting helper'}
  $state=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
  if($state.state -ne 'ready'){throw ('Cancelled helper state is '+$state.state)}
  if((Get-Content -LiteralPath (Join-Path $installed 'data/app.so') -Raw) -ne 'unchanged fixture'){throw 'Waiting changed the installed files'}
  @{holdSeconds=$HoldSeconds;singleHelper=$true;cancelledState=$state.state;sourceUninterrupted=$true;bundleUnchanged=$true}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding UTF8
  Write-Output "PASS: one helper stayed prepared for $HoldSeconds seconds; cancellation retained the package and original app ($work)"
} finally {
  [void]$cancel.Set()
  if($helper){if(-not $helper.HasExited){if(-not $helper.WaitForExit(10000)){$helper.Kill();$helper.WaitForExit()}};$helper.Dispose()}
  if(-not $source.HasExited){$source.Kill();$source.WaitForExit()};$source.Dispose()
  $ready.Dispose();$proceed.Dispose();$cancel.Dispose()
}
