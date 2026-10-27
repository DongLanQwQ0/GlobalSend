<#
.SYNOPSIS
Preview or remove explicitly reviewed obsolete GlobalSend artifacts.
.EXAMPLE
& .\scripts\Clean-OldArtifacts.ps1
.EXAMPLE
& .\scripts\Clean-OldArtifacts.ps1 -Delete
.EXAMPLE
& .\scripts\Clean-OldArtifacts.ps1 -PlanPath artifacts\reports\cleanup-approved-remainder-20261027.plan.json -Delete
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param([switch]$Delete, [string]$PlanPath)

$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$prefix = $project + '\'
if (-not (Test-Path -LiteralPath (Join-Path $project 'client\pubspec.yaml'))) {
    throw 'Run the script from its original GlobalSend scripts directory.'
}

# The original reviewed list remains the default. A project-local plan can
# provide a newer explicit list; neither mode selects paths by age at deletion.
$targets = @'
client\build\group-password-1.0.1
client\build\group-password-tool-config
client\build\library-network-20261025
client\build\candidate-tool-config
client\build\reverse-direct-20261025
client\build\rtc-library-20261025
client\build\rtc-android-probe
client\build\native-drop-check
client\build\java-check
artifacts\candidates\web-1.0.2
artifacts\candidates\web-autoconnect
artifacts\candidates\web-library
artifacts\candidates\web-rtc
artifacts\candidates\web-workspace-1.0.3
artifacts\candidates\web-workspace-1.0.3-receipt
artifacts\candidates\web-workspace-redesign
artifacts\candidates\web-workspace-redesign-final
artifacts\releases\GlobalSend-1.0.0-android-arm64-v8a.apk
artifacts\releases\GlobalSend-1.0.0-android-public-default-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-compact-ui-android-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-editor-drag-android-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-library-network-20261025-android-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-library-network-20261025-windows.zip
artifacts\releases\GlobalSend-1.0.0-reverse-direct-20261025-android-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-reverse-direct-20261025-windows.zip
artifacts\releases\GlobalSend-1.0.0-rtc-library-20261025-android-arm64-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-rtc-library-20261025-android-debug-signed.apk
artifacts\releases\GlobalSend-1.0.0-rtc-library-20261025-windows.zip
artifacts\releases\GlobalSend-1.0.1-android-arm64-v8a.apk
artifacts\releases\GlobalSend-1.0.1-android-armeabi-v7a.apk
artifacts\releases\GlobalSend-1.0.1-android-packages.json
artifacts\releases\GlobalSend-1.0.1-android-x86_64.apk
artifacts\releases\GlobalSend-1.0.1-windows-x64.zip
artifacts\releases\windows-compact-ui-20261025.zip
artifacts\releases\windows-editor-drag-20261025.zip
artifacts\releases\windows-public-default-20261025-101658.zip
artifacts\releases\windows-validated-20261025-100514.zip
'@ -split '\r?\n'

if ($PlanPath) {
    $resolvedPlan = [IO.Path]::GetFullPath((Join-Path $project $PlanPath))
    if (-not $resolvedPlan.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The cleanup plan must be inside this project.'
    }
    $plan = Get-Content -LiteralPath $resolvedPlan -Raw | ConvertFrom-Json
    if ($plan.root.TrimEnd('\') -ine $project) { throw 'Cleanup plan root does not match this project.' }
    $targets = @($plan.entries | Where-Object status -eq 'ready' | ForEach-Object path)
}

function Assert-ProjectPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Outside project: $full"
    }
    # Check ancestors too: a normal child can still be under a junction.
    $cursor = $full
    while ($cursor.Length -ge $project.Length) {
        $item = Get-Item -LiteralPath $cursor -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Link/junction skipped: $cursor"
        }
        if ($cursor -eq $project) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Get-TargetBytes([string]$Path) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Path)
    [long]$bytes = 0
    while ($pending.Count) {
        $item = Get-Item -LiteralPath $pending.Pop() -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Contains link/junction; target skipped: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) {
                $pending.Push($child.FullName)
            }
        } else { $bytes += $item.Length }
    }
    return $bytes
}

$results = @()
foreach ($relative in $targets) {
    $path = Join-Path $project $relative
    $entry = [ordered]@{ path = $relative; status = 'missing'; bytes = 0; error = '' }
    try {
        if (Test-Path -LiteralPath $path) {
            $path = Assert-ProjectPath $path
            $entry.bytes = Get-TargetBytes $path
            $entry.status = 'preview'
            if ($Delete -and $PSCmdlet.ShouldProcess($path, 'Delete obsolete artifact')) {
                Remove-Item -LiteralPath $path -Recurse -Force
                if (Test-Path -LiteralPath $path) { throw "Target still exists: $path" }
                $entry.status = 'deleted'
            }
        }
    } catch {
        $entry.status = 'failed-or-skipped'
        $entry.error = $_.Exception.Message
    }
    $results += [pscustomobject]$entry
}

$results | Format-Table status, @{Name='MB'; Expression={ [math]::Round($_.bytes / 1e6, 2) }}, path -AutoSize | Out-Host
$deleted = @($results | Where-Object status -eq 'deleted')
$ready = @($results | Where-Object status -eq 'preview')
$deletedBytes = ($deleted | Measure-Object bytes -Sum).Sum
$readyBytes = ($ready | Measure-Object bytes -Sum).Sum
Write-Host ('Deleted: {0} targets, {1:N2} MB. Preview: {2} targets, {3:N2} MB.' -f $deleted.Count, ($deletedBytes / 1e6), $ready.Count, ($readyBytes / 1e6))
if (-not $Delete) { Write-Host 'Preview only. Add -Delete to remove the listed targets.' }

$reportDirectory = Join-Path $project 'artifacts\reports'
[void](New-Item -ItemType Directory -Path $reportDirectory -Force)
$reportPath = Join-Path $reportDirectory ('cleanup-manual-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
[ordered]@{
    recordedAt = (Get-Date).ToString('o'); deleteRequested = [bool]$Delete
    root = $project; plan = $PlanPath; deletedTargets = $deleted.Count; reclaimedBytes = $deletedBytes
    entries = $results
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
Write-Host "Report: $reportPath"
if (@($results | Where-Object status -eq 'failed-or-skipped').Count) {
    throw 'Some targets were skipped or could not be fully removed. See the report.'
}
