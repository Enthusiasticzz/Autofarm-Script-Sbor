return {
    Name = "ReturnToFarmZone",
    IsFeature = true,
    Dependencies = {"Runtime", "CombatUtils", "ProfileManager"},
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
            Name = "ReturnToFarmZone",
            IsFeature = true,
        }
        function Feature.GetFarmReturnPosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if not RootPart or FeatureState.IgnoreFarmZone.Enabled or not PlaceConfig then
                return nil
            end
        
            local now = os.clock()
        
            if AICFeature.S.FarmReturnPosition
                and now - AICFeature.S.LastFarmReturnCalculateTime < CONFIG.FARM_RETURN_RECALCULATE_INTERVAL
            then
                return AICFeature.S.FarmReturnPosition
            end
        
            AICFeature.S.LastFarmReturnCalculateTime = now
            local PreviousReturnPosition = AICFeature.S.FarmReturnPosition
            AICFeature.S.FarmReturnPosition = nil
        
            local ActiveZone = AICCombatUtils.GetActiveFarmZone()
            local FarmCenter = (ActiveZone and ActiveZone.Center) or RootPart.Position
            local Origin = RootPart.Position
            local Candidates = {}
        
            --// Return to a randomized point 10-20 studs away from the farm center.
            --// This prevents the character from repeatedly standing on the same spot.
            for Index = 1, CONFIG.FARM_RETURN_CANDIDATES do
                local Angle = math.random() * math.pi * 2
                local Radius = CONFIG.FARM_RETURN_RADIUS_MIN
                    + math.random() * (CONFIG.FARM_RETURN_RADIUS_MAX - CONFIG.FARM_RETURN_RADIUS_MIN)
                local Offset = Vector3.new(
                    math.cos(Angle) * Radius,
                    0,
                    math.sin(Angle) * Radius
                )
        
                local Candidate = AICCombatUtils.GetPatrolGroundPosition(FarmCenter + Offset)
        
                if Candidate
                    and AICCombatUtils.IsInsideFarmArea(Candidate)
                    and not AICCombatUtils.IsInsideFarmDeadzone(Candidate)
                then
                    table.insert(Candidates, Candidate)
                end
            end
        
            if #Candidates > 0 then
                --// Prefer a point that is not almost identical to the previous return spot.
                local Filtered = {}
                for _, Candidate in ipairs(Candidates) do
                    if not PreviousReturnPosition
                        or (Candidate - PreviousReturnPosition).Magnitude >= CONFIG.FARM_RETURN_MIN_SPREAD
                    then
                        table.insert(Filtered, Candidate)
                    end
                end
        
                if #Filtered > 0 then
                    Candidates = Filtered
                end
        
                AICFeature.S.FarmReturnPosition = Candidates[math.random(1, #Candidates)]
                return AICFeature.S.FarmReturnPosition
            end
        
            return nil
        end
        function Feature.MoveBackToFarmZone()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
        local FaceOrientation = Runtime:GetFaceOrientation()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if not FeatureState.ReturnToFarmZone.Enabled or not RootPart or not Humanoid then
                AICFeature.S.FarmReturnPosition = nil
                return false
            end
        
            if FeatureState.IgnoreFarmZone.Enabled then
                AICFeature.S.FarmReturnPosition = nil
                return false
            end
        
            local ActiveZone = AICCombatUtils.GetActiveFarmZone()
            local FarmCenter = (ActiveZone and ActiveZone.Center) or RootPart.Position
            local CenterOffset = RootPart.Position - FarmCenter
            local CenterDistance = Vector3.new(CenterOffset.X, 0, CenterOffset.Z).Magnitude
        
            --// Stop returning once we are close enough to the farm centre.
            if CenterDistance <= CONFIG.FARM_RETURN_CENTER_DISTANCE then
                AICFeature.S.FarmReturnPosition = nil
                AICFeature.S.LastFarmReturnCalculateTime = 0
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            --// No sampled point inside the zone passed its checks. Heading for the
            --// centre is still better than the old answer, which was to stand
            --// outside the zone doing nothing.
            local Position = AICFeature.GetFarmReturnPosition() or FarmCenter
        
            local Offset = Position - RootPart.Position
            local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
            if Distance <= CONFIG.FARM_RETURN_ARRIVAL_DISTANCE then
                AICFeature.S.FarmReturnPosition = nil
                AICFeature.S.LastFarmReturnCalculateTime = 0
                return false
            end
        
            --// The facing constraint is nil until AutoFarming makes one and again
            --// for a frame after every respawn, so setting it is optional.
            if FaceOrientation then
                FaceOrientation.Enabled = false
            end
        
            --// Straight line first, since it is free. If something is in the way,
            --// route around it rather than pressing into the obstacle.
            if AICCombatUtils.IsPathClear(Position) then
                Humanoid.AutoRotate = true
                Humanoid:MoveTo(Position)
                return true
            end
        
            if CenterDistance <= CONFIG.FARM_RETURN_PATH_DISTANCE
                and AICCombat.MoveAlongPathTo(Position, true)
            then
                return true
            end
        
            --// Pathfinding refused as well. Keep walking at the target anyway; the
            --// stuck check and the jump will usually free the character.
            Humanoid.AutoRotate = true
            Humanoid:MoveTo(Position)
            return true
        end

        AICFeature.GetFarmReturnPosition = function(...) return Feature.GetFarmReturnPosition(...) end
        AICFeature.MoveBackToFarmZone = function(...) return Feature.MoveBackToFarmZone(...) end

        function Feature:SetEnabled(Value)
            self.Enabled = Value == true
            if FeatureState.ReturnToFarmZone then
                FeatureState.ReturnToFarmZone.Enabled = self.Enabled
            end
        end

        function Feature:CreateUI()
            if UIRef.FeatureSection and UIRef.FeatureSection.AddToggle then
                --// Defaults to on. Without this the toggle drew as off while the
                --// return logic was actually running.
                self.Enabled = FeatureState.ReturnToFarmZone.Enabled == true
                self.Button = UIRef.FeatureSection:AddToggle{
                    Name = "Return To Farm Zone",
                    Default = self.Enabled,
                    Callback = function(Value)
                        self:SetEnabled(Value)

                        AICFeature.S.FarmReturnPosition = nil
                        AICFeature.S.LastFarmReturnCalculateTime = 0
                        AICProfile.SaveActiveProfile()
                    end,
                }
                FeatureState.ReturnToFarmZone.Button = self.Button
            end
        end

        function Feature:Update()
        end

        Feature:CreateUI()

        return Feature
    end,
}
