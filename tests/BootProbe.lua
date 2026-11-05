--[[
    Boot probe: builds the real window, Runtime's tabs/sections, Components and
    Bootstrap against stubbed Roblox, and prints the real error plus traceback
    when Bootstrap.Start fails. Run through run-boot-probe.ps1.
]]

--// The real feature and setting lists, so the probe restores the same ~70
--// toggles a live run builds.
local SaveConfig = SaveConfigModule.Start()
local TimeZones = TimeZonesModule.Start({})

local UI = Library.new{ Title = "BOOT PROBE", ManualLoading = true }

local function TabIcon(Tab)
    for _, Child in ipairs(Tab.Button:GetChildren()) do
        if Child.ClassName == "ImageLabel" then
            return Child.Image
        end
    end
end

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
    --// Alive is what the modules' loops and the settings save check, so the
    --// probe carries it like Init's Lifetime does.
    Lifetime = { OnEnd = noop, Alive = true },
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

--// The real profile serializer. The hiding-spot round trips below are the code
--// a reload or an import actually runs, so they have to run here too.
local SerializeOk, SerializeErr = xpcall(function()
    ProfileSerializationModule.Start(Context)
end, debug.traceback)

assert(SerializeOk, "PROFILE SERIALIZATION START ERROR:\n" .. tostring(SerializeErr))

--// Runtime also decides what CONFIG and the feature table are, so the fields
--// Bootstrap reads are re-seeded on whatever table it left behind.
local Config = Context.CONFIG
Config.UI_THEME = Config.UI_THEME or {}
Config.UI_FONT = Config.UI_FONT or ""
Config.UI_TEXT_SCALE = Config.UI_TEXT_SCALE or 1
Config.TARGET_ENTITY_PRIORITY = Config.TARGET_ENTITY_PRIORITY or {}
Config.TARGET_HP_MODE = Config.TARGET_HP_MODE or "Disabled"

--// Saved Settings-tab values, as the global store hands them over: Bootstrap
--// has to put them on the window before the tab is built, and a change made
--// later has to reach the store again.
Config.UI_MENU_KEY = "K"
Config.UI_PALETTE = "Navy"
Config.UI_WINDOW_WIDTH = 900
Config.UI_WINDOW_HEIGHT = 600
Config.UI_TAB_ANIMATION = "Slide"
Config.UI_NOTIFICATIONS = false
Config.UI_NOTIFICATION_POSITION = "Top left"
Config.UI_WATERMARK = true
Config.UI_KEYBIND_LIST = true
Config.UI_CURSOR = { Mode = "Always", Style = "Dot", Size = 150, Effects = false, CustomEnabled = true, Color = "FF8800" }

Context.Feature.ResetStats = Context.Feature.ResetStats or { Enabled = false }
Context.Feature.AutoFarm = Context.Feature.AutoFarm or { Enabled = true }

local AICUI = Context.AICUI
local RuntimeTabs = {
    { Context.UIRef.StatusTab, "Status", "110833916970208" },
    { Context.UIRef.FarmTab, "Farming", "133374538392505" },
    { Context.UIRef.BossTab, "Bosses", "120519237137109" },
    { Context.UIRef.EspTab, "ESP", "88721966949157" },
    { Context.UIRef.MineTab, "Mining", "72830736643456" },
    { Context.UIRef.ServerTab, "Server", "103577755616730" },
    { Context.UIRef.QuestTab, "Quest", "125636928571624" },
}

for _, Entry in ipairs(RuntimeTabs) do
    assert(TabIcon(Entry[1]) == "rbxassetid://" .. Entry[3], Entry[2] .. " tab icon is missing")
end

assert(#UI.Tabs == 7, "runtime should build seven task-focused tabs")
assert(Context.UIRef.CraftTab == Context.UIRef.MineTab, "resource pages were not consolidated")
assert(Context.UIRef.GearTab == Context.UIRef.QuestTab, "character pages were not consolidated")
assert(Context.UIRef.PartyTab == Context.UIRef.ServerTab, "party is not on Server")
assert(Context.UIRef.TeleportTab == Context.UIRef.EspTab, "travel is not on World")
assert(Context.UIRef.BlockSection.Tab == Context.UIRef.ServerTab, "player safety is not on Server")
assert(Context.UIRef.WebhookSection.Tab == Context.UIRef.ServerTab, "reports are not on Server")
assert(Context.UIRef.StatusTab.Heading, "the page has no visible heading")
assert(Context.UIRef.TargetSection.Header, "the section has no distinct heading")

print("runtime ok, tabs: " .. tostring(#UI.Tabs))

for _, name in ipairs({ "Components", "Bootstrap" }) do
    local Spec = name == "Components" and ComponentsModule or BootstrapModule

    local Started, Failure = xpcall(Spec.Start, debug.traceback, Context)

    if not Started then
        error(name:upper() .. " START ERROR:\n" .. tostring(Failure))
    end

    print(name .. " ok")
end

--// Every saved option reached the window, not just the ones with a hook of
--// their own (the font, theme and text scale above).
assert(UI.MenuKey == Enum.KeyCode.K, "saved menu key not applied")
assert(UI.Palette == "Navy", "saved palette not applied")
assert(UI.Root.Size.X.Offset == 900 and UI.Root.Size.Y.Offset == 600, "saved window size not applied")
assert(UI.TabAnimation == "Slide", "saved tab animation not applied")
assert(UI.Notifications.Enabled == false and UI.Notifications.Position == "Top left", "saved notifications not applied")
assert(UI.Watermark.Visible == true and UI.KeybindFrame.Visible == true, "saved watermark / keybind list not applied")
assert(UI.Cursor.Mode == "Always" and UI.Cursor.Style == "Dot" and UI.Cursor.Size == 150, "saved cursor not applied")
assert(UI.Cursor.Effects == false and UI.Cursor.CustomEnabled == true, "saved cursor switches not applied")

local storeWrites = 0
Context.AICProfile.WriteGlobalStore = function() storeWrites += 1 end
UI:SetMenuKey(Enum.KeyCode.J)
SmokeEnv.FlushDelayed(600)
assert(Config.UI_MENU_KEY == "J", "a settings change did not reach CONFIG")
assert(storeWrites == 1, "a settings change did not write the global store: " .. storeWrites)
UI:SetMenuKey(Enum.KeyCode.K)

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
    if child:IsA("TextButton") and child.Name == "Remove entry" then remove = child end
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
assert(TabIcon(Context.UIRef.ProfileTab) == "rbxassetid://139006229418347", "profile settings tab icon is missing")
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

--// BossNavigator: the player controls on the Bosses tab live in sections of
--// their own - the pause-for-strangers hold, its waypoint, its prompt, then
--// Auto Block and the whitelist - and each must open with its own title.
--// Starting the module is what proves those controls construct at boot
--// instead of only compiling.
local BossNavOk, BossNavErr = xpcall(BossNavigatorModule.Start, debug.traceback, Context)

if not BossNavOk then
    error("BOSSNAVIGATOR START ERROR:\n" .. tostring(BossNavErr))
end

--// The hold lives in Features/BossNavigator_Evade.lua now and reads the route
--// through AICFeature.BossNav; starting it here is what proves that seam is
--// complete at boot instead of the first time a stranger walks in.
local BossEvadeOk, BossEvadeErr = xpcall(BossEvadeModule.Start, debug.traceback, Context)

if not BossEvadeOk then
    error("BOSSNAVIGATOR_EVADE START ERROR:\n" .. tostring(BossEvadeErr))
end

--// The title of a section is its first row. A control given a negative
--// LayoutOrder to get above the other rows lands above the title too, which is
--// exactly what a section split is supposed to avoid.
local function SectionTitle(Section)
    local Best, BestOrder

    for _, Child in ipairs(Section.Frame:GetChildren()) do
        local Order = tonumber(Child.LayoutOrder)

        if Child:IsA("Frame") and Order and (not Best or Order < BestOrder) then
            Best, BestOrder = Child, Order
        end
    end

    if not Best then
        return ""
    end

    for _, Child in ipairs(Best:GetChildren()) do
        if Child:IsA("TextLabel") and Child.Text ~= "" then
            return Child.Text
        end
    end

    return ""
end

--// The time zone picker and the saved setting have to name the same zones: a
--// saved zone the picker does not list is reset to the default on load.
local zoneSetting

for _, entry in ipairs(SaveConfig.GlobalSettings) do
    if entry.Key == "DISCORD_TIMEZONE" then zoneSetting = entry end
end

assert(zoneSetting, "the saved time zone setting is missing")
assert(zoneSetting.Default == TimeZones.Default, "the saved time zone default drifted")
assert(zoneSetting.Options and #zoneSetting.Options == #TimeZones.Names, "the time zone list and the saved setting disagree")

for _, name in ipairs(TimeZones.Names) do
    assert(table.find(zoneSetting.Options, name), "the saved setting does not list " .. name)
end

assert(SaveConfig.NormalizeSetting(zoneSetting, "Mars") == TimeZones.Default, "an unknown saved zone was not reset")

--// The stamp follows the calendar by itself: in 2026 the US switch is 8 March
--// forward and 1 November back, so summer reads EDT and November reads EST.
assert(TimeZones.Stamp("US Eastern", 1768478400) == "07:00 AM EST", "January was not stamped EST")
assert(TimeZones.Stamp("US Eastern", 1773144000) == "08:00 AM EDT", "March was not stamped EDT")
assert(TimeZones.Stamp("US Eastern", 1793361600) == "08:00 AM EDT", "October was not stamped EDT")
assert(TimeZones.Stamp("US Eastern", 1793620800) == "07:00 AM EST", "November was not stamped EST")
assert(TimeZones.Stamp("UTC", 0) == "12:00 AM UTC", "UTC was not stamped")
assert(TimeZones.Stamp("US Arizona", 1782907200) == "05:00 AM MST", "Arizona changed with daylight saving")
assert(TimeZones.Get("Nowhere").Name == TimeZones.Default, "an unknown zone did not fall back to the default")

local boss = Context.UIRef
assert(boss.BlockSection and boss.WhitelistSection, "auto block sections missing")
assert(boss.EvadeSection and boss.EvadeListSection and boss.EvadeAddSection, "evade sections missing")
assert(SectionTitle(boss.EvadeSection) == "Pause For Strangers", "the hold's title is not at the top of its section: " .. SectionTitle(boss.EvadeSection))
assert(SectionTitle(boss.EvadeListSection) == "Hiding Spots", "the hiding-spot list's title is not at the top")
assert(SectionTitle(boss.EvadeAddSection) == "Add A Hiding Spot", "the add-a-spot section's title is not at the top")
assert(SectionTitle(boss.BlockSection) == "Stranger Protection", "the auto block title is not at the top of its section")
assert(SectionTitle(boss.WhitelistSection) == "Trusted Players", "the whitelist title is not at the top of its section")
assert(boss.BlockSection.Tab == boss.ServerTab, "auto block is not on the server tab")
assert(boss.DebugTab == nil, "debug tab still exists")
assert(boss.DebugSection and boss.DebugSection.Tab == boss.EspTab, "visualizer is not on the World tab")
assert(SectionTitle(boss.DebugSection) == "Route Visualizer", "visualizer section title is wrong")
assert(boss.BossBoundsVisualToggle, "fight bounds toggle missing")
assert(boss.BossDuoSyncToggle, "duo sync toggle missing")
assert(boss.BossDuoNameBox, "duo sync name box missing")
assert(boss.BossDuoRangeBox, "duo range box missing")
assert(boss.BossDuoSyncToggle:Get() == false, "duo sync started on")
assert(boss.WhitelistSection.Tab == boss.ServerTab, "the whitelist is not on the server tab")
assert(boss.EvadePauseToggle, "pause for strangers toggle missing")
assert(boss.EvadeListComponent, "hiding-spot list missing")
assert(boss.EvadeWaypointBox and boss.EvadePromptButton, "hiding-spot controls missing")
assert(boss.EvadeSpotLabel, "hiding-spot count label missing")
assert(boss.EvadeSpotLabel.Instance.Text:find("HIDING SPOTS:", 1, true), "hiding-spot label text missing")
assert(boss.EvadePauseToggle:Get() == false, "pause for strangers started on")
assert(boss.EvadePauseToggle.Row.Parent == boss.EvadeSection.Frame, "the hold's toggle was not placed in its own section")
assert(boss.EvadeWaypointBox.Row.Parent == boss.EvadeAddSection.Frame, "the add-waypoint box was not placed in its own section")
assert(boss.EvadePromptButton.Row.Parent == boss.EvadeAddSection.Frame, "the add-prompt button was not placed in its own section")        --// Auto Block's own module is not started here, so only the section it fills
        --// can be checked: it exists, it is titled, and it is on the Farming tab.
assert(boss.BlockSection.Tab ~= boss.BossTab and boss.WhitelistSection.Tab ~= boss.BossTab, "the auto block sections are still on the boss tab")

Context.AICProfile.S.ActiveProfileName = "Saved"
boss.EvadePauseToggle:Set(true)
assert(Context.Feature.PauseForStrangers.Enabled == true, "pause toggle did not turn the feature on")
assert(#SmokeEnv.Errors == 0, "pause toggle raised: " .. table.concat(SmokeEnv.Errors, "; "))
boss.EvadePauseToggle:Set(false)
assert(Context.Feature.PauseForStrangers.Enabled == false, "pause toggle did not turn the feature off")
assert(#SmokeEnv.Errors == 0, "pause toggle raised: " .. table.concat(SmokeEnv.Errors, "; "))

--// A waypoint number typed into the add box becomes a hiding spot on the
--// place config, so a reconnect to the same place has it again.
boss.EvadeWaypointBox:Set("12")
assert(#SmokeEnv.Errors == 0, "add hiding spot raised: " .. table.concat(SmokeEnv.Errors, "; "))
local livePlace = Context.Runtime:GetPlaceConfig()
assert(type(livePlace) == "table", "no place config after a hiding spot was saved")
assert(livePlace.BOSS_EVADE and livePlace.BOSS_EVADE.Spots, "the hiding-spot list was not saved on the place config")
assert(#livePlace.BOSS_EVADE.Spots == 1 and livePlace.BOSS_EVADE.Spots[1].Waypoint == 12, "the waypoint was not saved as a hiding spot")

--// Every edit saves through SetPlaceConfig, which hands back a normalized
--// copy, so what was saved has to be read again after an edit rather than
--// from the table read before it.
local function CurrentSpots()
    local place = Context.Runtime:GetPlaceConfig()

    return place and place.BOSS_EVADE and place.BOSS_EVADE.Spots or {}
end
assert(boss.EvadeSpotLabel.Instance.Text:find("1", 1, true), "the hiding-spot count was not reported")

--// The list is read back through the normalizer a profile or place load runs:
--// that is what used to drop every saved spot, so it is what is asserted here.
assert(type(Context.AICConfig.NormalizeBossEvade) == "function", "boss evade normalizer missing")
local reloaded = Context.AICConfig.NormalizeBossEvade(livePlace.BOSS_EVADE)
assert(reloaded.Spots and #reloaded.Spots == 1 and reloaded.Spots[1].Waypoint == 12, "the normalizer dropped the saved hiding spot")

local kept = Context.AICConfig.NormalizeBossEvade{
    Spots = {
        { Kind = "Waypoint", Waypoint = 5 },
        { Kind = "Prompt", Name = "Door", X = 10, Y = 2, Z = -3 },
        { Kind = "Waypoint", Waypoint = 0 },
        { Kind = "Prompt", Name = "Bad", X = 0 / 0, Y = 0, Z = 0 },
        "not a spot",
    },
}
assert(kept.Spots and #kept.Spots == 2, "the normalizer kept spots it should have dropped: " .. tostring(kept.Spots and #kept.Spots))
assert(kept.Spots[1].Kind == "Waypoint" and kept.Spots[1].Waypoint == 5, "the waypoint spot was not kept")
assert(kept.Spots[2].Kind == "Prompt" and kept.Spots[2].Name == "Door", "the prompt spot was not kept")
assert(Context.AICConfig.NormalizeBossEvade(nil).Spots == nil, "a save with no list should stay without one, so the old single spot can migrate")
assert(#Context.AICConfig.NormalizeBossEvade{ Spots = {} }.Spots == 0, "a list the player cleared came back")

--// A hiding spot has to survive the save format itself. A prompt spot is a
--// table that holds X/Y/Z, and the decoder read every table with those three
--// as a Vector3: the prompt came back as one, the normalizer dropped it (a
--// Vector3 has no Kind) and only waypoint spots - which hold no position -
--// survived. That is the bug that lost every prompt spot on reload.
local spotConfig = {
    BOSS_EVADE = {
        Spots = {
            { Kind = "Waypoint", Waypoint = 3 },
            { Kind = "Prompt", Name = "Door", X = 10, Y = 2, Z = -3 },
        },
    },
}

local roundTrip = Context.AICProfile.DeserializeConfigValue(
    Context.AICProfile.SerializeConfigValue(spotConfig)
)
local roundTripSpots = Context.AICConfig.NormalizeBossEvade(roundTrip.BOSS_EVADE).Spots
assert(#roundTripSpots == 2, "a hiding spot was lost in the save format: " .. tostring(#roundTripSpots))
assert(roundTripSpots[1].Kind == "Waypoint" and roundTripSpots[1].Waypoint == 3, "the waypoint spot did not survive the save format")
assert(roundTripSpots[2].Kind == "Prompt" and roundTripSpots[2].Name == "Door", "the prompt spot did not survive the save format")
assert(roundTripSpots[2].X == 10 and roundTripSpots[2].Z == -3, "the prompt spot lost its position")

--// A real Vector3 still comes back as one, so the check above did not just
--// switch the decode off.
local vectorTrip = Context.AICProfile.DeserializeConfigValue(
    Context.AICProfile.SerializeConfigValue({ Point = Vector3.new(1.5, 2.25, -3) })
)
assert(typeof(vectorTrip.Point) == "Vector3", "a saved Vector3 no longer decodes to a Vector3")
assert(vectorTrip.Point.X == 1.5 and vectorTrip.Point.Z == -3, "a saved Vector3 lost its numbers")

--// The exported config carries the hiding spots, so a profile handed to
--// someone else brings them along instead of leaving them on this device.
local compactExport = Context.AICProfile.BuildCompactConfig(Context.Runtime:GetBasePlaceConfig(), spotConfig)
assert(compactExport.BOSS_EVADE and compactExport.BOSS_EVADE.Spots, "the exported config does not carry the hiding spots")
assert(#compactExport.BOSS_EVADE.Spots == 2, "the exported config dropped a hiding spot")
assert(compactExport.BOSS_EVADE.Spots[2].Kind == "Prompt", "the exported config dropped the prompt spot")

--// Fight corners are part of the stop, so they have to ride the same export:
--// four saved vectors, through the compact diff and back through MergeConfig
--// and NormalizePlaceConfig, still four corners.
local boundsPlace = {
    BOSS_ROUTE = Context.AICConfig.NormalizeBossStops{
        {
            Label = "Bounds Stop",
            Position = Vector3.new(0, 0, 0),
            Bounds = {
                Vector3.new(-20, 0, -20),
                Vector3.new(20, 0, -20),
                Vector3.new(20, 0, 20),
                Vector3.new(-20, 0, 20),
            },
        },
    },
}
assert(#boundsPlace.BOSS_ROUTE[1].Bounds == 4, "the normalizer dropped the fight corners")

local boundsExport = Context.AICProfile.BuildCompactConfig(Context.Runtime:GetBasePlaceConfig(), boundsPlace)
assert(
    boundsExport.BOSS_ROUTE and boundsExport.BOSS_ROUTE[1] and boundsExport.BOSS_ROUTE[1].Bounds,
    "the exported config does not carry the fight corners"
)
assert(#boundsExport.BOSS_ROUTE[1].Bounds == 4, "the exported config dropped a fight corner")

local boundsReloaded = Context.AICConfig.NormalizePlaceConfig(
    Context.AICProfile.MergeConfig(Context.Runtime:GetBasePlaceConfig(), boundsExport)
)
assert(
    boundsReloaded.BOSS_ROUTE and boundsReloaded.BOSS_ROUTE[1]
        and boundsReloaded.BOSS_ROUTE[1].Bounds,
    "the fight corners were lost reloading the export"
)
assert(#boundsReloaded.BOSS_ROUTE[1].Bounds == 4, "the reloaded config dropped a fight corner")
assert(
    typeof(boundsReloaded.BOSS_ROUTE[1].Bounds[1]) == "Vector3",
    "a reloaded fight corner came back as a plain table"
)

--// The whole cycle a player runs: spots on the live config, the profile save,
--// the reload that reads it back through the place merge, and the export.
--// Asserted on the live config, not on a table built for the test, because a
--// prompt spot that only survives in a hand-made table is not saved at all.
local liveCycle = Context.Runtime:GetPlaceConfig()
assert(type(liveCycle.BOSS_EVADE) == "table" and type(liveCycle.BOSS_EVADE.Spots) == "table", "the live config has no hiding-spot list")
local beforePrompt = #liveCycle.BOSS_EVADE.Spots
table.insert(liveCycle.BOSS_EVADE.Spots, { Kind = "Prompt", Name = "Door", X = 10, Y = 2, Z = -3 })
assert(
    #liveCycle.BOSS_EVADE.Spots == beforePrompt + 1,
    "the prompt spot did not reach the live config: "
        .. beforePrompt .. " -> " .. #liveCycle.BOSS_EVADE.Spots
)

local savedProfile = Context.AICProfile.CaptureCurrentProfile("Cycle")
local storedPlace = Context.AICProfile.DeserializeConfigValue(savedProfile.PLACE_CONFIG)
local reloadedPlace = Context.AICConfig.NormalizePlaceConfig(
    Context.AICProfile.MergeConfig(Context.Runtime:GetBasePlaceConfig(), storedPlace)
)
assert(
    reloadedPlace.BOSS_EVADE and #reloadedPlace.BOSS_EVADE.Spots == beforePrompt + 1,
    "a hiding spot was lost reloading the profile: "
        .. tostring(reloadedPlace.BOSS_EVADE and reloadedPlace.BOSS_EVADE.Spots and #reloadedPlace.BOSS_EVADE.Spots)
)
assert(
    reloadedPlace.BOSS_EVADE.Spots[beforePrompt + 1].Kind == "Prompt",
    "the prompt spot was lost reloading the profile"
)

local cycleExport = Context.AICProfile.BuildCompactConfig(Context.Runtime:GetBasePlaceConfig(), reloadedPlace)
assert(
    cycleExport.BOSS_EVADE and #cycleExport.BOSS_EVADE.Spots == beforePrompt + 1,
    "the export from a reloaded config dropped a hiding spot: "
        .. tostring(cycleExport.BOSS_EVADE and cycleExport.BOSS_EVADE.Spots and #cycleExport.BOSS_EVADE.Spots)
)
assert(
    cycleExport.BOSS_EVADE.Spots[beforePrompt + 1].Kind == "Prompt",
    "the export from a reloaded config dropped the prompt spot"
)

--// The status line the Export Save button prints counts what actually went
--// into the text, so a profile with no spots cannot look exported with them.
local exportedTo = nil
setclipboard = function(value) exportedTo = value end
local exportOk, exportRaw, exportSpots = Context.AICProfile.ExportActiveProfile()
assert(exportOk, "exporting the profile failed: " .. tostring(exportRaw))
assert(exportSpots == beforePrompt + 1, "the export reported the wrong hiding-spot count: " .. tostring(exportSpots))
assert(exportedTo == exportRaw, "the export did not reach the clipboard")
setclipboard = nil

--// The prompt spot was put on the live list only for the cycle above; take it
--// back off so the edit tests below count the spots they added themselves.
table.remove(Context.Runtime:GetPlaceConfig().BOSS_EVADE.Spots, beforePrompt + 1)
assert(#CurrentSpots() == beforePrompt, "the cycle left its prompt spot on the live config")

--// The old single spot is still read, so a save from before the list keeps it.
local legacy = Context.AICConfig.NormalizeBossEvade{ Waypoint = 12, Prompt = true, PromptName = " Door " }
assert(legacy.Waypoint == 12 and legacy.Prompt == true and legacy.PromptName == "Door", "boss evade normalizer")
assert(Context.AICConfig.NormalizeBossEvade(nil).Waypoint == 0, "boss evade normalizer default")

--// A spot is removed from the list itself, waypoint or prompt: the X on the
--// row has to take it out of the saved list, not just off the screen.
local function FindRowWithText(Text)
    for _, Child in ipairs(boss.EvadeListComponent.Holder:GetChildren()) do
        if Child:IsA("Frame") then
            for _, Node in ipairs(Child:GetChildren()) do
                if Node:IsA("TextLabel") and Node.Text == Text then
                    return Child
                end
            end
        end
    end

    return nil
end

boss.EvadeWaypointBox:Set("4")
assert(#CurrentSpots() == 2, "the second hiding spot was not added")

local firstRow = FindRowWithText("#1  WAYPOINT  12")
assert(firstRow, "the first hiding spot has no row")

local removeButton

for _, Node in ipairs(firstRow:GetChildren()) do
    if Node:IsA("TextButton") and Node.Name == "Remove entry" then
        removeButton = Node
    end
end

assert(removeButton, "the hiding spot row has no X to remove it")
removeButton.MouseButton1Click:Fire()
assert(#CurrentSpots() == 1 and CurrentSpots()[1].Waypoint == 4, "the X did not remove the spot from the saved list")
assert(#boss.EvadeListComponent.Priority == 1, "the removed row stayed in the list")

--// Moving a spot reaches the saved list as well: the same read rebuilt the
--// list under the edit, so a move used to be lost the same way.
boss.EvadeWaypointBox:Set("7")
assert(#CurrentSpots() == 2 and CurrentSpots()[1].Waypoint == 4, "the next spot was not added under the kept one")
boss.EvadeListComponent:MoveDown("#1  WAYPOINT  4")
assert(CurrentSpots()[1].Waypoint == 7 and CurrentSpots()[2].Waypoint == 4, "moving a spot down did not reach the saved list")
boss.EvadeListComponent:MoveUp("#2  WAYPOINT  4")
assert(CurrentSpots()[1].Waypoint == 4 and CurrentSpots()[2].Waypoint == 7, "moving a spot up did not reach the saved list")
assert(#SmokeEnv.Errors == 0, "removing a hiding spot raised: " .. table.concat(SmokeEnv.Errors, "; "))

--// The hold only acts for a running route with the toggle on, and it lets go
--// the frame the stranger does. No character is needed for either: the hold
--// parks in RESPAWNING and still ends on its own.
local players = game:GetService("Players")
local realGetPlayers = players.GetPlayers
local intruder = { Name = "Intruder", UserId = 2, Parent = players }
local now = 0

Context.Feature.PauseForStrangers.Enabled = false
Context.Feature.BossRoute.Enabled = false
assert(Context.AICFeature.BossEvadeStep(now) == false, "hold ran with the route off")

--// A route with no stops is not a run: nothing may be reset for it.
Context.Feature.BossRoute.Enabled = true
players.GetPlayers = function() return { Context.Player, intruder } end
Context.Feature.PauseForStrangers.Enabled = true
assert(Context.AICFeature.BossEvadeStep(now) == false, "hold ran with no boss stops")
Context.Feature.PauseForStrangers.Enabled = false

--// One stop, so the hold has a run to pause and restart.
local stopPlace = Context.Runtime:GetPlaceConfig()
stopPlace.BOSS_ROUTE = Context.AICConfig.NormalizeBossStops{
    { Label = "Probe Stop", Position = Vector3.new(0, 0, 0) },
}
assert(Context.AICFeature.BossEvadeStep(now) == false, "hold ran with pause for strangers off")

Context.Feature.PauseForStrangers.Enabled = true
assert(Context.AICFeature.BossEvadeStep(now) == true, "hold did not take the frame for a stranger")
assert(boss.BossStatusLabel.Instance.Text:find("EVADING", 1, true), "hold did not report the stranger")
assert(#SmokeEnv.Errors == 0, "hold raised: " .. table.concat(SmokeEnv.Errors, "; "))

--// They left inside the window: the run starts again at the first boss, and
--// the report that says so names them and how long the hold waited. Webhook is
--// not started here, so the hook is captured instead of posted.
local leftReport

Context.AICFeature.ReportHoldCleared = function(Who, Seconds)
    leftReport = { Who = Who, Seconds = Seconds }
end

players.GetPlayers = function() return { Context.Player } end
assert(Context.AICFeature.BossEvadeStep(now) == true, "hold did not take the frame it ended on")
assert(leftReport, "the hold ended without reporting that they left")
assert(leftReport.Who[1] and leftReport.Who[1].Name == "Intruder", "the left report did not name who left")
assert(leftReport.Who[1].UserId == 2, "the left report lost the UserId")
assert(type(leftReport.Seconds) == "number" and leftReport.Seconds >= 0, "the left report has no wait on it")
assert(boss.BossStatusLabel.Instance.Text:find("STOP 1/1", 1, true), "hold did not restart at stop #1: " .. boss.BossStatusLabel.Instance.Text)
assert(Context.AICFeature.BossEvadeStep(now) == false, "hold kept the frame after ending")
assert(#SmokeEnv.Errors == 0, "hold release raised: " .. table.concat(SmokeEnv.Errors, "; "))

--// The roster the leave report names has to survive the frame they leave on.
--// The list is refreshed on a half-second tick, and that tick reads the empty
--// server a moment before the report is built: it used to overwrite the
--// names with that empty read, so the post said "A Player Left at" with no
--// one named. The tick only runs once time has moved, so this steps with the
--// clock past half a second.
local clearCalls, clearedName = 0, nil

Context.AICFeature.ReportHoldCleared = function(Who, Seconds)
    clearCalls += 1
    clearedName = Who[1] and Who[1].Name or nil
end

players.GetPlayers = function() return { Context.Player, intruder } end
assert(Context.AICFeature.BossEvadeStep(5) == true, "the hold did not start again for the roster test")
players.GetPlayers = function() return { Context.Player } end
assert(Context.AICFeature.BossEvadeStep(6) == true, "the hold did not take the frame it ended on")
assert(clearCalls == 1, "the hold reported the leave " .. tostring(clearCalls) .. " times")
assert(clearedName == "Intruder", "the roster tick erased the name of who left")
Context.AICFeature.BossEvadeStep(7)
assert(clearCalls == 1, "the same leave was reported again")
assert(#SmokeEnv.Errors == 0, "the roster test raised: " .. table.concat(SmokeEnv.Errors, "; "))

--// Switched off mid-hold: let go where it stands, never restarted from there.
players.GetPlayers = function() return { Context.Player, intruder } end
assert(Context.AICFeature.BossEvadeStep(now) == true, "hold did not start again for a stranger")
--// Through the control, so the toggle's own value moves with the flag.
boss.EvadePauseToggle:Set(true)
boss.EvadePauseToggle:Set(false)
assert(not boss.BossStatusLabel.Instance.Text:find("EVADING", 1, true), "switching the toggle off left the hold running")
assert(Context.AICFeature.BossEvadeStep(now) == false, "switching the toggle off left the frame to the hold")
assert(#SmokeEnv.Errors == 0, "hold cancel raised: " .. table.concat(SmokeEnv.Errors, "; "))

players.GetPlayers = realGetPlayers
Context.Feature.PauseForStrangers.Enabled = false
Context.Feature.BossRoute.Enabled = false

--// One report is one post. Several executors answer a webhook call with the
--// body as a plain string instead of a table, and the request loop used to
--// fall through to the next function for those, so one hold report arrived
--// three or four times over. The real Webhook module is started here so the
--// count is taken from the code that posts.
local Webhook
local WebhookOk, WebhookErr = xpcall(function()
    Webhook = WebhookModule.Start(Context)
end, debug.traceback)

assert(WebhookOk, "WEBHOOK START ERROR:\n" .. tostring(WebhookErr))

assert(type(Context.AICFeature.ReportHold) == "function", "the webhook did not register the hold report")
assert(type(Context.AICFeature.GetExpProgress) == "function", "the webhook did not register the EXP progress helper")

local posted = 0
request = function() posted += 1; return "{\"id\":\"1\"}" end
http_request = function() posted += 1; return "{\"id\":\"1\"}" end

Context.CONFIG.DISCORD_ENABLED = true
Context.CONFIG.DISCORD_WEBHOOK = "https://discord.com/api/webhooks/1/probe"
Context.CONFIG.DISCORD_HOLD_LOG = true

Context.AICFeature.ReportHold({ { Name = "Intruder", UserId = 2 } })
assert(posted == 1, "one waiting report was posted " .. tostring(posted) .. " times")

--// One hold is one left report. The same report asked for again is the same
--// event seen by another frame or another run, and a left report with nobody
--// to name is the "A Player Left at" header those copies used to arrive as.
Context.AICFeature.ReportHoldCleared({ { Name = "Intruder", UserId = 2 } }, 35)
assert(posted == 2, "the left report was not posted: " .. tostring(posted))
Context.AICFeature.ReportHoldCleared({ { Name = "Intruder", UserId = 2 } }, 35)
assert(posted == 2, "the same left report was posted twice")
Context.AICFeature.ReportHoldCleared({}, 35)
assert(posted == 2, "a left report with nobody to name was posted")

request = nil
http_request = nil

--// A level-up must report the whole EXP total and its hourly average. The
--// formatter used to re-group only the left side of a number, dropping the
--// last three digits from every seven-digit value.
local LevelStat = { Value = 1154 }
local ExpStat = { Value = 2836906 }
local PlayerStats = {
    FindFirstChild = function(_, name)
        if name == "Level" then return LevelStat end
        if name == "EXP" then return ExpStat end
    end,
}

Context.Player.FindFirstChild = function(_, name)
    if name == "PlayerStats" then return PlayerStats end
end

Webhook:ResetSession()
Webhook.GetElapsed = function() return 1 * 3600 + 49 * 60 + 8 end
LevelStat.Value, ExpStat.Value = 1155, 2342710
Context.CONFIG.DISCORD_FORMAT = "EXP Grind"

local Report = Webhook:BuildReport("End")
assert(Report:find("**Session EXP Gained:** 3,511,335", 1, true), "EXP total was formatted incorrectly:\n" .. Report)
assert(Report:find("**Average EXP / Hour:** 1,930,", 1, true), "EXP/hour was formatted incorrectly:\n" .. Report)
assert(not Report:find("EXP / Minute", 1, true), "per-minute rate is still shown")
assert(Report:find("Current EXP: 2,342,710/4,012,467", 1, true), "current EXP is not separated")
assert(Report:find("Starting EXP: 2,836,906/4,005,531", 1, true), "starting EXP is not separated")

--// A report must not create a baseline. If it did, sending at the end would
--// set the start to the current totals and report zero EXP gained.
Webhook.S.StartLevel, Webhook.S.StartExp = nil, nil
Webhook.S.LastExpLevel, Webhook.S.LastExp = nil, nil
local WithoutBaseline = Webhook:BuildReport("End")
assert(not WithoutBaseline:find("Session EXP Gained", 1, true), "a report captured a fresh zero baseline")

--// A start is one snapshot, not two independent reads. A partial read must
--// not pair an old level with a new EXP bar (or the reverse), which makes the
--// baseline higher than the current total and clamps the gain to zero.
local ShowLevel, ShowExp = true, true
PlayerStats.FindFirstChild = function(_, name)
    if name == "Level" and ShowLevel then return LevelStat end
    if name == "EXP" and ShowExp then return ExpStat end
end

ShowLevel, ShowExp = false, true
LevelStat.Value, ExpStat.Value = 1155, 2836906
Webhook:ResetSession()
assert(
    Webhook.S.StartLevel == nil and Webhook.S.StartExp == nil and Webhook.S.LastExpLevel == nil,
    "a partial PlayerStats read created a mixed start snapshot"
)

--// Stats arriving after the session starts are captured together on the next
--// update, before any gain is measured.
ShowLevel, ShowExp = true, true
LevelStat.Value, ExpStat.Value = 1154, 2836906
Context.Feature.AutoFarm.Enabled = false
Webhook:Update(0)
assert(Webhook.S.StartLevel == 1154 and Webhook.S.StartExp == 2836906, "late stats did not capture a start")
assert(Webhook.S.LastExpLevel == 1154 and Webhook.S.LastExp == 2836906, "late stats did not capture the EXP observation")

LevelStat.Value, ExpStat.Value = 1155, 2342710
local Gained = Context.AICFeature.GetExpProgress()
assert(Gained == 3511335, "late start did not measure the gain: " .. tostring(Gained))

--// Status labels use the report's totals, including when farming is off.
local StatusGained, StatusRate
Context.UIRef.ExpGainedLabel = { Set = function(_, text) StatusGained = text end }
Context.UIRef.ExpHourLabel = { Set = function(_, text) StatusRate = text end }
Webhook.S.LastLabelUpdate = -math.huge
Webhook:Update(0)
assert(StatusGained == "SESSION EXP GAINED  3,511,335", "status total did not refresh")
assert(StatusRate and StatusRate:find("AVG EXP / HOUR  1,930,", 1, true), "status rate disagrees with report")
Context.AICUI.UpdateExpRates()
assert(Webhook.S.SessionExpGained == 3511335, "repainting status counted the gain twice")

-- EXP can reset one replication tick before Level advances. This exact
-- sequence used to report 10,028,177 instead of the endpoint gain 4,558,220.
LevelStat.Value, ExpStat.Value = 1357, 2346164
Webhook:ResetSession()
Webhook.GetElapsed = function() return 3963 end
LevelStat.Value, ExpStat.Value = 1357, 5469957
Webhook:ObserveExp()
ExpStat.Value = 0
Webhook:ObserveExp()
LevelStat.Value = 1358
Webhook:ObserveExp()
ExpStat.Value = 1367827
local FixedGain, FixedRate = Context.AICFeature.GetExpProgress()
assert(FixedGain == 4558220, "split level-up counted EXP twice: " .. tostring(FixedGain))
assert(math.floor(FixedRate) == 4140699, "hourly average doesn't use corrected total and seconds")
local FixedReport = Webhook:BuildReport("End")
assert(FixedReport:find("**Session EXP Gained:** 4,558,220", 1, true), "report didn't use corrected gain")
assert(FixedReport:find("**Average EXP / Hour:** 4,140,699", 1, true), "report didn't use corrected average")
Context.AICUI.UpdateExpRates()
assert(StatusGained == "SESSION EXP GAINED  4,558,220", "status panel didn't use corrected total")
assert(StatusRate == "AVG EXP / HOUR  4,140,699", "status panel didn't use corrected average")

-- The reverse replication order must converge to the same endpoint too.
LevelStat.Value, ExpStat.Value = 1357, 2346164
Webhook:ResetSession()
ExpStat.Value = 5469957; Webhook:ObserveExp()
LevelStat.Value = 1358; Webhook:ObserveExp()
ExpStat.Value = 0; Webhook:ObserveExp()
ExpStat.Value = 1367827
assert(Context.AICFeature.GetExpProgress() == 4558220, "level-first replication counted EXP twice")

-- A temporary reset below the starting bar must not count its recovery as
-- profit. Repeated reports/status reads must not change the total either.
LevelStat.Value, ExpStat.Value = 1358, 1367827
Webhook:ResetSession()
ExpStat.Value = 0
assert(Context.AICFeature.GetExpProgress() == 0, "negative session progress wasn't hidden")
ExpStat.Value = 1367927
assert(Context.AICFeature.GetExpProgress() == 100, "recovery of the starting bar was counted as earned EXP")
assert(Context.AICFeature.GetExpProgress() == 100, "re-reading status duplicated EXP")

-- Skip several levels and cross backwards again; only endpoint progress is
-- earned. A missing curve must leave the transition pending for a retry.
LevelStat.Value, ExpStat.Value = 1357, 2346164
Webhook:ResetSession()
local Needed = Context.AICUI.neededExp
Context.AICUI.neededExp = function(level)
    if level == 1358 then return nil end
    return Needed(level)
end
LevelStat.Value, ExpStat.Value = 1359, 50
assert(Webhook:ObserveExp() == false, "missing curve committed a partial level transition")
assert(Webhook.S.LastExpLevel == 1357 and Webhook.S.LastExp == 2346164, "missing curve discarded the previous snapshot")
Context.AICUI.neededExp = Needed
assert(Context.AICFeature.GetExpProgress() == Needed(1357) + Needed(1358) - 2346164 + 50, "multi-level gain is wrong")
LevelStat.Value, ExpStat.Value = 1358, 1367827
assert(Context.AICFeature.GetExpProgress() == 4558220, "backwards correction inflated the session")
print("EXP regression passed: both replication orders, recovery, multi-level correction, report/status agreement")
do
    -- Exercise the real approach/fight/reset code: a spawn is not a release
    -- signal until a living duo has returned from this cycle's reset.
    local nav = Context.AICFeature.BossNav
    local state = nav.S
    local function pos(x)
        return setmetatable({X=x or 0,Y=0,Z=0}, {
            __typename="Vector3",
            __sub=function(a,b) return {X=a.X-b.X,Y=0,Z=0,Magnitude=math.abs(a.X-b.X)} end,
        })
    end
    local character=Instance.new("Model",workspace)
    local root=Instance.new("Part",character); root.Name="HumanoidRootPart"; root.Position=pos(0)
    local hum=Instance.new("Humanoid",character); hum.Health=100; hum.MaxHealth=100
    rawset(hum,"Move",noop); rawset(hum,"MoveTo",noop)
    Context.Runtime.GetCharacter=function() return character,hum,root end
    Context.Runtime.GetInputBindableFunction=function() return nil end
    Context.Services.Replicated.FindFirstChild=function() return nil end
    Context.AICFeature.EnsureWeaponDrawn=function() return false end
    Context.AICFeature.TryHeal=function() return false end
    Context.AICCombatUtils.GetHorizontalDistance=function(a,b) return math.abs(a.X-b.X) end
    Context.AICCombatUtils.IsStandingOnTarget=function() return false end
    Context.AICCombat.GetCombatDistance=function() return 0 end
    Context.AICCombat.GetNearestThreat=function() return nil end
    Context.AICCombat.FaceCombatTarget=noop
    local attacks=0
    Context.AICCombat.AttackTarget=function() attacks+=1 end
    local duo={Name="DuoWaitTest",DisplayName="Duo Wait Test"}
    local function respawnDuo(x)
        local model=Instance.new("Model",workspace)
        local r=Instance.new("Part",model); r.Name="HumanoidRootPart"; r.Position=pos(x)
        local h=Instance.new("Humanoid",model); h.Health=100
        duo.Character=model
        return model,r,h
    end
    local duoCharacter,duoRoot,duoHum=respawnDuo(200)
    players.GetPlayers=function() return {Context.Player,duo} end
    local mobs=Instance.new("Folder",workspace); mobs.Name="Mobs"
    local mob=Instance.new("Model"); mob.Name="WaitTestBoss"
    local mobRoot=Instance.new("Part",mob); mobRoot.Name="HumanoidRootPart"; mobRoot.Position=pos(0)
    local mobHum=Instance.new("Humanoid",mob); mobHum.Health=100
    rawset(mob,"IsDescendantOf",function() return mob.Parent==mobs end)
    local stop={Label="Wait test",Position=pos(0),Radius=100,Targets={"WaitTestBoss"},Path={},
        Wait=0,ResetWait=0,ResetAfterKill=true,Dodge=false,Waypoint=0}
    local place=Context.Runtime:GetPlaceConfig()
    place.BOSS_ROUTE={stop}
    Context.CONFIG.BOSS_WAIT_FOR_SPAWN=true
    Context.CONFIG.BOSS_DUO_SYNC=true
    Context.CONFIG.BOSS_DUO_NAME=duo.Name
    Context.CONFIG.BOSS_DUO_RANGE=35
    Context.CONFIG.BOSS_DEATH_FARM=true
    assert(boss.BossWaitForSpawnToggle, "dynamic spawn wait toggle missing")
    nav.StopRoute(); state.Index=1; nav.BeginStop(100)
    assert(nav.ApproachStep(stop,100)==true and state.Phase=="Approach", "missing duo didn't hold approach")
    assert(boss.BossStatusLabel.Instance.Text:find("WAITING FOR DUO",1,true), "duo didn't take status priority")
    duoRoot.Position=pos(0)
    nav.ApproachStep(stop,101)
    assert(state.Phase=="Approach" and boss.BossStatusLabel.Instance.Text:find("WAITING FOR BOSS",1,true), "ready duo didn't wait for spawn")
    for t=102,260 do nav.ApproachStep(stop,t) end
    assert(state.Phase=="Approach" and state.Index==1, "long spawn wait expired as an unreachable stop")
    mob.Parent=mobs
    duoRoot.Position=pos(200)
    nav.ApproachStep(stop,261)
    assert(state.Phase=="Approach" and attacks==0, "boss spawn released a missing duo")
    duoRoot.Position=pos(0)
    nav.ApproachStep(stop,262)
    assert(state.Phase=="Fight", "living boss + duo didn't release a zero-wait stop")
    nav.FightStep(stop,263)
    assert(attacks==1, "ready duo couldn't attack")
    duoHum.Health=0
    assert(nav.FightStep(stop,264)==true and attacks==1, "duo dying didn't stop attacks")
    duoHum.Health=100; duoRoot.Position=pos(200)
    nav.FightStep(stop,265)
    assert(attacks==1, "duo leaving didn't stop attacks")
    duoRoot.Position=pos(0); nav.FightStep(stop,266)
    assert(attacks==2, "duo returning didn't resume the fight")
    -- The old character was recorded during combat, before any slow EXP wait.
    assert(state.FightDuoCharacter==duoCharacter, "duo cycle wasn't recorded")
    mobHum.Health=0
    LevelStat.Value,ExpStat.Value=1358,0
    nav.FightStep(stop,267)
    assert(state.Phase=="Recover" and hum.Health==0, "dynamic spawn wait blocked the post-kill reset")
    assert(state.AwaitDuoCharacter==duoCharacter, "reset didn't require a new duo character")
    hum.Health=100
    nav.BeginStop(268)
    mobHum.Health=100
    nav.ApproachStep(stop,269)
    assert(state.Phase=="Approach" and attacks==2, "nearby duo still waiting to reset released next boss")
    assert(boss.BossStatusLabel.Instance.Text:find("WAITING FOR DUO",1,true), "resetting duo lost status priority")
    respawnDuo(200); nav.ApproachStep(stop,270)
    assert(state.Phase=="Approach", "duo respawned far away but counted as ready")
    duoCharacter,duoRoot,duoHum=respawnDuo(0)
    nav.ApproachStep(stop,271); nav.FightStep(stop,272)
    assert(state.Phase=="Fight" and attacks==3, "returned duo didn't release next boss")
    -- Fast partner can already have reset by the time our own slow reset ends.
    local foughtCharacter=duoCharacter
    respawnDuo(0)
    mobHum.Health=0; nav.FightStep(stop,273)
    assert(state.AwaitDuoCharacter==foughtCharacter, "slow reset captured the partner's new character and would deadlock")
    hum.Health=100; nav.BeginStop(274); mobHum.Health=100
    nav.ApproachStep(stop,275)
    assert(state.Phase=="Fight", "already respawned/returned duo was asked to reset again")
    -- In-flight fight with no first target also waits beyond normal timeouts
    -- and does not mistake an earlier corpse for this visit's kill.
    nav.StopRoute(); nav.BeginStop(276)
    state.Phase="Fight"; state.FightStart=276; mobHum.Health=0
    nav.FightStep(stop,500)
    assert(state.Phase=="Fight" and not state.SeenTarget and hum.Health==100, "old corpse or no-target timeout escaped dynamic wait")
    Context.CONFIG.BOSS_DUO_SYNC=false
    mobHum.Health=100; nav.FightStep(stop,501)
    assert(attacks==4, "solo dynamic wait couldn't attack spawned boss")
    nav.StopRoute()
    assert(state.AwaitDuoCharacter==nil and state.FightDuoCharacter==nil, "stopping route retained stale duo readiness")
    Context.CONFIG.BOSS_DUO_SYNC=true
    duoRoot=duo.Character:FindFirstChild("HumanoidRootPart"); duoRoot.Position=pos(200)
    assert(boss.BossDuoTimeoutBox and boss.BossDuoTimeoutBox:Get()=="0", "duo timeout textbox missing or doesn't default to unlimited")
    boss.BossDuoTimeoutBox:Set("5")
    assert(Context.CONFIG.BOSS_DUO_WAIT_TIMEOUT==5, "duo timeout wasn't saved")
    boss.BossDuoTimeoutBox:Set("invalid")
    assert(Context.CONFIG.BOSS_DUO_WAIT_TIMEOUT==5 and boss.BossDuoTimeoutBox:Get()=="5", "invalid timeout corrupted config")
    nav.BeginStop(600)
    nav.ApproachStep(stop,600); nav.ApproachStep(stop,604)
    assert(state.Phase=="Approach" and attacks==4, "duo wait expired early")
    nav.ApproachStep(stop,605); nav.FightStep(stop,606); nav.FightStep(stop,607)
    assert(state.Phase=="Fight" and state.Index==1 and attacks==6, "duo timeout skipped stop or failed to keep attacking")
    nav.BeginStop(608); nav.ApproachStep(stop,608)
    assert(state.Phase=="Approach", "duo timeout release leaked into next visit")
    mob.Parent=nil; nav.BeginStop(610)
    nav.ApproachStep(stop,610); nav.ApproachStep(stop,615)
    assert(state.Phase=="Approach" and state.Index==1 and attacks==6, "duo timeout bypassed missing boss or advanced stop")
    assert(boss.BossStatusLabel.Instance.Text:find("WAITING FOR BOSS",1,true), "expired duo wait didn't become a spawn wait")
    mob.Parent=mobs; nav.ApproachStep(stop,620); nav.FightStep(stop,621)
    assert(state.Phase=="Fight" and state.Index==1 and attacks==7, "boss spawning after duo timeout didn't release current stop")
    nav.StopRoute(); boss.BossDuoTimeoutBox:Set("0"); nav.BeginStop(700)
    for t=700,900 do nav.ApproachStep(stop,t) end
    assert(state.Phase=="Approach" and state.Index==1 and attacks==7, "zero timeout didn't wait indefinitely at the current boss")
    -- The configurable release works with legacy fixed waits as well.
    nav.StopRoute(); Context.CONFIG.BOSS_WAIT_FOR_SPAWN=false; stop.Wait=0
    boss.BossDuoTimeoutBox:Set("2"); nav.BeginStop(910)
    nav.ApproachStep(stop,910); nav.ApproachStep(stop,912); nav.FightStep(stop,913)
    assert(state.Phase=="Fight" and state.Index==1 and attacks==8, "legacy duo timeout advanced instead of attacking")
    nav.StopRoute()
    -- A new boss during the slow account's EXP hold cannot cancel its owed
    -- reset or replace the duo identity captured before the previous kill.
    Context.CONFIG.BOSS_WAIT_FOR_SPAWN=true
    boss.BossDuoTimeoutBox:Set("0"); stop.ResetWait=5
    ExpStat.Value=Context.AICUI.neededExp(LevelStat.Value)
    duoCharacter,duoRoot,duoHum=respawnDuo(0)
    nav.BeginStop(930); nav.ApproachStep(stop,930); nav.FightStep(stop,931)
    local attacksBeforeHold=attacks
    mobHum.Health=0; nav.FightStep(stop,932)
    assert(state.Phase=="Fight" and hum.Health==100 and state.KillAt, "EXP-protecting reset hold was lost")
    local previousDuo=duoCharacter
    respawnDuo(0); mobRoot.Position=pos(90); mobHum.Health=100; nav.FightStep(stop,933)
    assert(attacks==attacksBeforeHold and hum.Health==100, "new spawn interrupted EXP hold")
    nav.FightStep(stop,937)
    assert(state.Phase=="Recover" and hum.Health==0 and state.AwaitDuoCharacter==previousDuo, "slow reset lost the prior duo cycle")
    nav.StopRoute()
    -- Verify the complete requested loop through the real teleport, recovery
    -- and stop-advance paths, including wrapping from stop #2 back to #1.
    local second=table.clone(stop)
    stop.Position,stop.Waypoint,stop.ResetWait=pos(0),1,0
    second.Position,second.Waypoint,second.ResetWait=pos(1000),2,0
    place.BOSS_ROUTE={stop,second}
    Context.CONFIG.BOSS_ROUTE_LOOP=true
    ExpStat.Value=0
    RaycastParams={new=function() return {} end}
    rawset(workspace,"Raycast",function() return nil end)
    local teleports={}
    Context.Services.Replicated.FindFirstChild=function(_,name)
        if name=="TeleportEvent" then return {FireServer=function(_,waypoint)
            teleports[#teleports+1]=waypoint
            root.Position=pos(waypoint==1 and 0 or 1000)
        end} end
    end
    local function respawnSelf()
        character:Destroy()
        character=Instance.new("Model",workspace)
        root=Instance.new("Part",character); root.Name="HumanoidRootPart"
        root.Position,root.Size=pos(-500),Vector3.new(2,2,1)
        hum=Instance.new("Humanoid",character); hum.Health,hum.MaxHealth=100,100
        rawset(hum,"Move",noop); rawset(hum,"MoveTo",noop)
    end
    respawnSelf(); respawnDuo(-1000); state.Index=1; nav.BeginStop(1000)
    local attacksAtLoopStart=attacks
    for cycle=1,3 do
        local t=1000+(cycle-1)*20
        local index=cycle==2 and 2 or 1
        local current=place.BOSS_ROUTE[index]
        mob.Parent=nil
        nav.ApproachStep(current,t+2)
        nav.ApproachStep(current,t+3)
        nav.ApproachStep(current,t+4)
        assert(teleports[cycle]==index and state.Index==index, "cycle teleported to the wrong stop")
        assert(state.Phase=="Approach" and boss.BossStatusLabel.Instance.Text:find("WAITING FOR DUO",1,true), "cycle didn't wait for duo after travel")
        duoCharacter,duoRoot,duoHum=respawnDuo(current.Position.X)
        nav.ApproachStep(current,t+5)
        assert(state.Phase=="Approach" and boss.BossStatusLabel.Instance.Text:find("WAITING FOR BOSS",1,true), "cycle didn't wait for boss after duo arrived")
        mob.Parent=mobs; mobRoot.Position=current.Position; mobHum.Health=100
        nav.ApproachStep(current,t+6); nav.FightStep(current,t+7)
        assert(attacks==attacksAtLoopStart+cycle, "cycle didn't attack once both gates were ready")
        mobHum.Health=0; nav.FightStep(current,t+8)
        assert(state.Phase=="Recover" and hum.Health==0, "cycle didn't reset after the kill")
        respawnSelf(); nav.RecoverStep(t+9)
        assert(state.Phase=="Approach" and state.Index==(index==1 and 2 or 1), "post-kill recovery didn't advance/loop to the next stop")
    end
    nav.StopRoute()
    print("BOSS CYCLE passed: kill -> reset -> teleport next -> duo -> spawn -> repeat (1, 2, 1)")
    -- Live evasion must remain bounded when the dodge ends and combat closes
    -- in again, steps off a body, or recovers from knockback.
    local originalVectorNew,originalXAxis=Vector3.new,Vector3.xAxis
    local vmt={__typename="Vector3"}
    Vector3.new=function(x,y,z) return setmetatable({X=x or 0,Y=y or 0,Z=z or 0},vmt) end
    vmt.__index=function(v,key)
        if key=="Magnitude" then return math.sqrt(v.X*v.X+v.Y*v.Y+v.Z*v.Z) end
        if key=="Unit" then return Vector3.new(v.X/v.Magnitude,v.Y/v.Magnitude,v.Z/v.Magnitude) end
    end
    vmt.__add=function(a,b) return Vector3.new(a.X+b.X,a.Y+b.Y,a.Z+b.Z) end
    vmt.__sub=function(a,b) return Vector3.new(a.X-b.X,a.Y-b.Y,a.Z-b.Z) end
    vmt.__mul=function(a,b) return Vector3.new(a.X*b,a.Y*b,a.Z*b) end
    Vector3.xAxis=Vector3.new(1,0,0)
    local vec=Vector3.new
    local bounds={vec(-20,0,-20),vec(20,0,-20),vec(20,0,20),vec(-20,0,20)}
    stop.Position,stop.Waypoint,stop.Bounds,stop.Radius,stop.Dodge=vec(0,0,0),0,bounds,1000,false
    place.BOSS_ROUTE={stop}
    Context.CONFIG.BOSS_DUO_SYNC=false
    root.Position,mobRoot.Position,hum.Health,mobHum.Health=vec(18,0,0),vec(100,0,0),100,100
    local moves={}
    rawset(hum,"MoveTo",function(_,point) moves[#moves+1]=point end)
    Context.AICCombatUtils.GetHorizontalDistance=function(a,b) return math.sqrt((a.X-b.X)^2+(a.Z-b.Z)^2) end
    Context.AICCombatUtils.DoJumpIfObstacle=noop
    Context.AICCombatUtils.IsPressedAgainstBody=function() return false end
    Context.AICCombatUtils.IsHoleAhead=function() return false end
    Context.AICCombatUtils.IsPathClear=function() return true end
    Context.AICCombat.GetCombatDistance=function(_,offset) return offset.Magnitude end
    local function bounded(point)
        assert(point and math.abs(point.X)<=18 and math.abs(point.Z)<=18,"live combat navigated outside the inset fight bounds")
    end
    state.Index=1; nav.BeginStop(1200); nav.FightStep(stop,1201)
    bounded(moves[#moves]) -- boss outside the wall: don't follow it out
    Context.AICCombatUtils.IsStandingOnTarget=function() return true end
    Context.AICCombatUtils.GetStepOffPosition=function() return vec(100,0,100) end
    nav.FightStep(stop,1202); bounded(moves[#moves])
    stop.Bounds=nil; nav.FightStep(stop,1203)
    assert(moves[#moves].X==100 and moves[#moves].Z==100,"no-bounds movement was restricted")
    stop.Bounds={bounds[1],bounds[2],bounds[3]}; nav.FightStep(stop,1204)
    assert(moves[#moves].X==100,"incomplete fight bounds restricted movement")
    stop.Bounds=bounds
    root.Position=vec(25,0,-30)
    local beforeCorrection=attacks
    nav.FightStep(stop,1205); bounded(moves[#moves])
    assert(attacks==beforeCorrection and moves[#moves].X==18 and moves[#moves].Z==-18,"knockback wasn't corrected before attacking")
    Context.AICCombatUtils.IsStandingOnTarget=function() return false end
    root.Position,mobRoot.Position=vec(16,0,0),vec(18,0,0)
    stop.Dodge=true
    state.DodgeMaxUntil,state.DodgeMinUntil,state.SkillSeenAt=1218,1212,1210
    state.DodgeTarget=vec(100,0,100) -- target cached before bounds were set
    for t=1210,1211,.25 do
        nav.FightStep(stop,t)
        bounded(moves[#moves])
    end
    mobRoot.Position=vec(100,0,0)
    nav.FightStep(stop,1220); bounded(moves[#moves]) -- dodge expired: chase still bounded
    Context.CONFIG.BOSS_DUO_SYNC=true
    respawnDuo(200); root.Position=vec(25,0,25)
    beforeCorrection=attacks
    nav.FightStep(stop,1221); bounded(moves[#moves])
    assert(attacks==beforeCorrection and boss.BossStatusLabel.Instance.Text:find("WAITING FOR DUO",1,true),"duo wait allowed combat or lost its priority while returning inside")
    -- The emergency health retreat runs before BossStep. Its dedicated hook
    -- must own movement (including a stationary heal) so Auto Farm never falls
    -- through to an unbounded retreat or a return-to-farm-zone destination.
    Context.Feature.BossRoute.Enabled=true
    Context.CONFIG.BOSS_DUO_SYNC=false
    state.Phase="Fight"
    root.Position,mobRoot.Position,hum.Health=vec(16,0,0),vec(18,0,0),25
    assert(Context.AICFeature.BossRetreatStep(1222)==true,"low-HP retreat wasn't handled by boss bounds")
    bounded(moves[#moves])
    root.Position=vec(25,0,25)
    assert(Context.AICFeature.BossRetreatStep(1223)==true,"low-HP knockback recovery wasn't handled")
    bounded(moves[#moves])
    assert(moves[#moves].X==18 and moves[#moves].Z==18,"healing retreat didn't return to the box")
    root.Position,mobRoot.Position=vec(0,0,0),vec(100,0,0)
    local movesBeforeHeal=#moves
    assert(Context.AICFeature.BossRetreatStep(1224)==true and #moves==movesBeforeHeal,"stationary healing released the farm-zone fallback")
    state.Phase,state.SpotWaitUntil="Approach",1230
    assert(Context.AICFeature.BossRetreatStep(1225)==true and state.LastProgressAt==1225,"healing during spot wait could time out the stop")
    state.SpotWaitUntil,state.DuoWaitStartedAt=nil,nil
    assert(Context.AICFeature.BossRetreatStep(1226)==nil,"boss bounds constrained travel before reaching the stop")
    state.Phase="Fight"; stop.Bounds=nil
    assert(Context.AICFeature.BossRetreatStep(1227)==nil,"unbounded boss stop lost normal retreat")
    stop.Bounds=bounds; Context.Feature.BossRoute.Enabled=false
    assert(Context.AICFeature.BossRetreatStep(1228)==nil,"disabled boss route restricted normal farming")
    hum.Health=100
    nav.StopRoute()
    Vector3.new,Vector3.xAxis=originalVectorNew,originalXAxis
    print("BOSS BOUNDS passed: live dodge/chase, low-HP healing retreat, knockback, wait, and unbounded fallback")
    -- Spawn readiness is an additional condition, never a replacement for the
    -- configured spot wait. Duo readiness starts that timer, as before.
    Context.CONFIG.BOSS_DUO_SYNC=false
    stop.Bounds,stop.Dodge,stop.Wait,stop.Position=nil,false,5,pos(0)
    root.Position,mobRoot.Position=pos(0),pos(0)
    mobHum.Health=100
    nav.BeginStop(1300); nav.ApproachStep(stop,1300)
    assert(state.Phase=="Approach" and state.SpotWaitUntil==1305,"spawn mode skipped Wait At Spot")
    nav.ApproachStep(stop,1304)
    assert(state.Phase=="Approach","spawned boss bypassed the remaining spot wait")
    nav.ApproachStep(stop,1305)
    assert(state.Phase=="Fight","elapsed spot timer plus living boss didn't release")
    nav.StopRoute(); mob.Parent=nil; nav.BeginStop(1310)
    nav.ApproachStep(stop,1310); nav.ApproachStep(stop,1315)
    assert(state.Phase=="Approach","elapsed spot timer bypassed missing boss")
    mob.Parent=mobs; nav.ApproachStep(stop,1316)
    assert(state.Phase=="Fight","late boss spawn restarted an already elapsed spot timer")
    nav.StopRoute(); Context.CONFIG.BOSS_DUO_SYNC=true; respawnDuo(200)
    nav.BeginStop(1320); nav.ApproachStep(stop,1320)
    assert(state.SpotWaitUntil==nil,"spot timer started while waiting for duo")
    respawnDuo(0); nav.ApproachStep(stop,1322)
    assert(state.Phase=="Approach" and state.SpotWaitUntil==1327,"duo arrival didn't start full spot wait")
    nav.ApproachStep(stop,1326)
    assert(state.Phase=="Approach","boss/duo readiness skipped spot timer")
    nav.ApproachStep(stop,1327)
    assert(state.Phase=="Fight","all three readiness conditions didn't release")
    nav.StopRoute()
    print("BOSS SPOT WAIT passed: boss spawn and duo readiness never bypass the configured spot timer")
    mobs:Destroy(); character:Destroy()
    players.GetPlayers=realGetPlayers
    print("BOSS WAIT regression passed: spawn/duo priority, reset cycles, indefinite waits, timeout attacks current stop")
end
print("BOOT PROBE PASSED")
