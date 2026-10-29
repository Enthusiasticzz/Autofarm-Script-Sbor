# Builds the real menu + Runtime's tabs/sections + Components + Bootstrap
# against the full UI stub, so a failure in Bootstrap.Start reports its real
# error and traceback instead of only the first line the loader can show.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-boot-probe.ps1 -Luau <path-to-luau.exe>

# -FromBundle runs the sources packed into script/Bundle instead of the files
# under script/. The bundle is what the client downloads, and the packer edits
# those sources (comments and indentation dropped), so this proves the bytes
# that actually run still build the same window.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-boot-probe.ps1 -Luau <path-to-luau.exe> [-FromBundle]

param(
    [string]$Luau = "luau",
    [switch]$FromBundle
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$Packed = @{}

if ($FromBundle) {
    $bundleDir = Join-Path $root "script/Bundle"
    $manifest = Get-Content (Join-Path $bundleDir "Manifest.lua") -Raw
    $partCount = [int]([regex]::Match($manifest, "Parts\s*=\s*(\d+)").Groups[1].Value)

    for ($index = 1; $index -le $partCount; $index++) {
        $text = Get-Content (Join-Path $bundleDir ("Part{0}.lua" -f $index)) -Raw
        $entries = [regex]::Matches($text, '(?s)\["([^"]+)"\] = \[======\]\r?\n(.*?)\r?\n\]======\],')

        foreach ($entry in $entries) {
            $Packed[$entry.Groups[1].Value] = $entry.Groups[2].Value
        }
    }
}

function Module-Source ([string]$packedPath, [string]$filePath) {
    if ($Packed.ContainsKey($packedPath)) {
        return $Packed[$packedPath]
    }

    return (Get-Content (Join-Path $root $filePath) -Raw)
}

$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw
$library = Module-Source "UI/Utils.lua" "script/UI/Utils.lua"
$runtime = Module-Source "Core/Runtime.lua" "script/Core/Runtime.lua"
$saveConfig = Module-Source "Core/SaveConfig.lua" "script/Core/SaveConfig.lua"
$components = Module-Source "UI/Components.lua" "script/UI/Components.lua"
$bootstrap = Module-Source "Core/Bootstrap.lua" "script/Core/Bootstrap.lua"
$profileSettings = Module-Source "Features/ProfileSettings.lua" "script/Features/ProfileSettings.lua"
$probe = Get-Content (Join-Path $PSScriptRoot "BootProbe.lua") -Raw

# The stub keeps its world in locals (the UI smoke test runs in the same chunk).
# The module specs below are loaded with loadstring, which only sees globals, so
# the same objects are published here. This run under the CLI, where globals are
# writable.
$bridge = @'
game = game
workspace = workspace
Enum = Enum
Instance = Instance
UDim = UDim
UDim2 = UDim2
Vector2 = Vector2
Color3 = Color3
Font = Font
TweenInfo = TweenInfo
ColorSequence = ColorSequence
NumberSequence = NumberSequence
task = task
typeof = typeof
warn = warn
Vector3 = {
    new = function(x, y, z)
        return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, Magnitude = 0 }, { __typename = "Vector3" })
    end,
    zero = setmetatable({ X = 0, Y = 0, Z = 0, Magnitude = 0 }, { __typename = "Vector3" }),
}
CFrame = {
    new = function()
        return { Position = Vector3.new(0, 0, 0), LookVector = Vector3.new(0, 0, 0) }
    end,
}
'@

# The CLI sandboxes each loadstring'd chunk, so the module specs are evaluated
# as functions inside this chunk instead: they then see the stub's locals.
$combined = $stub + "`n" + $bridge
$combined += "`nlocal Library = (function()`n" + $library + "`nend)()`n"
$combined += "`nlocal SaveConfigModule = (function()`n" + $saveConfig + "`nend)()`n"
$combined += "`nlocal RuntimeModule = (function()`n" + $runtime + "`nend)()`n"
$combined += "`nlocal ComponentsModule = (function()`n" + $components + "`nend)()`n"
$combined += "`nlocal BootstrapModule = (function()`n" + $bootstrap + "`nend)()`n"
$combined += "`nlocal ProfileSettingsModule = (function()`n" + $profileSettings + "`nend)()`n"
$combined += "`n" + $probe

$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$combinedPath = Join-Path $outDir "boot-probe.lua"
[System.IO.File]::WriteAllText($combinedPath, $combined, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Running $combinedPath"
& $Luau $combinedPath
exit $LASTEXITCODE
