return {
    Name = "EnemyPriority",
    IsFeature = true,
    Dependencies = {"Runtime"},

    Start = function(Context)
        local CONFIG = Context.CONFIG

        --// The priority list itself is CONFIG.TARGET_ENTITY_PRIORITY, saved as
        --// the profile's DEFAULT_TARGET_PRIORITY. The Targeting section owns
        --// its UI.
        local Feature = {
            Name = "EnemyPriority",
            IsFeature = true,
        }

        function Feature:GetPriority()
            return CONFIG.TARGET_ENTITY_PRIORITY or {}
        end

        function Feature:SetPriority(Value)
            CONFIG.TARGET_ENTITY_PRIORITY = Value or {}
        end

        function Feature:IsPriority(Name)
            return table.find(self:GetPriority(), Name) ~= nil
        end

        function Feature:Update()
        end

        return Feature
    end,
}
