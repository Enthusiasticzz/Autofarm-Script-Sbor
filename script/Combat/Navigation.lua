return {
    Name = "Navigation",
    Dependencies = {"Runtime", "CombatUtils", "Targeting"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local Replicated = Services.Replicated
        local StarterGui = Services.StarterGui
        local RunService = Services.RunService
        local PathfindingService = Services.PathfindingService
        local HttpService = Services.HttpService
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICCombatUtils = Context.AICCombatUtils
        local AICCombat = Context.AICCombat

        local Module = Context.AICCombat

        --// Going round the target's body, the walk keeps this much more than
        --// TARGET_BODY_CLEARANCE from it.
        local BODY_DETOUR_MARGIN = 2
        --// After the path to the Safe Combat spot fails, paths go to the mob
        --// itself for this long rather than switching back and forth.
        local PATH_TO_MOB_HOLD = 2
        --// A path solve not back after this long is given up on.
        local PATH_COMPUTE_TIMEOUT = 3
        --// With Safe Combat off, the spots tried around the target, nearest
        --// first, step back from the Close Combat Range setting by these.
        --// None is closer than CLOSE_COMBAT_MIN (clear of the body,
        --// TARGET_BODY_CLEARANCE); the range itself is how close it holds
        --// (CLOSE HOLD).
        local CLOSE_COMBAT_STEPS = { 2, 1, 0 }
        local CLOSE_COMBAT_MIN = 4
        --// While Character.NoDamage is on us: circle the target this far
        --// outside its reach, aiming this far round the circle each frame,
        --// and turn the other way at most this often when the way is shut.
        local ORBIT_PADDING = 2
        local ORBIT_STEP_ANGLE = math.rad(35)
        local ORBIT_FLIP_COOLDOWN = 1.5
        --// With Safe Combat off, standing within this of the mob's facing
        --// (cosine; 0.5 = 60 degrees either side) counts as in front of it,
        --// the only place it moves away from.
        local CLOSE_FRONT_DOT = 0.5

        function AICCombat.IsSafeCombatPathClear(TargetPosition, Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            local Origin    = RootPart.Position + Vector3.new(0, 1.5, 0)
            local Direction = (TargetPosition - RootPart.Position)
        
            if Direction.Magnitude <= 0.01 then
                return true
            end
        
            --// Built as a plain table first: FilterDescendantsInstances hands
            --// back a copy, so inserting into it afterwards changed nothing.
            local Filter = {
                Character,
                Goblin,   --// เพิ่ม Goblin เข้า exclude ด้วย กันโดนตัวมอนเองที่กำลังจะเดินเข้าหา
            }

            --// Ignore every player's character so other players do not block SafeCombat raycasts.
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character and OtherPlayer.Character ~= Character then
                    table.insert(Filter, OtherPlayer.Character)
                end
            end

            if AICCombatUtils.S.DebugFolder then
                table.insert(Filter, AICCombatUtils.S.DebugFolder)
            end

            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = Filter
        
            local Result = workspace:Raycast(Origin, Direction, RaycastParams)
        
            if Result then
                --print("[SafeCombat] blocked by:", Result.Instance:GetFullName())
                return false
            end
        
            return true
        end
        
        --// Whether a straight walk from us to Destination passes through the
        --// target's body. A player standing still and facing us puts the spot
        --// behind them on the far side, and walking there ran into them until
        --// the character climbed or jumped on top.
        function AICCombat.IsTargetBodyInTheWay(Destination, TargetRoot)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Destination or not TargetRoot then
                return false
            end

            local Origin = RootPart.Position
            local Segment = Vector3.new(Destination.X - Origin.X, 0, Destination.Z - Origin.Z)
            local ToTarget = Vector3.new(TargetRoot.Position.X - Origin.X, 0, TargetRoot.Position.Z - Origin.Z)
            local Length = Segment.Magnitude

            if Length <= 0.01 then
                return false
            end

            --// Closest point of the walk to the target, capped at its end.
            --// A walk heading away never passes through, even when it starts
            --// right against the body.
            local Along = math.min(ToTarget:Dot(Segment) / Length, Length)

            if Along <= 0 then
                return false
            end

            local Miss = (ToTarget - Segment.Unit * Along).Magnitude

            return Miss < (tonumber(CONFIG.TARGET_BODY_CLEARANCE) or 3.5)
        end

        --// Close Combat Range (CONFIG.CLOSE_COMBAT_RANGE), never under
        --// CLOSE_COMBAT_MIN.
        local function GetCloseCombatRange()
            return math.max(tonumber(CONFIG.CLOSE_COMBAT_RANGE) or 6, CLOSE_COMBAT_MIN)
        end

        --// The spots Safe Combat off tries, nearest first.
        local function GetCloseCombatDistances()
            local Range = GetCloseCombatRange()
            local Distances = {}

            for _, Step in ipairs(CLOSE_COMBAT_STEPS) do
                table.insert(Distances, math.max(Range - Step, CLOSE_COMBAT_MIN))
            end

            return Distances
        end

        --// Get a safe combat position around the Target.
        --// Cheap checks are performed first. Expensive path/visibility checks are
        --// only run for the best few candidates to reduce physics-query spikes.
        --// Close is the Safe Combat off version: the same rear-first spots and
        --// the same circling as the mob turns, but Close Combat Range from
        --// it instead of outside its blade reach. Only the spacing differs.
        function AICCombat.GetSafeCombatPosition(TargetMob, Close)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetMob then
                return nil
            end
        
            local TargetRoot = TargetMob:FindFirstChild("HumanoidRootPart")
            if not TargetRoot then
                return nil
            end
        
            local Offset = RootPart.Position - TargetRoot.Position
            local CurrentDirection = Vector3.new(Offset.X, 0, Offset.Z)
        
            if CurrentDirection.Magnitude <= 0.01 then
                CurrentDirection = Vector3.zAxis
            else
                CurrentDirection = CurrentDirection.Unit
            end
        
            local CombatDistance = CONFIG.PLAYER_ATTACK_DISTANCE
            local LastAttacker = TargetMob:FindFirstChild("LastAttacker")
            local LastAttackerValue = LastAttacker and LastAttacker.Value
            local OtherAttacker = LastAttackerValue and LastAttackerValue ~= Player
        
            --// Always approach from behind first, regardless of who the LastAttacker is.
            --// When another player is attacking, also alternate the side used for the
            --// approach so the player does not stay on one predictable side.
            if AICCombat.S.LastAttackerCombatMob ~= TargetMob then
                AICCombat.S.LastAttackerCombatMob = TargetMob
                AICCombat.S.LastAttackerCombatSide = math.random(0, 1) == 0 and -1 or 1
                AICCombat.S.LastAttackerCombatSwitchTime = os.clock() + math.random() * (CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MAX - CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MIN) + CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MIN
                AICCombat.S.LastAttackerCombatPosition = nil
            elseif os.clock() >= AICCombat.S.LastAttackerCombatSwitchTime then
                AICCombat.S.LastAttackerCombatSide *= -1
                AICCombat.S.LastAttackerCombatSwitchTime = os.clock() + math.random() * (CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MAX - CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MIN) + CONFIG.OTHER_ATTACKER_SIDE_SWITCH_MIN
                AICCombat.S.LastAttackerCombatPosition = nil
            end
        
            if OtherAttacker then
                CombatDistance = math.max(CombatDistance, CONFIG.GOBLIN_REACH_DISTANCE)
            end
        
            for _, BladePart in AICCombat.GetCombatBladeParts(TargetMob) do
                local BladeOffset = BladePart.Position - TargetRoot.Position
                local HorizontalBladeOffset = Vector3.new(BladeOffset.X, 0, BladeOffset.Z)
                local BladeDistance = HorizontalBladeOffset.Magnitude
                CombatDistance = math.max(
                    CombatDistance,
                    BladeDistance + AICCombatUtils.GetBladeDangerDistance()
                )
            end
        
            --// A spot past a player's body is skipped: they stand and face us,
            --// so the walk round them never ends. A mob's rear is still preferred;
            --// ChaseMoveTo walks round the body to get there. A duel opponent
            --// is fought like a mob we are hitting: walked round to its rear.
            local IsPlayerTarget = Players:GetPlayerFromCharacter(TargetMob) ~= nil
                and not AICCombat.IsOwnDuelOpponent(TargetMob)
            local Candidates = {}
            local DirectionCount = CONFIG.SAFE_COMBAT_DIRECTIONS
            local PreferredDirections = {}
        
            --// Farm Zone can make the normal attack radius unreachable when the mob
            --// is close to the edge of the zone. Try progressively closer combat
            --// positions instead of giving up at PLAYER_ATTACK_DISTANCE.
            local CombatDistances = Close and GetCloseCombatDistances() or {
                CombatDistance,
                math.max(CONFIG.GOBLIN_REACH_DISTANCE, CombatDistance - 2),
                math.max(CONFIG.GOBLIN_REACH_DISTANCE, CombatDistance - 4),
                math.max(CONFIG.GOBLIN_REACH_DISTANCE, CombatDistance - 6),
                math.max(CONFIG.GOBLIN_REACH_DISTANCE, CombatDistance - 8),
            }

            --// Close spots sit inside the blade reach by design.
            local function IsBladeSafe(CandidatePosition)
                return Close or AICCombat.IsPositionSafeFromBladeGroup(CandidatePosition, TargetMob)
            end
        
            --// Always prefer the mob's rear. This applies both when LastAttacker is
            --// the local player and when another player is the current attacker.
            local Look = TargetRoot.CFrame.LookVector
            local Right = TargetRoot.CFrame.RightVector
            local Back = Vector3.new(-Look.X, 0, -Look.Z)
            local Side = Vector3.new(Right.X, 0, Right.Z) * AICCombat.S.LastAttackerCombatSide
            if Back.Magnitude > 0.01 then
                Back = Back.Unit
            end
            if Side.Magnitude > 0.01 then
                Side = Side.Unit
            end
            PreferredDirections = {
                Back,
                Side,
                -Side,
            }
        
            for _, Direction in ipairs(PreferredDirections) do
                for _, CandidateDistance in ipairs(CombatDistances) do
                    local CandidatePosition = TargetRoot.Position + Direction * CandidateDistance
                    if AICCombatUtils.IsInsideFarmArea(CandidatePosition)
                        and not (IsPlayerTarget and AICCombat.IsTargetBodyInTheWay(CandidatePosition, TargetRoot))
                        and not AICCombatUtils.IsWaterAtPosition(CandidatePosition, TargetMob)
                        and not AICCombatUtils.IsPathThroughDeadzone(CandidatePosition)
                        and IsBladeSafe(CandidatePosition)
                    then
                        local Dot = math.clamp(CurrentDirection:Dot(Direction), -1, 1)
                        local DirectionPenalty = (1 - Dot) * CandidateDistance * 0.2
                        table.insert(Candidates, {
                            Position = CandidatePosition,
                            Score = (CandidatePosition - RootPart.Position).Magnitude + DirectionPenalty - 20,
                        })
                    end
                end
            end
        
            for Index = 0, DirectionCount - 1 do
                local Angle = (math.pi * 2 / DirectionCount) * Index
                local Direction = Vector3.new(math.cos(Angle), 0, math.sin(Angle))
        
                for _, CandidateDistance in ipairs(CombatDistances) do
                    local CandidatePosition = TargetRoot.Position + Direction * CandidateDistance
        
                    --// Cheap checks first. These avoid expensive raycasts for obviously
                    --// invalid positions.
                    if not AICCombatUtils.IsInsideFarmArea(CandidatePosition)
                        or (IsPlayerTarget and AICCombat.IsTargetBodyInTheWay(CandidatePosition, TargetRoot))
                        or AICCombatUtils.IsWaterAtPosition(CandidatePosition, TargetMob)
                        or AICCombatUtils.IsPathThroughDeadzone(CandidatePosition)
                        or not IsBladeSafe(CandidatePosition)
                    then
                        continue
                    end
        
                    local Dot = math.clamp(CurrentDirection:Dot(Direction), -1, 1)
                    local DirectionPenalty = (1 - Dot) * CandidateDistance * 0.35
                    local TravelDistance = (CandidatePosition - RootPart.Position).Magnitude
        
                    table.insert(Candidates, {
                        Position = CandidatePosition,
                        Score = TravelDistance + DirectionPenalty,
                    })
                end
            end
        
            table.sort(Candidates, function(A, B)
                return A.Score < B.Score
            end)
        
            local MaxPathTests = math.min(CONFIG.SAFE_COMBAT_MAX_PATH_TESTS, #Candidates)
        
            --// A spot the mob cannot be seen from is worse, not unusable. Rejecting
            --// it outright meant a pillar or a rock between us was enough to leave
            --// the solver with no answer at all, when walking around it was always
            --// an option. Sight is preferred; blocked sight is kept as a fallback
            --// and the pathfinder routes to it.
            local BlindFallback = nil
        
            for Index = 1, MaxPathTests do
                local CandidatePosition = Candidates[Index].Position
        
                if AICCombatUtils.IsPathThroughWater(CandidatePosition)
                    or (not Close and AICCombat.IsPathThroughBladeGroupDanger(CandidatePosition, TargetMob))
                then
                    continue
                end
        
                if AICCombatUtils.CanSeeGoblinFromPosition(CandidatePosition, TargetMob)
                    and AICCombat.IsSafeCombatPathClear(CandidatePosition, TargetMob)
                then
                    return CandidatePosition
                end
        
                if not BlindFallback then
                    BlindFallback = CandidatePosition
                end
            end
        
            return BlindFallback
        end
        
        --// Calculate Retreat Position
        function AICCombat.IsRetreatPositionReachable(TargetPosition, RequirePathfinding)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            if not AICCombatUtils.IsInsideFarmArea(TargetPosition)
                or AICCombatUtils.IsWaterAtPosition(TargetPosition)
                or AICCombatUtils.IsPathThroughWater(TargetPosition)
                or AICCombatUtils.IsPathThroughDeadzone(TargetPosition)
            then
                return false
            end
        
            if not AICCombatUtils.IsPathClear(TargetPosition) then
                return false
            end
        
            --// A retreat position is only useful if it is outside every active
            --// enemy blade danger area, and the route does not cross one.
            for _, Goblin in AICCombat.GetLivingGoblins() do
                if AICCombat.IsPositionSafeFromBladeGroup(TargetPosition, Goblin) == false
                    or AICCombat.IsPathThroughBladeGroupDanger(TargetPosition, Goblin)
                then
                    return false
                end
            end
        
            if not RequirePathfinding then
                return true
            end
        
            local Path = PathfindingService:CreatePath({
                AgentRadius    = math.max(RootPart.Size.X * 0.5, 2),
                AgentHeight    = math.max(RootPart.Size.Y, 5),
                AgentCanJump   = true,
                WaypointSpacing = 4,
            })
        
            local Success = pcall(function()
                Path:ComputeAsync(RootPart.Position, TargetPosition)
            end)
        
            if not Success or Path.Status ~= Enum.PathStatus.Success then
                return false
            end
        
            local Waypoints = Path:GetWaypoints()
        
            if #Waypoints < 2 then
                return false
            end
        
            for Index = 2, #Waypoints do
                local Position = Waypoints[Index].Position
        
                if not AICCombatUtils.IsInsideFarmArea(Position)
                    or AICCombatUtils.IsWaterAtPosition(Position)
                    or AICCombatUtils.IsPathThroughDeadzone(Position)
                then
                    return false
                end
            end
        
            return true
        end
        function AICCombat.GetEnemySkillRetreatPosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil
            end
        
            local Threats = AICCombat.GetRetreatThreats()
        
            if #Threats == 0 then
                return nil
            end
        
            local Origin = RootPart.Position
            local Away = Vector3.zero
        
            --// Weight every nearby enemy by inverse distance.
            --// This makes the retreat direction react to the whole group instead
            --// of blindly running directly away from the current target.
            for _, Goblin in Threats do
                local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
                if MobRoot then
                    local Offset = Origin - MobRoot.Position
                    local Horizontal = Vector3.new(Offset.X, 0, Offset.Z)
                    local Distance = Horizontal.Magnitude
        
                    if Distance > 0.01 then
                        Away += Horizontal.Unit / math.max(Distance, 4)
                    end
                end
            end
        
            if Away.Magnitude <= 0.01 then
                return nil
            end
        
            Away = Away.Unit
        
            local Directions = {}
        
            --// Test the direct escape first, then progressively wider angles.
            --// The longer candidates are preferred so the player gets out of
            --// the skill range quickly instead of stopping after a tiny step.
            for Index = 0, CONFIG.RETREAT_DIRECTIONS - 1 do
                local Angle = (math.pi * 2 / CONFIG.RETREAT_DIRECTIONS) * Index
                local Direction = CFrame.fromAxisAngle(Vector3.yAxis, Angle):VectorToWorldSpace(Away)
        
                table.insert(Directions, Direction)
            end
        
            local BestPosition = nil
            local BestScore = -math.huge
        
            for _, Direction in ipairs(Directions) do
                Direction = Vector3.new(Direction.X, 0, Direction.Z)
        
                if Direction.Magnitude <= 0.01 then
                    continue
                end
        
                Direction = Direction.Unit
        
                for _, Distance in ipairs({
                    CONFIG.SKILL_RETREAT_DISTANCE,
                    48,
                    36,
                    28,
                    20,
                    }) do
                    local Candidate = Origin + Direction * Distance
        
                    if not AICCombat.IsRetreatPositionReachable(Candidate, true) then
                        continue
                    end
        
                    local DirectionScore = Away:Dot(Direction)
                    local DistanceScore = Distance / CONFIG.SKILL_RETREAT_DISTANCE
        
                    --// Strongly prefer getting farther away, but only after the
                    --// candidate has passed the actual reachability/safety checks.
                    local Score = DirectionScore * 5 + DistanceScore * 3
        
                    if Score > BestScore then
                        BestScore = Score
                        BestPosition = Candidate
                    end
        
                    --// Once a safe long route exists in this direction, don't
                    --// waste pathfinding calls on the shorter candidates.
                    break
                end
            end
        
            --// Emergency local fallback: if every long retreat candidate is
            --// rejected, still try a short escape around the player. This does
            --// not use PathfindingService, but it still respects FarmZone,
            --// Deadzone, water and blade-safety checks.
            if not BestPosition then
                for _, Distance in ipairs({12, 8, 5}) do
                    local Candidate = Origin + Away * Distance
                    if AICCombat.IsRetreatPositionReachable(Candidate, false) then
                        BestPosition = Candidate
                        break
                    end
                end
            end
        
            return BestPosition
        end
        function AICCombat.GetRetreatPosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil
            end
        
            local Goblins = AICCombat.GetRetreatThreats()
        
            if #Goblins == 0 then
                return nil
            end
        
            local RetreatDirection = Vector3.zero
        
            if AICCombat.S.ClosestTarget
                and AICCombat.S.ClosestTarget:IsDescendantOf(workspace)
            then
                local TargetHumanoid = AICCombat.S.ClosestTarget:FindFirstChildOfClass("Humanoid")
                local TargetRoot     = AICCombat.S.ClosestTarget:FindFirstChild("HumanoidRootPart")
        
                if TargetHumanoid
                    and TargetRoot
                    and TargetHumanoid.Health > 0
                then
                    local Offset = RootPart.Position - TargetRoot.Position
                    local Distance = Offset.Magnitude
        
                    if Distance > 0 then
                        RetreatDirection = Offset.Unit
                    end
                end
            end
        
            if RetreatDirection.Magnitude <= 0 then
                for _, Goblin in Goblins do
                    local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
                    if MobRoot then
                        local Offset = RootPart.Position - MobRoot.Position
                        local Distance = Offset.Magnitude
        
                        if Distance > 0 then
                            RetreatDirection += Offset.Unit / math.max(Distance, 1)
                        end
                    end
                end
        
                if RetreatDirection.Magnitude <= 0 then
                    return nil
                end
        
                RetreatDirection = RetreatDirection.Unit
            end
        
            local BestPosition = nil
            local BestScore    = -math.huge
        
            --// Only the full retreat distance used to be tried. Near a zone edge, or
            --// with any wall inside sixty studs, every direction failed and the
            --// caller was left standing in the damage. Shorter hops are worth far
            --// more than no movement at all.
            local Distances = {
                CONFIG.RETREAT_DISTANCE,
                45,
                32,
                22,
                14,
            }
        
            for _, Distance in ipairs(Distances) do
                for Index = 0, CONFIG.RETREAT_DIRECTIONS - 1 do
                    local Angle = (math.pi * 2 / CONFIG.RETREAT_DIRECTIONS) * Index
        
                    local Direction = Vector3.new(
                        math.cos(Angle),
                        0,
                        math.sin(Angle)
                    )
        
                    local TargetPosition = RootPart.Position + Direction * Distance
        
                    --// Deadzones were not checked here, so a health retreat could
                    --// run straight into one.
                    if AICCombatUtils.IsInsideFarmArea(TargetPosition)
                        and not AICCombatUtils.IsInsideFarmDeadzone(TargetPosition)
                        and not AICCombatUtils.IsPathThroughDeadzone(TargetPosition)
                        and AICCombatUtils.IsPathClear(TargetPosition)
                    then
                        local Score = Direction:Dot(RetreatDirection)
        
                        if Score > BestScore then
                            BestScore    = Score
                            BestPosition = TargetPosition
                        end
                    end
                end
        
                --// Prefer the longest distance that produced anything.
                if BestPosition then
                    return BestPosition
                end
            end
        
            return BestPosition
        end
        
        --// Direction away from the nearest threat, with no validation at all. Used
        --// as the last resort when every vetted escape has failed: walking into a
        --// wall still beats standing still while a mob swings.
        function AICCombat.GetRawAwayDirection()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil
            end
        
            local Origin = RootPart.Position
            local NearestModel = AICCombat.GetNearestThreat()
            local Nearest = NearestModel and NearestModel:FindFirstChild("HumanoidRootPart")

            if not Nearest then
                return nil
            end

            local Offset = Origin - Nearest.Position
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)
        
            if Flat.Magnitude <= 0.01 then
                return nil
            end
        
            return Flat.Unit
        end
        
        --// Check whether any living priority mob is close enough to justify retreat movement.
        --// Distance to the nearest living mob of any kind. The priority list decides
        --// what to attack, not what can hurt us: a mob outside it swings just as hard,
        --// and keying "am I safe to stand still" off the priority list meant the
        --// script would hold position while something not on the list beat on it.
        local function IsAliveModel(Model)
            local ModelRoot = Model and Model:FindFirstChild("HumanoidRootPart")
            local ModelHumanoid = Model and Model:FindFirstChildOfClass("Humanoid")

            return ModelRoot ~= nil and ModelHumanoid ~= nil and ModelHumanoid.Health > 0
        end

        --// Players worth running from: the duel opponent while in a duel,
        --// otherwise every player on the target list.
        function AICCombat.GetHostilePlayerCharacters()
            local Result = {}
            local Opponents = AICCombat.GetOwnDuelOpponents()

            if Opponents then
                for _, Opponent in ipairs(Opponents) do
                    if IsAliveModel(Opponent.Character) then
                        table.insert(Result, Opponent.Character)
                    end
                end

                return Result
            end

            for _, PlayerCharacter in ipairs(AICCombat.GetPriorityPlayerCharacters()) do
                if IsAliveModel(PlayerCharacter) then
                    table.insert(Result, PlayerCharacter)
                end
            end

            return Result
        end

        --// Everything a retreat steers away from: priority mobs plus hostile
        --// players. A player swings just as hard as a mob.
        function AICCombat.GetRetreatThreats()
            local Threats = table.clone(AICCombat.GetLivingGoblins())

            for _, PlayerCharacter in ipairs(AICCombat.GetHostilePlayerCharacters()) do
                table.insert(Threats, PlayerCharacter)
            end

            return Threats
        end

        --// Nearest living mob of any kind, or hostile player. Returns the
        --// model, its horizontal distance and whether it is a player.
        function AICCombat.GetNearestThreat()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil, math.huge, false
            end

            local Nearest, NearestDistance, NearestIsPlayer = nil, math.huge, false

            local function Consider(Model, IsPlayer)
                if not Model:IsA("Model") or not IsAliveModel(Model) then
                    return
                end

                local Distance = AICCombatUtils.GetHorizontalDistance(
                    RootPart.Position,
                    Model.HumanoidRootPart.Position
                )

                if Distance < NearestDistance then
                    Nearest, NearestDistance, NearestIsPlayer = Model, Distance, IsPlayer
                end
            end

            local MobFolder = workspace:FindFirstChild("Mobs")

            for _, Mob in (MobFolder and MobFolder:GetChildren() or {}) do
                Consider(Mob, false)
            end

            for _, PlayerCharacter in ipairs(AICCombat.GetHostilePlayerCharacters()) do
                Consider(PlayerCharacter, true)
            end

            return Nearest, NearestDistance, NearestIsPlayer
        end

        function AICCombat.GetNearestHostileDistance()
            local _, Distance = AICCombat.GetNearestThreat()
            return Distance
        end

        --// While retreating, a threat inside attack range is hit rather than
        --// only run from. Returns the threat when it is that close.
        function AICCombat.GetFightBackThreat()
            local Threat, Distance = AICCombat.GetNearestThreat()

            if not Threat then
                return nil
            end

            if Distance > AICCombat.GetCombatAttackRange(Threat) then
                return nil
            end

            return Threat, Distance
        end
        function AICCombat.GetNearestLivingGoblinDistance()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return math.huge
            end
        
            local NearestDistance = math.huge
        
            for _, Goblin in AICCombat.GetLivingGoblins() do
                local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
                if MobRoot then
                    local Distance = AICCombatUtils.GetHorizontalDistance(RootPart.Position, MobRoot.Position)
        
                    if Distance < NearestDistance then
                        NearestDistance = Distance
                    end
                end
            end
        
            return NearestDistance
        end
        
        --// Retreat
        --// Dodging a skill is a race, and the pathfinding solver is not fast enough
        --// to win it: sixteen directions by five distances is up to eighty
        --// ComputeAsync calls plus hundreds of samples, which stalls frames badly
        --// enough that the character appears to crawl.
        --//
        --// This picks a direction away from the whole group and validates it with
        --// nothing but a farm-zone test, a ground ray and one body-width blockcast.
        --// It is allowed to be imperfect; moving now beats moving well later.
        function AICCombat.GetImmediateEscapePosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return nil
            end
        
            local Origin = RootPart.Position
            local Away = Vector3.zero
        
            for _, Goblin in AICCombat.GetRetreatThreats() do
                local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
                if MobRoot then
                    local Offset = Origin - MobRoot.Position
                    local Flat = Vector3.new(Offset.X, 0, Offset.Z)
                    local Distance = Flat.Magnitude
        
                    if Distance > 0.01 then
                        --// Inverse distance: the mob about to hit us dominates.
                        Away += Flat.Unit / math.max(Distance, 4)
                    end
                end
            end
        
            if Away.Magnitude <= 0.01 then
                Away = -Vector3.new(
                    RootPart.CFrame.LookVector.X,
                    0,
                    RootPart.CFrame.LookVector.Z
                )
        
                if Away.Magnitude <= 0.01 then
                    return nil
                end
            end
        
            Away = Away.Unit
        
            local DirectionCount = math.max(1, tonumber(CONFIG.SKILL_DODGE_DIRECTIONS) or 9)
            local Spread = tonumber(CONFIG.SKILL_DODGE_SPREAD) or 110
            local Distances = {
                tonumber(CONFIG.SKILL_DODGE_DISTANCE) or 26,
                tonumber(CONFIG.SKILL_DODGE_FALLBACK_DISTANCE) or 14,
            }
        
            for _, Distance in ipairs(Distances) do
                for Index = 0, DirectionCount - 1 do
                    --// Straight away first, then alternating outward to either side.
                    local Step = math.ceil(Index / 2)
                    local Sign = (Index % 2 == 0) and 1 or -1
                    local Angle = math.rad((Spread / math.max(1, DirectionCount - 1)) * Step * Sign)
                    local Direction = CFrame.fromAxisAngle(Vector3.yAxis, Angle):VectorToWorldSpace(Away)
        
                    Direction = Vector3.new(Direction.X, 0, Direction.Z)
        
                    if Direction.Magnitude > 0.01 then
                        Direction = Direction.Unit
        
                        local Candidate = AICCombatUtils.GetPatrolGroundPosition(Origin + Direction * Distance)
        
                        if Candidate
                            and AICCombatUtils.IsInsideFarmArea(Candidate)
                            and not AICCombatUtils.IsInsideFarmDeadzone(Candidate)
                            and AICCombatUtils.IsEscapePathClear(Candidate)
                        then
                            return Candidate
                        end
                    end
                end
            end
        
            return nil
        end
        function AICCombat.RetreatFromGoblins(IsEnemySkill)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()
            local RetreatPosition = nil
            local now = os.clock()

            if not Humanoid or not RootPart then
                return false
            end
        
            --// Normal retreat only triggers movement/jump when a mob is within
            --// the configured nearby distance. Enemy skill retreat is different:
            --// if a mob is actively using a skill, keep the skill-escape logic
            --// even when that mob is farther than the normal 30-stud trigger.
            --// A duel is never waited out standing still. Against another
            --// player the character may only stop once they are farther than
            --// RETREAT_PLAYER_SAFE_DISTANCE; against mobs the old trigger holds.
            local NearestThreat, NearestThreatDistance, NearestIsPlayer = AICCombat.GetNearestThreat()

            if not IsEnemySkill and not AICCombat.IsInDuel() then
                --// Any living mob counts here, not just the ones we would attack.
                local SafeDistance = NearestIsPlayer
                    and (tonumber(CONFIG.RETREAT_PLAYER_SAFE_DISTANCE) or 50)
                    or CONFIG.RETREAT_NEARBY_MOB_DISTANCE

                if NearestThreatDistance > SafeDistance then
                    Humanoid.AutoRotate = false
                    Humanoid:Move(Vector3.zero)

                    --// Keep watching whatever is out there until healed.
                    if NearestThreat then
                        AICCombat.FaceWhileRetreating(NearestThreat)
                    end

                    return false
                end
            end
        
            if IsEnemySkill then
                --// Keep running toward the position already chosen while it is still
                --// worth reaching, so the character commits to one escape instead of
                --// re-deciding every frame and shuffling on the spot.
                if AICCombat.S.SkillRetreatPosition
                    and now - AICCombat.S.LastSkillRetreatTime < CONFIG.RETREAT_RECALCULATE_INTERVAL
                    and AICCombatUtils.GetHorizontalDistance(RootPart.Position, AICCombat.S.SkillRetreatPosition) > 3
                    and AICCombatUtils.IsInsideFarmArea(AICCombat.S.SkillRetreatPosition)
                    and not AICCombatUtils.IsInsideFarmDeadzone(AICCombat.S.SkillRetreatPosition)
                then
                    RetreatPosition = AICCombat.S.SkillRetreatPosition
                else
                    --// Cheap solver first. It answers in a handful of raycasts.
                    RetreatPosition = AICCombat.GetImmediateEscapePosition()
        
                    --// Only when there is no room at all does the expensive
                    --// pathfinding solver run, and then no more than once every
                    --// SKILL_SOLVER_INTERVAL so it cannot stall frame after frame.
                    if not RetreatPosition
                        and now - AICCombat.S.LastSkillSolverTime >= (tonumber(CONFIG.SKILL_SOLVER_INTERVAL) or 0.6)
                    then
                        AICCombat.S.LastSkillSolverTime = now
                        RetreatPosition = AICCombat.GetEnemySkillRetreatPosition()
                    end
        
                    if RetreatPosition then
                        AICCombat.S.SkillRetreatPosition = RetreatPosition
                        AICCombat.S.LastSkillRetreatTime = now
                    else
                        AICCombat.S.SkillRetreatPosition = nil
                    end
                end
            else
                if AICCombat.S.LastRetreatPosition
                    and now - AICCombat.S.LastRetreatCalculateTime < CONFIG.RETREAT_RECALCULATE_INTERVAL
                then
                    RetreatPosition = AICCombat.S.LastRetreatPosition
                else
                    RetreatPosition = AICCombat.GetRetreatPosition()
        
                    --// Same cheap solver the skill dodge uses. It accepts ground the
                    --// vetted search rejects, which is the difference between moving
                    --// and standing still.
                    if not RetreatPosition then
                        RetreatPosition = AICCombat.GetImmediateEscapePosition()
                    end
        
                    if RetreatPosition then
                        AICCombat.S.LastRetreatPosition      = RetreatPosition
                        AICCombat.S.LastRetreatCalculateTime = now
                        AICCombat.S.RetreatNoPositionSince   = nil
                    elseif not AICCombat.S.RetreatNoPositionSince then
                        AICCombat.S.RetreatNoPositionSince = now
                    end
                end
            end
        
            if RetreatPosition then
                AICCombat.S.RetreatNoPositionSince = nil
        
                Humanoid.AutoRotate = false
                Humanoid:MoveTo(RetreatPosition)

                local RootPosition = RootPart.Position
                local RetreatDirection = Vector3.new(
                    RetreatPosition.X - RootPosition.X,
                    0,
                    RetreatPosition.Z - RootPosition.Z
                )

                --// Back away facing the nearest threat so it can be hit if it
                --// closes in; with nothing in face range, face the way we run.
                AICCombat.FaceWhileRetreating(NearestThreat, RetreatDirection)
        
                AICCombatUtils.DoCombatJumpIfObstacle(RetreatPosition)
                return true
            end
        
            --// Nothing passed any check. Standing still here is the worst possible
            --// answer and is exactly what the script used to do: it would hold
            --// position, still flagged as retreating, and take hits until it died.
            if not AICCombat.S.RetreatNoPositionSince then
                AICCombat.S.RetreatNoPositionSince = now
            end
        
            if now - AICCombat.S.RetreatNoPositionSince < (tonumber(CONFIG.RETREAT_NO_POSITION_TIMEOUT) or 1.5) then
                local Away = AICCombat.GetRawAwayDirection()

                --// The raw direction has no validation, so it used to walk (and
                --// jump) straight out of the farm zone or into a deadzone. Keep
                --// it only while the spot it lands on is still allowed ground,
                --// shortening the step before giving up on it.
                local RawTarget = nil

                if Away then
                    for _, Scale in ipairs({ 1, 0.5 }) do
                        local Candidate = RootPart.Position + Away * CONFIG.SKILL_DODGE_FALLBACK_DISTANCE * Scale

                        if AICCombatUtils.IsInsideFarmArea(Candidate)
                            and not AICCombatUtils.IsInsideFarmDeadzone(Candidate)
                            and not AICCombatUtils.IsPathThroughDeadzone(Candidate)
                        then
                            RawTarget = Candidate
                            break
                        end
                    end
                end

                if RawTarget then
                    Humanoid.AutoRotate = false
                    Humanoid:MoveTo(RawTarget)
                    AICCombat.FaceWhileRetreating(NearestThreat, RawTarget - RootPart.Position)

                    AICCombatUtils.DoCombatJumpIfObstacle(RawTarget)
                    return true
                end
            else
                --// Boxed in for long enough that retreating is clearly not working.
                --// Fighting back beats being a stationary target, so hand control
                --// back to the combat loop.
                AICCombat.S.RETREATING = false
                AICCombat.S.RetreatNoPositionSince = nil
                AICCombat.S.SkillRetreatPosition = nil
                AICCombat.S.LastRetreatPosition = nil
            end
        
            Humanoid.AutoRotate = false
            Humanoid:Move(Vector3.zero)
            return false
        end
        
        --// Approach Position Check
        function AICCombat.IsApproachPositionClear(TargetPosition, Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            if not AICCombatUtils.IsInsideFarmArea(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsWaterAtPosition(TargetPosition, Goblin) then
                return false
            end
        
            if AICCombatUtils.IsPathThroughWater(TargetPosition) then
                return false
            end
        
            if AICCombatUtils.IsPathThroughDeadzone(TargetPosition) then
                return false
            end
        
            --// Never select a position inside any BladePart danger zone
            --// around the target group.
            if AICCombat.S.SafeCombatPositionEnabled
                and Goblin
                and not AICCombat.IsPositionSafeFromBladeGroup(TargetPosition, Goblin)
            then
                return false
            end
        
            --// Also make sure the route itself doesn't pass through
            --// an enemy BladePart danger zone.
            if AICCombat.S.SafeCombatPositionEnabled
                and Goblin
                and AICCombat.IsPathThroughBladeGroupDanger(TargetPosition, Goblin)
            then
                return false
            end
        
            local Origin    = RootPart.Position
            local Direction = TargetPosition - Origin
        
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
        
            local Result = workspace:Raycast(Origin, Direction, RaycastParams)
        
            return Result == nil
        end
        
        --// Target Reposition
        function AICCombat.GetTargetRepositionPosition(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin then
                return nil
            end
        
            local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
            if not MobRoot then
                return nil
            end
        
            --// Calculate the minimum safe radius around the target.
            local SafeRadius = CONFIG.PLAYER_ATTACK_DISTANCE
        
            if AICCombat.S.SafeCombatPositionEnabled then
                for _, BladePart in AICCombat.GetCombatBladeParts(Goblin) do
                    local Offset = BladePart.Position - MobRoot.Position
                    local HorizontalOffset = Vector3.new(Offset.X, 0, Offset.Z)
                    local BladeDistance = HorizontalOffset.Magnitude
        
                    SafeRadius = math.max(
                        SafeRadius,
                        BladeDistance + AICCombatUtils.GetBladeDangerDistance()
                    )
                end
            end
        
            --// Never make the radius absurdly small.
            SafeRadius = math.max(SafeRadius, CONFIG.GOBLIN_REACH_DISTANCE)
        
            local BestPosition = nil
            local BestScore    = math.huge
        
            for Index = 0, CONFIG.TARGET_REPOSITION_DIRECTIONS - 1 do
                local Angle = (math.pi * 2 / CONFIG.TARGET_REPOSITION_DIRECTIONS) * Index
        
                local Direction = Vector3.new(
                    math.cos(Angle),
                    0,
                    math.sin(Angle)
                )
        
                local CandidatePosition = MobRoot.Position + Direction * SafeRadius
        
                if not AICCombat.IsApproachPositionClear(CandidatePosition, Goblin) then
                    continue
                end
        
                if AICCombat.S.SafeCombatPositionEnabled
                    and not AICCombat.IsPositionSafeFromBladeGroup(CandidatePosition, Goblin)
                then
                    continue
                end
        
                local Offset = CandidatePosition - RootPart.Position
                local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
                --// Prefer positions closer to the current player
                --// while still maintaining safety.
                local TargetOffset = CandidatePosition - MobRoot.Position
                local TargetDistance = Vector3.new(TargetOffset.X, 0, TargetOffset.Z).Magnitude
        
                local Score = Distance + TargetDistance * 0.15
        
                --// Penalise rather than discard a spot with no view of the mob, so a
                --// wall in the way costs a detour instead of the whole candidate set.
                if not AICCombatUtils.CanSeeGoblinFromPosition(CandidatePosition, Goblin) then
                    Score += CONFIG.BLIND_POSITION_PENALTY
                end
        
                if Score < BestScore then
                    BestScore    = Score
                    BestPosition = CandidatePosition
                end
            end
        
            return BestPosition
        end
        function AICCombat.IsSafeCombatDirectPathBlocked(Goblin, TargetPosition, now)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin or not TargetPosition then
                return true
            end
        
            if AICCombat.S.LastDirectPathTarget == Goblin
                and AICCombat.S.LastDirectPathPosition == TargetPosition
                and now - AICCombat.S.LastDirectPathCheckTime < CONFIG.DIRECT_PATH_CACHE_INTERVAL
            then
                return AICCombat.S.LastDirectPathBlocked
            end
        
            AICCombat.S.LastDirectPathCheckTime = now
            AICCombat.S.LastDirectPathTarget = Goblin
            AICCombat.S.LastDirectPathPosition = TargetPosition
        
            AICCombat.S.LastDirectPathBlocked =
                not AICCombatUtils.CanSeeGoblin(Goblin)
                or not AICCombat.IsSafeCombatPathClear(TargetPosition, Goblin)
                or AICCombatUtils.IsPathThroughWater(TargetPosition)
                or AICCombatUtils.IsPathThroughDeadzone(TargetPosition)
                --// Close combat (Safe Combat off) walks past the blade on purpose.
                or (AICCombat.S.SafeCombatPositionEnabled and AICCombat.IsPathThroughBladeGroupDanger(TargetPosition, Goblin))

            return AICCombat.S.LastDirectPathBlocked
        end
        
        --// ============================================================
        --// TARGET PATHFINDING
        --// ============================================================
        function AICCombat.ResetTargetPath()
            AICCombat.S.TargetPath             = nil
            AICCombat.S.TargetPathMob          = nil
            AICCombat.S.TargetPathDestination  = nil
            AICCombat.S.TargetPathWaypoint     = 1
            AICCombat.S.LastTargetPathTime     = 0
            AICCombat.S.TargetPathBlockedSince = nil
        end
        --// A solve is running. One that has not come back in
        --// PATH_COMPUTE_TIMEOUT is given up on, so a hung ComputeAsync cannot
        --// leave every chase waiting on it.
        function AICCombat.IsTargetPathComputing()
            return AICCombat.S.TargetPathComputing == true
                and os.clock() - (AICCombat.S.TargetPathComputeStart or 0) < PATH_COMPUTE_TIMEOUT
        end

        function AICCombat.ComputeTargetPath(Goblin, Destination)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin or not Destination then
                AICCombat.ResetTargetPath()
                return false
            end
        
            local Path = PathfindingService:CreatePath({
                AgentRadius = math.max(RootPart.Size.X * 0.5, 2),
                AgentHeight = math.max(RootPart.Size.Y, 5),
                AgentCanJump = true,
                WaypointSpacing = 4,
            })
        
            --// ComputeAsync yields, and every heartbeat is its own thread, so
            --// without this a slow solve stacked up one request per frame.
            if AICCombat.IsTargetPathComputing() then
                return AICCombat.S.TargetPath ~= nil and AICCombat.S.TargetPathMob == Goblin
            end

            local Token = (AICCombat.S.TargetPathToken or 0) + 1
            AICCombat.S.TargetPathToken = Token
            AICCombat.S.TargetPathComputing = true
            AICCombat.S.TargetPathComputeStart = os.clock()

            local Success = pcall(function()
                Path:ComputeAsync(RootPart.Position, Destination)
            end)

            --// Given up on (PATH_COMPUTE_TIMEOUT) and replaced meanwhile.
            if AICCombat.S.TargetPathToken ~= Token then
                return false
            end

            AICCombat.S.TargetPathComputing = false

            if not Success or Path.Status ~= Enum.PathStatus.Success then
                AICCombat.ResetTargetPath()
                return false
            end

            local Waypoints = Path:GetWaypoints()

            if #Waypoints < 2 then
                AICCombat.ResetTargetPath()
                return false
            end
        
            --// Never follow a path that leaves the FarmZone, and never one that cuts
            --// through a deadzone. IsInsideFarmArea covers both, but it short
            --// circuits to true when Ignore Farm Zone is on, so the deadzone test is
            --// spelled out for the case where only the zone restriction is waived.
            for Index = 2, #Waypoints do
                local Position = Waypoints[Index].Position
        
                if not AICCombatUtils.IsInsideFarmArea(Position) then
                    AICCombat.ResetTargetPath()
                    return false
                end
        
                if not FeatureState.IgnoreFarmZone.Enabled
                    and AICCombatUtils.IsInsideFarmDeadzone(Position)
                then
                    AICCombat.ResetTargetPath()
                    return false
                end
            end
        
            AICCombat.S.TargetPath             = Path
            AICCombat.S.TargetPathMob          = Goblin
            AICCombat.S.TargetPathDestination  = Destination
            AICCombat.S.TargetPathWaypoint     = 2
            AICCombat.S.LastTargetPathTime     = os.clock()
            AICCombat.S.TargetPathBlockedSince = nil
        
            return true
        end
        --// Pressed up against the target: a stall there is the body in the
        --// way, not a ledge a hop would clear.
        local function IsAgainstTargetBody(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local GoblinRoot = Goblin and Goblin:FindFirstChild("HumanoidRootPart")

            return RootPart ~= nil
                and GoblinRoot ~= nil
                and AICCombatUtils.GetHorizontalDistance(RootPart.Position, GoblinRoot.Position)
                    <= (tonumber(CONFIG.TARGET_BODY_CLEARANCE) or 3.5)
        end

        function AICCombat.MoveAlongTargetPath(Goblin, Destination)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin or not Destination then
                return false
            end
        
            local now = os.clock()
            local NeedRecalculate =
                AICCombat.S.TargetPath == nil
                or AICCombat.S.TargetPathMob ~= Goblin
                or not AICCombat.S.TargetPathDestination
                or (AICCombat.S.TargetPathDestination - Destination).Magnitude > 5
                or now - AICCombat.S.LastTargetPathTime >= CONFIG.TARGET_PATH_RECALCULATE_INTERVAL
        
            if NeedRecalculate then
                if not AICCombat.ComputeTargetPath(Goblin, Destination) then
                    if not AICCombat.S.TargetPathBlockedSince then
                        AICCombat.S.TargetPathBlockedSince = now
                    end
        
                    return false
                end
            end
        
            local Waypoints = AICCombat.S.TargetPath:GetWaypoints()
        
            while AICCombat.S.TargetPathWaypoint <= #Waypoints do
                local Waypoint = Waypoints[AICCombat.S.TargetPathWaypoint]
                local Offset = Waypoint.Position - RootPart.Position
                local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
                if Distance <= CONFIG.TARGET_PATH_WAYPOINT_DISTANCE then
                    AICCombat.S.TargetPathWaypoint += 1
                    continue
                end
        
                --// The pathfinder marks jumps generously, including on flat ground.
                --// Only take them when something is actually in the way, or when the
                --// character has stopped making progress.
                if Waypoint.Action == Enum.PathWaypointAction.Jump
                    and (AICCombatUtils.IsJumpableObstacleAhead(Waypoint.Position)
                        or (AICCombatUtils.IsStuck() and not IsAgainstTargetBody(Goblin)))
                then
                    AICCombatUtils.DoCombatJump()
                end

                --// Hung on a corner between two path points: the path is
                --// fine, the body is caught on the edge. A hop frees it.
                --// Not when the "corner" is the target itself: the hop lands
                --// on top of it.
                if AICCombatUtils.IsStuck() and not IsAgainstTargetBody(Goblin) then
                    AICCombatUtils.DoCombatJump()
                end

                Humanoid.AutoRotate = false
                Humanoid:MoveTo(Waypoint.Position)
                AICCombat.FaceGoblin(Goblin)
                return true
            end
        
            --// Path reached its final waypoint. Let combat positioning decide
            --// whether we should attack or make a final adjustment.
            AICCombat.ResetTargetPath()
            return false
        end

        --// ============================================================
        --// CHASE MOVEMENT
        --// ============================================================
        --// Every approach to a target goes through ChaseMoveTo. It walks
        --// straight while that works, switches to pathfinding for a while
        --// when a wall is just ahead or the character stalls, and sidesteps
        --// out of the corner when it stalls even on the path. A plain MoveTo
        --// used to run into the same wall until the target was given up.
        function AICCombat.ResetChase()
            AICCombat.S.ChaseMob = nil
            AICCombat.S.ChasePathUntil = 0
            AICCombat.S.ChaseUnstickUntil = 0
            AICCombat.S.ChaseUnstickPosition = nil
            AICCombat.S.ChaseBlockedCheckTime = 0
            AICCombat.S.ChaseBlocked = false
            AICCombat.S.ChaseBestDistance = math.huge
            AICCombat.S.ChaseUnstickCount = 0
        end

        AICCombat.ResetChase()

        local function GetChaseObstacleParams(Goblin)
            local Character = Runtime:GetCharacter()
            local Filter = { Character, Goblin, AICCombatUtils.S.DebugFolder }

            --// Mobs and players move; they are walked around by the detour
            --// and blade logic, not treated as walls.
            local MobFolder = workspace:FindFirstChild("Mobs")
            if MobFolder then
                table.insert(Filter, MobFolder)
            end

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character and OtherPlayer.Character ~= Character then
                    table.insert(Filter, OtherPlayer.Character)
                end
            end

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = Filter
            Params.IgnoreWater = true
            return Params
        end

        --// Whether the body would hit something solid in the next few studs
        --// toward Destination. Cached briefly; it runs every frame of a chase.
        function AICCombat.IsChaseLineBlocked(Goblin, Destination, now)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return false
            end

            if now - AICCombat.S.ChaseBlockedCheckTime < (tonumber(CONFIG.CHASE_BLOCK_CHECK_INTERVAL) or 0.12) then
                return AICCombat.S.ChaseBlocked
            end

            AICCombat.S.ChaseBlockedCheckTime = now

            local Offset = Destination - RootPart.Position
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= 0.5 then
                AICCombat.S.ChaseBlocked = false
                return false
            end

            local Probe = math.min(Flat.Magnitude, tonumber(CONFIG.CHASE_BLOCK_PROBE_DISTANCE) or 6)
            --// Raised off the feet so a slope or a step the jump logic
            --// handles is not read as a wall.
            local Origin = CFrame.new(RootPart.Position + Vector3.new(0, 0.5, 0))
            local Size = Vector3.new(2.2, 2.5, 2.2)
            local Hit = workspace:Blockcast(Origin, Size, Flat.Unit * Probe, GetChaseObstacleParams(Goblin))

            AICCombat.S.ChaseBlocked = Hit ~= nil
                and not AICCombatUtils.IsJumpableObstacleAhead(Destination)
            return AICCombat.S.ChaseBlocked
        end

        --// A spot beside the target's body, on the side Destination lies, far
        --// enough out that the walk on from there clears the body. nil when
        --// Destination is the body itself (nothing to go round) or neither
        --// side is allowed ground.
        local function GetBodyDetour(RootPart, GoblinRoot, Destination)
            local Clearance = (tonumber(CONFIG.TARGET_BODY_CLEARANCE) or 3.5) + BODY_DETOUR_MARGIN
            local ToTarget = GoblinRoot.Position - RootPart.Position
            local Forward = Vector3.new(ToTarget.X, 0, ToTarget.Z)
            local ToDestination = Vector3.new(Destination.X - GoblinRoot.Position.X, 0, Destination.Z - GoblinRoot.Position.Z)

            if Forward.Magnitude <= 0.01 or ToDestination.Magnitude < Clearance - BODY_DETOUR_MARGIN then
                return nil
            end

            Forward = Forward.Unit

            local Side = Vector3.new(-Forward.Z, 0, Forward.X)

            if ToDestination:Dot(Side) < 0 then
                Side = -Side
            end

            for _, Sign in ipairs({ 1, -1 }) do
                local Point = GoblinRoot.Position + Side * Sign * Clearance
                Point = Vector3.new(Point.X, RootPart.Position.Y, Point.Z)

                if AICCombatUtils.IsInsideFarmArea(Point) and not AICCombatUtils.IsInsideFarmDeadzone(Point) then
                    return Point
                end
            end

            return nil
        end

        local function MoveStraight(Humanoid, Goblin, Destination)
            Humanoid.AutoRotate = false
            Humanoid:MoveTo(Destination)
            AICCombat.FaceGoblin(Goblin)
            AICCombatUtils.DoCombatJumpIfObstacle(Destination)
        end

        --// Sidesteps are only worth repeating while they lead somewhere. Once
        --// several in a row have not brought the target closer, the caller
        --// falls back to its own handling, which marks a target with no
        --// route as unreachable instead of dancing in the corner forever.
        local function TrackChaseProgress(Destination)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local Distance = AICCombatUtils.GetHorizontalDistance(RootPart.Position, Destination)

            if Distance < AICCombat.S.ChaseBestDistance - 2 then
                AICCombat.S.ChaseBestDistance = Distance
                AICCombat.S.ChaseUnstickCount = 0
            end
        end

        local function StartUnstick(Destination, now)
            AICCombatUtils.ResetStuckTracker()

            if AICCombat.S.ChaseUnstickCount >= (tonumber(CONFIG.CHASE_MAX_UNSTICKS) or 4) then
                return false
            end

            local Position = AICCombatUtils.GetUnstickPosition(Destination)

            if not Position then
                return false
            end

            AICCombat.S.ChaseUnstickCount += 1
            AICCombat.S.ChaseUnstickPosition = Position
            AICCombat.S.ChaseUnstickUntil = now + (tonumber(CONFIG.CHASE_UNSTICK_TIME) or 0.6)
            AICCombat.ResetTargetPath()
            return true
        end

        function AICCombat.ChaseMoveTo(Goblin, Destination)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Humanoid or not RootPart or not Goblin or not Destination then
                return false
            end

            local now = os.clock()

            if AICCombat.S.ChaseMob ~= Goblin then
                AICCombat.ResetChase()
                AICCombat.S.ChaseMob = Goblin
            end

            TrackChaseProgress(Destination)

            --// Pressed up against the target in melee is not a corner. The
            --// body blocks the walk, which the stuck tracker would otherwise
            --// read as a stall and start pathing and sidestepping mid-fight.
            local GoblinRoot = Goblin:FindFirstChild("HumanoidRootPart")

            if GoblinRoot
                and AICCombatUtils.GetHorizontalDistance(RootPart.Position, GoblinRoot.Position)
                    <= CONFIG.GOBLIN_REACH_DISTANCE
            then
                AICCombatUtils.ResetStuckTracker()
                AICCombat.ResetTargetPath()

                --// The target stands between us and the spot (its rear, say):
                --// pushing on only climbs onto it. Walk round its side instead.
                --// Holding here, as v2.67 did, left nothing to move us on
                --// without Safe Combat, so the character stood at the mob's face.
                if AICCombat.IsTargetBodyInTheWay(Destination, GoblinRoot) then
                    local Detour = GetBodyDetour(RootPart, GoblinRoot, Destination)

                    Humanoid.AutoRotate = false
                    Humanoid:MoveTo(Detour or RootPart.Position)
                    AICCombat.FaceGoblin(Goblin)
                    AICCombat.S.ChaseMoveStep = Detour and "ROUND BODY" or "BODY IN WAY, NO SIDE"
                    return true
                end

                MoveStraight(Humanoid, Goblin, Destination)
                AICCombat.S.ChaseMoveStep = "MELEE"
                return true
            end

            --// Mid-sidestep: finish it before trying the target again. The
            --// sidestep heads for open ground, so it only hops over something
            --// actually in the way.
            if now < AICCombat.S.ChaseUnstickUntil and AICCombat.S.ChaseUnstickPosition then
                Humanoid.AutoRotate = false
                Humanoid:MoveTo(AICCombat.S.ChaseUnstickPosition)
                AICCombat.FaceGoblin(Goblin)
                AICCombatUtils.DoCombatJumpIfObstacle(AICCombat.S.ChaseUnstickPosition)
                AICCombat.S.ChaseMoveStep = "UNSTICK"
                return true
            end

            --// Within attack range the character is swinging, and swings and
            --// the bodies of a crowd slow the walk. That is not a corner, so
            --// it must not start pathing, sidestepping and hopping mid-fight.
            if GoblinRoot
                and AICCombat.GetCombatDistance(Goblin, GoblinRoot.Position - RootPart.Position)
                    <= AICCombat.GetCombatAttackRange(Goblin)
            then
                AICCombatUtils.ResetStuckTracker()
            end

            local InPathMode = now < AICCombat.S.ChasePathUntil

            if AICCombatUtils.IsStuck() then
                if InPathMode then
                    --// Stalled even on the path: get out of the corner first.
                    if StartUnstick(Destination, now) then
                        return AICCombat.ChaseMoveTo(Goblin, Destination)
                    end

                    AICCombatUtils.DoCombatJump()
                else
                    AICCombatUtils.ResetStuckTracker()
                end

                AICCombat.S.ChasePathUntil = now + (tonumber(CONFIG.CHASE_PATH_HOLD) or 2.5)
                InPathMode = true
            elseif not InPathMode and AICCombat.IsChaseLineBlocked(Goblin, Destination, now) then
                AICCombat.S.ChasePathUntil = now + (tonumber(CONFIG.CHASE_PATH_HOLD) or 2.5)
                InPathMode = true
            end

            if not InPathMode then
                AICCombat.ResetTargetPath()
                MoveStraight(Humanoid, Goblin, Destination)
                AICCombat.S.ChaseMoveStep = "STRAIGHT"
                return true
            end

            if AICCombat.MoveAlongTargetPath(Goblin, Destination) then
                AICCombat.S.ChaseMoveStep = "PATH"
                return true
            end

            --// A solve for this target is still running: keep the last
            --// heading rather than stopping dead for a frame.
            if AICCombat.IsTargetPathComputing() then
                MoveStraight(Humanoid, Goblin, Destination)
                AICCombat.S.ChaseMoveStep = "STRAIGHT (PATH SOLVING)"
                return true
            end

            --// The pathfinder found no route, which it often does on rough
            --// terrain to a mob that is plainly walkable to. Walk straight at
            --// it, as the chase did before v2.62: a real wall makes the
            --// character stall, and the stuck handling above sidesteps. Only
            --// once every sidestep has failed to get closer is the chase given
            --// up, so the caller can mark the target unreachable.
            if AICCombat.S.ChaseUnstickCount >= (tonumber(CONFIG.CHASE_MAX_UNSTICKS) or 4) then
                AICCombat.S.ChaseMoveStep = "GAVE UP"
                return false
            end

            MoveStraight(Humanoid, Goblin, Destination)
            AICCombat.S.ChaseMoveStep = "STRAIGHT (NO PATH)"
            return true
        end

        --// ============================================================
        --// WATER COMBAT
        --// ============================================================
        --// Ground navigation refuses water outright, so a fight that ends up
        --// in it is handled here. While swimming the Humanoid follows the
        --// full 3D move direction, which is what lets the character dive to
        --// a target below the surface; Jump makes it rise.
        function AICCombat.IsWaterCombat(Goblin)
            if not Goblin then
                return false
            end

            --// Only PvP is fought in the water. Swimming toward a mob on land
            --// keeps the old jump-out recovery, which lets pathfinding take
            --// over instead of paddling against the bank.
            if not Players:GetPlayerFromCharacter(Goblin) then
                return false
            end

            --// Knocked in mid-fight, or the player is in the water: swim.
            return AICCombatUtils.IsSelfSwimming()
                or AICCombatUtils.IsModelInWater(Goblin)
        end

        --// The ControlModule calls Player:Move and sets Humanoid.Jump from the
        --// keyboard on every RenderStepped, before physics. A swim stroke
        --// issued from Heartbeat was zeroed again before it ever moved the
        --// character (MoveTo survives that, which is why the walk to the
        --// shore worked and the swim did not). SwimChase leaves its latest
        --// order here and it is re-applied right after the ControlModule.
        local SWIM_STEP_NAME = "AICSwimChase"
        local SWIM_ORDER_LIFETIME = 0.25
        AICCombat.S.SwimOrder = nil

        local function ApplySwimOrder()
            local Order = AICCombat.S.SwimOrder
            if not Order then
                return
            end

            --// SwimChase stopped calling: the fight left the water.
            if os.clock() - Order.Time > SWIM_ORDER_LIFETIME then
                AICCombat.S.SwimOrder = nil
                return
            end

            local Character, Humanoid = Runtime:GetCharacter()
            if not Humanoid or Humanoid.Health <= 0 then
                return
            end

            Humanoid:Move(Order.Direction, false)

            if Order.Rise then
                Humanoid.Jump = true
            end
        end

        pcall(RunService.UnbindFromRenderStep, RunService, SWIM_STEP_NAME)
        RunService:BindToRenderStep(SWIM_STEP_NAME, Enum.RenderPriority.Input.Value + 1, ApplySwimOrder)

        function AICCombat.SwimChase(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local MobRoot = Goblin and Goblin:FindFirstChild("HumanoidRootPart")
            if not Humanoid or not RootPart or not MobRoot then
                AICCombat.S.SwimOrder = nil
                return false
            end

            AICCombat.ResetTargetPath()

            local Offset = MobRoot.Position - RootPart.Position
            local Arrival = tonumber(CONFIG.SWIM_ARRIVAL_DISTANCE) or 5
            local Margin = tonumber(CONFIG.SWIM_SURFACE_MARGIN) or 2

            Humanoid.AutoRotate = false
            AICCombat.FaceGoblin(Goblin)

            if not AICCombatUtils.IsSelfSwimming() then
                --// Still on land: walk in after them. Pathfinding would
                --// refuse the water, so this is a straight line.
                AICCombat.S.SwimOrder = nil
                Humanoid:MoveTo(MobRoot.Position)
                AICCombatUtils.DoCombatJumpIfObstacle(MobRoot.Position)
                return true
            end

            --// Rise toward a target above us, including one back on land.
            --// Jump in water swims upward rather than leaving the surface.
            AICCombat.S.SwimOrder = {
                Direction = Offset.Magnitude > Arrival and Offset.Unit or Vector3.zero,
                Rise = Offset.Y > Margin,
                Time = os.clock(),
            }

            return true
        end
        
        --// ============================================================
        --// SAFE ENEMY RANGE
        --// ============================================================
        function AICCombat.GetSafeEnemyRangePosition(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Goblin then
                return nil
            end
        
            local SafeRange = math.max(tonumber(CONFIG.SAFE_ENEMY_RANGE) or 0, 0)
            if SafeRange <= 0 then
                return nil
            end
        
            local TargetRoot = Goblin:FindFirstChild("HumanoidRootPart")
            if not TargetRoot then
                return nil
            end
        
            local BladeParts = AICCombat.GetCombatBladeParts(Goblin)
            if #BladeParts == 0 then
                return nil
            end
        
            --// Our own fight: a mob whose LastAttacker is us, or our duel
            --// opponent (players carry no LastAttacker).
            local LastAttacker = Goblin:FindFirstChild("LastAttacker")
            local IsPlayerAttacker = (LastAttacker and LastAttacker.Value == Player)
                or AICCombat.IsOwnDuelOpponent(Goblin)
        
            local ClosestBlade = nil
            local ClosestPoint = nil
            local ClosestDistance = math.huge
        
            for _, BladePart in ipairs(BladeParts) do
                local Point, Distance = AICCombatUtils.GetClosestPointOnBlade(BladePart, RootPart.Position)
                if Point and Distance < ClosestDistance then
                    ClosestBlade = BladePart
                    ClosestPoint = Point
                    ClosestDistance = Distance
                end
            end
        
            if not ClosestBlade or not ClosestPoint then
                return nil
            end
        
            local CurrentPosition = RootPart.Position
        
            --// In our own fight, prefer the target's rear first, then the two
            --// sides. No visibility/path/water checks are used.
            local Look = TargetRoot.CFrame.LookVector
            local Right = TargetRoot.CFrame.RightVector
            local Back = Vector3.new(-Look.X, 0, -Look.Z)
            local Side = Vector3.new(Right.X, 0, Right.Z)
        
            if Back.Magnitude > 0.01 then
                Back = Back.Unit
            else
                Back = Vector3.zAxis
            end
        
            if Side.Magnitude > 0.01 then
                Side = Side.Unit
            else
                Side = Vector3.xAxis
            end
        
            local AwayFromBlade = CurrentPosition - ClosestPoint
            local FlatAwayFromBlade = Vector3.new(AwayFromBlade.X, 0, AwayFromBlade.Z)
            if FlatAwayFromBlade.Magnitude > 0.01 then
                FlatAwayFromBlade = FlatAwayFromBlade.Unit
            else
                FlatAwayFromBlade = Back
            end
        
            local Directions
            if IsPlayerAttacker then
                Directions = {
                    Back,
                    Side,
                    -Side,
                    FlatAwayFromBlade,
                }
            else
                Directions = {
                    FlatAwayFromBlade,
                    Back,
                    Side,
                    -Side,
                }
            end
        
            for _, Direction in ipairs(Directions) do
                local Candidate = ClosestPoint + Direction * SafeRange
        
                --// The only environment checks for Safe Enemy Range:
                --// stay inside FarmZone and never enter a Deadzone.
                if AICCombatUtils.IsInsideFarmArea(Candidate) and not AICCombatUtils.IsInsideFarmDeadzone(Candidate) then
                    local SafeFromAllBlades = true
                    for _, BladePart in ipairs(BladeParts) do
                        local _, Distance = AICCombatUtils.GetClosestPointOnBlade(BladePart, Candidate)
                        if Distance < SafeRange then
                            SafeFromAllBlades = false
                            break
                        end
                    end
        
                    if SafeFromAllBlades then
                        return Candidate
                    end
                end
            end
        
            return nil
        end
        
        --// ============================================================
        --// MOVE TO GOBLIN
        --// ============================================================
        --// The game puts NoDamage in our character while our hits do nothing
        --// (just spawned, say). Rushing in then only takes damage.
        function AICCombat.HasNoDamage()
            local Character = Runtime:GetCharacter()
            return Character ~= nil and Character:FindFirstChild("NoDamage") ~= nil
        end

        --// Outside the target's blade reach, as Safe Combat stands, and never
        --// inside our attack distance; plus ORBIT_PADDING.
        local function GetOrbitRadius(Goblin, GoblinRoot)
            local Radius = CONFIG.PLAYER_ATTACK_DISTANCE

            for _, BladePart in AICCombat.GetCombatBladeParts(Goblin) do
                local Offset = BladePart.Position - GoblinRoot.Position
                local BladeDistance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
                Radius = math.max(Radius, BladeDistance + AICCombatUtils.GetBladeDangerDistance())
            end

            return Radius + ORBIT_PADDING
        end

        --// Walks round the target without closing in, facing it, until
        --// NoDamage is gone. Each frame it heads ORBIT_STEP_ANGLE further
        --// round the circle from where it stands, so it settles onto the
        --// circle from any distance. A spot off the farm zone, in a
        --// deadzone, in water or behind a wall turns it the other way.
        function AICCombat.OrbitTarget(Goblin)
            local _, Humanoid, RootPart = Runtime:GetCharacter()
            local GoblinRoot = Goblin and Goblin:FindFirstChild("HumanoidRootPart")

            if not Humanoid or not RootPart or not GoblinRoot then
                return
            end

            local now = os.clock()
            local Offset = RootPart.Position - GoblinRoot.Position
            local Angle = (Offset.X ~= 0 or Offset.Z ~= 0) and math.atan2(Offset.Z, Offset.X) or 0
            local Radius = GetOrbitRadius(Goblin, GoblinRoot)

            AICCombat.S.OrbitSide = AICCombat.S.OrbitSide or 1

            local function PointAt(Side)
                local Next = Angle + Side * ORBIT_STEP_ANGLE
                return GoblinRoot.Position + Vector3.new(math.cos(Next), 0, math.sin(Next)) * Radius
            end

            local Point = PointAt(AICCombat.S.OrbitSide)

            if not AICCombat.IsApproachPositionClear(Point, Goblin) and now >= (AICCombat.S.OrbitFlipAt or 0) then
                AICCombat.S.OrbitSide = -AICCombat.S.OrbitSide
                AICCombat.S.OrbitFlipAt = now + ORBIT_FLIP_COOLDOWN
                Point = PointAt(AICCombat.S.OrbitSide)
            end

            if not AICCombat.ChaseMoveTo(Goblin, Point) then
                Humanoid:MoveTo(Point)
            end

            AICCombat.FaceGoblin(Goblin)
            AICCombat.S.ChaseStep = "NO DAMAGE, CIRCLING"
        end

        function AICCombat.MoveToGoblin(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()
            local now = os.clock()
            if not Goblin or not RootPart then
                return
            end
        
            if not AICCombat.IsTargetLockValid(Goblin) then
                if AICCombat.S.ClosestTarget == Goblin then
                    AICCombat.S.ClosestTarget = nil
                end
        
                AICCombat.ResetTargetReposition()
                AICCombat.ResetTargetPath()
                AICCombat.S.ChaseStep = "LOCK INVALID"
                return
            end

            --// In the water every ground rule (paths, water checks, safe
            --// spots on land) says no, so swimming fights use their own mover.
            if AICCombat.IsWaterCombat(Goblin) then
                AICCombat.SwimChase(Goblin)
                AICCombat.S.ChaseStep = "SWIM"
                return
            end

            local MobHumanoid = Goblin:FindFirstChildOfClass("Humanoid")
            local MobRoot     = Goblin:FindFirstChild("HumanoidRootPart")

            --// Safe Combat off (close combat) never backs away: no making room
            --// from a second mob, no Safe Enemy Range spacing, no stepping
            --// out from the target. It only goes round the target to its rear.
            local CloseCombat = not AICCombat.S.SafeCombatPositionEnabled

            --// Secondary threat handling:
            --// Keep the current target locked, but make room if another mob
            --// closes in from the player's side or rear.
            local ThreatMob, ThreatDistance = nil, math.huge

            if not CloseCombat then
                ThreatMob, ThreatDistance = AICCombat.GetNearbyThreatMob(Goblin)
            end

            if ThreatMob and ThreatDistance <= CONFIG.ENEMY_ATTACK_SAFE_DISTANCE + CONFIG.THREAT_ESCAPE_DISTANCE then
                local ThreatEscapePosition = AICCombat.GetThreatEscapePosition(Goblin, ThreatMob)
        
                if ThreatEscapePosition then
                    Humanoid.AutoRotate = false
                    Humanoid:MoveTo(ThreatEscapePosition)
                    AICCombat.FaceGoblin(Goblin)
                    AICCombat.S.ChaseStep = "THREAT ESCAPE"
                    return
                end
            end
        
            if not MobHumanoid
                or not MobRoot
                or MobHumanoid.Health <= 0
            then
                if AICCombat.S.ClosestTarget == Goblin then
                    AICCombat.S.ClosestTarget = nil
                end
        
                AICCombat.S.ValidMobs[Goblin] = nil
                AICCombat.ResetTargetReposition()
                AICCombat.ResetTargetPath()
        
                AICCombat.S.ChaseStep = "TARGET DEAD"
                return
            end
        
            --// Safe Enemy Range has its own lightweight rule set.
            --// It only cares about BladePart distance, FarmZone, and Deadzone.
            --// It does not use CanSeeGoblin, water checks, path checks, or SafeCombat.
            --// Spacing, so Safe Combat on only.
            local SafeEnemyRangePosition = not CloseCombat and AICCombat.GetSafeEnemyRangePosition(Goblin)

            if SafeEnemyRangePosition then
                local SafeEnemyOffset = SafeEnemyRangePosition - RootPart.Position
                local SafeEnemyDistance = Vector3.new(SafeEnemyOffset.X, 0, SafeEnemyOffset.Z).Magnitude

                if SafeEnemyDistance > CONFIG.SAFE_ENEMY_RANGE_ARRIVAL
                    and AICCombat.ChaseMoveTo(Goblin, SafeEnemyRangePosition)
                then
                    AICCombat.S.ChaseStep = "SAFE ENEMY RANGE"
                    return
                end
            end

            --// Safe Combat off fights as Safe Combat on does (rear first,
            --// circling round as the mob turns to face us, paths round
            --// obstacles) but close: Close Combat Range from the mob, with
            --// no backing off at all. In reach and out of the mob's front, it
            --// stays put and fights; it only moves when the mob turns to face it.
            if CloseCombat then
                local Offset = RootPart.Position - MobRoot.Position
                local FlatOffset = Vector3.new(Offset.X, 0, Offset.Z)
                local Look = MobRoot.CFrame.LookVector
                local FlatLook = Vector3.new(Look.X, 0, Look.Z)
                local InFront = FlatOffset.Magnitude > 0.01
                    and FlatLook.Magnitude > 0.01
                    and FlatOffset.Unit:Dot(FlatLook.Unit) > CLOSE_FRONT_DOT

                if FlatOffset.Magnitude <= GetCloseCombatRange() and not InFront then
                    Humanoid.AutoRotate = false
                    Humanoid:Move(Vector3.zero)
                    AICCombat.FaceGoblin(Goblin)
                    AICCombat.S.TargetUnreachableSince = nil
                    AICCombat.S.TargetApproachPosition = nil
                    AICCombat.S.ChaseStep = "CLOSE HOLD"
                    return
                end
            end

            if AICCombat.S.TargetApproachMob ~= Goblin then
                AICCombat.ResetTargetReposition()
                AICCombat.S.TargetApproachMob = Goblin
                AICCombat.S.CACHED_SAFECOMBAT_POSITION = nil
                AICCombat.S.CACHED_SAFECOMBAT_TARGET = Goblin
                AICCombat.S.LAST_SAFECOMBAT_TIME = 0
            end
        
            --// ========================================================
            --// FIRST PRIORITY:
            --// Get away from ANY BladePart that is currently too close.
            --// ========================================================
        
            local PushDirection, ClosestEffectiveDistance, ClosestBlade = AICCombat.GetBladeDangerData(Goblin)

            --// Close combat stands inside the blade reach on purpose.
            if ClosestEffectiveDistance <= 0 and not CloseCombat then
                if PushDirection.Magnitude > 0 then
                    local RetreatDistance = math.abs(ClosestEffectiveDistance) + CONFIG.ENEMY_ATTACK_SAFE_DISTANCE + 2
                    local RetreatPosition = RootPart.Position + PushDirection * RetreatDistance
        
                    if AICCombatUtils.IsInsideFarmArea(RetreatPosition)
                        and not AICCombatUtils.IsWaterAtPosition(RetreatPosition, Goblin)
                        and not AICCombatUtils.IsPathThroughWater(RetreatPosition)
                        and not AICCombatUtils.IsPathThroughDeadzone(RetreatPosition)
                        and not AICCombat.IsPathThroughBladeGroupDanger(RetreatPosition, Goblin)
                        and AICCombatUtils.IsEscapePathClear(RetreatPosition)
                    then
                        Humanoid.AutoRotate = false
                        Humanoid:MoveTo(RetreatPosition)
                        AICCombat.FaceGoblin(Goblin)
                    else
                        local MoveDistance  = math.abs(ClosestEffectiveDistance) + CONFIG.ENEMY_ATTACK_SAFE_DISTANCE + 2
                        local MovePosition  = RootPart.Position + PushDirection * MoveDistance
        
                        if AICCombatUtils.IsInsideFarmArea(MovePosition)
                            and not AICCombatUtils.IsWaterAtPosition(MovePosition, Goblin)
                            and not AICCombatUtils.IsPathThroughWater(MovePosition)
                            and not AICCombatUtils.IsPathThroughDeadzone(MovePosition)
                        then
                            Humanoid.AutoRotate = false
                            Humanoid:MoveTo(MovePosition)
                            AICCombat.FaceGoblin(Goblin)
                        else
                            Humanoid:Move(Vector3.zero)
                            AICCombat.FaceGoblin(Goblin)
                        end
                    end
                else
                    --// Standing inside the blade with nowhere to push: keep
                    --// facing the mob. Handing rotation back to AutoRotate
                    --// here is where a mob walking round us got behind us.
                    Humanoid:Move(Vector3.zero)
                    AICCombat.FaceGoblin(Goblin)
                end
        
                AICCombat.S.ChaseStep = "BLADE PUSH"
                return
            end
        
            --// ========================================================
            --// SECOND PRIORITY:
            --// Move to a safe attack position.
            --// ========================================================
        
            local SafeCombatPosition = AICCombat.S.CACHED_SAFECOMBAT_POSITION
            if AICCombat.S.CACHED_SAFECOMBAT_TARGET ~= Goblin
                or AICCombat.S.CACHED_SAFECOMBAT_CLOSE ~= CloseCombat
                or now - AICCombat.S.LAST_SAFECOMBAT_TIME >= CONFIG.SAFECOMBAT_INTERVAL
                or (SafeCombatPosition and not AICCombatUtils.IsInsideFarmArea(SafeCombatPosition))
            then
                AICCombat.S.LAST_SAFECOMBAT_TIME = now
                AICCombat.S.CACHED_SAFECOMBAT_TARGET = Goblin
                AICCombat.S.CACHED_SAFECOMBAT_CLOSE = CloseCombat
                SafeCombatPosition = AICCombat.GetSafeCombatPosition(Goblin, CloseCombat)
                AICCombat.S.CACHED_SAFECOMBAT_POSITION = SafeCombatPosition
            end
        
            if SafeCombatPosition then
                local Offset = SafeCombatPosition - RootPart.Position
                local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
                --// Already at the desired safe position.
                if Distance <= CONFIG.COMBAT_POSITION_ARRIVAL then
                    --// Stop movement but keep the character locked onto the target.
                    Humanoid.AutoRotate = false
                    Humanoid:Move(Vector3.zero)
                    AICCombat.FaceGoblin(Goblin)
        
                    AICCombat.S.TargetUnreachableSince = nil
                    AICCombat.S.TargetApproachPosition = nil
        
                    AICCombat.S.ChaseStep = "AT SPOT"
                    return
                end
        
                local DirectPathBlocked

                --// Close combat leaves what is in the way to ChaseMoveTo, which
                --// walks straight, paths and sidesteps by itself; only water and
                --// deadzones rule the walk out. The line-of-sight test hit the
                --// other mobs of the pack, and the pathfinder could not end this
                --// close to the mob (inside its body), so every close fight
                --// ended in PATH SOLVING / WAITING (NO WAY FOUND).
                if CloseCombat then
                    DirectPathBlocked = AICCombatUtils.IsPathThroughWater(SafeCombatPosition)
                        or AICCombatUtils.IsPathThroughDeadzone(SafeCombatPosition)
                else
                    DirectPathBlocked = AICCombat.IsSafeCombatDirectPathBlocked(Goblin, SafeCombatPosition, now)
                end

                if not DirectPathBlocked
                    and AICCombat.ChaseMoveTo(Goblin, SafeCombatPosition)
                then
                    AICCombat.S.TargetUnreachableSince = nil
                    AICCombat.S.TargetApproachPosition = nil
                    AICCombat.S.ChaseStep = "CHASE TO SPOT"
                    return
                end
            end

            --// Close combat with no spot to go to: walk at the mob itself, as
            --// Safe Combat off did before v2.81.
            if CloseCombat
                and not AICCombatUtils.IsPathThroughWater(MobRoot.Position)
                and not AICCombatUtils.IsPathThroughDeadzone(MobRoot.Position)
                and AICCombat.ChaseMoveTo(Goblin, MobRoot.Position)
            then
                AICCombat.S.TargetUnreachableSince = nil
                AICCombat.S.TargetApproachPosition = nil
                AICCombat.S.ChaseStep = "CHASE TO MOB"
                return
            end

            --// ========================================================
            --// THIRD PRIORITY:
            --// Use real pathfinding when an object blocks the direct route.
            --// A blocked line of sight does NOT mean the target is unreachable.
            --// ========================================================
        
            --// One destination at a time. Trying the spot and the mob in the
            --// same frame made each solve replace the other's path, so neither
            --// was ever walked: the character stood facing a mob it could reach.
            local PathToMob = not SafeCombatPosition or now < (AICCombat.S.PathToMobUntil or 0)
            local PathDestination = PathToMob and MobRoot.Position or SafeCombatPosition
        
            local OtherPlayerDetour = AICCombat.GetOtherPlayerDetourPosition(PathDestination, Goblin)
            if OtherPlayerDetour then
                AICCombat.ResetTargetPath()
                Humanoid.AutoRotate = false
                Humanoid:MoveTo(OtherPlayerDetour)
                AICCombat.FaceGoblin(Goblin)
                AICCombat.S.ChaseStep = "PLAYER DETOUR"
                return
            end
        
            if AICCombat.MoveAlongTargetPath(Goblin, PathDestination) then
                AICCombat.S.TargetUnreachableSince = nil
                AICCombat.S.TargetApproachPosition = nil
                AICCombat.S.ChaseStep = "PATH"
                return
            end
        
            --// A solve is still running: ComputeAsync yields, and frames meanwhile
            --// land here. Leave the last MoveTo going and keep facing the target.
            --// Falling through stopped the character with Move(0) on every one
            --// of those frames, which is why it stood still beside a mob it
            --// could not see but could walk to.
            if AICCombat.IsTargetPathComputing() then
                AICCombat.FaceGoblin(Goblin)
                AICCombat.S.ChaseStep = "PATH SOLVING"
                return
            end

            --// The chosen combat spot may be unreachable while the mob itself is
            --// perfectly walkable: route to the mob for a while before treating
            --// the target as out of reach. An obstacle between us is a detour,
            --// not a reason to drop the target.
            if not PathToMob then
                AICCombat.S.PathToMobUntil = now + PATH_TO_MOB_HOLD

                if AICCombat.MoveAlongTargetPath(Goblin, MobRoot.Position) then
                    AICCombat.S.TargetUnreachableSince = nil
                    AICCombat.S.TargetApproachPosition = nil
                    AICCombat.S.ChaseStep = "PATH TO MOB"
                    return
                end

                if AICCombat.IsTargetPathComputing() then
                    AICCombat.FaceGoblin(Goblin)
                    AICCombat.S.ChaseStep = "PATH SOLVING (MOB)"
                    return
                end
            end
        
            --// ========================================================
            --// FOURTH PRIORITY:
            --// Reposition around the entire enemy group.
            --// ========================================================
        
            if not AICCombat.S.TargetUnreachableSince then
                AICCombat.S.TargetUnreachableSince = now
            end
        
            if not AICCombat.S.TargetApproachPosition
                or now - AICCombat.S.LastTargetRepositionTime >= CONFIG.TARGET_REPOSITION_INTERVAL
            then
                AICCombat.S.LastTargetRepositionTime = now
                AICCombat.S.TargetApproachPosition = AICCombat.GetTargetRepositionPosition(Goblin)
            end
        
            if AICCombat.S.TargetApproachPosition then
                local ApproachOffset = AICCombat.S.TargetApproachPosition - RootPart.Position
                local ApproachDistance = Vector3.new(ApproachOffset.X, 0, ApproachOffset.Z).Magnitude
        
                if ApproachDistance <= CONFIG.APPROACH_ARRIVAL_DISTANCE then
                    AICCombat.S.TargetApproachPosition = nil
                elseif AICCombat.ChaseMoveTo(Goblin, AICCombat.S.TargetApproachPosition) then
                    AICCombat.S.ChaseStep = "REPOSITION"
                    return
                end
            end
        
            --// No safe combat position was found. Do not make the target appear
            --// invisible just because the safe-position solver failed. If the direct
            --// route is clear, move toward the actual mob and let the blade-danger check
            --// above keep us from standing inside the enemy weapon range.
            if AICCombat.IsSafeCombatPathClear(MobRoot.Position, Goblin)
                and not AICCombatUtils.IsPathThroughWater(MobRoot.Position)
                and not AICCombatUtils.IsPathThroughDeadzone(MobRoot.Position)
                and AICCombat.ChaseMoveTo(Goblin, MobRoot.Position)
            then
                AICCombat.S.TargetUnreachableSince = nil
                AICCombat.S.ChaseStep = "CHASE TO MOB"
                return
            end
        
            --// The mob is still a valid target even when the safe-position solver
            --// cannot find a perfect attack point. Keep the target locked while the
            --// pathfinding/reposition logic retries instead of dropping visibility.
            --// Waiting still faces it, so it cannot walk round behind us.
            AICCombat.S.ChaseStep = "WAITING (NO WAY FOUND)"
            Humanoid:Move(Vector3.zero)
            AICCombat.FaceGoblin(Goblin)
        
            if now - AICCombat.S.TargetUnreachableSince >= CONFIG.TARGET_UNREACHABLE_TIMEOUT then
                --// Nothing worked: no safe spot, no path to one, no path to the mob
                --// and no clear line. Remember that, or the next selection hands the
                --// same mob back and the whole attempt repeats forever.
                AICCombat.MarkMobUnreachable(Goblin)
        
                if AICCombat.S.ClosestTarget == Goblin then
                    AICCombat.S.ClosestTarget = nil
                end
        
                AICCombat.ResetTargetReposition()
                AICCombat.ResetTargetPath()
            end
        end
        
        ------------------------------------------------------------------------
        --// AICCombat  ::  target acquisition and attack / skill execution
        --// 8 function(s)
        ------------------------------------------------------------------------
        --// PRO COMBAT ACTION ENGINE
        function AICCombat.MoveAlongPathTo(Destination, AllowOutsideFarmArea)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not Humanoid or not Destination then
                return false
            end
        
            local Path = PathfindingService:CreatePath({
                AgentRadius     = math.max(RootPart.Size.X * 0.5, 2),
                AgentHeight     = math.max(RootPart.Size.Y, 5),
                AgentCanJump    = true,
                WaypointSpacing = 4,
            })
        
            local Success = pcall(function()
                Path:ComputeAsync(RootPart.Position, Destination)
            end)
        
            if not Success or Path.Status ~= Enum.PathStatus.Success then
                return false
            end
        
            local Waypoints = Path:GetWaypoints()
        
            if #Waypoints < 2 then
                return false
            end
        
            for Index = 2, #Waypoints do
                local Waypoint = Waypoints[Index]
        
                --// Returning to the zone starts outside it by definition, so that
                --// caller opts out of the containment check.
                if not AllowOutsideFarmArea
                    and not AICCombatUtils.IsInsideFarmArea(Waypoint.Position)
                then
                    return false
                end
        
                if AICCombatUtils.IsInsideFarmDeadzone(Waypoint.Position) then
                    return false
                end
            end
        
            for Index = 2, #Waypoints do
                local Waypoint = Waypoints[Index]
                local Offset = Waypoint.Position - RootPart.Position
                local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
                if Distance > CONFIG.TARGET_PATH_WAYPOINT_DISTANCE then
                    --// The pathfinder marks jumps generously, including on flat ground.
                    --// Only take them when something is actually in the way, or when the
                    --// character has stopped making progress.
                    --// Returning to the farm zone is its own walk, not a fight:
                    --// Jump While Fighting does not touch this one.
                    if Waypoint.Action == Enum.PathWaypointAction.Jump
                        and (AICCombatUtils.IsJumpableObstacleAhead(Waypoint.Position) or AICCombatUtils.IsStuck())
                    then
                        AICCombatUtils.DoJump()
                    end
        
                    Humanoid.AutoRotate = true
                    Humanoid:MoveTo(Waypoint.Position)
                    return true
                end
            end
        
            return false
        end
        
        
        ------------------------------------------------------------------------
        --// AICCombat
        --//
        --// targeting, approach, retreat and attack execution
        --//
        --// 49 function(s). Definitions only; nothing here runs
        --// at load time.
        ------------------------------------------------------------------------
        
        --// Target Reposition

        return Module
    end,
}
