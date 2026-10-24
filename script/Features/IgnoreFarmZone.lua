return {
    Name = "IgnoreFarmZone",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components"},

    Start = function(Context)
        local AICFeature = Context.AICFeature
        local AICCombat = Context.AICCombat
        local AICUI = Context.AICUI
        local PatrolState = Context.PatrolState

        local Feature = {
            Name = "IgnoreFarmZone",
            IsFeature = true,
        }

        function Feature:Update()
        end

        AICUI.BindFeatureToggle("IgnoreFarmZone", "Ignore Farm Zone", function()
            AICCombat.S.ClosestTarget = nil
            table.clear(AICCombat.S.ValidMobs)
            table.clear(AICCombat.S.CombatGroupCache)
            AICCombat.ResetTargetReposition()
            AICFeature.S.DeadzoneEscapePosition = nil
            PatrolState.PatrolPosition = nil
            PatrolState.LastPatrolCalculateTime = 0
            AICFeature.S.FarmReturnPosition = nil
            AICFeature.S.LastFarmReturnCalculateTime = 0
            AICCombat.UpdateValidMobs()
            AICCombat.S.ClosestTarget = AICCombat.GetClosestGoblin()
        end)

        return Feature
    end,
}
