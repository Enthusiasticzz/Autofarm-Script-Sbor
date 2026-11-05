param([string]$Luau = "luau", [switch]$FromBundle)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$probe = Get-Content (Join-Path $PSScriptRoot "LifecycleSmoke.lua") -Raw
$modules = @{
    AsyncModule = "Core/Async.lua"
    StaminaModule = "Features/AutoFarming_UI.lua"
    PotionModule = "Features/AutoFarming_Combat.lua"
    PartyModule = "Features/PartySystem.lua"
    MiningModule = "Features/AutoMining.lua"
    SmithingModule = "Features/AutoSmithing.lua"
    BoosterModule = "Features/SafeBoosterReset.lua"
}
$packed = ""
if ($FromBundle) {
    $packed = (Get-ChildItem (Join-Path $root "script/Bundle") -Filter "Part*.lua" | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
}
$sources = foreach ($name in $modules.Keys) {
    $path = $modules[$name]
    $source = Get-Content (Join-Path $root "script/$path") -Raw
    if ($FromBundle) {
        $pattern = '(?s)\["' + [regex]::Escape($path) + '"\] = \[======\[\r?\n(.*?)\r?\n\]======\],'
        $entry = [regex]::Match($packed, $pattern)
        if (-not $entry.Success) { throw "$path missing from bundle" }
        $source = $entry.Groups[1].Value
    }
    "local $name = (function()`n$source`nend)()"
}
$probe = $probe.Replace("-- MODULES", ($sources -join "`n"))
$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$path = Join-Path $outDir "lifecycle-smoke.lua"
[System.IO.File]::WriteAllText($path, $probe, (New-Object System.Text.UTF8Encoding($false)))
& $Luau $path
exit $LASTEXITCODE
