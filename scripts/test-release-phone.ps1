<# Exercise only phone-delivery orchestration, without ADB or a native build. #>
$ErrorActionPreference='Stop'
$errors=$null
$tokens=$null
$source=Join-Path $PSScriptRoot 'Release-Local.ps1'
$tree=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function=$tree.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Publish-PhonePackage'},$true)
if (-not $function) { throw 'Phone publisher missing' }
# Load this one trusted repository function, not the release script's side effects.
Invoke-Expression $function.Extent.Text
$script:calls=[Collections.Generic.List[object]]::new()
$script:installFails=$false
$script:launchFails=$false
$adb='fake-adb'
$version='1.0.74'
$buildNumber=97
function Install-PhoneApk([string]$Device,[string]$Package) {
    $script:calls.Add(@('install',$Device,$Package))
    if ($script:installFails) { throw 'User rejected permissions' }
}
function Invoke-Checked([string]$Exe,[string[]]$Arguments) {
    if ($Exe -ne $adb) { throw 'Unexpected executable' }
    $script:calls.Add($Arguments)
    if ($script:launchFails -and $Arguments -contains 'start') { throw 'Launch failed' }
}
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Report { return @{androidInstalled=$false;phonePending=$true;lastConfirmedPhoneBuildNumber=96} }

$report=Report
Publish-PhonePackage 'phone' 'F:/GlobalSend/candidate.apk' $report
Check ($calls.Count -eq 2 -and $calls[0][0] -eq 'install' -and $calls[1] -contains 'start') 'Normal update must stream-install, then launch, without push/mkdir'
Check ($report.androidInstalled -and $report.phoneLaunched -and -not $report.phonePending) 'Successful update state'
Check ($report.phoneInstallMode -eq 'adb-streamed-install-r' -and -not $report.ContainsKey('deviceCopy')) 'No leftover APK in normal mode'

$calls.Clear();$report=Report
Publish-PhonePackage 'phone' 'F:/GlobalSend/candidate.apk' $report -PushOnly
Check ($calls.Count -eq 2 -and $calls[0] -contains 'mkdir' -and $calls[1] -contains 'push') 'Explicit push-only retains its delivery contract'
Check ($report.deviceCopy -eq '/sdcard/Download/GlobalSend/Updates/GlobalSend-latest.apk') 'Push-only artifact must stay inside the product subfolder'
Check (-not $report.androidInstalled -and $report.phonePending -and $report.lastConfirmedPhoneBuildNumber -eq 96) 'Push alone is not installation'

$calls.Clear();$report=Report;$installFails=$true
try { Publish-PhonePackage 'phone' 'F:/GlobalSend/candidate.apk' $report; throw 'Expected installation denial' }
catch { Check ($_.Exception.Message -eq 'User rejected permissions') 'Preserve the installation denial' }
Check ($calls.Count -eq 1 -and -not $report.androidInstalled -and $report.phonePending) 'Do not launch or report success after installation denial'

$calls.Clear();$report=Report;$installFails=$false;$launchFails=$true
try { Publish-PhonePackage 'phone' 'F:/GlobalSend/candidate.apk' $report; throw 'Expected launch failure' }
catch { Check ($_.Exception.Message -eq 'Launch failed') 'Preserve the launch failure' }
Check ($report.androidInstalled -and -not $report.phonePending -and -not $report.phoneLaunched) 'Record a successful install separately from launch failure'
Write-Output 'PASS: streamed installation, explicit scoped push, installation denial, separate launch outcome'
