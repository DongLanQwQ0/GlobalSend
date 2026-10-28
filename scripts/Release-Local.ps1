<# Builds and publishes the native clients to the user's local test devices. #>
[CmdletBinding()]
param([string]$Serial = $env:GLOBALSEND_ADB_SERIAL, [switch]$PublishOnly, [switch]$KeepRunning, [switch]$PushOnlyPhone, [switch]$WindowsOnly)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$client = Join-Path $root 'client'
$versionText = Get-Content -LiteralPath (Join-Path $client 'pubspec.yaml') -Raw
if ($versionText -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)') { throw 'Missing native version' }
$version = $Matches[1]
$buildNumber = [int]$Matches[2]
$target = [IO.Path]::GetFullPath('E:\Programs\GlobalSend')
$releases = Join-Path $root 'artifacts\releases'
$logs = Join-Path $root 'artifacts\logs'
$config = Join-Path $client 'build\release-local-tool-config'
$temp = Join-Path $root 'artifacts\tmp\release-local'
if (-not $env:GLOBALSEND_DATA_DIR) {
    $installedPointer = Join-Path $target 'globalsend-data.json'
    if (Test-Path -LiteralPath $installedPointer) {
        $env:GLOBALSEND_DATA_DIR = (Get-Content -LiteralPath $installedPointer -Raw | ConvertFrom-Json).dataDirectory
    }
    if (-not $env:GLOBALSEND_DATA_DIR) { $env:GLOBALSEND_DATA_DIR = Join-Path $root 'artifacts\native-state' }
}
New-Item -ItemType Directory -Path $releases,$logs,$config,$temp -Force | Out-Null
$previousRelease = $null
if (Test-Path -LiteralPath (Join-Path $releases 'latest-local.json')) {
    $previousRelease = Get-Content -LiteralPath (Join-Path $releases 'latest-local.json') -Raw | ConvertFrom-Json
}
if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Installation folder must not be a link' }
$oldAppData = $env:APPDATA
$dart = 'E:\Programs\flutter\bin\cache\dart-sdk\bin\dart.exe'
$snapshot = 'E:\Programs\flutter\bin\cache\flutter_tools.snapshot'
$adb = 'F:\Android\Sdk\platform-tools\adb.exe'
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    $prior = $ErrorActionPreference
    try {
        # Windows PowerShell 5 treats ordinary native stderr as ErrorRecords.
        $ErrorActionPreference = 'Continue'
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Output "$_" }
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prior }
    if ($exitCode -ne 0) { throw "$Exe failed ($exitCode)" }
}
function Install-PhoneApk([string]$Device, [string]$Package) {
    $output = Join-Path $logs "release-local-$version-build$buildNumber-install.log"
    $errors = Join-Path $logs "release-local-$version-build$buildNumber-install-error.log"
    # Keep ownership of the native process handle. Windows PowerShell 5's
    # Start-Process wrapper can return a null ExitCode after a successful wait.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $adb
    $start.Arguments = ('-s "{0}" install -r "{1}"' -f $Device,$Package)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $installer = New-Object Diagnostics.Process
    $installer.StartInfo = $start
    try {
        if (-not $installer.Start()) { throw 'Unable to start phone installer' }
        $stdout = $installer.StandardOutput.ReadToEndAsync()
        $stderr = $installer.StandardError.ReadToEndAsync()
        $finished = $installer.WaitForExit(120000)
        if (-not $finished) {
            # Stop only our waiting client, never the daemon or phone installer.
            $installer.Kill()
        }
        $installer.WaitForExit()
        $exitCode = $installer.ExitCode
        [IO.File]::WriteAllText($output,$stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText($errors,$stderr.GetAwaiter().GetResult())
        Get-Content -LiteralPath $output,$errors | Write-Output
        if (-not $finished) { throw 'Phone installation is waiting for system confirmation; the APK remains in Download/GlobalSend-latest.apk' }
        if ($exitCode -ne 0) { throw "Phone installation was not completed ($exitCode); APK retained for manual installation" }
    } finally { $installer.Dispose() }
}
try {
    $env:APPDATA = $config
    $env:TEMP = $temp; $env:TMP = $temp
    $env:PUB_CACHE = 'F:\Caches\PubCache'
    $env:GRADLE_USER_HOME = 'F:\Android\GradleCache'
    $env:ANDROID_HOME = 'F:\Android\Sdk'; $env:JAVA_HOME = 'D:\Minecraft\java21'
    $env:CI = 'true'; $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $settings = @{ 'build-dir' = "build/local-release/$version"; 'enable-windows-desktop' = $true } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $config '.flutter_settings'), $settings, (New-Object Text.UTF8Encoding($false)))
    if (-not $PublishOnly) {
    # Flutter's Windows assembler reuses build/flutter_assets independently of
    # the versioned native output. Retired assets must not survive in that cache.
    $buildAssets = [IO.Path]::GetFullPath((Join-Path $client 'build\flutter_assets'))
    $buildRoot = [IO.Path]::GetFullPath((Join-Path $client 'build'))
    if (-not $buildAssets.StartsWith($buildRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Build assets escaped the project build folder' }
    if (Test-Path -LiteralPath $buildAssets) {
        $assetEntries = @(Get-Item -LiteralPath $buildAssets -Force) + @(Get-ChildItem -LiteralPath $buildAssets -Recurse -Force)
        if (@($assetEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Build assets contain links; refusing to replace them' }
        Remove-Item -LiteralPath $buildAssets -Recurse -Force
    }
    Push-Location $client
    try {
        Invoke-Checked $dart @($snapshot,'build','windows','--release','--no-pub') *> (Join-Path $logs "release-local-$version-windows.log")
        if (-not $WindowsOnly) {
            Invoke-Checked $dart @($snapshot,'build','apk','--release','--no-pub','--target-platform=android-arm64','--android-project-arg=globalsendCompressNative=true','--android-project-arg=globalsendAbi=arm64-v8a','--android-project-arg=disable-abi-filtering=true') *> (Join-Path $logs "release-local-$version-android.log")
        }
    } finally { Pop-Location }
    }
    $windows = Join-Path $client "build\local-release\$version\windows\x64\runner\Release"
    $apk = $null; $apkBytes = 0
    if ($WindowsOnly) {
        Invoke-Checked 'D:\Python\python.exe' @((Join-Path $PSScriptRoot 'verify-no-fonts.py'),$windows)
    } else {
        $apk = Join-Path $releases "GlobalSend-$version-android-arm64-v8a.apk"
        Copy-Item -LiteralPath (Join-Path $client 'build\app\outputs\flutter-apk\app-release.apk') -Destination $apk -Force
        Invoke-Checked 'F:\Android\Sdk\build-tools\36.0.0\apksigner.bat' @('verify',$apk)
        Invoke-Checked 'D:\Python\python.exe' @((Join-Path $PSScriptRoot 'verify-no-fonts.py'),$windows,$apk)
        $apkBytes = (Get-Item -LiteralPath $apk).Length
    }
    Compress-Archive -Path "$windows\*" -DestinationPath (Join-Path $releases "GlobalSend-$version-windows-x64.zip") -Force

    # Stop only GlobalSend, never other Flutter/Node/Java applications.
    $running = @(Get-Process -Name globalsend -ErrorAction SilentlyContinue)
    foreach ($instance in $running) { Stop-Process -Id $instance.Id -Force }
    foreach ($instance in $running) { $instance.WaitForExit() }
    # New history migrations must have a cold, independently restorable input.
    $stateBackup = $null
    if (Test-Path -LiteralPath $env:GLOBALSEND_DATA_DIR -PathType Container) {
        $stateBackup = Join-Path $root ('backups\native-state\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-pre-' + $version)
        New-Item -ItemType Directory -Path (Split-Path -Parent $stateBackup) -Force | Out-Null
        Copy-Item -LiteralPath $env:GLOBALSEND_DATA_DIR -Destination $stateBackup -Recurse
    }
    if (Test-Path -LiteralPath $target) {
        $backup = Join-Path $root ('backups\windows-installed\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $backup -Recurse
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    # Asset removals must also reach the installed bundle. Merging the new
    # assets over the old directory would leave retired font files behind.
    $installedAssets = [IO.Path]::GetFullPath((Join-Path $target 'data\flutter_assets'))
    if (-not $installedAssets.StartsWith($target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Installed assets escaped the application folder' }
    if (Test-Path -LiteralPath $installedAssets) {
        $assetEntries = @(Get-Item -LiteralPath $installedAssets -Force) + @(Get-ChildItem -LiteralPath $installedAssets -Recurse -Force)
        $assetLinks = @($assetEntries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($assetLinks.Count) { throw 'Installed assets contain links; refusing to replace them' }
        Remove-Item -LiteralPath $installedAssets -Recurse -Force
    }
    Get-ChildItem -LiteralPath $windows | Copy-Item -Destination $target -Recurse -Force
    $env:APPDATA = $oldAppData
    if (-not $env:GLOBALSEND_DATA_DIR) { $env:GLOBALSEND_DATA_DIR = Join-Path $root 'artifacts\native-state' }
    [IO.File]::WriteAllText((Join-Path $target 'globalsend-data.json'),
        (@{ dataDirectory = $env:GLOBALSEND_DATA_DIR } | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    $process = Start-Process -FilePath (Join-Path $target 'globalsend.exe') -WorkingDirectory $target -WindowStyle Normal -PassThru
    # Persist Windows publication even when the phone disconnects during build.
    $report = @{ version=$version; buildNumber=$buildNumber; windowsVersion=$version; windows=$target; windowsPid=$process.Id; stateBackup=$stateBackup; apk=$apk; apkBytes=$apkBytes; apkBuilt=(!$WindowsOnly); serial=$Serial; androidInstalled=$false; phonePending=$true; lastConfirmedPhoneVersion=$previousRelease.lastConfirmedPhoneVersion; lastConfirmedPhoneBuildNumber=$previousRelease.lastConfirmedPhoneBuildNumber; publishedAt=(Get-Date).ToString('o') }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $releases 'latest-local.json') -Encoding UTF8

    if ($WindowsOnly) {
        $report.phoneDeferred = $true
        $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $releases 'latest-local.json') -Encoding UTF8
        $report | ConvertTo-Json
        if ($KeepRunning) { Wait-Process -Id $process.Id }
        return
    }

    try {
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            $devices = @(& $adb devices | ForEach-Object { if ($_ -match '^(\S+)\s+device$' -and $Matches[1] -notlike 'emulator-*') { $Matches[1] } })
            if ($Serial -and $devices -contains $Serial) { break }
            $usb = @($devices | Where-Object { $_ -notmatch ':' })
            if ($usb.Count -eq 1) { $Serial = $usb[0]; break }
            if (-not $Serial -and $devices.Count -eq 1) { $Serial = $devices[0]; break }
            # Reconnect only the address explicitly supplied by the user. No port scanning.
            if ($Serial -match '^\d+\.\d+\.\d+\.\d+:\d+$') {
                & $adb connect $Serial 2>&1 | ForEach-Object { Write-Output "$_" }
            }
            if ($attempt -lt 2) { Start-Sleep -Seconds 2 }
        }
        if (-not $Serial) { throw 'No single authorized phone is connected' }
        Invoke-Checked $adb @('-s',$Serial,'push',$apk,'/sdcard/Download/GlobalSend-latest.apk')
        $report.apkPushed=$true
        $report.deviceCopy='/sdcard/Download/GlobalSend-latest.apk'
        $report.serial=$Serial
        if ($PushOnlyPhone) {
            $report.phoneInstallSkipped=$true
            $report.phoneError='APK pushed; installation deferred by PushOnlyPhone'
        } else {
            Install-PhoneApk $Serial $apk
            Invoke-Checked $adb @('-s',$Serial,'shell','am','start','-n','dev.globalsend.globalsend/.MainActivity')
            $report.androidInstalled=$true; $report.phonePending=$false
            $report.lastConfirmedPhoneVersion=$version
            $report.lastConfirmedPhoneBuildNumber=$buildNumber
            $report.completedAt=(Get-Date).ToString('o')
        }
    } catch {
        # An unattended phone failure must not block the other release targets.
        $report.phoneError=$_.Exception.Message
        Write-Warning "Phone update pending; APK retained at $apk. $($report.phoneError)"
    }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $releases 'latest-local.json') -Encoding UTF8
    $report | ConvertTo-Json
    if ($KeepRunning) { Wait-Process -Id $process.Id }
} finally { $env:APPDATA = $oldAppData }
