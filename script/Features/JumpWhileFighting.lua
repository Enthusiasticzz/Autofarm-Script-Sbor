return {
    Name = "JumpWhileFighting",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components"},

    Start = function(Context)
        local AICCombatUtils = Context.AICCombatUtils
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef

        local Feature = {
            Name = "JumpWhileFighting",
            IsFeature = true,
        }

        function Feature:Update()
        end

        --// Read by the combat movement jumps: CombatUtils.DoCombatJump and
        --// DoCombatJumpIfObstacle. Off, the character stays on the ground for
        --// the whole fight; the waypoint route, Waypoint Loop, patrol, mining
        --// and smithing each make their own jumps and are not affected.
        AICUI.BindFeatureToggle("JumpWhileFighting", "Jump While Fighting", function()
            --// Whatever the chase was doing, decide again from here rather than
            --// finishing a hop the toggle has just turned off.
            AICCombatUtils.ResetStuckTracker()
        end, UIRef.CombatSection)

        return Feature
    end,
}
