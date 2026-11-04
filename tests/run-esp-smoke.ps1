param([string]$Luau = "luau")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw
$source = Get-Content (Join-Path $root "script/Features/Esp.lua") -Raw
$probe = Get-Content (Join-Path $PSScriptRoot "EspSmoke.lua") -Raw
$combined = $stub + "`n" + $probe.Replace("-- ESP_MODULE", ("local EspModule = (function()`n" + $source + "`nend)()"))
$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$path = Join-Path $outDir "esp-smoke.lua"
[System.IO.File]::WriteAllText($path, $combined, (New-Object System.Text.UTF8Encoding($false)))
& $Luau $path
exit $LASTEXITCODE
