-- BossNavigator walks a saved route of boss stops, fighting at each one.
--
-- It has its own tab and its own list (Boss Route on the place config), so it
-- is separate from the waypoint route Auto Farm walks and from the waypoints
-- in Profile Settings: editing one never moves the other. A stop is a spot to
-- stand on. Coming to a stop the character walks there, or teleports to one of
-- the game's waypoints first when the stop names one, then waits Wait seconds
-- and fights whatever matches its Boss Names inside its radius.
--
-- A fight ends when the target dies and nothing else is in the radius, or
-- when nothing is there to fight at all. With Reset After Kill on (the default
-- for a new stop) the character is then reset, so the next stop is travelled
-- to from spawn. Reset After is only a timeout for a fight that drags on
-- (0 = never, fight until the boss is down).
-- Wait Exp holds the next stop until the game's EXP actually dropped after the
-- reset, so the loss is registered before walking off. A stop with it off
-- moves on after Wait After Reset instead.
--
-- The route loops unless Loop Route is off; then it plays once and switches
-- itself off. Travel is a PathfindingService path followed waypoint by
-- waypoint. The path sidesteps obstacles; the mining walker's detour probes
-- did not, which made the character pace backwards and sideways. Where the
-- game has no navmesh the solver fails, and driving at the stop in a straight
-- line ran into buildings; that case now uses a probe-ray heading that walks
-- round walls instead. The fight uses the same combat inputs as Auto Farm.
-- Auto Farm hands this module the frame while it is on, with Auto Farm on or
-- off.
return {
    Name = "BossNavigator",
    IsFeature = true,
    Dependencies = {
        "Runtime",
        "SaveConfig",
        "ProfileManager",
        "Components",
        "CombatUtils",
        "Navigation",
        "Combat",
    },

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local PathfindingService = Context.Services.PathfindingService
        local Players = Context.Services.Players
        local AICCombatUtils = Context.AICCombatUtils
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICFeature = Context.AICFeature
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// How close to the stop counts as standing on it, when the place has
        --// no reach distance of its own.
        local REACH_DISTANCE = 5
        --// Waited after a waypoint teleport, so the character lands before
        --// the walk to the spot starts.
        local TELEPORT_WAIT = 2
        --// Mob scan interval. The folder is read whole, so not every frame.
        local SCAN_INTERVAL = 0.2
        --// Nothing matching at the spot for this long: move on.
        local NO_TARGET_TIMEOUT = 5
        --// The target just died; this long with nothing else there counts as
        --// the boss being down.
        local KILL_GRACE = 2
        --// A reset whose character never comes back gives up after this.
        local RESPAWN_TIMEOUT = 20
        --// Longest wait for the EXP drop after a reset, when Wait Exp is on.
        local EXP_LOSS_TIMEOUT = 15
        --// Walking to a stop this long means it cannot be reached.
        local WALK_TIMEOUT = 120
        --// No progress toward the stop for this long (no navmesh, a sealed
        --// room, a wall the steering keeps sliding along): skip it instead of
        --// standing there until WALK_TIMEOUT.
        local NO_PROGRESS_TIMEOUT = 20
        --// Path following. A path is solved off the frame and its waypoints are
        --// walked in order; it is solved again only when the destination has
        --// moved, the path is old, or the character is stuck, so the character
        --// never paces around deciding where to go.
        local PATH_SPACING = 4
        local PATH_MAX_AGE = 8
        local PATH_DEST_TOLERANCE = 4
        local PATH_WAYPOINT_REACH = 3
        local PATH_RETRY = 2
        local PATH_STUCK_SECONDS = 1.5
        --// A stuck check samples the position this often, and counts as stuck
        --// when less than this many studs were covered in that window.
        local STUCK_SAMPLE = 0.5
        local STUCK_DISTANCE = 0.75
        --// Steering, for games where PathfindingService has no navmesh. The
        --// heading is picked from rays fanned around the goal direction and
        --// kept while it stays clear, so a wall is followed instead of the
        --// character running into it and turning every frame.
        local STEER_PROBE = 6
        local STEER_SHORT_PROBE = 2.5
        local STEER_STEP = 5
        local STEER_SAMPLE = 0.15
        --// Longest a heading is held before it is looked at again, so walking
        --// along a wall cannot turn into walking away from the stop forever.
        local STEER_HOLD = 1.2
        --// How far from a wall the slide tries to keep the character.
        local STEER_WALL_STANDOFF = 2.5
        --// How far ahead the straight way to the stop is checked before a wall
        --// is considered gone. Six studs said "clear" with the building still
        --// in the way, so the character turned into it again and sawed.
        local STEER_GOAL_PROBE = 40
        local STEER_BACKOFF = 0.7
        local STEER_ANGLES = { 0, 30, -30, 60, -60, 90, -90, 120, -120, 150, -150 }
        local STEER_RAY_HEIGHTS = { 1.2, 3.5 }
        local STEER_RAY_OFFSETS = { -0.9, 0, 0.9 }
        --// How far below the feet a step may land and still be taken.
        local STEER_STEP_DOWN = 7
        --// How far from the character a mob name is offered in the picker.
        local NAME_SCAN_RADIUS = 300
        --// The status line is rewritten at most this often.
        local STATUS_INTERVAL = 0.5
        --// Longest a stop name may be, for the list.
        local MAX_LABEL_LENGTH = 32

        local Feature = {
            Name = "BossNavigator",
            IsFeature = true,
            S = {
                --// "Idle", "Approach", "Wait", "Fight", "Recover" or "Done".
                Phase = "Idle",
                Index = 1,
                PhaseStart = 0,
                FightStart = nil,
                WaitUntil = nil,
                WalkStart = nil,
                Teleported = false,
                --// A target was fought at this stop, so its absence now means
                --// the boss is down rather than not spawned yet.
                SeenTarget = false,
                KillAt = nil,
                --// EXP before the reset, and when to stop waiting for it.
                ExpBefore = nil,
                SkipExpCheck = true,
                ExpDeadline = 0,
                RecoveredAt = nil,
                --// Closest the character has been to the stop this visit, and
                --// when it was last closer than before. A stop the character
                --// stops approaching is the only unreachable stop.
                BestDistance = nil,
                LastProgressAt = nil,
                --// Per visit, for the status line.
                Resets = 0,
            },
        }

        local S = Feature.S

        AICProfile.S.SelectedBossStopIndex = AICProfile.S.SelectedBossStopIndex or 1

        local LastStatus = ""
        local LastStatusTime = 0

        --// The status line, rewritten only when it changes or after
        --// STATUS_INTERVAL, so countdowns can be shown without churn.
        local function SetStatus(Text)
            local Now = os.clock()

            if Text == LastStatus and Now - LastStatusTime < STATUS_INTERVAL then
                return
            end

            LastStatus = Text
            LastStatusTime = Now

            if UIRef.BossStatusLabel then
                UIRef.BossStatusLabel.Text = "STATUS:  " .. tostring(Text)
            end
        end

        --// The saved toggle is the one state: the profile load, the tab's
        --// toggle and the end-of-route switch-off all write it, so no copy of
        --// it here can drift out of step (the feature is BossRoute while the
        --// module is BossNavigator, so the module table is not sync'd for us).
        local function IsEnabled()
            return FeatureState.BossRoute ~= nil and FeatureState.BossRoute.Enabled == true
        end

        local function GetStops()
            local PlaceConfig = Runtime:GetPlaceConfig()
            return PlaceConfig and PlaceConfig.BOSS_ROUTE or {}
        end

        local function CurrentStop()
            return GetStops()[S.Index]
        end

        local function SelectedStop()
            return GetStops()[AICProfile.S.SelectedBossStopIndex]
        end

        --// Boss stops are place config, so they need a profile to be written
        --// to, the same rule as waypoints and zones.
        local function CanEdit(Message)
            if AICProfile.S.ActiveProfileName then
                return true
            end

            SetStatus("CREATE / LOAD PROFILE FIRST")
            AICUI.SetProfileStatus(Message or "CREATE / LOAD PROFILE FIRST")
            return false
        end

        local function Say(Action, Message, Duration)
            if NotifyAction then
                NotifyAction(Action or "Boss Route", Message, Duration or 3)
            end
        end

        local function GetExp()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Exp = PlayerStats and PlayerStats:FindFirstChild("EXP")
            return Exp and tonumber(Exp.Value) or nil
        end

        ------------------------------------------------------------------------
        --// Travel: one path, followed waypoint by waypoint
        ------------------------------------------------------------------------

        local PathState = {
            Waypoints = nil,
            Index = 1,
            Destination = nil,
            Time = 0,
            Computing = false,
            Token = 0,
            FailedAt = 0,
            StuckSince = nil,
            LastPosition = nil,
            SampleAt = nil,
        }

        local function ResetPath()
            PathState.Token += 1
            PathState.Waypoints = nil
            PathState.Index = 1
            PathState.Destination = nil
            PathState.Computing = false
            PathState.FailedAt = 0
            PathState.StuckSince = nil
            PathState.LastPosition = nil
            PathState.SampleAt = nil
        end

        --// A path to Destination, solved off the frame. The path already in
        --// hand keeps being walked while the next one is solved, so a
        --// recalculation is never a pause or a step in another direction.
        local function RequestPath(From, Destination)
            local _, _, RootPart = Runtime:GetCharacter()

            PathState.Token += 1
            local Token = PathState.Token
            PathState.Computing = true
            PathState.Destination = Destination

            local Start = From
            local Radius = RootPart and math.max(RootPart.Size.X * 0.5, 2) or 2

            task.spawn(function()
                local Solver = PathfindingService:CreatePath({
                    AgentRadius = Radius,
                    AgentHeight = 5,
                    AgentCanJump = true,
                    WaypointSpacing = PATH_SPACING,
                })

                local Ok = pcall(function()
                    Solver:ComputeAsync(Start, Destination)
                end)

                --// Reset or superseded while solving.
                if Token ~= PathState.Token then
                    return
                end

                PathState.Computing = false

                local Waypoints = Ok and Solver.Status == Enum.PathStatus.Success and Solver:GetWaypoints()

                if not Waypoints or #Waypoints < 2 then
                    PathState.Waypoints = nil
                    PathState.FailedAt = os.clock()
                    return
                end

                PathState.Waypoints = Waypoints
                PathState.Index = 2
                PathState.Time = os.clock()
                PathState.FailedAt = 0
            end)
        end

        ------------------------------------------------------------------------
        --// Steering: walking round walls where the game has no navmesh
        ------------------------------------------------------------------------

        local Steer = {
            Direction = nil,
            Params = nil,
            Key = nil,
            DecidedAt = 0,
            ChosenAt = 0,
            Side = 0,
            BackOffPoint = nil,
            BackOffUntil = 0,
            NoHeadingAt = nil,
            Sliding = false,
        }

        local function RotateFlat(Direction, Degrees)
            local Radians = math.rad(Degrees)
            local Cos, Sin = math.cos(Radians), math.sin(Radians)

            return Vector3.new(
                Direction.X * Cos - Direction.Z * Sin,
                0,
                Direction.X * Sin + Direction.Z * Cos
            )
        end

        --// Raycast parameters that ignore the character, the other players'
        --// characters and the mobs: a mob standing in the way is not a wall.
        local function GetProbeParams(Character)
            if not Character then
                return nil
            end

            if Steer.Params and Steer.Key == Character then
                return Steer.Params
            end

            local Filter = { Character }
            local MobFolder = workspace:FindFirstChild("Mobs")

            if MobFolder then
                table.insert(Filter, MobFolder)
            end

            if Players then
                for _, Other in ipairs(Players:GetPlayers()) do
                    if Other.Character and Other.Character ~= Character then
                        table.insert(Filter, Other.Character)
                    end
                end
            end

            if AICCombatUtils.S and AICCombatUtils.S.DebugFolder then
                table.insert(Filter, AICCombatUtils.S.DebugFolder)
            end

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = Filter
            Params.IgnoreWater = true

            Steer.Params = Params
            Steer.Key = Character

            return Params
        end

        --// Is Direction walkable? One centre ray carries the look-ahead; the
        --// side rays are body width but only a short way ahead, so walking
        --// parallel to a wall is not rejected by a ray grazing it.
        local function IsDirectionClear(Origin, Direction, Distance, Params)
            if workspace:Raycast(Origin + Vector3.new(0, 2.2, 0), Direction * Distance, Params) then
                return false
            end

            local Side = Vector3.new(-Direction.Z, 0, Direction.X)
            local Width = math.min(Distance, STEER_SHORT_PROBE)

            for _, Height in ipairs(STEER_RAY_HEIGHTS) do
                for _, Offset in ipairs(STEER_RAY_OFFSETS) do
                    local Start = Origin + Vector3.new(0, Height, 0) + Side * Offset

                    if workspace:Raycast(Start, Direction * Width, Params) then
                        return false
                    end
                end
            end

            return true
        end

        --// A step has to land on ground at about the character's height: no
        --// hole to fall into and no ledge to climb.
        local function HasStepGround(Point, FeetY, Params)
            local Hit = workspace:Raycast(Point + Vector3.new(0, 4, 0), Vector3.new(0, -16, 0), Params)

            if not Hit or Hit.Material == Enum.Material.Water then
                return false
            end

            return math.abs(Hit.Position.Y - FeetY) <= STEER_STEP_DOWN
        end

        --// The clearest heading that still makes progress toward the stop:
        --// straight first, then widening to either side. This handles props and
        --// doorways; a wall is walked along instead (ChooseSlide).
        local function ChooseHeading(Origin, Destination, Params, Distance)
            local Offset = Destination - Origin
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= 0.01 then
                return nil
            end

            local Forward = Flat.Unit
            local Best, BestScore = nil, -math.huge

            for _, Angle in ipairs(STEER_ANGLES) do
                local Direction = RotateFlat(Forward, Angle)

                if IsDirectionClear(Origin, Direction, Distance, Params)
                    and HasStepGround(Origin + Direction * Distance, Origin.Y, Params)
                then
                    local Score = math.cos(math.rad(Angle)) - math.abs(Angle) / 180 * 0.5

                    if Score > BestScore then
                        Best, BestScore = Direction, Score
                    end

                    if Angle == 0 then
                        break
                    end
                end
            end

            if not Best then
                return nil
            end

            return Best
        end

        --// Walking along a wall. The ray toward the stop gives the surface
        --// normal; the heading runs across it, leaning toward or away from the
        --// wall to hold roughly STEER_WALL_STANDOFF, and the side it is
        --// followed on is picked once and kept until the way opens. A fan of
        --// fixed angles cannot do this: against a long wall it turns away in
        --// 30° steps and then flips to the other side, which is the
        --// side-to-side pacing this replaces.
        local function ChooseSlide(Origin, Destination, Params)
            local Offset = Destination - Origin
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= 0.01 then
                return nil
            end

            local Forward = Flat.Unit
            local Reach = math.min(Flat.Magnitude, STEER_GOAL_PROBE)
            local Hit = workspace:Raycast(Origin + Vector3.new(0, 2.2, 0), Forward * Reach, Params)

            if not Hit then
                return nil
            end

            local Normal = Vector3.new(Hit.Normal.X, 0, Hit.Normal.Z)

            if Normal.Magnitude <= 0.01 then
                Normal = -Forward
            else
                Normal = Normal.Unit
            end

            --// One consistent way round the surface: 90° from its normal.
            local Tangent = Vector3.new(-Normal.Z, 0, Normal.X)

            if Tangent.Magnitude <= 0.01 then
                return nil
            end

            Tangent = Tangent.Unit

            --// No side picked for this wall yet: take the way round that ends
            --// up nearer the stop.
            if Steer.Side == 0 then
                local Right = Origin + Tangent * STEER_STEP
                local Left = Origin - Tangent * STEER_STEP
                local RightRemain = Vector3.new(Destination.X - Right.X, 0, Destination.Z - Right.Z).Magnitude
                local LeftRemain = Vector3.new(Destination.X - Left.X, 0, Destination.Z - Left.Z).Magnitude

                Steer.Side = RightRemain <= LeftRemain and 1 or -1
            end

            --// Lean toward the wall when it is far, away when it is close, so
            --// the walk follows it at roughly the same distance instead of
            --// drifting off in a wide arc.
            local Perpendicular = math.abs(Forward:Dot(Normal))
            local WallDistance = Hit.Distance
                and Hit.Distance * math.max(Perpendicular, 0.2)
                or STEER_WALL_STANDOFF
            local Lean = math.clamp(
                (WallDistance - STEER_WALL_STANDOFF) / STEER_WALL_STANDOFF,
                -0.4,
                0.4
            )

            local function DirectionFor(Side)
                return (Tangent * Side - Normal * Lean).Unit
            end

            local function Usable(Direction)
                return IsDirectionClear(Origin, Direction, STEER_PROBE, Params)
                    and HasStepGround(Origin + Direction * STEER_STEP, Origin.Y, Params)
            end

            local Direction = DirectionFor(Steer.Side)

            if not Usable(Direction) then
                --// A corner or a prop on this side: try the other way round,
                --// and keep that side while it works.
                Steer.Side = -Steer.Side
                Direction = DirectionFor(Steer.Side)

                if not Usable(Direction) then
                    return nil
                end
            end

            return Direction
        end

        --// Straight line to the stop, up to STEER_GOAL_PROBE studs. Wall
        --// following lasts until this is clear, not until the next few studs
        --// are: a six-stud look-ahead kept saying the wall was gone while the
        --// building was still between the character and the stop.
        local function IsGoalLineClear(Origin, Destination, Params)
            local Offset = Destination - Origin
            local Flat = Vector3.new(Offset.X, 0, Offset.Z)

            if Flat.Magnitude <= STEER_SHORT_PROBE then
                return true
            end

            return IsDirectionClear(
                Origin,
                Flat.Unit,
                math.min(Flat.Magnitude, STEER_GOAL_PROBE),
                Params
            )
        end

        --// One heading at a time, re-checked a few times a second, so the
        --// character walks a straight stretch and then turns, instead of
        --// re-aiming every frame. Returns "moving" while it has somewhere to
        --// go, "blocked" when nothing around is clear (it jumps and backs out,
        --// and the caller's progress check decides when to give the stop up).
        local function SteerTo(Destination, Now, RootPart, Humanoid)
            local Character = Runtime:GetCharacter()
            local Params = GetProbeParams(Character)

            if not Params then
                return "failed"
            end

            local Origin = RootPart.Position

            if Steer.BackOffPoint and Now < Steer.BackOffUntil then
                Humanoid:MoveTo(Steer.BackOffPoint)
                return "moving"
            end

            Steer.BackOffPoint = nil

            if Now - Steer.DecidedAt >= STEER_SAMPLE or not Steer.Direction then
                Steer.DecidedAt = Now

                local ToStop = Vector3.new(Destination.X - Origin.X, 0, Destination.Z - Origin.Z)
                local Forward = ToStop.Magnitude > 0.01 and ToStop.Unit or nil
                local Heading = Steer.Direction
                local GoalClear = Forward ~= nil and IsGoalLineClear(Origin, Destination, Params)
                local Clear = Heading ~= nil
                    and Forward ~= nil
                    and (Steer.Sliding or Heading:Dot(Forward) > 0)
                    and Now - Steer.ChosenAt < STEER_HOLD
                    and IsDirectionClear(Origin, Heading, STEER_PROBE, Params)
                    and HasStepGround(Origin + Heading * STEER_PROBE, Origin.Y, Params)

                --// The straight way opened: stop walking the wall.
                if Steer.Sliding and GoalClear then
                    Clear = false
                end

                if not Clear then
                    if GoalClear then
                        Heading = Forward
                        Steer.Sliding = false
                    else
                        Heading = ChooseSlide(Origin, Destination, Params)
                        Steer.Sliding = Heading ~= nil

                        --// A prop or a doorway rather than a wall: the fan
                        --// finds a way through where a slide would not.
                        if not Heading then
                            Heading = ChooseHeading(Origin, Destination, Params, STEER_PROBE)
                        end

                        --// Boxed in close up: a short step through a doorway
                        --// or between two props.
                        if not Heading then
                            Heading = ChooseHeading(Origin, Destination, Params, STEER_SHORT_PROBE)
                        end
                    end
                end

                if not Heading then
                    AICCombatUtils.DoJump()
                    Steer.Direction = nil
                    Steer.Side = -Steer.Side
                    Steer.NoHeadingAt = Steer.NoHeadingAt or Now

                    --// Turning on the spot never gets out of a corner.
                    if Now - Steer.NoHeadingAt >= STEER_BACKOFF then
                        local Away = Vector3.new(Origin.X - Destination.X, 0, Origin.Z - Destination.Z)

                        if Away.Magnitude > 0.01 then
                            Steer.BackOffPoint = Origin + Away.Unit * STEER_STEP
                            Steer.BackOffUntil = Now + STEER_BACKOFF
                            Humanoid:MoveTo(Steer.BackOffPoint)
                        end

                        Steer.NoHeadingAt = Now
                    end

                    return "blocked"
                end

                Steer.NoHeadingAt = nil

                if Heading ~= Steer.Direction then
                    Steer.ChosenAt = Now
                end

                Steer.Direction = Heading
            end

            local Step = Origin + Steer.Direction * STEER_STEP
            AICCombatUtils.DoJumpIfObstacle(Step)
            Humanoid:MoveTo(Step)

            return "moving"
        end

        --// "moving", "waiting" (a path is being solved), "blocked" (no path
        --// and no clear heading) or "done" at the destination. Never a straight
        --// line at the stop: without a navmesh that walked into walls.
        local function WalkTo(Destination, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return "failed"
            end

            if AICCombatUtils.GetHorizontalDistance(Destination, RootPart.Position)
                <= PATH_WAYPOINT_REACH
            then
                Humanoid:Move(Vector3.zero)
                return "done"
            end

            --// Stuck on the way: hop once and ask for a fresh path, rather
            --// than walking off in a random direction. The position is
            --// sampled, not compared frame by frame: a walking character
            --// moves well under a stud per frame, so a per-frame check called
            --// every frame "stuck" and reset a healthy path constantly.
            if not PathState.SampleAt or Now - PathState.SampleAt >= STUCK_SAMPLE
            then
                if PathState.LastPosition
                    and (RootPart.Position - PathState.LastPosition).Magnitude < STUCK_DISTANCE
                then
                    PathState.StuckSince = PathState.StuckSince or Now
                else
                    PathState.StuckSince = nil
                end

                PathState.LastPosition = RootPart.Position
                PathState.SampleAt = Now
            end

            if PathState.StuckSince and Now - PathState.StuckSince >= PATH_STUCK_SECONDS then
                AICCombatUtils.DoJump()
                PathState.StuckSince = nil
                PathState.Waypoints = nil
            end

            local Moved = PathState.Destination
                and (PathState.Destination - Destination).Magnitude > PATH_DEST_TOLERANCE
            local Stale = not PathState.Waypoints or Now - PathState.Time >= PATH_MAX_AGE
            local MayRetry = PathState.FailedAt == 0 or Now - PathState.FailedAt >= PATH_RETRY

            if not PathState.Computing and (Moved or Stale) and MayRetry then
                RequestPath(RootPart.Position, Destination)
            end

            if not PathState.Waypoints then
                return SteerTo(Destination, Now, RootPart, Humanoid)
            end

            while PathState.Index <= #PathState.Waypoints do
                local Waypoint = PathState.Waypoints[PathState.Index]

                if AICCombatUtils.GetHorizontalDistance(Waypoint.Position, RootPart.Position)
                    <= PATH_WAYPOINT_REACH
                then
                    PathState.Index += 1
                else
                    break
                end
            end

            local Waypoint = PathState.Waypoints[PathState.Index]

            if Waypoint then
                if Waypoint.Action == Enum.PathWaypointAction.Jump then
                    AICCombatUtils.DoJumpIfObstacle(Waypoint.Position)
                end

                Humanoid:MoveTo(Waypoint.Position)
            else
                Humanoid:MoveTo(Destination)
            end

            return "moving"
        end

        --// The Boss Route list labels. A stop keeps its number and position in
        --// the label so a drag can find it again, even with two identically
        --// named stops.
        local function BuildLabels()
            local Labels = {}

            for Index, Stop in ipairs(GetStops()) do
                local Extra = ""

                if (Stop.Waypoint or 0) > 0 then
                    Extra = string.format("  > WP%d", Stop.Waypoint)
                end

                if #Stop.Targets > 0 then
                    Extra = Extra .. "  " .. Stop.Targets[1]
                end

                Labels[Index] = string.format(
                    "#%d  %s%s  (%s)",
                    Index,
                    Stop.Label,
                    Extra,
                    string.format("%.0f, %.0f, %.0f", Stop.Position.X, Stop.Position.Y, Stop.Position.Z)
                )
            end

            return Labels
        end

        local function GetResetValues()
            local Values = {}

            for Index, Stop in ipairs(GetStops()) do
                Values[Index] = tonumber(Stop.ResetAfter) or 0
            end

            return Values
        end

        local function GetWaitExpChecks()
            local Checks = {}

            for Index, Stop in ipairs(GetStops()) do
                Checks[Index] = Stop.WaitExp == true
            end

            return Checks
        end

        function AICUI.RefreshBossRouteList()
            if not UIRef.BossListComponent then
                return
            end

            UIRef.BossListComponent:SetPriority(BuildLabels(), GetResetValues(), GetWaitExpChecks())
        end

        --// Names of the boss picked in "Edit Boss Stop": a list plus a
        --// dropdown of the mobs around the player, the same pattern as Zone
        --// Targets. Nothing is typed by hand.
        function AICUI.RefreshBossNames()
            local Component = UIRef.BossNamesComponent
            local Section = UIRef.BossSection

            if not Component or not Section then
                return
            end

            local Stop = SelectedStop()
            local Names = Stop and Stop.Targets or {}

            Component:SetPriority(table.clone(Names))

            local _, _, RootPart = Runtime:GetCharacter()
            local Options = {}
            local Offered = {}

            local function Offer(Name)
                if type(Name) ~= "string" or Name == "" or Offered[Name] then
                    return
                end

                if table.find(Names, Name) then
                    return
                end

                Offered[Name] = true
                table.insert(Options, Name)
            end

            --// Nearest first: the mobs actually around the character, so the
            --// usual pick is the first entry.
            local Nearby, NearbyDistance = {}, {}
            local MobFolder = workspace:FindFirstChild("Mobs")

            if RootPart and MobFolder then
                for _, Mob in ipairs(MobFolder:GetChildren()) do
                    if Mob:IsA("Model") then
                        local MobRoot = Mob:FindFirstChild("HumanoidRootPart")
                        local Name = AICCombat.GetTargetEntityName(Mob)

                        if Name and MobRoot then
                            local Distance = (MobRoot.Position - RootPart.Position).Magnitude

                            if Distance <= NAME_SCAN_RADIUS
                                and Distance < (NearbyDistance[Name] or math.huge)
                            then
                                Nearby[Name] = true
                                NearbyDistance[Name] = Distance
                            end
                        end
                    end
                end
            end

            local NearbyNames = {}

            for Name in pairs(Nearby) do
                table.insert(NearbyNames, Name)
            end

            table.sort(NearbyNames, function(A, B)
                if NearbyDistance[A] == NearbyDistance[B] then
                    return A < B
                end

                return NearbyDistance[A] < NearbyDistance[B]
            end)

            for _, Name in ipairs(NearbyNames) do
                Offer(Name)
            end

            --// Then every other mob the game has loaded, so a boss name can
            --// be picked before walking next to it.
            local Detected = type(AICCombat.GetDetectedMobTargets) == "function"
                and AICCombat.GetDetectedMobTargets()
                or {}

            for _, Name in ipairs(Detected) do
                Offer(Name)
            end

            if #Options == 0 then
                Options = { "No mobs nearby" }
            end

            UIRef.BossNameDropdown = AICUI.ReplaceDropdown(
                UIRef.BossNameDropdown,
                Section,
                "Add Boss Name",
                Options,
                function(Value)
                    local Current = SelectedStop()

                    if not Current or Value == "No mobs nearby" then
                        return
                    end

                    if not AICProfile.S.ActiveProfileName then
                        SetStatus("CREATE / LOAD PROFILE FIRST")
                        return
                    end

                    Current.Targets = Current.Targets or {}

                    if not table.find(Current.Targets, Value) then
                        table.insert(Current.Targets, Value)
                        AICProfile.SaveActiveProfile()
                        Say("Boss Route", "Boss name added: " .. Value)
                    end

                    AICUI.RefreshBossNames()
                end
            )
        end

        --// Puts the selected stop's values back into the edit boxes, after a
        --// selection change or an edit was applied.
        local function RefreshEditor()
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if UIRef.BossNameBox then UIRef.BossNameBox:Set(Stop.Label, false) end
            if UIRef.BossWaypointBox then UIRef.BossWaypointBox:Set(tostring(Stop.Waypoint or 0), false) end
            if UIRef.BossWaitBox then UIRef.BossWaitBox:Set(tostring(Stop.Wait or 0), false) end
            if UIRef.BossRespawnWaitBox then UIRef.BossRespawnWaitBox:Set(tostring(Stop.RespawnWait or 0), false) end
            if UIRef.BossRadiusBox then UIRef.BossRadiusBox:Set(tostring(Stop.Radius or 0), false) end
            if UIRef.BossResetAfterKillToggle then
                UIRef.BossResetAfterKillToggle:Set(Stop.ResetAfterKill == true, false)
            end
            if UIRef.BossLoopToggle then UIRef.BossLoopToggle:Set(CONFIG.BOSS_ROUTE_LOOP ~= false, false) end
        end

        --// Rebuilds the "Edit Boss Stop" picker, keeping its slot in the
        --// section, and follows the selected stop.
        function AICUI.RefreshBossRoutePickers()
            if not UIRef.BossSection then
                return
            end

            local Stops = GetStops()
            local Options = {}

            for Index, Stop in ipairs(Stops) do
                Options[Index] = string.format("#%d  %s", Index, Stop.Label)
            end

            if #Options == 0 then
                Options = { "No boss stops" }
            end

            AICProfile.S.SelectedBossStopIndex = math.clamp(
                AICProfile.S.SelectedBossStopIndex, 1, math.max(1, #Stops)
            )

            local Selected = Options[AICProfile.S.SelectedBossStopIndex] or Options[1]

            UIRef.BossPicker = AICUI.ReplaceDropdown(
                UIRef.BossPicker,
                UIRef.BossSection,
                "Edit Boss Stop",
                Options,
                function(Value)
                    local Index = table.find(Options, Value)

                    if Index and GetStops()[Index] then
                        AICProfile.S.SelectedBossStopIndex = Index
                        RefreshEditor()
                        AICUI.RefreshBossNames()
                    end
                end
            )

            if Selected then
                UIRef.BossPicker:Set(Selected, false)
            end

            RefreshEditor()
        end

        local function Commit(StatusText)
            Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
            AICUI.RefreshBossRouteList()
            AICUI.RefreshBossRoutePickers()
            AICProfile.SaveActiveProfile()
            SetStatus(StatusText)
            AICDebug.UpdateDebugVisualizer()
        end

        --// Turned off from inside the run (route finished with Loop Route off).
        local function SwitchOff()
            FeatureState.BossRoute.Enabled = false

            if AICUI.SetFeatureComponent then
                AICUI.SetFeatureComponent("BossRoute", false)
            end

            if AICProfile.S.ActiveProfileName then
                AICProfile.SaveActiveProfile()
            end
        end

        ------------------------------------------------------------------------
        --// The run
        ------------------------------------------------------------------------

        local function StopRoute(StatusText)
            S.Phase = "Idle"
            S.SeenTarget = false
            S.KillAt = nil
            S.WaitUntil = nil
            S.WalkStart = nil
            AICCombat.S.ClosestTarget = nil
            ResetPath()
            SetStatus(StatusText or "IDLE")
        end

        local function BeginStop(Now)
            local Stops = GetStops()
            local Stop = Stops[S.Index]

            if not Stop then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return
            end

            S.Phase = "Approach"
            S.PhaseStart = Now
            S.WalkStart = Now
            S.WaitUntil = nil
            S.FightStart = nil
            S.SeenTarget = false
            S.KillAt = nil
            S.Teleported = false
            S.BestDistance = nil
            S.LastProgressAt = Now
            S.Resets = 0
            Steer.Direction = nil
            Steer.DecidedAt = 0
            Steer.ChosenAt = 0
            Steer.Sliding = false
            Steer.Side = 0
            Steer.BackOffPoint = nil
            Steer.BackOffUntil = 0
            Steer.NoHeadingAt = nil
            S.SkipExpCheck = true
            AICCombat.S.ClosestTarget = nil
            ResetPath()
            SetStatus(string.format("STOP %d/%d  %s", S.Index, #Stops, Stop.Label))
        end

        local function Advance(Now)
            local Stops = GetStops()
            S.SeenTarget = false
            S.KillAt = nil
            S.FightStart = nil
            S.WalkStart = nil
            S.WaitUntil = nil
            S.BestDistance = nil
            S.LastProgressAt = nil

            if #Stops == 0 then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return
            end

            if S.Index >= #Stops then
                if CONFIG.BOSS_ROUTE_LOOP == false then
                    S.Phase = "Done"
                    SetStatus("ROUTE FINISHED")
                    SwitchOff()
                    return
                end

                S.Index = 1
            else
                S.Index += 1
            end

            BeginStop(Now)
        end

        local function BeginRecover(Now, Reason, SkipExpCheck)
            S.Phase = "Recover"
            S.PhaseStart = Now
            S.RecoveredAt = nil
            S.SkipExpCheck = SkipExpCheck == true
            S.ExpBefore = nil

            if not S.SkipExpCheck then
                S.ExpBefore = GetExp()
            end

            S.ExpDeadline = Now + EXP_LOSS_TIMEOUT
            AICCombat.S.ClosestTarget = nil
            ResetPath()
            SetStatus(string.format("STOP %d/%d  %s", S.Index, #GetStops(), Reason))
        end

        local function BeginReset(Now, Reason)
            local _, Humanoid = Runtime:GetCharacter()

            S.Resets += 1

            if Humanoid and Humanoid.Health > 0 then
                Humanoid:Move(Vector3.zero)
                --// The same reset Party System uses; the game respawns the
                --// character and, on a death, takes the EXP it takes.
                Humanoid.Health = 0
            end

            BeginRecover(Now, "RESET " .. Reason, false)
            Say("Boss Route", string.format("Reset %s at stop #%d", Reason, S.Index), 3)
        end

        --// Waits for the character after a reset or a death, then for Respawn
        --// Wait (and the EXP drop, when the stop asks for it).
        local function RecoverStep(Now)
            if S.Phase ~= "Recover" then
                return false
            end

            local _, Humanoid = Runtime:GetCharacter()

            if not Humanoid or Humanoid.Health <= 0 then
                if S.RecoveredAt then
                    S.RecoveredAt = nil
                end

                if Now - S.PhaseStart >= RESPAWN_TIMEOUT then
                    Say("Boss Route", "No respawn, moving to the next stop", 4)
                    Advance(Now)
                end

                return true
            end

            if not S.RecoveredAt then
                S.RecoveredAt = Now
            end

            local Stop = CurrentStop()
            local RespawnWait = Stop and tonumber(Stop.RespawnWait) or 0

            if Now - S.RecoveredAt < RespawnWait then
                SetStatus(string.format(
                    "STOP %d/%d  RESPAWNED  %ds",
                    S.Index,
                    #GetStops(),
                    math.ceil(RespawnWait - (Now - S.RecoveredAt))
                ))
                return true
            end

            if Stop and Stop.WaitExp and not S.SkipExpCheck then
                local Exp = GetExp()
                local Dropped = S.ExpBefore ~= nil and Exp ~= nil and Exp < S.ExpBefore

                if not Dropped then
                    if Now < S.ExpDeadline then
                        SetStatus(string.format("STOP %d/%d  WAITING FOR EXP LOSS", S.Index, #GetStops()))
                        return true
                    end

                    SetStatus("NO EXP LOSS SEEN")
                end
            end

            Advance(Now)
            return true
        end

        --// Nearest living mob at the stop that matches its Boss Names (or any
        --// mob when none are set). The scan is shared by every frame that asks
        --// within SCAN_INTERVAL.
        local ScanAt = 0
        local ScanKey = nil
        local ScanResult = nil
        --// Kept apart from ScanResult, which is nil when the scan found
        --// nothing: without it an empty spot would rescan every frame.
        local ScanDone = false

        --// Auto Farm's own IsCombatTargetValid also demands the name be on the
        --// Enemy Priority list and that the mob be within its farm engage
        --// range. A boss stop knows nothing about that list, so a boss the stop
        --// names was found and then thrown away: the character stood at the
        --// stop without drawing its weapon. A boss stop validates its own
        --// target instead.
        local function IsStopTargetAlive(Mob)
            if not Mob or not Mob:IsA("Model") or not Mob:IsDescendantOf(workspace) then
                return false
            end

            local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
            local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

            return MobHumanoid ~= nil and MobRoot ~= nil and MobHumanoid.Health > 0
        end

        local function FindTarget(Stop, Now)
            local Key = string.format(
                "%d|%s|%s",
                S.Index,
                tostring(Stop.Radius),
                table.concat(Stop.Targets, ",")
            )

            if not ScanDone or Now - ScanAt >= SCAN_INTERVAL or ScanKey ~= Key then
                ScanAt = Now
                ScanKey = Key
                ScanDone = true

                local Best, BestDistance = nil, math.huge
                local MobFolder = workspace:FindFirstChild("Mobs")

                for _, Mob in ipairs(MobFolder and MobFolder:GetChildren() or {}) do
                    if Mob:IsA("Model") then
                        local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                        local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                        if MobHumanoid and MobRoot and MobHumanoid.Health > 0 then
                            local Distance = (MobRoot.Position - Stop.Position).Magnitude

                            if Distance <= Stop.Radius and Distance < BestDistance then
                                local Name = AICCombat.GetTargetEntityName(Mob)
                                local Match = Name ~= nil
                                    and (#Stop.Targets == 0 or table.find(Stop.Targets, Name) ~= nil)

                                if Match then
                                    Best, BestDistance = Mob, Distance
                                end
                            end
                        end
                    end
                end

                ScanResult = Best
            end

            if IsStopTargetAlive(ScanResult) then
                return ScanResult
            end

            return nil
        end

        --// Walks into reach and fights. The weapon is drawn first, which costs
        --// a frame, and the swing itself is the same combat input Auto Farm
        --// presses.
        local function Fight(Target, Now)
            if AICFeature.EnsureWeaponDrawn and AICFeature.EnsureWeaponDrawn(Now) then
                return
            end

            local _, Humanoid, RootPart = Runtime:GetCharacter()
            local TargetRoot = Target:FindFirstChild("HumanoidRootPart")

            if not Humanoid or not RootPart or not TargetRoot then
                return
            end

            local Offset = TargetRoot.Position - RootPart.Position
            local Distance = AICCombat.GetCombatDistance(Target, Offset)
            local Range = AICCombat.GetCombatAttackRange(Target)

            if Distance > Range * 0.95 then
                local Flat = Vector3.new(Offset.X, 0, Offset.Z)
                local Direction = Flat.Magnitude > 0.01 and Flat.Unit or Vector3.xAxis
                --// Stop a little short of the body, not inside it. The target
                --// is in sight at this range, so this is a straight step with
                --// a hop over anything low; no path or detour is needed.
                local Standoff = math.clamp(Range * 0.4, 1, 4)
                local Destination = TargetRoot.Position - Direction * Standoff

                AICCombatUtils.DoJumpIfObstacle(Destination)
                Humanoid:MoveTo(Destination)
            else
                Humanoid:Move(Vector3.zero)
                AICCombat.FaceCombatTarget(Target)
            end

            AICCombat.PerformCombatActions(Target, Now)
        end

        local function TeleportToWaypoint(Number)
            local TeleportEvent = Replicated:FindFirstChild("TeleportEvent", true)

            if not TeleportEvent then
                Say("Boss Route", "No TeleportEvent in this game; walking instead", 4)
                return false
            end

            local Ok, Error = pcall(function()
                TeleportEvent:FireServer(Number)
            end)

            if not Ok then
                Say("Boss Route", "Teleport failed: " .. tostring(Error), 4)
                return false
            end

            return true
        end

        local function ApproachStep(Stop, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return
            end

            --// The stop names one of the game's waypoints: take it once, then
            --// give the character a moment to land.
            if not S.Teleported and (Stop.Waypoint or 0) > 0 then
                S.Teleported = true

                if TeleportToWaypoint(Stop.Waypoint) then
                    S.WaitUntil = Now + TELEPORT_WAIT
                    SetStatus(string.format("STOP %d/%d  TELEPORT WP%d", S.Index, #GetStops(), Stop.Waypoint))
                    return
                end
            end

            if S.WaitUntil and Now < S.WaitUntil then
                Humanoid:Move(Vector3.zero)
                return
            end

            local Offset = Stop.Position - RootPart.Position
            local Flat = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
            local Reach = tonumber(Runtime:GetPlaceConfig().REACH_DISTANCE) or REACH_DISTANCE

            if Flat <= Reach then
                S.Phase = "Wait"
                S.WaitUntil = Now + (tonumber(Stop.Wait) or 0)
                Humanoid:Move(Vector3.zero)
                SetStatus(string.format("STOP %d/%d  WAITING", S.Index, #GetStops()))
                return
            end

            --// Progress, not the solver's opinion: a map without a navmesh
            --// reports no path while the steering still gets there, so only a
            --// stop the character stops getting closer to is skipped. Half a
            --// stud of slack absorbs the dodging round an obstacle.
            if not S.BestDistance or Flat < S.BestDistance - 0.5 then
                S.BestDistance = Flat
                S.LastProgressAt = Now
            end

            if Now - (S.LastProgressAt or Now) >= NO_PROGRESS_TIMEOUT
                or Now - (S.WalkStart or Now) > WALK_TIMEOUT
            then
                Say("Boss Route", "Could not reach stop #" .. tostring(S.Index) .. "; skipping", 4)
                Advance(Now)
                return
            end

            SetStatus(string.format("STOP %d/%d  WALKING", S.Index, #GetStops()))

            --// One path, walked waypoint by waypoint; with no navmesh a
            --// steering heading round whatever is in the way (WalkTo).
            WalkTo(Stop.Position, Now)
        end

        local function FightStep(Stop, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return
            end

            local Target = FindTarget(Stop, Now)

            if Target then
                S.SeenTarget = true
                S.KillAt = nil
                AICCombat.S.ClosestTarget = Target

                local ResetAfter = tonumber(Stop.ResetAfter) or 0

                if ResetAfter > 0 and S.FightStart and Now - S.FightStart >= ResetAfter then
                    BeginReset(Now, "TIMER")
                    return
                end

                SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                Fight(Target, Now)
                return
            end

            AICCombat.S.ClosestTarget = nil
            Humanoid:Move(Vector3.zero)

            --// The boss went down: a grace period covers a second mob of the
            --// same stop still standing up.
            if S.SeenTarget then
                S.KillAt = S.KillAt or Now
                SetStatus(string.format("STOP %d/%d  CLEARING", S.Index, #GetStops()))

                if Now - S.KillAt >= KILL_GRACE then
                    --// The fight is done: reset and travel on when the stop
                    --// asks for it, otherwise just take the next stop.
                    if Stop.ResetAfterKill then
                        BeginReset(Now, "BOSS DOWN")
                    else
                        Advance(Now)
                    end
                end

                return
            end

            --// Nothing here at all: the boss is dead already, on its respawn
            --// timer, or the spot is wrong.
            SetStatus(string.format("STOP %d/%d  NOTHING TO FIGHT", S.Index, #GetStops()))

            if S.FightStart and Now - S.FightStart >= NO_TARGET_TIMEOUT then
                Advance(Now)
            end
        end

        local function Step(Now)
            if not IsEnabled() then
                return false
            end

            if S.Phase == "Recover" then
                return RecoverStep(Now)
            end

            local Stops = GetStops()

            if #Stops == 0 then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return true
            end

            if S.Index > #Stops then
                S.Index = 1
            end

            if S.Phase == "Idle" then
                BeginStop(Now)
            end

            local _, Humanoid, RootPart = Runtime:GetCharacter()

            --// Died on the way or in the fight without being reset by us: the
            --// loss is already taken, so wait for the respawn only.
            if not Humanoid or not RootPart or Humanoid.Health <= 0 then
                if S.Phase ~= "Recover" then
                    BeginRecover(Now, "DIED", true)
                end

                return true
            end

            local Stop = CurrentStop()

            if not Stop then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return true
            end

            if S.Phase == "Approach" then
                ApproachStep(Stop, Now)
                return true
            end

            if S.Phase == "Wait" then
                Humanoid:Move(Vector3.zero)

                if Now < (S.WaitUntil or 0) then
                    return true
                end

                S.Phase = "Fight"
                S.FightStart = Now
                S.SeenTarget = false
                S.KillAt = nil
            end

            if S.Phase == "Fight" then
                FightStep(Stop, Now)
                return true
            end

            --// "Done" with the loop off, or something else parked the run.
            if S.Phase == "Done" then
                return true
            end

            BeginStop(Now)
            return true
        end

        --// Auto Farm calls this every frame, with Auto Farm on or off. True
        --// means the route owns this frame's movement and combat.
        AICFeature.BossStep = function(Now)
            return Step(Now)
        end

        --// Called while the character is dead or gone, where Auto Farm
        --// returns before BossStep: keeps a reset waiting for its respawn.
        AICFeature.BossRecoverStep = function(Now)
            if not IsEnabled() then
                return false
            end

            return RecoverStep(Now)
        end

        --// A profile load brings another place's stops with it.
        AICFeature.ResetBossRoute = function()
            S.Index = 1
            S.Phase = "Idle"
            S.SeenTarget = false
            S.KillAt = nil
            S.WaitUntil = nil
            S.WalkStart = nil
            ResetPath()
        end

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        UIRef.BossSection = UIRef.BossTab:AddSection("Boss Route")

        UIRef.BossToggle = AICUI.BindFeatureToggle("BossRoute", "Boss Route", function(Enabled)
            if Enabled then
                S.Index = 1
                S.Phase = "Idle"
                BeginStop(os.clock())
            else
                StopRoute("OFF")
            end
        end, UIRef.BossSection)

        UIRef.BossStatusLabel = UIRef.BossSection:AddLabel("STATUS:  IDLE")

        UIRef.BossSection:AddButton("Add Boss Stop Here", function()
            local _, _, RootPart = Runtime:GetCharacter()

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit() then
                return
            end

            local Stops = GetStops()

            table.insert(Stops, {
                Label = "Boss " .. tostring(#Stops + 1),
                Position = AICConfig.RoundVector3(RootPart.Position),
                Targets = {},
                Waypoint = 0,
                Wait = 0,
                ResetAfter = AICConfig.DEFAULT_BOSS_RESET_AFTER,
                ResetAfterKill = true,
                RespawnWait = AICConfig.DEFAULT_BOSS_RESPAWN_WAIT,
                WaitExp = false,
                Radius = AICConfig.DEFAULT_BOSS_RADIUS,
            })

            AICProfile.S.SelectedBossStopIndex = #GetStops()
            Commit("BOSS STOP ADDED #" .. tostring(#GetStops()))
            Say("Boss Route", "Added boss stop #" .. tostring(#GetStops()))
        end)

        UIRef.BossSection:AddButton("Clear Boss Route", function()
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.clear(GetStops())
            AICProfile.S.SelectedBossStopIndex = 1
            S.Index = 1
            S.Phase = "Idle"
            Commit("BOSS ROUTE CLEARED")
            Say("Boss Route", "Cleared every boss stop")
        end)

        UIRef.BossListComponent = UIRef.BossSection:AddPriority("Boss Route", BuildLabels(), {
            --// Seconds of fighting before the character is reset.
            Values = true,
            ValueLabel = "Reset (s)",
            Default = 0,
            Min = 0,
            Max = AICConfig.MAX_BOSS_RESET,
            --// Hold the next stop until the EXP loss is registered.
            Checks = true,
            CheckLabel = "Wait Exp",
        })

        UIRef.BossListComponent.OnValueChanged = function(Index, Value)
            local Stop = GetStops()[Index]

            if not Stop then
                return
            end

            if not AICProfile.S.ActiveProfileName then
                SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                AICUI.RefreshBossRouteList()
                return
            end

            Stop.ResetAfter = Value
            AICProfile.QueueProfileSave()
            SetStatus(string.format("STOP #%d RESET AFTER %ss", Index, tostring(Value)))
        end

        UIRef.BossListComponent.OnCheckChanged = function(Index, Checked)
            local Stop = GetStops()[Index]

            if not Stop then
                return
            end

            if not AICProfile.S.ActiveProfileName then
                SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                AICUI.RefreshBossRouteList()
                return
            end

            Stop.WaitExp = Checked == true
            AICProfile.QueueProfileSave()
            SetStatus(string.format("STOP #%d %s", Index, Checked and "WAITS FOR EXP LOSS" or "NO EXP WAIT"))
        end

        --// Stops move in place, so their timers, teleport and names travel with
        --// them. The labels are rebuilt afterwards: they carry the number.
        local OriginalMoveUp = UIRef.BossListComponent.MoveUp
        local OriginalMoveDown = UIRef.BossListComponent.MoveDown
        local OriginalRemove = UIRef.BossListComponent.Remove

        local function MoveStop(Component, Label, Delta, Original, StatusText)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Stops = GetStops()
            local Index = table.find(BuildLabels(), Label)
            local Other = Index and Index + Delta

            if not Other or Other < 1 or Other > #Stops then
                return
            end

            Stops[Index], Stops[Other] = Stops[Other], Stops[Index]
            Original(Component, Label)
            AICProfile.S.SelectedBossStopIndex = Other
            Commit(StatusText)
        end

        function UIRef.BossListComponent:MoveUp(Label)
            MoveStop(self, Label, -1, OriginalMoveUp, "BOSS STOP MOVED UP")
        end

        function UIRef.BossListComponent:MoveDown(Label)
            MoveStop(self, Label, 1, OriginalMoveDown, "BOSS STOP MOVED DOWN")
        end

        function UIRef.BossListComponent:Remove(Label)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = table.find(BuildLabels(), Label)

            if not Index then
                return
            end

            table.remove(GetStops(), Index)
            OriginalRemove(self, Label)
            AICProfile.S.SelectedBossStopIndex = math.clamp(Index, 1, math.max(1, #GetStops()))

            if S.Index > #GetStops() then
                S.Index = math.max(1, #GetStops())
            end

            Commit("BOSS STOP REMOVED #" .. tostring(Index))
        end

        AICUI.RefreshBossRoutePickers()

        --// Per stop edits. Each box writes the selected stop and commits it,
        --// so what the list shows and what the run reads can never differ.
        local function AddStopBox(Label, Write)
            return UIRef.BossSection:AddTextbox(Label, "", function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                if not Write(Stop, Value) then
                    SetStatus("INVALID VALUE")
                    RefreshEditor()
                    return
                end

                Commit(string.format("STOP #%d UPDATED", AICProfile.S.SelectedBossStopIndex))
            end)
        end

        UIRef.BossNameBox = AddStopBox("Boss Stop Name", function(Stop, Value)
            local Text = tostring(Value or ""):gsub("^%s*(.-)%s*$", "%1")

            if Text == "" then
                return false
            end

            Stop.Label = string.sub(Text, 1, MAX_LABEL_LENGTH)
            return true
        end)

        UIRef.BossWaypointBox = AddStopBox("Teleport Waypoint #", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.Waypoint = math.clamp(math.floor(Number), 0, AICConfig.MAX_BOSS_WAYPOINT)
            return true
        end)

        UIRef.BossWaitBox = AddStopBox("Wait At Spot (s)", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.Wait = math.clamp(Number, 0, AICConfig.MAX_WAYPOINT_WAIT)
            return true
        end)

        --// How long to wait after the reset's respawn before walking on. The
        --// stored key keeps its old name (RespawnWait) so existing profiles
        --// still load; only the label changed.
        UIRef.BossRespawnWaitBox = AddStopBox("Wait After Reset (s)", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.RespawnWait = math.clamp(Number, 0, AICConfig.MAX_BOSS_RESPAWN_WAIT)
            return true
        end)

        UIRef.BossRadiusBox = AddStopBox("Engage Radius", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number <= 0 then
                return false
            end

            Stop.Radius = math.clamp(Number, 1, AICConfig.MAX_BOSS_RADIUS)
            return true
        end)

        --// Reset once the boss is down, i.e. the character respawns at the
        --// usual spawn point before the next stop is travelled to. Off, the
        --// next stop starts from wherever the fight ended.
        UIRef.BossResetAfterKillToggle = UIRef.BossSection:AddToggle(
            "Reset After Kill",
            true,
            function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                Stop.ResetAfterKill = Value == true
                AICProfile.SaveActiveProfile()
                SetStatus(
                    Stop.ResetAfterKill
                        and "STOP RESETS AFTER THE KILL"
                        or "STOP STAYS WHERE THE BOSS DIED"
                )
            end
        )

        --// Boss names come from a list of the mobs around the player, the same
        --// way Zone Targets does it, so nothing has to be typed.
        UIRef.BossNamesComponent = UIRef.BossSection:AddPriority("Boss Names", {})

        --// Built here, before the refresh button, so the button sits directly
        --// under the picker: both take the next two slots of the section.
        AICUI.RefreshBossNames()

        UIRef.BossRefreshButton = UIRef.BossSection:AddButton("Refresh Nearby Bosses", function()
            AICUI.RefreshBossNames()
            SetStatus("NEARBY BOSSES REFRESHED")
        end)

        local OriginalNameRemove = UIRef.BossNamesComponent.Remove
        local OriginalNameMoveUp = UIRef.BossNamesComponent.MoveUp
        local OriginalNameMoveDown = UIRef.BossNamesComponent.MoveDown

        local function CommitNames(Component)
            local Stop = SelectedStop()

            if Stop then
                Stop.Targets = table.clone(Component.Priority)
                AICProfile.SaveActiveProfile()
            end

            AICUI.RefreshBossNames()
        end

        local function NamesGuard()
            if AICProfile.S.ActiveProfileName and SelectedStop() then
                return true
            end

            SetStatus("ADD A BOSS STOP FIRST")
            return false
        end

        function UIRef.BossNamesComponent:Remove(Value)
            if not NamesGuard() then
                return false
            end

            local Changed = OriginalNameRemove(self, Value)
            CommitNames(self)
            return Changed
        end

        function UIRef.BossNamesComponent:MoveUp(Value)
            if not NamesGuard() then
                return
            end

            OriginalNameMoveUp(self, Value)
            CommitNames(self)
        end

        function UIRef.BossNamesComponent:MoveDown(Value)
            if not NamesGuard() then
                return
            end

            OriginalNameMoveDown(self, Value)
            CommitNames(self)
        end

        UIRef.BossSection:AddButton("Move Stop Here", function()
            local Stop = SelectedStop()
            local _, _, RootPart = Runtime:GetCharacter()

            if not Stop then
                SetStatus("ADD A BOSS STOP FIRST")
                return
            end

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            Stop.Position = AICConfig.RoundVector3(RootPart.Position)
            Commit(string.format("STOP #%d MOVED HERE", AICProfile.S.SelectedBossStopIndex))
        end)

        UIRef.BossSection:AddButton("Remove Stop", function()
            local Index = AICProfile.S.SelectedBossStopIndex
            local Stops = GetStops()

            if not Stops[Index] then
                SetStatus("ADD A BOSS STOP FIRST")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.remove(Stops, Index)
            AICProfile.S.SelectedBossStopIndex = math.clamp(Index, 1, math.max(1, #GetStops()))

            if S.Index > #GetStops() then
                S.Index = math.max(1, #GetStops())
            end

            Commit("BOSS STOP REMOVED #" .. tostring(Index))
        end)

        UIRef.BossLoopToggle = UIRef.BossSection:AddToggle(
            "Loop Route",
            CONFIG.BOSS_ROUTE_LOOP ~= false,
            function(Value)
                CONFIG.BOSS_ROUTE_LOOP = Value == true

                if AICProfile.S.ActiveProfileName then
                    AICProfile.SaveActiveProfile()
                end

                SetStatus(CONFIG.BOSS_ROUTE_LOOP and "ROUTE LOOPS" or "ROUTE RUNS ONCE")
            end
        )

        --// Every control exists now, so fill the edit boxes from the selected
        --// stop instead of leaving them empty until the first edit.
        AICUI.RefreshBossRoutePickers()
        SetStatus("IDLE")

        return Feature
    end,
}
