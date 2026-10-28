-- AutoFarming_Navigation - target approach and mob-gather helpers.
-- Split from Features/AutoFarming.lua as part of Step 4b.
return {
    Name = "AutoFarming_Navigation",
    Dependencies = {"AutoFarming"},

    Start = function(Context)
        local AICFeature = Context.AICFeature
        local AICCombat = Context.AICCombat

        --// Goes for the locked target. While Character.NoDamage is on us our
        --// hits do nothing, so it circles the target outside its reach
        --// instead of running in, until NoDamage is gone.
        AICFeature.ApproachTarget = function(Target)
            if AICCombat.HasNoDamage() then
                AICCombat.OrbitTarget(Target)
            else
                AICCombat.MoveToGoblin(Target)
            end
        end

        --// Gather Mobs, once the route is walked and the character is inside
        --// the farm zone. True while it pulls a pack together or uses the
        --// skill on it; it moves and fights by itself then.
        AICFeature.RunGather = function(now)
            if not AICFeature.GatherStep or not AICFeature.GatherStep(now) then
                return false
            end

            AICCombat.S.ClosestTarget = nil
            AICFeature.CancelPatrol()
            return true
        end

        return { Name = "AutoFarming_Navigation" }
    end,
}
