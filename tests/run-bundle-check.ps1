# Loads every part of script/Bundle and compiles every module source inside it.
# The bundle is what the client actually runs, and tools/build-bundle.ps1 rewrites
# the sources it packs (comments and indentation dropped), so a part that still
# loads can hold a module that no longer parses.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-bundle-check.ps1 -Luau <path-to-luau.exe>

param(
    [string]$Luau = "luau"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bundleDir = Join-Path $root "script/Bundle"

$manifest = Get-Content (Join-Path $bundleDir "Manifest.lua") -Raw
$parts = [int]([regex]::Match($manifest, "Parts\s*=\s*(\d+)").Groups[1].Value)

if ($parts -lt 1) {
    throw "Manifest.lua does not name a part count"
}

$combined = ""

for ($index = 1; $index -le $parts; $index++) {
    $path = Join-Path $bundleDir ("Part{0}.lua" -f $index)

    if (-not (Test-Path $path)) {
        throw ("Part{0}.lua is missing but the manifest counts {1} parts" -f $index, $parts)
    }

    $combined += "`nlocal P$index = (function()" + (Get-Content $path -Raw) + "`nend)()`n"
}

$refs = (1..$parts | ForEach-Object { "P$_" }) -join ", "

$combined += @"

local Parts = { $refs }
local Total, Failed = 0, 0

for _, Part in ipairs(Parts) do
    for Path, Source in pairs(Part) do
        Total += 1

        local Chunk, Error = loadstring(Source, "@" .. Path)

        if not Chunk then
            Failed += 1
            print("COMPILE FAIL " .. Path .. ": " .. tostring(Error))
        end
    end
end

print(string.format("BUNDLE %d parts, %d modules, %d compile failures", #Parts, Total, Failed))
assert(Failed == 0, "a module in the bundle no longer compiles")
"@

$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$combinedPath = Join-Path $outDir "bundle-check.lua"
[System.IO.File]::WriteAllText($combinedPath, $combined, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Running $combinedPath"
& $Luau $combinedPath
exit $LASTEXITCODE
