-- AutoFarming_State - farm-state label, chase description, and side-job gate.
-- Split from Features/AutoFarming.lua as part of Step 4b.
return {
    Name = "AutoFarming_State",
    Dependencies = {"AutoFarming", "Logger"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local UIRef = Context.UIRef
        local AICFeature = Context.AICFeature
        local AICCombat = Context.AICCombat
        local AICCombatUtils = Context.AICCombatUtils
        local Logger = Context.Logger

        --// FARM STATE on the Status tab: what the loop did this frame, so a
        --// character standing still can be told apart without reading the code.
        AICFeature.SetFarmState = function(Text)
            local Label = UIRef.FarmStateLabel
            Text = "FARM STATE  " .. Text

            if Label and Label.Text ~= Text then
                Label.Text = Text
                Logger.debug("%s", Text)
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

        AICFeature.DescribeChase = function()
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

        --// Auto Smithing, then Auto Mining, once the route is walked. True
        --// while one of them owns this frame's movement.
        AICFeature.RunSideJobs = function(now)
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

        return { Name = "AutoFarming_State" }
    end,
}
