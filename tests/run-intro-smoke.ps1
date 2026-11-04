param([string]$Luau = "luau")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw
$source = Get-Content (Join-Path $root "script/Intro.lua") -Raw
$probe = Get-Content (Join-Path $PSScriptRoot "IntroSmoke.lua") -Raw
$combined = $stub + "`nlocal Intro = (function()`n" + $source + "`nend)()`n" + $probe
$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$path = Join-Path $outDir "intro-smoke.lua"
[System.IO.File]::WriteAllText($path, $combined, (New-Object System.Text.UTF8Encoding($false)))
& $Luau $path
exit $LASTEXITCODE
