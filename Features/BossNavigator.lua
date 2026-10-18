-- BossNavigator walks a saved route of boss stops, fighting at each one.
--
-- It has its own tab and its own list (Boss Route on the place config), so it
-- is separate from the waypoint route Auto Farm walks and from the waypoints
-- in Profile Settings: editing one never moves the other. A stop is a spot to
-- stand on. Coming to a stop the character walks there, or teleports to one of
-- the game's waypoints first when the stop names one, then waits Wait seconds
-- and fights whatever matches its Boss Names inside its radius.
--
-- A fight ends one of three ways:
--   * the target dies and nothing else is in the radius -> the next stop;
--   * Reset After seconds pass, or health drops to Reset Below HP % -> the
--     character is reset and the next stop begins once it is back;
--   * nothing is there to fight -> the next stop.
-- Wait Exp holds the next stop until the game's EXP actually dropped after the
-- reset, so the loss is registered before walking off. A stop with it off
-- moves on after Respawn Wait instead.
--
-- The route loops unless Loop Route is off; then it plays once and switches
-- itself off. Uneven terrain is handled by WalkController, and the fight uses
-- the same combat inputs as Auto Farm. Auto Farm hands this module the frame
-- while it is on, with Auto Farm on or off.
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
        "WalkController",
    },

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICFeature = Context.AICFeature
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local UIRef = Context.UIRef
        local Movement = Context.WalkController
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
            if UIRef.BossResetBelowBox then UIRef.BossResetBelowBox:Set(tostring(Stop.ResetBelow or 0), false) end
            if UIRef.BossRespawnWaitBox then UIRef.BossRespawnWaitBox:Set(tostring(Stop.RespawnWait or 0), false) end
            if UIRef.BossRadiusBox then UIRef.BossRadiusBox:Set(tostring(Stop.Radius or 0), false) end
            if UIRef.BossNamesBox then UIRef.BossNamesBox:Set(table.concat(Stop.Targets, ", "), false) end
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
            Movement:Reset()
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
            S.Resets = 0
            S.SkipExpCheck = true
            AICCombat.S.ClosestTarget = nil
            Movement:Reset()
            SetStatus(string.format("STOP %d/%d  %s", S.Index, #Stops, Stop.Label))
        end

        local function Advance(Now)
            local Stops = GetStops()
            S.SeenTarget = false
            S.KillAt = nil
            S.FightStart = nil
            S.WalkStart = nil
            S.WaitUntil = nil

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
            Movement:Reset()
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

            if ScanResult and AICCombat.IsCombatTargetValid(ScanResult) then
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
                --// Stop a little short of the body, not inside it.
                local Standoff = math.clamp(Range * 0.4, 1, 4)
                local Destination = TargetRoot.Position - Direction * Standoff
                local Result = Movement:MoveTo(Destination, { Ignore = Target })

                if Result == "failed" then
                    Humanoid:MoveTo(Destination)
                end
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

            if Now - (S.WalkStart or Now) > WALK_TIMEOUT then
                Say("Boss Route", "Could not reach stop #" .. tostring(S.Index) .. "; skipping", 4)
                Advance(Now)
                return
            end

            SetStatus(string.format("STOP %d/%d  WALKING", S.Index, #GetStops()))
            Movement:MoveTo(Stop.Position)
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

                local ResetBelow = tonumber(Stop.ResetBelow) or 0

                if ResetBelow > 0
                    and Humanoid.MaxHealth > 0
                    and (Humanoid.Health / Humanoid.MaxHealth) * 100 <= ResetBelow
                then
                    BeginReset(Now, "LOW HP")
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
            Movement:Reset()
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
                ResetBelow = 0,
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

        UIRef.BossResetBelowBox = AddStopBox("Reset Below HP %", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.ResetBelow = math.clamp(Number, 0, 100)
            return true
        end)

        UIRef.BossRespawnWaitBox = AddStopBox("Respawn Wait (s)", function(Stop, Value)
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

        UIRef.BossNamesBox = AddStopBox("Boss Names", function(Stop, Value)
            local Names = {}

            for Name in string.gmatch(tostring(Value or ""), "[^,]+") do
                local Text = Name:gsub("^%s*(.-)%s*$", "%1")

                if Text ~= "" and not table.find(Names, Text) then
                    table.insert(Names, Text)
                end
            end

            Stop.Targets = Names
            return true
        end)

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
