return {
    Name = "AutoPatrol",
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
            Name = "AutoPatrol",
            IsFeature = true,
        }
        function Feature.IsPatrolPathClear(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            local Origin = RootPart.Position
            local Direction = TargetPosition - Origin
        
            if Direction.Magnitude <= 0.01 then
                return true
            end
        
            local RaycastParams = RaycastParams.new()
            RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
            RaycastParams.FilterDescendantsInstances = {
                Character,
                workspace:FindFirstChild("Mobs"),
            }
            if AICCombatUtils.S.DebugFolder then
                table.insert(RaycastParams.FilterDescendantsInstances, AICCombatUtils.S.DebugFolder)
            end
        
            local RayOrigin = Origin + Vector3.new(0, 1.5, 0)
            local RayDirection = Vector3.new(Direction.X, 0, Direction.Z)
        
            local Result = workspace:Raycast(RayOrigin, RayDirection, RaycastParams)
        
            if Result then
                --print("[PatrolPath] blocked by:", Result.Instance:GetFullName(), "at", Result.Position)
                return false
            end
        
            return true
        end
        function Feature.IsPatrolPathInsideFarmArea(TargetPosition)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition then
                return false
            end
        
            local Origin = RootPart.Position
            local Offset = TargetPosition - Origin
            local HorizontalOffset = Vector3.new(Offset.X, 0, Offset.Z)
        
            local Distance = HorizontalOffset.Magnitude
        
            if Distance <= 0.01 then
                return AICCombatUtils.IsInsideFarmArea(Origin)
            end
        
            local Direction = HorizontalOffset.Unit
            local SampleDistance = 4
        
            for CurrentDistance = 0, Distance, SampleDistance do
                local SamplePosition = Origin + Direction * math.min(CurrentDistance, Distance)
        
                if not AICCombatUtils.IsInsideFarmArea(SamplePosition)
                    or AICCombatUtils.IsInsideFarmDeadzone(SamplePosition)
                then
                    return false
                end
            end
        
            return true
        end
        function Feature.HasPatrolEscapeSpace(Position)
            if not Position then
                return false
            end
        
            local Distance = CONFIG.PATROL_ESCAPE_DISTANCE
            local DirectionCount = CONFIG.PATROL_ESCAPE_DIRECTIONS
        
            for Index = 0, DirectionCount - 1 do
                local Angle = (math.pi * 2 / DirectionCount) * Index
                local Direction = Vector3.new(math.cos(Angle), 0, math.sin(Angle))
                local EscapePosition = Position + Direction * Distance
        
                if AICCombatUtils.IsInsideFarmArea(EscapePosition)
                    and not AICCombatUtils.IsInsideFarmDeadzone(EscapePosition)
                    and not AICCombatUtils.IsWaterAtPosition(EscapePosition)
                    and AICCombatUtils.GetPatrolGroundPosition(EscapePosition)
                    and AICFeature.IsPatrolPathClear(EscapePosition)
                then
                    return true
                end
            end
        
            return false
        end
        function Feature.GetAutoPatrolPosition()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if not RootPart then
                return nil
            end
        
            local now = os.clock()
        
            if PatrolState.PatrolPauseUntil > now then
                return nil
            end
        
            if PatrolState.PatrolPosition and now - PatrolState.LastPatrolCalculateTime < CONFIG.PATROL_RECALCULATE_INTERVAL then
                return PatrolState.PatrolPosition
            end
        
            PatrolState.LastPatrolCalculateTime = now
            PatrolState.PatrolPosition = nil
        
            local Origin = RootPart.Position
            --// With Ignore Farm Zone on there is no zone to stay near, so roaming is
            --// measured from where the character already is. Keeping the farm centre
            --// as the anchor would pull it back every cycle and defeat the point.
            local Center
            if FeatureState.IgnoreFarmZone.Enabled then
                Center = (RootPart and RootPart.Position) or Vector3.zero
            else
                Center = (AICCombatUtils.GetActiveFarmZone() and AICCombatUtils.GetActiveFarmZone().Center)
                    or (RootPart and RootPart.Position)
                    or Vector3.zero
            end
            local Candidates = {}
        
            --// Keep some directional memory so patrol does not look like a random
            --// teleport between directions every cycle.
            local DirectionCount = CONFIG.PATROL_DIRECTIONS
            local PreviousDirection = PatrolState.PatrolDirection
            local BaseAngle = PreviousDirection
                and math.atan2(PreviousDirection.Z, PreviousDirection.X)
                or math.random() * math.pi * 2
        
            --// Humans tend to vary their walking distance. Do not always use the
            --// exact same radius or the exact same angle spacing.
            local Radius = math.random(
                math.floor(CONFIG.PATROL_MIN_DISTANCE),
                math.floor(CONFIG.PATROL_MAX_DISTANCE)
            )
        
            --// Sometimes just shuffle a few steps rather than crossing the area.
            --// Always walking a long leg is one of the more obvious tells.
            if math.random() < (tonumber(CONFIG.PATROL_SHORT_LEG_CHANCE) or 0.22) then
                Radius = math.max(
                    CONFIG.PATROL_ARRIVAL_DISTANCE + 3,
                    math.floor(Radius * (tonumber(CONFIG.PATROL_SHORT_LEG_SCALE) or 0.45))
                )
            end
        
            for Index = 0, DirectionCount - 1 do
                local StepAngle = (math.pi * 2 / DirectionCount) * Index
                local AngleJitter = math.rad(math.random(-14, 14))
                local Angle = BaseAngle + StepAngle + AngleJitter
                local Direction = Vector3.new(math.cos(Angle), 0, math.sin(Angle))
        
                --// Add a few distance variations instead of creating a perfect ring.
                local DistanceJitter = math.random(-10, 10)
                local CandidateRadius = math.clamp(
                    Radius + DistanceJitter,
                    CONFIG.PATROL_MIN_DISTANCE,
                    CONFIG.PATROL_MAX_DISTANCE
                )
        
                local Candidate = AICCombatUtils.GetPatrolGroundPosition(Origin + Direction * CandidateRadius)
        
                if Candidate then
                    local TravelDistance = Vector3.new(
                        Candidate.X - Origin.X,
                        0,
                        Candidate.Z - Origin.Z
                    ).Magnitude
        
                    local ToCandidate = Vector3.new(
                        Candidate.X - Origin.X,
                        0,
                        Candidate.Z - Origin.Z
                    )
        
                    local DirectionScore = 0
        
                    if PreviousDirection and ToCandidate.Magnitude > 0.01 then
                        --// Prefer continuing roughly in the previous direction, but only
                        --// as a soft preference. A person can change direction naturally.
                        DirectionScore = PreviousDirection:Dot(ToCandidate.Unit) * CONFIG.PATROL_DIRECTION_MEMORY
                    end
        
                    local CenterDistance = Vector3.new(
                        Candidate.X - Center.X,
                        0,
                        Candidate.Z - Center.Z
                    ).Magnitude
        
                    local RepeatPenalty = 0
        
                    if PatrolState.PatrolLastPosition then
                        local SinceLast = Vector3.new(
                            Candidate.X - PatrolState.PatrolLastPosition.X,
                            0,
                            Candidate.Z - PatrolState.PatrolLastPosition.Z
                        ).Magnitude
        
                        if SinceLast < CONFIG.PATROL_MIN_DISTANCE * 0.75 then
                            RepeatPenalty = 18
                        end
                    end
        
                    table.insert(Candidates, {
                        Position = Candidate,
                        Direction = ToCandidate.Magnitude > 0.01 and ToCandidate.Unit or Direction,
                        Score = TravelDistance * 0.20
                        - DirectionScore * 12
                            + CenterDistance * 0.08
                            + RepeatPenalty
                            + math.random() * 8,
                    })
                end
            end
        
            table.sort(Candidates, function(A, B)
                return A.Score < B.Score
            end)
        
            if #Candidates == 0 then
                return nil
            end
        
            --// Do not always choose the mathematically best candidate. Choosing from
            --// the first few valid candidates creates natural variation while keeping
            --// the patrol inside safe areas.
            local ChoiceCount = math.min(4, #Candidates)
            local CandidateIndex = math.random(1, ChoiceCount)
        
            for Index = 1, ChoiceCount do
                local Candidate = Candidates[Index]
        
                if AICFeature.IsPatrolPathInsideFarmArea(Candidate.Position)
                    and AICFeature.IsPatrolPathClear(Candidate.Position)
                    and AICFeature.HasPatrolEscapeSpace(Candidate.Position)
                then
                    if Index == CandidateIndex or ChoiceCount == 1 then
                        PatrolState.PatrolPosition = Candidate.Position
                        PatrolState.PatrolDirection = Candidate.Direction
                        PatrolState.PatrolLastDistance = (Candidate.Position - Origin).Magnitude
                        return Candidate.Position
                    end
                end
            end
        
            --// Fallback: use the first valid candidate if the random choice failed
            --// because one of the preferred candidates became invalid.
            for _, Candidate in ipairs(Candidates) do
                if AICFeature.IsPatrolPathInsideFarmArea(Candidate.Position)
                    and AICFeature.IsPatrolPathClear(Candidate.Position)
                then
                    PatrolState.PatrolPosition = Candidate.Position
                    PatrolState.PatrolDirection = Candidate.Direction
                    PatrolState.PatrolLastDistance = (Candidate.Position - Origin).Magnitude
                    return Candidate.Position
                end
            end
        
            return nil
        end
        
        --// Drops everything the patrol was in the middle of. Combat outranks
        --// patrolling, but the patrol state used to survive the interruption, so
        --// after a fight the character could sit out a pause it had started before
        --// the fight, or carry on a leg chain and a heading that no longer meant
        --// anything.
        function Feature.CancelPatrol()
            PatrolState.PatrolPosition = nil
            PatrolState.PatrolPauseUntil = 0
            PatrolState.PatrolLegsRemaining = 0
            PatrolState.PatrolHeading = nil
            PatrolState.PatrolArrivalDistance = 0
            PatrolState.PatrolCurveUntil = 0
            PatrolState.PatrolCurveBias = 0
            PatrolState.PatrolCurveRadius = 0
            PatrolState.LastPatrolCalculateTime = 0
        end
        function Feature.MoveToPatrol()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
        local FaceOrientation = Runtime:GetFaceOrientation()
            if not FeatureState.AutoPatrol.Enabled or not RootPart or not Humanoid then
                PatrolState.PatrolPosition = nil
                PatrolState.PatrolPauseUntil = 0
                PatrolState.PatrolHeading = nil
                PatrolState.PatrolLegsRemaining = 0
                return false
            end
        
            local now = os.clock()
        
            --// Short natural pauses between patrol destinations.
            if PatrolState.PatrolPauseUntil > now then
                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            local Position = AICFeature.GetAutoPatrolPosition()
        
            if not Position then
                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            local Offset = Position - RootPart.Position
            local Distance = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        
            --// Stop partway now and then without abandoning the destination, the way
            --// someone pauses mid walk. Rolled on an interval rather than per frame,
            --// otherwise the odds compound into stopping constantly.
            if now - PatrolState.PatrolMidwalkRollTime >= (tonumber(CONFIG.PATROL_MIDWALK_ROLL_INTERVAL) or 1.1) then
                PatrolState.PatrolMidwalkRollTime = now
        
                if Distance > CONFIG.PATROL_ARRIVAL_DISTANCE * 2
                    and math.random() < (tonumber(CONFIG.PATROL_MIDWALK_PAUSE_CHANCE) or 0.18)
                then
                    local Low = tonumber(CONFIG.PATROL_MIDWALK_PAUSE_MIN) or 0.4
                    local High = tonumber(CONFIG.PATROL_MIDWALK_PAUSE_MAX) or 1.5
        
                    PatrolState.PatrolPauseUntil = now + Low + math.random() * math.max(0, High - Low)
        
                    if FaceOrientation then
                        FaceOrientation.Enabled = false
                    end
                    Humanoid.AutoRotate = true
                    Humanoid:Move(Vector3.zero)
                    return false
                end
            end
        
            --// Nobody stops at exactly the same distance every time.
            if PatrolState.PatrolArrivalDistance <= 0 then
                PatrolState.PatrolArrivalDistance = CONFIG.PATROL_ARRIVAL_DISTANCE
                    + math.random() * (tonumber(CONFIG.PATROL_ARRIVAL_JITTER) or 2.5)
            end
        
            if Distance <= PatrolState.PatrolArrivalDistance then
                PatrolState.PatrolLastPosition = Position
                PatrolState.PatrolPosition = nil
                PatrolState.LastPatrolCalculateTime = 0
                PatrolState.PatrolArrivalDistance = 0
        
                --// Walk several legs back to back before resting. Stopping at every
                --// single point is the giveaway; a person crossing an area passes
                --// through corners without pausing at each one.
                if PatrolState.PatrolLegsRemaining > 0 then
                    PatrolState.PatrolLegsRemaining -= 1
                end
        
                if PatrolState.PatrolLegsRemaining > 0 then
                    --// Straight on to the next leg, no pause and no reset of the
                    --// smoothed aim point, so the corner is taken as a turn.
                    return false
                end
        
                --// Vary the idle time. Occasionally make the pause a little longer,
                --// similar to someone briefly deciding where to go next.
                local Pause = math.random() * (CONFIG.PATROL_PAUSE_MAX - CONFIG.PATROL_PAUSE_MIN)
                    + CONFIG.PATROL_PAUSE_MIN
        
                if math.random() < 0.12 then
                    Pause += math.random() * 1.5
                end
        
                PatrolState.PatrolPauseUntil = now + Pause
                PatrolState.PatrolLegsRemaining = math.random(
                    math.max(1, tonumber(CONFIG.PATROL_LEGS_MIN) or 1),
                    math.max(1, tonumber(CONFIG.PATROL_LEGS_MAX) or 4)
                )
        
                --// A rest ends the chain, so the next leg starts from a fresh bearing
                --// rather than curving out of a direction it is no longer walking.
                PatrolState.PatrolHeading = nil
                PatrolState.PatrolCurveUntil = 0
                PatrolState.PatrolCurveBias = 0
                PatrolState.PatrolCurveRadius = 0
        
                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            if not AICCombatUtils.IsInsideFarmArea(RootPart.Position) or AICCombatUtils.IsInsideFarmDeadzone(RootPart.Position) then
                PatrolState.PatrolPosition = nil
                PatrolState.LastPatrolCalculateTime = 0
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            if not AICFeature.IsPatrolPathInsideFarmArea(Position) then
                PatrolState.PatrolPosition = nil
                PatrolState.LastPatrolCalculateTime = 0
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return false
            end
        
            if FaceOrientation then
                FaceOrientation.Enabled = false
            end
            Humanoid.AutoRotate = true
        
            --// Switching destinations outright makes the character snap round on the
            --// spot. Walking at a point that eases toward the real destination turns
            --// that into a curve, which is also how a person changes direction.
            if PatrolState.PatrolLegsRemaining <= 0 then
                PatrolState.PatrolLegsRemaining = math.random(
                    math.max(1, tonumber(CONFIG.PATROL_LEGS_MIN) or 1),
                    math.max(1, tonumber(CONFIG.PATROL_LEGS_MAX) or 4)
                )
            end
        
            local SnapDistance = tonumber(CONFIG.PATROL_SMOOTH_SNAP_DISTANCE) or 7
            local Desired = Vector3.new(Offset.X, 0, Offset.Z)
        
            --// Close in, or with no bearing yet, walk straight at it. Steering near
            --// the destination would only orbit it.
            if Distance <= SnapDistance or Desired.Magnitude <= 0.01 then
                PatrolState.PatrolHeading = Desired.Magnitude > 0.01 and Desired.Unit or PatrolState.PatrolHeading
                PatrolState.PatrolSteerTime = now
                Humanoid:MoveTo(Position)
                return true
            end
        
            Desired = Desired.Unit
        
            --// Time step for the sweep and the steering below. Clamped so a frame
            --// spike cannot swing the bearing in one go. Taken before either uses it.
            local Delta = math.clamp(now - PatrolState.PatrolSteerTime, 0, 0.25)
            PatrolState.PatrolSteerTime = now
        
            --// Now and then walk an arc instead of the straight bearing, described by
            --// the radius it is walked at. Radius is the part that shows: a small one
            --// loops tightly, a large one is barely a drift. The turn rate that holds
            --// a radius is speed over radius, so the shape survives any walk speed
            --// rather than changing with it.
            if now - PatrolState.PatrolCurveRollTime >= (tonumber(CONFIG.PATROL_RANDOM_CURVE_ROLL_INTERVAL) or 2.6) then
                PatrolState.PatrolCurveRollTime = now
        
                if now >= PatrolState.PatrolCurveUntil
                    and math.random() < (tonumber(CONFIG.PATROL_RANDOM_CURVE_CHANCE) or 0.22)
                then
                    local MinRadius = math.max(1, tonumber(CONFIG.PATROL_CURVE_RADIUS_MIN) or 12)
                    local MaxRadius = math.max(MinRadius, tonumber(CONFIG.PATROL_CURVE_RADIUS_MAX) or 55)
                    local MinTime = tonumber(CONFIG.PATROL_RANDOM_CURVE_MIN_TIME) or 1.2
                    local MaxTime = tonumber(CONFIG.PATROL_RANDOM_CURVE_MAX_TIME) or 2.5
        
                    PatrolState.PatrolCurveRadius = MinRadius + math.random() * (MaxRadius - MinRadius)
                    PatrolState.PatrolCurveSide = math.random(0, 1) == 0 and -1 or 1
                    PatrolState.PatrolCurveUntil = now + MinTime + math.random() * math.max(0, MaxTime - MinTime)
                    PatrolState.PatrolCurveBias = 0
                end
            end
        
            local CurveRadius = math.max(tonumber(PatrolState.PatrolCurveRadius) or 0, 0)
            local CurveBias = tonumber(PatrolState.PatrolCurveBias) or 0
            local MaxSweep = math.rad(tonumber(CONFIG.PATROL_CURVE_MAX_SWEEP) or 48)
            local Speed = math.max(Humanoid.WalkSpeed, 1)
        
            if now < PatrolState.PatrolCurveUntil and CurveRadius > 0 then
                --// Capped, so a long curve bends the route instead of closing it
                --// into a circle.
                CurveBias = math.clamp(
                    CurveBias + (Speed / CurveRadius) * Delta * (PatrolState.PatrolCurveSide or 1),
                    -MaxSweep,
                    MaxSweep
                )
            elseif CurveBias ~= 0 then
                --// Unwind at the rate it was wound on, so the route eases back onto
                --// the bearing rather than snapping straight.
                local Unwind = (Speed / math.max(CurveRadius, 1)) * Delta
        
                if math.abs(CurveBias) <= Unwind then
                    CurveBias = 0
                    PatrolState.PatrolCurveRadius = 0
                else
                    CurveBias -= Unwind * (CurveBias > 0 and 1 or -1)
                end
            end
        
            PatrolState.PatrolCurveBias = CurveBias
        
            if CurveBias ~= 0 then
                local Biased = CFrame.fromAxisAngle(Vector3.yAxis, CurveBias):VectorToWorldSpace(Desired)
                Biased = Vector3.new(Biased.X, 0, Biased.Z)
        
                if Biased.Magnitude > 0.01 then
                    Desired = Biased.Unit
                end
            end
        
            if not PatrolState.PatrolHeading then
                PatrolState.PatrolHeading = Desired
            end
        
            --// Turn the heading toward the new bearing at a limited rate. Walking at
            --// a point a short way along that heading is what draws the arc: the
            --// character leans into the turn instead of rotating on the spot.
        
            local Dot = math.clamp(PatrolState.PatrolHeading:Dot(Desired), -1, 1)
            local Angle = math.acos(Dot)
        
            if Angle > math.rad(tonumber(CONFIG.PATROL_CURVE_MIN_ANGLE) or 12) then
                --// Sign of the Y component of the cross product gives the turn side.
                local Side = PatrolState.PatrolHeading:Cross(Desired).Y < 0 and -1 or 1
                local MaxStep = math.rad(tonumber(CONFIG.PATROL_TURN_RATE) or 150) * Delta
                local Step = math.min(Angle, MaxStep) * Side
        
                local Turned = CFrame.fromAxisAngle(Vector3.yAxis, Step):VectorToWorldSpace(PatrolState.PatrolHeading)
                Turned = Vector3.new(Turned.X, 0, Turned.Z)
        
                if Turned.Magnitude > 0.01 then
                    PatrolState.PatrolHeading = Turned.Unit
                end
            else
                --// Near enough to straight: stop steering and commit to the bearing.
                PatrolState.PatrolHeading = Desired
            end
        
            local Aim = RootPart.Position + PatrolState.PatrolHeading * math.min(
                tonumber(CONFIG.PATROL_LOOKAHEAD) or 11,
                Distance
            )
        
            --// The arc must not curve into ground the patrol is not allowed on. If it
            --// would, give up the curve for this frame and head straight at the
            --// destination, which is already known to be valid.
            if not AICCombatUtils.IsInsideFarmArea(Aim) or AICCombatUtils.IsInsideFarmDeadzone(Aim) then
                PatrolState.PatrolHeading = Desired
                Humanoid:MoveTo(Position)
                return true
            end
        
            Humanoid:MoveTo(Aim)
        
            return true
        end

        AICFeature.IsPatrolPathClear = function(...) return Feature.IsPatrolPathClear(...) end
        AICFeature.IsPatrolPathInsideFarmArea = function(...) return Feature.IsPatrolPathInsideFarmArea(...) end
        AICFeature.HasPatrolEscapeSpace = function(...) return Feature.HasPatrolEscapeSpace(...) end
        AICFeature.GetAutoPatrolPosition = function(...) return Feature.GetAutoPatrolPosition(...) end
        AICFeature.CancelPatrol = function(...) return Feature.CancelPatrol(...) end
        AICFeature.MoveToPatrol = function(...) return Feature.MoveToPatrol(...) end

        function Feature:SetEnabled(Value)
            self.Enabled = Value == true
            if FeatureState.AutoPatrol then
                FeatureState.AutoPatrol.Enabled = self.Enabled
            end
        end

        function Feature:CreateUI()
            if UIRef.FeatureSection and UIRef.FeatureSection.AddToggle then
                self.Enabled = FeatureState.AutoPatrol.Enabled == true
                self.Button = UIRef.FeatureSection:AddToggle{
                    Name = "Auto Patrol",
                    Default = self.Enabled,
                    Callback = function(Value)
                        self:SetEnabled(Value)

                        PatrolState.PatrolPosition = nil
                        PatrolState.LastPatrolCalculateTime = 0
                        PatrolState.PatrolDirection = nil
                        PatrolState.PatrolPauseUntil = 0
                        PatrolState.PatrolLastPosition = nil
                        PatrolState.PatrolLastDistance = 0
                        AICProfile.SaveActiveProfile()
                    end,
                }
                FeatureState.AutoPatrol.Button = self.Button
            end
        end

        function Feature:Update()
            -- AutoFarming owns movement arbitration; this module owns patrol state.
        end

        Feature:CreateUI()

        return Feature
    end,
}
