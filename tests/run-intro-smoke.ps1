param([string]$Luau = "luau")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw
$source = Get-Content (Join-Path $root "script/Intro.lua") -Raw
$heartbeat = Get-Content (Join-Path $root "script/Core/Heartbeat.lua") -Raw
$init = Get-Content (Join-Path $root "script/Init.lua") -Raw
$releaseStart = $init.IndexOf("-- The menu can lay out beneath the intro")
if ($releaseStart -lt 0) { throw "Startup handoff missing" }
$releaseEnd = $init.IndexOf("return Context", $releaseStart)
if ($releaseEnd -lt 0) { throw "Startup handoff end missing" }
$release = $init.Substring($releaseStart, $releaseEnd - $releaseStart)
$probe = Get-Content (Join-Path $PSScriptRoot "IntroSmoke.lua") -Raw
$combined = $stub + "`nlocal Intro = (function()`n" + $source + "`nend)()`n"
$combined += "local HeartbeatModule = (function()`n" + $heartbeat + "`nend)()`n"
$combined += "local function ReleaseStartup(Context)`nlocal Startup, Lifetime = Context.Startup, Context.Lifetime`n" + $release + "`nend`n" + $probe
$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$path = Join-Path $outDir "intro-smoke.lua"
[System.IO.File]::WriteAllText($path, $combined, (New-Object System.Text.UTF8Encoding($false)))
& $Luau $path
exit $LASTEXITCODE
