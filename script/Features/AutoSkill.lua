return {
    Name = "AutoSkill",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components"},

    Start = function(Context)
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef

        local Feature = {
            Name = "AutoSkill",
            IsFeature = true,
        }

        function Feature:Update()
        end

        --// Read by PerformCombatActions through Feature.AutoSkill.Enabled.
        AICUI.BindFeatureToggle("AutoSkill", "Auto Skill", nil, UIRef.CombatSection)

        return Feature
    end,
}
