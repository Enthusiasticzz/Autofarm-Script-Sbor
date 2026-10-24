-- WalkController walks Auto Mining and Auto Smithing to a spot.
--
-- Pathfinding comes first whenever the straight line is not clean: an
-- obstacle in the body's way taller than a hop (MAX_HOP_RISE), a hole too
-- wide to jump, a climb higher than a jump, a deadzone, or (with
-- KeepInsideMine) leaving the mine zone. An open line is walked straight;
-- a jumpable hole is jumped at its edge and a low bump is hopped. Paths are solved off the heartbeat, so a slow solve never stalls a
-- frame, and a path that enters a deadzone (or leaves the mine zone) is
-- refused.
--
-- When the solver finds no path, the walk detours: it steps toward the
-- open side of the obstacle nearest the heading, then tries the straight
-- line and the path again from there. Only after MAX_DETOURS in a row
-- bring it no closer does it report "failed"; an obstacle low enough to
-- hop is then still jumped as a last resort.
return {
    Name = "WalkController",
    Dependencies = {"Runtime", "CombatUtils"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local PathfindingService = Services.PathfindingService
        local FeatureState = Context.Feature
        local AICCombatUtils = Context.AICCombatUtils

        --// How often the straight line is re-tested; holes need this often
        --// enough to jump at the edge rather than past it.
        local DIRECT_CHECK_INTERVAL = 0.1
        --// Taller than this above the feet needs a path, not a straight walk.
        local MAX_DIRECT_RISE = 6
        --// How far ahead the body probe looks for obstacles.
        local OBSTACLE_PROBE_DISTANCE = 8
        --// The body probe: as wide as the character, from BODY_PROBE_LIFT
        --// above the feet (over steps a walk takes in stride) to head height.
        local BODY_PROBE_SIZE = Vector3.new(2.4, 3.5, 2.4)
        local BODY_PROBE_LIFT = 1
        --// A surface facing up more than this is ground to walk up, not a wall.
        local WALKABLE_NORMAL_Y = 0.6
        --// Jump once the hole edge is this close.
        local HOLE_JUMP_EDGE = 2.5
        --// An obstacle with nothing above this height over it (measured from
        --// the feet) is a bump: walked straight at and hopped, not pathed
        --// round. HOP_LANDING is the clear room needed past its edge.
        local MAX_HOP_RISE = 3
        local HOP_LANDING = 2
        --// Hop once the bump is this close.
        local HOP_EDGE = 2
        --// Once on a path, stay on it at least this long so a borderline
        --// straight line does not flip the mode every frame.
        local PATH_HOLD_SECONDS = 4
        local PATH_RECALCULATE_INTERVAL = 3
        local PATH_RETRY_INTERVAL = 2
        local PATH_WAYPOINT_REACH = 3
        local PATH_DESTINATION_TOLERANCE = 4
        --// Jumping has not freed the character for this long: take a path,
        --// or solve the one being walked again.
        local STUCK_PATH_SECONDS = 1.5
        local ZONE_SAMPLE_DISTANCE = 4
        --// Detours, tried nearest the heading first, on alternating sides.
        local DETOUR_ANGLES = { 30, 60, 90, 120, 150 }
        local DETOUR_PROBE_DISTANCE = 10
        --// A side needs at least this much open ground to be worth a detour.
        local DETOUR_MIN_FREE = 4
        local DETOUR_REACH = 2
        local DETOUR_TIMEOUT = 2.5
        local MAX_DETOURS = 4
        --// Closer to the destination by this much counts as progress.
        local DETOUR_PROGRESS = 2

        local Movement = {
            Name = "WalkController",
            S = {
                Holding = false,
                PathUntil = 0,
                StuckSince = nil,
                LastDirectCheck = 0,
                DirectBlocked = false,
                --// The straight line is unsafe (hole, climb, deadzone, zone),
                --// not merely obstructed.
                Unsafe = false,
                HoleCanJump = false,
                HoleEdge = nil,
                --// Distance to an obstacle on the straight line low enough
                --// to hop, or nil.
                BumpDistance = nil,
                PathToken = 0,
                Path = {},
                Detour = nil,
                DetourSide = 1,
                DetourCount = 0,
                BestDistance = math.huge,
                ProgressDestination = nil,
            },
        }

        local S = Movement.S

        local function CanUseGround(Position, KeepInsideMine)
            if not FeatureState.IgnoreFarmZone.Enabled and AICCombatUtils.IsInsideFarmDeadzone(Position) then
                return false
            end

            return not KeepInsideMine or AICCombatUtils.IsInsideMineZone(Position)
        end

        local function SegmentStaysInMine(From, To)
            local Offset = To - From
            local Distance = Offset.Magnitude

            if Distance <= 0 then
                return AICCombatUtils.IsInsideMineZone(To)
            end

            for Travelled = ZONE_SAMPLE_DISTANCE, Distance, ZONE_SAMPLE_DISTANCE do
                if not AICCombatUtils.IsInsideMineZone(From + Offset.Unit * Travelled) then
                    return false
                end
            end

            return AICCombatUtils.IsInsideMineZone(To)
        end

        local function BuildWallParams(Character, IgnoreModel)
            local Filter = { Character }

            if IgnoreModel then
                table.insert(Filter, IgnoreModel)
            end

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

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = Filter
            return Params
        end

        local function GetFeet(RootPart, Humanoid)
            --// R6 legs are not counted in HipHeight.
            local Hip = Humanoid.RigType == Enum.HumanoidRigType.R6 and 2 or Humanoid.HipHeight
            return RootPart.Position - Vector3.new(0, Hip + RootPart.Size.Y * 0.5, 0)
        end

        --// How far the body gets along Direction (flat, unit) before it hits
        --// something that is not walkable ground, or nil when nothing.
        local function CastBody(RootPart, Humanoid, Params, Direction, Distance)
            local Center = GetFeet(RootPart, Humanoid) + Vector3.new(0, BODY_PROBE_LIFT + BODY_PROBE_SIZE.Y * 0.5, 0)
            local Hit = workspace:Blockcast(CFrame.new(Center), BODY_PROBE_SIZE, Direction * Distance, Params)

            if Hit and Hit.Normal.Y < WALKABLE_NORMAL_Y then
                return Hit.Distance
            end

            return nil
        end

        --// A body probe lifted MAX_HOP_RISE: nothing there over the obstacle
        --// and HOP_LANDING past it means a jump clears it.
        local function IsHoppable(RootPart, Humanoid, Params, Direction, HitDistance)
            local Center = GetFeet(RootPart, Humanoid) + Vector3.new(0, MAX_HOP_RISE + BODY_PROBE_SIZE.Y * 0.5, 0)
            return workspace:Blockcast(CFrame.new(Center), BODY_PROBE_SIZE, Direction * (HitDistance + HOP_LANDING), Params) == nil
        end

        --// Blocked, and the distance to an obstacle low enough to hop (nil
        --// when there is none, or the one ahead is too tall to hop).
        local function CheckObstacleAhead(RootPart, Humanoid, Character, Destination, IgnoreModel)
            local Offset = Destination - RootPart.Position
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= 0.5 then
                return false, nil
            end

            local Params = BuildWallParams(Character, IgnoreModel)
            local Distance = math.min(Flat.Magnitude, OBSTACLE_PROBE_DISTANCE)
            local HitDistance = CastBody(RootPart, Humanoid, Params, Flat.Unit, Distance)

            if not HitDistance then
                return false, nil
            end

            if IsHoppable(RootPart, Humanoid, Params, Flat.Unit, HitDistance) then
                return false, HitDistance
            end

            return true, nil
        end

        --// Re-tests the straight line at most every DIRECT_CHECK_INTERVAL.
        local function UpdateDirectCheck(now, RootPart, Humanoid, Character, Destination, Options)
            if now - S.LastDirectCheck < DIRECT_CHECK_INTERVAL then
                return
            end

            S.LastDirectCheck = now

            local IsHole, CanJump, Edge = AICCombatUtils.IsHoleAhead(Destination)
            S.HoleCanJump = IsHole and CanJump
            S.HoleEdge = Edge

            S.Unsafe = (IsHole and not CanJump)
                or Destination.Y - RootPart.Position.Y > MAX_DIRECT_RISE
                or AICCombatUtils.IsPathThroughDeadzone(Destination)
                or (Options.KeepInsideMine and not SegmentStaysInMine(RootPart.Position, Destination))

            local Blocked, BumpDistance = CheckObstacleAhead(RootPart, Humanoid, Character, Destination, Options.Ignore)
            S.BumpDistance = BumpDistance
            S.DirectBlocked = S.Unsafe or Blocked
        end

        local function JumpHoleIfClose()
            if S.HoleCanJump and S.HoleEdge and S.HoleEdge <= HOLE_JUMP_EDGE then
                AICCombatUtils.DoJump()
            end
        end

        local function JumpBumpIfClose()
            if S.BumpDistance and S.BumpDistance <= HOP_EDGE then
                AICCombatUtils.DoJump()
            end
        end

        local function IsRouteAllowed(Waypoints, KeepInsideMine)
            for Index = 2, #Waypoints do
                if not CanUseGround(Waypoints[Index].Position, KeepInsideMine) then
                    return false
                end
            end

            return true
        end

        local function RequestPath(RootPart, Destination, KeepInsideMine)
            local Path = S.Path
            local From = RootPart.Position
            local AgentRadius = math.max(RootPart.Size.X * 0.5, 2)
            local AgentHeight = math.max(RootPart.Size.Y, 5)

            S.PathToken += 1
            local Token = S.PathToken
            Path.Computing = true

            task.spawn(function()
                local Solver = PathfindingService:CreatePath({
                    AgentRadius = AgentRadius,
                    AgentHeight = AgentHeight,
                    AgentCanJump = true,
                    WaypointSpacing = 4,
                })

                local Ok = pcall(function()
                    Solver:ComputeAsync(From, Destination)
                end)

                --// Reset or superseded while solving.
                if Token ~= S.PathToken then
                    return
                end

                Path.Computing = false

                local Waypoints = Ok and Solver.Status == Enum.PathStatus.Success and Solver:GetWaypoints()

                if not Waypoints or #Waypoints < 2 or not IsRouteAllowed(Waypoints, KeepInsideMine) then
                    Path.Waypoints = nil
                    Path.FailedAt = os.clock()
                    return
                end

                Path.Waypoints = Waypoints
                Path.Index = 2
                Path.Destination = Destination
                Path.Time = os.clock()
                Path.FailedAt = nil
            end)
        end

        --// "moving", "waiting" while a path is being solved, "failed" when
        --// no allowed path exists, or "done" once the path is walked.
        local function FollowPath(now, RootPart, Humanoid, Destination, KeepInsideMine)
            local Path = S.Path
            local Stale = not Path.Waypoints
                or (Path.Destination - Destination).Magnitude > PATH_DESTINATION_TOLERANCE
                or now - Path.Time >= PATH_RECALCULATE_INTERVAL
            local MayRetry = not Path.FailedAt or now - Path.FailedAt >= PATH_RETRY_INTERVAL

            if Stale and not Path.Computing and MayRetry then
                RequestPath(RootPart, Destination, KeepInsideMine)
            end

            if not Path.Waypoints then
                return Path.Computing and "waiting" or "failed"
            end

            while Path.Index <= #Path.Waypoints do
                local Waypoint = Path.Waypoints[Path.Index]

                if AICCombatUtils.GetHorizontalDistance(Waypoint.Position, RootPart.Position) <= PATH_WAYPOINT_REACH then
                    Path.Index += 1
                    continue
                end

                --// The solver marks jumps generously; only take one when
                --// something is in the way or the character has stalled.
                if Waypoint.Action == Enum.PathWaypointAction.Jump
                    and (AICCombatUtils.IsJumpableObstacleAhead(Waypoint.Position) or AICCombatUtils.IsStuck())
                then
                    AICCombatUtils.DoJump()
                end

                JumpHoleIfClose()
                Humanoid:MoveTo(Waypoint.Position)
                return "moving"
            end

            Path.Waypoints = nil
            S.PathUntil = 0
            return "done"
        end

        local function UpdateStuck(now)
            if not AICCombatUtils.IsStuck() then
                S.StuckSince = nil
                return
            end

            S.StuckSince = S.StuckSince or now
            AICCombatUtils.DoJump()

            if now - S.StuckSince >= STUCK_PATH_SECONDS then
                --// Already on a path and still stuck: solve it again from here.
                if now < S.PathUntil then
                    S.Path.Time = 0
                end

                S.PathUntil = now + PATH_HOLD_SECONDS
                S.StuckSince = nil
                AICCombatUtils.ResetStuckTracker()
            end
        end

        ------------------------------------------------------------------------
        --// Detours, for when the solver finds no path
        ------------------------------------------------------------------------

        --// Detours are only worth repeating while they lead somewhere.
        local function TrackProgress(RootPart, Destination)
            if not S.ProgressDestination
                or (S.ProgressDestination - Destination).Magnitude > PATH_DESTINATION_TOLERANCE
            then
                S.ProgressDestination = Destination
                S.BestDistance = math.huge
                S.DetourCount = 0
            end

            local Distance = (Destination - RootPart.Position).Magnitude

            if Distance < S.BestDistance - DETOUR_PROGRESS then
                S.BestDistance = Distance
                S.DetourCount = 0
            end
        end

        local function IsDetourAllowed(RootPart, Candidate, KeepInsideMine)
            local IsHole, CanJump = AICCombatUtils.IsHoleAhead(Candidate)

            return CanUseGround(Candidate, KeepInsideMine)
                and not (IsHole and not CanJump)
                and not AICCombatUtils.IsPathThroughDeadzone(Candidate)
                and not (KeepInsideMine and not SegmentStaysInMine(RootPart.Position, Candidate))
        end

        --// The open side nearest the heading, starting on the other side
        --// from last time so two detours do not hit the same wall.
        local function FindDetour(RootPart, Humanoid, Character, Destination, Options)
            local Offset = Destination - RootPart.Position
            local Heading = Vector3.new(Offset.X, 0, Offset.Z)
            Heading = Heading.Magnitude > 0.01 and Heading.Unit or RootPart.CFrame.LookVector

            local Params = BuildWallParams(Character, Options.Ignore)
            S.DetourSide = -S.DetourSide

            for _, Angle in ipairs(DETOUR_ANGLES) do
                for _, Sign in ipairs({ S.DetourSide, -S.DetourSide }) do
                    local Direction = CFrame.Angles(0, math.rad(Angle * Sign), 0):VectorToWorldSpace(Heading)
                    local HitDistance = CastBody(RootPart, Humanoid, Params, Direction, DETOUR_PROBE_DISTANCE)
                    local Free = HitDistance and HitDistance - 1 or DETOUR_PROBE_DISTANCE

                    if Free >= DETOUR_MIN_FREE then
                        local Candidate = RootPart.Position + Direction * Free

                        if IsDetourAllowed(RootPart, Candidate, Options.KeepInsideMine) then
                            return Candidate
                        end
                    end
                end
            end

            return nil
        end

        local function StartDetour(now, RootPart, Humanoid, Character, Destination, Options)
            if S.DetourCount >= MAX_DETOURS then
                return false
            end

            local Position = FindDetour(RootPart, Humanoid, Character, Destination, Options)

            if not Position then
                return false
            end

            S.DetourCount += 1
            S.Detour = { Position = Position, Until = now + DETOUR_TIMEOUT }
            AICCombatUtils.ResetStuckTracker()
            return true
        end

        --// True while a detour has this frame. Once reached (or timed out),
        --// the straight line and the path are tried again from there.
        local function WalkDetour(now, RootPart, Humanoid)
            local Detour = S.Detour

            if not Detour then
                return false
            end

            if now > Detour.Until or AICCombatUtils.GetHorizontalDistance(RootPart.Position, Detour.Position) <= DETOUR_REACH then
                S.Detour = nil
                S.PathUntil = 0
                S.LastDirectCheck = 0
                return false
            end

            AICCombatUtils.DoJumpIfObstacle(Detour.Position)
            Humanoid:MoveTo(Detour.Position)
            return true
        end

        ------------------------------------------------------------------------

        --// Stands still. A MoveTo stays active until reached, so it is
        --// cancelled once by moving to where we already are.
        function Movement:Hold()
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return
            end

            if not S.Holding then
                S.Holding = true
                Humanoid:MoveTo(RootPart.Position)
            end

            Humanoid:Move(Vector3.zero)
        end

        --// Options:
        --//   Ignore          model the obstacle probes look through (the ore)
        --//   KeepInsideMine  never step outside the mine zones
        --// Returns "moving", "waiting" (standing while a path is solved) or
        --// "failed" (no allowed way there).
        function Movement:MoveTo(Destination, Options)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return "failed"
            end

            Options = Options or {}

            local now = os.clock()
            local FaceOrientation = Runtime:GetFaceOrientation()

            if FaceOrientation then
                FaceOrientation.Enabled = false
            end

            Humanoid.AutoRotate = true
            S.Holding = false

            UpdateStuck(now)
            TrackProgress(RootPart, Destination)

            if WalkDetour(now, RootPart, Humanoid) then
                return "moving"
            end

            UpdateDirectCheck(now, RootPart, Humanoid, Character, Destination, Options)

            if S.DirectBlocked and now >= S.PathUntil then
                S.PathUntil = now + PATH_HOLD_SECONDS
            end

            if now < S.PathUntil then
                local Result = FollowPath(now, RootPart, Humanoid, Destination, Options.KeepInsideMine)

                if Result == "moving" then
                    return Result
                end

                if Result == "waiting" then
                    self:Hold()
                    return Result
                end

                --// No path: go round the obstacle and try again from there.
                if Result == "failed" then
                    if StartDetour(now, RootPart, Humanoid, Character, Destination, Options) then
                        WalkDetour(now, RootPart, Humanoid)
                        return "moving"
                    end

                    --// Out of detours. Never walk an unsafe line (the hole or
                    --// the deadzone); an obstacle is still hopped if it is low
                    --// enough, otherwise give up.
                    if S.Unsafe or (S.DirectBlocked and not AICCombatUtils.IsJumpableObstacleAhead(Destination)) then
                        self:Hold()
                        return "failed"
                    end
                end
            end

            JumpHoleIfClose()
            JumpBumpIfClose()
            AICCombatUtils.DoJumpIfObstacle(Destination)
            Humanoid:MoveTo(Destination)
            return "moving"
        end

        --// A ground spot Standoff studs out from Part's surface, on our side.
        --// Ores and tables are solid, so neither MoveTo nor a path can end
        --// inside one. Ignore is the model Part belongs to.
        function Movement:GetApproachPoint(Part, Standoff, Ignore)
            local Character, _, RootPart = Runtime:GetCharacter()
            local Offset = RootPart and RootPart.Position - Part.Position or Vector3.xAxis
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)
            local Direction = Flat.Magnitude > 0.01 and Flat.Unit or Vector3.xAxis
            local Point = Part.Position + Direction * (math.max(Part.Size.X, Part.Size.Z) * 0.5 + Standoff)

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = { Character, Ignore, AICCombatUtils.S.DebugFolder }

            local Hit = workspace:Raycast(Point + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), Params)

            return Hit and Hit.Position + Vector3.new(0, 3, 0) or Point
        end

        function Movement:Reset()
            S.PathToken += 1
            S.Holding = false
            S.PathUntil = 0
            S.StuckSince = nil
            S.LastDirectCheck = 0
            S.DirectBlocked = false
            S.BumpDistance = nil
            S.Unsafe = false
            S.HoleCanJump = false
            S.HoleEdge = nil
            S.Detour = nil
            S.DetourCount = 0
            S.BestDistance = math.huge
            S.ProgressDestination = nil
            table.clear(S.Path)
        end

        return Movement
    end,
}
