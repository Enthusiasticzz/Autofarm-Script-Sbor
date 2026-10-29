-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Early version: each enabled kind gets a Highlight on the model it is about,
-- refreshed on a slow scan. Players are the models directly in workspace that
-- have a Humanoid. Mobs are the models in workspace.Mobs. Weapons are the
-- Sword and Sword2 models on a player, or the mob's Weapon model.
return {
    Name = "Esp",
    IsFeature = true,
    Dependencies = {
        "Runtime",
        "SaveConfig",
        "Components",
    },

    Start = function(Context)
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local UIRef = Context.UIRef

        local SCAN_INTERVAL = 0.5

        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        local S = {
            Enabled = {
                Player = false,
                Mob = false,
                Weapon = false,
            },
            Highlights = {},
            Timer = 0,
        }

        local function ClearHighlights()
            for _, Highlight in pairs(S.Highlights) do
                Highlight:Destroy()
            end
            S.Highlights = {}
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Highlights[Target] then return end

            local Highlight = Instance.new("Highlight")
            Highlight.Name = "AICEsp" .. Kind
            Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            Highlight.FillTransparency = 1
            Highlight.OutlineColor = COLORS[Kind]
            Highlight.OutlineTransparency = 0
            Highlight.Adornee = Target
            Highlight.Parent = Target
            S.Highlights[Target] = Highlight
        end

        --// Drops highlights whose target has gone, so the table does not grow.
        local function Prune()
            for Target, Highlight in pairs(S.Highlights) do
                if Target.Parent == nil then
                    Highlight:Destroy()
                    S.Highlights[Target] = nil
                end
            end
        end

        local function WeaponsOf(Character)
            local Weapons = {}
            if not Character then return Weapons end
            for _, Name in ipairs({ "Sword", "Sword2" }) do
                local Weapon = Character:FindFirstChild(Name)
                if Weapon and Weapon:IsA("Model") then
                    table.insert(Weapons, Weapon)
                end
            end
            return Weapons
        end

        local function Scan()
            local Wanted = {}

            if S.Enabled.Player then
                for _, Child in ipairs(workspace:GetChildren()) do
                    if Child:IsA("Model") and Child ~= Player.Character
                        and Child:FindFirstChildOfClass("Humanoid") then
                        Wanted[Child] = "Player"
                    end
                end
            end

            if S.Enabled.Mob then
                local Mobs = workspace:FindFirstChild("Mobs")
                if Mobs then
                    for _, Mob in ipairs(Mobs:GetChildren()) do
                        if Mob:IsA("Model") then
                            Wanted[Mob] = "Mob"
                        end
                    end
                end
            end

            for Target, Kind in pairs(Wanted) do
                Mark(Target, Kind)
            end

            if S.Enabled.Weapon then
                for _, Child in ipairs(workspace:GetChildren()) do
                    if Child:IsA("Model") and Child ~= Player.Character
                        and Child:FindFirstChildOfClass("Humanoid") then
                        for _, Weapon in ipairs(WeaponsOf(Child)) do
                            Mark(Weapon, "Weapon")
                        end
                    end
                end
                local Mobs = workspace:FindFirstChild("Mobs")
                if Mobs then
                    for _, Mob in ipairs(Mobs:GetChildren()) do
                        local Weapon = Mob:FindFirstChild("Weapon")
                        if Weapon and Weapon:IsA("Model") then
                            Mark(Weapon, "Weapon")
                        end
                    end
                end
            end

            Prune()
        end

        local function AnyEnabled()
            return S.Enabled.Player or S.Enabled.Mob or S.Enabled.Weapon
        end

        local Feature = {
            Name = "Esp",
            IsFeature = true,
            S = S,
        }

        function Feature:Update(DeltaTime)
            if not AnyEnabled() then return end
            S.Timer += DeltaTime
            if S.Timer < SCAN_INTERVAL then return end
            S.Timer = 0
            Scan()
        end

        local function SetKind(Kind, Value)
            S.Enabled[Kind] = Value == true
            if not AnyEnabled() then
                ClearHighlights()
            end
        end

        if UIRef.EspSection then
            UIRef.EspSection:AddToggle{
                Name = "Player ESP",
                Default = false,
                Callback = function(Value) SetKind("Player", Value) end,
            }
            UIRef.EspSection:AddToggle{
                Name = "Mob ESP",
                Default = false,
                Callback = function(Value) SetKind("Mob", Value) end,
            }
            UIRef.EspSection:AddToggle{
                Name = "Weapon ESP",
                Default = false,
                Callback = function(Value) SetKind("Weapon", Value) end,
            }
        end

        Context.Lifetime.OnEnd(ClearHighlights)

        return Feature
    end,
}
