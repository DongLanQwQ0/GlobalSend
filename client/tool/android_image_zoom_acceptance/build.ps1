$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$work = Join-Path $root 'artifacts\tmp\android-image-zoom-acceptance'
$classes = Join-Path $work 'classes'
New-Item -ItemType Directory -Path $classes -Force | Out-Null
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
$env:TEMP = $work
$env:TMP = $work
try {
$platform = 'F:\Android\Sdk\platforms\android-36'
$classpath = "$platform\android.jar;$platform\uiautomator.jar;$platform\optional\android.test.base.jar"
& 'D:\Minecraft\java21\bin\javac.exe' -encoding UTF-8 -source 8 -target 8 -classpath $classpath -d $classes (Join-Path $PSScriptRoot 'ZoomGestureTest.java')
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
$inputJar = Join-Path $work 'input.jar'
& 'D:\Minecraft\java21\bin\jar.exe' cf $inputJar -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
& 'F:\Android\Sdk\build-tools\36.0.0\d8.bat' --min-api 24 --output (Join-Path $work 'zoom-gesture-test.jar') --lib (Join-Path $platform 'android.jar') --classpath (Join-Path $platform 'uiautomator.jar') --classpath (Join-Path $platform 'optional\android.test.base.jar') $inputJar
if ($LASTEXITCODE -ne 0) { throw 'd8 failed' }
Write-Output (Join-Path $work 'zoom-gesture-test.jar')
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}
