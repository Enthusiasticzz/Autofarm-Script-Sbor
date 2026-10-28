-- AutoFarming_UI - stat helpers, stamina regen, and the per-frame UI sync.
-- Split from Features/AutoFarming.lua as part of Step 4b.
return {
    Name = "AutoFarming_UI",
    Dependencies = {"AutoFarming", "Logger"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local PlayerGui = Context.PlayerGui
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local Logger = Context.Logger
        local CONFIG = Context.CONFIG

        AICFeature.GetPlayerStatValue = function(Name, Default)
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Stat = PlayerStats and PlayerStats:FindFirstChild(Name)

            if not Stat then
                Logger.debug("PlayerStats.%s missing; using %s", Name, tostring(Default))
                return Default
            end

            return tonumber(Stat.Value) or Default
        end

        AICFeature.GetPlayerLevel = function()
            return AICFeature.GetPlayerStatValue("Level", 0)
        end

        --// Toggle Screen GUI
        AICFeature.CreateToggleContainer = function()
        end

        AICFeature.RegenStamina = function()
            task.spawn(function()
                local PlayerStats = Player:FindFirstChild("PlayerStats")
                if not PlayerStats then
                    repeat task.wait(0.5) until Player:FindFirstChild("PlayerStats")
                    PlayerStats = Player:FindFirstChild("PlayerStats")
                end
                local GameGui = PlayerGui:FindFirstChild("GameGui")
                if not GameGui then
                    repeat task.wait(0.5) until PlayerGui:FindFirstChild("GameGui")
                    GameGui = PlayerGui:FindFirstChild("GameGui")
                end
                local Stamina = GameGui:FindFirstChild("Stamina")
                local MaxStamina = PlayerStats:FindFirstChild("MaxStamina")

                if not Stamina or not MaxStamina then
                    return
                end

                AICFeature.S.StaminaConnection = Stamina:GetPropertyChangedSignal("Value"):Connect(function()
                    if Stamina.Value < MaxStamina.Value then
                        Stamina.Value = MaxStamina.Value
                    end
                end)
            end)
        end

        AICFeature.RenderUpdate = function(dt)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local PlaceConfig = Runtime:GetPlaceConfig()

            AICUI.updatePosition()

            --// Auto Mining holds WalkSpeed at 0 while it mines a node.
            local SpeedLocked = AICFeature.IsWalkSpeedLocked and AICFeature.IsWalkSpeedLocked()

            if Humanoid and not SpeedLocked then
                if AICFeature.GetPlayerLevel() >= CONFIG.HIGH_LEVEL_THRESHOLD then
                    if Humanoid.WalkSpeed < CONFIG.MAXIMUM_WALKSPEED then
                        Humanoid.WalkSpeed = CONFIG.MAXIMUM_WALKSPEED
                    end
                elseif Humanoid.WalkSpeed < CONFIG.MINIMUM_WALKSPEED then
                    Humanoid.WalkSpeed = CONFIG.MINIMUM_WALKSPEED
                end
            end
        end

        return { Name = "AutoFarming_UI" }
    end,
}
