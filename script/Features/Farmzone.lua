return {
    Name = "Farmzone",
    Dependencies = {"Runtime", "ProfileManager", "ProfileSettings", "Components"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local CONFIG = Context.CONFIG
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local AICConfig = Context.AICConfig
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

        local Module = {Name = "Farmzone", IsFeature = true}
        UIRef.FarmzoneSection = UIRef.ProfileTab:AddSection("Farmzone")
        UIRef.FarmzoneSection = UIRef.FarmzoneSection

UIRef.FarmRadiusSlider = UIRef.FarmzoneSection:AddSlider(
    "Farm Radius",
    100,
    1,
    500,
    function(Value)
        local Zone = Runtime:GetPlaceConfig() and Runtime:GetPlaceConfig().FARM_ZONES
            and Runtime:GetPlaceConfig().FARM_ZONES[AICProfile.S.SelectedFarmZoneIndex]

        if not Zone or not AICProfile.S.ActiveProfileName then return end

        Zone.Radius = Value
        AICUI.RefreshFarmZoneList()
        AICDebug.UpdateDebugVisualizer()
        AICProfile.QueueProfileSave()
    end
)



UIRef.FarmzoneSection:AddButton("Add Farm Zone Here", function()
    if not GetRootPart() then
        AICUI.SetProfileStatus("CHARACTER NOT READY")
        return
    end

    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
        return
    end

    local Radius = UIRef.FarmRadiusSlider:Get()

    table.insert(Runtime:GetPlaceConfig().FARM_ZONES, {
        Center = AICConfig.RoundVector3(GetRootPart().Position),
        Radius = Radius,
    })

    Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
    AICUI.RefreshFarmZoneList()
    AICProfile.S.SelectedFarmZoneIndex = #Runtime:GetPlaceConfig().FARM_ZONES
    AICUI.RefreshFarmZonePicker()
    AICProfile.SaveActiveProfile()
    AICDebug.UpdateDebugVisualizer()
    AICUI.SetProfileStatus("FARM ZONE ADDED #" .. tostring(#Runtime:GetPlaceConfig().FARM_ZONES))
end)


UIRef.FarmzoneSection:AddButton("Clear Farm Zones", function()
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
        return
    end

    table.clear(Runtime:GetPlaceConfig().FARM_ZONES)
    Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
    AICProfile.S.SelectedFarmZoneIndex = 1
    AICUI.RefreshFarmZoneList()
    AICUI.RefreshFarmZonePicker()
    AICProfile.SaveActiveProfile()
    AICDebug.UpdateDebugVisualizer()
    AICUI.SetProfileStatus("FARM ZONES CLEARED")
    NotifyAction("Farm Zone", "Cleared all farm zones")
end)

UIRef.FarmZoneListComponent = UIRef.FarmzoneSection:AddPriority(
    "All Farm Zones",
    AICUI.BuildZoneLabels(Runtime:GetPlaceConfig().FARM_ZONES, "Farm")
)


AICUI.S.OriginalFarmZoneMoveUp = UIRef.FarmZoneListComponent.MoveUp
AICUI.S.OriginalFarmZoneMoveDown = UIRef.FarmZoneListComponent.MoveDown
AICUI.S.OriginalFarmZoneRemove = UIRef.FarmZoneListComponent.Remove
AICUI.RefreshFarmZonePicker()


function UIRef.FarmZoneListComponent:MoveUp(Label)
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
        return
    end

    local Index = table.find(AICUI.BuildZoneLabels(Runtime:GetPlaceConfig().FARM_ZONES, "Farm"), Label)

    if Index and Index > 1 then
        Runtime:GetPlaceConfig().FARM_ZONES[Index], Runtime:GetPlaceConfig().FARM_ZONES[Index - 1] =
            Runtime:GetPlaceConfig().FARM_ZONES[Index - 1], Runtime:GetPlaceConfig().FARM_ZONES[Index]
        --// Waypoints paired with these two zones follow them.
        AICConfig.RemapWaypointZones(Runtime:GetPlaceConfig(), function(Z)
            return (Z == Index and Index - 1) or (Z == Index - 1 and Index) or Z
        end)
        AICUI.S.OriginalFarmZoneMoveUp(self, Label)
        AICUI.RefreshFarmZoneList()
        AICProfile.S.SelectedFarmZoneIndex = math.max(1, Index - 1)
        AICUI.RefreshFarmZonePicker()
        AICProfile.SaveActiveProfile()
        AICDebug.UpdateDebugVisualizer()
        AICUI.SetProfileStatus("FARM ZONE MOVED UP")
        NotifyAction("Farm Zone", "Moved up")
    end
end

function UIRef.FarmZoneListComponent:MoveDown(Label)
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
        return
    end

    local Index = table.find(AICUI.BuildZoneLabels(Runtime:GetPlaceConfig().FARM_ZONES, "Farm"), Label)

    if Index and Index < #Runtime:GetPlaceConfig().FARM_ZONES then
        Runtime:GetPlaceConfig().FARM_ZONES[Index], Runtime:GetPlaceConfig().FARM_ZONES[Index + 1] =
            Runtime:GetPlaceConfig().FARM_ZONES[Index + 1], Runtime:GetPlaceConfig().FARM_ZONES[Index]
        AICConfig.RemapWaypointZones(Runtime:GetPlaceConfig(), function(Z)
            return (Z == Index and Index + 1) or (Z == Index + 1 and Index) or Z
        end)
        AICUI.S.OriginalFarmZoneMoveDown(self, Label)
        AICUI.RefreshFarmZoneList()
        AICProfile.S.SelectedFarmZoneIndex = math.min(#Runtime:GetPlaceConfig().FARM_ZONES, Index + 1)
        AICUI.RefreshFarmZonePicker()
        AICProfile.SaveActiveProfile()
        AICDebug.UpdateDebugVisualizer()
        AICUI.SetProfileStatus("FARM ZONE MOVED DOWN")
        NotifyAction("Farm Zone", "Moved down")
    end
end

function UIRef.FarmZoneListComponent:Remove(Label)
    if not AICProfile.S.ActiveProfileName then
        AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
        return
    end

    local Index = table.find(AICUI.BuildZoneLabels(Runtime:GetPlaceConfig().FARM_ZONES, "Farm"), Label)

    if Index then
        table.remove(Runtime:GetPlaceConfig().FARM_ZONES, Index)
        --// Waypoints paired with the removed zone lose their pair; later
        --// zones shift down by one.
        AICConfig.RemapWaypointZones(Runtime:GetPlaceConfig(), function(Z)
            return (Z == Index and 0) or (Z > Index and Z - 1) or Z
        end)
        AICUI.S.OriginalFarmZoneRemove(self, Label)
        Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
        AICProfile.S.SelectedFarmZoneIndex = math.clamp(Index, 1, math.max(1, #Runtime:GetPlaceConfig().FARM_ZONES))
        AICUI.RefreshFarmZoneList()
        AICUI.RefreshFarmZonePicker()
        AICProfile.SaveActiveProfile()
        AICDebug.UpdateDebugVisualizer()
        AICUI.SetProfileStatus("FARM ZONE REMOVED #" .. tostring(Index))
    end
end

        return Module
    end,
}
