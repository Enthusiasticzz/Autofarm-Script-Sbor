return {
    Name = "AutoFarming",
    IsFeature = true,
    Dependencies = {"Runtime", "Combat", "Targeting", "Navigation", "CombatUtils", "ProfileManager", "Components"},
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
            Name = "AutoFarming",
            IsFeature = true,
        }
        function Feature.updateCharacter()
            local Character = Player.Character
            local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
            local RootPart = Character and Character:FindFirstChild("HumanoidRootPart")

            Runtime:SetCharacter(Character, Humanoid, RootPart)

            if not Character or not RootPart then
                return
            end

            if not AICFeature.S.FaceAttachment then
                AICFeature.S.FaceAttachment = Instance.new("Attachment")
                AICFeature.S.FaceAttachment.Name = "FaceGoblinAttachment"
                AICFeature.S.FaceAttachment.Parent = RootPart
            end

            local FaceOrientation = Runtime:GetFaceOrientation()
            if not FaceOrientation then
                FaceOrientation = Instance.new("AlignOrientation")
                FaceOrientation.Name = "FaceGoblin"
                FaceOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
                FaceOrientation.Attachment0 = AICFeature.S.FaceAttachment
                FaceOrientation.RigidityEnabled = false
                --// Fast enough to track a mob circling at melee range; 25
                --// trailed visibly behind it. FaceGoblin switches to rigid
                --// for large corrections.
                FaceOrientation.Responsiveness = CONFIG.FACE_RESPONSIVENESS
                FaceOrientation.MaxTorque = math.huge
                FaceOrientation.MaxAngularVelocity = math.huge
                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                FaceOrientation.Parent = RootPart
                Runtime:SetFaceOrientation(FaceOrientation)
            end

            task.defer(function()
                if not Humanoid then
                    return
                end

                Humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
                Humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
                Humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
                Humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
            end)
        end

        function Feature.GetPlayerStatValue(Name, Default)
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Stat = PlayerStats and PlayerStats:FindFirstChild(Name)
        
            if not Stat then
                return Default
            end
        
            return tonumber(Stat.Value) or Default
        end
        function Feature.GetPlayerLevel()
            return Feature.GetPlayerStatValue("Level", 0)
        end
        
        --// Toggle Screen GUI
        function Feature.CreateToggleContainer()
        end
        function Feature.RegenStamina()
            task.spawn(function()
                local PlayerStats = Player:FindFirstChild("PlayerStats")
                if not PlayerStats then
                    repeat task.wait(0.5) until Player:FindFirstChild("PlayerStats")
                    PlayerStats = Player:FindFirstChild("PlayerStats")
                end
                local GameGui = PlayerGui:FindFirstChild("GameGui")
                if not GameGui then
                    repeat task.wait(0.5) until PlayerGui:FindFirstChild("GameGui")
                    GameGui = PlayerGui:FindFirstChild("GameGui")
                end
                local Stamina = GameGui:FindFirstChild("Stamina")
                local MaxStamina = PlayerStats:FindFirstChild("MaxStamina")
        
                --// Both values are required. Without MaxStamina there is no target
                --// value to restore, so the connection would error on every change.
                if not Stamina or not MaxStamina then
                    return
                end
        
                AICFeature.S.StaminaConnection = Stamina:GetPropertyChangedSignal("Value"):Connect(function()
                    if Stamina.Value < MaxStamina.Value then
                        Stamina.Value = MaxStamina.Value
                    end
                end)
            end)
        end

        function Feature:RenderUpdate(dt)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local PlaceConfig = Runtime:GetPlaceConfig()

            AICUI.updatePosition()

            --// Auto Mining holds WalkSpeed at 0 while it mines a node.
            local SpeedLocked = AICFeature.IsWalkSpeedLocked and AICFeature.IsWalkSpeedLocked()

            if Humanoid and not SpeedLocked then
                if AICFeature.GetPlayerLevel() >= CONFIG.HIGH_LEVEL_THRESHOLD then
                    if Humanoid.WalkSpeed < CONFIG.MAXIMUM_WALKSPEED then
                        Humanoid.WalkSpeed = CONFIG.MAXIMUM_WALKSPEED
                    end
                elseif Humanoid.WalkSpeed < CONFIG.MINIMUM_WALKSPEED then
                    Humanoid.WalkSpeed = CONFIG.MINIMUM_WALKSPEED
                end
            end
        end
        --// Draws the weapon when it is sheathed. True when the draw was just
        --// issued, so the caller should give it this frame.
        local function EnsureWeaponDrawn(now, InputBindableFunction, MainWeld)
            local Sheathed = not AICFeature.S.Equipped
                or (MainWeld.Part1 and MainWeld.Part1.Name == "UpperTorso")

            if not Sheathed or now - AICFeature.S.LAST_EQUIP_TIME < CONFIG.EQUIP_TOGGLE_COOLDOWN then
                return false
            end

            AICFeature.S.Equipped = true
            AICFeature.S.LAST_EQUIP_TIME = now

            InputBindableFunction:Invoke(
                "EquipButton",
                Enum.UserInputState.Begin
            )

            return true
        end

        --// For code outside the farm loop (Auto Mining's defence), which has
        --// no weld or input handle of its own.
        AICFeature.EnsureWeaponDrawn = function(now)
            local Character = Runtime:GetCharacter()
            local Sword = Character and Character:FindFirstChild("Sword")
            local MainWeld = Sword and Sword:FindFirstChild("MainWeld", true)
            local InputBindableFunction = Runtime:GetInputBindableFunction()

            if not MainWeld or not InputBindableFunction then
                return false
            end

            return EnsureWeaponDrawn(now, InputBindableFunction, MainWeld)
        end

        --// Auto Smithing, then Auto Mining, once the route is walked. True
        --// while one of them owns this frame's movement; each fights off
        --// anything close by itself, so the combat at the end of the frame
        --// is skipped then. Smithing never pulls the character off a node
        --// mid-mining; mining never interrupts a craft, as smithing keeps
        --// the frame for the whole of one.
        local function RunSideJobs(now)
            local MiningBusy = AICFeature.IsMiningCommitted and AICFeature.IsMiningCommitted()
            local Taken = (not MiningBusy and AICFeature.SmithingStep and AICFeature.SmithingStep(now))
                or (AICFeature.MiningStep and AICFeature.MiningStep(now))

            if not Taken then
                return false
            end

            AICCombat.S.ClosestTarget = nil
            AICFeature.CancelPatrol()
            return true
        end

        --// FARM STATE on the Status tab: what the loop did this frame, so a
        --// character standing still can be told apart (retreating, holding
        --// for Auto Block, waiting on a path...) without reading the code.
        local function SetFarmState(Text)
            local Label = UIRef.FarmStateLabel
            Text = "FARM STATE  " .. Text

            if Label and Label.Text ~= Text then
                Label.Text = Text
            end
        end

        --// "CHASE Goblin 12 // CHASE TO SPOT / STRAIGHT": the target, how far
        --// it is, the MoveToGoblin step and what ChaseMoveTo did in it.
        local CHASE_MOVE_STEPS = {
            ["CHASE TO SPOT"] = true,
            ["CHASE TO MOB"] = true,
            ["REPOSITION"] = true,
            ["SAFE ENEMY RANGE"] = true,
        }

        local function DescribeChase()
            local Target = AICCombat.S.ClosestTarget
            local _, _, RootPart = Runtime:GetCharacter()
            local TargetRoot = Target and Target:FindFirstChild("HumanoidRootPart")
            local Distance = RootPart and TargetRoot
                and math.floor(AICCombatUtils.GetHorizontalDistance(RootPart.Position, TargetRoot.Position) + 0.5)
                or "?"
            local Step = tostring(AICCombat.S.ChaseStep or "?")

            if CHASE_MOVE_STEPS[Step] and AICCombat.S.ChaseMoveStep then
                Step ..= " / " .. AICCombat.S.ChaseMoveStep
            end

            return string.format("CHASE  %s  %s  //  %s", Target and Target.Name or "?", tostring(Distance), Step)
        end

        --// Goes for the locked target. While Character.NoDamage is on us our
        --// hits do nothing, so it circles the target outside its reach
        --// instead of running in, until NoDamage is gone.
        local function ApproachTarget(Target)
            if AICCombat.HasNoDamage() then
                AICCombat.OrbitTarget(Target)
            else
                AICCombat.MoveToGoblin(Target)
            end
        end

        --// Gather Mobs, once the route is walked and the character is inside
        --// the farm zone. True while it pulls a pack together or uses the
        --// skill on it; it moves and fights by itself then, so the combat at
        --// the end of the frame is skipped. Once the skill is used, normal
        --// combat fights the pack.
        local function RunGather(now)
            if not AICFeature.GatherStep or not AICFeature.GatherStep(now) then
                return false
            end

            AICCombat.S.ClosestTarget = nil
            AICFeature.CancelPatrol()
            return true
        end

        --// Drinks the last used potion when it is off cooldown. The weapon
        --// is sheathed first, which costs a frame: true means this frame was
        --// spent sheathing and the caller should yield it. Shared by the
        --// retreat and by healing while walking the waypoint route.
        local function TryConsumePotion(now, PlayerStats, InputBindableFunction, MainWeld)
            local UseConsumable = Replicated:FindFirstChild("UseConsumable", true)
            local LastConsumed = PlayerStats and PlayerStats:FindFirstChild("LastConsumed")

            if not UseConsumable
                or not LastConsumed
                or LastConsumed.Value == ""
                or now - AICFeature.S.LAST_CONSUME_TIME < CONFIG.CONSUME_INTERVAL
            then
                return false
            end

            --// Sheathe only when a potion is actually about to be drunk. The old
            --// build sheathed on every retreat frame and drew again as soon as
            --// the retreat ended, which is where the constant draw/sheathe came
            --// from, and each toggle also threw away the frame it happened on.
            if InputBindableFunction
                and (AICFeature.S.Equipped or (MainWeld.Part1 and MainWeld.Part1.Name ~= "UpperTorso"))
                and now - AICFeature.S.LAST_EQUIP_TIME >= CONFIG.EQUIP_TOGGLE_COOLDOWN
            then
                AICFeature.S.Equipped = false
                AICFeature.S.LAST_EQUIP_TIME = now

                InputBindableFunction:Invoke(
                    "EquipButton",
                    Enum.UserInputState.Begin
                )

                return true
            end

            if not AICFeature.S.Equipped then
                AICFeature.S.LAST_CONSUME_TIME = now
                UseConsumable:InvokeServer(LastConsumed.Value)
            end

            return false
        end

        --// Drinks from anywhere, for code that never reaches the retreat
        --// above: the Boss Route fights its stops before Auto Farm's health
        --// decision runs, so a stop was fought with no heal at all. True when
        --// the frame was spent sheathing, so the caller gives it up.
        AICFeature.TryHeal = function(now)
            local Character = Runtime:GetCharacter()
            local Sword = Character and Character:FindFirstChild("Sword")
            local MainWeld = Sword and Sword:FindFirstChild("MainWeld", true)
            local InputBindableFunction = Runtime:GetInputBindableFunction()

            if not Character or not MainWeld or not InputBindableFunction then
                return false
            end

            return TryConsumePotion(
                now,
                Player:FindFirstChild("PlayerStats"),
                InputBindableFunction,
                MainWeld
            )
        end

        function Feature:Update(dt)
            -- Keep walkspeed / position UI in sync every frame (was RenderUpdate)
            Feature:RenderUpdate(dt)

            local now = os.clock()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local InputBindableFunction = Runtime:GetInputBindableFunction()
            local FaceOrientation = Runtime:GetFaceOrientation()
            local PlaceConfig = Runtime:GetPlaceConfig()

            --// Auto Block is controlled by the active profile/default config.
            --// Do not gate it by the static PLACE_CONFIG table because profiles can
            --// enable Auto Block even when the current PlaceId has no built-in config.
            --if IsValidPlace(game.PlaceId) then
            --    Enabled = false
            --    updateButton()
            --    return
            --end

            if not Humanoid or not RootPart then
                --// A Boss Route reset waiting for its character still has to
                --// see the respawn, and this is where the frame returns while
                --// there is no character at all.
                if AICFeature.BossRecoverStep then
                    AICFeature.BossRecoverStep(now)
                end

                AICFeature.updateCharacter()
                table.clear(AICCombat.S.ValidMobs)
                AICCombat.S.ClosestTarget = nil
                return
            end

            if Humanoid.Health <= 0 then
                if AICFeature.BossRecoverStep then
                    AICFeature.BossRecoverStep(now)
                end

                AICDebug.ResetDebugWaypoints()
                CONFIG.CURRENT_WAYPOINT_TARGET = 1
                AICFeature.S.WaypointWaitUntil = nil
                if AICFeature.ResetWaypointLoop then AICFeature.ResetWaypointLoop() end
                table.clear(AICCombat.S.ValidMobs)
                AICCombat.S.ClosestTarget = nil
                return
            end

            if now - AICUI.S.LAST_TEXT_UPDATE_TIME >= CONFIG.TEXT_UPDATE_INTERVAL then
                AICUI.S.LAST_TEXT_UPDATE_TIME = now
                AICUI.updatePlayTime()
                AICUI.updateEventCurrency()

                if UIRef.WayPointLabel then
                    UIRef.WayPointLabel.Text = "WAYPOINTS:  ".. CONFIG.CURRENT_WAYPOINT_TARGET .. "/" .. (PlaceConfig and #PlaceConfig.WAYPOINTS or 0)
                end
                if UIRef.WalkSpeedLabel then
                    UIRef.WalkSpeedLabel.Text = "WALKSPEED:  " .. tostring(math.floor(Humanoid.WalkSpeed + 0.5))
                end
                if UIRef.DeathLabel then
                    UIRef.DeathLabel.Text = "DEATH:  " .. tostring(AICFeature.S.DEATH_COUNT)
                end
            end

            if FeatureState.DebugVisualizer.Enabled then
                AICDebug.UpdateDebugWaypointColors()
            end

            --// Feeds the jump logic. Only counts while the character is actually
            --// trying to move, so standing still on purpose is not read as stuck.
            AICCombatUtils.UpdateStuckTracker(now, Humanoid.MoveDirection.Magnitude > 0.1)

            --// Realtime Mob Validation
            if now - AICCombat.S.LAST_MOB_VALIDATION_TIME >= CONFIG.MOB_VALIDATION_INTERVAL then
                AICCombat.S.LAST_MOB_VALIDATION_TIME = now
                AICCombat.UpdateValidMobs()
            end

            --// Party System is resetting or waiting to Tp to its Leader.
            if AICFeature.IsPartyHolding and AICFeature.IsPartyHolding() then
                SetFarmState("PARTY HOLD")

                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return
            end

            if not AICFeature.S.Enabled then
                SetFarmState("AUTO FARM OFF")

                --// The Boss Route runs on its own, with Auto Farm on or off:
                --// it walks its stops, fights, and resets on its own timers.
                if AICFeature.BossStep and AICFeature.BossStep(now) then
                    SetFarmState("BOSS ROUTE")
                    return
                end

                --// Auto Smithing also runs with Auto Farm off: it walks to
                --// the table and crafts, and nothing else moves.
                if AICFeature.SmithingStep and AICFeature.SmithingStep(now) then
                    return
                end

                if FaceOrientation then
                    FaceOrientation.Enabled = false
                end
                Humanoid.AutoRotate = true
                Humanoid:Move(Vector3.zero)
                return
            end

            if not InputBindableFunction then
                InputBindableFunction = PlayerGui:FindFirstChild("InputBindableFunction", true) :: BindableFunction
                Runtime:SetInputBindableFunction(InputBindableFunction)
                return
            end

            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Sword = Character:FindFirstChild("Sword")

            if not Sword or not Sword:FindFirstChild("MainWeld", true) or not PlayerStats then
                return
            end

            local MainWeld = Sword:FindFirstChild("MainWeld", true)

            if AICFeature.HandleDeadzoneEscape() then
                return
            end

            --// Emergency Retreat
            local RetreatHealthPercent = math.clamp(tonumber(CONFIG.RETREAT_HEALTH_PERCENT) or 40, 0, 80)
            local AutoHealHealthPercent = math.clamp(tonumber(CONFIG.AUTO_HEAL_HEALTH_PERCENT) or 65, 30, 80)
            local RetreatHealthRatio = RetreatHealthPercent / 100
            local AutoHealHealthRatio = AutoHealHealthPercent / 100
            local RecoverHealthPercent = math.min(95, math.max(70, RetreatHealthPercent + 10))
            --// 0 = never, not even on the frame health reaches 0.
            local EmergencyHealth = RetreatHealthRatio > 0 and Humanoid.Health <= Humanoid.MaxHealth * RetreatHealthRatio
            local ShouldHeal      = Humanoid.Health <= Humanoid.MaxHealth * AutoHealHealthRatio

            --// Watches every nearby mob rather than only the current target, and
            --// latches for a short hold so a flickering sound or emitter cannot drop
            --// the dodge partway through.
            local EnemyUsingSkill = AICCombat.UpdateSkillThreat(now)

            --// Still walking the waypoint route. There the route itself is the
            --// way out: low health keeps walking and drinks on the move, and a
            --// skill is dodged and then the route resumes.
            local RouteActive = not FeatureState.AutoFind.Enabled
                and PlaceConfig ~= nil
                and type(PlaceConfig.WAYPOINTS) == "table"
                and (tonumber(CONFIG.CURRENT_WAYPOINT_TARGET) or 1) <= #PlaceConfig.WAYPOINTS

            --// Why we are retreating. A skill dodge ends with the skill; only a
            --// health retreat waits for health to come back. Both used to wait
            --// for health, so one boss skill that dropped us under the recover
            --// line kept the character fleeing long after the skill was over.
            --// The reason only counts while retreating, so one left behind by
            --// a respawn or another path clearing RETREATING cannot stick.
            if EnemyUsingSkill then
                if not (AICCombat.S.RETREATING and AICCombat.S.RetreatReason == "Health") then
                    AICCombat.S.RetreatReason = "Skill"
                end

                AICCombat.S.RETREATING = true
            end

            --// Execute: a target this close to death is finished instead of retreated
            --// from, at any health of our own. An enemy skill still overrides it,
            --// because eating a skill to land one more hit is not a good trade.
            local ExecuteCharge = false
            local ExecutePercent = math.clamp(tonumber(CONFIG.EXECUTE_CHARGE_HP_PERCENT) or 0, 0, 90)

            if ExecutePercent > 0 and not EnemyUsingSkill and AICCombat.S.ClosestTarget then
                local TargetHumanoid = AICCombat.S.ClosestTarget:FindFirstChildOfClass("Humanoid")

                if TargetHumanoid
                    and TargetHumanoid.MaxHealth > 0
                    and TargetHumanoid.Health > 0
                then
                    ExecuteCharge =
                        (TargetHumanoid.Health / TargetHumanoid.MaxHealth) * 100 <= ExecutePercent
                end
            end

            --// Retreat is a health decision only. The old build also entered retreat
            --// whenever WalkSpeed had not been raised yet, but RenderStepped restores
            --// WalkSpeed every frame, so that clause only produced random retreats.
            local Recovered = Humanoid.Health >= Humanoid.MaxHealth * (RecoverHealthPercent / 100)

            if ExecuteCharge then
                AICCombat.S.RETREATING = false
                AICCombat.S.RetreatReason = nil
            elseif EmergencyHealth and not RouteActive then
                AICCombat.S.RETREATING = true
                AICCombat.S.RetreatReason = "Health"
            elseif AICCombat.S.RETREATING
                and not EnemyUsingSkill
                and (AICCombat.S.RetreatReason ~= "Health" or RouteActive or Recovered)
            then
                AICCombat.S.RETREATING = false
                AICCombat.S.RetreatReason = nil

                --// Re-acquire a valid target immediately after healing so the
                --// combat loop does not wait for another target cycle.
                if not AICCombat.IsTargetLockValid(AICCombat.S.ClosestTarget) then
                    AICCombat.S.ClosestTarget = AICCombat.GetClosestGoblin()
                end
            end

            if AICCombat.S.RETREATING then
                SetFarmState("RETREAT (" .. tostring(AICCombat.S.RetreatReason or "?") .. ")")

                --// On the route the dodge may land outside the farm zones,
                --// which is where the route runs.
                AICCombatUtils.S.DodgeOffRoute = RouteActive
                local RetreatMoved = AICCombat.RetreatFromGoblins(EnemyUsingSkill)
                AICCombatUtils.S.DodgeOffRoute = false

                --// With no mob close enough to flee from, the retreat stands still
                --// to heal wherever it happens to be. Outside the farm zone that
                --// meant waiting there until health came back, which can be a very
                --// long time without a potion. Heal back inside the zone instead,
                --// once the waypoint route (if any) has been walked.
                local RouteDone = not PlaceConfig
                    or type(PlaceConfig.WAYPOINTS) ~= "table"
                    or #PlaceConfig.WAYPOINTS == 0
                    or (tonumber(CONFIG.CURRENT_WAYPOINT_TARGET) or 1) > #PlaceConfig.WAYPOINTS

                if not RetreatMoved
                    and not EnemyUsingSkill
                    and RouteDone
                    and FeatureState.ReturnToFarmZone.Enabled
                    and not FeatureState.IgnoreFarmZone.Enabled
                    and (not AICCombatUtils.IsInsideFarmArea(RootPart.Position)
                        or AICCombatUtils.IsInsideFarmDeadzone(RootPart.Position))
                then
                    SetFarmState("RETURN TO FARM ZONE")
                    AICFeature.MoveBackToFarmZone()
                end

                --// Something inside attack range is hit while backing away. In a
                --// duel the weapon stays drawn and no potion is drunk at all.
                local InDuel = AICCombat.IsInDuel()
                local FightBackThreat = AICCombat.GetFightBackThreat()

                if (InDuel or (FightBackThreat and not EnemyUsingSkill))
                    and EnsureWeaponDrawn(now, InputBindableFunction, MainWeld)
                then
                    return
                end

                if FightBackThreat and not EnemyUsingSkill then
                    AICCombat.FaceWhileRetreating(FightBackThreat)
                    AICCombat.RetreatAttack(FightBackThreat, now)
                end

                --// Never stop to drink mid-dodge. Getting out of the skill first
                --// is worth more than the heal, and sheathing costs an animation.
                --// A mob in reach used to block the drink as well, which is
                --// exactly when the health was being taken: only the softer
                --// heal waits for the fight now, an emergency drink does not.
                local WantsConsume = (EmergencyHealth or (ShouldHeal and not FightBackThreat))
                    and not EnemyUsingSkill
                    and not InDuel

                if WantsConsume then
                    TryConsumePotion(now, PlayerStats, InputBindableFunction, MainWeld)
                end

                return
            end

            --// Low on the route: no retreat, keep walking and drink on the move.
            if RouteActive
                and (EmergencyHealth or ShouldHeal)
                and TryConsumePotion(now, PlayerStats, InputBindableFunction, MainWeld)
            then
                return
            end

            --// Enemy skill retreat speed is temporary. Once retreating ends,
            --// return to the normal movement cap on the next heartbeat.
            if not EnemyUsingSkill and Humanoid.WalkSpeed > CONFIG.MAXIMUM_WALKSPEED then
                Humanoid.WalkSpeed = CONFIG.MAXIMUM_WALKSPEED
            end

            --// Player Check
            --// Whitelisted players are never blocked, and a server holding only
            --// them is left alone unless Whitelist Skips Safety is off and one of
            --// them is already blocked. Anyone else is blocked individually and then the
            --// server is abandoned; the whole lobby is no longer blocked one by one.
            --// With a party Leader set, Party System deals with intruders instead.
            local PartyHandles = AICFeature.PartyHandlesIntruders and AICFeature.PartyHandlesIntruders()

            if AICFeature.S.BlockEnabled and not PartyHandles then
                local Intruder = nil
                --// A whitelisted player we have blocked. Never prompted, but
                --// with Whitelist Skips Safety off they make us hop all the same.
                local BlockedWhitelisted = nil

                --// Within the Block Delay an intruder is tolerated and the
                --// farm carries on; block and hop only once it has run out.
                --// Every intruder is asked about, so each one's delay starts
                --// when they are first seen, not when the one before is dealt with.
                for _, plr in Players:GetPlayers() do
                    if plr ~= Player then
                        if not AICFeature.IsWhitelisted(plr.UserId) then
                            if AICFeature.IsBlockDelayOver(plr) and not Intruder then
                                Intruder = plr
                            end
                        elseif not BlockedWhitelisted
                            and AICFeature.IsSafetyExempt
                            and not AICFeature.IsSafetyExempt(plr.UserId)
                            and AICFeature.IsBlockDelayOver(plr)
                            and AICFeature.isBlocked(plr.UserId)
                        then
                            BlockedWhitelisted = plr
                        end
                    end
                end

                if not Intruder and BlockedWhitelisted then
                    SetFarmState("AUTO BLOCK  HOP FROM @" .. BlockedWhitelisted.Name)
                    AICFeature.TeleportToPlace()
                    return
                end

                if Intruder then
                    --// Leave Instead Of Block: the delay has run out, so
                    --// drop the server without touching the block list.
                    if FeatureState.AutoBlockLeaveOnly.Enabled then
                        SetFarmState("AUTO BLOCK  HOP FROM @" .. Intruder.Name)
                        AICFeature.TeleportToPlace()
                        return
                    end

                    SetFarmState("AUTO BLOCK  @" .. Intruder.Name)

                    if not AICFeature.isBlocked(Intruder.UserId) then
                        AICFeature.promptBlockPlayer(Intruder)
                        return
                    end

                    --// Hop only once the block has gone through, or the hop
                    --// can cut the block request short and land us back
                    --// with them.
                    if not AICFeature.IsBlockSettled(Intruder) then
                        SetFarmState("AUTO BLOCK  CHECKING @" .. Intruder.Name)
                        return
                    end

                    AICFeature.S.BlockCache[Intruder.UserId] = nil
                    AICFeature.TeleportToPlace()
                    return
                end
            end

            --// Play Time
            if workspace.DistributedGameTime >= CONFIG.MAX_SERVER_AGE then
                SetFarmState("SERVER TOO OLD, HOPPING")
                AICFeature.TeleportToPlace()
                return
            end

            --// Boss Route: its own stops and timers, above the waypoint route
            --// and the combat below. Every safety check above still ran this
            --// frame, so a Boss Route run keeps Auto Block, the retreat and the
            --// server-age hop.
            if AICFeature.BossStep and AICFeature.BossStep(now) then
                SetFarmState("BOSS ROUTE")
                return
            end

            --// Movement
            --// Waypoint route always has priority over combat/patrol.
            --// Combat target acquisition is completely disabled until the route is finished.
            local HasWaypoints = PlaceConfig and type(PlaceConfig.WAYPOINTS) == "table" and #PlaceConfig.WAYPOINTS > 0
            local WaypointIndex = tonumber(CONFIG.CURRENT_WAYPOINT_TARGET) or 1
            local target = nil
            local HandedOff = false

            --// Holding at a waypoint that has a wait time. Nothing else runs on
            --// the route meanwhile, the same as walking it.
            if AICFeature.S.WaypointWaitUntil then
                if HasWaypoints
                    and not FeatureState.AutoFind.Enabled
                    and now < AICFeature.S.WaypointWaitUntil
                then
                    SetFarmState("WAYPOINT WAIT")

                    if FaceOrientation then
                        FaceOrientation.Enabled = false
                    end
                    Humanoid.AutoRotate = true
                    Humanoid:Move(Vector3.zero)
                    return
                end

                AICFeature.S.WaypointWaitUntil = nil
            end

            if HasWaypoints then
                if WaypointIndex < 1 then
                    WaypointIndex = 1
                    CONFIG.CURRENT_WAYPOINT_TARGET = 1
                end

                local WaypointCount = #PlaceConfig.WAYPOINTS
                local AtLastWaypoint = WaypointIndex > WaypointCount
                target = not AtLastWaypoint and PlaceConfig.WAYPOINTS[WaypointIndex] or nil

                --// Route mode: never let combat target state leak into waypoint movement.
                if not FeatureState.AutoFind.Enabled and target then
                    SetFarmState("ROUTE  #" .. tostring(WaypointIndex))
                    AICCombat.S.ClosestTarget = nil
                    AICCombat.S.TargetPath = nil
                    AICCombat.S.TargetPathMob = nil
                    AICCombat.S.TargetApproachMob = nil
                    AICCombat.S.TargetApproachPosition = nil
                    AICCombat.S.RETREATING = false

                    local WaypointOffset = target - RootPart.Position
                    local WaypointHorizontalDistance = Vector3.new(
                        WaypointOffset.X,
                        0,
                        WaypointOffset.Z
                    ).Magnitude
                    local WaypointVerticalDistance = math.abs(WaypointOffset.Y)
                    local ReachDistance = tonumber(PlaceConfig.REACH_DISTANCE) or 5
                    --// A Jump waypoint sits at a gap's edge: reached only
                    --// right on it, and only on the ground, so the jump
                    --// below always goes off.
                    local IsJumpWaypoint, JumpReached = AICConfig.CheckJumpWaypoint(
                        PlaceConfig, WaypointIndex, WaypointHorizontalDistance
                    )
                    local Reached

                    if IsJumpWaypoint then
                        Reached = JumpReached
                            and Humanoid.FloorMaterial ~= Enum.Material.Air
                            and WaypointVerticalDistance <= math.max(ReachDistance, CONFIG.JUMP_HEIGHT + 2)
                    else
                        Reached = WaypointHorizontalDistance <= ReachDistance
                            and WaypointVerticalDistance <= math.max(ReachDistance, CONFIG.JUMP_HEIGHT + 2)
                    end

                    if Reached then
                        CONFIG.CURRENT_WAYPOINT_TARGET = WaypointIndex + 1

                        if IsJumpWaypoint then
                            AICCombatUtils.DoJump()
                            --// Keep running forward; the next waypoint's
                            --// MoveTo below takes over when there is one.
                            Humanoid:Move(AICCombatUtils.GetFlatLook(RootPart))
                        end

                        --// Waypoint Loop takes over from the first paired
                        --// waypoint, so the route ends there.
                        local LoopEntry = AICFeature.GetWaypointLoopEntry and AICFeature.GetWaypointLoopEntry()

                        if LoopEntry and WaypointIndex >= LoopEntry then
                            CONFIG.CURRENT_WAYPOINT_TARGET = WaypointCount + 1
                            AICFeature.EnterWaypointLoop(WaypointIndex)
                        end

                        AICCombatUtils.S.LAST_STUCK_POSITION = nil
                        AICCombatUtils.S.LAST_STUCK_TIME = now
                        AICDebug.UpdateDebugWaypointColors()

                        --// Waypoint wait: hold here before heading on. The
                        --// check at the top of the route stands still until then.
                        local Wait = tonumber(PlaceConfig.WAYPOINT_WAITS and PlaceConfig.WAYPOINT_WAITS[WaypointIndex]) or 0

                        if Wait > 0 then
                            AICFeature.S.WaypointWaitUntil = now + Wait
                            Humanoid:Move(Vector3.zero)
                            return
                        end

                        WaypointIndex = CONFIG.CURRENT_WAYPOINT_TARGET
                        target = PlaceConfig.WAYPOINTS[WaypointIndex]
                    end

                    if target then
                        if FaceOrientation then
                            FaceOrientation.Enabled = false
                        end
                        Humanoid.AutoRotate = true
                        Humanoid:MoveTo(target)
                        AICCombatUtils.DoJumpIfRouteHole()
                    end

                    if now - AICCombatUtils.S.LAST_STUCK_TIME >= CONFIG.STUCK_CHECK_INTERVAL then
                        AICCombatUtils.S.LAST_STUCK_TIME = now
                        if AICCombatUtils.S.LAST_STUCK_POSITION
                            and (RootPart.Position - AICCombatUtils.S.LAST_STUCK_POSITION).Magnitude < 1
                        then
                            AICCombatUtils.DoJump()
                        else
                            AICCombatUtils.S.LAST_STUCK_POSITION = RootPart.Position
                        end
                    end

                else
                    --// Final waypoint reached: the waypoint loop, when on, decides
                    --// which paired zone to fight in or walks the route to find one.
                    local LoopResult = AICFeature.WaypointLoopStep and AICFeature.WaypointLoopStep(now)
                    local OutsideFarmZone = not AICCombatUtils.IsInsideFarmArea(RootPart.Position)
                    local InFarmDeadzone = AICCombatUtils.IsInsideFarmDeadzone(RootPart.Position)

                    if LoopResult == "move" then
                        SetFarmState("WAYPOINT LOOP")
                        AICFeature.CancelPatrol()
                    elseif RunSideJobs(now) then
                        SetFarmState("MINING / SMITHING")
                        HandedOff = true
                    elseif FeatureState.ReturnToFarmZone.Enabled
                        and not FeatureState.IgnoreFarmZone.Enabled
                        and (OutsideFarmZone or InFarmDeadzone)
                    then
                        AICCombat.S.ClosestTarget = nil
                        AICFeature.CancelPatrol()
                        SetFarmState("RETURN TO FARM ZONE")
                        AICFeature.MoveBackToFarmZone()
                    elseif RunGather(now) then
                        SetFarmState("GATHER")
                        HandedOff = true
                    else
                        if not AICCombat.S.ClosestTarget or not AICCombat.IsTargetLockValid(AICCombat.S.ClosestTarget) then
                            AICCombat.S.ClosestTarget = AICCombat.AcquireCombatTarget(now)
                        else
                            local LockedTarget = AICCombat.AcquireCombatTarget(now)
                            if LockedTarget then
                                AICCombat.S.ClosestTarget = LockedTarget
                            end
                        end

                        if AICCombat.S.ClosestTarget then
                            --// Combat outranks patrolling, so drop whatever the
                            --// patrol was doing rather than leaving a pause or a leg
                            --// chain to resume once the fight is over.
                            AICFeature.CancelPatrol()
                            ApproachTarget(AICCombat.S.ClosestTarget)
                            SetFarmState(DescribeChase())
                        elseif FeatureState.AutoPatrol.Enabled then
                            SetFarmState("PATROL")
                            AICFeature.MoveToPatrol()
                        else
                            SetFarmState("IDLE (NO TARGET)")
                            PatrolState.PatrolPosition = nil
                            AICFeature.S.FarmReturnPosition = nil
                            if FaceOrientation then
                                FaceOrientation.Enabled = false
                            end
                            Humanoid.AutoRotate = true
                            Humanoid:Move(Vector3.zero)
                        end
                    end
                end

            else
                --// No configured waypoints: preserve the original combat/patrol flow.
                local OutsideFarmZone = not AICCombatUtils.IsInsideFarmArea(RootPart.Position)
                local InFarmDeadzone = AICCombatUtils.IsInsideFarmDeadzone(RootPart.Position)

                if RunSideJobs(now) then
                    SetFarmState("MINING / SMITHING")
                    HandedOff = true
                elseif FeatureState.ReturnToFarmZone.Enabled
                    and not FeatureState.IgnoreFarmZone.Enabled
                    and (OutsideFarmZone or InFarmDeadzone)
                then
                    AICCombat.S.ClosestTarget = nil
                    AICFeature.CancelPatrol()
                    SetFarmState("RETURN TO FARM ZONE")
                    AICFeature.MoveBackToFarmZone()
                elseif RunGather(now) then
                    SetFarmState("GATHER")
                    HandedOff = true
                else
                    if not AICCombat.S.ClosestTarget or not AICCombat.IsTargetLockValid(AICCombat.S.ClosestTarget) then
                        AICCombat.S.ClosestTarget = AICCombat.AcquireCombatTarget(now)
                    else
                        local LockedTarget = AICCombat.AcquireCombatTarget(now)
                        if LockedTarget then
                            AICCombat.S.ClosestTarget = LockedTarget
                        end
                    end

                    if AICCombat.S.ClosestTarget then
                        --// Combat outranks patrolling, so drop whatever the patrol
                        --// was doing rather than leaving a pause or a leg chain to
                        --// resume once the fight is over.
                        AICFeature.CancelPatrol()
                        ApproachTarget(AICCombat.S.ClosestTarget)
                        SetFarmState(DescribeChase())
                    elseif FeatureState.AutoPatrol.Enabled then
                        SetFarmState("PATROL")
                        AICFeature.MoveToPatrol()
                    else
                        SetFarmState("IDLE (NO TARGET)")
                        PatrolState.PatrolPosition = nil
                        AICFeature.S.FarmReturnPosition = nil
                        if FaceOrientation then
                            FaceOrientation.Enabled = false
                        end
                        Humanoid.AutoRotate = true
                        Humanoid:Move(Vector3.zero)
                    end
                end
            end

            --// Jump. A waypoint sitting higher is not a reason on its own: a ramp
            --// climbs fine on foot, and hopping up one only costs speed. Probe for
            --// something actually in the way instead. This is the waypoint route
            --// walking, so Jump While Fighting leaves it alone.
            if PlaceConfig and not FeatureState.AutoFind.Enabled and target then
                AICCombatUtils.DoJumpIfObstacle(target)
            end

            --// Swim Recovery. A fight that moved into the water (a player who
            --// jumped in, or us knocked in mid-duel) carries on: SwimChase
            --// already steered this frame, and returning here skipped the
            --// attack below, so the character only ever bobbed at the surface.
            local FightingInWater = AICCombat.S.ClosestTarget
                and AICCombat.IsWaterCombat(AICCombat.S.ClosestTarget)

            if Humanoid:GetState() == Enum.HumanoidStateType.Swimming and not FightingInWater then
                Humanoid.Jump = true
                AICCombatUtils.DoJump()
                return
            end

            if Humanoid.Sit == true then
                Humanoid.Sit = false
                AICCombatUtils.DoJump()
                return
            end

            --// Smithing or mining already moved, and fought anything close,
            --// this frame. Falling through would press Interact there.
            if HandedOff then
                return
            end

            --// Combat
            --// Never enter combat while a configured waypoint route is still active.
            --// Auto Find skips the route entirely, so for it the route never
            --// "finishes"; without this it acquired a target and then only ever
            --// pressed Interact instead of attacking.
            local WaypointRouteFinished = FeatureState.AutoFind.Enabled
                or not HasWaypoints
                or (tonumber(CONFIG.CURRENT_WAYPOINT_TARGET) or 1) > #PlaceConfig.WAYPOINTS

            --// A duel is always fought, Ignore Farm Zone or not: the opponent
            --// may be anywhere, and falling through to Interact never attacks.
            local CanFightTarget = AICCombat.S.ClosestTarget
                and (not FeatureState.IgnoreFarmZone.Enabled or AICCombat.IsInDuel())

            if WaypointRouteFinished
                and (FeatureState.AutoFind.Enabled or not HasWaypoints or CanFightTarget) then
                if AICCombat.S.ClosestTarget then
                    if not AICCombat.IsTargetLockValid(AICCombat.S.ClosestTarget) then
                        AICCombat.S.ClosestTarget = nil
                        return
                    end

                    --// Locked but not in engage range yet. The approach above has
                    --// already issued this frame's MoveTo; stopping here with
                    --// Move(zero) cancelled it, so a target more than
                    --// COMBAT_ENGAGE_MAX_DISTANCE away was never walked to and the
                    --// character just stood still.
                    if not AICCombat.IsCombatTargetValid(AICCombat.S.ClosestTarget) then
                        return
                    end

                    if EnsureWeaponDrawn(now, InputBindableFunction, MainWeld) then
                        return
                    end

                    --// Circling (ApproachTarget): no attacks until NoDamage goes.
                    if AICCombat.HasNoDamage() then
                        return
                    end

                    local MobHumanoid = AICCombat.S.ClosestTarget:FindFirstChildOfClass("Humanoid")
                    local MobRoot     = AICCombat.S.ClosestTarget:FindFirstChild("HumanoidRootPart")

                    if MobHumanoid and MobRoot and MobHumanoid.Health > 0 then
                        AICCombat.PerformCombatActions(AICCombat.S.ClosestTarget, now)
                    else
                        AICCombat.S.ValidMobs[AICCombat.S.ClosestTarget] = nil
                        AICCombat.S.ClosestTarget = nil
                    end
                end
            else
                --// Also quiet for a moment after a script teleport: landing on
                --// a prompt and pressing it again re-fires the door (see
                --// Runtime:MuteInteract).
                if not Runtime:IsInteractMuted()
                    and now - AICFeature.S.LAST_INTERACTION_TIME >= CONFIG.INTERACTION_INTERVAL
                then
                    AICFeature.S.LAST_INTERACTION_TIME = now

                    InputBindableFunction:Invoke(
                        "InteractButton",
                        Enum.UserInputState.Begin
                    )
                end
            end
        end

        AICFeature.updateCharacter = function(...) return Feature.updateCharacter(...) end
        AICFeature.GetPlayerStatValue = function(...) return Feature.GetPlayerStatValue(...) end
        AICFeature.GetPlayerLevel = function(...) return Feature.GetPlayerLevel(...) end
        AICFeature.CreateToggleContainer = function(...) return Feature.CreateToggleContainer(...) end
        AICFeature.RegenStamina = function(...) return Feature.RegenStamina(...) end

        function Feature:CreateUI()
            if UIRef.FeatureSection and UIRef.FeatureSection.AddToggle then
                self.Button = AICUI.CreateFeature("Auto Farm", AICFeature.S.Enabled, function(Value)
                    AICFeature.S.Enabled = Value
                    FeatureState.AutoFarm.Enabled = Value

                    --// Only a real click on the toggle comes through here
                    --// (a profile load and FollowerGuard set the flag
                    --// directly), so this is where FollowerGuard's hold on
                    --// Auto Farm is lifted.
                    if AICFeature.NotifyManualAutoFarmToggle then
                        AICFeature.NotifyManualAutoFarmToggle(Value)
                    end

                    AICProfile.SaveActiveProfile()
                end)
                FeatureState.AutoFarm.Button = self.Button
            end
        end

        Feature:CreateUI()

        --// Called by Init after every feature toggle exists, so the sliders sit
        --// below Reset Stats as they do in AFV2.
        function Feature:BuildLateUI()
            if not UIRef.FeatureSection then
                return
            end

            --// Ranges and defaults come from SaveConfig.Settings.
            UIRef.ExecuteChargeSlider = AICUI.AddSettingSlider(
                UIRef.FeatureSection, "Execute Charge at HP%", "EXECUTE_CHARGE_HP_PERCENT", true
            )
            UIRef.RetreatHealthSlider = AICUI.AddSettingSlider(
                UIRef.FeatureSection, "Retreat At HP%", "RETREAT_HEALTH_PERCENT", true
            )
            UIRef.AutoHealHealthSlider = AICUI.AddSettingSlider(
                UIRef.FeatureSection, "Auto Heal at HP%", "AUTO_HEAL_HEALTH_PERCENT", true
            )
        end

        if UIRef.StatusSection then
            UIRef.FarmStateLabel = UIRef.StatusSection:AddLabel("FARM STATE  --")
            UIRef.PlaceIDLabel = UIRef.StatusSection:AddLabel("PLACE ID       " .. tostring(game.PlaceId))
            UIRef.WalkSpeedLabel = UIRef.StatusSection:AddLabel("WALKSPEED      0")
            UIRef.WayPointLabel = UIRef.StatusSection:AddLabel("WAYPOINTS:  0/" .. ((Runtime:GetPlaceConfig() and #Runtime:GetPlaceConfig().WAYPOINTS) or 0))
            --// Named after the currency the game is handing out this event.
            UIRef.EventCurrencyLabel = UIRef.StatusSection:AddLabel(AICUI.FormatEventCurrency(0))
            UIRef.ServerAgeLabel = UIRef.StatusSection:AddLabel("PLAY TIME      00:00:00")
            UIRef.PositionLabel = UIRef.StatusSection:AddLabel("POSITION       --")
            UIRef.DeathLabel = UIRef.StatusSection:AddLabel("DEATH          0")
            UIRef.ExpLabel = UIRef.StatusSection:AddLabel("EXP            0/0")
        end
        --// The stamina value outlives this run.
        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(AICFeature.S.StaminaConnection)
            AICFeature.S.StaminaConnection = nil
        end)

        --// The facing constraint sits in the character, which outlives this
        --// run: left enabled, it would hold the character turned towards the
        --// last target, and the next run makes its own.
        Context.Lifetime.OnEnd(function()
            local FaceOrientation = Runtime:GetFaceOrientation()

            if FaceOrientation then
                FaceOrientation:Destroy()
                Runtime:SetFaceOrientation(nil)
            end

            if AICFeature.S.FaceAttachment then
                AICFeature.S.FaceAttachment:Destroy()
                AICFeature.S.FaceAttachment = nil
            end

            local _, Humanoid = Runtime:GetCharacter()

            if Humanoid and Humanoid.Parent then
                Humanoid.AutoRotate = true
            end
        end)

        return Feature
    end,
}
