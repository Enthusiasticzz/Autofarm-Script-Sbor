return {
    Name = "AutoHeal",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig"},

    Start = function()
        local Feature = {
            Name = "AutoHeal",
            IsFeature = true,
            Enabled = true,
        }

        function Feature:SetEnabled(Value)
            self.Enabled = Value == true
        end

        function Feature:CreateUI()
            -- Healing is part of the existing retreat/consumable decision
            -- in AutoFarming. The slider remains feature-owned in the UI builder.
        end

        function Feature:Update()
        end

        return Feature
    end,
}
