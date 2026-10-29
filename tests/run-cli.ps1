# Builds a single-file harness (the Luau CLI sandboxes each module's globals)
# and runs the pure-logic tests with luau.exe.
#
# Usage: powershell -ExecutionPolicy Bypass -File tests/run-cli.ps1 -Luau <path-to-luau.exe>
param(
    [string]$Luau = "luau"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$stub = Get-Content (Join-Path $PSScriptRoot "StubRoblox.lua") -Raw
$stub = [regex]::Replace($stub, '(?s)\s*return\s+Stub\s*$', '')

$runtime = Get-Content (Join-Path $root "script/Core/Runtime.lua") -Raw
$logger = Get-Content (Join-Path $root "script/Core/Logger.lua") -Raw
$profileManager = Get-Content (Join-Path $root "script/Core/ProfileManager.lua") -Raw
$profileManagerStorage = Get-Content (Join-Path $root "script/Core/ProfileManager_Storage.lua") -Raw
$profileManagerGlobal = Get-Content (Join-Path $root "script/Core/ProfileManager_Global.lua") -Raw
$profileManagerSerialization = Get-Content (Join-Path $root "script/Core/ProfileManager_Serialization.lua") -Raw
$profileManagerCreation = Get-Content (Join-Path $root "script/Core/ProfileManager_Creation.lua") -Raw
$autoFarmingCombat = Get-Content (Join-Path $root "script/Features/AutoFarming_Combat.lua") -Raw
$autoFarmingNavigation = Get-Content (Join-Path $root "script/Features/AutoFarming_Navigation.lua") -Raw
$autoFarmingState = Get-Content (Join-Path $root "script/Features/AutoFarming_State.lua") -Raw
$autoFarmingUI = Get-Content (Join-Path $root "script/Features/AutoFarming_UI.lua") -Raw
$autoFarmingSmithing = Get-Content (Join-Path $root "script/Features/AutoFarming_Smithing.lua") -Raw
$autoFarmingMining = Get-Content (Join-Path $root "script/Features/AutoFarming_Mining.lua") -Raw
$heartbeat = Get-Content (Join-Path $root "script/Core/Heartbeat.lua") -Raw

$body = @'
local RuntimeModule = assert(loadstring(RuntimeSource, "@Runtime.lua"))()

local SaveConfig = {
    Settings = {},
    GlobalSettings = {},
    Features = {
        { Name = "AutoFarm", Default = true, Key = "AF" },
        { Name = "AutoBlock", Default = true, Key = "AB" },
    },
    GetSettingDefault = function(_, entry) return entry.Default end,
    NormalizeSetting = function(_, entry, value)
        if value == nil then return entry.Default end
        return value
    end,
    GetSetting = function(_, key) return { Key = key } end,
}

local Context = {
    SaveConfig = SaveConfig,
    UI = UI,
    Lifetime = { OnEnd = function() end },
    Modules = {},
}

local Runtime = RuntimeModule.Start(Context)

Context.Runtime = Runtime
Context.Logger = assert(loadstring(LoggerSource, "@Logger.lua"))().Start(Context)
Context.Services = Context.Services or {}
Context.Services.HttpService = {
    JSONEncode = function(_, value) return tostring(value) end,
    JSONDecode = function(_, value) return {} end,
}

assert(loadstring(ProfileManagerStorageSource, "@ProfileManager_Storage.lua"))().Start(Context)
assert(loadstring(ProfileManagerGlobalSource, "@ProfileManager_Global.lua"))().Start(Context)
assert(loadstring(ProfileManagerSerializationSource, "@ProfileManager_Serialization.lua"))().Start(Context)
assert(loadstring(ProfileManagerCreationSource, "@ProfileManager_Creation.lua"))().Start(Context)

local ProfileManager = assert(loadstring(ProfileManagerSource, "@ProfileManager.lua"))()
ProfileManager.Start(Context)
local AICProfile = Context.AICProfile
local Config = Context.AICConfig

--// AutoFarming helper sub-modules only register functions on AICFeature at
--// Start, so a small stub context is enough to prove the split wiring holds.
local AICFeature = { S = {} }
Context.AICFeature = AICFeature
Context.AICCombat = { S = {} }
Context.AICCombatUtils = { GetHorizontalDistance = function() return 0 end }
Context.UIRef = {}
Context.CONFIG = {
    EQUIP_TOGGLE_COOLDOWN = 0.3,
    CONSUME_INTERVAL = 1,
    HIGH_LEVEL_THRESHOLD = 100,
    MAXIMUM_WALKSPEED = 50,
    MINIMUM_WALKSPEED = 16,
}
Context.Player = { FindFirstChild = function() return nil end }
Context.PlayerGui = { FindFirstChild = function() return nil end }
Context.Services.Replicated = { FindFirstChild = function() return nil end }

for _, Source in ipairs({
    AutoFarmingCombatSource,
    AutoFarmingNavigationSource,
    AutoFarmingStateSource,
    AutoFarmingUISource,
    AutoFarmingSmithingSource,
    AutoFarmingMiningSource,
}) do
    assert(loadstring(Source, "@AutoFarmingSub.lua"))().Start(Context)
end

local Passed, Failed = 0, 0
local function Check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        Passed += 1
        print(string.format("  OK   %s", name))
    else
        Failed += 1
        print(string.format("  FAIL %s: %s", name, tostring(err)))
    end
end

local function Equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

Check("NormalizeWaitList clamps and pads", function()
    local r = Config.NormalizeWaitList({ 100, -5, 999 }, 4)
    Equal(r[1], 100, "valid")
    Equal(r[2], 0, "negative")
    Equal(r[3], 600, "over max")
    Equal(r[4], 0, "missing")
end)

Check("NormalizeWaitList handles nil", function()
    local r = Config.NormalizeWaitList(nil, 2)
    Equal(r[1], 0, "nil 1")
    Equal(r[2], 0, "nil 2")
end)

Check("NormalizeJumpList coerces", function()
    local r = Config.NormalizeJumpList({ true, false, nil }, 3)
    Equal(r[1], true, "true")
    Equal(r[2], false, "false")
    Equal(r[3], false, "missing")
end)

Check("NormalizeZonePairs drops out-of-range", function()
    local r = Config.NormalizeZonePairs({ 1, 5, 0 }, 3, 3)
    Equal(r[1], 1, "in range")
    Equal(r[2], 0, "above")
    Equal(r[3], 0, "zero")
end)

Check("CloneTargetList dedupes and filters", function()
    local r = Config.CloneTargetList({ "A", "A", "", "B", 3 })
    Equal(#r, 2, "count")
    Equal(r[1], "A", "first")
    Equal(r[2], "B", "second")
end)

Check("CheckJumpWaypoint reports reach", function()
    local ok, reached = Config.CheckJumpWaypoint({ WAYPOINT_JUMPS = { [1] = true } }, 1, 1)
    Equal(ok, true, "jump")
    Equal(reached, true, "reach")
end)

Check("Serialize/Deserialize round-trips a table", function()
    local source = { A = 1, B = "two", C = { D = true } }
    local encoded = AICProfile.SerializeConfigValue(source)
    local decoded = AICProfile.DeserializeConfigValue(encoded)
    Equal(decoded.A, 1, "A")
    Equal(decoded.B, "two", "B")
    Equal(decoded.C.D, true, "C.D")
end)

Check("MergeConfig overrides nested keys", function()
    local base = { A = 1, Nested = { X = 1, Y = 2 } }
    local override = { Nested = { Y = 9 } }
    local merged = AICProfile.MergeConfig(base, override)
    Equal(merged.A, 1, "base kept")
    Equal(merged.Nested.X, 1, "nested base kept")
    Equal(merged.Nested.Y, 9, "nested override")
end)

Check("IsArrayTable detects arrays", function()
    Equal(AICProfile.IsArrayTable({ 1, 2, 3 }), true, "array")
    Equal(AICProfile.IsArrayTable({ A = 1 }), false, "map")
end)

Check("AutoFarming split registers its helpers", function()
    local Expected = {
        "EnsureWeaponDrawnRaw",
        "EnsureWeaponDrawn",
        "TryConsumePotion",
        "TryHeal",
        "ApproachTarget",
        "RunGather",
        "SetFarmState",
        "DescribeChase",
        "RunSideJobs",
        "GetPlayerStatValue",
        "GetPlayerLevel",
        "CreateToggleContainer",
        "RegenStamina",
        "RenderUpdate",
    }

    for _, Name in ipairs(Expected) do
        Equal(type(AICFeature[Name]), "function", Name)
    end
end)

Check("Heartbeat isolates a failing feature", function()
    local Handler
    local FakeRun = {
        Heartbeat = {
            Connect = function(_, fn)
                Handler = fn
                return { Disconnect = function() end }
            end,
        },
    }

    local Ctx = {
        Services = { RunService = FakeRun },
        Lifetime = { Alive = true },
    }

    local Hb = assert(loadstring(HeartbeatSource, "@Heartbeat.lua"))().Start(Ctx)
    local Good, Bad = 0, 0

    local Features = {
        { Name = "Good", Update = function() Good += 1 end },
        { Name = "Bad", Update = function() Bad += 1; error("boom") end },
    }

    Hb:Start(Features)
    Handler(0.1)
    Handler(0.1)

    Equal(Good, 2, "a good feature kept updating past a failing one")
    Equal(Bad, 1, "a failing feature is backed off instead of retried every frame")
    Equal(Hb.Failing["Bad"].Count, 1, "the failure was recorded once")
    Equal(Hb.Failing["Good"], nil, "a feature that works was not marked")

    --// It is retried once the pause is over, rather than being disabled for the
    --// rest of the session.
    Hb.Failing["Bad"].Until = 0
    Handler(0.1)
    Equal(Bad, 2, "a failing feature is retried after the pause")
    Equal(Hb.Failing["Bad"].Count, 2, "the retry counted")

    --// A run that has ended unhooks its own loop instead of touching a newer
    --// run's state.
    Ctx.Lifetime.Alive = false
    Hb:Start(Features)
    Handler(0.1)
    Equal(Hb.Connection, nil, "a stopped run unhooked its heartbeat")
end)

Check("Logger gates debug output", function()
    Context.Logger.SetVerbose(false)
    Equal(Context.Logger.IsDebugEnabled(), false, "off")

    Context.Logger.SetVerbose(true)
    Equal(Context.Logger.IsDebugEnabled(), true, "on")

    --// Exercises the %s formatter with a literal % in the argument.
    Context.Logger.debug("verbose probe: value=%s", "50%")

    Context.Logger.SetVerbose(false)
    Equal(Context.Logger.IsDebugEnabled(), false, "off again")
end)

print(string.format("\n%d passed, %d failed", Passed, Failed))
if Failed > 0 then
    error(string.format("%d test(s) failed", Failed), 0)
end
'@

$combined = @"
$stub

local RuntimeSource = [====[
$runtime
]====]

local LoggerSource = [====[
$logger
]====]

local ProfileManagerSource = [====[
$profileManager
]====]

local ProfileManagerStorageSource = [====[
$profileManagerStorage
]====]

local ProfileManagerGlobalSource = [====[
$profileManagerGlobal
]====]

local ProfileManagerSerializationSource = [====[
$profileManagerSerialization
]====]

local ProfileManagerCreationSource = [====[
$profileManagerCreation
]====]

local AutoFarmingCombatSource = [====[
$autoFarmingCombat
]====]

local AutoFarmingNavigationSource = [====[
$autoFarmingNavigation
]====]

local AutoFarmingStateSource = [====[
$autoFarmingState
]====]

local AutoFarmingUISource = [====[
$autoFarmingUI
]====]

local AutoFarmingSmithingSource = [====[
$autoFarmingSmithing
]====]

local AutoFarmingMiningSource = [====[
$autoFarmingMining
]====]

local HeartbeatSource = [====[
$heartbeat
]====]

$body
"@

$outDir = Join-Path $PSScriptRoot "output"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$combinedPath = Join-Path $outDir "combined-run.lua"
Set-Content -Path $combinedPath -Value $combined -NoNewline

Write-Host "Running $combinedPath"
& $Luau $combinedPath
exit $LASTEXITCODE
