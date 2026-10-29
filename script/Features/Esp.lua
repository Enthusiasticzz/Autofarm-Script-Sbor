-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind can draw an outline (Highlight) and/or a 2D box.
-- Everything lives under one ScreenGui: the highlights sit in a folder inside
-- it, and the 2D boxes are Frames moved every render frame from the target's
-- projected bounding box.
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
        local Player = Context.Player
        local UIRef = Context.UIRef
        local RunService = game:GetService("RunService")

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
            Entries = {}, -- [Target] = { Kind, Highlight?, Frame?, Stroke? }
            Timer = 0,
        }
        for _, Kind in ipairs(KINDS) do
            S.Kinds[Kind] = {
                Enabled = false,
                Color = COLORS[Kind],
                Outline = true,
                Box = false,
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
        -- 2D boxes
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
        local function ProjectBox(Target)
            local Camera = workspace.CurrentCamera
            if not Camera then return nil end

            local Ok, CF, Size = pcall(Target.GetBoundingBox, Target)
            if not Ok then return nil end

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

        local function UpdateBoxes()
            for Target, Entry in pairs(S.Entries) do
                local Frame = Entry.Frame
                if Frame then
                    local X1, Y1, X2, Y2
                    if Target.Parent then
                        X1, Y1, X2, Y2 = ProjectBox(Target)
                    end
                    if X1 then
                        Frame.Position = UDim2.fromOffset(X1, Y1)
                        Frame.Size = UDim2.fromOffset(X2 - X1, Y2 - Y1)
                        Frame.Visible = true
                    else
                        Frame.Visible = false
                    end
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

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Entries[Target] then return end

            local C = S.Kinds[Kind]
            if not (C.Outline or C.Box) then return end

            local Entry = { Kind = Kind }

            --// Each piece is built on its own so one failure can't stop the other.
            if C.Outline then
                pcall(AddOutline, Entry, Target, C, Kind)
            end
            if C.Box then
                pcall(AddBox, Entry, C, Kind)
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

        --// Boxes follow the camera, so they move on RenderStepped rather than
        --// on the slower scan (otherwise they trail behind the target).
        local RenderConnection = RunService.RenderStepped:Connect(function()
            if AnyEnabled() then
                UpdateBoxes()
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

        --// Toggling outline or box rebuilds that kind on the next update.
        local function Rebuild(Kind)
            Clear(Kind)
            S.Timer = SCAN_INTERVAL
        end

        --// Colour changes are applied live, with no rebuild.
        local function Recolor(Kind)
            local Color = S.Kinds[Kind].Color
            for _, Entry in pairs(S.Entries) do
                if Entry.Kind == Kind then
                    if Entry.Highlight then Entry.Highlight.OutlineColor = Color end
                    if Entry.Stroke then Entry.Stroke.Color = Color end
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
                Sec:AddToggle{
                    Name = Kind .. " outline",
                    Default = C.Outline,
                    Callback = function(Value)
                        C.Outline = Value == true
                        Rebuild(Kind)
                    end,
                }
                Sec:AddToggle{
                    Name = Kind .. " 2D box",
                    Default = C.Box,
                    Callback = function(Value)
                        C.Box = Value == true
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