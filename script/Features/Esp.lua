-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind draws either an outline (Highlight) or a 2D box, never
-- both, and can add a text label (name, level, EXP, HP, distance).
-- Everything lives under one ScreenGui: the highlights sit in a folder inside
-- it, and the boxes and labels are GUI objects moved every render frame from
-- the target's projected bounds.
--
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
        local RunService = game:GetService("RunService")

        local SCAN_INTERVAL = 0.5
        --// Box bounds are measured once and reused; the model only has to be
        --// measured again when it changes size (a respawn, a different rig).
        --// GetBoundingBox walks every part, so calling it per target per frame
        --// is what made mob boxes crawl behind their models.
        local MEASURE_INTERVAL = 1
        --// Nothing is drawn past this range: a box on the other side of the
        --// map is a few pixels and not worth projecting every frame.
        local MAX_DRAW_DISTANCE = 900

        local KINDS = { "Player", "Mob", "Weapon" }
        local TITLES = { Player = "Players", Mob = "Mobs", Weapon = "Weapons" }
        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        local S = {
            Kinds = {},
            Entries = {}, -- [Target] = { Kind, Highlight?, Frame?, Stroke?, Label?, ... }
            StyleToggles = {}, -- [Kind] = { Outline = toggle, Box = toggle }
            Timer = 0,
        }
        for _, Kind in ipairs(KINDS) do
            S.Kinds[Kind] = {
                Enabled = false,
                Color = COLORS[Kind],
                Outline = true,
                Box = false,
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
            if Entry.Highlight then pcall(function() Entry.Highlight:Destroy() end) end
            if Entry.Frame then pcall(function() Entry.Frame:Destroy() end) end
            if Entry.Label then pcall(function() Entry.Label:Destroy() end) end
            S.Entries[Target] = nil
        end

        local function Clear(Kind)
            for Target, Entry in pairs(S.Entries) do
                if Kind == nil or Entry.Kind == Kind then
                    Remove(Target, Entry)
                end
            end
        end

        ----------------------------------------------------------------------
        -- ScreenGui root
        ----------------------------------------------------------------------

        local Root, HighlightFolder

        local function TryParent(Gui, Parent)
            if not Parent then return false end
            local Ok = pcall(function() Gui.Parent = Parent end)
            return Ok and Gui.Parent == Parent
        end

        --// One ScreenGui holds everything. It goes in a hidden UI container
        --// when the executor has one, then CoreGui, then PlayerGui. If it is
        --// ever lost (PlayerGui reset, etc.) it is rebuilt and all entries
        --// are redrawn on the same scan.
        local function GetRoot()
            if Root and Root.Parent and HighlightFolder and HighlightFolder.Parent then
                return Root
            end

            if Root then
                pcall(function() Root:Destroy() end)
            end
            Root, HighlightFolder = nil, nil
            Clear()

            local Gui = Instance.new("ScreenGui")
            Gui.Name = "AICEsp"
            Gui.IgnoreGuiInset = true
            Gui.ResetOnSpawn = false
            Gui.ClipToDeviceSafeArea = false
            Gui.DisplayOrder = 999999

            local Parented = false
            if type(gethui) == "function" then
                local Ok, Hui = pcall(gethui)
                if Ok then Parented = TryParent(Gui, Hui) end
            end
            if not Parented then
                Parented = TryParent(Gui, game:GetService("CoreGui"))
            end
            if not Parented then
                Parented = TryParent(Gui, Player:FindFirstChildOfClass("PlayerGui"))
            end
            if not Parented then
                Gui:Destroy()
                return nil
            end

            local Folder = Instance.new("Folder")
            Folder.Name = "Outlines"
            Folder.Parent = Gui

            Root, HighlightFolder = Gui, Folder
            return Root
        end

        ----------------------------------------------------------------------
        -- Projection
        ----------------------------------------------------------------------

        local CORNERS = {}
        for _, X in ipairs({ -0.5, 0.5 }) do
            for _, Y in ipairs({ -0.5, 0.5 }) do
                for _, Z in ipairs({ -0.5, 0.5 }) do
                    table.insert(CORNERS, Vector3.new(X, Y, Z))
                end
            end
        end

        --// Screen rectangle around a target. Corners behind the camera are
        --// skipped (their projection is mirrored); nil when none are in front.
        local function Project(CF, Size, Camera)
            local MinX, MinY = math.huge, math.huge
            local MaxX, MaxY = -math.huge, -math.huge
            local InFront = 0

            for _, Corner in ipairs(CORNERS) do
                local Point = Camera:WorldToViewportPoint(CF:PointToWorldSpace(Corner * Size))
                if Point.Z > 0 then
                    InFront += 1
                    MinX = math.min(MinX, Point.X)
                    MinY = math.min(MinY, Point.Y)
                    MaxX = math.max(MaxX, Point.X)
                    MaxY = math.max(MaxY, Point.Y)
                end
            end

            if InFront == 0 then return nil end
            return MinX, MinY, MaxX, MaxY
        end

        --// The model's box relative to its pivot, so a moving (or turning)
        --// target only costs one GetPivot per frame instead of a full
        --// GetBoundingBox. Re-measured on the scan so a changed rig is picked
        --// up, with the size kept if a measurement fails.
        local function Measure(Target, Entry)
            Entry.NextMeasure = os.clock() + MEASURE_INTERVAL

            local Ok, CF, Size = pcall(Target.GetBoundingBox, Target)
            if not Ok or not CF then return end

            local OkPivot, Pivot = pcall(Target.GetPivot, Target)
            if not OkPivot then return end

            Entry.LocalCF = Pivot:ToObjectSpace(CF)
            Entry.Size = Size
        end

        local function DistanceTo(Target)
            local Camera = workspace.CurrentCamera
            if not Camera then return nil end
            local Ok, Pivot = pcall(Target.GetPivot, Target)
            if not Ok then return nil end
            return (Pivot.Position - Camera.CFrame.Position).Magnitude
        end

        ----------------------------------------------------------------------
        -- Labels
        ----------------------------------------------------------------------

        --// Name, then level, EXP and HP where the game exposes them, and the
        --// distance. Missing pieces are simply left out.
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
                    table.insert(Lines, "Lv " .. math.floor(Level))
                    if ExpStat and type(AICUI.neededExp) == "function" then
                        local Needed = tonumber(AICUI.neededExp(Level)) or 0
                        table.insert(Lines, "EXP " .. math.floor(ExpStat.Value) .. "/" .. math.floor(Needed))
                    end
                end
            elseif Config then
                local LvlStat = Config:FindFirstChild("LVL")
                local Level = LvlStat and tonumber(LvlStat.Value)
                if Level then
                    table.insert(Lines, "Lv " .. math.floor(Level))
                end
            end

            local Humanoid = Target:FindFirstChildOfClass("Humanoid")
            if Humanoid and Kind ~= "Weapon" then
                table.insert(Lines, "HP " .. math.floor(Humanoid.Health) .. "/" .. math.floor(Humanoid.MaxHealth))
            end

            local Distance = DistanceTo(Target)
            if Distance then
                table.insert(Lines, math.floor(Distance + 0.5) .. "m")
            end

            return table.concat(Lines, "\n")
        end

        --// Rewrites the text of every live label. Called on the scan, so HP
        --// and distance stay current without touching labels every frame.
        local function RefreshLabels()
            for Target, Entry in pairs(S.Entries) do
                local Label = Entry.Label
                if Label and Label.Parent and Target.Parent then
                    Label.Text = LabelText(Target, Entry.Kind)
                end
            end
        end

        ----------------------------------------------------------------------
        -- Drawing
        ----------------------------------------------------------------------

        local function AddOutline(Entry, Target, C, Kind)
            local Highlight = Instance.new("Highlight")
            Highlight.Name = Kind
            Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            Highlight.FillTransparency = 1
            Highlight.OutlineColor = C.Color
            Highlight.OutlineTransparency = 0
            Highlight.Adornee = Target
            Highlight.Parent = HighlightFolder
            Entry.Highlight = Highlight
        end

        local function AddBox(Entry, C, Kind)
            local Frame = Instance.new("Frame")
            Frame.Name = Kind .. "Box"
            Frame.BackgroundTransparency = 1
            Frame.BorderSizePixel = 0
            Frame.Visible = false
            Frame.ZIndex = 2

            local Stroke = Instance.new("UIStroke")
            Stroke.Color = C.Color
            Stroke.Thickness = 1.5
            Stroke.Parent = Frame

            Frame.Parent = Root
            Entry.Frame = Frame
            Entry.Stroke = Stroke
        end

        local function AddLabel(Entry, Target, C, Kind)
            local Text = Instance.new("TextLabel")
            Text.Name = Kind .. "Label"
            Text.BackgroundTransparency = 1
            Text.AnchorPoint = Vector2.new(0.5, 1)
            Text.Size = UDim2.fromOffset(240, 90)
            Text.TextColor3 = C.Color
            Text.TextStrokeTransparency = 0.4
            Text.Font = Enum.Font.GothamBold
            Text.TextSize = 12
            Text.TextYAlignment = Enum.TextYAlignment.Bottom
            Text.TextXAlignment = Enum.TextXAlignment.Center
            Text.Visible = false
            Text.ZIndex = 3
            Text.Text = LabelText(Target, Kind)
            Text.Parent = Root
            Entry.Label = Text
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Entries[Target] then return end

            local C = S.Kinds[Kind]
            if not (C.Outline or C.Box or C.Label) then return end

            local Entry = { Kind = Kind }

            --// Each piece is built on its own so one failure can't stop the other.
            if C.Outline then
                pcall(AddOutline, Entry, Target, C, Kind)
            end
            if C.Box then
                pcall(AddBox, Entry, C, Kind)
            end
            if C.Label then
                pcall(AddLabel, Entry, Target, C, Kind)
            end

            if Entry.Frame or Entry.Label then
                Measure(Target, Entry)
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
            if not GetRoot() then return end

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

            --// Bounds are re-measured here, and label text rewritten, so both
            --// follow the target without doing either every frame.
            local Now = os.clock()
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent then
                    if (Entry.Frame or Entry.Label)
                        and (not Entry.NextMeasure or Now >= Entry.NextMeasure) then
                        Measure(Target, Entry)
                    end
                end
            end

            RefreshLabels()
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

            S.Timer += DeltaTime
            if S.Timer < SCAN_INTERVAL then return end
            S.Timer = 0
            Scan()
        end

        --// Boxes and labels follow the camera, so they move on RenderStepped
        --// rather than on the slower scan (otherwise they trail the target).
        local function UpdateDrawings()
            local Camera = workspace.CurrentCamera
            if not Camera or not Root or not Root.Parent then return end

            local CameraPosition = Camera.CFrame.Position

            for Target, Entry in pairs(S.Entries) do
                local Frame, Label = Entry.Frame, Entry.Label
                if Frame or Label then
                    local X1, Y1, X2, Y2
                    local Ok, Pivot = pcall(Target.GetPivot, Target)

                    if Ok and Entry.LocalCF and Entry.Size
                        and (Pivot.Position - CameraPosition).Magnitude <= MAX_DRAW_DISTANCE then
                        X1, Y1, X2, Y2 = Project(Pivot * Entry.LocalCF, Entry.Size, Camera)
                    end

                    if Frame and Frame.Parent then
                        if X1 then
                            Frame.Position = UDim2.fromOffset(X1, Y1)
                            Frame.Size = UDim2.fromOffset(X2 - X1, Y2 - Y1)
                            Frame.Visible = true
                        else
                            Frame.Visible = false
                        end
                    end

                    if Label and Label.Parent then
                        if X1 then
                            Label.Position = UDim2.fromOffset((X1 + X2) / 2, Y1 - 4)
                            Label.Visible = true
                        else
                            Label.Visible = false
                        end
                    end
                end
            end
        end

        local RenderConnection = RunService.RenderStepped:Connect(function()
            if AnyEnabled() then
                UpdateDrawings()
            end
        end)

        local function SetKind(Kind, Value)
            S.Kinds[Kind].Enabled = Value == true
            if IsEnabled(Kind) then
                S.Timer = SCAN_INTERVAL
            else
                --// Turning a kind off removes its drawings at once.
                Clear(Kind)
            end
        end

        --// Toggling the style rebuilds that kind on the next update.
        local function Rebuild(Kind)
            Clear(Kind)
            S.Timer = SCAN_INTERVAL
        end

        --// Outline and 2D box are alternatives, not companions: picking one
        --// turns the other off (silently, so its toggle just repaints).
        local function SetStyle(Kind, Style)
            local C = S.Kinds[Kind]
            C.Outline = Style == "Outline"
            C.Box = Style == "Box"

            local Toggles = S.StyleToggles[Kind]
            if Toggles then
                if Toggles.Outline then Toggles.Outline:Set(C.Outline, true) end
                if Toggles.Box then Toggles.Box:Set(C.Box, true) end
            end

            Rebuild(Kind)
        end

        --// Colour changes are applied live, with no rebuild.
        local function Recolor(Kind)
            local Color = S.Kinds[Kind].Color
            for _, Entry in pairs(S.Entries) do
                if Entry.Kind == Kind then
                    if Entry.Highlight then Entry.Highlight.OutlineColor = Color end
                    if Entry.Stroke then Entry.Stroke.Color = Color end
                    if Entry.Label then Entry.Label.TextColor3 = Color end
                end
            end
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
                    Callback = function(Value) SetKind(Kind, Value) end,
                }

                local OutlineToggle = Sec:AddToggle{
                    Name = Kind .. " outline",
                    Default = C.Outline,
                    Callback = function(Value)
                        if Value then
                            SetStyle(Kind, "Outline")
                        else
                            C.Outline = false
                            Rebuild(Kind)
                        end
                    end,
                }
                local BoxToggle = Sec:AddToggle{
                    Name = Kind .. " 2D box",
                    Default = C.Box,
                    Callback = function(Value)
                        if Value then
                            SetStyle(Kind, "Box")
                        else
                            C.Box = false
                            Rebuild(Kind)
                        end
                    end,
                }
                S.StyleToggles[Kind] = { Outline = OutlineToggle, Box = BoxToggle }

                Sec:AddToggle{
                    Name = Kind .. " info text",
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
                        if type(Color) == "table" then
                            Color = Color.Color or Color.Value or Color[1]
                        end
                        if typeof(Color) == "Color3" then
                            C.Color = Color
                            Recolor(Kind)
                        end
                    end,
                }
            end
        end

        Context.Lifetime.OnEnd(function()
            RenderConnection:Disconnect()
            Clear()
            if Root then Root:Destroy() end
        end)

        return Feature
    end,
}
