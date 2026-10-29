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
        local AICUI = Context.AICUI

        local SCAN_INTERVAL = 0.5

        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        local KINDS = { "Player", "Mob", "Weapon" }

        --// Per-kind settings. Each kind has its own on/off, colour, and the
        --// drawing style it uses: outline (Highlight), box, tracer, or label.
        local S = {
            Kinds = {},
            Highlights = {},   -- [Target] = { Kind = ..., Instance = Highlight }
            Timer = 0,
        }
        for _, Kind in ipairs(KINDS) do
            S.Kinds[Kind] = {
                Enabled = false,
                Color = COLORS[Kind],
                Outline = true,
                Box = false,
                Tracer = false,
                Label = false,
            }
        end

        local function Enabled(Kind)
            return S.Kinds[Kind].Enabled
        end

        local function AnyEnabled()
            for _, Kind in ipairs(KINDS) do
                if Enabled(Kind) then return true end
            end
            return false
        end

        local function ClearHighlights(Kind)
            for Target, Entry in pairs(S.Highlights) do
                if Kind == nil or Entry.Kind == Kind then
                    for _, Instance in ipairs(Entry.Instances) do
                        Instance:Destroy()
                    end
                    S.Highlights[Target] = nil
                end
            end
        end

        local function PartOf(Target)
            return Target:FindFirstChild("Head")
                or Target.PrimaryPart
                or Target:FindFirstChildWhichIsA("BasePart")
        end

        --// The text a label shows: name, then level, EXP and HP where the
        --// game exposes them. Missing pieces are simply left out.
        local function LabelText(Target, Kind)
            local Lines = {}
            local Owner = Kind == "Player" and Players:GetPlayerFromCharacter(Target) or nil
            table.insert(Lines, Owner and Owner.Name or Target.Name)

            local Level
            if Owner then
                local Stats = Owner:FindFirstChild("PlayerStats")
                local LevelStat = Stats and Stats:FindFirstChild("Level")
                local ExpStat = Stats and Stats:FindFirstChild("EXP")
                Level = LevelStat and tonumber(LevelStat.Value)
                if Level then
                    table.insert(Lines, "Lv " .. Level)
                end
                if ExpStat and type(AICUI.neededExp) == "function" and Level then
                    local Needed = tonumber(AICUI.neededExp(Level)) or 0
                    table.insert(Lines, "EXP " .. math.floor(ExpStat.Value) .. "/" .. math.floor(Needed))
                end
            elseif Kind == "Mob" then
                local Config = Target:FindFirstChild("Config")
                local LvlStat = Config and Config:FindFirstChild("LVL")
                if LvlStat then
                    table.insert(Lines, "Lv " .. tostring(LvlStat.Value))
                end
            end

            local Humanoid = Target:FindFirstChildOfClass("Humanoid")
            if Humanoid and Kind ~= "Weapon" then
                table.insert(Lines, "HP " .. math.floor(Humanoid.Health) .. "/" .. math.floor(Humanoid.MaxHealth))
            end

            return table.concat(Lines, "\n")
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Highlights[Target] then return end

            local C = S.Kinds[Kind]
            local Entry = { Kind = Kind, Instances = {} }

            if C.Outline then
                local Highlight = Instance.new("Highlight")
                Highlight.Name = "AICEsp" .. Kind
                Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                Highlight.FillTransparency = 1
                Highlight.OutlineColor = C.Color
                Highlight.OutlineTransparency = 0
                Highlight.Adornee = Target
                Highlight.Parent = Target
                table.insert(Entry.Instances, Highlight)
            end

            if C.Box then
                local Box = Instance.new("SelectionBox")
                Box.Name = "AICEspBox" .. Kind
                Box.Adornee = Target
                Box.Color3 = C.Color
                Box.LineThickness = 0.04
                Box.SurfaceTransparency = 1
                Box.AlwaysOnTop = true
                Box.Parent = Target
                table.insert(Entry.Instances, Box)
            end

            if C.Label then
                local Part = PartOf(Target)
                if Part then
                    local Gui = Instance.new("BillboardGui")
                    Gui.Name = "AICEspLabel" .. Kind
                    Gui.Adornee = Part
                    Gui.AlwaysOnTop = true
                    Gui.Size = UDim2.fromOffset(180, 70)
                    Gui.StudsOffset = Vector3.new(0, 3, 0)
                    Gui.Parent = Target

                    local Text = Instance.new("TextLabel")
                    Text.BackgroundTransparency = 1
                    Text.Size = UDim2.fromScale(1, 1)
                    Text.TextColor3 = C.Color
                    Text.TextStrokeTransparency = 0.4
                    Text.Font = Enum.Font.GothamBold
                    Text.TextSize = 12
                    Text.TextYAlignment = Enum.TextYAlignment.Bottom
                    Text.Text = LabelText(Target, Kind)
                    Text.Parent = Gui

                    Entry.Label = Text
                    table.insert(Entry.Instances, Gui)
                end
            end

            S.Highlights[Target] = Entry
        end

        --// Drops highlights whose target has gone, or whose kind is now off.
        local function Prune()
            for Target, Entry in pairs(S.Highlights) do
                if Target.Parent == nil or not Enabled(Entry.Kind) then
                    for _, Instance in ipairs(Entry.Instances) do
                        Instance:Destroy()
                    end
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

            if Enabled("Player") then
                for _, Child in ipairs(workspace:GetChildren()) do
                    if Child:IsA("Model") and Child ~= Player.Character
                        and Child:FindFirstChildOfClass("Humanoid") then
                        Wanted[Child] = "Player"
                    end
                end
            end

            if Enabled("Mob") then
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

            if Enabled("Weapon") then
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

            --// Labels are rewritten each scan so level, EXP and HP stay current.
            for Target, Entry in pairs(S.Highlights) do
                if Entry.Label and Target.Parent then
                    Entry.Label.Text = LabelText(Target, Entry.Kind)
                end
            end

            Prune()
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
            S.Kinds[Kind].Enabled = Value == true
            --// Turning a kind off removes its outlines at once, not on the next scan.
            if not Enabled(Kind) then
                ClearHighlights(Kind)
            end
        end

        if UIRef.EspSection then
            for _, Kind in ipairs(KINDS) do
                local C = S.Kinds[Kind]
                local Name = Kind

                UIRef.EspSection:AddToggle{
                    Name = Name .. " ESP",
                    Bold = true,
                    Default = false,
                    Callback = function(Value) SetKind(Kind, Value) end,
                }
                UIRef.EspSection:AddToggle{
                    Name = Name .. " outline",
                    Default = C.Outline,
                    Callback = function(Value) C.Outline = Value; ClearHighlights(Kind) end,
                }
                UIRef.EspSection:AddToggle{
                    Name = Name .. " box",
                    Default = C.Box,
                    Callback = function(Value) C.Box = Value; ClearHighlights(Kind) end,
                }
                UIRef.EspSection:AddToggle{
                    Name = Name .. " label (level, EXP, HP)",
                    Default = C.Label,
                    Callback = function(Value) C.Label = Value; ClearHighlights(Kind) end,
                }
                UIRef.EspSection:AddColorPicker{
                    Name = Name .. " colour",
                    Default = C.Color,
                    Callback = function(Color)
                        C.Color = Color
                        ClearHighlights(Kind)
                    end,
                }
            end
        end

        Context.Lifetime.OnEnd(ClearHighlights)

        return Feature
    end,
}
