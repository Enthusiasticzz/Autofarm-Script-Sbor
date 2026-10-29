--[[
    Boot probe: builds the real window, Runtime's tabs/sections, Components and
    Bootstrap against stubbed Roblox, and prints the real error plus traceback
    when Bootstrap.Start fails. Run through run-boot-probe.ps1.
]]

--// The real feature and setting lists, so the probe restores the same ~70
--// toggles a live run builds.
local SaveConfig = SaveConfigModule.Start()

local UI = Library.new{ Title = "BOOT PROBE", ManualLoading = true }

local noop = function() end
local function Stub(name)
    return setmetatable({}, {
        __index = function(_, key)
            if key == "S" then
                rawset(_, key, {})
                return rawget(_, key)
            end
            return noop
        end,
    })
end

local Feature = { ResetStats = { Enabled = false }, AutoFarm = { Enabled = true } }

local Context = {
    SaveConfig = SaveConfig,
    UI = UI,
    UIRef = {},
    Lifetime = { OnEnd = noop },
    Modules = {},
    CONFIG = {
        UI_FONT = "",
        UI_THEME = {},
        UI_TEXT_SCALE = 1,
        TARGET_HP_MODE = "Disabled",
        TARGET_ENTITY_PRIORITY = {},
    },
    Feature = Feature,
    PatrolState = {},
    DEBUG_COLORS = {},
    NotifyAction = noop,
    Connect = function() return { Disconnect = noop } end,
    AICProfile = {
        S = {},
        ReadPinnedState = function() return nil end,
        QueuePinnedSave = noop,
        QueueProfileSave = noop,
        SaveActiveProfile = noop,
        WriteGlobalStore = noop,
        ReadGlobalStore = function() return nil end,
    },
    AICCombat = Stub("combat"),
    AICCombatUtils = Stub("combatutils"),
    AICFeature = Stub("feature"),
    AICDebug = Stub("debug"),
    MiningFeature = Stub("mining"),
}

--// The stub's LocalPlayer keeps PlayerGui as a property, while Runtime waits
--// for it as a child, so the probe hands over a player that answers directly.
local PlayerGui = SmokeEnv.PlayerGui
Context.PlayerGui = PlayerGui
Context.Player = {
    Name = "TestPlayer",
    DisplayName = "Test Player",
    UserId = 1,
    Character = nil,
    WaitForChild = function(_, name) return name == "PlayerGui" and PlayerGui or nil end,
    FindFirstChild = function() return nil end,
    GetAttribute = function() return nil end,
}

--// Runtime reads the local player from the service, not from Context.
game:GetService("Players").LocalPlayer = Context.Player

Context.AICCombat.GetDetectedPlayerTargets = function() return {} end
Context.AICCombat.GetDetectedMobTargets = function() return {} end
Context.AICCombat.ResetTargetState = noop

local Ok, Err = xpcall(function()
    RuntimeModule.Start(Context)
end, debug.traceback)

if not Ok then
    print("RUNTIME START ERROR:\n" .. tostring(Err))
    return
end

--// Runtime installs its own (mostly empty) module tables, which replace the
--// stubs above. Fill in whatever Bootstrap calls on them.
local function Permissive(target)
    if type(target) ~= "table" then return end

    setmetatable(target, {
        __index = function(t, key)
            if key == "S" then
                local state = {}
                rawset(t, key, state)
                return state
            end

            return noop
        end,
    })
end

for _, name in ipairs({ "AICFeature", "AICCombat", "AICCombatUtils", "AICDebug", "MiningFeature", "AICProfile" }) do
    Permissive(Context[name])
end

Context.AICFeature.updateCharacter = noop
Context.AICCombat.GetDetectedPlayerTargets = function() return {} end
Context.AICCombat.GetDetectedMobTargets = function() return {} end

--// Runtime also decides what CONFIG and the feature table are, so the fields
--// Bootstrap reads are re-seeded on whatever table it left behind.
local Config = Context.CONFIG
Config.UI_THEME = Config.UI_THEME or {}
Config.UI_FONT = Config.UI_FONT or ""
Config.UI_TEXT_SCALE = Config.UI_TEXT_SCALE or 1
Config.TARGET_ENTITY_PRIORITY = Config.TARGET_ENTITY_PRIORITY or {}
Config.TARGET_HP_MODE = Config.TARGET_HP_MODE or "Disabled"

Context.Feature.ResetStats = Context.Feature.ResetStats or { Enabled = false }
Context.Feature.AutoFarm = Context.Feature.AutoFarm or { Enabled = true }

local AICUI = Context.AICUI
print("runtime ok, tabs: " .. tostring(#UI.Tabs))

for _, name in ipairs({ "Components", "Bootstrap" }) do
    local Spec = name == "Components" and ComponentsModule or BootstrapModule

    local Started, Failure = xpcall(Spec.Start, debug.traceback, Context)

    if not Started then
        print(name:upper() .. " START ERROR:\n" .. tostring(Failure))
        return
    end

    print(name .. " ok")
end

--// The paths Bootstrap only runs when there is saved state or a live server:
--// a filled priority list, restored pins, and target pickers with entries.
local DataOk, DataErr = xpcall(function()
    local priority = Context.UIRef.PriorityComponent
    priority:SetPriority({ "Karkinos", "Drake" })
    priority:Add("Marina")
    priority:MoveUp("Marina")
    priority:MoveDown("Marina")
    priority:Remove("Drake")
    priority:Refresh()

    Context.UIRef.PinPanel:SetState({ Items = { "Board", "Stone" }, Floating = true, Visible = true, X = 300, Y = 200 })
    Context.UIRef.PinPanel:GetState()
    Context.UIRef.PinPanel:ResetPosition()

    Context.AICCombat.GetDetectedPlayerTargets = function() return { "TestPlayer" } end
    Context.AICCombat.GetDetectedMobTargets = function() return { "Goblin" } end
    Context.AICUI.RefreshTargetDropdown()
    Context.AICUI.updateFeatureButtons()
end, debug.traceback)

if not DataOk then
    print("BOOT DATA PATH ERROR:\n" .. tostring(DataErr))
    return
end

print("BOOT PROBE PASSED")
