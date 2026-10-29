-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind draws either an outline (Highlight) or a 2D box, never
-- both, and can add a text label (name, level, EXP, HP, distance).
-- Outlines live in a folder inside one ScreenGui. Boxes and labels are drawn
-- with the executor's Drawing API when it has one, because a Drawing object
-- costs no GUI work per frame; otherwise they fall back to Frames and
-- TextLabels inside that same ScreenGui.
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
        local MEASURE_INTERVAL = 2
        --// Bounds re-measurement is spread over scans: doing every due mob in
        --// one frame put a visible hitch in the same frame, every interval.
        local MEASURE_PER_SCAN = 12
        --// Label text is rewritten this often from the render loop, so HP,
        --// EXP and the distance read live instead of at the scan's rate.
        local LABEL_INTERVAL = 0.25

        local KINDS = { "Player", "Mob", "Weapon" }
        local TITLES = { Player = "Players", Mob = "Mobs", Weapon = "Weapons" }
        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        local S = {
            Kinds = {},
            Entries = {}, -- [Target] = { Kind, Highlight?, Frame?, Stroke?, Label?, BoxLines?, DrawText?, ... }
            StyleToggles = {}, -- [Kind] = { Outline = toggle, Box = toggle }
            Settings = {
                Thickness = 1.5, -- box thickness at close range
                AutoThickness = true,
                Range = 900, -- studs; nothing past this is drawn
            },
            Timer = 0,
            LabelRefresh = 0,
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
            if Entry.BoxLines then
                for _, Line in ipairs(Entry.BoxLines) do
                    pcall(function() Line:Remove() end)
                end
            end
            if Entry.DrawText then pcall(function() Entry.DrawText:Remove() end) end
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

        --// One ScreenGui holds the highlights and, when there is no Drawing
        --// API, every box and label. It goes in a hidden UI container when the
        --// executor has one, then CoreGui, then PlayerGui. If it is ever lost
        --// (PlayerGui reset, etc.) it is rebuilt and all entries are redrawn on
        --// the same scan.
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
        -- Drawing API
        ----------------------------------------------------------------------

        --// Drawing draws straight to the screen instead of through the GUI, so
        --// a box costs four property writes a frame rather than a Frame, its
        --// UIStroke and a TextLabel each. It is an executor feature, so it is
        --// probed once and every piece falls back to the GUI on its own.
        local DrawingApi
        do
            local Ok, Api = pcall(function() return Drawing end)
            if Ok and Api and (type(Api) == "table" or type(Api) == "userdata") then
                local HasNew, NewFn = pcall(function() return Api.new end)
                if HasNew and type(NewFn) == "function" then
                    DrawingApi = Api
                end
            end
        end

        local LineSupported, TextSupported = false, false
        if DrawingApi then
            LineSupported = pcall(function()
                local Line = DrawingApi.new("Line")
                if not Line then error("no Line") end
                pcall(function() Line:Remove() end)
            end)
            TextSupported = pcall(function()
                local Text = DrawingApi.new("Text")
                if not Text then error("no Text") end
                pcall(function() Text:Remove() end)
            end)
        end

        local function NewLine()
            if not LineSupported then return nil end
            local Ok, Line = pcall(DrawingApi.new, "Line")
            if Ok then return Line end
            return nil
        end

        local function NewText()
            if not TextSupported then return nil end
            local Ok, Text = pcall(DrawingApi.new, "Text")
            if Ok then return Text end
            return nil
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

        --// A part the box can follow. Reading Model:GetPivot looks cheap but
        --// is only a single CFrame read when the model has a PrimaryPart: a
        --// mob rig usually does not, so the engine falls back to the model's
        --// stored pivot, which does not follow its parts. A cached part has
        --// the position of what is actually on screen.
        local function GetAnchor(Target)
            --// HumanoidRootPart first: it is the part the rest of this script
            --// already uses to follow a mob, so the box follows the same thing
            --// the AI does.
            local Root = Target:FindFirstChild("HumanoidRootPart")
            if Root and Root:IsA("BasePart") then return Root end

            if Target.PrimaryPart then return Target.PrimaryPart end

            for _, Name in ipairs({ "Torso", "UpperTorso", "Head" }) do
                local Candidate = Target:FindFirstChild(Name)
                if Candidate and Candidate:IsA("BasePart") then return Candidate end
            end

            return Target:FindFirstChildWhichIsA("BasePart")
        end

        --// The box is measured in world space and follows its anchor by
        --// translation only. GetBoundingBox is world-aligned, so a cached
        --// offset rotated with the mob would swing the box around its feet
        --// every time it turned, then snap back on the next measurement.
        local function Measure(Target, Entry)
            Entry.NextMeasure = os.clock() + MEASURE_INTERVAL

            local Anchor = GetAnchor(Target)
            Entry.Anchor = (Anchor and Anchor.Parent) and Anchor or nil

            local Ok, CF, Size = pcall(Target.GetBoundingBox, Target)
            if not Ok or not CF then
                Entry.BoxCF, Entry.Size, Entry.MeasurePoint = nil, nil, nil
                return
            end

            Entry.BoxCF = CF
            Entry.Size = Size
            Entry.MeasurePoint = Entry.Anchor and Entry.Anchor.Position or CF.Position
        end

        --// Thicker up close, thinner far away, so a box at 20 studs does not
        --// turn into one fat line at 400. The slider is the close-up width.
        local function ThicknessFor(Distance)
            local Base = S.Settings.Thickness
            if not S.Settings.AutoThickness or Distance == math.huge then
                return Base
            end
            return math.clamp(Base * (250 / math.max(Distance, 1)), 1, Base)
        end

        ----------------------------------------------------------------------
        -- Labels
        ----------------------------------------------------------------------

        --// Name, then level, EXP and HP where the game exposes them, and the
        --// distance. Missing pieces are simply left out.
        local function LabelText(Target, Kind, Entry)
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

            local Anchor = Entry and Entry.Anchor
            local Camera = workspace.CurrentCamera
            if Camera and Anchor and Anchor.Parent then
                local Distance = (Anchor.Position - Camera.CFrame.Position).Magnitude
                table.insert(Lines, math.floor(Distance + 0.5) .. "m")
            end

            return table.concat(Lines, "\n")
        end

        local function SetLabelText(Target, Kind, Entry)
            local Text = LabelText(Target, Kind, Entry)
            Entry.LabelLines = 1

            for _ in string.gmatch(Text, "\n") do
                Entry.LabelLines += 1
            end

            if Entry.DrawText then
                Entry.DrawText.Text = Text
            end
            if Entry.Label then
                Entry.Label.Text = Text
            end
        end

        --// Rewrites every live label from the render loop, so the numbers
        --// read live without re-projecting or rebuilding anything.
        local function RefreshLabels()
            for Target, Entry in pairs(S.Entries) do
                if (Entry.DrawText or Entry.Label) and Target.Parent then
                    SetLabelText(Target, Entry.Kind, Entry)
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
            --// Four Drawing lines, refusing the whole set if one cannot be
            --// made (an executor with a partial Drawing API falls back to a
            --// Frame instead of leaving half a box).
            if LineSupported then
                local Lines = {}
                for Index = 1, 4 do
                    local Line = NewLine()
                    if not Line then
                        for _, Created in ipairs(Lines) do
                            pcall(function() Created:Remove() end)
                        end
                        Lines = nil
                        break
                    end

                    Line.Color = C.Color
                    Line.Thickness = S.Settings.Thickness
                    Line.Transparency = 1
                    Line.Visible = false
                    Lines[Index] = Line
                end

                if Lines then
                    Entry.BoxLines = Lines
                    return
                end
            end

            local Frame = Instance.new("Frame")
            Frame.Name = Kind .. "Box"
            Frame.BackgroundTransparency = 1
            Frame.BorderSizePixel = 0
            Frame.Visible = false
            Frame.ZIndex = 2

            local Stroke = Instance.new("UIStroke")
            Stroke.Color = C.Color
            Stroke.Thickness = S.Settings.Thickness
            Stroke.Parent = Frame

            Frame.Parent = Root
            Entry.Frame = Frame
            Entry.Stroke = Stroke
        end

        local function AddLabel(Entry, Target, C, Kind)
            local DrawText = NewText()
            if DrawText then
                pcall(function()
                    DrawText.Color = C.Color
                    DrawText.Size = 13
                    DrawText.Center = true
                    DrawText.Transparency = 1
                    DrawText.Visible = false
                end)
                --// Outline is not on every executor's Text object.
                pcall(function() DrawText.Outline = true end)
                pcall(function() DrawText.OutlineColor = Color3.fromRGB(0, 0, 0) end)

                Entry.DrawText = DrawText
                SetLabelText(Target, Kind, Entry)
                return
            end

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
            Text.Parent = Root
            Entry.Label = Text
            SetLabelText(Target, Kind, Entry)
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Entries[Target] then return end

            local C = S.Kinds[Kind]
            if not (C.Outline or C.Box or C.Label) then return end

            local Entry = { Kind = Kind }

            --// Measured first so the label can carry the distance straight away.
            if C.Box or C.Label then
                Measure(Target, Entry)
            end

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

            --// Bounds are re-measured here, a few at a time, so a rig change
            --// is picked up without one frame paying for every mob.
            local Now = os.clock()
            local Measured = 0
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent and (Entry.Frame or Entry.BoxLines or Entry.Label or Entry.DrawText)
                    and (not Entry.NextMeasure or Now >= Entry.NextMeasure) then
                    if Measured >= MEASURE_PER_SCAN then break end
                    Measure(Target, Entry)
                    Measured += 1
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

            S.Timer += DeltaTime
            if S.Timer < SCAN_INTERVAL then return end
            S.Timer = 0
            Scan()
        end

        local function SetLine(Line, X1, Y1, X2, Y2)
            Line.From = Vector2.new(X1, Y1)
            Line.To = Vector2.new(X2, Y2)
        end

        --// Boxes and labels follow the camera, so they move on RenderStepped
        --// rather than on the slower scan (otherwise they trail the target).
        local function UpdateDrawings()
            local Camera = workspace.CurrentCamera
            if not Camera or not Root or not Root.Parent then return end

            local CameraPosition = Camera.CFrame.Position
            local Viewport = Camera.ViewportSize
            local Range = S.Settings.Range

            for _, Entry in pairs(S.Entries) do
                local Frame, Label = Entry.Frame, Entry.Label
                local Lines, DrawText = Entry.BoxLines, Entry.DrawText

                if Frame or Label or Lines or DrawText then
                    local X1, Y1, X2, Y2
                    local Anchor = Entry.Anchor
                    local Distance = math.huge

                    --// One live part is read per frame; the rest of the box is
                    --// the measurement cached on the scan.
                    if Anchor and Anchor.Parent then
                        Distance = (Anchor.Position - CameraPosition).Magnitude
                        if Entry.BoxCF and Entry.Size and Distance <= Range then
                            local BoxCF = Entry.BoxCF + (Anchor.Position - Entry.MeasurePoint)
                            X1, Y1, X2, Y2 = Project(BoxCF, Entry.Size, Camera)
                        end
                    end

                    --// Off-screen targets are hidden rather than moved, so a
                    --// busy zone does not pay for drawing it cannot show.
                    if X1 and (X2 < 0 or Y2 < 0 or X1 > Viewport.X or Y1 > Viewport.Y) then
                        X1 = nil
                    end

                    local Thickness = ThicknessFor(Distance)

                    if Lines then
                        if X1 then
                            SetLine(Lines[1], X1, Y1, X2, Y1)
                            SetLine(Lines[2], X2, Y1, X2, Y2)
                            SetLine(Lines[3], X2, Y2, X1, Y2)
                            SetLine(Lines[4], X1, Y2, X1, Y1)
                            for _, Line in ipairs(Lines) do
                                Line.Thickness = Thickness
                                Line.Visible = true
                            end
                        else
                            for _, Line in ipairs(Lines) do
                                Line.Visible = false
                            end
                        end
                    elseif Frame and Frame.Parent then
                        if X1 then
                            Frame.Position = UDim2.fromOffset(X1, Y1)
                            Frame.Size = UDim2.fromOffset(X2 - X1, Y2 - Y1)
                            Frame.Visible = true
                            if Entry.Stroke then Entry.Stroke.Thickness = Thickness end
                        else
                            Frame.Visible = false
                        end
                    end

                    if DrawText then
                        if X1 then
                            --// Center is both axes, so the block sits just
                            --// above the box: half a line per extra line.
                            local LineCount = Entry.LabelLines or 1
                            DrawText.Position = Vector2.new((X1 + X2) / 2, Y1 - 8 - LineCount * 7)
                            DrawText.Visible = true
                        else
                            DrawText.Visible = false
                        end
                    elseif Label and Label.Parent then
                        if X1 then
                            Label.Position = UDim2.fromOffset((X1 + X2) / 2, Y1 - 4)
                            Label.Visible = true
                        else
                            Label.Visible = false
                        end
                    end
                end
            end

            local Now = os.clock()
            if Now - S.LabelRefresh >= LABEL_INTERVAL then
                S.LabelRefresh = Now
                RefreshLabels()
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
                    if Entry.DrawText then Entry.DrawText.Color = Color end
                    if Entry.BoxLines then
                        for _, Line in ipairs(Entry.BoxLines) do
                            Line.Color = Color
                        end
                    end
                end
            end
        end

        ----------------------------------------------------------------------
        -- UI
        ----------------------------------------------------------------------

        if UIRef.EspTab then
            local SettingsSection = UIRef.EspTab:AddSection{ Title = "ESP Settings" }

            SettingsSection:AddSlider{
                Name = "Box thickness",
                Default = S.Settings.Thickness,
                Min = 1,
                Max = 6,
                Decimals = 1,
                Callback = function(Value)
                    S.Settings.Thickness = Value
                end,
            }
            SettingsSection:AddToggle{
                Name = "Auto thickness",
                Default = true,
                Callback = function(Value)
                    S.Settings.AutoThickness = Value == true
                end,
            }
            SettingsSection:AddSlider{
                Name = "Draw range",
                Default = S.Settings.Range,
                Min = 100,
                Max = 2000,
                Suffix = "m",
                Callback = function(Value)
                    S.Settings.Range = Value
                end,
            }

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
