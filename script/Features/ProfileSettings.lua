return {
    Name = "ProfileSettings",
    Dependencies = {"Runtime", "ProfileManager", "Components"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local CONFIG = Context.CONFIG
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local UI = Context.UI
        local Feature = Context.Feature
        local AICFeature = Context.AICFeature
        local AICCombat = Context.AICCombat
        local BasePlaceConfig = Context.Runtime:GetBasePlaceConfig()
        local NotifyAction = Context.NotifyAction
        local function GetRootPart()
            local _, _, RootPart = Runtime:GetCharacter()
            return RootPart
        end

        local Module = {Name = "ProfileSettings"}
    function AICUI.SetProfileStatus(Text)
        if UIRef.ProfileStatusLabel then
            UIRef.ProfileStatusLabel:Set("STATUS:  " .. tostring(Text))
        end
    end

    function AICUI.GetCurrentProfileNames()
        local Names = AICProfile.GetProfileNames()

        -- Default Config is always available for the current PlaceId.
        table.insert(Names, 1, "Default Config")

        return Names
    end

    function AICUI.RefreshProfileDropdown()
        local Options = AICUI.GetCurrentProfileNames()

        UIRef.ProfileDropdown = AICUI.ReplaceDropdown(
            UIRef.ProfileDropdown,
            UIRef.ProfilesSection,
            "Profile",
            Options,
            function(Value)
                local PlaceConfig = Runtime:GetPlaceConfig()

                if Value == "Default Config" then
                    AICProfile.ApplyDefaultPlaceConfig()

                    PlaceConfig = Runtime:GetPlaceConfig()

                    UIRef.ProfileNameBox:Set("")
                    UIRef.ReachDistanceBox:Set(tostring(PlaceConfig.REACH_DISTANCE or 5))
                    UIRef.FarmRadiusSlider:Set(
                        (PlaceConfig.FARM_ZONES[1] and PlaceConfig.FARM_ZONES[1].Radius) or 100,
                        true
                    )
                    UIRef.DeadzoneRadiusSlider:Set(
                        (PlaceConfig.DEADZONES[1] and PlaceConfig.DEADZONES[1].Radius) or 35,
                        true
                    )
                    UIRef.RetreatHealthSlider:Set(CONFIG.RETREAT_HEALTH_PERCENT, true)
                    UIRef.AutoHealHealthSlider:Set(CONFIG.AUTO_HEAL_HEALTH_PERCENT, true)
                    UIRef.SafeEnemyRangeSlider:Set(CONFIG.SAFE_ENEMY_RANGE, true)

                    AICUI.RefreshWaypointList()
                    AICUI.RefreshFarmZoneList()
                    AICUI.RefreshDeadzoneList()
                    AICUI.RefreshFarmZonePicker()
                    AICUI.RefreshDeadzonePicker()

                    UIRef.PriorityComponent:SetPriority(
                        table.clone(CONFIG.TARGET_ENTITY_PRIORITY)
                    )

                    AICUI.updateFeatureButtons()
                    AICUI.RefreshTargetDropdown()
                    AICCombat.ResetTargetState()
                    AICDebug.UpdateDebugVisualizer()
                    AICUI.SetProfileStatus("DEFAULT CONFIG (READ-ONLY)")
                    return
                end

                if AICProfile.LoadProfile(Value) then
                    PlaceConfig = Runtime:GetPlaceConfig()

                    UIRef.ProfileNameBox:Set(Value)
                    UIRef.ReachDistanceBox:Set(tostring(PlaceConfig.REACH_DISTANCE or 5))
                    UIRef.FarmRadiusSlider:Set(
                        (PlaceConfig.FARM_ZONES[1] and PlaceConfig.FARM_ZONES[1].Radius) or 100,
                        true
                    )
                    UIRef.DeadzoneRadiusSlider:Set(
                        (PlaceConfig.DEADZONES[1] and PlaceConfig.DEADZONES[1].Radius) or 35,
                        true
                    )
                    UIRef.RetreatHealthSlider:Set(CONFIG.RETREAT_HEALTH_PERCENT, true)
                    UIRef.AutoHealHealthSlider:Set(CONFIG.AUTO_HEAL_HEALTH_PERCENT, true)
                    UIRef.SafeEnemyRangeSlider:Set(CONFIG.SAFE_ENEMY_RANGE, true)

                    AICUI.RefreshWaypointList()
                    AICUI.RefreshFarmZoneList()
                    AICUI.RefreshDeadzoneList()
                    AICUI.RefreshFarmZonePicker()
                    AICUI.RefreshDeadzonePicker()

                    local AutoBlock = Context.Modules.AutoBlock
                    if AutoBlock and AutoBlock.SetEnabled then
                        AutoBlock:SetEnabled(AICFeature.S.BlockEnabled, false)
                    end

                    UIRef.PriorityComponent:SetPriority(
                        table.clone(CONFIG.TARGET_ENTITY_PRIORITY)
                    )

                    AICUI.updateFeatureButtons()
                    AICUI.RefreshTargetDropdown()
                    AICCombat.ResetTargetState()
                    AICDebug.UpdateDebugVisualizer()
                    AICUI.SetProfileStatus("LOADED " .. Value)
                else
                    AICUI.SetProfileStatus("LOAD FAILED")
                end
            end
        )

        if AICProfile.S.ActiveProfileName
            and table.find(Options, AICProfile.S.ActiveProfileName)
        then
            UIRef.ProfileDropdown:Set(AICProfile.S.ActiveProfileName, true)
        else
            UIRef.ProfileDropdown:Set("Default Config", true)
        end
    end
        UIRef.ProfileTab = UI:AddTab{ Name = "Profile Settings" }
        UIRef.ProfilesSection = UIRef.ProfileTab:AddSection{ Title = "Profiles" }

UIRef.ProfileStatusLabel = UIRef.ProfilesSection:AddLabel("STATUS:  DEFAULT PLACE_CONFIG (READ-ONLY)")

UIRef.ProfileNameBox = UIRef.ProfilesSection:AddTextBox{
    Name = "Profile Name",
    Default = "",
    Callback = function(Value)
        --// The textbox is used as the source for Create Profile.
    end,
}

UIRef.ImportDataBox = UIRef.ProfilesSection:AddTextBox{
    Name = "Import Data",
    Default = "",
    Callback = function(Value)
        --// Paste JSON here, then press Import Save.
    end,
}

--// A save is hundreds of kilobytes of JSON. Left in the TextBox the client
--// lays all of it out as one line, which is what made importing freeze, so a
--// long paste is taken off the box the moment it lands and kept here; the box
--// shows a short note instead.
local ImportPayload = nil
local ImportBoxBusy = false
local IMPORT_BOX_LIMIT = 1200
local IMPORT_BOX_NOTE = "(save kept outside the box - press Import Save)"

local function WatchImportBox()
    local Box = UIRef.ImportDataBox and UIRef.ImportDataBox.Box

    if not Box then
        return
    end

    Box:GetPropertyChangedSignal("Text"):Connect(function()
        if ImportBoxBusy then
            return
        end

        local Raw = Box.Text

        if #Raw <= IMPORT_BOX_LIMIT then
            ImportPayload = #Raw > 0 and Raw or nil
            return
        end

        ImportPayload = Raw
        ImportBoxBusy = true
        Box.Text = IMPORT_BOX_NOTE
        ImportBoxBusy = false
    end)
end

WatchImportBox()

local function ImportText()
    local FromBox = UIRef.ImportDataBox:Get()

    if FromBox == IMPORT_BOX_NOTE then
        return ImportPayload or ""
    end

    --// The box was edited since the paste: what is in it is what to import.
    return (#FromBox > 0) and FromBox or (ImportPayload or "")
end

--// The refresh after a load touches every list in the menu at once. Steps run
--// one per frame, with the failure named, so the client keeps drawing instead
--// of stalling on a single huge frame.
local function RunInSteps(Steps, OnDone)
    task.spawn(function()
        for _, Step in ipairs(Steps) do
            local Ok, Err = pcall(Step)

            if not Ok then
                warn("[AIC] profile refresh step failed:", Err)
            end

            task.wait()
        end

        if OnDone then
            OnDone()
        end
    end)
end

UIRef.ProfilesSection:AddButton{ Name = "Create New Profile", Callback = function()
    local Name = UIRef.ProfileNameBox:Get()

    if Name == "" then
        AICUI.SetProfileStatus("ENTER PROFILE NAME")
        return
    end

    local Success, ErrorMessage = AICProfile.CreateProfile(Name)

    if not Success then
        AICUI.SetProfileStatus(ErrorMessage or "CREATE FAILED")
        return
    end

    UIRef.ProfileNameBox:Set(Name)
    UIRef.ReachDistanceBox:Set(tostring(Runtime:GetPlaceConfig().REACH_DISTANCE or 5))
    UIRef.FarmRadiusSlider:Set((Runtime:GetPlaceConfig().FARM_ZONES[1] and Runtime:GetPlaceConfig().FARM_ZONES[1].Radius) or 100, true)
    UIRef.DeadzoneRadiusSlider:Set((Runtime:GetPlaceConfig().DEADZONES[1] and Runtime:GetPlaceConfig().DEADZONES[1].Radius) or 35, true)
    UIRef.RetreatHealthSlider:Set(CONFIG.RETREAT_HEALTH_PERCENT, true)
    UIRef.AutoHealHealthSlider:Set(CONFIG.AUTO_HEAL_HEALTH_PERCENT, true)
    UIRef.SafeEnemyRangeSlider:Set(CONFIG.SAFE_ENEMY_RANGE, true)
    AICUI.RefreshWaypointList()
    AICUI.RefreshFarmZoneList()
    AICUI.RefreshDeadzoneList()
    AICUI.RefreshProfileDropdown()
    UIRef.ProfileDropdown:Set(Name, true)
    --// A new profile can replace CONFIG.TARGET_ENTITY_PRIORITY.
    --// Sync the Utils priority component before rebuilding the target dropdown,
    --// otherwise it may still hold the previous profile's priority list.
    UIRef.PriorityComponent:SetPriority(table.clone(CONFIG.TARGET_ENTITY_PRIORITY or {}))
    AICUI.updateFeatureButtons()
    AICUI.RefreshTargetDropdown()
    AICDebug.UpdateDebugVisualizer()
    AICUI.SetProfileStatus("CREATED " .. Name)
    NotifyAction("Profile", "Created " .. Name)
end }

UIRef.ProfilesSection:AddButton{ Name = "Save Profile", Callback = function()
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("NO ACTIVE PROFILE")
        return
    end

    if AICProfile.SaveActiveProfile() then
        AICUI.SetProfileStatus("SAVED " .. AICProfile.S.ActiveProfileName)
        NotifyAction("Save", "Saved " .. AICProfile.S.ActiveProfileName)
    else
        AICUI.SetProfileStatus("SAVE FAILED")
    end
end }

UIRef.ProfilesSection:AddButton{ Name = "Export Save", Callback = function()
    local Success, Result = AICProfile.ExportActiveProfile()

    if Success then
        AICUI.SetProfileStatus("EXPORTED " .. tostring(AICProfile.S.ActiveProfileName))
        NotifyAction("Export", "Copied " .. tostring(AICProfile.S.ActiveProfileName) .. " to clipboard")
    else
        AICUI.SetProfileStatus(Result or "EXPORT FAILED")
    end
end }

UIRef.ProfilesSection:AddButton{ Name = "Import Save", Callback = function()
    local Raw = ImportText()

    AICUI.SetProfileStatus("IMPORTING...")

    local Success, Result = AICProfile.ImportProfileFromText(Raw)

    if not Success then
        --// Kept, so a refused paste can be tried again without pasting it
        --// a second time.
        ImportPayload = Raw
        AICUI.SetProfileStatus(Result or "IMPORT FAILED")
        NotifyAction("Import", Result or "IMPORT FAILED")
        return
    end

    ImportPayload = nil
    UIRef.ImportDataBox:Set("")

    local PlaceConfig = Runtime:GetPlaceConfig()

    UIRef.ProfileNameBox:Set(Result)
    UIRef.ReachDistanceBox:Set(tostring(PlaceConfig.REACH_DISTANCE or 5))
    UIRef.FarmRadiusSlider:Set((PlaceConfig.FARM_ZONES[1] and PlaceConfig.FARM_ZONES[1].Radius) or 100, true)
    UIRef.DeadzoneRadiusSlider:Set((PlaceConfig.DEADZONES[1] and PlaceConfig.DEADZONES[1].Radius) or 35, true)
    UIRef.RetreatHealthSlider:Set(CONFIG.RETREAT_HEALTH_PERCENT, true)
    UIRef.AutoHealHealthSlider:Set(CONFIG.AUTO_HEAL_HEALTH_PERCENT, true)
    UIRef.SafeEnemyRangeSlider:Set(CONFIG.SAFE_ENEMY_RANGE, true)

    RunInSteps({
        function() AICUI.RefreshProfileDropdown(); UIRef.ProfileDropdown:Set(Result, true) end,
        function() AICUI.RefreshWaypointList() end,
        function() AICUI.RefreshFarmZoneList() end,
        function() AICUI.RefreshDeadzoneList() end,
        function() AICUI.RefreshFarmZonePicker() end,
        function() AICUI.RefreshDeadzonePicker() end,
        function() UIRef.PriorityComponent:SetPriority(table.clone(CONFIG.TARGET_ENTITY_PRIORITY)) end,
        function() Feature.AutoBlock.Enabled = AICFeature.S.BlockEnabled end,
        function() AICUI.updateFeatureButtons() end,
        function() AICUI.RefreshTargetDropdown() end,
        function() AICCombat.ResetTargetState() end,
        function() AICDebug.UpdateDebugVisualizer() end,
    }, function()
        AICUI.SetProfileStatus("IMPORTED " .. Result)
        NotifyAction("Import", "Imported " .. tostring(Result))
    end)
end }

UIRef.ProfilesSection:AddButton{ Name = "Delete Profile", Callback = function()
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("NO ACTIVE PROFILE")
        return
    end

    local Name = AICProfile.S.ActiveProfileName

    if AICProfile.DeleteProfile(Name) then
        UIRef.ProfileNameBox:Set("")
        UIRef.ReachDistanceBox:Set(tostring(Runtime:GetPlaceConfig().REACH_DISTANCE or 5))
        UIRef.FarmRadiusSlider:Set((Runtime:GetPlaceConfig().FARM_ZONES[1] and Runtime:GetPlaceConfig().FARM_ZONES[1].Radius) or 100, true)
        UIRef.DeadzoneRadiusSlider:Set((Runtime:GetPlaceConfig().DEADZONES[1] and Runtime:GetPlaceConfig().DEADZONES[1].Radius) or 35, true)
        AICUI.RefreshWaypointList()
        AICUI.RefreshFarmZoneList()
        AICUI.RefreshDeadzoneList()
        AICUI.RefreshProfileDropdown()
        UIRef.PriorityComponent:SetPriority(table.clone(
            BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                or CONFIG.TARGET_ENTITY_PRIORITY
                or {}
        ))
        CONFIG.TARGET_ENTITY_PRIORITY = UIRef.PriorityComponent.Priority
        AICUI.updateFeatureButtons()
        AICUI.RefreshTargetDropdown()
        AICDebug.UpdateDebugVisualizer()
        AICUI.SetProfileStatus("DELETED " .. Name)
        NotifyAction("Profile", "Deleted " .. Name)
    else
        AICUI.SetProfileStatus("DELETE FAILED")
    end
end }


        function Module:Finalize()
            AICUI.RefreshWaypointList()
            AICUI.RefreshFarmZoneList()
            AICUI.RefreshDeadzoneList()
            AICUI.updatePosition()

            --// Initial debug setup.
            AICDebug.UpdateDebugVisualizer()

            --// Load the most recently used profile for this PlaceId. If there
            --// is none, the place_config defaults stay in effect.
            if AICProfile.S.ProfileStore.LastUsed
                and AICProfile.S.ProfileStore.Profiles[AICProfile.S.ProfileStore.LastUsed]
            then
                local LastUsed = AICProfile.S.ProfileStore.LastUsed
                AICProfile.S.ActiveProfileName = LastUsed
                if not AICProfile.LoadProfile(LastUsed) then
                    AICProfile.S.ActiveProfileName = nil
                    AICProfile.S.ProfileData = nil
                end
            end

            if AICProfile.S.ActiveProfileName then
                UIRef.ProfileNameBox:Set(AICProfile.S.ActiveProfileName)
                if UIRef.ReachDistanceBox then
                    UIRef.ReachDistanceBox:Set(tostring(Runtime:GetPlaceConfig().REACH_DISTANCE or 5))
                end
                if UIRef.FarmRadiusSlider then
                    UIRef.FarmRadiusSlider:Set((Runtime:GetPlaceConfig().FARM_ZONES[1] and Runtime:GetPlaceConfig().FARM_ZONES[1].Radius) or 100, true)
                end
                if UIRef.DeadzoneRadiusSlider then
                    UIRef.DeadzoneRadiusSlider:Set((Runtime:GetPlaceConfig().DEADZONES[1] and Runtime:GetPlaceConfig().DEADZONES[1].Radius) or 35, true)
                end
                AICUI.RefreshWaypointList()
                AICUI.RefreshFarmZoneList()
                AICUI.RefreshDeadzoneList()
                if UIRef.PriorityComponent then
                    UIRef.PriorityComponent:SetPriority(table.clone(CONFIG.TARGET_ENTITY_PRIORITY))
                    CONFIG.TARGET_ENTITY_PRIORITY = UIRef.PriorityComponent.Priority
                end
                AICUI.updateFeatureButtons()
                AICUI.RefreshTargetDropdown()
                AICDebug.UpdateDebugVisualizer()
            end

            AICUI.RefreshProfileDropdown()
            if AICProfile.S.ActiveProfileName and UIRef.ProfileDropdown then
                UIRef.ProfileDropdown:Set(AICProfile.S.ActiveProfileName, true)
                AICUI.SetProfileStatus("AUTO LOADED " .. AICProfile.S.ActiveProfileName)
            end
        end

        return Module
    end,
}
