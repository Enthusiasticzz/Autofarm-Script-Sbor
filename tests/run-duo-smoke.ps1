param([string]$Luau = "luau")
$ErrorActionPreference = "Stop"
$source = Get-Content "$PSScriptRoot/../script/Features/BossNavigator.lua" -Raw
$start = $source.IndexOf('        local function GetDuoName()')
$end = $source.IndexOf('        -- Auto Farm', $start)
$logic = $source.Substring($start, $end - $start)
$setup = @'
local CONFIG = { BOSS_DUO_NAME = "Partner", BOSS_DUO_SYNC = true, BOSS_WAIT_FOR_SPAWN = true, BOSS_DUO_RANGE = 200 }
local S = {}
local Player = {}
local Members = {}
local Players = { GetPlayers = function() return Members end }
local function TrimText(v) return tostring(v or ""):match("^%s*(.-)%s*$") end
local function GetDuoRange() return CONFIG.BOSS_DUO_RANGE end
local AICCombatUtils = { GetHorizontalDistance = function(a, b) return math.abs(a - b) end }
local function Member(name, display, health, position)
    local char = {}
    local root = { Parent = char, Position = position }
    local hum = { Health = health }
    function char:FindFirstChild() return root end
    function char:FindFirstChildOfClass() return hum end
    return { Name = name, DisplayName = display, Character = char }, hum, root
end
'@
$checks = @'
local duo, hum, root = Member("Partner", "Friend", 100, 150)
Members = { duo }
S.AwaitDuoCharacter, S.AwaitDuoName = duo.Character, "Partner"
assert(not IsWaitingForDuo({ Position = 0 }, 0), "surviving duo must be accepted")
root.Position = 400
assert(not IsWaitingForDuo({ Position = 0 }, 1), "arrival must stay latched")
S = {}
assert(IsWaitingForDuo({ Position = 0 }, 2))
assert(S.DuoWaitReason == "400 / 200 STUDS")
hum.Health = 0
assert(IsWaitingForDuo({ Position = 0 }, 3))
assert(S.DuoWaitReason == "DUO IS DEAD / RESPAWNING")
Members = {}
assert(IsWaitingForDuo({ Position = 0 }, 4))
assert(S.DuoWaitReason == "PLAYER NOT IN SERVER")
local impostor = Member("Someone", "Partner", 100, 400)
local real = Member("Partner", "Real", 100, 100)
Members = { impostor, real }
assert(not IsWaitingForDuo({ Position = 0 }, 5), "username must beat display name")
S = {}
Members = { impostor, Member("Another", "Partner", 100, 100) }
assert(IsWaitingForDuo({ Position = 0 }, 6))
assert(S.DuoWaitReason == "AMBIGUOUS DISPLAY NAME - USE USERNAME")
CONFIG.BOSS_DUO_WAIT_TIMEOUT = 5
assert(not IsWaitingForDuo({ Position = 0 }, 11), "timeout must release wait")
S = {}
Members = { { Name = "Partner" } }
assert(IsWaitingForDuo({ Position = 0 }, 12))
assert(S.DuoWaitReason == "CHARACTER LOADING / NOT STREAMED")
print("PASS: duo readiness, identity, diagnostics, arrival latch and timeout")
'@
$out = Join-Path $PSScriptRoot '_duo-harness.luau'
try {
    [IO.File]::WriteAllText($out, $setup + "`n" + $logic + "`n" + $checks)
    & $Luau $out
    if ($LASTEXITCODE -ne 0) { throw 'Duo regression failed' }
} finally {
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
}
