return {
    Name = "Combat",
    Dependencies = {"Runtime", "CombatUtils", "Targeting", "Navigation"},
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

        local Module = Context.AICCombat
        function AICCombat.FaceGoblin(Goblin)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()
            if not RootPart or not Goblin then
                return
            end
        
            local MobRoot = Goblin:FindFirstChild("HumanoidRootPart")
        
            if not MobRoot then
                return
            end
        
            local RootPosition = RootPart.Position

            local TrueDirection = Vector3.new(
                MobRoot.Position.X - RootPosition.X,
                0,
                MobRoot.Position.Z - RootPosition.Z
            )
            local Distance = TrueDirection.Magnitude

            if Distance <= 0.01 then
                return
            end

            if not FaceOrientation then
                return
            end

            TrueDirection = TrueDirection.Unit

            --// Lead the target by its own velocity, so a mob circling us is
            --// faced where it is going rather than where it was. The lead is
            --// bounded three ways, because an unbounded one aimed players
            --// (running ~35 studs/s) past us or 40-55 degrees off them:
            --//   - none at close range, where fast turning already keeps up
            --//   - speed capped, so a dash or knockback cannot fling the aim
            --//   - at most a share of the distance, so the aim stays within
            --//     ~20 degrees of the target and never triggers a snap itself
            local Direction = TrueDirection

            if Distance > (tonumber(CONFIG.FACE_LEAD_MIN_DISTANCE) or 6) then
                local Velocity = MobRoot.AssemblyLinearVelocity
                local FlatVelocity = Vector3.new(Velocity.X, 0, Velocity.Z)
                local MaxSpeed = tonumber(CONFIG.FACE_LEAD_MAX_SPEED) or 20

                if FlatVelocity.Magnitude > MaxSpeed then
                    FlatVelocity = FlatVelocity.Unit * MaxSpeed
                end

                local Lead = FlatVelocity * (tonumber(CONFIG.FACE_LEAD_TIME) or 0)
                local MaxLead = Distance * (tonumber(CONFIG.FACE_LEAD_MAX_RATIO) or 0.35)

                if Lead.Magnitude > MaxLead then
                    Lead = Lead.Unit * MaxLead
                end

                local Aim = TrueDirection * Distance + Lead

                if Aim.Magnitude > 0.01 then
                    Direction = Aim.Unit
                end
            end

            --// AutoRotate turns toward the walk direction and fights the
            --// alignment, which is what let a mob slip behind us.
            if Humanoid then
                Humanoid.AutoRotate = false
            end

            local Look = RootPart.CFrame.LookVector
            local FlatLook = Vector3.new(Look.X, 0, Look.Z)
            --// Measured against where the target actually is, not the led
            --// aim, so a shifting lead cannot toggle the snap every frame.
            local Error = FlatLook.Magnitude > 0.01
                and math.deg(math.acos(math.clamp(FlatLook.Unit:Dot(TrueDirection), -1, 1)))
                or 180

            --// Swimming, tilt toward the target like a diver striking: nose
            --// down at one below, up at one above. Capped short of vertical,
            --// where lookAt has no stable "up" and the body would spin.
            if AICCombatUtils.IsSelfSwimming() then
                local MaxPitch = math.rad(tonumber(CONFIG.SWIM_FACE_MAX_PITCH) or 70)
                local Pitch = math.clamp(
                    math.atan2(MobRoot.Position.Y - RootPosition.Y, Distance),
                    -MaxPitch,
                    MaxPitch
                )

                Direction = Direction * math.cos(Pitch) + Vector3.yAxis * math.sin(Pitch)
            end

            --// A retreat leaves the alignment slowed down; fighting is fast.
            FaceOrientation.Responsiveness = CONFIG.FACE_RESPONSIVENESS
            FaceOrientation.MaxAngularVelocity = math.huge

            --// A big miss snaps round in one step; small ones ease, which
            --// keeps the stance from twitching on every tiny adjustment.
            FaceOrientation.RigidityEnabled = Error > (tonumber(CONFIG.FACE_SNAP_ANGLE) or 35)
            FaceOrientation.CFrame = CFrame.lookAt(
                RootPosition,
                RootPosition + Direction
            )

            FaceOrientation.Enabled = true
        end

        --// Facing while backing away. The retreat used to switch between the
        --// threat and the way it runs whenever the threat crossed the face
        --// range, and the fight-back swing turned it again in the same frame,
        --// each through FaceGoblin's instant snap, so the character spun back
        --// and forth. Here the turn is slow and capped, small changes are
        --// ignored, and a switch between threat and run direction needs the
        --// threat clearly in or out of range and is then held for a moment.
        --// No RunDirection means the caller has to face the threat (a swing).
        function AICCombat.FaceWhileRetreating(Threat, RunDirection)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()
            if not RootPart or not FaceOrientation then
                return
            end

            local now = os.clock()
            local RootPosition = RootPart.Position
            local ThreatRoot = Threat and Threat:FindFirstChild("HumanoidRootPart")
            local ThreatDirection, ThreatDistance = nil, math.huge

            if ThreatRoot then
                local Flat = Vector3.new(
                    ThreatRoot.Position.X - RootPosition.X,
                    0,
                    ThreatRoot.Position.Z - RootPosition.Z
                )

                if Flat.Magnitude > 0.01 then
                    ThreatDirection = Flat.Unit
                    ThreatDistance = Flat.Magnitude
                end
            end

            local FlatRun = RunDirection and Vector3.new(RunDirection.X, 0, RunDirection.Z)
            local RunUnit = FlatRun and FlatRun.Magnitude > 0.01 and FlatRun.Unit or nil

            local FacingThreat = AICCombat.S.RetreatFacingThreat == true
            local FaceRange = CONFIG.COMBAT_FACE_RANGE

            if FacingThreat then
                FaceRange += tonumber(CONFIG.RETREAT_FACE_HYSTERESIS) or 6
            end

            local WantThreat = ThreatDirection ~= nil
                and (not RunUnit or ThreatDistance <= FaceRange)

            --// A swing turns to its threat at once; the retreat call in the
            --// next frame then agrees with it instead of turning back.
            local HoldOver = now - (AICCombat.S.RetreatFacingSince or 0)
                >= (tonumber(CONFIG.RETREAT_FACE_HOLD) or 0.8)

            if WantThreat ~= FacingThreat and (HoldOver or not RunUnit) then
                FacingThreat = WantThreat
                AICCombat.S.RetreatFacingThreat = WantThreat
                AICCombat.S.RetreatFacingSince = now
            end

            local Direction = FacingThreat and ThreatDirection or RunUnit or ThreatDirection
            if not Direction then
                return
            end

            --// Keep the current heading through small changes. Only a fresh
            --// one counts: a heading left over from an old retreat is not.
            local Previous = AICCombat.S.RetreatFaceDirection
            local Deadband = math.cos(math.rad(tonumber(CONFIG.RETREAT_FACE_DEADBAND) or 15))

            if Previous
                and now - (AICCombat.S.RetreatFaceTime or 0) < 0.3
                and Previous:Dot(Direction) >= Deadband
            then
                Direction = Previous
            end

            AICCombat.S.RetreatFaceDirection = Direction
            AICCombat.S.RetreatFaceTime = now

            if Humanoid then
                Humanoid.AutoRotate = false
            end

            FaceOrientation.RigidityEnabled = false
            FaceOrientation.Responsiveness = tonumber(CONFIG.RETREAT_FACE_RESPONSIVENESS) or 30
            FaceOrientation.MaxAngularVelocity = tonumber(CONFIG.RETREAT_FACE_MAX_TURN_SPEED) or 6
            FaceOrientation.CFrame = CFrame.lookAt(RootPosition, RootPosition + Direction)
            FaceOrientation.Enabled = true
        end
        function AICCombat.GetCombatHealthPercent()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not Humanoid or Humanoid.MaxHealth <= 0 then
                return 100
            end
        
            return (Humanoid.Health / Humanoid.MaxHealth) * 100
        end
        function AICCombat.IsEnemyUsingSkill(Mob)
            if not Mob then
                return false
            end
        
            local EnemySword = Mob:FindFirstChild("Sword")
            local BladePart = EnemySword and EnemySword:FindFirstChild("BladePart")
            local SkillObject = Mob:FindFirstChild("Skill", true)
            local Sparkles = BladePart and BladePart:FindFirstChild("Sparkles", true)
        
            local SkillSoundActive = SkillObject
                and SkillObject:IsA("Sound")
                and SkillObject.IsPlaying
        
            local SparklesActive = Sparkles
                and Sparkles:IsA("ParticleEmitter")
                and Sparkles.Enabled
        
            return SkillSoundActive or SparklesActive or false
        end
        
        --// Scan every nearby living priority mob, not only the current target. A
        --// skill from a mob we are not fighting lands just the same, and the old
        --// check missed it entirely.
        function AICCombat.GetSkillThreat()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart then
                return false, nil
            end
        
            local Range = tonumber(CONFIG.SKILL_DETECT_DISTANCE) or 45
            local Closest = nil
            local ClosestDistance = math.huge
        
            local function Consider(Mob)
                local MobRoot = Mob:FindFirstChild("HumanoidRootPart")
                local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
        
                if not MobRoot or not MobHumanoid or MobHumanoid.Health <= 0 then
                    return
                end
        
                --// Distance first: it is far cheaper than walking the mob for a
                --// sound and an emitter, and this runs every frame.
                local Distance = AICCombatUtils.GetHorizontalDistance(RootPart.Position, MobRoot.Position)
        
                if Distance > Range or Distance >= ClosestDistance then
                    return
                end
        
                if AICCombat.IsEnemyUsingSkill(Mob) then
                    Closest = Mob
                    ClosestDistance = Distance
                end
            end
        
            --// Only whether a skill is in progress matters, not which mob is closest,
            --// so this stops at the first hit instead of ranking them. It runs every
            --// heartbeat, so the saving is worth having.
            for Mob in AICCombat.S.ValidMobs do
                if Mob:IsDescendantOf(workspace) then
                    Consider(Mob)
        
                    if Closest then
                        return true, Closest
                    end
                end
            end
        
            --// ValidMobs lags a freshly spawned mob by up to one validation tick, so
            --// also look straight at the folder.
            local MobFolder = workspace:FindFirstChild("Mobs")
        
            if MobFolder then
                for _, Mob in MobFolder:GetChildren() do
                    if Mob:IsA("Model") and not AICCombat.S.ValidMobs[Mob] then
                        local Config = Mob:FindFirstChild("Config")
                        local Entity = Config and Config:FindFirstChild("Entity")
        
                        if Entity
                            and Entity:IsA("StringValue")
                            and AICCombat.IsEntityInPriority(Entity.Value)
                        then
                            Consider(Mob)
        
                            if Closest then
                                return true, Closest
                            end
                        end
                    end
                end
            end
        
            return Closest ~= nil, Closest
        end
        
        --// Latches the dodge on for a short hold. The sound and the emitter both
        --// flicker, and without this the script would step back into the attack
        --// between two frames of the same skill.
        function AICCombat.UpdateSkillThreat(now)
            local Detected = AICCombat.GetSkillThreat()
        
            if Detected then
                AICCombat.S.SkillThreatUntil = now + (tonumber(CONFIG.SKILL_DODGE_HOLD) or 0.75)
            end
        
            return now < AICCombat.S.SkillThreatUntil
        end
        function AICCombat.GetCombatAttackRange(TargetMob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local Range = CONFIG.COMBAT_ATTACK_RANGE
        
            if not TargetMob then
                return Range
            end
        
            local MobHumanoid = TargetMob:FindFirstChildOfClass("Humanoid")
            if MobHumanoid and MobHumanoid.MaxHealth > 0 then
                local HP = (MobHumanoid.Health / MobHumanoid.MaxHealth) * 100
                if HP <= CONFIG.COMBAT_FINISHER_HP_PERCENT then
                    Range += CONFIG.COMBAT_FINISHER_RANGE_BONUS
                end
            end
        
            return Range
        end
        function AICCombat.FaceCombatTarget(TargetMob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()
            if not RootPart or not TargetMob then
                return
            end
        
            --// One facing rule for approach and attack, so the two cannot
            --// pull the character toward slightly different headings.
            AICCombat.FaceGoblin(TargetMob)
        end
        function AICCombat.InvokeCombatInput(InputName)
            local InputBindableFunction = Runtime:GetInputBindableFunction()
            if not InputBindableFunction then
                return false
            end
        
            local Success = pcall(function()
                InputBindableFunction:Invoke(
                    InputName,
                    Enum.UserInputState.Begin
                )
            end)
        
            return Success
        end
        --// Distance used for attack decisions. In water it is 3D: a diver
        --// straight below is horizontally "in range" but the swing misses.
        function AICCombat.GetCombatDistance(TargetMob, Offset)
            if CONFIG.DISTANCE_Y_CALCULATE or AICCombat.IsWaterCombat(TargetMob) then
                return Offset.Magnitude
            end

            return Vector3.new(Offset.X, 0, Offset.Z).Magnitude
        end
        function AICCombat.CanCombatAttack(TargetMob, now)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not TargetMob or not RootPart then
                return false
            end
        
            local MobHumanoid = TargetMob:FindFirstChildOfClass("Humanoid")
            local MobRoot = TargetMob:FindFirstChild("HumanoidRootPart")
            if not MobHumanoid or not MobRoot or MobHumanoid.Health <= 0 then
                return false
            end
        
            local Distance = AICCombat.GetCombatDistance(TargetMob, MobRoot.Position - RootPart.Position)

            return Distance <= AICCombat.GetCombatAttackRange(TargetMob)
                and now >= AICCombat.S.COMBAT_NEXT_ATTACK_TIME
        end
        --// Fights the mob it is given, with no Enemy Priority check. The
        --// swing and skill logic lives here once for every caller; Auto
        --// Farm's PerformCombatActions validates first, and a boss stop
        --// picks its target from its own Boss Names (which are not on the
        --// Enemy Priority list) so it calls this directly.
        function AICCombat.AttackTarget(TargetMob, now)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not TargetMob or not RootPart then
                return
            end
        
            local MobRoot = TargetMob:FindFirstChild("HumanoidRootPart")
            local MobHumanoid = TargetMob:FindFirstChildOfClass("Humanoid")
            if not MobRoot or not MobHumanoid or MobHumanoid.Health <= 0 then
                return
            end
        
            local Distance = AICCombat.GetCombatDistance(TargetMob, MobRoot.Position - RootPart.Position)

            local EnemySkill = AICCombat.IsEnemyUsingSkill(TargetMob)
            local PlayerHP = AICCombat.GetCombatHealthPercent()
        
            if Distance <= CONFIG.COMBAT_FACE_RANGE then
                AICCombat.FaceCombatTarget(TargetMob)
            end
        
            if FeatureState.AutoSkill.Enabled
                and Distance <= CONFIG.COMBAT_SKILL_RANGE
                and PlayerHP >= CONFIG.COMBAT_SKILL_MIN_HP_PERCENT
                and not EnemySkill
                and now >= AICCombat.S.COMBAT_NEXT_SKILL_TIME
            then
                if AICCombat.InvokeCombatInput("SkillButton") then
                    AICCombat.S.LAST_SKILL_TIME = now
                    AICCombat.S.COMBAT_NEXT_SKILL_TIME = now + CONFIG.SKILL_INTERVAL
                    AICCombat.S.COMBAT_NEXT_ATTACK_TIME = math.max(AICCombat.S.COMBAT_NEXT_ATTACK_TIME, now + 0.08)
                end
            end
        
            if AICCombat.CanCombatAttack(TargetMob, now) then
                if AICCombat.InvokeCombatInput("AttackButton") then
                    AICCombat.S.LAST_ATTACK_TIME = now
                    AICCombat.S.COMBAT_ATTACK_PHASE = (AICCombat.S.COMBAT_ATTACK_PHASE % 2) + 1
        
                    local PhaseJitter = (AICCombat.S.COMBAT_ATTACK_PHASE == 1)
                        and CONFIG.COMBAT_ACTION_JITTER
                        or 0
        
                    AICCombat.S.COMBAT_NEXT_ATTACK_TIME = now
                        + CONFIG.ATTACK_INTERVAL
                        + PhaseJitter
                end
            end
        end
        function AICCombat.PerformCombatActions(TargetMob, now)
            if not TargetMob or not AICCombat.IsCombatTargetValid(TargetMob) then
                return
            end

            AICCombat.AttackTarget(TargetMob, now)
        end
        --// A swing thrown while retreating. Unlike PerformCombatActions it does
        --// not require a priority target: whatever has closed in gets hit, and
        --// no skill is spent on the way out.
        function AICCombat.RetreatAttack(Threat, now)
            if not AICCombat.CanCombatAttack(Threat, now) then
                return false
            end

            if not AICCombat.InvokeCombatInput("AttackButton") then
                return false
            end

            AICCombat.S.LAST_ATTACK_TIME = now
            AICCombat.S.COMBAT_NEXT_ATTACK_TIME = now + CONFIG.ATTACK_INTERVAL
            return true
        end

        function AICCombat.GetLivingGoblins()
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            --// Cached for a fraction of a second. The retreat solver asks for this
            --// once per candidate position, which meant rescanning the entire mob
            --// folder tens of times for a single decision.
            local now = os.clock()
        
            if AICCombat.S.LivingGoblinCache
                and now - AICCombat.S.LivingGoblinCacheTime < (tonumber(CONFIG.LIVING_MOB_CACHE_INTERVAL) or 0.1)
            then
                return AICCombat.S.LivingGoblinCache
            end
        
            local MobFolder = workspace:FindFirstChild("Mobs")
        
            if not MobFolder then
                AICCombat.S.LivingGoblinCache = {}
                AICCombat.S.LivingGoblinCacheTime = now
                return AICCombat.S.LivingGoblinCache
            end
        
            local Goblins = {}
        
            for _, Mob in MobFolder:GetChildren() do
                if not Mob:IsA("Model") then
                    continue
                end
        
                local Config      = Mob:FindFirstChild("Config")
                local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                local MobRoot     = Mob:FindFirstChild("HumanoidRootPart")
        
                if not Config or not MobHumanoid or not MobRoot then
                    continue
                end
        
                local Entity = Config:FindFirstChild("Entity")
        
                if not Entity then
                    continue
                end
        
                if not AICCombat.IsEntityInPriority(Entity.Value) then
                    continue
                end
        
                if MobHumanoid.Health <= 0 then
                    continue
                end
        
                table.insert(Goblins, Mob)
            end
        
            AICCombat.S.LivingGoblinCache = Goblins
            AICCombat.S.LivingGoblinCacheTime = now
        
            return Goblins
        end
        
        --// Return all mobs around the current combat group.
        function AICCombat.GetNearbyCombatMobs(TargetMob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not TargetMob then
                return {}
            end
        
            local TargetRoot = TargetMob:FindFirstChild("HumanoidRootPart")
        
            if not TargetRoot then
                return {}
            end
        
            local now = os.clock()
            local Cached = AICCombat.S.CombatGroupCache[TargetMob]
        
            if Cached
                and now - Cached.Time < CONFIG.COMBAT_GROUP_CACHE_INTERVAL
            then
                return Cached.Mobs
            end
        
            local NearbyMobs = {
                [TargetMob] = true,
            }
        
            local TargetPosition = TargetRoot.Position
        
            for Mob in AICCombat.S.ValidMobs do
                if Mob == TargetMob then
                    continue
                end
        
                if not Mob:IsDescendantOf(workspace) then
                    continue
                end
        
                local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                local MobRoot     = Mob:FindFirstChild("HumanoidRootPart")
        
                if not MobHumanoid
                    or not MobRoot
                    or MobHumanoid.Health <= 0
                then
                    continue
                end
        
                local Distance = AICCombatUtils.GetHorizontalDistance(TargetPosition, MobRoot.Position)
        
                if Distance <= CONFIG.GROUP_DANGER_DISTANCE then
                    NearbyMobs[Mob] = true
                end
            end
        
            --// Also inspect Mobs directly from workspace so a newly spawned
            --// mob that has not entered ValidMobs yet can still be considered.
            local MobFolder = workspace:FindFirstChild("Mobs")
        
            if MobFolder then
                for _, Mob in MobFolder:GetChildren() do
                    if NearbyMobs[Mob] or not Mob:IsA("Model") then
                        continue
                    end
        
                    local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                    local MobRoot     = Mob:FindFirstChild("HumanoidRootPart")
        
                    if not MobHumanoid
                        or not MobRoot
                        or MobHumanoid.Health <= 0
                    then
                        continue
                    end
        
                    local Config = Mob:FindFirstChild("Config")
                    local Entity = Config and Config:FindFirstChild("Entity")
        
                    if not Entity
                        or not Entity:IsA("StringValue")
                        or not AICCombat.IsEntityInPriority(Entity.Value)
                    then
                        continue
                    end
        
                    local Distance = AICCombatUtils.GetHorizontalDistance(TargetPosition, MobRoot.Position)
        
                    if Distance <= CONFIG.GROUP_DANGER_DISTANCE then
                        NearbyMobs[Mob] = true
                    end
                end
            end
        
            local Result = {}
        
            for Mob in NearbyMobs do
                table.insert(Result, Mob)
            end
        
            AICCombat.S.CombatGroupCache[TargetMob] = {
                Time = now,
                Mobs = Result,
            }
        
            return Result
        end
        
        --// Return cached BladeParts for the entire combat group.
        function AICCombat.GetCombatBladeParts(TargetMob)
            if not TargetMob then
                return {}
            end
        
            local now = os.clock()
            local Cached = AICCombat.S.CombatBladeCache[TargetMob]
        
            if Cached
                and now - Cached.Time < CONFIG.COMBAT_GROUP_CACHE_INTERVAL
            then
                return Cached.Parts
            end
        
            local BladeParts = {}
        
            for _, Mob in AICCombat.GetNearbyCombatMobs(TargetMob) do
                for _, BladePart in AICCombatUtils.GetBladeParts(Mob) do
                    if BladePart:IsDescendantOf(workspace) then
                        table.insert(BladeParts, BladePart)
                    end
                end
            end
        
            AICCombat.S.CombatBladeCache[TargetMob] = {
                Time  = now,
                Parts = BladeParts,
            }
        
            return BladeParts
        end
        
        --// Checks every BladePart in the combat group.
        function AICCombat.GetBladeDangerData(TargetMob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetMob then
                return Vector3.zero, math.huge, nil
            end
        
            local PushDirection            = Vector3.zero
            local ClosestEffectiveDistance = math.huge
            local ClosestBlade             = nil
            local DangerDistance           = AICCombatUtils.GetBladeDangerDistance()
        
            for _, BladePart in AICCombat.GetCombatBladeParts(TargetMob) do
                local ClosestPoint, Distance = AICCombatUtils.GetClosestPointOnBlade(BladePart, RootPart.Position)
        
                if not ClosestPoint then
                    continue
                end
        
                local EffectiveDistance = Distance - DangerDistance
        
                if EffectiveDistance < ClosestEffectiveDistance then
                    ClosestEffectiveDistance = EffectiveDistance
                    ClosestBlade = BladePart
                end
        
                if Distance <= DangerDistance then
                    local Offset = RootPart.Position - ClosestPoint
                    local HorizontalOffset = Vector3.new(Offset.X, 0, Offset.Z)
        
                    if HorizontalOffset.Magnitude > 0.01 then
                        local Strength = math.max(DangerDistance - Distance, 0.1)
                        PushDirection += HorizontalOffset.Unit * Strength
                    end
                end
            end
        
            if PushDirection.Magnitude > 0.01 then
                PushDirection = PushDirection.Unit
            end
        
            return PushDirection, ClosestEffectiveDistance, ClosestBlade
        end
        
        --// Check whether a position is safe from every BladePart
        --// in the nearby enemy group.
        function AICCombat.IsPositionSafeFromBladeGroup(Position, TargetMob)
            if not Position or not TargetMob then
                return true
            end
        
            local DangerDistance = AICCombatUtils.GetBladeDangerDistance()
        
            for _, BladePart in AICCombat.GetCombatBladeParts(TargetMob) do
                local _, Distance = AICCombatUtils.GetClosestPointOnBlade(BladePart, Position)
        
                if Distance <= DangerDistance then
                    return false
                end
            end
        
            return true
        end
        
        --// Checks whether a movement line crosses a BladePart danger zone.
        function AICCombat.IsPathThroughBladeGroupDanger(TargetPosition, TargetMob)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            if not RootPart or not TargetPosition or not TargetMob then
                return false
            end
        
            local Origin = RootPart.Position
            local Offset = TargetPosition - Origin
            local Distance = Offset.Magnitude
            local DangerDistance = AICCombatUtils.GetBladeDangerDistance()
            local BladeParts = AICCombat.GetCombatBladeParts(TargetMob)
        
            if Distance <= 0.01 then
                for _, BladePart in BladeParts do
                    local _, BladeDistance = AICCombatUtils.GetClosestPointOnBlade(BladePart, TargetPosition)
        
                    if BladeDistance <= DangerDistance then
                        return true
                    end
                end
        
                return false
            end
        
            local Direction = Offset.Unit
            local SampleDistance = 2
        
            for DistanceTravelled = 0, Distance, SampleDistance do
                local Position = Origin + Direction * DistanceTravelled
        
                for _, BladePart in BladeParts do
                    local _, BladeDistance = AICCombatUtils.GetClosestPointOnBlade(BladePart, Position)
        
                    if BladeDistance <= DangerDistance then
                        return true
                    end
                end
            end
        
            return false
        end
        
        
        ------------------------------------------------------------------------
        --// AICFeature
        --//
        --// standalone behaviours: route, patrol, zones, blocking, upkeep
        --//
        --// 22 function(s). Definitions only; nothing here runs
        --// at load time.
        ------------------------------------------------------------------------
        
        ------------------------------------------------------------------------
        --// AICState  ::  character handle, player stats, shared resets
        --// 9 function(s)
        ------------------------------------------------------------------------
        --// Character
        return Module
    end,
}
