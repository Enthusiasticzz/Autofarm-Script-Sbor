return {
    Name = "CombatUtils",
    Dependencies = {"Runtime"},
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

        local Module = Context.AICCombatUtils
        function AICCombatUtils.UpdateStuckTracker(now, IsMoving)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return
            end
        
            if not IsMoving then
                AICCombatUtils.S.StuckSamplePosition = nil
                AICCombatUtils.S.StuckStrikes = 0
                return
            end
        
            if now - AICCombatUtils.S.StuckSampleTime < (tonumber(CONFIG.STUCK_SAMPLE_INTERVAL) or 0.35) then
                return
            end
        
            AICCombatUtils.S.StuckSampleTime = now
        
            if AICCombatUtils.S.StuckSamplePosition then
                local Moved = (RootPart.Position - AICCombatUtils.S.StuckSamplePosition).Magnitude
        
                if Moved < (tonumber(CONFIG.STUCK_MIN_PROGRESS) or 0.6) then
                    AICCombatUtils.S.StuckStrikes += 1
                else
                    AICCombatUtils.S.StuckStrikes = 0
                end
            end
        
            AICCombatUtils.S.StuckSamplePosition = RootPart.Position
        end
        function AICCombatUtils.IsStuck()
            return AICCombatUtils.S.StuckStrikes >= 2
        end
        --// Called once a stuck has been acted on, so the same stall is not
        --// reported again before the new movement had a chance to work.
        function AICCombatUtils.ResetStuckTracker()
            AICCombatUtils.S.StuckSamplePosition = nil
            AICCombatUtils.S.StuckStrikes = 0
        end

        --// A short sidestep out of a corner. Probes at body height around the
        --// heading to Destination and keeps the most open direction that still
        --// lands on allowed ground. Directions closer to the heading win ties,
        --// and the preferred side alternates per call so two attempts in a
        --// row do not both bounce off the same wall.
        local UNSTICK_ANGLES = { 60, 90, 120, 150, 180 }

        function AICCombatUtils.GetUnstickPosition(Destination)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Destination then
                return nil
            end

            local Offset = Destination - RootPart.Position
            local Heading = Vector3.new(Offset.X, 0, Offset.Z)
            Heading = Heading.Magnitude > 0.01 and Heading.Unit or RootPart.CFrame.LookVector

            local Probe = tonumber(CONFIG.UNSTICK_PROBE_DISTANCE) or 9
            local MinFree = tonumber(CONFIG.UNSTICK_MIN_FREE) or 3

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = { Character, AICCombatUtils.S.DebugFolder }

            AICCombatUtils.S.UnstickSide = -(AICCombatUtils.S.UnstickSide or 1)

            local BestPosition, BestFree = nil, MinFree

            for _, Angle in ipairs(UNSTICK_ANGLES) do
                for _, Sign in ipairs({ AICCombatUtils.S.UnstickSide, -AICCombatUtils.S.UnstickSide }) do
                    local Radians = math.rad(Angle * Sign)
                    local Direction = (CFrame.Angles(0, Radians, 0) * CFrame.lookAt(Vector3.zero, Heading)).LookVector
                    local Hit = workspace:Raycast(RootPart.Position, Direction * Probe, Params)
                    local Free = Hit and (Hit.Position - RootPart.Position).Magnitude - 1.5 or Probe
                    local Candidate = RootPart.Position + Direction * Free

                    if Free > BestFree
                        and AICCombatUtils.IsInsideFarmArea(Candidate)
                        and not AICCombatUtils.IsInsideFarmDeadzone(Candidate)
                    then
                        BestFree = Free
                        BestPosition = Candidate
                    end

                    if Angle == 180 then
                        break
                    end
                end

                --// Something clearly open close to the heading beats a wider
                --// gap that sends the character backwards.
                if BestFree >= Probe * 0.8 then
                    break
                end
            end

            return BestPosition
        end

        --// Water is read from the terrain voxels, not a downward ray: the ray
        --// stops at the surface, so it cannot tell a swimmer from someone
        --// standing on a dock, and it reports nothing for a diver below it.
        function AICCombatUtils.IsPointInWater(Position)
            if not Position then
                return false
            end

            local Terrain = workspace.Terrain
            local Half = Vector3.new(2, 2, 2)
            local Region = Region3.new(Position - Half, Position + Half):ExpandToGrid(4)

            local Ok, Materials, Occupancies = pcall(function()
                return Terrain:ReadVoxels(Region, 4)
            end)

            if not Ok or not Materials then
                return false
            end

            local Size = Materials.Size

            for X = 1, Size.X do
                for Y = 1, Size.Y do
                    for Z = 1, Size.Z do
                        if Materials[X][Y][Z] == Enum.Material.Water
                            and Occupancies[X][Y][Z] > 0
                        then
                            return true
                        end
                    end
                end
            end

            return false
        end

        function AICCombatUtils.IsHumanoidSwimming(Humanoid)
            return Humanoid ~= nil
                and Humanoid:GetState() == Enum.HumanoidStateType.Swimming
        end

        --// A character counts as in the water while swimming or while its root
        --// sits in a water voxel. Another player's state is not always
        --// replicated, so the voxel test is what finds a diver.
        --// Asked several times per frame for the same target, so the voxel
        --// read is reused for a moment. Weak keys let dead models go.
        local WATER_CACHE_INTERVAL = 0.1
        AICCombatUtils.S.WaterModelCache = setmetatable({}, { __mode = "k" })

        function AICCombatUtils.IsModelInWater(Model)
            local ModelRoot = Model and Model:FindFirstChild("HumanoidRootPart")

            if not ModelRoot then
                return false
            end

            local now = os.clock()
            local Cached = AICCombatUtils.S.WaterModelCache[Model]

            if Cached and now - Cached.Time < WATER_CACHE_INTERVAL then
                return Cached.Value
            end

            local Value = AICCombatUtils.IsHumanoidSwimming(Model:FindFirstChildOfClass("Humanoid"))
                or AICCombatUtils.IsPointInWater(ModelRoot.Position)

            AICCombatUtils.S.WaterModelCache[Model] = { Time = now, Value = Value }
            return Value
        end

        function AICCombatUtils.IsSelfSwimming()
            local Character, Humanoid = Runtime:GetCharacter()
            return AICCombatUtils.IsHumanoidSwimming(Humanoid)
        end
        function AICCombatUtils.DoJumpIfObstacle(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Humanoid then
                return false
            end
        
            if not AICCombatUtils.IsJumpableObstacleAhead(TargetPosition) then
                return false
            end
        
            AICCombatUtils.DoJump()
            return true
        end
        function AICCombatUtils.DoJump()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Humanoid then
                return
            end
        
            if Humanoid.FloorMaterial ~= Enum.Material.Air
                and Humanoid:GetState() ~= Enum.HumanoidStateType.Jumping
            then
                Humanoid.Jump = true
                Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end

        --// Jump While Fighting. Off, nothing that moves the character towards,
        --// away from or around a target leaves the ground: mobs and other
        --// bodies crowding in were read as low terrain, which hopped the
        --// character at the fight every frame. The waypoint route (route holes
        --// and ticked waypoints), Waypoint Loop, patrol, mining and smithing
        --// jumps are their own and keep working.
        function AICCombatUtils.IsCombatJumpingEnabled()
            local State = FeatureState.JumpWhileFighting
            return State == nil or State.Enabled == true
        end

        function AICCombatUtils.DoCombatJump()
            if not AICCombatUtils.IsCombatJumpingEnabled() then
                return false
            end

            AICCombatUtils.DoJump()
            return true
        end

        function AICCombatUtils.DoCombatJumpIfObstacle(TargetPosition)
            if not AICCombatUtils.IsCombatJumpingEnabled() then
                return false
            end

            return AICCombatUtils.DoJumpIfObstacle(TargetPosition)
        end
        
        ------------------------------------------------------------------------
        --// AICWorld  ::  zones, water, ground, line of sight, path clearance
        --// 12 function(s)
        ------------------------------------------------------------------------
        --// Farm Area Check
        --// Shared cylinder test for farm zones and deadzones.
        function AICCombatUtils.IsPositionInsideZone(Position, Zone)
            if not Position or not Zone or not Zone.Center then
                return false
            end
        
            local Offset = Position - Zone.Center
            local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
            if Distance > (tonumber(Zone.Radius) or 0) then
                return false
            end
        
            local MaxHeight = tonumber(CONFIG.ZONE_MAX_HEIGHT_DIFFERENCE) or 0
        
            if MaxHeight > 0 and math.abs(Offset.Y) > MaxHeight then
                return false
            end
        
            return true
        end
        function AICCombatUtils.IsInsideFarmDeadzone(Position)
            local PlaceConfig = Runtime:GetPlaceConfig()
            if not Position or not PlaceConfig then
                return false
            end
        
            for _, Zone in ipairs(PlaceConfig.DEADZONES or {}) do
                if AICCombatUtils.IsPositionInsideZone(Position, Zone) then
                    return true
                end
            end
        
            return false
        end
        --// The waypoint loop fights one paired zone at a time. While it does,
        --// every farm-area check, return point and patrol uses only that zone.
        AICCombatUtils.S.ActiveZoneIndex = nil

        function AICCombatUtils.GetActiveFarmZone()
            local PlaceConfig = Runtime:GetPlaceConfig()
            local FarmZones = PlaceConfig and PlaceConfig.FARM_ZONES or {}
            local Active = AICCombatUtils.S.ActiveZoneIndex

            return (Active and FarmZones[Active]) or FarmZones[1]
        end

        function AICCombatUtils.IsInsideFarmArea(Position)
            local PlaceConfig = Runtime:GetPlaceConfig()
            if FeatureState.IgnoreFarmZone.Enabled or not PlaceConfig then
                return true
            end
        
            if not Position then
                return false
            end

            --// Set only while a skill dodge runs on the waypoint route. The
            --// route crosses ground outside every farm zone, and requiring a
            --// dodge spot inside one left nowhere to go, so the character
            --// stood in the skill. Deadzones still apply.
            if AICCombatUtils.S.DodgeOffRoute then
                return not AICCombatUtils.IsInsideFarmDeadzone(Position)
            end

            local FarmZones = PlaceConfig.FARM_ZONES or {}
            local ActiveZone = AICCombatUtils.S.ActiveZoneIndex and FarmZones[AICCombatUtils.S.ActiveZoneIndex]

            if ActiveZone then
                FarmZones = { ActiveZone }
            end
        
            --// No farm zones means the profile does not constrain the farm area.
            --// Deadzones can still be used independently.
            if #FarmZones == 0 then
                return not AICCombatUtils.IsInsideFarmDeadzone(Position)
            end
        
            local InsideAnyFarmZone = false
        
            for _, Zone in ipairs(FarmZones) do
                if AICCombatUtils.IsPositionInsideZone(Position, Zone) then
                    InsideAnyFarmZone = true
                    break
                end
            end
        
            if not InsideAnyFarmZone then
                return false
            end
        
            return not AICCombatUtils.IsInsideFarmDeadzone(Position)
        end

        --// Inside any mine zone. Deadzones are checked separately, so a
        --// caller can tell "outside the mine" from "in a deadzone".
        function AICCombatUtils.IsInsideMineZone(Position)
            local PlaceConfig = Runtime:GetPlaceConfig()

            if not Position or not PlaceConfig then
                return false
            end

            for _, Zone in ipairs(PlaceConfig.MINE_ZONES or {}) do
                if AICCombatUtils.IsPositionInsideZone(Position, Zone) then
                    return true
                end
            end

            return false
        end

        --// Water Check
        function AICCombatUtils.IsWaterAtPosition(Position, IgnoreModel)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Position then
                return false
            end
        
            local FilterInstances = {
                Character,
            }
        
            if IgnoreModel then
                table.insert(FilterInstances, IgnoreModel)
            end
            if AICCombatUtils.S.DebugFolder then
                table.insert(FilterInstances, AICCombatUtils.S.DebugFolder)
            end
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = FilterInstances
        
            local Origin    = Position + Vector3.new(0, 10, 0)
            local Direction = Vector3.new(0, -30, 0)
        
            local Result = workspace:Raycast(Origin, Direction, RaycastParams)
        
            return Result and Result.Material == Enum.Material.Water
        end
        function AICCombatUtils.IsPathThroughWater(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return true
            end
        
            local Origin   = RootPart.Position
            local Offset   = TargetPosition - Origin
            local Distance = Offset.Magnitude
        
            if Distance <= 0 then
                return AICCombatUtils.IsWaterAtPosition(TargetPosition)
            end
        
            local Direction = Offset.Unit
        
            for DistanceTravelled = 0, Distance, CONFIG.WATER_SAMPLE_DISTANCE do
                local Position = Origin + Direction * DistanceTravelled
        
                if AICCombatUtils.IsWaterAtPosition(Position) then
                    return true
                end
            end
        
            return AICCombatUtils.IsWaterAtPosition(TargetPosition)
        end
        
        --// Deadzone Path Check
        function AICCombatUtils.IsPathThroughDeadzone(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if FeatureState.IgnoreFarmZone.Enabled then
                return false
            end
        
            if not RootPart or not TargetPosition or not PlaceConfig then
                return false
            end
        
            local Origin   = RootPart.Position
            local Offset   = TargetPosition - Origin
            local Distance = Offset.Magnitude
        
            if Distance <= 0 then
                return AICCombatUtils.IsInsideFarmDeadzone(Origin)
            end
        
            local Direction = Offset.Unit
        
            for DistanceTravelled = 0, Distance, CONFIG.DEADZONE_SAMPLE_DISTANCE do
                local Position = Origin + Direction * DistanceTravelled
        
                if AICCombatUtils.IsInsideFarmDeadzone(Position) then
                    return true
                end
            end
        
            return AICCombatUtils.IsInsideFarmDeadzone(TargetPosition)
        end
        
        --// Line Of Sight
        function AICCombatUtils.CanSeeGoblin(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin then
                return false
            end
        
            local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
            if not MobRoot then
                return false
            end
        
            local Origin    = RootPart.Position
            local Direction = MobRoot.Position - Origin
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {
                Character,
            }
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            --// Water is not a wall. Without this a target under the surface
            --// was "hidden" behind the water it was swimming in.
            RaycastParams.IgnoreWater = true

            local Result = workspace:Raycast(Origin, Direction, RaycastParams)

            if not Result then
                return true
            end

            return Result.Instance:IsDescendantOf(Goblin)
        end
        
        --// ============================================================
        --// COMBAT BLADE SYSTEM
        --// ============================================================
        function AICCombatUtils.GetHorizontalDistance(PositionA, PositionB)
            local Offset = PositionA - PositionB
        
            return Vector3.new(
                Offset.X,
                0,
                Offset.Z
            ).Magnitude
        end
        
        --// Retreat Obstacle Check
        function AICCombatUtils.IsPathClear(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return false
            end
        
            if AICCombatUtils.IsWaterAtPosition(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsPathThroughWater(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsPathThroughDeadzone(TargetPosition) then
                return false
            end
        
            local Origin    = RootPart.Position
            local Direction = TargetPosition - Origin
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {
                Character,
            }
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            local Result = workspace:Raycast(Origin, Direction, RaycastParams)
        
            return Result == nil
        end
        function AICCombatUtils.IsEscapePathClear(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            if not AICCombatUtils.IsInsideFarmArea(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsWaterAtPosition(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsPathThroughWater(TargetPosition) then
                return false
            end
        
            local Origin = RootPart.Position
            local Direction = TargetPosition - Origin
        
            if Direction.Magnitude <= 0.01 then
                return false
            end
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {
                Character,
            }
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            if workspace:Raycast(Origin, Direction, RaycastParams) then
                return false
            end
        
            --// Also check the character's physical width so the center point
            --// cannot pass a wall while the character body gets stuck on it.
            local BlockcastSize = Vector3.new(
                math.max(RootPart.Size.X, 2.5),
                math.max(RootPart.Size.Y, 4),
                math.max(RootPart.Size.Z, 2.5)
            )
        
            local BlockcastCFrame = CFrame.new(Origin)
            local BlockcastResult = workspace:Blockcast(
                BlockcastCFrame,
                BlockcastSize,
                Direction,
                RaycastParams
            )
        
            return BlockcastResult == nil
        end
        function AICCombatUtils.CanSeeGoblinFromPosition(Position, Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Position or not Goblin then
                return false
            end
        
            local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
            if not MobRoot then
                return false
            end
        
            local Direction = MobRoot.Position - Position
        
            if Direction.Magnitude <= 0 then
                return true
            end
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {
                Character,
                Goblin,
            }
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            local Result = workspace:Raycast(Position, Direction, RaycastParams)
        
            return Result == nil
        end
        
        --// ============================================================
        --// AUTO PATROL
        --// ============================================================
        --// True when something in the way can actually be jumped over.
        --//
        --// Two probes at different heights: a hit low down with clear space above it
        --// is a ledge, a step or a rock, and a jump clears it. A hit at both heights
        --// is a wall, where jumping achieves nothing. Nothing at either height means
        --// the path is open and there is no reason to leave the ground.
        --//
        --// Also treats ground that steps up sharply just ahead as jumpable, since a
        --// short ledge can sit below the low probe.
        --//
        --// A hit on a character is not terrain. A mob standing beside the
        --// character reads as a low ledge with clear space above it, which made
        --// it hop at the crowd it was fighting; the folder check below misses
        --// any mob kept outside `workspace.Mobs`. Walking the hit's ancestors
        --// for a Humanoid covers every character, wherever the game stores it.
        local function IsCharacterHit(Hit)
            local Part = Hit and Hit.Instance

            while Part and Part ~= workspace do
                if Part:FindFirstChildOfClass("Humanoid") then
                    return true
                end

                Part = Part.Parent
            end

            return false
        end

        function AICCombatUtils.IsJumpableObstacleAhead(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            local Origin = RootPart.Position
            local Offset = TargetPosition - Origin
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)
        
            if Flat.Magnitude <= 0.01 then
                return false
            end
        
            local Direction = Flat.Unit * (tonumber(CONFIG.JUMP_PROBE_DISTANCE) or 4.5)
        
            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            local Filter = { Character }
        
            --// Mobs and other players are not obstacles to jump over.
            local MobFolder = workspace:FindFirstChild("Mobs")
            if MobFolder then
                table.insert(Filter, MobFolder)
            end
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character and OtherPlayer.Character ~= Character then
                    table.insert(Filter, OtherPlayer.Character)
                end
            end
            if AICCombatUtils.S.DebugFolder then
                table.insert(Filter, AICCombatUtils.S.DebugFolder)
            end
            Params.FilterDescendantsInstances = Filter
        
            local HalfHeight = RootPart.Size.Y * 0.5
            local Feet = Origin - Vector3.new(0, HalfHeight, 0)
        
            local LowOrigin = Feet + Vector3.new(0, tonumber(CONFIG.JUMP_PROBE_LOW_OFFSET) or 0.6, 0)
            local HighOrigin = Feet + Vector3.new(0, tonumber(CONFIG.JUMP_PROBE_HIGH_OFFSET) or 3.2, 0)
        
            local LowHit = workspace:Raycast(LowOrigin, Direction, Params)
            local HighHit = workspace:Raycast(HighOrigin, Direction, Params)

            --// A character in the way is not something to jump over.
            if IsCharacterHit(LowHit) then
                LowHit = nil
            end

            if IsCharacterHit(HighHit) then
                HighHit = nil
            end

            if LowHit and not HighHit then
                return true
            end
        
            if LowHit and HighHit then
                --// Solid from the ground up. Jumping will not get us past it.
                return false
            end
        
            --// Nothing hit either probe. Check for a step up that both probes passed
            --// over, by sampling the ground a little way ahead.
            local AheadOrigin = Origin + Flat.Unit * (tonumber(CONFIG.JUMP_PROBE_DISTANCE) or 4.5)
            local Down = workspace:Raycast(
                AheadOrigin + Vector3.new(0, HalfHeight, 0),
                Vector3.new(0, -(HalfHeight * 2 + 6), 0),
                Params
            )
        
            --// Ground is what can be stood on; the top of a mob is not a step.
            if not Down or IsCharacterHit(Down) then
                return false
            end

            local StepUp = Down.Position.Y - Feet.Y
        
            return StepUp >= (tonumber(CONFIG.JUMP_STEP_HEIGHT) or 1.2)
        end

        --// Hole Check
        --// Samples the ground every HOLE_SAMPLE_STEP studs toward
        --// TargetPosition. Ground missing, water, or lower than the feet by
        --// more than HOLE_MAX_SAFE_DROP is a hole. Returns IsHole, CanJump and
        --// the distance to the edge. CanJump means ground comes back within
        --// the reach of a running jump, at a height that jump can land on.
        local HOLE_PROBE_DISTANCE = 6
        local HOLE_SAMPLE_STEP = 1
        local HOLE_MAX_SAFE_DROP = 6
        --// Share of the ideal jump arc counted on, for speed lost at takeoff.
        local HOLE_JUMP_SAFETY = 0.8

        local function GetGroundHeight(Position, Params)
            local Hit = workspace:Raycast(
                Position + Vector3.new(0, 4, 0),
                Vector3.new(0, -(HOLE_MAX_SAFE_DROP + 12), 0),
                Params
            )

            if not Hit or Hit.Material == Enum.Material.Water then
                return nil
            end

            return Hit.Position.Y
        end

        local function GetJumpReach(Humanoid)
            local Gravity = math.max(workspace.Gravity, 1)
            local Speed = Humanoid.UseJumpPower
                and Humanoid.JumpPower
                or math.sqrt(2 * Gravity * Humanoid.JumpHeight)

            local Rise = Speed * Speed / (2 * Gravity)
            local AirTime = 2 * Speed / Gravity

            return Humanoid.WalkSpeed * AirTime * HOLE_JUMP_SAFETY, Rise * HOLE_JUMP_SAFETY
        end

        function AICCombatUtils.IsHoleAhead(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Humanoid or not TargetPosition then
                return false, false, nil
            end

            local Offset = TargetPosition - RootPart.Position
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= HOLE_SAMPLE_STEP then
                return false, false, nil
            end

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            local Filter = { Character }
            local MobFolder = workspace:FindFirstChild("Mobs")
            if MobFolder then
                table.insert(Filter, MobFolder)
            end
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character and OtherPlayer.Character ~= Character then
                    table.insert(Filter, OtherPlayer.Character)
                end
            end
            if AICCombatUtils.S.DebugFolder then
                table.insert(Filter, AICCombatUtils.S.DebugFolder)
            end
            Params.FilterDescendantsInstances = Filter

            local Direction = Flat.Unit
            local FeetY = GetGroundHeight(RootPart.Position, Params)
                or (RootPart.Position.Y - RootPart.Size.Y * 0.5 - Humanoid.HipHeight)
            local CheckDistance = math.min(Flat.Magnitude, HOLE_PROBE_DISTANCE)
            local EdgeDistance = nil

            for Distance = HOLE_SAMPLE_STEP, CheckDistance, HOLE_SAMPLE_STEP do
                local GroundY = GetGroundHeight(RootPart.Position + Direction * Distance, Params)

                if not GroundY or FeetY - GroundY > HOLE_MAX_SAFE_DROP then
                    EdgeDistance = Distance
                    break
                end
            end

            if not EdgeDistance then
                return false, false, nil
            end

            local Reach, Rise = GetJumpReach(Humanoid)

            for Distance = EdgeDistance + HOLE_SAMPLE_STEP, EdgeDistance + Reach, HOLE_SAMPLE_STEP do
                local GroundY = GetGroundHeight(RootPart.Position + Direction * Distance, Params)

                if GroundY
                    and GroundY <= FeetY + Rise
                    and FeetY - GroundY <= HOLE_MAX_SAFE_DROP
                then
                    return true, true, EdgeDistance
                end
            end

            return true, false, EdgeDistance
        end

        --// Route Hole Jump
        --// Walking a waypoint route, a gap to jump across (parkour) was
        --// walked straight into. Samples the ground along the root's
        --// LookVector every CONFIG.ROUTE_HOLE_SAMPLE_STEP up to
        --// CONFIG.ROUTE_HOLE_PROBE_DISTANCE; missing ground, water, or
        --// ground CONFIG.ROUTE_HOLE_MIN_DEPTH or more below the feet is a
        --// hole, and the character jumps at its edge. All three are
        --// profile settings (Profile Settings > Waypoints).
        --// Only while actually walking, not standing at a waypoint.
        local ROUTE_HOLE_MIN_MOVE = 0.1

        --// The part's facing on the ground plane, unit length, or zero.
        function AICCombatUtils.GetFlatLook(Part)
            local Look = Part.CFrame.LookVector
            local Flat = Vector3.new(Look.X, 0, Look.Z)

            return Flat.Magnitude > 0.01 and Flat.Unit or Vector3.zero
        end

        function AICCombatUtils.IsRouteHoleAhead()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Humanoid or Humanoid.MoveDirection.Magnitude < ROUTE_HOLE_MIN_MOVE then
                return false
            end

            local Direction = AICCombatUtils.GetFlatLook(RootPart)

            if Direction == Vector3.zero then
                return false
            end

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            local Filter = { Character }
            local MobFolder = workspace:FindFirstChild("Mobs")
            if MobFolder then
                table.insert(Filter, MobFolder)
            end
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character and OtherPlayer.Character ~= Character then
                    table.insert(Filter, OtherPlayer.Character)
                end
            end
            if AICCombatUtils.S.DebugFolder then
                table.insert(Filter, AICCombatUtils.S.DebugFolder)
            end
            Params.FilterDescendantsInstances = Filter

            --// Already in the air (mid-jump): nothing to measure from.
            local FeetY = GetGroundHeight(RootPart.Position, Params)
            if not FeetY then
                return false
            end

            local ProbeDistance = tonumber(CONFIG.ROUTE_HOLE_PROBE_DISTANCE) or 2
            local SampleStep = math.max(tonumber(CONFIG.ROUTE_HOLE_SAMPLE_STEP) or 0.5, 0.1)
            local MinDepth = tonumber(CONFIG.ROUTE_HOLE_MIN_DEPTH) or 1

            for Distance = SampleStep, ProbeDistance, SampleStep do
                local GroundY = GetGroundHeight(RootPart.Position + Direction * Distance, Params)

                if not GroundY or FeetY - GroundY >= MinDepth then
                    return true
                end
            end

            return false
        end

        function AICCombatUtils.DoJumpIfRouteHole()
            if not AICCombatUtils.IsRouteHoleAhead() then
                return false
            end

            AICCombatUtils.DoJump()
            return true
        end
        function AICCombatUtils.GetPatrolGroundPosition(Position)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Position or not RootPart then
                return nil
            end
        
            if not AICCombatUtils.IsInsideFarmArea(Position) then
                return nil
            end
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {Character}
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            --// เพิ่มความสูงเริ่มยิงและระยะยิงให้ครอบคลุมภูมิประเทศที่สูง/ต่ำกว่าเดิมมาก
            local Origin = Vector3.new(Position.X, RootPart.Position.Y + 60, Position.Z)
            local Result = workspace:Raycast(Origin, Vector3.new(0, -250, 0), RaycastParams)
        
            if not Result then
                return nil
            end
        
            if Result.Material == Enum.Material.Water then
                return nil
            end
        
            if Result.Normal.Y < 0.5 then
                return nil
            end
        
            local GroundPosition = Vector3.new(
                Position.X,
                Result.Position.Y + RootPart.Size.Y * 0.5,
                Position.Z
            )
        
            if AICCombatUtils.IsWaterAtPosition(GroundPosition)
                or AICCombatUtils.IsInsideFarmDeadzone(GroundPosition)
            then
                return nil
            end
        
            return GroundPosition
        end
        function AICCombatUtils.GetMobDistance(Mob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local MobRoot = Mob:FindFirstChild("HumanoidRootPart")
        
            if not MobRoot or not RootPart then
                return math.huge
            end
        
            local Offset = MobRoot.Position - RootPart.Position
        
            if CONFIG.DISTANCE_Y_CALCULATE then
                return Offset.Magnitude
            end
        
            return Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        end
        function AICCombatUtils.GetMobHealth(Mob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local MobHumanoid = Mob and Mob:FindFirstChildOfClass("Humanoid")
        
            if not MobHumanoid then
                return 0
            end
        
            return MobHumanoid.Health
        end
        
        ------------------------------------------------------------------------
        --// AICBlade  ::  enemy weapon hitboxes and danger geometry
        --// 8 function(s)
        ------------------------------------------------------------------------
        --// Get every BladePart inside one Mob.
        function AICCombatUtils.GetBladeParts(Mob)
            if not Mob then
                return {}
            end
        
            local now = os.clock()
            local Cached = AICCombatUtils.S.BladePartCache[Mob]
        
            if Cached
                and now - Cached.Time < CONFIG.BLADE_PART_CACHE_INTERVAL
            then
                return Cached.Parts
            end
        
            local BladeParts = {}
        
            for _, Descendant in Mob:GetDescendants() do
                if Descendant:IsA("BasePart") and Descendant.Name == "BladePart" then
                    table.insert(BladeParts, Descendant)
                end
            end
        
            AICCombatUtils.S.BladePartCache[Mob] = {
                Time  = now,
                Parts = BladeParts,
            }
        
            return BladeParts
        end
        
        --// Finds the closest point on an actual BladePart box.
        --// This is much more accurate than simply using BladePart.Position.
        function AICCombatUtils.GetClosestPointOnBlade(BladePart, Position)
            if not BladePart or not BladePart:IsA("BasePart") then
                return nil, math.huge
            end
        
            local LocalPosition = BladePart.CFrame:PointToObjectSpace(Position)
            local HalfSize      = BladePart.Size * 0.5
        
            local ClosestLocal = Vector3.new(
                math.clamp(LocalPosition.X, -HalfSize.X, HalfSize.X),
                math.clamp(LocalPosition.Y, -HalfSize.Y, HalfSize.Y),
                math.clamp(LocalPosition.Z, -HalfSize.Z, HalfSize.Z)
            )
        
            local ClosestWorld = BladePart.CFrame:PointToWorldSpace(ClosestLocal)
            local Distance     = (Position - ClosestWorld).Magnitude
        
            return ClosestWorld, Distance
        end
        function AICCombatUtils.GetBladeDangerDistance()
            return CONFIG.ENEMY_ATTACK_SAFE_DISTANCE + CONFIG.ENEMY_BLADE_PADDING
        end
        
        --// Walks a computed path toward a destination. Used when the straight line
        --// is blocked: the farm zone return had no pathfinding at all, so a wall or
        --// a ledge between the character and the zone left it walking into geometry.

        return Module
    end,
}
