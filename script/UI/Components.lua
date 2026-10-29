return {
    Name = "Components",
    Dependencies = {"Runtime", "SaveConfig"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local AICConfig = Context.AICConfig
        local AICProfile = Context.AICProfile
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local UI = Context.UI
        local FeatureState = Context.Feature
        local Module = Context.AICUI
        function AICUI.CreateFeature(Name, Default, Callback)
            local Component = UIRef.FeatureSection:AddToggle{ Name = Name, Default = Default, Callback = Callback }
        
            return Component
        end
        function AICUI.SetFeatureComponent(Name, Value)
            local Data = FeatureState[Name]

            --// Some entries park a plain TextButton here (Reset Stats), which
            --// has no state to set. Indexing .Set on an Instance would throw.
            if Data
                and type(Data.Button) == "table"
                and type(Data.Button.Set) == "function"
            then
                Data.Button:Set(Value, true)
            end
        end

        --// A feature toggle bound to a SaveConfig.Features entry: it shows the
        --// saved value, writes Feature[Name].Enabled, saves the profile, and
        --// is refreshed by updateFeatureButtons on every profile load. A
        --// module only supplies its label and what else should happen.
        --// A Global toggle is saved to the global file instead.
        function AICUI.BindFeatureToggle(Name, Label, OnChanged, Section)
            local State = FeatureState[Name]
            assert(State, "Feature not declared in SaveConfig.Features: " .. tostring(Name))

            local IsGlobal = Context.SaveConfig.GetFeature(Name).Global == true

            Section = Section or UIRef.FeatureSection
            if not Section then
                return nil
            end

            State.Button = Section:AddToggle{ Name = Label, Default = State.Enabled, Callback = function(Value)
                State.Enabled = Value == true

                if OnChanged then
                    OnChanged(State.Enabled)
                end

                if IsGlobal then
                    AICProfile.WriteGlobalStore()
                else
                    --// Queued, not immediate: SaveActiveProfile captures the
                    --// whole profile and writes the file, and a toggle should
                    --// not hitch the frame it was clicked on.
                    AICProfile.QueueProfileSave()
                end
            end }

            return State.Button
        end

        --// UserId -> Roblox username: a string once known, false while the
        --// lookup runs or after it failed (not asked again this session).
        AICUI.S.UserNames = {}
        --// UserId -> callbacks waiting on its lookup.
        AICUI.S.UserNameWaiters = {}
        --// UserId -> true once its lookup came back with nothing, so a row
        --// can say so instead of waiting for a name that is not coming.
        AICUI.S.UserNameFailed = {}

        --// An imported whitelist asks for every name in it at once. Roblox
        --// rate limits GetNameFromUserIdAsync, and a burst of refusals is what
        --// buried the executor in errors, so four run at a time and the rest
        --// wait their turn.
        AICUI.S.UserNameQueue = {}
        AICUI.S.UserNameInFlight = 0

        local USER_NAME_LOOKUPS = 4
        local UserNamePumping = false

        local function LookUpUserName(Id)
            local Ok, Name = pcall(Players.GetNameFromUserIdAsync, Players, Id)
            local Callbacks = AICUI.S.UserNameWaiters[Id] or {}

            AICUI.S.UserNameWaiters[Id] = nil

            if Ok and type(Name) == "string" then
                AICUI.S.UserNames[Id] = Name

                for _, Callback in ipairs(Callbacks) do
                    Callback(Name)
                end
            else
                --// A UserId Roblox will not answer for (deleted, or the
                --// request was refused): the row says so and stops asking.
                AICUI.S.UserNameFailed[Id] = true

                for _, Callback in ipairs(Callbacks) do
                    Callback(nil)
                end
            end
        end

        local function PumpUserNames()
            --// Not re-entrant: a lookup that finishes inside the loop below
            --// must not start a second loop of its own.
            if UserNamePumping then
                return
            end

            UserNamePumping = true

            while AICUI.S.UserNameInFlight < USER_NAME_LOOKUPS do
                local Id = table.remove(AICUI.S.UserNameQueue, 1)

                if not Id then
                    break
                end

                AICUI.S.UserNameInFlight += 1

                task.spawn(function()
                    LookUpUserName(Id)

                    AICUI.S.UserNameInFlight = math.max(AICUI.S.UserNameInFlight - 1, 0)
                    PumpUserNames()
                end)
            end

            UserNamePumping = false
        end

        --// The username of UserId, or nil when not known yet. Someone in the
        --// server is answered at once; anyone else is looked up in the
        --// background and OnFound(Name) runs when it arrives. The second
        --// value says why there is no name yet: "pending" or "failed".
        function AICUI.GetUserName(UserId, OnFound)
            local Id = tonumber(UserId)

            if not Id then
                return nil, "failed"
            end

            if AICUI.S.UserNameFailed[Id] then
                return nil, "failed"
            end

            local Cached = AICUI.S.UserNames[Id]

            if Cached then
                return Cached
            end

            local InServer = Players:GetPlayerByUserId(Id)

            if InServer then
                AICUI.S.UserNames[Id] = InServer.Name
                return InServer.Name
            end

            local Waiters = AICUI.S.UserNameWaiters[Id]

            if Waiters and OnFound and not table.find(Waiters, OnFound) then
                table.insert(Waiters, OnFound)
            end

            if Cached == nil then
                AICUI.S.UserNames[Id] = false
                AICUI.S.UserNameWaiters[Id] = { OnFound }

                table.insert(AICUI.S.UserNameQueue, Id)
                PumpUserNames()
            end

            return nil, "pending"
        end

        --// Makes a priority list of UserIds show the name on one line and
        --// the id under it, redrawn as names arrive. The two used to share a
        --// line joined by a separator written with two bytes, so a row showed
        --// the id, a stray byte, and then nothing else.
        function AICUI.ShowUserNames(Component)
            --// Every name that arrives used to redraw the whole list, so a
            --// whitelist of 120 people was rebuilt 120 times, each rebuild
            --// asking for all 120 again: that is what importing one froze.
            --// The redraws are collapsed into one per frame instead.
            local RedrawQueued = false

            local function Redraw()
                if RedrawQueued then
                    return
                end

                RedrawQueued = true

                task.defer(function()
                    RedrawQueued = false
                    Component:Refresh()
                end)
            end

            --// Every row is two lines, so a list does not change height as
            --// names arrive: who it is on top, the id underneath. Only
            --// characters a Row's font always has, so a name can never come
            --// out as stray bytes.
            Component.OnSelect = function(Value)
                local Id = tostring(Value)
                if not Id:match("^%d+$") then return end

                if type(setclipboard) ~= "function" then
                    Context.NotifyAction("User ID", "Clipboard is not available in this executor", 4)
                    return
                end

                local Ok = pcall(setclipboard, Id)
                Context.NotifyAction("User ID", Ok and ("Copied " .. Id) or "Could not copy to clipboard", 3)
            end

            Component.Format = function(Value)
                local Id = tostring(Value)
                local Name, Reason = AICUI.GetUserName(Value, Redraw)

                if Name then
                    return "@" .. Name, "ID " .. Id
                end

                return "UserId " .. Id, Reason == "failed" and "NAME NOT FOUND" or "LOOKING UP NAME"
            end

            Component:Refresh()
        end

        --// A slider bound to a numeric SaveConfig.Settings entry, using its
        --// range. Whole rounds the value down to an integer.
        --// Setting key -> its slider, so a loaded profile resyncs every one.
        AICUI.S.SettingSliders = AICUI.S.SettingSliders or {}

        function AICUI.AddSettingSlider(Section, Label, Key, Whole)
            local Entry = Context.SaveConfig.GetSetting(Key)
            assert(Entry, "Setting not declared in SaveConfig.Settings: " .. tostring(Key))

            local Slider = Section:AddSlider{
                Name = Label,
                Default = Context.SaveConfig.NormalizeSetting(Entry, CONFIG[Key]),
                Min = Entry.Min,
                Max = Entry.Max,
                Callback = function(Value)
                    local Number = tonumber(Value) or Entry.Default

                    if Whole then
                        Number = math.floor(Number)
                    end

                    CONFIG[Key] = Context.SaveConfig.NormalizeSetting(Entry, Number)
                    AICProfile.QueueProfileSave()
                end,
            }

            AICUI.S.SettingSliders[Key] = Slider
            return Slider
        end
        --// Target pickers. Players and mobs each get their own dropdown:
        --// the roster changes rarely and should show up at once, while mobs
        --// spawn and die constantly and rebuilding on every one made the
        --// list flicker and close under the cursor.
        local TARGET_PICKERS = {
            Player = {
                Ref = "PlayerTargetDropdown",
                Label = "Add Player Target",
                Empty = "No other players",
                GetNames = function()
                    return AICCombat.GetDetectedPlayerTargets()
                end,
            },
            Mob = {
                Ref = "MobTargetDropdown",
                Label = "Add Mob Target",
                Empty = "No detected mobs",
                GetNames = function()
                    return AICCombat.GetDetectedMobTargets()
                end,
            },
        }

        --// Placeholder rows, never added as a target.
        AICUI.S.TargetPickerPlaceholders = {}
        for _, Picker in pairs(TARGET_PICKERS) do
            AICUI.S.TargetPickerPlaceholders[Picker.Empty] = true
        end

        AICUI.S.TargetPickerSignature = {}
        AICUI.S.TargetPickerQueued = {}

        --// A dropdown owns the row it was built in, so removing it is one
        --// call and cannot leave a stray popup behind.
        local function DestroyDropdown(Dropdown)
            if Dropdown and Dropdown.Remove then
                Dropdown:Remove()
            end
        end

        --// Keeps a priority list that has a number per row (AddPriority with
        --// Values) and CONFIG[Key] = { { Name, <CountKey> }, ... } the same.
        --// Adds, edits, reorders and removals write CONFIG, queue a profile
        --// save, then call OnChanged. Returns Load, which shows CONFIG[Key]
        --// in the list (on start and after a profile load).
        function AICUI.BindCountList(Component, Key, CountKey, OnChanged)
            local function Save()
                local Values = Component:GetValues()
                local Result = {}

                for Index, Name in ipairs(Component:GetPriority()) do
                    table.insert(Result, { Name = Name, [CountKey] = Values[Index] })
                end

                CONFIG[Key] = Result
                AICProfile.QueueProfileSave()

                if OnChanged then
                    OnChanged()
                end
            end

            local OriginalAdd = Component.Add
            local OriginalMoveUp = Component.MoveUp
            local OriginalMoveDown = Component.MoveDown
            local OriginalRemove = Component.Remove

            function Component:Add(Name, Value)
                local Added = OriginalAdd(self, Name, Value)

                if Added then
                    Save()
                end

                return Added
            end

            function Component:MoveUp(Name)
                OriginalMoveUp(self, Name)
                Save()
            end

            function Component:MoveDown(Name)
                OriginalMoveDown(self, Name)
                Save()
            end

            function Component:Remove(Name)
                local Removed = OriginalRemove(self, Name)
                Save()
                return Removed
            end

            Component.OnValueChanged = Save

            return function()
                local Names, Values = {}, {}

                for Index, Entry in ipairs(CONFIG[Key] or {}) do
                    Names[Index] = Entry.Name
                    Values[Index] = Entry[CountKey]
                end

                Component:SetPriority(Names, Values)
            end
        end

        --// Swaps Old (or nothing) for a new dropdown with these options.
        --// Utils cannot replace a dropdown's options, and a new one is
        --// appended to the end of its section, so it takes Old's slot;
        --// without this a rebuilt dropdown dropped below every control
        --// after it.
        function AICUI.ReplaceDropdown(Old, Section, Label, Options, Callback)
            local Order = Old and Old.Row and Old.Row.LayoutOrder
            DestroyDropdown(Old)

            local Dropdown = Section:AddDropdown{ Name = Label, Options = Options, Callback = Callback }

            if Order and Dropdown.Row then
                Dropdown.Row.LayoutOrder = Order
            end

            return Dropdown
        end

        --// A dropdown whose options change at runtime, rebuilt only when
        --// the options differ and never while open unless Force (a pick by
        --// the user). Picker = { Dropdown, Signature } is kept by the caller.
        function AICUI.RefreshDropdown(Picker, Section, Label, Options, Callback, Force)
            local Old = Picker.Dropdown
            local Signature = table.concat(Options, "\n")

            if Old and (Picker.Signature == Signature or (Old.Open and not Force)) then
                return
            end

            Picker.Dropdown = AICUI.ReplaceDropdown(Old, Section, Label, Options, Callback)
            Picker.Signature = Signature
        end

        function AICUI.RefreshTargetPicker(Kind, Force)
            local Picker = TARGET_PICKERS[Kind]
            if not Picker or not UIRef.TargetSection then
                return
            end

            local Options = {}

            for _, Name in ipairs(Picker.GetNames()) do
                if not AICCombat.IsEntityInPriority(Name) then
                    table.insert(Options, Name)
                end
            end

            if #Options == 0 then
                Options = { Picker.Empty }
            end

            local Old = UIRef[Picker.Ref]
            local Signature = table.concat(Options, "\n")

            --// Same list: leave the dropdown alone, including one left open.
            if Old and AICUI.S.TargetPickerSignature[Kind] == Signature then
                return
            end

            --// Never rebuild under the cursor for a background change; try
            --// again once it closes. A forced refresh comes from the user (a
            --// pick fires before the dropdown closes), so it goes ahead.
            if Old and Old.Open and not Force then
                AICUI.QueueTargetPickerRefresh(Kind)
                return
            end

            --// A new dropdown is appended to the section, so it takes the
            --// old one's slot to keep its place in the list.
            local Order = Old and Old.Row and Old.Row.LayoutOrder
            DestroyDropdown(Old)

            local Dropdown = UIRef.TargetSection:AddDropdown{
                Name = Picker.Label,
                Options = Options,
                Callback = function(Value)
                    AICUI.S.AddPriorityTarget(Value)
                end,
            }

            if Order and Dropdown.Row then
                Dropdown.Row.LayoutOrder = Order
            end

            Dropdown.Row.LayoutOrder = Kind == "Mob" and 30 or 40
            UIRef[Picker.Ref] = Dropdown
            AICUI.S.TargetPickerSignature[Kind] = Signature
        end

        --// Collapses a burst of changes into one rebuild after a delay.
        function AICUI.QueueTargetPickerRefresh(Kind)
            if AICUI.S.TargetPickerQueued[Kind] then
                return
            end

            AICUI.S.TargetPickerQueued[Kind] = true

            local Delay = Kind == "Player"
                and CONFIG.PLAYER_TARGET_REFRESH_DELAY
                or CONFIG.MOB_TARGET_REFRESH_DELAY

            task.delay(Delay, function()
                AICUI.S.TargetPickerQueued[Kind] = false
                AICUI.RefreshTargetPicker(Kind)
            end)
        end

        --// Both pickers, right away. Used after the priority list or the
        --// profile changes, and by the Refresh button.
        function AICUI.RefreshTargetDropdown()
            AICUI.RefreshTargetPicker("Player", true)
            AICUI.RefreshTargetPicker("Mob", true)
        end
        function AICUI.SyncPriorityState(RefreshDropdown)
            CONFIG.TARGET_ENTITY_PRIORITY = UIRef.PriorityComponent.Priority
            AICCombat.ResetTargetState()
        
            if RefreshDropdown then
                AICUI.RefreshTargetDropdown()
            end
        
            AICProfile.SaveActiveProfile()
        end
        
        --// Utility UI status helpers
        function AICUI.updateFeatureButtons()
            if UIRef.ExecuteChargeSlider then
                UIRef.ExecuteChargeSlider:Set(
                    math.clamp(tonumber(CONFIG.EXECUTE_CHARGE_HP_PERCENT) or 0, 0, 90),
                    true
                )
            end
        
            if UIRef.TargetTypeDropdown then
                UIRef.TargetTypeDropdown:Set(tostring(CONFIG.TARGET_HP_MODE or "Disabled"), true)
            end
        
            if UIRef.BlockDelaySlider then
                UIRef.BlockDelaySlider:Set(CONFIG.AUTO_BLOCK_DELAY, true)
            end

            if UIRef.CloseCombatRangeSlider then
                UIRef.CloseCombatRangeSlider:Set(CONFIG.CLOSE_COMBAT_RANGE, true)
            end

            --// Every slider made with AddSettingSlider, so a new one does
            --// not need its own line here.
            for Key, Slider in pairs(AICUI.S.SettingSliders) do
                local Entry = Context.SaveConfig.GetSetting(Key)

                if Entry then
                    Slider:Set(Context.SaveConfig.NormalizeSetting(Entry, CONFIG[Key]), true)
                end
            end

            if UIRef.BlockWhitelistComponent then
                UIRef.BlockWhitelistComponent:SetPriority(table.clone(CONFIG.BLOCK_WHITELIST or {}))
                CONFIG.BLOCK_WHITELIST = UIRef.BlockWhitelistComponent.Priority
                AICUI.RefreshWhitelistPlayerDropdown()
            end
        
            --// Every saved toggle, so a new one in SaveConfig.Features is
            --// refreshed without being listed here. Missing this list entry
            --// is why Safe Booster Reset showed off after a reload.
            FeatureState.AutoFarm.Enabled = AICFeature.S.Enabled

            for _, Entry in ipairs(Context.SaveConfig.Features) do
                AICUI.SetFeatureComponent(Entry.Name, FeatureState[Entry.Name].Enabled)
            end

            if AICUI.RefreshPartyUI then
                AICUI.RefreshPartyUI()
            end

            if AICUI.RefreshMiningUI then
                AICUI.RefreshMiningUI()
            end

            if AICUI.RefreshSmithingUI then
                AICUI.RefreshSmithingUI()
            end

            --// AutoRefill's per-booster toggles follow RESET_BOOSTERS.
            if AICFeature.RefreshBoosterToggles then
                AICFeature.RefreshBoosterToggles()
            end
        end
        function AICUI.updateButton()
            FeatureState.AutoFarm.Enabled = AICFeature.S.Enabled
            AICUI.SetFeatureComponent("AutoFarm", AICFeature.S.Enabled)
        end
        function AICUI.FormatVector3(Position)
            if typeof(Position) ~= "Vector3" then
                return "0, 0, 0"
            end
        
            return string.format("%.2f, %.2f, %.2f", Position.X, Position.Y, Position.Z)
        end
        function AICUI.BuildWaypointLabels()
        local PlaceConfig = Runtime:GetPlaceConfig()
            local Labels = {}
        
            for Index, Position in ipairs(PlaceConfig.WAYPOINTS or {}) do
                local ZoneIndex = PlaceConfig.WAYPOINT_ZONES and PlaceConfig.WAYPOINT_ZONES[Index] or 0
                local Pair = ZoneIndex > 0 and string.format("  > Z%d", ZoneIndex) or ""

                Labels[Index] = string.format("#%d%s  (%s)", Index, Pair, AICUI.FormatVector3(Position))
            end
        
            return Labels
        end
        function AICUI.BuildZoneLabels(Zones, Prefix)
            local Labels = {}
        
            for Index, Zone in ipairs(Zones or {}) do
                Labels[Index] = string.format(
                    "#%d  R:%g  (%s)",
                    Index,
                    tonumber(Zone.Radius) or 0,
                    AICUI.FormatVector3(Zone.Center)
                )
            end
        
            return Labels
        end
        function AICUI.ReplacePriorityList(Component, Values)
            if not Component then
                return
            end
        
            Component:SetPriority(Values)
        end
        function AICUI.RefreshWaypointList()
            if not UIRef.WaypointListComponent then
                return
            end

            --// Wait times ride along with the labels, so the list always shows
            --// what PlaceConfig holds, including after a profile load.
            local PlaceConfig = Runtime:GetPlaceConfig()
            PlaceConfig.WAYPOINT_WAITS = AICConfig.NormalizeWaitList(PlaceConfig.WAYPOINT_WAITS, #PlaceConfig.WAYPOINTS)
            PlaceConfig.WAYPOINT_ZONES = AICConfig.NormalizeZonePairs(PlaceConfig.WAYPOINT_ZONES, #PlaceConfig.WAYPOINTS, #PlaceConfig.FARM_ZONES)
            PlaceConfig.WAYPOINT_JUMPS = AICConfig.NormalizeJumpList(PlaceConfig.WAYPOINT_JUMPS, #PlaceConfig.WAYPOINTS)

            UIRef.WaypointListComponent:SetPriority(
                AICUI.BuildWaypointLabels(),
                table.clone(PlaceConfig.WAYPOINT_WAITS),
                table.clone(PlaceConfig.WAYPOINT_JUMPS)
            )

            if AICUI.RefreshWaypointPairPickers then
                AICUI.RefreshWaypointPairPickers()
            end

            --// The Boss Route editor reads the same place config, so a profile
            --// load refreshes it too (BossNavigator).
            if AICUI.RefreshBossRoutePickers then
                AICUI.RefreshBossRoutePickers()
            end
        end
        function AICUI.RefreshFarmZoneList()
        local PlaceConfig = Runtime:GetPlaceConfig()
            AICUI.ReplacePriorityList(
                UIRef.FarmZoneListComponent,
                AICUI.BuildZoneLabels(PlaceConfig.FARM_ZONES, "Farm")
            )

            --// Zone count or order may have changed.
            if AICUI.RefreshZoneTargets then
                AICUI.RefreshZoneTargets()
            end

            if AICUI.RefreshWaypointPairPickers then
                AICUI.RefreshWaypointPairPickers()
            end
        end
        function AICUI.RefreshDeadzoneList()
        local PlaceConfig = Runtime:GetPlaceConfig()
            AICUI.ReplacePriorityList(
                UIRef.DeadzoneListComponent,
                AICUI.BuildZoneLabels(PlaceConfig.DEADZONES, "Deadzone")
            )
        end
        function AICUI.GetZonePickerOptions(Zones, Prefix)
            local Options = {}
        
            for Index in ipairs(Zones or {}) do
                table.insert(Options, string.format("#%d", Index))
            end
        
            if #Options == 0 then
                Options = {"No " .. Prefix .. " Zones"}
            end
        
            return Options
        end
        function AICUI.RefreshFarmZonePicker()
        local PlaceConfig = Runtime:GetPlaceConfig()
            local Options = AICUI.GetZonePickerOptions(PlaceConfig.FARM_ZONES, "Farm")
        
            AICProfile.S.SelectedFarmZoneIndex = math.clamp(AICProfile.S.SelectedFarmZoneIndex, 1, math.max(1, #PlaceConfig.FARM_ZONES))
            local SelectedOption = Options[AICProfile.S.SelectedFarmZoneIndex] or Options[1]

            UIRef.FarmZonePicker = AICUI.ReplaceDropdown(UIRef.FarmZonePicker, UIRef.FarmzoneSection, "Edit Farm Zone", Options, function(Value)
                if Value == "No Farm Zones" then return end
                local Index = table.find(Options, Value)
                if not Index or not PlaceConfig.FARM_ZONES[Index] then return end
        
                AICProfile.S.SelectedFarmZoneIndex = Index
                UIRef.FarmRadiusSlider:Set(tonumber(PlaceConfig.FARM_ZONES[Index].Radius) or 100, true)

                if AICUI.RefreshZoneTargets then
                    AICUI.RefreshZoneTargets()
                end
            end)
        
            if SelectedOption then
                UIRef.FarmZonePicker:Set(SelectedOption, true)
                local Zone = PlaceConfig.FARM_ZONES[AICProfile.S.SelectedFarmZoneIndex]
                if Zone then
                    UIRef.FarmRadiusSlider:Set(tonumber(Zone.Radius) or 100, true)
                    if AICUI.RefreshZoneTargets then AICUI.RefreshZoneTargets() end
                end
            end
        end
        function AICUI.RefreshDeadzonePicker()
        local PlaceConfig = Runtime:GetPlaceConfig()
            local Options = AICUI.GetZonePickerOptions(PlaceConfig.DEADZONES, "Deadzone")
        
            AICProfile.S.SelectedDeadzoneIndex = math.clamp(AICProfile.S.SelectedDeadzoneIndex, 1, math.max(1, #PlaceConfig.DEADZONES))
            local SelectedOption = Options[AICProfile.S.SelectedDeadzoneIndex] or Options[1]

            UIRef.DeadzonePicker = AICUI.ReplaceDropdown(UIRef.DeadzonePicker, UIRef.DeadzoneSection, "Edit Deadzone", Options, function(Value)
                if Value == "No Deadzone Zones" then return end
                local Index = table.find(Options, Value)
                if not Index or not PlaceConfig.DEADZONES[Index] then return end
        
                AICProfile.S.SelectedDeadzoneIndex = Index
                UIRef.DeadzoneRadiusSlider:Set(tonumber(PlaceConfig.DEADZONES[Index].Radius) or 35, true)
            end)
        
            if SelectedOption then
                UIRef.DeadzonePicker:Set(SelectedOption, true)
                local Zone = PlaceConfig.DEADZONES[AICProfile.S.SelectedDeadzoneIndex]
                if Zone then
                    UIRef.DeadzoneRadiusSlider:Set(tonumber(Zone.Radius) or 35, true)
                end
            end
        end
        
        --// UI stats
        --// EXP the next level needs: 9 plus 6 * (i + 2) for every level so
        --// far. Closed form: at level 900 the loop it replaces ran 899 times,
        --// twice a second, inside the label that shows this.
        function AICUI.neededExp(lvl)
            local levels = math.max(0, (tonumber(lvl) or 1) - 1)

            return 9 + 6 * (levels * (levels + 1) / 2 + 2 * levels)
        end
        function AICUI.GetItem(String, ItemName)
            for Item in string.gmatch(String, "([^,]+)") do
                local Name, Amount = string.match(Item, "([^|]+)|(.+)")
        
                if Name == ItemName then
                    return Name, tonumber(Amount) or 0
                end
            end
        
            return ItemName, 0
        end
        --// The event currency readout: how much of the currency this event
        --// hands out the player holds, under the name the game gives it
        --// (AICUI.S.TargetCurrency is the inventory item counted).
        function AICUI.FormatEventCurrency(Amount)
            return string.upper(AICUI.S.TargetCurrency) .. "  " .. tostring(Amount)
        end
        function AICUI.SetEventCurrencyLabel(Amount)
            if UIRef.EventCurrencyLabel then
                UIRef.EventCurrencyLabel:Set(AICUI.FormatEventCurrency(Amount))
            end
        end
        function AICUI.updateEventCurrency()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
        
            if not PlayerStats then
                AICUI.S.EventCurrency = 0
                AICUI.SetEventCurrencyLabel(0)
                UIRef.ExpLabel:Set("EXP            0/0")
                AICUI.S.LastInventory = nil
                return
            end
        
            local PlayerLvl = PlayerStats:FindFirstChild("Level")
            local PlayerExp = PlayerStats:FindFirstChild("EXP")
        
            if PlayerLvl and PlayerExp then
                UIRef.ExpLabel:Set("EXP            " .. PlayerExp.Value .. "/" .. AICUI.neededExp(PlayerLvl.Value))
            else
                UIRef.ExpLabel:Set("EXP            0/0")
            end
        
            local Inventory = PlayerStats:FindFirstChild("Inventory")
        
            if not Inventory then
                AICUI.S.EventCurrency = 0
                AICUI.SetEventCurrencyLabel(0)
                return
            end
        
            local InventoryValue = Inventory.Value
        
            if InventoryValue == AICUI.S.LastInventory then
                return
            end
        
            AICUI.S.LastInventory = InventoryValue
        
            local _, Amount = AICUI.GetItem(InventoryValue, AICUI.S.TargetCurrency)
        
            AICUI.S.EventCurrency = Amount
            AICUI.SetEventCurrencyLabel(AICUI.S.EventCurrency)
        end
        function AICUI.updatePlayTime()
            local ServerAge = math.floor(workspace.DistributedGameTime)
        
            local Hours   = math.floor(ServerAge / 3600)
            local Minutes = math.floor((ServerAge % 3600) / 60)
            local Seconds = ServerAge % 60
        
            if UIRef.ServerAgeLabel then
                UIRef.ServerAgeLabel:Set("PLAY TIME      " .. string.format("%02d:%02d:%02d", Hours, Minutes, Seconds))
            end
        end
        --// Written only when the text actually changes: a label assignment
        --// re-shapes the string, and the heartbeat used to do this 60 times a
        --// second for a readout nobody reads that often.
        function AICUI.updatePosition()
            if not UIRef.PositionLabel then
                return
            end

            local _, _, RootPart = Runtime:GetCharacter()
            local Text

            if RootPart then
                local Position = RootPart.Position

                Text = string.format(
                    "POSITION       %.2f, %.2f, %.2f",
                    Position.X,
                    Position.Y,
                    Position.Z
                )
            else
                Text = "POSITION       --"
            end

            if Text ~= AICUI.S.LastPositionText then
                AICUI.S.LastPositionText = Text
                UIRef.PositionLabel:Set(Text)
            end
        end
        
        --// Refresh the dropdown whenever the mob set changes.
        --// Subscribes the picker to the mob watcher. Assigned here rather than
        --// called from there, so the dependency runs UI -> Combat only.
        AICCombat.OnMobSetChanged = function(Kind)
            AICUI.QueueTargetPickerRefresh(Kind == "Player" and "Player" or "Mob")
        end
        
        
        ------------------------------------------------------------------------
        --// AICDebug
        --//
        --// in-world waypoint and zone visualiser
        --//
        --// 10 function(s). Definitions only; nothing here runs
        --// at load time.
        ------------------------------------------------------------------------
        
        ------------------------------------------------------------------------
        --// AICDebug  ::  in-world waypoint and zone visualiser
        --// 10 function(s)
        ------------------------------------------------------------------------
        --// ============================================================
        --// DEBUG VISUALIZER
        --// ============================================================
        return Module
    end,
}
