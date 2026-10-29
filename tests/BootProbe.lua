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
    error("RUNTIME START ERROR:\n" .. tostring(Err))
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
        error(name:upper() .. " START ERROR:\n" .. tostring(Failure))
    end

    print(name .. " ok")
end

--// The paths Bootstrap only runs when there is saved state or a live server:
--// a filled priority list and target pickers with entries.
local DataOk, DataErr = xpcall(function()
    local priority = Context.UIRef.PriorityComponent
    priority:SetPriority({ "Karkinos", "Drake" })
    priority:Add("Marina")
    priority:MoveUp("Marina")
    priority:MoveDown("Marina")
    priority:Remove("Drake")
    priority:Refresh()

    Context.AICCombat.GetDetectedPlayerTargets = function() return { "TestPlayer" } end
    Context.AICCombat.GetDetectedMobTargets = function() return { "Goblin" } end
    Context.AICUI.RefreshTargetDropdown()
    Context.AICUI.updateFeatureButtons()
end, debug.traceback)

if not DataOk then
    error("BOOT DATA PATH ERROR:\n" .. tostring(DataErr))
end

local target = Context.UIRef
assert(target.PriorityComponent.Header.LayoutOrder < target.PriorityComponent.Frame.LayoutOrder)
assert(target.PriorityComponent.Frame.LayoutOrder < target.MobTargetDropdown.Row.LayoutOrder)
assert(target.MobTargetDropdown.Row.LayoutOrder < target.PlayerTargetDropdown.Row.LayoutOrder)
assert(target.PlayerTargetDropdown.Row.LayoutOrder < target.TargetTypeDropdown.Row.LayoutOrder)
assert(target.TargetTypeDropdown.Row.LayoutOrder < target.TargetRefreshButton.Row.LayoutOrder)
local priorOrder = target.MobTargetDropdown.Row.LayoutOrder
Context.AICCombat.GetDetectedMobTargets = function() return { "Goblin", "Boss" } end
Context.AICUI.RefreshTargetDropdown()
assert(target.MobTargetDropdown.Row.LayoutOrder == priorOrder, "rebuilt mob picker changed order")

-- Clicking the name area copies a player's ID; the X only removes the row.
local clipboard, notices = nil, {}
setclipboard = function(value) clipboard = value end
Context.NotifyAction = function(_, text) table.insert(notices, text) end
local players = game:GetService("Players")
players.GetPlayerByUserId = function() return { Name = "Tester" } end
local list = target.TargetSection:AddPriority("Test whitelist", { "123456" })
AICUI.ShowUserNames(list)
local row
for _, child in ipairs(list.Holder:GetChildren()) do
    if child:IsA("Frame") then row = child end
end
assert(row and row:FindFirstChild("SelectEntry"), "player row is not clickable")
row:FindFirstChild("SelectEntry").MouseButton1Click:Fire()
assert(clipboard == "123456", "click did not copy the user ID")
assert(#list.Priority == 1, "copy changed the list")
local remove
for _, child in ipairs(row:GetChildren()) do
    if child:IsA("TextButton") and child.Text == "X" then remove = child end
end
assert(remove, "plain X remove button missing")
remove.MouseButton1Click:Fire()
assert(#list.Priority == 0, "X did not remove the player")
assert(clipboard == "123456", "removing a player changed the clipboard")
setclipboard = nil
list:Add("456")
row = nil
for _, child in ipairs(list.Holder:GetChildren()) do
    if child:IsA("Frame") then row = child end
end
row:FindFirstChild("SelectEntry").MouseButton1Click:Fire()
assert(notices[#notices]:find("not available", 1, true), "missing clipboard was not reported")

-- A place/profile reload refreshes the boss-stop list as well as its editor.
local refreshes = {}
Context.UIRef.WaypointListComponent = { SetPriority = noop }
Context.AICUI.RefreshBossRouteList = function() table.insert(refreshes, "list") end
Context.AICUI.RefreshBossRoutePickers = function() table.insert(refreshes, "picker") end
Context.AICUI.RefreshBossNames = function() table.insert(refreshes, "names") end
Context.AICUI.RefreshBossVisuals = function() table.insert(refreshes, "visuals") end
Context.AICUI.RefreshWaypointList()
assert(table.concat(refreshes, ",") == "list,picker,names,visuals", "profile refresh omitted boss route UI")
local colorSetting
for _, entry in ipairs(SaveConfig.GlobalSettings) do
    if entry.Key == "BOSS_PATH_COLOR" then colorSetting = entry end
end
assert(colorSetting and SaveConfig.NormalizeSetting(colorSetting, "aa55ff") == "AA55FF", "boss color was not normalized")
assert(SaveConfig.NormalizeSetting(colorSetting, "invalid") == "4F7CF5", "invalid boss color not reset")

-- Profile dropdown redraws must not invoke the selection handler: that handler
-- loads/reset the profile and refreshes the dropdown again during boot.
local profileLoads, defaultLoads = 0, 0
Context.AICProfile.S.ProfileStore = { LastUsed = "Saved", Profiles = { Saved = {} } }
Context.AICProfile.S.ActiveProfileName = "Saved"
Context.AICProfile.GetProfileNames = function() return { "Saved" } end
Context.AICProfile.LoadProfile = function()
    profileLoads += 1
    return true
end
Context.AICProfile.ApplyDefaultPlaceConfig = function() defaultLoads += 1 end
local ProfileSettings = ProfileSettingsModule.Start(Context)
local updateFeatureButtons = Context.AICUI.updateFeatureButtons
Context.AICUI.RefreshProfileDropdown()
assert(Context.UIRef.ProfileDropdown:Get() == "Saved", "saved profile not displayed")
assert(profileLoads == 0 and defaultLoads == 0, "profile redraw invoked selection")
Context.AICProfile.S.ActiveProfileName = nil
Context.AICUI.RefreshProfileDropdown()
assert(Context.UIRef.ProfileDropdown:Get() == "Default Config", "default profile not displayed")
assert(profileLoads == 0 and defaultLoads == 0, "default redraw reset profile")

-- Finalize restores a saved profile once; subsequent dropdown synchronization
-- must not load it again or overwrite it with the default configuration.
Context.AICProfile.S.ActiveProfileName = nil
Context.AICProfile.LoadProfile = function(name)
    profileLoads += 1
    Context.AICProfile.S.ActiveProfileName = name
    return true
end
Context.AICUI.RefreshWaypointList = noop
Context.AICUI.RefreshFarmZoneList = noop
Context.AICUI.RefreshDeadzoneList = noop
Context.AICUI.updatePosition = noop
Context.AICUI.updateFeatureButtons = noop
ProfileSettings:Finalize()
assert(profileLoads == 1 and defaultLoads == 0, "finalize reloaded or reset the saved profile")
assert(Context.UIRef.ProfileDropdown:Get() == "Saved", "finalize did not display the restored profile")

-- Synchronization of feature toggles/sliders must not fire their callbacks.
Context.AICUI.updateFeatureButtons = updateFeatureButtons
local callbacks = 0
local section = Context.UIRef.TargetSection
local toggle = section:AddToggle{ Name = "Sync test", Default = false, Callback = function() callbacks += 1 end }
Context.Feature.AutoFarm.Button = toggle
Context.AICFeature.S.Enabled = true
local slider = section:AddSlider{ Name = "Sync slider", Default = 0, Min = 0, Max = 90, Callback = function() callbacks += 1 end }
Context.UIRef.ExecuteChargeSlider = slider
Context.CONFIG.EXECUTE_CHARGE_HP_PERCENT = 25
Context.AICUI.updateFeatureButtons()
assert(toggle:Get() == true and slider:Get() == 25, "controls did not synchronize")
assert(callbacks == 0, "synchronization invoked user callbacks")
toggle:Set(false)
slider:Set(30)
assert(callbacks == 2, "user changes stopped invoking callbacks")
assert(#SmokeEnv.Errors == 0, "stub captured asynchronous handler errors: " .. table.concat(SmokeEnv.Errors, "; "))

print("BOOT PROBE PASSED")
