<#
.SYNOPSIS
Preview or delete the one remaining approved, obsolete project AVD.
.EXAMPLE
& .\scripts\Clean-BlockedArtifacts.ps1
.EXAMPLE
& .\scripts\Clean-BlockedArtifacts.ps1 -Delete
.NOTES
Run manually. This script does not change execution policy or stop processes.
The shared F:\Android\Avd\Chrona_Classroom_36 AVD is not a deletion target.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param([switch]$Delete)

$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$approvedProject = [IO.Path]::GetFullPath('F:\Codes\Java\GlobalSend').TrimEnd('\')
if ($project -ine $approvedProject) { throw 'Run this script from its original GlobalSend scripts folder.' }
$target = [IO.Path]::GetFullPath((Join-Path $project 'artifacts\emulator\GlobalSend_JNI_36.avd'))
if (-not $target.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Target is outside the approved project.'
}
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host 'Already removed. Nothing to delete.'
    return
}

# Never follow a project ancestor or a nested link into a shared SDK or AVD.
$cursor = $target
while ($cursor.Length -ge $project.Length) {
    $item = Get-Item -LiteralPath $cursor -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Link detected: $cursor" }
    if ($cursor -eq $project) { break }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
}

# Inspect only emulator process metadata; do not close the shared emulator.
$emulators = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -match '^(emulator|qemu-system.*)\.exe$'
})
foreach ($process in $emulators) {
    if (-not $process.CommandLine) { throw "Cannot inspect emulator PID $($process.ProcessId); no deletion performed." }
    $command = $process.CommandLine.Replace('/', '\')
    if ($command -match '\bGlobalSend_JNI_36\b' -or
        $command.IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "The old project AVD is running (PID $($process.ProcessId)); no deletion performed."
    }
}

$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($target)
[long]$bytes = 0
while ($pending.Count) {
    $item = Get-Item -LiteralPath $pending.Pop() -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Nested link detected; no deletion performed: $($item.FullName)"
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Force) { $pending.Push($child.FullName) }
    } else { $bytes += $item.Length }
}

Write-Host "Target: $target"
Write-Host ('Size: {0:N2} GB ({1} bytes)' -f ($bytes / 1e9), $bytes)
if (-not $Delete) {
    Write-Host 'PREVIEW ONLY. Add -Delete to remove this old project AVD.'
    return
}
if (-not $PSCmdlet.ShouldProcess($target, 'Delete obsolete GlobalSend_JNI_36 project AVD')) { return }

$reportDirectory = Join-Path $project 'artifacts\reports'
[void](New-Item -ItemType Directory -Path $reportDirectory -Force)
$reportPath = Join-Path $reportDirectory ('cleanup-blocked-manual-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
$report = [ordered]@{ recordedAt=(Get-Date).ToString('o'); target=$target; bytes=$bytes; status='delete-requested'; error='' }
$report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding UTF8
try {
    Remove-Item -LiteralPath $target -Recurse -Force
    if (Test-Path -LiteralPath $target) { throw 'Target still exists after deletion.' }
    $report.status = 'deleted'
    Write-Host ('Deleted. Reclaimed {0:N2} GB.' -f ($bytes / 1e9))
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    throw
} finally {
    $report | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host "Report: $reportPath"
}
