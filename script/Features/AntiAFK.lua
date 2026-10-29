return {
    Name = "AntiAFK",
    IsFeature = true,
    Dependencies = {"Runtime"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local Replicated = Services.Replicated
        local StarterGui = Services.StarterGui
        local RunService = Services.RunService
        local PathfindingService = Services.PathfindingService
        local HttpService = Services.HttpService
        local CONFIG = Context.CONFIG
        local AICFeature = Context.AICFeature

        local Feature = {
            Name = "AntiAFK",
            IsFeature = true,
        }
        function Feature.SetupAntiAfk()
            local Ok, VirtualUser = pcall(function()
                return game:GetService("VirtualUser")
            end)
        
            if not Ok or not VirtualUser then
                return false
            end
        
            local function Nudge()
                pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new())
                end)
            end
        
            pcall(function()
                Context.Connect(Player.Idled, Nudge)
            end)
        
            --// Backstop on a timer as well, in case Idled does not fire in this
            --// environment. Far inside the twenty minute window either way.
            task.spawn(function()
                while Context.Lifetime.Alive do
                    task.wait(tonumber(CONFIG.ANTI_AFK_INTERVAL) or 480)

                    if not Context.Lifetime.Alive then
                        break
                    end

                    AICFeature.S.LastAntiAfkTime = os.clock()
                    Nudge()
                end
            end)
        
            return true
        end

        AICFeature.SetupAntiAfk = function(...) return Feature.SetupAntiAfk(...) end
        Feature.SetupAntiAfk()

        return Feature
    end,
}
