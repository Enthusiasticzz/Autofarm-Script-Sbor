-- Minezone owns the mine zone editor on the Mining tab. Mine zones are
-- stored on the place config (MINE_ZONES) like farm zones and deadzones, so
-- they save and export with the profile. Auto Mining only mines inside them.
return {
    Name = "Minezone",
    Dependencies = {"Runtime", "ProfileManager", "Components", "DebugVisualizer"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local AICConfig = Context.AICConfig
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        local DEFAULT_RADIUS = 60
        local MIN_RADIUS = 5
        local MAX_RADIUS = 300

        local Module = { Name = "Minezone" }

        AICProfile.S.SelectedMineZoneIndex = 1

        local function GetMineZones()
            return Runtime:GetPlaceConfig().MINE_ZONES
        end

        local function GetLabels()
            return AICUI.BuildZoneLabels(GetMineZones(), "Mine")
        end

        --// Every edit needs a profile to write to; the place preset is
        --// read-only, the same rule as farm zones and deadzones.
        local function CanEdit(Message)
            if AICProfile.S.ActiveProfileName then
                return true
            end

            AICUI.SetProfileStatus(Message or "CREATE / LOAD PROFILE FIRST")
            return false
        end

        local function Commit(Status)
            Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
            AICUI.RefreshMineZoneList()
            AICUI.RefreshMineZonePicker()
            AICProfile.SaveActiveProfile()
            AICDebug.UpdateDebugVisualizer()
            AICUI.SetProfileStatus(Status)
        end

        UIRef.MineZoneSection = UIRef.MineTab:AddSection("Mine Zone")

        UIRef.MineRadiusSlider = UIRef.MineZoneSection:AddSlider(
            "Mine Zone Radius",
            DEFAULT_RADIUS,
            MIN_RADIUS,
            MAX_RADIUS,
            function(Value)
                local Zone = GetMineZones()[AICProfile.S.SelectedMineZoneIndex]

                if not Zone or not AICProfile.S.ActiveProfileName then
                    return
                end

                Zone.Radius = Value
                AICUI.RefreshMineZoneList()
                AICDebug.UpdateDebugVisualizer()
                AICProfile.QueueProfileSave()
            end
        )

        UIRef.MineZoneSection:AddButton("Add Mine Zone Here", function()
            local _, _, RootPart = Runtime:GetCharacter()

            if not RootPart then
                AICUI.SetProfileStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit() then
                return
            end

            table.insert(GetMineZones(), {
                Center = AICConfig.RoundVector3(RootPart.Position),
                Radius = UIRef.MineRadiusSlider:Get(),
            })

            AICProfile.S.SelectedMineZoneIndex = #GetMineZones()
            Commit("MINE ZONE ADDED #" .. tostring(#GetMineZones()))
        end)

        UIRef.MineZoneSection:AddButton("Clear Mine Zones", function()
            if not CanEdit() then
                return
            end

            table.clear(GetMineZones())
            AICProfile.S.SelectedMineZoneIndex = 1
            Commit("MINE ZONES CLEARED")
            NotifyAction("Mine Zone", "Cleared all mine zones")
        end)

        UIRef.MineZoneListComponent = UIRef.MineZoneSection:AddPriority("All Mine Zones", GetLabels())

        local OriginalMoveUp = UIRef.MineZoneListComponent.MoveUp
        local OriginalMoveDown = UIRef.MineZoneListComponent.MoveDown
        local OriginalRemove = UIRef.MineZoneListComponent.Remove

        --// Swaps a zone with its neighbour Delta (-1 up, +1 down) away.
        local function MoveZone(Component, Label, Delta, Original, Status)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Zones = GetMineZones()
            local Index = table.find(GetLabels(), Label)
            local Other = Index and Index + Delta

            if not Other or Other < 1 or Other > #Zones then
                return
            end

            Zones[Index], Zones[Other] = Zones[Other], Zones[Index]
            Original(Component, Label)
            AICProfile.S.SelectedMineZoneIndex = Other
            Commit(Status)
        end

        function UIRef.MineZoneListComponent:MoveUp(Label)
            MoveZone(self, Label, -1, OriginalMoveUp, "MINE ZONE MOVED UP")
        end

        function UIRef.MineZoneListComponent:MoveDown(Label)
            MoveZone(self, Label, 1, OriginalMoveDown, "MINE ZONE MOVED DOWN")
        end

        function UIRef.MineZoneListComponent:Remove(Label)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = table.find(GetLabels(), Label)

            if not Index then
                return
            end

            table.remove(GetMineZones(), Index)
            OriginalRemove(self, Label)
            AICProfile.S.SelectedMineZoneIndex = math.clamp(Index, 1, math.max(1, #GetMineZones()))
            Commit("MINE ZONE REMOVED #" .. tostring(Index))
        end

        function AICUI.RefreshMineZoneList()
            AICUI.ReplacePriorityList(UIRef.MineZoneListComponent, GetLabels())
        end

        --// Picks which zone the radius slider edits. Rebuilt whenever the
        --// zone count changes, like the farm zone and deadzone pickers.
        function AICUI.RefreshMineZonePicker()
            local Zones = GetMineZones()
            local Options = AICUI.GetZonePickerOptions(Zones, "Mine")
            local Old = UIRef.MineZonePicker
            --// A new dropdown is appended to the section; it takes the old
            --// one's slot instead.
            local Order = Old and Old.Frame and Old.Frame.LayoutOrder

            if Old then
                if Old.Popup then Old.Popup:Destroy() end
                if Old.Frame then Old.Frame:Destroy() end
            end

            AICProfile.S.SelectedMineZoneIndex = math.clamp(AICProfile.S.SelectedMineZoneIndex, 1, math.max(1, #Zones))

            UIRef.MineZonePicker = UIRef.MineZoneSection:AddDropdown("Edit Mine Zone", Options, function(Value)
                local Index = table.find(Options, Value)
                local Zone = Index and GetMineZones()[Index]

                if not Zone then
                    return
                end

                AICProfile.S.SelectedMineZoneIndex = Index
                UIRef.MineRadiusSlider:Set(tonumber(Zone.Radius) or DEFAULT_RADIUS, false)
            end)

            if Order and UIRef.MineZonePicker.Frame then
                UIRef.MineZonePicker.Frame.LayoutOrder = Order
            end

            local Selected = Options[AICProfile.S.SelectedMineZoneIndex] or Options[1]

            if Selected then
                UIRef.MineZonePicker:Set(Selected)
            end
        end

        AICUI.RefreshMineZonePicker()

        return Module
    end,
}
