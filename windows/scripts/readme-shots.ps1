# Redraws the README's pictures of the Windows app, from posed data:
# no real display arrangement, no real clipboard.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$shots = Join-Path $env:TEMP "screenhere-shots-$PID"
dotnet build (Join-Path $root 'ScreenHere') -c Debug --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
$exe = Get-ChildItem (Join-Path $root 'ScreenHere\bin\Debug') -Recurse -Filter ScreenHere.exe | Select-Object -First 1
Start-Process $exe.FullName -ArgumentList '--shots', "`"$shots`"" -Wait
$assets = Join-Path (Split-Path $root -Parent) 'docs\assets'
foreach ($name in 'panel', 'history') {
    foreach ($scheme in 'dark', 'light') { Copy-Item (Join-Path $shots "$name-$scheme.png") (Join-Path $assets "windows-$name-$scheme.png") -Force }
}
"Pictures written to $assets"
