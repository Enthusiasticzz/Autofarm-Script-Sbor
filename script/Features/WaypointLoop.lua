-- WaypointLoop: farm only the farm zones paired with a waypoint, walking the
-- route between them.
--
-- Each waypoint may be paired with one farm zone, and each farm zone may have
-- its own target list (empty = the Enemy Priority list).
--   * The route is walked as usual up to the first paired waypoint, where the
--     loop takes over.
--   * It always heads for the closest paired zone (walking distance along the
--     route) worth visiting: targets visible there, or not yet found empty
--     and not dead according to workspace.RespawnTimers. The choice is made
--     again at every waypoint, so a closer zone with a target is never
--     walked past.
--   * A zone found empty is remembered and skipped until one of its targets
--     respawns (its timer is removed).
--   * With every zone dead, walk to the zone whose target respawns soonest
--     and wait there, instead of walking back and forth.
-- The walk only uses the waypoints between paired ones: it never heads back
-- past the first or last paired waypoint (e.g. first pair on #34 never walks
-- back to #33).
return {
    Name = "WaypointLoop",
    IsFeature = true,
    Dependencies = {"Runtime", "ProfileManager", "Components", "Targeting", "Waypoints", "Farmzone", "RespawnTimers"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Players = Context.Services.Players
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICConfig = Context.AICConfig
        local AICProfile = Context.AICProfile
        local AICCombat = Context.AICCombat
        local AICCombatUtils = Context.AICCombatUtils
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// How often zones are rescanned for targets.
        local ZONE_SCAN_INTERVAL = 0.25
        --// How long a zone must stay empty before it counts as cleared, so a
        --// scan that misses a mob for a moment does not send us away.
        local ZONE_CLEAR_GRACE = 1.5
        --// A zone whose timers say its target is alive, but which was found
        --// empty, is looked at again after this long.
        local CHECKED_EXPIRE = 60

        local Feature = {
            Name = "WaypointLoop",
            IsFeature = true,
        }

        AICFeature.S.Loop = {
            --// Waypoint the character is at, or nil before the route ends.
            Index = nil,
            --// Paired waypoint being walked to or fought at.
            Goal = nil,
            --// When the goal zone was first seen empty, or nil.
            EmptySince = nil,
            --// [ZoneIndex] = when that zone was last found empty. Kept across
            --// deaths: it describes the world, not the character.
            Checked = {},
            ScanTime = 0,
            ScanResult = {},
        }

        local Loop = AICFeature.S.Loop

        local function ZoneTargetNames(Zone)
            if type(Zone.Targets) == "table" and #Zone.Targets > 0 then
                return Zone.Targets
            end

            return CONFIG.TARGET_ENTITY_PRIORITY or {}
        end

        --// Waypoints paired with an existing farm zone, in route order.
        local function PairedWaypoints(PlaceConfig)
            local List = {}

            for WaypointIndex, ZoneIndex in ipairs(PlaceConfig.WAYPOINT_ZONES or {}) do
                if ZoneIndex > 0 and PlaceConfig.WAYPOINTS[WaypointIndex] and PlaceConfig.FARM_ZONES[ZoneIndex] then
                    table.insert(List, WaypointIndex)
                end
            end

            return List
        end

        --// True when a living target of this zone's list stands inside it.
        local function ScanZone(Zone)
            local Names = ZoneTargetNames(Zone)

            if #Names == 0 then
                return false
            end

            local MobFolder = workspace:FindFirstChild("Mobs")
            local Candidates = MobFolder and MobFolder:GetChildren() or {}

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer.Character then
                    table.insert(Candidates, OtherPlayer.Character)
                end
            end

            for _, Mob in ipairs(Candidates) do
                local EntityName = AICCombat.GetTargetEntityName(Mob)

                if EntityName and table.find(Names, EntityName) then
                    local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                    local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                    if MobHumanoid
                        and MobRoot
                        and MobHumanoid.Health > 0
                        and AICCombatUtils.IsPositionInsideZone(MobRoot.Position, Zone)
                        and not AICCombatUtils.IsInsideFarmDeadzone(MobRoot.Position)
                    then
                        return true
                    end
                end
            end

            return false
        end

        local function ZoneHasTargets(PlaceConfig, ZoneIndex, now)
            if now - Loop.ScanTime >= ZONE_SCAN_INTERVAL then
                Loop.ScanTime = now
                table.clear(Loop.ScanResult)
            end

            if Loop.ScanResult[ZoneIndex] == nil then
                local Zone = PlaceConfig.FARM_ZONES[ZoneIndex]
                Loop.ScanResult[ZoneIndex] = Zone ~= nil and ScanZone(Zone)
            end

            return Loop.ScanResult[ZoneIndex]
        end

        local function HasOwnTargets(Zone)
            return type(Zone.Targets) == "table" and #Zone.Targets > 0
        end

        --// Respawn timers of a zone with its own target list:
        --//   Dead     every target is waiting to respawn
        --//   Soonest  seconds until the first of them is back, or nil
        --// Zones on the Enemy Priority list have no timer view (nil, nil).
        local function ZoneRespawn(Zone)
            if not HasOwnTargets(Zone) or not AICFeature.GetRespawnState then
                return nil, nil
            end

            local Dead, Soonest = true, nil

            for _, Name in ipairs(Zone.Targets) do
                local Pending, Remaining = AICFeature.GetRespawnState(Name)

                if Pending == 0 then
                    Dead = false
                elseif Remaining then
                    Soonest = math.min(Soonest or math.huge, Remaining)
                end
            end

            return Dead, Soonest
        end

        --// A zone we stood in and found empty is not revisited until one of
        --// its targets respawns. Where the timers claim a target is alive
        --// but it was not there (it may have wandered off), look again after
        --// CHECKED_EXPIRE; a zone with no timer view waits for a respawn.
        local function IsCheckedEmpty(PlaceConfig, ZoneIndex, now)
            local CheckedAt = Loop.Checked[ZoneIndex]

            if not CheckedAt then
                return false
            end

            local Zone = PlaceConfig.FARM_ZONES[ZoneIndex]

            if Zone and HasOwnTargets(Zone) and now - CheckedAt >= CHECKED_EXPIRE then
                Loop.Checked[ZoneIndex] = nil
                return false
            end

            return true
        end

        --// Worth walking to: targets are visible there, or nothing says the
        --// zone is empty (not checked empty, timers do not say all dead).
        local function IsZoneCandidate(PlaceConfig, ZoneIndex, now)
            if ZoneHasTargets(PlaceConfig, ZoneIndex, now) then
                return true
            end

            if IsCheckedEmpty(PlaceConfig, ZoneIndex, now) then
                return false
            end

            local Zone = PlaceConfig.FARM_ZONES[ZoneIndex]
            return Zone ~= nil and ZoneRespawn(Zone) ~= true
        end

        --// Walking distance in studs along the route between two waypoints.
        local function RouteDistance(PlaceConfig, From, To)
            local Waypoints = PlaceConfig.WAYPOINTS
            local Step = To > From and 1 or -1
            local Total = 0

            for Index = From, To - Step, Step do
                Total += (Waypoints[Index + Step] - Waypoints[Index]).Magnitude
            end

            return Total
        end

        --// Where to go from the current waypoint:
        --//   1. the closest paired zone (walking distance) worth visiting;
        --//   2. with none, the zone whose target respawns soonest, to wait
        --//      there;
        --//   3. nil when nothing is known: stay where we are.
        local function SelectGoal(PlaceConfig, Paired, now)
            local Best, BestDistance = nil, math.huge

            for _, WaypointIndex in ipairs(Paired) do
                local Distance = RouteDistance(PlaceConfig, Loop.Index, WaypointIndex)

                if Distance < BestDistance
                    and IsZoneCandidate(PlaceConfig, PlaceConfig.WAYPOINT_ZONES[WaypointIndex], now)
                then
                    Best, BestDistance = WaypointIndex, Distance
                end
            end

            if Best then
                return Best
            end

            local BestRespawn = math.huge

            for _, WaypointIndex in ipairs(Paired) do
                local Zone = PlaceConfig.FARM_ZONES[PlaceConfig.WAYPOINT_ZONES[WaypointIndex]]
                local _, Soonest = ZoneRespawn(Zone)

                if Soonest then
                    local Distance = RouteDistance(PlaceConfig, Loop.Index, WaypointIndex)

                    if Soonest < BestRespawn or (Soonest == BestRespawn and Distance < BestDistance) then
                        Best, BestRespawn, BestDistance = WaypointIndex, Soonest, Distance
                    end
                end
            end

            return Best
        end

        --// Nearest paired waypoint regardless of targets.
        local function NearestGoal(PlaceConfig, Paired)
            local Best, BestDistance = nil, math.huge

            for _, WaypointIndex in ipairs(Paired) do
                local Distance = RouteDistance(PlaceConfig, Loop.Index, WaypointIndex)

                if Distance < BestDistance then
                    Best, BestDistance = WaypointIndex, Distance
                end
            end

            return Best
        end

        --// A respawn makes every zone hunting that enemy worth a visit again.
        function AICFeature.OnEnemyRespawned(EnemyName)
            local PlaceConfig = Runtime:GetPlaceConfig()
            local Wanted = string.lower(EnemyName)

            for ZoneIndex, Zone in ipairs(PlaceConfig and PlaceConfig.FARM_ZONES or {}) do
                for _, Name in ipairs(ZoneTargetNames(Zone)) do
                    if string.lower(Name) == Wanted then
                        Loop.Checked[ZoneIndex] = nil
                        break
                    end
                end
            end
        end

        --// Waypoint closest to the character, for picking the loop up when
        --// it did not start from the route (e.g. switched on mid-farm).
        local function NearestWaypointIndex(PlaceConfig, RootPart)
            local Best, BestDistance = #PlaceConfig.WAYPOINTS, math.huge

            for Index, Position in ipairs(PlaceConfig.WAYPOINTS) do
                local Distance = (Position - RootPart.Position).Magnitude

                if Distance < BestDistance then
                    Best, BestDistance = Index, Distance
                end
            end

            return Best
        end

        local function StandStill(Humanoid)
            local FaceOrientation = Runtime:GetFaceOrientation()

            if FaceOrientation then
                FaceOrientation.Enabled = false
            end

            Humanoid.AutoRotate = true
            Humanoid:Move(Vector3.zero)
        end

        --// Walks to the neighbouring waypoint NextIndex; on arrival that becomes
        --// the current waypoint, and its wait time (if any) is honoured.
        local function StepTo(PlaceConfig, NextIndex, Humanoid, RootPart, now)
            local Target = PlaceConfig.WAYPOINTS[NextIndex]
            local Offset = Target - RootPart.Position
            local Horizontal = Vector3.new(Offset.X, 0, Offset.Z).Magnitude
            local Reach = tonumber(PlaceConfig.REACH_DISTANCE) or 5

            local VerticalOk = math.abs(Offset.Y) <= math.max(Reach, CONFIG.JUMP_HEIGHT + 2)
            local IsJumpWaypoint, JumpReached = AICConfig.CheckJumpWaypoint(PlaceConfig, NextIndex, Horizontal)

            --// A Jump waypoint: jump at it and head straight on to the
            --// next one, without stopping (see AutoFarming's route).
            if IsJumpWaypoint then
                if JumpReached and VerticalOk and Humanoid.FloorMaterial ~= Enum.Material.Air then
                    Loop.Index = NextIndex
                    AICCombatUtils.DoJump()
                    --// Keep the run-up going; walking back to this waypoint
                    --// would kill the jump. The next frame heads on.
                    Humanoid:Move(AICCombatUtils.GetFlatLook(RootPart))
                    return false
                end
            elseif Horizontal <= Reach and VerticalOk then
                Loop.Index = NextIndex

                local Wait = tonumber(PlaceConfig.WAYPOINT_WAITS and PlaceConfig.WAYPOINT_WAITS[NextIndex]) or 0

                if Wait > 0 then
                    AICFeature.S.WaypointWaitUntil = now + Wait
                end

                StandStill(Humanoid)
                return true
            end

            local FaceOrientation = Runtime:GetFaceOrientation()

            if FaceOrientation then
                FaceOrientation.Enabled = false
            end

            Humanoid.AutoRotate = true
            Humanoid:MoveTo(Target)

            if not AICCombatUtils.DoJumpIfRouteHole() then
                AICCombatUtils.DoJumpIfObstacle(Target)
            end

            return false
        end

        function AICFeature.ResetWaypointLoop()
            Loop.Index = nil
            Loop.Goal = nil
            Loop.EmptySince = nil
            table.clear(Loop.ScanResult)
            AICCombatUtils.S.ActiveZoneIndex = nil
        end

        --// Paired waypoints when the loop applies, else nil.
        local function GetActivePaired()
            local PlaceConfig = Runtime:GetPlaceConfig()

            if not FeatureState.WaypointLoop.Enabled
                or FeatureState.AutoFind.Enabled
                or FeatureState.IgnoreFarmZone.Enabled
                or not PlaceConfig
                or #PlaceConfig.WAYPOINTS == 0
            then
                return nil
            end

            local Paired = PairedWaypoints(PlaceConfig)
            return #Paired > 0 and Paired or nil
        end

        --// First paired waypoint: the route hands over to the loop there.
        --// nil when the loop does not apply and the route runs to the end.
        function AICFeature.GetWaypointLoopEntry()
            local Paired = GetActivePaired()
            return Paired and Paired[1] or nil
        end

        --// Called by the route on reaching the entry waypoint (or beyond).
        function AICFeature.EnterWaypointLoop(WaypointIndex)
            AICFeature.ResetWaypointLoop()
            Loop.Index = WaypointIndex
        end

        --// Called by the farm loop once the route has been walked.
        --//   nil     the loop does not apply; farm as before
        --//   "fight" fight (or wait) inside the active paired zone
        --//   "move"  the loop moved the character this frame
        function AICFeature.WaypointLoopStep(now)
            local PlaceConfig = Runtime:GetPlaceConfig()
            local _, Humanoid, RootPart = Runtime:GetCharacter()
            local Paired = GetActivePaired()

            if not Paired or not Humanoid or not RootPart then
                if Loop.Index then
                    AICFeature.ResetWaypointLoop()
                end

                return nil
            end

            --// Not entered from the route: pick up from the nearest waypoint.
            if not Loop.Index or not PlaceConfig.WAYPOINTS[Loop.Index] then
                Loop.Index = NearestWaypointIndex(PlaceConfig, RootPart)
                Loop.Goal = nil
            end

            --// No goal yet, or its pair was removed.
            if not Loop.Goal or not table.find(Paired, Loop.Goal) then
                Loop.Goal = SelectGoal(PlaceConfig, Paired, now) or NearestGoal(PlaceConfig, Paired)
                Loop.EmptySince = nil
            end

            if Loop.Goal ~= Loop.Index then
                AICCombatUtils.S.ActiveZoneIndex = nil
                AICCombat.S.ClosestTarget = nil

                local Arrived = StepTo(PlaceConfig, Loop.Index + (Loop.Goal > Loop.Index and 1 or -1), Humanoid, RootPart, now)

                --// Plan again at every waypoint: a closer zone with a target
                --// (the one we are standing at, say) wins over the old goal.
                if Arrived then
                    local Next = SelectGoal(PlaceConfig, Paired, now)

                    if Next and Next ~= Loop.Goal then
                        Loop.Goal = Next
                        Loop.EmptySince = nil
                    end
                end

                return "move"
            end

            local ZoneIndex = PlaceConfig.WAYPOINT_ZONES[Loop.Goal]
            AICCombatUtils.S.ActiveZoneIndex = ZoneIndex

            if ZoneHasTargets(PlaceConfig, ZoneIndex, now) then
                Loop.EmptySince = nil
                Loop.Checked[ZoneIndex] = nil
                return "fight"
            end

            Loop.EmptySince = Loop.EmptySince or now

            --// Zone cleared: remember it, then go to the closest zone still
            --// worth visiting, or wait at the one that respawns first. With
            --// nothing known the goal stays and we wait here.
            if now - Loop.EmptySince >= ZONE_CLEAR_GRACE then
                Loop.Checked[ZoneIndex] = Loop.Checked[ZoneIndex] or now

                local Next = SelectGoal(PlaceConfig, Paired, now)

                if Next and Next ~= Loop.Goal then
                    Loop.Goal = Next
                    Loop.EmptySince = nil
                end
            end

            return "fight"
        end

        function Feature:Update()
        end

        ------------------------------------------------------------------------
        --// UI: waypoint pairing (Waypoints section) and zone targets (Farmzone)
        ------------------------------------------------------------------------
        local SelectedPairWaypoint = 1
        --// Options the pair pickers were built with (joined), so an
        --// unchanged list keeps its dropdown.
        local PairPickerSignatures = { Waypoint = nil, Zone = nil }

        local function ZoneOptionLabel(ZoneIndex)
            return ZoneIndex > 0 and ("Farm Zone #" .. ZoneIndex) or "None"
        end

        function AICUI.RefreshWaypointPairPickers()
            local Section = UIRef.WaypointSection

            if not Section then
                return
            end

            local PlaceConfig = Runtime:GetPlaceConfig()
            local WaypointOptions = {}
            local ZoneOptions = { "None" }

            for Index in ipairs(PlaceConfig.WAYPOINTS) do
                table.insert(WaypointOptions, "Waypoint #" .. Index)
            end

            for Index in ipairs(PlaceConfig.FARM_ZONES) do
                table.insert(ZoneOptions, ZoneOptionLabel(Index))
            end

            if #WaypointOptions == 0 then
                WaypointOptions = { "No Waypoints" }
            end

            SelectedPairWaypoint = math.clamp(SelectedPairWaypoint, 1, math.max(1, #PlaceConfig.WAYPOINTS))

            --// The same options keep the dropdowns: they are rebuilt only when
            --// the lists change, never from inside their own pick handler
            --// for nothing (which could swallow the next click).
            local WaypointSignature = table.concat(WaypointOptions, "\n")
            local ZoneSignature = table.concat(ZoneOptions, "\n")

            if not UIRef.PairWaypointPicker or PairPickerSignatures.Waypoint ~= WaypointSignature then
                PairPickerSignatures.Waypoint = WaypointSignature

                UIRef.PairWaypointPicker = AICUI.ReplaceDropdown(UIRef.PairWaypointPicker, Section, "Pair Waypoint", WaypointOptions, function(Value)
                    local Current = Runtime:GetPlaceConfig()
                    local Index = table.find(WaypointOptions, Value)

                    if Index and Current.WAYPOINTS[Index] then
                        SelectedPairWaypoint = Index

                        if UIRef.PairZonePicker then
                            UIRef.PairZonePicker:Set(ZoneOptionLabel(Current.WAYPOINT_ZONES[Index] or 0), false)
                        end
                    end
                end)
            end

            if UIRef.PairZonePicker and PairPickerSignatures.Zone == ZoneSignature then
                if PlaceConfig.WAYPOINTS[SelectedPairWaypoint] then
                    UIRef.PairWaypointPicker:Set(WaypointOptions[SelectedPairWaypoint], false)
                    UIRef.PairZonePicker:Set(ZoneOptionLabel(PlaceConfig.WAYPOINT_ZONES[SelectedPairWaypoint] or 0), false)
                end

                return
            end

            PairPickerSignatures.Zone = ZoneSignature

            UIRef.PairZonePicker = AICUI.ReplaceDropdown(UIRef.PairZonePicker, Section, "Paired Farm Zone", ZoneOptions, function(Value)
                local Current = Runtime:GetPlaceConfig()

                if not Current.WAYPOINTS[SelectedPairWaypoint] then
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
                    return
                end

                local ZoneIndex = (table.find(ZoneOptions, Value) or 1) - 1

                Current.WAYPOINT_ZONES = AICConfig.NormalizeZonePairs(Current.WAYPOINT_ZONES, #Current.WAYPOINTS, #Current.FARM_ZONES)

                --// Nothing changed: do not save or rebuild. Rebuilding recreates
                --// this dropdown, which is how the startup freeze looped.
                if Current.WAYPOINT_ZONES[SelectedPairWaypoint] == ZoneIndex then
                    return
                end

                Current.WAYPOINT_ZONES[SelectedPairWaypoint] = ZoneIndex
                AICFeature.ResetWaypointLoop()
                AICProfile.SaveActiveProfile()
                AICUI.RefreshWaypointList()
                AICUI.SetProfileStatus("WAYPOINT #" .. SelectedPairWaypoint .. " -> " .. ZoneOptionLabel(ZoneIndex):upper())
            end)

            if PlaceConfig.WAYPOINTS[SelectedPairWaypoint] then
                UIRef.PairWaypointPicker:Set(WaypointOptions[SelectedPairWaypoint], false)
                UIRef.PairZonePicker:Set(ZoneOptionLabel(PlaceConfig.WAYPOINT_ZONES[SelectedPairWaypoint] or 0), false)
            end
        end

        --// Targets of the farm zone picked in "Edit Farm Zone".
        local function SelectedZone()
            local PlaceConfig = Runtime:GetPlaceConfig()
            return PlaceConfig.FARM_ZONES[AICProfile.S.SelectedFarmZoneIndex]
        end

        function AICUI.RefreshZoneTargets()
            local Section = UIRef.FarmzoneSection

            if not Section or not UIRef.ZoneTargetsComponent then
                return
            end

            local Zone = SelectedZone()
            UIRef.ZoneTargetsComponent:SetPriority(table.clone(Zone and Zone.Targets or {}))

            --// Choices: everything detected nearby plus the Enemy Priority list.
            local Options = {}

            for _, Name in ipairs(AICCombat.GetDetectedEnemyEntities()) do
                table.insert(Options, Name)
            end

            for _, Name in ipairs(CONFIG.TARGET_ENTITY_PRIORITY or {}) do
                if not table.find(Options, Name) then
                    table.insert(Options, Name)
                end
            end

            for Index = #Options, 1, -1 do
                if Zone and table.find(Zone.Targets or {}, Options[Index]) then
                    table.remove(Options, Index)
                end
            end

            if #Options == 0 then
                Options = { "No detected enemies" }
            end

            UIRef.ZoneTargetDropdown = AICUI.ReplaceDropdown(UIRef.ZoneTargetDropdown, Section, "Add Zone Target", Options, function(Value)
                local Current = SelectedZone()

                if not Current or Value == "No detected enemies" then
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
                    return
                end

                Current.Targets = Current.Targets or {}

                if not table.find(Current.Targets, Value) then
                    table.insert(Current.Targets, Value)
                    AICProfile.SaveActiveProfile()
                    NotifyAction("Zone Targets", "Added " .. Value)
                end

                AICUI.RefreshZoneTargets()
            end)
        end

        if UIRef.WaypointSection then
            FeatureState.WaypointLoop.Button = UIRef.WaypointSection:AddToggle(
                "Waypoint Loop",
                FeatureState.WaypointLoop.Enabled,
                function(Value)
                    FeatureState.WaypointLoop.Enabled = Value
                    AICFeature.ResetWaypointLoop()
                    AICProfile.SaveActiveProfile()
                end
            )

            AICUI.RefreshWaypointPairPickers()
        end

        if UIRef.FarmzoneSection then
            UIRef.ZoneTargetsComponent = UIRef.FarmzoneSection:AddPriority("Zone Targets", {})

            --// The list mirrors the selected zone's Targets; every edit is
            --// written back to the zone and saved.
            local Component = UIRef.ZoneTargetsComponent
            local OriginalRemove = Component.Remove
            local OriginalMoveUp = Component.MoveUp
            local OriginalMoveDown = Component.MoveDown

            local function Commit(Component)
                local Zone = SelectedZone()

                if Zone then
                    Zone.Targets = table.clone(Component.Priority)
                    AICProfile.SaveActiveProfile()
                end

                AICUI.RefreshZoneTargets()
            end

            local function Guard()
                if AICProfile.S.ActiveProfileName and SelectedZone() then
                    return true
                end

                AICUI.SetProfileStatus("CREATE / LOAD PROFILE FIRST")
                return false
            end

            function Component:Remove(Value)
                if not Guard() then return false end
                local Changed = OriginalRemove(self, Value)
                Commit(self)
                return Changed
            end

            function Component:MoveUp(Value)
                if not Guard() then return end
                OriginalMoveUp(self, Value)
                Commit(self)
            end

            function Component:MoveDown(Value)
                if not Guard() then return end
                OriginalMoveDown(self, Value)
                Commit(self)
            end

            AICUI.RefreshZoneTargets()
        end

        return Feature
    end,
}
