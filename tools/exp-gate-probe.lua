-- EXP-GATE PROBE
--
-- Paste this into the executor's console while in game and read the [EXP-GATE]
-- lines. It does not need any more decompiled scripts: every module under
-- ReplicatedStorage is already on the client, so we can require it and read
-- the API it exports, which is enough to find whatever decides whether a death
-- or a reset costs EXP.
--
-- Three passes, all read-only:
--   A. the stats the player has, and any attribute that even looks related
--   B. every client module, required, with its exported key names filtered to
--      the words an EXP rule would use (level, exp, loss, death, safe, zone...)
--   C. the zone helpers CoreCommons forwards to, called for real
--
-- Then an optional watch: leave it running, die once on purpose (walk out of
-- a safe zone and let something kill you, not a reset), and it prints every
-- EXP change with the position and distance from spawn next to it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

local function out(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)

    print("[EXP-GATE] " .. (ok and text or tostring(fmt)))
end

-- Words an EXP-loss rule would plausibly use in a name.
local WORDS = {
    "exp", "level", "lvl", "loss", "lose", "lost", "penal", "punish",
    "death", "died", "dead", "respawn", "reset", "safe", "zone", "kill",
    "pvp", "protect", "immune", "keep", "pardon", "grant", "award", "reward",
}

local function Interesting(Name)
    local Low = string.lower(Name)

    for _, Word in ipairs(WORDS) do
        if string.find(Low, Word, 1, true) then
            return true
        end
    end

    return false
end

--////////////////////////////////////////////////////////////////////////
-- A. What the player actually carries
--////////////////////////////////////////////////////////////////////////

local function DumpValues(Root, Title)
    if not Root then
        out("%s: not found", Title)
        return
    end

    out("--- %s (%s)", Title, Root:GetFullName())

    local Any = false

    for _, Child in ipairs(Root:GetChildren()) do
        if typeof(Child) ~= "Instance" or not Child:IsA("ValueBase") then
            out("    [%s] %s", Child.ClassName, Child.Name)
        else
            local Ok, Value = pcall(function() return Child.Value end)

            out("    %s = %s  (%s)", Child.Name, tostring(Ok and Value or "?"), Child.ClassName)
        end

        Any = true
    end

    if not Any then
        out("    (no children)")
    end

    local Attrs = Root:GetAttributes()

    for Name, Value in pairs(Attrs) do
        out("    <attr> %s = %s", Name, tostring(Value))
    end
end

DumpValues(LocalPlayer:FindFirstChild("PlayerStats"), "PlayerStats")
DumpValues(LocalPlayer, "Player")
DumpValues(LocalPlayer.Character, "Character")

--////////////////////////////////////////////////////////////////////////
-- B. Every client module, required, with its API surface filtered
--////////////////////////////////////////////////////////////////////////

local Modules = ReplicatedStorage:FindFirstChild("Modules")

local function ScanModule(Module)
    local Ok, Result = pcall(require, Module)

    if not Ok then
        return
    end

    if type(Result) == "table" then
        local Hits, Total = {}, 0

        for Key in pairs(Result) do
            Total = Total + 1

            if type(Key) == "string" and Interesting(Key) then
                local Kind = type(Result[Key])

                table.insert(Hits, string.format("%s(%s)", Key, Kind))
            end
        end

        if #Hits > 0 then
            out("%s  ->  %s", Module:GetFullName(), table.concat(Hits, ", "))
        end
    elseif type(Result) == "function" and Interesting(Module.Name) then
        out("%s  ->  function", Module:GetFullName())
    end
end

if Modules then
    local Started = os.clock()
    local Count = 0

    out("--- scanning modules under %s", Modules:GetFullName())

    for _, Desc in ipairs(Modules:GetDescendants()) do
        if Desc:IsA("ModuleScript") then
            Count = Count + 1
            ScanModule(Desc)
        end
    end

    out("--- scanned %d modules in %.2fs", Count, os.clock() - Started)
else
    out("Modules folder not found")
end

--////////////////////////////////////////////////////////////////////////
-- C. The zone helpers CoreCommons forwards to, called for real
--////////////////////////////////////////////////////////////////////////

do
    local Utility = Modules and Modules:FindFirstChild("Utility")
    local Path = Utility and Utility:FindFirstChild("CommonZoneFuncs")

    if not Path and Modules then
        for _, Desc in ipairs(Modules:GetDescendants()) do
            if Desc:IsA("ModuleScript") and Desc.Name == "CommonZoneFuncs" then
                Path = Desc
                break
            end
        end
    end

    if Path then
        local Ok, Zone = pcall(require, Path)
        local Names = {}

        if Ok and type(Zone) == "table" then
            for Key, Value in pairs(Zone) do
                if type(Key) == "string" then
                    table.insert(Names, string.format("%s(%s)", Key, type(Value)))
                end
            end

            table.sort(Names)
            out("--- CommonZoneFuncs: %s", table.concat(Names, ", "))
        else
            out("--- CommonZoneFuncs require failed: %s", tostring(Zone))
        end
    else
        out("--- CommonZoneFuncs not found")
    end
end

-- The three CoreCommons wrappers, through the wrapper so we call what the game
-- calls, not our own guess at it.
do
    local Shared = Modules and Modules:FindFirstChild("Shared")
    local Commons = Shared and Shared:FindFirstChild("CoreCommons")

    if Commons then
        local Ok, Core = pcall(require, Commons)

        if Ok and type(Core) == "table" then
            for _, Name in ipairs({ "checkSafeZone", "checkKillZone", "checkPvpZone" }) do
                local Fine, Result = pcall(function() return Core[Name]() end)

                out("%s() -> %s", Name, Fine and tostring(Result) or ("error: " .. tostring(Result)))
            end
        else
            out("CoreCommons require failed: %s", tostring(Core))
        end
    else
        out("CoreCommons not found")
    end
end

--////////////////////////////////////////////////////////////////////////
-- D. Watch: what EXP does on a real death
--////////////////////////////////////////////////////////////////////////

-- Set to 0 to skip the watch, or a number of seconds to run it.
local WATCH_SECONDS = 0

if WATCH_SECONDS > 0 then
    local Stats = LocalPlayer:FindFirstChild("PlayerStats")
    local Exp = Stats and Stats:FindFirstChild("EXP")
    local Level = Stats and Stats:FindFirstChild("Level")

    if Exp then
        local Last = Exp.Value
        local Ends = os.clock() + WATCH_SECONDS

        out("--- watching EXP for %ds, go die somewhere it should hurt", WATCH_SECONDS)

        while os.clock() < Ends do
            task.wait(0.1)

            if Exp.Value ~= Last then
                local Char = LocalPlayer.Character
                local Root = Char and Char:FindFirstChild("HumanoidRootPart")
                local At = Root and Root.Position or Vector3.zero
                local Spawns = workspace:FindFirstChild("SpawnLocation")
                local FromSpawn = Spawns and (At - Spawns.Position).Magnitude or -1

                out(
                    "EXP %d -> %d  (%+d)  level %s  at %.0f, %.0f, %.0f  %.0f from spawn",
                    Last,
                    Exp.Value,
                    Exp.Value - Last,
                    tostring(Level and Level.Value or "?"),
                    At.X, At.Y, At.Z,
                    FromSpawn
                )

                Last = Exp.Value
            end
        end

        out("--- watch over")
    else
        out("no EXP stat to watch")
    end
end
