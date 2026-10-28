# Builds the menu against a stubbed Roblox environment and runs it.
# No Studio or client is needed: this only proves that the window, every
# widget the project uses, the Settings tab and the pinned panel construct,
# react to clicks and tear down without errors.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-ui-smoke.ps1 -Luau <path-to-luau.exe>

param(
    [string]$Luau = "luau"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw -Encoding UTF8
$library = Get-Content (Join-Path $root "script/UI/Utils.lua") -Raw -Encoding UTF8
$smoke = Get-Content (Join-Path $PSScriptRoot "UiSmoke.lua") -Raw -Encoding UTF8

# The library is a chunk that returns the Library table; wrapping it in a
# function lets the stub's locals act as its globals.
$combined = $stub + "`nlocal Library = (function()`n" + $library + "`nend)()`n" + $smoke

$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$combinedPath = Join-Path $outDir "ui-smoke.lua"
[System.IO.File]::WriteAllText($combinedPath, $combined, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Running $combinedPath"
& $Luau $combinedPath
exit $LASTEXITCODE
