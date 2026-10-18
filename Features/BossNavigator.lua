-- BossNavigator walks a saved route of boss stops, fighting at each one.
--
-- It has its own tab and its own list (Boss Route on the place config), so it
-- is separate from the waypoint route Auto Farm walks and from the waypoints
-- in Profile Settings: editing one never moves the other. A stop is a spot to
-- stand on. Coming to a stop the character walks there, or teleports to one of
-- the game's waypoints first when the stop names one, then fights whatever
-- matches its Boss Names inside its radius. There is no wait at the spot.
--
-- A fight ends when the target dies and nothing else is in the radius, or
-- when nothing is there to fight at all. With Reset After Kill on (the default
-- for a new stop) the character then holds at the corpse for the stop's Reset
-- After seconds and is reset, so the next stop is travelled to from spawn.
-- There is no timer reset: the character never resets while the boss is still
-- standing.
-- Wait Exp holds the next stop until the game's EXP actually dropped after the
-- reset, so the loss is registered before walking off. A stop with it off
-- moves straight on instead. Dying, rather than being reset by
-- the route, is never taken as the stop being done: once the character is back
-- the same stop is run again, teleporting to its waypoint and walking its Path
-- from the first point. The sword is asked for before the fight, not at it.
--
-- The route loops unless Loop Route is off; then it plays once and switches
-- itself off. Travel is the stop's own saved Path points, walked in order and
-- then the stop itself; nothing is solved or steered, so the way round a
-- building is the one recorded in the Path to Boss section. While walking it
-- presses the game's Interact input like the Farming waypoint route, so doors,
-- levers and other proximity prompts on the path are used. The fight uses the
-- same combat inputs as Auto Farm, and a big health drop in a moment (a boss
-- skill) makes the character sprint out of range before going back in. Auto
-- Farm hands this module the frame while it is on, with Auto Farm on or off.
return {
    Name = "BossNavigator",
    IsFeature = true,
    Dependencies = {
        "Runtime",
        "SaveConfig",
        "ProfileManager",
        "Components",
        "CombatUtils",
        "Combat",
    },

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
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
        --// Interact presses while walking, when the place config has no
        --// interaction interval of its own.
        local INTERACT_INTERVAL = 0.5
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
        --// No progress toward the next point for this long (a wrong point, a
        --// wall in the way): skip the stop instead of standing there for
        --// WALK_TIMEOUT.
        local NO_PROGRESS_TIMEOUT = 20
        --// How close a saved path point has to be to count as reached. The stop
        --// itself uses the place's Waypoint Reach Distance.
        local PATH_REACH = 4
        --// The walk samples the position this often and hops when less than
        --// this many studs were covered in that window (a step, a fence).
        local STUCK_SAMPLE = 0.5
        local STUCK_DISTANCE = 0.75
        --// How far from the boss the character stops to swing. The combat range
        --// says when the attack input may be pressed, not where a swing lands.
        local FIGHT_STANDOFF = 6
        --// Distance from the stop at which the sword is asked for, so it is
        --// already out when the fight starts instead of being fumbled for
        --// while the boss is hitting the character.
        local WEAPON_READY_DISTANCE = 60
        --// A boss skill lands as a big chunk of health in a moment. The drop is
        --// measured as a fraction of max health inside this window, so it works
        --// at any level and a slow grind of small hits is not a skill.
        local BURST_WINDOW = 0.6
        local BURST_DROP_PERCENT = 0.2
        --// How long the dodge lasts, how far it goes, and the sprint on top of
        --// the normal run speed while it does.
        local DODGE_TIME = 1.3
        local DODGE_DISTANCE = 36
        local DODGE_SPEED_BONUS = 12
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
                --// "Idle", "Approach", "Fight", "Recover" or "Done".
                Phase = "Idle",
                Index = 1,
                --// Next point of the stop's saved Path to walk (1 = first).
                PathIndex = 1,
                WalkFrom = nil,
                WalkSampleAt = nil,
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
                --// When the game's Interact input was last pressed on the way.
                InteractAt = nil,
                --// Where the character stood when the waypoint teleport was
                --// fired, and how many times it has been retried for this stop.
                TeleportFrom = nil,
                Teleports = 0,
                --// Health watching for a skill: the baseline percent and when
                --// the current window started.
                HpAt = nil,
                HpBase = nil,
                --// While a dodge runs: when it ends, where it runs to, and the
                --// normal speed to put back afterwards.
                DodgeUntil = 0,
                DodgeTarget = nil,
                DodgeFromSpeed = nil,
                --// This recovery is a death, not a planned reset: walk the same
                --// stop's path again instead of moving on to the next stop.
                RestartStop = false,
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
        --// Travel: the saved Path points, walked in order
        ------------------------------------------------------------------------

        --// Forgets the walk samples, so the next point starts a fresh stuck
        --// check.
        local function ResetWalk()
            S.WalkFrom = nil
            S.WalkSampleAt = nil
        end

        --// Walks at Point until it is within Reach of it. Straight MoveTo with
        --// a hop over anything low: the way there is the stop's saved Path, so
        --// nothing has to guess a route round a building.
        local function WalkTo(Point, Reach, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return false
            end

            if AICCombatUtils.GetHorizontalDistance(Point, RootPart.Position) <= Reach then
                Humanoid:Move(Vector3.zero)
                return true
            end

            --// Stuck (a step, a fence, a corner): hop. Sampled, never compared
            --// frame by frame: a walking character covers under a stud a
            --// frame, which a per-frame check reads as standing still.
            if not S.WalkSampleAt or Now - S.WalkSampleAt >= STUCK_SAMPLE then
                if S.WalkFrom and (RootPart.Position - S.WalkFrom).Magnitude < STUCK_DISTANCE then
                    AICCombatUtils.DoJump()
                end

                S.WalkFrom = RootPart.Position
                S.WalkSampleAt = Now
            end

            AICCombatUtils.DoJumpIfObstacle(Point)
            Humanoid:MoveTo(Point)

            return false
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

                if #(Stop.Path or {}) > 0 then
                    Extra = Extra .. string.format("  P%d", #Stop.Path)
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

        --// Saved Path points of the stop picked in "Edit Boss Stop".
        local function BuildPathLabels()
            local Stop = SelectedStop()
            local Labels = {}

            for Index, Point in ipairs(Stop and Stop.Path or {}) do
                Labels[Index] = string.format(
                    "#%d  (%.0f, %.0f, %.0f)",
                    Index,
                    Point.X,
                    Point.Y,
                    Point.Z
                )
            end

            return Labels
        end

        function AICUI.RefreshBossPathList()
            if not UIRef.BossPathComponent then
                return
            end

            UIRef.BossPathComponent:SetPriority(BuildPathLabels())

            if UIRef.BossPathLabel then
                local Stop = SelectedStop()

                if Stop then
                    UIRef.BossPathLabel.Text = string.format(
                        "PATH TO %s  (#%d)  %d POINTS",
                        string.upper(Stop.Label),
                        AICProfile.S.SelectedBossStopIndex,
                        #(Stop.Path or {})
                    )
                else
                    UIRef.BossPathLabel.Text = "PATH TO BOSS  NO STOP SELECTED"
                end
            end
        end

        local function GetWaitExpChecks()
            local Checks = {}

            for Index, Stop in ipairs(GetStops()) do
                Checks[Index] = Stop.WaitExp == true
            end

            return Checks
        end

        local function GetResetWaits()
            local Waits = {}

            for Index, Stop in ipairs(GetStops()) do
                Waits[Index] = tonumber(Stop.ResetWait) or 0
            end

            return Waits
        end

        function AICUI.RefreshBossRouteList()
            if not UIRef.BossListComponent then
                return
            end

            UIRef.BossListComponent:SetPriority(BuildLabels(), GetResetWaits(), GetWaitExpChecks())
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
            if UIRef.BossRadiusBox then UIRef.BossRadiusBox:Set(tostring(Stop.Radius or 0), false) end
            if UIRef.BossResetAfterKillToggle then
                UIRef.BossResetAfterKillToggle:Set(Stop.ResetAfterKill == true, false)
            end
            if UIRef.BossLoopToggle then UIRef.BossLoopToggle:Set(CONFIG.BOSS_ROUTE_LOOP ~= false, false) end
            AICUI.RefreshBossPathList()
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
            AICUI.RefreshBossPathList()
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

        --// Puts the speed the dodge borrowed back and forgets the dodge. Safe
        --// without a character (dead, loading): the next body has its own
        --// speed and only the state needs clearing.
        local function EndDodge(Humanoid)
            if not Humanoid then
                local _, Current = Runtime:GetCharacter()
                Humanoid = Current
            end

            if S.DodgeFromSpeed and Humanoid and (tonumber(Humanoid.Health) or 0) > 0 then
                Humanoid.WalkSpeed = S.DodgeFromSpeed
            end

            S.DodgeFromSpeed = nil
            S.DodgeUntil = 0
            S.DodgeTarget = nil
        end

        local function StopRoute(StatusText)
            S.Phase = "Idle"
            S.SeenTarget = false
            S.KillAt = nil
            S.WaitUntil = nil
            S.WalkStart = nil
            EndDodge()
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
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
            S.PathIndex = 1
            S.InteractAt = nil
            S.TeleportFrom = nil
            S.Teleports = 0
            S.RestartStop = false
            S.RecoveredAt = nil
            S.HpAt = nil
            S.HpBase = nil
            EndDodge()
            S.BestDistance = nil
            S.LastProgressAt = Now
            S.Resets = 0
            S.SkipExpCheck = true
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
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

        --// Restart: the character died rather than being reset here, so the
        --// same stop is walked again from its first path point once it is back.
        local function BeginRecover(Now, Reason, SkipExpCheck, Restart)
            EndDodge()
            S.Phase = "Recover"
            S.PhaseStart = Now
            S.RecoveredAt = nil
            S.RestartStop = Restart == true
            S.SkipExpCheck = SkipExpCheck == true
            S.ExpBefore = nil

            if not S.SkipExpCheck then
                S.ExpBefore = GetExp()
            end

            S.ExpDeadline = Now + EXP_LOSS_TIMEOUT
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
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

        --// The recovery is done. A planned reset moves the route on; a death
        --// walks the same stop's path again, from its first point, instead of
        --// pretending the boss was dealt with.
        local function FinishRecovery(Now)
            if S.RestartStop then
                S.RestartStop = false
                BeginStop(Now)
            else
                Advance(Now)
            end
        end

        --// Waits for the character after a reset or a death, then for Wait
        --// After Reset (and the EXP drop, when the stop asks for it). The wait
        --// is measured from the frame the character is back, so the death
        --// animation is never mistaken for part of it.
        local function RecoverStep(Now)
            if S.Phase ~= "Recover" then
                return false
            end

            local _, Humanoid = Runtime:GetCharacter()

            if not Humanoid or Humanoid.Health <= 0 then
                S.RecoveredAt = nil

                if Now - S.PhaseStart >= RESPAWN_TIMEOUT then
                    Say(
                        "Boss Route",
                        S.RestartStop
                            and "No respawn; retrying the stop"
                            or "No respawn, moving to the next stop",
                        4
                    )
                    FinishRecovery(Now)
                end

                return true
            end

            if not S.RecoveredAt then
                S.RecoveredAt = Now
                --// The EXP window runs from the respawn too, so a slow death
                --// cannot use up the whole wait before the character is back.
                S.ExpDeadline = Now + EXP_LOSS_TIMEOUT
            end

            --// Back on the character and straight on: the pause that matters
            --// is the one before the reset (Reset After). The old second wait
            --// after the respawn only delayed the next stop, so it is gone;
            --// Wait Exp is the only thing that can hold the route here.
            local Stop = CurrentStop()

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

            FinishRecovery(Now)
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

        --// Asks for the sword. The cached Equipped flag is not trusted: it
        --// survives a reset or a respawn that sheathed the sword, so checking
        --// it meant this helper was never called and the boss was fought
        --// unarmed until an attack happened to equip the sword. The helper
        --// itself reads the weld and rate-limits with the game's equip
        --// cooldown, so asking every frame cannot toggle the sword.
        --// True when the equip input was just sent: the game needs a frame to
        --// swap the weld, and closing in with the sword still on the back is
        --// how the character got hit before it could swing.
        local function RequireWeapon(Now)
            if not AICFeature.EnsureWeaponDrawn then
                return false
            end

            return AICFeature.EnsureWeaponDrawn(Now) == true
        end

        --// A point to run to from TargetRoot: straight away first, then to
        --// either side, then behind, skipping directions with a hole or a wall.
        local function PickDodgePoint(RootPart, TargetRoot)
            local Away = Vector3.new(
                RootPart.Position.X - TargetRoot.Position.X,
                0,
                RootPart.Position.Z - TargetRoot.Position.Z
            )

            if Away.Magnitude < 0.01 then
                Away = Vector3.xAxis
            else
                Away = Away.Unit
            end

            local Fallback = nil

            for _, Degrees in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
                local Angle = math.rad(Degrees)
                local Cos, Sin = math.cos(Angle), math.sin(Angle)
                local Direction = Vector3.new(
                    Away.X * Cos - Away.Z * Sin,
                    0,
                    Away.X * Sin + Away.Z * Cos
                )
                local Candidate = RootPart.Position + Direction * DODGE_DISTANCE
                local Hole = AICCombatUtils.IsHoleAhead(Candidate)

                if not Hole and AICCombatUtils.IsPathClear(Candidate) then
                    return Candidate
                end

                if not Hole and not Fallback then
                    Fallback = Candidate
                end
            end

            return Fallback or (RootPart.Position + Away * DODGE_DISTANCE)
        end

        --// Runs away from the boss for a moment at sprint speed. True while the
        --// dodge is still running; false on the frame it ends (and whenever
        --// there is no dodge), so the fight can carry on.
        local function DodgeStep(Target, Humanoid, RootPart, Now)
            if (S.DodgeUntil or 0) <= Now then
                if S.DodgeFromSpeed then
                    EndDodge(Humanoid)
                end

                return false
            end

            if not S.DodgeTarget then
                local TargetRoot = Target and Target:FindFirstChild("HumanoidRootPart")

                if not TargetRoot then
                    EndDodge(Humanoid)
                    return false
                end

                S.DodgeFromSpeed = tonumber(Humanoid.WalkSpeed) or 0
                S.DodgeTarget = PickDodgePoint(RootPart, TargetRoot)
            end

            --// Run, not walk: the normal run speed plus a sprint.
            local Speed = tonumber(Humanoid.WalkSpeed) or 0
            local RunSpeed = (tonumber(CONFIG.MAXIMUM_WALKSPEED) or Speed) + DODGE_SPEED_BONUS

            if Speed < RunSpeed then
                Humanoid.WalkSpeed = RunSpeed
            end

            AICCombatUtils.DoJumpIfObstacle(S.DodgeTarget)
            Humanoid:MoveTo(S.DodgeTarget)
            SetStatus(string.format("STOP %d/%d  DODGE", S.Index, #GetStops()))

            return true
        end

        --// True when health fell by a burst inside the window: a boss skill.
        local function IsHealthBurst(Humanoid, Now)
            local MaxHealth = tonumber(Humanoid.MaxHealth) or 0

            if MaxHealth <= 0 then
                return false
            end

            local Percent = math.clamp((tonumber(Humanoid.Health) or 0) / MaxHealth, 0, 1)

            if not S.HpAt or Now - S.HpAt > BURST_WINDOW then
                S.HpAt = Now
                S.HpBase = Percent
                return false
            end

            if Percent > (S.HpBase or 0) then
                S.HpBase = Percent
            end

            if (S.HpBase or 0) - Percent >= BURST_DROP_PERCENT then
                S.HpAt = Now
                S.HpBase = Percent
                return true
            end

            return false
        end

        --// Walks into swinging distance and fights. The attack goes through
        --// AttackTarget, not PerformCombatActions: that one also demands the
        --// mob be on Auto Farm's Enemy Priority list, so the boss stop's own
        --// target was found, drawn for, and then never swung at.
        local function Fight(Target, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()
            local TargetRoot = Target:FindFirstChild("HumanoidRootPart")

            if not Humanoid or not RootPart or not TargetRoot then
                return
            end

            if RequireWeapon(Now) then
                Humanoid:Move(Vector3.zero)
                return
            end

            --// A dodge already running owns the frame.
            if DodgeStep(Target, Humanoid, RootPart, Now) then
                return
            end

            --// A skill just landed: run out of it instead of trading hits.
            if IsHealthBurst(Humanoid, Now) then
                S.DodgeUntil = Now + DODGE_TIME
                S.DodgeTarget = nil

                if DodgeStep(Target, Humanoid, RootPart, Now) then
                    Say("Boss Route", "Dodging a skill at stop #" .. tostring(S.Index), 2)
                    return
                end
            end

            local Offset = TargetRoot.Position - RootPart.Position
            local Distance = AICCombat.GetCombatDistance(Target, Offset)

            if Distance > FIGHT_STANDOFF then
                local Flat = Vector3.new(Offset.X, 0, Offset.Z)
                local Direction = Flat.Magnitude > 0.01 and Flat.Unit or Vector3.xAxis
                --// Stop just short of the body, not inside it.
                local Destination = TargetRoot.Position - Direction * math.max(FIGHT_STANDOFF - 1, 2)

                AICCombatUtils.DoJumpIfObstacle(Destination)
                Humanoid:MoveTo(Destination)
            else
                Humanoid:Move(Vector3.zero)
                AICCombat.FaceCombatTarget(Target)
            end

            --// The same swing and skill inputs Auto Farm presses, with the
            --// same attack clock. Called while closing in too: it only swings
            --// once the target is in the combat range.
            AICCombat.AttackTarget(Target, Now)
        end

        --// The Farming waypoint route presses the game's Interact input while
        --// it walks (Auto Farm does it every INTERACTION_INTERVAL), which is
        --// how doors, levers and other proximity prompts get used on the way.
        --// Boss Route owns the frame, so nothing else would press it and the
        --// character would walk straight past every prompt on the path.
        local function PressInteract(Now)
            local GetInput = Runtime.GetInputBindableFunction

            if not GetInput then
                return
            end

            local Interval = tonumber(CONFIG.INTERACTION_INTERVAL) or INTERACT_INTERVAL

            if S.InteractAt and Now - S.InteractAt < Interval then
                return
            end

            S.InteractAt = Now

            local InputBindableFunction = GetInput(Runtime)

            if not InputBindableFunction then
                return
            end

            --// A game without the binding must not break the walk.
            pcall(function()
                InputBindableFunction:Invoke(
                    "InteractButton",
                    Enum.UserInputState.Begin
                )
            end)
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
                S.TeleportFrom = RootPart.Position

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

            --// A teleport fired before a just-respawned character had loaded
            --// can be dropped by the game. If nothing moved and the stop is
            --// still far away, ask once more rather than walking the whole
            --// way from spawn.
            if S.TeleportFrom then
                local Moved = (RootPart.Position - S.TeleportFrom).Magnitude
                local ToStop = AICCombatUtils.GetHorizontalDistance(Stop.Position, RootPart.Position)
                S.TeleportFrom = nil

                if Moved < 4 and ToStop > 60 and (S.Teleports or 0) < 1 then
                    S.Teleports = (S.Teleports or 0) + 1
                    S.Teleported = false
                end
            end

            local Path = Stop.Path or {}
            local Point = Path[S.PathIndex]
            local Destination = Point or Stop.Position
            local Reach = Point
                and PATH_REACH
                or (tonumber(Runtime:GetPlaceConfig().REACH_DISTANCE) or REACH_DISTANCE)
            local Flat = AICCombatUtils.GetHorizontalDistance(Destination, RootPart.Position)

            --// Close to the stop now: get the sword out before the fight, so
            --// the first swing is not spent equipping it under the boss.
            if AICCombatUtils.GetHorizontalDistance(Stop.Position, RootPart.Position) <= WEAPON_READY_DISTANCE then
                RequireWeapon(Now)
            end

            --// On the way: use whatever prompt the character passes, the same
            --// way the Farming waypoint route does. Not on the frame the stop
            --// is reached, where the fight begins instead.
            if Flat > Reach then
                PressInteract(Now)
            end

            --// Progress, not the walker's opinion: a wrong point or a wall in
            --// the way shows up as no approach at all.
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

            if WalkTo(Destination, Reach, Now) then
                if Point then
                    S.PathIndex += 1
                    S.BestDistance = nil
                    S.LastProgressAt = Now
                    --// The 120 s cap is per leg, so a long recorded route is
                    --// not cut short just for having many points.
                    S.WalkStart = Now
                    ResetWalk()

                    SetStatus(string.format(
                        "STOP %d/%d  PATH %d/%d",
                        S.Index,
                        #GetStops(),
                        math.min(S.PathIndex - 1, #Path),
                        #Path
                    ))
                else
                    --// On the spot: fight straight away. There is no wait at
                    --// the stop any more; the boss is picked up from here.
                    S.Phase = "Fight"
                    S.FightStart = Now
                    S.SeenTarget = false
                    S.KillAt = nil
                    Humanoid:Move(Vector3.zero)
                    SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                end

                return
            end

            if Point then
                SetStatus(string.format(
                    "STOP %d/%d  PATH %d/%d",
                    S.Index,
                    #GetStops(),
                    S.PathIndex,
                    #Path
                ))
            else
                SetStatus(string.format("STOP %d/%d  WALKING", S.Index, #GetStops()))
            end
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

                SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                Fight(Target, Now)
                return
            end

            AICCombat.S.ClosestTarget = nil
            Humanoid:Move(Vector3.zero)
            EndDodge(Humanoid)

            --// The boss went down: a grace period covers a second mob of the
            --// same stop still standing up, then the stop's own Reset After
            --// pause is held before the character is reset.
            if S.SeenTarget then
                S.KillAt = S.KillAt or Now

                --// The pause belongs to the reset; with Reset After Kill off
                --// there is nothing to wait for and the route moves on after
                --// the grace.
                local ResetWait = Stop.ResetAfterKill and (tonumber(Stop.ResetWait) or 0) or 0
                local Delay = math.max(KILL_GRACE, ResetWait)
                local Left = Delay - (Now - S.KillAt)

                if Left > 0.05 then
                    SetStatus(string.format(
                        "STOP %d/%d  CLEARING  %ds",
                        S.Index,
                        #GetStops(),
                        math.ceil(Left)
                    ))
                    return
                end

                --// The fight is done. The only reset is this one: after the
                --// kill, never while the boss is still standing.
                if Stop.ResetAfterKill then
                    BeginReset(Now, "BOSS DOWN")
                else
                    Advance(Now)
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
            --// loss is already taken, so wait for the respawn only, then walk
            --// this same stop's path again rather than skipping it.
            if not Humanoid or not RootPart or Humanoid.Health <= 0 then
                if S.Phase ~= "Recover" then
                    BeginRecover(Now, "DIED", true, true)
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
        --// returns before BossStep: keeps a reset waiting for its respawn, and
        --// registers a death the route did not cause. Without the second part
        --// a death was invisible to the route (Auto Farm returns before
        --// BossStep while dead), so it resumed the half-walked path from the
        --// spawn on respawn and never teleported back to the stop's waypoint.
        AICFeature.BossRecoverStep = function(Now)
            if not IsEnabled() then
                return false
            end

            if S.Phase ~= "Recover" then
                BeginRecover(Now, "DIED", true, true)
            end

            return RecoverStep(Now)
        end

        --// A profile load brings another place's stops with it.
        AICFeature.ResetBossRoute = function()
            EndDodge()
            S.HpAt = nil
            S.HpBase = nil
            S.Index = 1
            S.Phase = "Idle"
            S.SeenTarget = false
            S.KillAt = nil
            S.WaitUntil = nil
            S.WalkStart = nil
            ResetWalk()
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
                Path = {},
                Targets = {},
                Waypoint = 0,
                ResetAfterKill = true,
                ResetWait = 0,
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
        end)        UIRef.BossListComponent = UIRef.BossSection:AddPriority("Boss Route", BuildLabels(), {
            --// Seconds held at the corpse after the kill, before the reset.
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

            Stop.ResetWait = Value
            AICProfile.QueueProfileSave()
            SetStatus(string.format("STOP #%d RESETS %ss AFTER THE KILL", Index, tostring(Value)))
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

        ------------------------------------------------------------------------
        --// Path to Boss: the points walked to reach each stop
        ------------------------------------------------------------------------

        UIRef.BossPathSection = UIRef.BossTab:AddSection("Path to Boss")
        UIRef.BossPathLabel = UIRef.BossPathSection:AddLabel("PATH TO BOSS  NO STOP SELECTED")

        UIRef.BossPathSection:AddButton("Add Path Point Here", function()
            local Stop = SelectedStop()
            local _, _, RootPart = Runtime:GetCharacter()

            if not Stop then
                SetStatus("PICK A BOSS STOP FIRST")
                return
            end

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit() then
                return
            end

            Stop.Path = Stop.Path or {}
            table.insert(Stop.Path, AICConfig.RoundVector3(RootPart.Position))
            Commit(string.format("PATH POINT #%d ADDED", #Stop.Path))
            Say("Boss Route", string.format("Path point #%d saved", #Stop.Path))
        end)

        UIRef.BossPathSection:AddButton("Clear Path", function()
            local Stop = SelectedStop()

            if not Stop then
                SetStatus("PICK A BOSS STOP FIRST")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.clear(Stop.Path or {})
            Commit("PATH CLEARED")
        end)

        UIRef.BossPathComponent = UIRef.BossPathSection:AddPriority("Path Points", {})

        local PathMoveUp = UIRef.BossPathComponent.MoveUp
        local PathMoveDown = UIRef.BossPathComponent.MoveDown
        local PathRemove = UIRef.BossPathComponent.Remove

        local function MovePath(Component, Label, Delta, Original, StatusText)
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Path = Stop.Path or {}
            local Index = table.find(BuildPathLabels(), Label)
            local Other = Index and Index + Delta

            if not Other or Other < 1 or Other > #Path then
                return
            end

            Path[Index], Path[Other] = Path[Other], Path[Index]
            Original(Component, Label)
            Commit(StatusText)
        end

        function UIRef.BossPathComponent:MoveUp(Label)
            MovePath(self, Label, -1, PathMoveUp, "PATH POINT MOVED UP")
        end

        function UIRef.BossPathComponent:MoveDown(Label)
            MovePath(self, Label, 1, PathMoveDown, "PATH POINT MOVED DOWN")
        end

        function UIRef.BossPathComponent:Remove(Label)
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = table.find(BuildPathLabels(), Label)

            if not Index then
                return
            end

            table.remove(Stop.Path, Index)
            PathRemove(self, Label)
            Commit("PATH POINT REMOVED #" .. tostring(Index))
        end

        --// Every control exists now, so fill the edit boxes from the selected
        --// stop instead of leaving them empty until the first edit.
        AICUI.RefreshBossRoutePickers()
        AICUI.RefreshBossPathList()
        SetStatus("IDLE")

        return Feature
    end,
}
