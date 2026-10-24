return {
    Name = "Deadzone",
    IsFeature = true,
    Dependencies = {"Runtime", "ProfileManager", "ProfileSettings", "CombatUtils", "Components"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local PlayerGui = Context.PlayerGui
        local Replicated = Services.Replicated
        local StarterGui = Services.StarterGui
        local RunService = Services.RunService
        local PathfindingService = Services.PathfindingService
        local HttpService = Services.HttpService
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICConfig = Context.AICConfig
        local AICProfile = Context.AICProfile
        local AICCombatUtils = Context.AICCombatUtils
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local UI = Context.UI
        local PatrolState = Context.PatrolState
        local MiningFeature = Context.MiningFeature
        local NotifyAction = Context.NotifyAction

        local Feature = {
            Name = "Deadzone",
            IsFeature = true,
        }
        function Feature.GetDeadzoneEscapePosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil
            end
        
            local now = os.clock()
        
            if AICFeature.S.DeadzoneEscapePosition
                and now - AICFeature.S.LastDeadzoneEscapeTime < CONFIG.DEADZONE_ESCAPE_INTERVAL
            then
                return AICFeature.S.DeadzoneEscapePosition
            end
        
            AICFeature.S.LastDeadzoneEscapeTime = now
            AICFeature.S.DeadzoneEscapePosition = nil
        
        
            local Origin = RootPart.Position
            local Fallback = nil

            for Index = 1, CONFIG.DEADZONE_ESCAPE_DIRECTIONS do
                local Angle = (Index / CONFIG.DEADZONE_ESCAPE_DIRECTIONS) * math.pi * 2

                local Direction = Vector3.new(
                    math.cos(Angle),
                    0,
                    math.sin(Angle)
                )

                local Candidate = Origin + Direction * CONFIG.DEADZONE_ESCAPE_DISTANCE

                if AICCombatUtils.IsEscapePathClear(Candidate) then
                    --// Prefer a spot that is back on farm ground. Escaping out of
                    --// the farm zone just hands the character to Return To Farm
                    --// Zone, which can walk it straight back in.
                    if AICCombatUtils.IsInsideFarmArea(Candidate)
                        and not AICCombatUtils.IsInsideFarmDeadzone(Candidate)
                    then
                        AICFeature.S.DeadzoneEscapePosition = Candidate
                        return Candidate
                    end

                    Fallback = Fallback or Candidate
                end
            end

            if Fallback then
                AICFeature.S.DeadzoneEscapePosition = Fallback
                return Fallback
            end
        
            return nil
        end
        function Feature.HandleDeadzoneEscape()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if FeatureState.IgnoreFarmZone.Enabled then
                AICFeature.S.DeadzoneEscapePosition = nil
        
                return false
            end
        
            if not RootPart or not Humanoid then
                return false
            end
        
            if not AICCombatUtils.IsInsideFarmDeadzone(RootPart.Position) then
                AICFeature.S.DeadzoneEscapePosition = nil
        
        
                return false
            end
        
            local EscapePosition = AICFeature.GetDeadzoneEscapePosition()
        
            if EscapePosition then
                Humanoid:MoveTo(EscapePosition)
                return true
            end
        
            return false
        end
        
        
        
        ------------------------------------------------------------------------
        --// AICUI
        --//
        --// tabs, controls, status readouts
        --//
        --// 26 function(s). Definitions only; nothing here runs
        --// at load time.
        ------------------------------------------------------------------------
        
        ------------------------------------------------------------------------
        --// AICUI  ::  tabs, controls, status readouts
        --// 25 function(s)
        ------------------------------------------------------------------------

        AICFeature.GetDeadzoneEscapePosition = function(...) return Feature.GetDeadzoneEscapePosition(...) end
        AICFeature.HandleDeadzoneEscape = function(...) return Feature.HandleDeadzoneEscape(...) end

        ------------------------------------------------------------------------
        --// Deadzone editor (Profile Settings tab)
        --//
        --// ProfileSettings and AICUI.RefreshDeadzonePicker both expect these
        --// controls to exist, so a missing one errors on every profile load.
        ------------------------------------------------------------------------
        local function GetRootPart()
            local _, _, RootPart = Runtime:GetCharacter()
            return RootPart
        end

        local function GetDeadzones()
            return Runtime:GetPlaceConfig().DEADZONES
        end

        local function FindDeadzoneIndex(Label)
            return table.find(AICUI.BuildZoneLabels(GetDeadzones(), "Deadzone"), Label)
        end

        UIRef.DeadzoneSection = UIRef.ProfileTab:AddSection("Deadzone")

        UIRef.DeadzoneRadiusSlider = UIRef.DeadzoneSection:AddSlider(
            "Deadzone Radius",
            35,
            1,
            250,
            function(Value)
                local Zone = GetDeadzones()[AICProfile.S.SelectedDeadzoneIndex]

                if not Zone or not AICProfile.S.ActiveProfileName then
                    return
                end

                Zone.Radius = Value
                AICUI.RefreshDeadzoneList()
                AICDebug.UpdateDebugVisualizer()
                AICProfile.QueueProfileSave()
            end
        )

        UIRef.DeadzoneSection:AddButton("Add Deadzone Here", function()
            local RootPart = GetRootPart()

            if not RootPart then
                AICUI.SetProfileStatus("CHARACTER NOT READY")
                return
            end

            if not AICProfile.S.ActiveProfileName then
                AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
                return
            end

            table.insert(GetDeadzones(), {
                Center = AICConfig.RoundVector3(RootPart.Position),
                Radius = UIRef.DeadzoneRadiusSlider:Get(),
            })

            Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
            AICUI.RefreshDeadzoneList()
            AICProfile.S.SelectedDeadzoneIndex = #GetDeadzones()
            AICUI.RefreshDeadzonePicker()
            AICProfile.SaveActiveProfile()
            AICDebug.UpdateDebugVisualizer()
            AICUI.SetProfileStatus("DEADZONE ADDED #" .. tostring(#GetDeadzones()))
        end)

        UIRef.DeadzoneSection:AddButton("Clear Deadzones", function()
            if not AICProfile.S.ActiveProfileName then
                AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
                return
            end

            table.clear(GetDeadzones())
            Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
            AICProfile.S.SelectedDeadzoneIndex = 1
            AICUI.RefreshDeadzoneList()
            AICUI.RefreshDeadzonePicker()
            AICProfile.SaveActiveProfile()
            AICDebug.UpdateDebugVisualizer()
            AICUI.SetProfileStatus("DEADZONES CLEARED")
            NotifyAction("Deadzone", "Cleared all deadzones")
        end)

        UIRef.DeadzoneListComponent = UIRef.DeadzoneSection:AddPriority(
            "All Deadzones",
            AICUI.BuildZoneLabels(GetDeadzones(), "Deadzone")
        )

        AICUI.S.OriginalDeadzoneMoveUp = UIRef.DeadzoneListComponent.MoveUp
        AICUI.S.OriginalDeadzoneMoveDown = UIRef.DeadzoneListComponent.MoveDown
        AICUI.S.OriginalDeadzoneRemove = UIRef.DeadzoneListComponent.Remove
        AICUI.RefreshDeadzonePicker()

        function UIRef.DeadzoneListComponent:MoveUp(Label)
            if not AICProfile.S.ActiveProfileName then
                AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                return
            end

            local Deadzones = GetDeadzones()
            local Index = FindDeadzoneIndex(Label)

            if Index and Index > 1 then
                Deadzones[Index], Deadzones[Index - 1] = Deadzones[Index - 1], Deadzones[Index]
                AICUI.S.OriginalDeadzoneMoveUp(self, Label)
                AICUI.RefreshDeadzoneList()
                AICProfile.S.SelectedDeadzoneIndex = math.max(1, Index - 1)
                AICUI.RefreshDeadzonePicker()
                AICProfile.SaveActiveProfile()
                AICDebug.UpdateDebugVisualizer()
                AICUI.SetProfileStatus("DEADZONE MOVED UP")
                NotifyAction("Deadzone", "Moved up")
            end
        end

        function UIRef.DeadzoneListComponent:MoveDown(Label)
            if not AICProfile.S.ActiveProfileName then
                AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                return
            end

            local Deadzones = GetDeadzones()
            local Index = FindDeadzoneIndex(Label)

            if Index and Index < #Deadzones then
                Deadzones[Index], Deadzones[Index + 1] = Deadzones[Index + 1], Deadzones[Index]
                AICUI.S.OriginalDeadzoneMoveDown(self, Label)
                AICUI.RefreshDeadzoneList()
                AICProfile.S.SelectedDeadzoneIndex = math.min(#Deadzones, Index + 1)
                AICUI.RefreshDeadzonePicker()
                AICProfile.SaveActiveProfile()
                AICDebug.UpdateDebugVisualizer()
                AICUI.SetProfileStatus("DEADZONE MOVED DOWN")
                NotifyAction("Deadzone", "Moved down")
            end
        end

        function UIRef.DeadzoneListComponent:Remove(Label)
            if not AICProfile.S.ActiveProfileName then
                AICUI.SetProfileStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                return
            end

            local Index = FindDeadzoneIndex(Label)

            if Index then
                table.remove(GetDeadzones(), Index)
                AICUI.S.OriginalDeadzoneRemove(self, Label)
                Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
                AICProfile.S.SelectedDeadzoneIndex = math.clamp(Index, 1, math.max(1, #GetDeadzones()))
                AICUI.RefreshDeadzoneList()
                AICUI.RefreshDeadzonePicker()
                AICProfile.SaveActiveProfile()
                AICDebug.UpdateDebugVisualizer()
                AICUI.SetProfileStatus("DEADZONE REMOVED #" .. tostring(Index))
            end
        end

        return Feature
    end,
}
