-- MobGather pulls a pack of mobs together before using the skill on them.
--
--   Idle   picks a pack: at least GATHER_MIN_MOBS valid mobs within
--          GATHER_RADIUS of the nearest one, none being fought by another
--          player. Fewer than that and the farm fights as usual.
--   Tag    runs to each mob in turn and hits it once, so it follows us,
--          then goes on to the next (GATHER_MAX_MOBS at most).
--   Kite   backs off KITE_DISTANCE away from the pack and waits there for
--          the tagged mobs to bunch up within the skill's range.
--   Burst  faces the pack and uses the skill once it is ready.
--   Fight  hands the frame back to normal combat until the pack is down.
--
-- Any step that takes too long, a pack that stops following, a duel, or
-- health under COMBAT_SKILL_MIN_HP_PERCENT ends the round; the farm then
-- fights as usual and the next round waits ROUND_COOLDOWN. The health
-- retreat, skill dodging, Auto Block and the waypoint route all run before
-- this, as AutoFarming calls GatherStep after them.
return {
    Name = "MobGather",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components", "CombatUtils", "Targeting", "Navigation", "Combat", "WalkController"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local Feature = Context.Feature
        local AICCombat = Context.AICCombat
        local AICCombatUtils = Context.AICCombatUtils
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef
        local Movement = Context.WalkController

        --// Seconds to reach and hit one mob before it is dropped from the pack.
        local TAG_TIMEOUT = 6
        local KITE_TIMEOUT = 10
        --// Waiting at the kite spot for the pack before using the skill anyway.
        local GATHER_WAIT = 4
        --// Facing the pack and waiting for the skill to come off cooldown.
        local BURST_TIMEOUT = 4
        local FIGHT_TIMEOUT = 25
        local ROUND_COOLDOWN = 4
        --// How far the kite backs off from the pack.
        local KITE_DISTANCE = 12
        local KITE_ARRIVAL = 3
        --// A tagged mob farther than this from us has stopped following...
        local LOST_DISTANCE = 35
        --// ...once it has been that far this long.
        local LOST_SECONDS = 3
        --// Kite directions tried, in degrees off straight away from the pack.
        local KITE_ANGLES = { 0, 35, -35, 70, -70, 110, -110 }

        local Gather = {
            Name = "MobGather",
            IsFeature = true,
            S = {
                State = "Idle",
                StateSince = 0,
                CooldownUntil = 0,
                --// The pack in tagging order.
                Pack = {},
                Tagged = {},
                TagIndex = 1,
                TagStart = 0,
                LostSince = {},
                KitePoint = nil,
                ArrivedAt = nil,
            },
        }

        local S = Gather.S

        ------------------------------------------------------------------------
        --// Helpers
        ------------------------------------------------------------------------

        local function SetState(State, now)
            S.State = State
            S.StateSince = now
        end

        local function GetRoot(Mob)
            return Mob and Mob.Parent and Mob:FindFirstChild("HumanoidRootPart")
        end

        local function IsAlive(Mob)
            local Humanoid = Mob and Mob.Parent and Mob:FindFirstChildOfClass("Humanoid")
            return Humanoid ~= nil and Humanoid.Health > 0 and GetRoot(Mob) ~= nil
        end

        --// Another player is fighting it: leave it to them.
        local function IsClaimedByOther(Mob)
            local LastAttacker = Mob:FindFirstChild("LastAttacker")
            local Value = LastAttacker and LastAttacker.Value
            return Value ~= nil and Value ~= Player
        end

        local function IsPackCandidate(Mob)
            return not Players:GetPlayerFromCharacter(Mob)
                and AICCombat.IsTargetLockValid(Mob)
                and not IsClaimedByOther(Mob)
        end

        local function GetHealthPercent()
            local _, Humanoid = Runtime:GetCharacter()

            if not Humanoid or Humanoid.MaxHealth <= 0 then
                return 0
            end

            return Humanoid.Health / Humanoid.MaxHealth * 100
        end

        --// Tagged mobs still alive and still following.
        local function GetFollowers(now, RootPart)
            local Followers = {}

            for _, Mob in ipairs(S.Pack) do
                local MobRoot = GetRoot(Mob)

                if S.Tagged[Mob] and IsAlive(Mob) and MobRoot then
                    if AICCombatUtils.GetHorizontalDistance(MobRoot.Position, RootPart.Position) > LOST_DISTANCE then
                        S.LostSince[Mob] = S.LostSince[Mob] or now
                    else
                        S.LostSince[Mob] = nil
                    end

                    if now - (S.LostSince[Mob] or now) < LOST_SECONDS then
                        table.insert(Followers, Mob)
                    end
                end
            end

            return Followers
        end

        local function GetCentroid(Mobs)
            local Sum, Count = Vector3.zero, 0

            for _, Mob in ipairs(Mobs) do
                local MobRoot = GetRoot(Mob)

                if MobRoot then
                    Sum += MobRoot.Position
                    Count += 1
                end
            end

            return Count > 0 and Sum / Count or nil
        end

        local function GetNearest(Mobs, Position)
            local Best, BestDistance = nil, math.huge

            for _, Mob in ipairs(Mobs) do
                local MobRoot = GetRoot(Mob)
                local Distance = MobRoot and AICCombatUtils.GetHorizontalDistance(MobRoot.Position, Position) or math.huge

                if Distance < BestDistance then
                    Best, BestDistance = Mob, Distance
                end
            end

            return Best, BestDistance
        end

        local function CountWithin(Mobs, Position, Radius)
            local Count = 0

            for _, Mob in ipairs(Mobs) do
                local MobRoot = GetRoot(Mob)

                if MobRoot and AICCombatUtils.GetHorizontalDistance(MobRoot.Position, Position) <= Radius then
                    Count += 1
                end
            end

            return Count
        end

        local function SetStatus(Text)
            if UIRef.GatherStatusLabel then
                UIRef.GatherStatusLabel.Text = "GATHER  " .. Text
            end
        end

        ------------------------------------------------------------------------
        --// Rounds
        ------------------------------------------------------------------------

        function Gather:Reset(now)
            table.clear(S.Pack)
            table.clear(S.Tagged)
            table.clear(S.LostSince)
            S.TagIndex = 1
            S.KitePoint = nil
            S.ArrivedAt = nil
            SetState("Idle", now or os.clock())
            Movement:Reset()
        end

        local function EndRound(now, Reason)
            Gather:Reset(now)
            S.CooldownUntil = now + ROUND_COOLDOWN
            SetStatus(Reason)
        end

        --// Nearest valid mob first, then repeatedly the pack member nearest
        --// the last one, so the tagging run does not zig-zag.
        local function FindPack(RootPart)
            local Candidates = {}

            for Mob in pairs(AICCombat.S.ValidMobs) do
                if IsPackCandidate(Mob) then
                    table.insert(Candidates, Mob)
                end
            end

            local Seed = GetNearest(Candidates, RootPart.Position)
            local SeedRoot = GetRoot(Seed)

            if not SeedRoot then
                return nil
            end

            local Radius = tonumber(CONFIG.GATHER_RADIUS) or 40
            local Remaining = {}

            for _, Mob in ipairs(Candidates) do
                local MobRoot = GetRoot(Mob)

                if MobRoot and AICCombatUtils.GetHorizontalDistance(MobRoot.Position, SeedRoot.Position) <= Radius then
                    table.insert(Remaining, Mob)
                end
            end

            if #Remaining < (tonumber(CONFIG.GATHER_MIN_MOBS) or 3) then
                return nil
            end

            local Pack = {}
            local From = RootPart.Position
            local MaxMobs = tonumber(CONFIG.GATHER_MAX_MOBS) or 5

            while #Remaining > 0 and #Pack < MaxMobs do
                local Next = GetNearest(Remaining, From)
                table.remove(Remaining, table.find(Remaining, Next))
                table.insert(Pack, Next)
                From = GetRoot(Next).Position
            end

            return Pack
        end

        --// A spot KITE_DISTANCE away from the pack, inside the farm zone and
        --// out of deadzones and water, with an open walk to it.
        local function FindKitePoint(RootPart, Followers)
            local Center = GetCentroid(Followers)

            if not Center then
                return nil
            end

            local Away = RootPart.Position - Center
            Away = Vector3.new(Away.X, 0, Away.Z)
            Away = Away.Magnitude > 0.01 and Away.Unit or RootPart.CFrame.LookVector * -1

            for _, Angle in ipairs(KITE_ANGLES) do
                local Direction = CFrame.Angles(0, math.rad(Angle), 0):VectorToWorldSpace(Away)
                local Point = RootPart.Position + Direction * KITE_DISTANCE

                if AICCombatUtils.IsInsideFarmArea(Point)
                    and not AICCombatUtils.IsInsideFarmDeadzone(Point)
                    and not AICCombatUtils.IsWaterAtPosition(Point)
                    and not AICCombatUtils.IsPathThroughDeadzone(Point)
                    and AICCombatUtils.IsPathClear(Point)
                then
                    return Point
                end
            end

            return nil
        end

        local function StepIdle(now, RootPart)
            if now < S.CooldownUntil then
                return false
            end

            if GetHealthPercent() < (tonumber(CONFIG.COMBAT_SKILL_MIN_HP_PERCENT) or 50) then
                SetStatus("WAITING FOR HEALTH")
                return false
            end

            local Pack = FindPack(RootPart)

            if not Pack then
                SetStatus("NO PACK")
                return false
            end

            S.Pack = Pack
            S.TagIndex = 1
            S.TagStart = now
            SetState("Tag", now)
            return true
        end

        local function StepTag(now, RootPart)
            --// Skip anything dead, gone, taken by another player, or already
            --// following us (hit by the fight before the round).
            while S.TagIndex <= #S.Pack do
                local Mob = S.Pack[S.TagIndex]
                local LastAttacker = IsAlive(Mob) and Mob:FindFirstChild("LastAttacker")

                if not IsAlive(Mob) or IsClaimedByOther(Mob) then
                    S.TagIndex += 1
                    S.TagStart = now
                elseif LastAttacker and LastAttacker.Value == Player then
                    S.Tagged[Mob] = true
                    S.TagIndex += 1
                    S.TagStart = now
                else
                    break
                end
            end

            local Mob = S.Pack[S.TagIndex]

            if not Mob then
                SetState("Kite", now)
                return true
            end

            if now - S.TagStart > TAG_TIMEOUT then
                S.TagIndex += 1
                S.TagStart = now
                return true
            end

            SetStatus(string.format("TAG  %d / %d", S.TagIndex, #S.Pack))

            if AICFeature.EnsureWeaponDrawn and AICFeature.EnsureWeaponDrawn(now) then
                Movement:Hold()
                return true
            end

            local MobRoot = GetRoot(Mob)
            local Distance = AICCombatUtils.GetHorizontalDistance(MobRoot.Position, RootPart.Position)

            if Distance <= AICCombat.GetCombatAttackRange(Mob) then
                Movement:Hold()
                AICCombat.FaceGoblin(Mob)

                --// One swing is enough to make it follow; go on to the next.
                if AICCombat.RetreatAttack(Mob, now) then
                    S.Tagged[Mob] = true
                    S.TagIndex += 1
                    S.TagStart = now
                end

                return true
            end

            if Movement:MoveTo(MobRoot.Position, { Ignore = Mob }) == "failed" then
                S.TagIndex += 1
                S.TagStart = now
            end

            return true
        end

        local function StepKite(now, RootPart, Followers)
            if #Followers == 0 then
                EndRound(now, "PACK LOST")
                return false
            end

            local SkillRange = tonumber(CONFIG.COMBAT_SKILL_RANGE) or 15
            local Wanted = math.min(tonumber(CONFIG.GATHER_MIN_MOBS) or 3, #Followers)

            --// Bunched up already: no need to back off further.
            if CountWithin(Followers, RootPart.Position, SkillRange) >= Wanted
                and now - S.StateSince > 0.5
            then
                SetState("Burst", now)
                return true
            end

            S.KitePoint = S.KitePoint or FindKitePoint(RootPart, Followers)

            local Arrived = not S.KitePoint
                or AICCombatUtils.GetHorizontalDistance(S.KitePoint, RootPart.Position) <= KITE_ARRIVAL

            if Arrived then
                S.ArrivedAt = S.ArrivedAt or now
                Movement:Hold()
                AICCombat.FaceGoblin((GetNearest(Followers, RootPart.Position)))
                SetStatus(string.format("GATHERING  %d / %d", CountWithin(Followers, RootPart.Position, SkillRange), #Followers))

                if now - S.ArrivedAt > GATHER_WAIT then
                    SetState("Burst", now)
                end

                return true
            end

            if now - S.StateSince > KITE_TIMEOUT then
                SetState("Burst", now)
                return true
            end

            SetStatus("KITE")
            Movement:MoveTo(S.KitePoint)
            return true
        end

        local function StepBurst(now, RootPart, Followers)
            local Nearest = GetNearest(Followers, RootPart.Position)

            if not Nearest then
                EndRound(now, "PACK LOST")
                return false
            end

            Movement:Hold()
            AICCombat.FaceGoblin(Nearest)
            SetStatus("BURST")

            if AICFeature.EnsureWeaponDrawn and AICFeature.EnsureWeaponDrawn(now) then
                return true
            end

            local SkillReady = now >= AICCombat.S.COMBAT_NEXT_SKILL_TIME

            if SkillReady and AICCombat.InvokeCombatInput("SkillButton") then
                AICCombat.S.LAST_SKILL_TIME = now
                AICCombat.S.COMBAT_NEXT_SKILL_TIME = now + CONFIG.SKILL_INTERVAL
                SetState("Fight", now)
                return true
            end

            --// The skill would not come: fight them as they are.
            if now - S.StateSince > BURST_TIMEOUT then
                SetState("Fight", now)
            end

            return true
        end

        --// Normal combat fights the pack; this only watches for the end.
        local function StepFight(now, Followers)
            SetStatus(string.format("FIGHT  %d LEFT", #Followers))

            if #Followers == 0 or now - S.StateSince > FIGHT_TIMEOUT then
                EndRound(now, "DONE")
            end

            return false
        end

        --// Called by AutoFarming once the route is walked, after the health
        --// retreat and skill dodging. True while gathering owns this frame.
        function AICFeature.GatherStep(now)
            if not Feature.MobGather.Enabled then
                return false
            end

            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return false
            end

            if S.State ~= "Idle" and AICCombat.IsInDuel() then
                EndRound(now, "DUEL")
                return false
            end

            if S.State == "Idle" then
                return StepIdle(now, RootPart)
            elseif S.State == "Tag" then
                return StepTag(now, RootPart)
            end

            local Followers = GetFollowers(now, RootPart)

            if S.State == "Kite" then
                return StepKite(now, RootPart, Followers)
            elseif S.State == "Burst" then
                return StepBurst(now, RootPart, Followers)
            end

            return StepFight(now, Followers)
        end

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        local Section = UIRef.GatherSection

        AICUI.BindFeatureToggle("MobGather", "Gather Mobs", function(Enabled)
            Gather:Reset()
            SetStatus(Enabled and "IDLE" or "OFF")
        end, Section)

        UIRef.GatherStatusLabel = Section:AddLabel("GATHER  OFF")
        UIRef.GatherMinSlider = AICUI.AddSettingSlider(Section, "Min Mobs", "GATHER_MIN_MOBS", true)
        UIRef.GatherMaxSlider = AICUI.AddSettingSlider(Section, "Max Mobs", "GATHER_MAX_MOBS", true)
        UIRef.GatherRadiusSlider = AICUI.AddSettingSlider(Section, "Gather Radius", "GATHER_RADIUS", true)

        Context.Connect(Player.CharacterAdded, function()
            Gather:Reset()
        end)

        function Gather:Update()
            if not Feature.MobGather.Enabled and S.State ~= "Idle" then
                Gather:Reset()
            end
        end

        return Gather
    end,
}
