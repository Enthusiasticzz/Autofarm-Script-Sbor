return {
    Name = "ResetStats",
    IsFeature = true,
    Dependencies = {"Runtime", "Components"},

    Start = function(Context)
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local NotifyAction = Context.NotifyAction
        local Feature = {
            Name = "ResetStats",
            IsFeature = true,
            Enabled = true,
        }

        function Feature:Update()
        end

        function Feature:CreateUI()
            if Context.UIRef.StatusSection then
                self.Button = Context.UIRef.StatusSection:AddButton("Reset Stats", function()
                    task.spawn(function()
                        local PlayerStats = Player:WaitForChild("PlayerStats")
                        local StatsEvent = Replicated:FindFirstChild("StatsEvent", true)
                        if not StatsEvent then
                            return print(`StatsEvent is not valid.`)
                        end

                        local Stats = {"Vitality", "Agility", "Luck", "Strength", "Defense"}
                        for _, StatName in ipairs(Stats) do
                            local StatValue = PlayerStats:FindFirstChild(StatName)
                            if not StatValue then
                                continue
                            end
                            if StatValue.Value < CONFIG.STAT_RESET_THRESHOLD then
                                StatsEvent:FireServer(StatName, 0)
                            else
                                NotifyAction("RESET STATS", `Cannot reset "{StatName}": {CONFIG.STAT_RESET_THRESHOLD}+ invested points trip the game anticheat.`)
                            end
                        end
                    end)
                end)
                FeatureState.ResetStats.Button = self.Button
            end
        end

        Feature:CreateUI()

        return Feature
    end,
}
