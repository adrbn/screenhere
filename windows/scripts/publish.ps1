# Builds ScreenHere for Windows as one self-contained file: dist\ScreenHere-Windows.exe.
# The name is the one releases carry, and the one the app's updater looks for.
param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root 'dist'
$extra = @()
if ($Version) { $extra += "-p:Version=$Version" }

dotnet test (Join-Path $root 'ScreenHere.Tests') --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }

dotnet publish (Join-Path $root 'ScreenHere') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -o $dist --nologo @extra
if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }

$exe = Join-Path $dist 'ScreenHere-Windows.exe'
Move-Item (Join-Path $dist 'ScreenHere.exe') $exe -Force
"{0}  {1:N1} MB" -f $exe, ((Get-Item $exe).Length / 1MB)
