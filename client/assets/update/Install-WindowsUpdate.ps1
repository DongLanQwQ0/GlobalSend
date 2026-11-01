# Runs outside the installed bundle; never force-kills the application.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class GlobalSendUpdateNative {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool MoveFileEx(string source, string destination, uint flags);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateEvent(IntPtr attributes, bool manual, bool initial, string name);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr OpenEvent(uint access, bool inherit, string name);
  [DllImport("kernel32")] public static extern bool SetEvent(IntPtr handle);
  [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32")] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
  [DllImport("kernel32")] public static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles, bool all, uint milliseconds);
  [DllImport("user32", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
  [DllImport("user32", SetLastError=true)] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
}
'@
$request = [IO.File]::ReadAllText($RequestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
$work = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($RequestPath))
$resultPath = Join-Path $work 'windows-update-result.json'
if ($request.resultPath) { $resultPath = [IO.Path]::GetFullPath($request.resultPath) }
$stage = Join-Path $work ('windows-update-stage-' + [Guid]::NewGuid().ToString('N'))
$install = [IO.Path]::GetFullPath($request.installDirectory).TrimEnd('\')
$backup = Join-Path $install ('.globalsend-update-backup-' + [Guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($backup).StartsWith($install + '\.globalsend-update-backup-',[StringComparison]::OrdinalIgnoreCase)) { throw 'Backup escaped the application folder' }
$proceed = [IntPtr]::Zero; $cancel = [IntPtr]::Zero
$moved = New-Object Collections.Generic.List[string]
$copied = New-Object Collections.Generic.List[string]
$changed = $false; $oldExited = $false; $newReady = $false
function Save-Result([string]$State,[string]$Message='') {
  $value = @{state=$State;version=$request.version;build=[int]$request.build;message=$Message;at=[DateTime]::UtcNow.ToString('o')}
  $temporary = $resultPath + '.tmp'
  [IO.File]::WriteAllText($temporary,($value | ConvertTo-Json -Compress),(New-Object Text.UTF8Encoding($false)))
  if (-not [GlobalSendUpdateNative]::MoveFileEx($temporary,$resultPath,9)) { throw (New-Object ComponentModel.Win32Exception([Runtime.InteropServices.Marshal]::GetLastWin32Error())) }
}
function Pe-Machine([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  $reader = New-Object IO.BinaryReader($stream)
  try {
    if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'The application executable is not a Windows PE file' }
    [void]$stream.Seek(0x3c,[IO.SeekOrigin]::Begin)
    $offset = $reader.ReadUInt32()
    [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
    if ($reader.ReadUInt32() -ne 0x4550) { throw 'The application executable has an invalid PE header' }
    return $reader.ReadUInt16()
  } finally { $reader.Dispose(); $stream.Dispose() }
}
function Start-App([bool]$CheckStartup=$false) {
  $arguments = @()
  if ($request.background) { $arguments += '--background' }
  $start = @{FilePath=(Join-Path $install $request.executable);WorkingDirectory=$install;WindowStyle='Hidden';PassThru=$true}
  if ($arguments.Count) { $start.ArgumentList=$arguments }
  $readyEvent = [IntPtr]::Zero
  $previousEvent = $env:GLOBALSEND_UPDATE_READY_EVENT
  try {
    if ($CheckStartup) {
      $env:GLOBALSEND_UPDATE_READY_EVENT = 'Local\GlobalSend.UpdateStarted.' + [Guid]::NewGuid().ToString('N')
      $readyEvent = [GlobalSendUpdateNative]::CreateEvent([IntPtr]::Zero,$true,$false,$env:GLOBALSEND_UPDATE_READY_EVENT)
      if ($readyEvent -eq [IntPtr]::Zero) { throw 'Unable to create the startup acknowledgement' }
    } else { Remove-Item Env:GLOBALSEND_UPDATE_READY_EVENT -ErrorAction SilentlyContinue }
    $launched = Start-Process @start
    try {
      if ($CheckStartup) {
        $ready = [GlobalSendUpdateNative]::WaitForMultipleObjects(2,@($readyEvent,$launched.Handle),$false,30000)
        if ($ready -ne 0) {
          # Only the new process launched by this update may be stopped.
          if (-not $launched.HasExited) { $launched.Kill(); $launched.WaitForExit() }
          throw 'The updated application did not reach its first frame'
        }
      }
    } finally { $launched.Dispose() }
  } finally {
    $env:GLOBALSEND_UPDATE_READY_EVENT = $previousEvent
    if ($readyEvent -ne [IntPtr]::Zero) { [void][GlobalSendUpdateNative]::CloseHandle($readyEvent) }
  }
}
try {
  if ($request.readyEvent) {
    $ready = [GlobalSendUpdateNative]::OpenEvent(0x0002,$false,$request.readyEvent)
    if ($ready -eq [IntPtr]::Zero) { throw 'Update launch handshake is unavailable' }
    [void][GlobalSendUpdateNative]::SetEvent($ready)
    [void][GlobalSendUpdateNative]::CloseHandle($ready)
    $proceed = [GlobalSendUpdateNative]::OpenEvent(0x00100000,$false,$request.proceedEvent)
    $cancel = [GlobalSendUpdateNative]::OpenEvent(0x00100000,$false,$request.cancelEvent)
    if ($proceed -eq [IntPtr]::Zero -or $cancel -eq [IntPtr]::Zero) { throw 'Update launch handshake is incomplete' }
    $gate = [GlobalSendUpdateNative]::WaitForMultipleObjects(2,@($proceed,$cancel),$false,15000)
    if ($gate -eq 1) { Save-Result 'ready' 'Update cancelled before extraction'; return }
    if ($gate -ne 0) { throw 'Update launch did not continue' }
  }
  Save-Result 'preparing'
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($request.package))
  try {
    $stagePrefix = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
    foreach ($entry in $archive.Entries) {
      $target = [IO.Path]::GetFullPath((Join-Path $stage $entry.FullName))
      if (-not $target.StartsWith($stagePrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP entry escapes the update folder' }
    }
  } finally { $archive.Dispose() }
  [IO.Compression.ZipFile]::ExtractToDirectory([IO.Path]::GetFullPath($request.package),$stage)
  foreach ($required in @($request.executable,'flutter_windows.dll','data/app.so','data/icudtl.dat','data/flutter_assets/AssetManifest.bin')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) { throw "The update is not a complete Windows bundle: $required" }
  }
  $metadata = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $stage $request.executable))
  if ($metadata.ProductVersion -ne ($request.version + '+' + $request.build)) { throw 'The ZIP version does not match this update' }
  if ((Pe-Machine (Join-Path $stage $request.executable)) -ne (Pe-Machine (Join-Path $install $request.executable))) { throw 'The ZIP architecture does not match the installed application' }
  # The installed data pointer is local to this installation, never supplied by a ZIP.
  if (Test-Path -LiteralPath (Join-Path $stage 'globalsend-data.json')) { Remove-Item -LiteralPath (Join-Path $stage 'globalsend-data.json') -Force }
  # Establish that the installed directory is writable before closing the app.
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  if ($cancel -ne [IntPtr]::Zero -and [GlobalSendUpdateNative]::WaitForSingleObject($cancel,0) -eq 0) {
    Save-Result 'ready' 'Update cancelled before apply'; return
  }
  Save-Result 'prepared'
  $sourceProcess = Get-Process -Id ([int]$request.processId) -ErrorAction SilentlyContinue
  if ($sourceProcess) {
    if ([int64]$request.window -ne 0) {
      $message = [GlobalSendUpdateNative]::RegisterWindowMessage('GlobalSend.UpdateExit.v1')
      $requestToken = [IntPtr]::Zero
      if ($request.requestToken) { $requestToken = [IntPtr]([int64]$request.requestToken) }
      if (-not [GlobalSendUpdateNative]::PostMessage([IntPtr]([int64]$request.window),$message,$requestToken,[IntPtr]::Zero)) { throw 'Unable to request the current app to exit' }
    }
    if ($cancel -ne [IntPtr]::Zero) {
      # A drag/menu can outlive a timeout. Sleep in the OS until this exact
      # process exits or the application explicitly cancels this one helper.
      $wait = [GlobalSendUpdateNative]::WaitForMultipleObjects(2,@($sourceProcess.Handle,$cancel),$false,[uint32]::MaxValue)
      if ($wait -eq 1) { Save-Result 'ready' 'The app is busy; the downloaded update remains ready'; return }
      if ($wait -ne 0) { throw 'The current application did not finish closing' }
    } elseif (-not $sourceProcess.WaitForExit(30000)) { throw 'The current application did not finish closing' }
    $sourceProcess.Dispose()
  }
  $oldExited = $true
  # Back up only replaced application entries, not user files or application state.
  $entries = @()
  foreach ($item in Get-ChildItem -LiteralPath $stage -Force) {
    if ($item.Name -eq 'globalsend-data.json') { continue }
    if ($item.Name -eq 'data' -and $item.PSIsContainer) {
      foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $entries += @{path=('data\' + $child.Name);item=$child} }
    } else { $entries += @{path=$item.Name;item=$item} }
  }
  foreach ($entry in $entries) {
    $name = $entry.path; $item = $entry.item
    $destination = Join-Path $install $name
    if (Test-Path -LiteralPath $destination) {
      $resolved = [IO.Path]::GetFullPath($destination)
      if (-not $resolved.StartsWith($install + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Replacement escaped the application folder' }
      $saved = Join-Path $backup $name
      New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
      Move-Item -LiteralPath $destination -Destination $saved
      $moved.Add($name)
      $changed = $true
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    $copied.Add($name)
    $changed = $true
    Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
  }
  Start-App $true
  $newReady = $true
  # This backup contains only the just-replaced bundle. A failed update keeps it.
  $cleanupMessage = ''
  if ([IO.Path]::GetFullPath($backup).StartsWith($install + '\.globalsend-update-backup-',[StringComparison]::OrdinalIgnoreCase)) {
    try { Remove-Item -LiteralPath $backup -Recurse -Force }
    catch { $cleanupMessage = 'The update started; the previous bundle remains in ' + $backup }
  }
  Save-Result 'installed' $cleanupMessage
} catch {
  $failure = $_.Exception.Message
  # Reporting/cleanup cannot undo a new process that already rendered its frame.
  # Its own installed version is authoritative even if the cache became unwritable.
  if ($newReady) { exit 0 }
  if ($changed) {
    try {
      foreach ($name in $copied) {
        $target = [IO.Path]::GetFullPath((Join-Path $install $name))
        if (-not $target.StartsWith($install + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Rollback target escaped the application folder' }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
      }
      foreach ($name in $moved) { Move-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $install $name) -Force }
      if ($oldExited) { Start-App }
      Save-Result 'rolled-back' $failure
    } catch { Save-Result 'failed' ($failure + '; Recovery failed; previous files remain in ' + $backup + ': ' + $_.Exception.Message) }
  } else {
    if ($oldExited) {
      try { Start-App } catch { $failure += '; Unable to reopen the unchanged app: ' + $_.Exception.Message }
    }
    Save-Result 'failed' $failure
  }
  exit 1
} finally {
  foreach ($handle in @($proceed,$cancel)) { if ($handle -ne [IntPtr]::Zero) { [void][GlobalSendUpdateNative]::CloseHandle($handle) } }
  $stagePrefix = [IO.Path]::GetFullPath($work).TrimEnd('\') + '\windows-update-stage-'
  if ([IO.Path]::GetFullPath($stage).StartsWith($stagePrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force }
  if ((Test-Path -LiteralPath $backup) -and @(Get-ChildItem -LiteralPath $backup -Force).Count -eq 0) { Remove-Item -LiteralPath $backup -Force }
  if (Test-Path -LiteralPath $RequestPath) { Remove-Item -LiteralPath $RequestPath -Force }
}
