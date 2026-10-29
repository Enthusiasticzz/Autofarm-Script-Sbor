-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind can draw any mix of: an outline (Highlight), a box
-- (3D SelectionBox, or screen-space 2D / Corner frames), and a label.
-- Players are the models directly in workspace that have a Humanoid. Mobs are
-- the models in workspace.Mobs. Weapons are the Sword and Sword2 models on a
-- player, or the mob's Weapon model.
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

        local KINDS = { "Player", "Mob", "Weapon" }
        local TITLES = { Player = "Players", Mob = "Mobs", Weapon = "Weapons" }
        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        local S = {
            Kinds = {},
            Entries = {}, -- [Target] = { Kind, Instances, Screen?, Label? }
            Timer = 0,
        }
        for _, Kind in ipairs(KINDS) do
            S.Kinds[Kind] = {
                Enabled = false,
                Color = COLORS[Kind],
                Outline = true,
                Box = false,
                BoxStyle = "3D",
                Label = false,
            }
        end

        ----------------------------------------------------------------------
        -- Helpers
        ----------------------------------------------------------------------

        local function IsEnabled(Kind)
            return S.Kinds[Kind].Enabled
        end

        local function AnyEnabled()
            for _, Kind in ipairs(KINDS) do
                if IsEnabled(Kind) then return true end
            end
            return false
        end

        local function Remove(Target, Entry)
            for _, Item in ipairs(Entry.Instances) do
                pcall(function() Item:Destroy() end)
            end
            S.Entries[Target] = nil
        end

        local function Clear(Kind)
            for Target, Entry in pairs(S.Entries) do
                if Kind == nil or Entry.Kind == Kind then
                    Remove(Target, Entry)
                end
            end
        end

        --// Dropdowns and pickers may hand back a table or a plain value.
        local function Unwrap(Value)
            if type(Value) == "table" then
                return Value[1] or Value.Value or Value.Color
            end
            return Value
        end

        ----------------------------------------------------------------------
        -- Screen-space boxes (2D / Corner)
        ----------------------------------------------------------------------

        local Gui
        local CORNERS = {}
        for _, X in ipairs({ -0.5, 0.5 }) do
            for _, Y in ipairs({ -0.5, 0.5 }) do
                for _, Z in ipairs({ -0.5, 0.5 }) do
                    table.insert(CORNERS, Vector3.new(X, Y, Z))
                end
            end
        end

        --// One ScreenGui holds every 2D / Corner frame. It goes in a hidden
        --// UI container when one exists, otherwise PlayerGui.
        local function GetGui()
            if Gui and Gui.Parent then return Gui end

            local NewGui = Instance.new("ScreenGui")
            NewGui.Name = "AICEspScreen"
            NewGui.IgnoreGuiInset = true
            NewGui.ResetOnSpawn = false
            NewGui.DisplayOrder = 50

            local Parented = false
            if type(gethui) == "function" then
                Parented = pcall(function() NewGui.Parent = gethui() end) and NewGui.Parent ~= nil
            end
            if not Parented then
                local PlayerGui = Player:FindFirstChildOfClass("PlayerGui")
                if not PlayerGui then
                    NewGui:Destroy()
                    return nil
                end
                NewGui.Parent = PlayerGui
            end

            Gui = NewGui
            return Gui
        end

        --// Screen rectangle around a target, or nil when any corner is behind
        --// the camera (a half-visible box would be wrong, so it is hidden).
        local function ProjectBox(Target)
            local Camera = workspace.CurrentCamera
            if not Camera then return nil end

            local CF, Size = Target:GetBoundingBox()
            local MinX, MinY = math.huge, math.huge
            local MaxX, MaxY = -math.huge, -math.huge

            for _, Corner in ipairs(CORNERS) do
                local World = CF:PointToWorldSpace(Corner * Size)
                local Point = Camera:WorldToViewportPoint(World)
                if Point.Z <= 0 then return nil end
                MinX = math.min(MinX, Point.X)
                MinY = math.min(MinY, Point.Y)
                MaxX = math.max(MaxX, Point.X)
                MaxY = math.max(MaxY, Point.Y)
            end

            return MinX, MinY, MaxX, MaxY
        end

        local function HideFrames(Frames)
            for _, F in ipairs(Frames) do F.Visible = false end
        end

        local function UpdateScreenBoxes()
            for Target, Entry in pairs(S.Entries) do
                local Screen = Entry.Screen
                if Screen and Target.Parent then
                    local X1, Y1, X2, Y2 = ProjectBox(Target)
                    if not X1 then
                        HideFrames(Screen.Frames)
                    elseif Screen.Style == "2D" then
                        local F = Screen.Frames[1]
                        F.Visible = true
                        F.Position = UDim2.fromOffset(X1, Y1)
                        F.Size = UDim2.fromOffset(X2 - X1, Y2 - Y1)
                    else
                        local A = math.max(4, math.min(X2 - X1, Y2 - Y1) * 0.25)
                        local T = 2
                        local Segs = {
                            { X1, Y1, A, T }, { X1, Y1, T, A },
                            { X2 - A, Y1, A, T }, { X2 - T, Y1, T, A },
                            { X1, Y2 - T, A, T }, { X1, Y2 - A, T, A },
                            { X2 - A, Y2 - T, A, T }, { X2 - T, Y2 - A, T, A },
                        }
                        for I, F in ipairs(Screen.Frames) do
                            local Seg = Segs[I]
                            F.Visible = true
                            F.Position = UDim2.fromOffset(Seg[1], Seg[2])
                            F.Size = UDim2.fromOffset(Seg[3], Seg[4])
                        end
                    end
                end
            end
        end

        ----------------------------------------------------------------------
        -- Labels
        ----------------------------------------------------------------------

        local function PartOf(Target)
            return Target:FindFirstChild("Head")
                or Target.PrimaryPart
                or Target:FindFirstChildWhichIsA("BasePart")
        end

        --// Name, then level, EXP and HP where the game exposes them.
        --// Missing pieces are simply left out.
        local function LabelText(Target, Kind)
            local Lines = {}
            local Owner = Kind == "Player" and Players:GetPlayerFromCharacter(Target) or nil
            local Config = Kind == "Mob" and Target:FindFirstChild("Config") or nil
            local MobEntity = Config and Config:FindFirstChild("Entity")

            local Name = Owner and Owner.Name
                or (MobEntity and MobEntity:IsA("StringValue") and MobEntity.Value ~= "" and MobEntity.Value)
                or Target.Name
            table.insert(Lines, Name)

            if Owner then
                local Stats = Owner:FindFirstChild("PlayerStats")
                local LevelStat = Stats and Stats:FindFirstChild("Level")
                local ExpStat = Stats and Stats:FindFirstChild("EXP")
                local Level = LevelStat and tonumber(LevelStat.Value)
                if Level then
                    table.insert(Lines, "Lv " .. Level)
                    if ExpStat and type(AICUI.neededExp) == "function" then
                        local Needed = tonumber(AICUI.neededExp(Level)) or 0
                        table.insert(Lines, "EXP " .. math.floor(ExpStat.Value) .. "/" .. math.floor(Needed))
                    end
                end
            elseif Config then
                local LvlStat = Config:FindFirstChild("LVL")
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

        ----------------------------------------------------------------------
        -- Drawing
        ----------------------------------------------------------------------

        local function AddOutline(Entry, Target, C, Kind)
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

        --// One SelectionBox around the whole model. It is parented to the
        --// model itself so it is cleaned up with it.
        local function Add3DBox(Entry, Target, C, Kind)
            local Box = Instance.new("SelectionBox")
            Box.Name = "AICEspBox" .. Kind
            Box.Adornee = Target
            Box.Color3 = C.Color
            Box.LineThickness = 0.03
            Box.SurfaceTransparency = 1
            Box.Parent = Target
            table.insert(Entry.Instances, Box)
        end

        local function AddScreenBox(Entry, C)
            local ScreenGui = GetGui()
            if not ScreenGui then return end

            local Frames = {}
            local Count = C.BoxStyle == "Corner" and 8 or 1
            for _ = 1, Count do
                local F = Instance.new("Frame")
                F.BorderSizePixel = 0
                F.Visible = false
                if C.BoxStyle == "2D" then
                    F.BackgroundTransparency = 1
                    local Stroke = Instance.new("UIStroke")
                    Stroke.Color = C.Color
                    Stroke.Thickness = 1.5
                    Stroke.Parent = F
                else
                    F.BackgroundColor3 = C.Color
                end
                F.Parent = ScreenGui
                table.insert(Frames, F)
                table.insert(Entry.Instances, F)
            end
            Entry.Screen = { Style = C.BoxStyle, Frames = Frames }
        end

        --// A BillboardGui only renders under a part, so it lives on the head
        --// (or the first part found) rather than on the model.
        local function AddLabel(Entry, Target, C, Kind)
            local Part = PartOf(Target)
            if not Part then return end

            local LabelGui = Instance.new("BillboardGui")
            LabelGui.Name = "AICEspLabel" .. Kind
            LabelGui.Adornee = Part
            LabelGui.AlwaysOnTop = true
            LabelGui.Size = UDim2.fromOffset(180, 70)
            LabelGui.StudsOffset = Vector3.new(0, 3, 0)
            LabelGui.Parent = Part

            local Text = Instance.new("TextLabel")
            Text.BackgroundTransparency = 1
            Text.Size = UDim2.fromScale(1, 1)
            Text.TextColor3 = C.Color
            Text.TextStrokeTransparency = 0.4
            Text.Font = Enum.Font.GothamBold
            Text.TextSize = 12
            Text.TextYAlignment = Enum.TextYAlignment.Bottom
            Text.Text = LabelText(Target, Kind)
            Text.Parent = LabelGui

            Entry.Label = Text
            table.insert(Entry.Instances, LabelGui)
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Entries[Target] then return end

            local C = S.Kinds[Kind]
            local Entry = { Kind = Kind, Instances = {} }

            --// Each piece is built on its own so one failure can't stop the rest.
            if C.Outline then
                pcall(AddOutline, Entry, Target, C, Kind)
            end
            if C.Box then
                if C.BoxStyle == "3D" then
                    pcall(Add3DBox, Entry, Target, C, Kind)
                else
                    pcall(AddScreenBox, Entry, C)
                end
            end
            if C.Label then
                pcall(AddLabel, Entry, Target, C, Kind)
            end

            S.Entries[Target] = Entry
        end

        --// Drops entries whose target has gone, or whose kind is now off.
        local function Prune()
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent == nil or not IsEnabled(Entry.Kind) then
                    Remove(Target, Entry)
                end
            end
        end

        ----------------------------------------------------------------------
        -- Scanning
        ----------------------------------------------------------------------

        local function WeaponsOf(Character)
            local Weapons = {}
            for _, Name in ipairs({ "Sword", "Sword2" }) do
                local Weapon = Character:FindFirstChild(Name)
                if Weapon and Weapon:IsA("Model") then
                    table.insert(Weapons, Weapon)
                end
            end
            return Weapons
        end

        local function Scan()
            local WantPlayer = IsEnabled("Player")
            local WantMob = IsEnabled("Mob")
            local WantWeapon = IsEnabled("Weapon")

            if WantPlayer or WantWeapon then
                for _, Child in ipairs(workspace:GetChildren()) do
                    if Child:IsA("Model") and Child ~= Player.Character
                        and Child:FindFirstChildOfClass("Humanoid") then
                        if WantPlayer then
                            Mark(Child, "Player")
                        end
                        if WantWeapon then
                            for _, Weapon in ipairs(WeaponsOf(Child)) do
                                Mark(Weapon, "Weapon")
                            end
                        end
                    end
                end
            end

            if WantMob or WantWeapon then
                local Mobs = workspace:FindFirstChild("Mobs")
                if Mobs then
                    for _, Mob in ipairs(Mobs:GetChildren()) do
                        if Mob:IsA("Model") then
                            if WantMob then
                                Mark(Mob, "Mob")
                            end
                            if WantWeapon then
                                local Weapon = Mob:FindFirstChild("Weapon")
                                if Weapon and Weapon:IsA("Model") then
                                    Mark(Weapon, "Weapon")
                                end
                            end
                        end
                    end
                end
            end

            --// Labels are rewritten each scan so level, EXP and HP stay current.
            for Target, Entry in pairs(S.Entries) do
                if Entry.Label and Entry.Label.Parent and Target.Parent then
                    Entry.Label.Text = LabelText(Target, Entry.Kind)
                end
            end

            Prune()
        end

        ----------------------------------------------------------------------
        -- Feature
        ----------------------------------------------------------------------

        local Feature = {
            Name = "Esp",
            IsFeature = true,
            S = S,
        }

        function Feature:Update(DeltaTime)
            if not AnyEnabled() then return end

            UpdateScreenBoxes()

            S.Timer += DeltaTime
            if S.Timer < SCAN_INTERVAL then return end
            S.Timer = 0
            Scan()
        end

        local function SetKind(Kind, Value)
            S.Kinds[Kind].Enabled = Value == true
            --// Turning a kind off removes its drawings at once, not on the next scan.
            if not IsEnabled(Kind) then
                Clear(Kind)
            end
        end

        --// Changing any drawing option rebuilds that kind on the next scan,
        --// and a scan is forced so the change shows straight away.
        local function Rebuild(Kind)
            Clear(Kind)
            S.Timer = SCAN_INTERVAL
        end

        ----------------------------------------------------------------------
        -- UI
        ----------------------------------------------------------------------

        if UIRef.EspTab then
            for _, Kind in ipairs(KINDS) do
                local C = S.Kinds[Kind]
                local Sec = UIRef.EspTab:AddSection{ Title = TITLES[Kind] }

                Sec:AddToggle{
                    Name = Kind .. " ESP",
                    Bold = true,
                    Default = false,
                    Callback = function(Value)
                        SetKind(Kind, Value)
                        S.Timer = SCAN_INTERVAL
                    end,
                }
                Sec:AddToggle{
                    Name = Kind .. " outline",
                    Default = C.Outline,
                    Callback = function(Value)
                        C.Outline = Value == true
                        Rebuild(Kind)
                    end,
                }
                Sec:AddToggle{
                    Name = Kind .. " box",
                    Default = C.Box,
                    Callback = function(Value)
                        C.Box = Value == true
                        Rebuild(Kind)
                    end,
                }
                Sec:AddDropdown{
                    Name = Kind .. " box style",
                    Options = { "2D", "3D", "Corner" },
                    Default = C.BoxStyle,
                    Callback = function(Value)
                        Value = Unwrap(Value)
                        if Value == "2D" or Value == "3D" or Value == "Corner" then
                            C.BoxStyle = Value
                            Rebuild(Kind)
                        end
                    end,
                }
                Sec:AddToggle{
                    Name = Kind .. " label (level, EXP, HP)",
                    Default = C.Label,
                    Callback = function(Value)
                        C.Label = Value == true
                        Rebuild(Kind)
                    end,
                }
                Sec:AddColorPicker{
                    Name = Kind .. " colour",
                    Default = C.Color,
                    Callback = function(Color)
                        Color = Unwrap(Color)
                        if typeof(Color) == "Color3" then
                            C.Color = Color
                            Rebuild(Kind)
                        end
                    end,
                }
            end
        end

        Context.Lifetime.OnEnd(function()
            Clear()
            if Gui then Gui:Destroy() end
        end)

        return Feature
    end,
}