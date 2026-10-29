--[[
    Temporary: loads EVERY module from the built bundle against the UI stub,
    starts them in dependency order, then ticks the heartbeat and times each
    feature's Update. Its job is to point at real cost instead of guessing.
]]

local SaveConfig = SaveConfigModule.Start()

local UI = Library.new{ Title = "FULL PROBE", ManualLoading = true }

local noop = function() end

local function Permissive(target)
    if type(target) ~= "table" then return target end
    if getmetatable(target) then return target end

    setmetatable(target, {
        __index = function(t, key)
            if key == "S" then
                local state = {}
                rawset(t, key, state)
                return state
            end

            local fn = function() end
            rawset(t, key, fn)
            return fn
        end,
    })

    return target
end

--// Services the stub does not model become permissive tables instead of empty
--// ones, so a module can be started far enough to be timed.
local OriginalGetService = game.GetService
local ExtraServices = {}

game.GetService = function(self, name)
    local service = OriginalGetService(self, name)

    if service and next(service) ~= nil then
        return service
    end

    if not ExtraServices[name] then
        ExtraServices[name] = Permissive({})
    end

    return ExtraServices[name]
end

local Players = game:GetService("Players")
Players.GetPlayerByUserId = Players.GetPlayerByUserId or function() return nil end
Players.GetNameFromUserIdAsync = Players.GetNameFromUserIdAsync or function(_, id) return "Player" .. tostring(id) end
Players.GetPlayerFromCharacter = Players.GetPlayerFromCharacter or function() return nil end
Players.GetUserThumbnailAsync = Players.GetUserThumbnailAsync or function() return "", false end

local Player = {
    Name = "TestPlayer",
    DisplayName = "Test Player",
    UserId = 1,
    Character = nil,
    WaitForChild = function(_, name) return name == "PlayerGui" and SmokeEnv.PlayerGui or nil end,
    FindFirstChild = function() return nil end,
    FindFirstChildOfClass = function() return nil end,
    GetAttribute = function() return nil end,
    GetChildren = function() return {} end,
    IsA = function(_, name) return name == "Player" end,
}

Players.LocalPlayer = Player
Players.GetPlayers = function() return { Player } end

local Feature = { ResetStats = { Enabled = false }, AutoFarm = { Enabled = false } }

local Context = {
    SaveConfig = SaveConfig,
    UI = UI,
    UIRef = {},
    Lifetime = { OnEnd = noop, Alive = true, RunCleanups = noop },
    Modules = {},
    Features = {},
    CONFIG = {
        UI_FONT = "",
        UI_THEME = {},
        UI_TEXT_SCALE = 1,
        TARGET_HP_MODE = "Disabled",
        TARGET_ENTITY_PRIORITY = {},
        BLOCK_WHITELIST = {},
        PROFILE_SAVE_DEBOUNCE = 0.5,
        TEXT_UPDATE_INTERVAL = 0.25,
        MAXIMUM_WALKSPEED = 16,
        MINIMUM_WALKSPEED = 8,
        HIGH_LEVEL_THRESHOLD = 100,
        FACE_RESPONSIVENESS = 25,
    },
    Feature = Feature,
    PatrolState = {},
    DEBUG_COLORS = {
        WaypointPending = Color3.fromRGB(1, 1, 1),
        WaypointVisited = Color3.fromRGB(1, 1, 1),
        WaypointCurrent = Color3.fromRGB(1, 1, 1),
        WaypointLine = Color3.fromRGB(1, 1, 1),
        BillboardText = Color3.fromRGB(1, 1, 1),
        BillboardMuted = Color3.fromRGB(1, 1, 1),
        MineZone = Color3.fromRGB(1, 1, 1),
    },
    NotifyAction = noop,
    Connect = function() return { Disconnect = noop } end,
    Player = Player,
    PlayerGui = SmokeEnv.PlayerGui,
    AICProfile = {
        S = { ProfileStore = { Profiles = {} } },
        QueueProfileSave = noop,
        SaveActiveProfile = noop,
        WriteGlobalStore = noop,
        ReadGlobalStore = function() return nil end,
        GetProfileNames = function() return {} end,
        ApplyDefaultPlaceConfig = noop,
        CanUseFileStorage = function() return false end,
    },
    AICCombat = Permissive({}),
    AICCombatUtils = Permissive({}),
    AICFeature = Permissive({}),
    AICDebug = Permissive({}),
    MiningFeature = Permissive({}),
}

local Ok, Err = xpcall(function()
    RuntimeModule.Start(Context)
end, debug.traceback)

if not Ok then
    print("RUNTIME START ERROR:\n" .. tostring(Err))
    return
end

for _, name in ipairs({ "AICFeature", "AICCombat", "AICCombatUtils", "AICDebug", "MiningFeature", "AICProfile" }) do
    Permissive(Context[name])
end

Context.AICCombat.GetDetectedPlayerTargets = function() return {} end
Context.AICCombat.GetDetectedMobTargets = function() return {} end
Context.AICCombat.GetPlayerTargets = function() return {} end
Context.AICCombat.GetMobTargets = function() return {} end
Context.AICFeature.updateCharacter = noop

--// AICProfile is a real table with methods in the app; keep the ones above and
--// let anything else resolve to a noop.
if type(Context.AICProfile) == "table" and getmetatable(Context.AICProfile) == nil then
    local Methods = {}
    for key, value in pairs(Context.AICProfile) do Methods[key] = value end
    setmetatable(Context.AICProfile, {
        __index = function(_, key)
            local fn = function() end
            rawset(Context.AICProfile, key, fn)
            return fn
        end,
    })
end

local Config = Context.CONFIG
Config.UI_THEME = Config.UI_THEME or {}
Config.UI_TEXT_SCALE = Config.UI_TEXT_SCALE or 1
Config.TARGET_ENTITY_PRIORITY = Config.TARGET_ENTITY_PRIORITY or {}
Config.TARGET_HP_MODE = Config.TARGET_HP_MODE or "Disabled"

Context.Feature.ResetStats = Context.Feature.ResetStats or { Enabled = false }
Context.Feature.AutoFarm = Context.Feature.AutoFarm or { Enabled = true }

for _, name in ipairs({ "Components", "Bootstrap" }) do
    local Spec = name == "Components" and ComponentsModule or BootstrapModule
    local Started, Failure = xpcall(Spec.Start, debug.traceback, Context)

    if not Started then
        print(name:upper() .. " START ERROR:\n" .. tostring(Failure))
        return
    end
end

------------------------------------------------------------------ load specs
--// Specs is built by the runner, which inlines every module in this chunk so
--// the modules see the stub's locals exactly as the real loader would.
local Loaded = 0

for _ in pairs(Specs) do
    Loaded += 1
end

local Order = {}

for Name in pairs(Specs) do
    table.insert(Order, Name)
end

table.sort(Order)
print(string.format("MODULES %d", Loaded))

------------------------------------------------------------------ start all
local StartedModules = {}
local InProgress = {}
local Failures = 0
local Suspended = 0

local function start(Name)
    if StartedModules[Name] then
        return StartedModules[Name]
    end

    if InProgress[Name] then
        return nil
    end

    local Spec = Specs[Name]

    if not Spec then
        return nil
    end

    InProgress[Name] = true

    for _, Dependency in ipairs(Spec.Dependencies or {}) do
        start(Dependency)
    end

    --// Runs the module in its own coroutine, with task.wait yielding. A module
    --// that waits for an instance the stub does not model then simply suspends
    --// instead of hanging the probe forever, which is what the real loader
    --// does too (it yields between modules).
    local Co = coroutine.create(function()
        return Spec.Start(Context)
    end)

    local PreviousWait = task.wait

    task.wait = function()
        if coroutine.isyieldable() then
            coroutine.yield()
        end
    end

    local Before = os.clock()
    local NewBefore, SetsBefore = StubStats.New, StubStats.Sets
    local Ok2, Module = coroutine.resume(Co)
    local Cost = os.clock() - Before
    local Built, Wrote = StubStats.New - NewBefore, StubStats.Sets - SetsBefore

    if Built > 40 then
        print(string.format("BUILD      %-26s instances +%4d  writes +%5d", Name, Built, Wrote))
    end

    task.wait = PreviousWait

    InProgress[Name] = nil

    if not Ok2 then
        Failures += 1
        print(string.format("START FAIL  %-26s %7.1f ms  %s", Name, Cost * 1000, tostring(Module):gsub("%s+", " "):sub(1, 140)))
        return nil
    end

    if coroutine.status(Co) == "suspended" then
        Suspended += 1
        print(string.format("START WAIT  %-26s %7.1f ms (still waiting; abandoned)", Name, Cost * 1000))
        return nil
    end

    StartedModules[Name] = Module
    Context.Modules[Name] = Module
    Context[Name] = Module

    if Spec.IsFeature or (type(Module) == "table" and Module.IsFeature) then
        table.insert(Context.Features, Module)
    end

    if Cost > 0.01 then
        print(string.format("START SLOW  %-26s %7.1f ms", Name, Cost * 1000))
    end

    return Module
end

for _, Name in ipairs(Order) do
    start(Name)
end

print(string.format("STARTED %d, FAILED %d, WAITING %d, FEATURES %d", #Order - Failures - Suspended, Failures, Suspended, #Context.Features))

------------------------------------------------------------------ GUI cost
--// How much GUI the menu actually builds. Every instance the window creates is
--// a client-side object the renderer has to keep, and every property written
--// is a change the client has to notice.
local Stats = StubStats

local function TopList(source, count, fmt)
    local list = {}

    for key, value in pairs(source) do
        table.insert(list, { key, value })
    end

    table.sort(list, function(a, b) return a[2] > b[2] end)

    for index = 1, math.min(count, #list) do
        print(string.format(fmt, tostring(list[index][1]), list[index][2]))
    end
end

print(string.format("GUI: %d instances, %d property writes to build the menu", Stats.New, Stats.Sets))
TopList(Stats.ByClass, 12, "GUI CLASS  %-22s %6d")
TopList(Stats.ByProp, 10, "GUI WRITE  %-22s %6d")

for _, Name in ipairs(Order) do
    local Module = StartedModules[Name]

    if type(Module) == "table" then
        if type(Module.BuildLateUI) == "function" then
            xpcall(Module.BuildLateUI, debug.traceback, Module)
        end

        if type(Module.Finalize) == "function" then
            local Before = os.clock()
            local Ok3, Failure = xpcall(Module.Finalize, debug.traceback, Module)

            if not Ok3 then
                print("FINALIZE FAIL " .. Name .. ": " .. tostring(Failure):gsub("%s+", " "):sub(1, 160))
            elseif os.clock() - Before > 0.02 then
                print(string.format("FINALIZE SLOW %-24s %7.1f ms", Name, (os.clock() - Before) * 1000))
            end
        end
    end
end

------------------------------------------------------------------ heartbeat
--// The window open and the pin panel visible: the two things that are true
--// when a player says "it freezes once the menu is up".
pcall(function()
    UI:Open()
end)

for Round = 1, 3 do
    local Total = 0
    local NewBefore, SetsBefore = Stats.New, Stats.Sets
    local Building = 0

    for _, Module in ipairs(Context.Features) do
        if type(Module.Update) == "function" then
            local Before = os.clock()
            local Ok4, Failure = xpcall(Module.Update, debug.traceback, Module, 0.016)
            local Cost = os.clock() - Before

            Total += Cost

            if Cost > 0.003 then
                print(string.format("TICK SLOW  r%d %-26s %7.2f ms", Round, tostring(Module.Name), Cost * 1000))
            end

            if not Ok4 and Round == 1 then
                print("TICK ERR   " .. tostring(Module.Name) .. ": " .. tostring(Failure):gsub("%s+", " "):sub(1, 160))
            end
        end
    end

    Building = Stats.New - NewBefore

    print(string.format(
        "TICK %d total %.1f ms over %d features   instances +%d   writes +%d",
        Round, Total * 1000, #Context.Features, Building, Stats.Sets - SetsBefore
    ))
end

print("FULL PROBE DONE")
