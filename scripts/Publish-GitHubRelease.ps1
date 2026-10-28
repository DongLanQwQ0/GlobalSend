[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('windows','android','ios')][string]$Platform,
  [Parameter(Mandatory)][string]$Package,
  [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
  [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$BuildNumber,
  [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
  [string]$AndroidSdk = 'F:\Android\Sdk',
  [switch]$Publish
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gh = 'F:\Programs\GitHubCLI\bin\gh.exe'
$repo = 'DongLanQwQ0/GlobalSend'
$file = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Package).Path
$work = Join-Path $root ('artifacts\tmp\github-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

# Check package contents, not a repository-wide version or a filename alone.
switch ($Platform) {
  'windows' {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
    try {
      $entries = @($zip.Entries | Where-Object { $_.FullName -match '(^|/)globalsend\.exe$' })
      if ($entries.Count -ne 1) { throw 'Expected one GlobalSend executable in the Windows ZIP.' }
      $exe = Join-Path $work 'globalsend.exe'
      [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $exe)
      $actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).ProductVersion
      if ($actual -ne "$Version+$BuildNumber") { throw "Package version mismatch: $actual" }
    } finally { $zip.Dispose() }
  }
  'android' {
    $aapt = Get-ChildItem -LiteralPath (Join-Path $AndroidSdk 'build-tools') -Directory |
      Sort-Object { [version]$_.Name } -Descending |
      ForEach-Object { Join-Path $_.FullName 'aapt2.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $aapt) { throw 'aapt2 is required from the existing Android SDK.' }
    $badging = (& $aapt dump badging $file.FullName) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'Could not read APK metadata.' }
    if ($badging -notmatch "package: name='dev.globalsend.globalsend' versionCode='(\d+)' versionName='([^']+)'") { throw 'Expected a GlobalSend APK.' }
    if ([long]$Matches[1] -ne $BuildNumber -or $Matches[2] -ne $Version) { throw 'APK version does not match the requested platform manifest.' }
  }
  'ios' {
    $actual = (& python (Join-Path $PSScriptRoot 'inspect-ipa-version.py') $file.FullName) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $actual.version -ne $Version -or $actual.build -ne $BuildNumber) { throw 'IPA version does not match the requested platform manifest.' }
  }
}
$manifest = Join-Path $work "globalsend-update-$Platform.json"
$metadata = [ordered]@{ schema=1; platform=$Platform; version=$Version; build=$BuildNumber; assets=@($file.Name); sourceCommit=$SourceCommit }
[IO.File]::WriteAllText($manifest, ($metadata | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
$tag = "v$Version-build$BuildNumber"
[pscustomobject]@{ repository=$repo; tag=$tag; platform=$Platform; package=$file.FullName; bytes=$file.Length; manifest=$manifest; publish=[bool]$Publish } | ConvertTo-Json
if (-not $Publish) { return }

# GitHub hosts packages. The center server is never used for distribution.
# Windows PowerShell 5 turns expected native stderr ("release not found")
# into a terminating ErrorRecord under Stop, before LASTEXITCODE is checked.
$priorErrorAction = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  & $gh release view $tag --repo $repo --json tagName 2>$null | Out-Null
  $releaseExists = $LASTEXITCODE -eq 0
} finally { $ErrorActionPreference = $priorErrorAction }
if (-not $releaseExists) {
  & $gh release create $tag --repo $repo --target $SourceCommit --title "GlobalSend $Version ($BuildNumber)" --notes 'Download the package matching your platform. IPA files require manual signing.'
  if ($LASTEXITCODE -ne 0) { throw 'GitHub release creation failed.' }
}
$ref = (& $gh api "repos/$repo/git/ref/tags/$tag") | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not read the release source tag.' }
$commit = $ref.object.sha
if ($ref.object.type -eq 'tag') { $commit = (& $gh api "repos/$repo/git/tags/$commit" --jq '.object.sha') }
if ($commit -ne $SourceCommit) { throw 'Existing release points at a different source commit; do not overwrite its packages.' }
& $gh release upload $tag $file.FullName $manifest --repo $repo --clobber
if ($LASTEXITCODE -ne 0) { throw 'GitHub package upload failed.' }
