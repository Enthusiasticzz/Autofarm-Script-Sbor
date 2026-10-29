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

        --// The walk speed picks between two speeds from this every frame, and
        --// the lookup walks two children each time; a quarter second of lag
        --// on a level-up is not worth sixty lookups a second.
        local LEVEL_CACHE_SECONDS = 0.25
        local CachedLevel, CachedLevelAt = nil, -math.huge

        AICFeature.GetPlayerLevel = function()
            local Now = os.clock()

            if CachedLevel ~= nil and Now - CachedLevelAt < LEVEL_CACHE_SECONDS then
                return CachedLevel
            end

            CachedLevel, CachedLevelAt = AICFeature.GetPlayerStatValue("Level", 0), Now

            return CachedLevel
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

        --// Runs every frame, so it only touches what changes every frame. The
        --// position readout moved to the heartbeat's slower text tick.
        AICFeature.RenderUpdate = function(dt)
            local _, Humanoid = Runtime:GetCharacter()

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
