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

--// BossNavigator: the player controls on the Bosses tab live in sections of
--// their own - the pause-for-strangers hold, its waypoint, its prompt, then
--// Auto Block and the whitelist - and each must open with its own title.
--// Starting the module is what proves those controls construct at boot
--// instead of only compiling.
local BossNavOk, BossNavErr = xpcall(BossNavigatorModule.Start, debug.traceback, Context)

if not BossNavOk then
    error("BOSSNAVIGATOR START ERROR:\n" .. tostring(BossNavErr))
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
assert(SectionTitle(boss.BlockSection) == "Auto Block", "the auto block title is not at the top of its section")
assert(SectionTitle(boss.WhitelistSection) == "Block Whitelist", "the whitelist title is not at the top of its section")
assert(boss.BlockSection.Frame.LayoutOrder > boss.EvadeSection.Frame.LayoutOrder, "auto block was not placed under the evade sections")
assert(boss.WhitelistSection.Frame.LayoutOrder > boss.BlockSection.Frame.LayoutOrder, "the whitelist was not placed under auto block")
assert(boss.EvadePauseToggle, "pause for strangers toggle missing")
assert(boss.EvadeListComponent, "hiding-spot list missing")
assert(boss.EvadeWaypointBox and boss.EvadePromptButton, "hiding-spot controls missing")
assert(boss.EvadeSpotLabel, "hiding-spot count label missing")
assert(boss.EvadeSpotLabel.Instance.Text:find("HIDING SPOTS:", 1, true), "hiding-spot label text missing")
assert(boss.EvadePauseToggle:Get() == false, "pause for strangers started on")
assert(boss.EvadePauseToggle.Row.Parent == boss.EvadeSection.Frame, "the hold's toggle was not placed in its own section")
assert(boss.EvadeWaypointBox.Row.Parent == boss.EvadeAddSection.Frame, "the add-waypoint box was not placed in its own section")
assert(boss.EvadePromptButton.Row.Parent == boss.EvadeAddSection.Frame, "the add-prompt button was not placed in its own section")
--// Auto Block's own module is not started here, so only the section it fills
--// can be checked: it exists, it is titled, and it sits under Auto Block.
assert(boss.WhitelistSection.Frame.LayoutOrder == boss.BlockSection.Frame.LayoutOrder + 1, "the whitelist section is not directly under auto block")

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
    if Node:IsA("TextButton") and Node.Text == "X" then
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
local WebhookOk, WebhookErr = xpcall(function()
    WebhookModule.Start(Context)
end, debug.traceback)

assert(WebhookOk, "WEBHOOK START ERROR:\n" .. tostring(WebhookErr))

assert(type(Context.AICFeature.ReportHold) == "function", "the webhook did not register the hold report")

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

print("BOOT PROBE PASSED")
