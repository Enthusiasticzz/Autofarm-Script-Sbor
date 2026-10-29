param([string]$Luau = "luau")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$stub = Get-Content (Join-Path $PSScriptRoot "UiStub.lua") -Raw
$library = Get-Content (Join-Path $root "script/UI/Utils.lua") -Raw
$runtime = Get-Content (Join-Path $root "script/Core/Runtime.lua") -Raw
$saveConfig = Get-Content (Join-Path $root "script/Core/SaveConfig.lua") -Raw
$components = Get-Content (Join-Path $root "script/UI/Components.lua") -Raw
$bootstrap = Get-Content (Join-Path $root "script/Core/Bootstrap.lua") -Raw
$probe = Get-Content (Join-Path $PSScriptRoot "_FullProbe.lua") -Raw

$bridge = @'
local Vector3 = {
    new = function(x, y, z)
        return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, Magnitude = 0 }, { __typename = "Vector3" })
    end,
    zero = setmetatable({ X = 0, Y = 0, Z = 0, Magnitude = 0 }, { __typename = "Vector3" }),
}
local CFrame = {
    new = function()
        return { Position = Vector3.new(0, 0, 0), LookVector = Vector3.new(0, 0, 0) }
    end,
    lookAt = function()
        return { Position = Vector3.new(0, 0, 0), LookVector = Vector3.new(0, 0, 0) }
    end,
    Angles = function()
        return { Position = Vector3.new(0, 0, 0), LookVector = Vector3.new(0, 0, 0) }
    end,
}
'@

$specs = "local Specs = {}`nlocal function AddSpec(Spec)`n  if type(Spec) == 'table' and type(Spec.Start) == 'function' then Specs[Spec.Name] = Spec end`nend`n"
Get-ChildItem (Join-Path $root "script") -Recurse -Filter "*.lua" |
    Where-Object { $_.FullName -notmatch "\Bundle\\" -and $_.Name -ne "Utils.lua" -and $_.Name -ne "Init.lua" } |
    Sort-Object FullName | ForEach-Object {
        $specs += "AddSpec((function()`n" + (Get-Content $_.FullName -Raw) + "`nend)())`n"
    }

$combined = $stub + "`n" + $bridge
$combined += "`nlocal Library = (function()`n" + $library + "`nend)()`n"
$combined += "`nlocal SaveConfigModule = (function()`n" + $saveConfig + "`nend)()`n"
$combined += "`nlocal RuntimeModule = (function()`n" + $runtime + "`nend)()`n"
$combined += "`nlocal ComponentsModule = (function()`n" + $components + "`nend)()`n"
$combined += "`nlocal BootstrapModule = (function()`n" + $bootstrap + "`nend)()`n"
$combined += "`n" + $specs
$combined += "`n" + $probe

$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$combinedPath = Join-Path $outDir "full-probe.lua"
[System.IO.File]::WriteAllText($combinedPath, $combined, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Running $combinedPath"
& $Luau $combinedPath
exit $LASTEXITCODE
