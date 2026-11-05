-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind draws either a projected body contour or a 2D box, never
-- both. Name and health form a compact block above the box; level, mob EXP
-- and distance share one line below it. Drawing lines follow the readable
-- Blissful reference implementations; menu rectangles clip only covered line
-- segments. GUI labels and the no-Drawing fallback live below the menu layer.
-- Optional Smooth mode uses native Highlight on body-only mesh copies; the
-- original contour renderer stays the default and the creation-error fallback.
--
-- The box look follows the reference ESPs: a black backing behind a thinner
-- coloured box, and corner brackets instead of a closed box if that style is
-- picked.
--
-- Players include the local character, so Player outline also outlines you.
-- Characters are models directly in workspace that have a Humanoid. Mobs are
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
        local CONFIG = Context.CONFIG
        local SaveConfig = Context.SaveConfig
        local AICProfile = Context.AICProfile
        local RunService = game:GetService("RunService")

        local SCAN_INTERVAL = 0.5
        --// A target is measured once. Measuring walks every part of the rig,
        --// and re-measuring a good box is what made it change shape and jump.
        --// Only a target with no usable measurement is measured again, and
        --// only a few of those per scan, so a rig that was still spawning
        --// when it was first seen is picked up without a hitch.
        local MEASURE_PER_SCAN = 12
        --// Label text is refreshed this often from the render loop, so it
        --// reads live instead of at the scan's rate.
        local LABEL_INTERVAL = 0.25
        local OUTLINE_BUDGET = 24 -- Bound per-frame body projection work.
        --// Every piece of text is the same pixel size at any distance, like
        --// the popular ESP libraries. Change this one number to resize all
        --// of it.
        local TEXT_SIZE = 14

        local KINDS = { "Player", "Mob", "Weapon" }
        local TITLES = { Player = "Players", Mob = "Mobs", Weapon = "Weapons" }
        local COLORS = {
            Player = Color3.fromRGB(80, 200, 255),
            Mob = Color3.fromRGB(255, 90, 90),
            Weapon = Color3.fromRGB(255, 200, 60),
        }

        --// The two box looks from the references: a closed box, or eight
        --// brackets that only draw the corners.
        local BOX_STYLES = { "Full box", "Corners" }
        local BOX_STYLE_KEYS = { ["Full box"] = "Full", Corners = "Corners", Full = "Full" }
        local BOX_STYLE_NAMES = { Full = "Full box", Corners = "Corners" }

        local BLACK = Color3.fromRGB(0, 0, 0)

        local S = {
            Kinds = {},
            --// [Target] = { Kind, BoxStyle, BodyParts?, ContourLines?, BoxLines?, BoxShadow?,
            --//              Frame?, Stroke?, TextParts?, Anchor?,
            --//              BoxHeight?/BoxWidth?/BoxOffsetY? }
            Entries = {},
            StyleToggles = {}, -- [Kind] = { Outline = toggle, Box = toggle }
            Settings = {
                Thickness = 1.5, -- box thickness at close range
                AutoThickness = true,
                Range = 900, -- studs; nothing past this is drawn
                BoxStyle = "Full",
                OutlineRenderer = "Contour",
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
        -- Saved settings
        ----------------------------------------------------------------------

        --// Everything the ESP tab can change is a SaveConfig setting, so it
        --// is written with the profile and restored on the next execution.
        local ENABLED_KEYS = {
            Player = "ESP_PLAYER_ENABLED",
            Mob = "ESP_MOB_ENABLED",
            Weapon = "ESP_WEAPON_ENABLED",
        }
        local STYLE_KEYS = {
            Player = "ESP_PLAYER_STYLE",
            Mob = "ESP_MOB_STYLE",
            Weapon = "ESP_WEAPON_STYLE",
        }
        local TEXT_KEYS = {
            Player = "ESP_PLAYER_TEXT",
            Mob = "ESP_MOB_TEXT",
            Weapon = "ESP_WEAPON_TEXT",
        }

        local function ReadSetting(Key, Fallback)
            local Entry = SaveConfig and SaveConfig.GetSetting(Key)
            if not Entry then return Fallback end
            return SaveConfig.NormalizeSetting(Entry, CONFIG and CONFIG[Key])
        end

        local function SaveSetting(Key, Value)
            if CONFIG then CONFIG[Key] = Value end
            if AICProfile and type(AICProfile.QueueProfileSave) == "function" then
                AICProfile.QueueProfileSave()
            end
        end

        local function HexToColor(Hex, Fallback)
            if type(Hex) ~= "string" then return Fallback end
            local Clean = string.upper((string.gsub(Hex, "#", "")))
            if not string.match(Clean, "^%x%x%x%x%x%x$") then return Fallback end
            return Color3.fromRGB(
                tonumber(string.sub(Clean, 1, 2), 16),
                tonumber(string.sub(Clean, 3, 4), 16),
                tonumber(string.sub(Clean, 5, 6), 16)
            )
        end

        local SavedColors = { Player = "50C8FF", Mob = "FF5A5A", Weapon = "FFC83C" }

        --// Filled in by the UI below, so a profile restored after this module
        --// has started can put the loaded values back on the controls.
        local Controls = {
            Kinds = {},
            Text = {},
            Colors = {},
        }

        local function SaveStyle(Kind)
            local C = S.Kinds[Kind]
            SaveSetting(STYLE_KEYS[Kind], C.Box and "Box" or (C.Outline and "Outline" or "None"))
        end

        local function SaveColor(Kind, Color)
            SavedColors[Kind] = string.format(
                "%02X%02X%02X",
                math.floor(Color.R * 255 + 0.5),
                math.floor(Color.G * 255 + 0.5),
                math.floor(Color.B * 255 + 0.5)
            )
            SaveSetting("ESP_COLORS", SavedColors)
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

        local function RemoveSmooth(Entry)
            if Entry.SmoothModel then Entry.SmoothModel:Destroy() end
            Entry.SmoothModel, Entry.SmoothHighlight, Entry.SmoothParts, Entry.SmoothActive = nil, nil, nil, nil
        end

        local function Remove(Target, Entry)
            RemoveSmooth(Entry)
            if Entry.Frame then pcall(function() Entry.Frame:Destroy() end) end
            if Entry.ShadowFrame then pcall(function() Entry.ShadowFrame:Destroy() end) end
            if Entry.TextParts then
                for _, Part in ipairs(Entry.TextParts) do
                    if Part.Draw then pcall(function() Part.Draw:Remove() end) end
                    if Part.Gui then pcall(function() Part.Gui:Destroy() end) end
                end
            end
            for _, Key in ipairs({ "BoxLines", "BoxShadow", "ContourLines", "ContourShadow" }) do
                local List = Entry[Key]
                if List then
                    for _, Object in ipairs(List) do
                        pcall(function() Object:Remove() end)
                    end
                end
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

        ----------------------------------------------------------------------
        -- Loaded settings
        ----------------------------------------------------------------------

        --// Reads every ESP setting back into the live state and repaints the
        --// controls. Called at start and again whenever a profile is loaded,
        --// since the profile is restored after the features have started.
        local function LoadSettings()
            local Colors = ReadSetting("ESP_COLORS", nil)
            if type(Colors) == "table" then
                SavedColors = Colors
            end

            S.Settings.Thickness = ReadSetting("ESP_THICKNESS", S.Settings.Thickness)
            S.Settings.AutoThickness = ReadSetting("ESP_AUTO_THICKNESS", S.Settings.AutoThickness) == true
            S.Settings.Range = ReadSetting("ESP_RANGE", S.Settings.Range)
            S.Settings.BoxStyle = BOX_STYLE_KEYS[ReadSetting("ESP_BOX_STYLE", nil) or ""] or "Full"
            S.Settings.OutlineRenderer = ReadSetting("ESP_OUTLINE_RENDERER", "Contour") == "Smooth" and "Smooth" or "Contour"

            for _, Kind in ipairs(KINDS) do
                local C = S.Kinds[Kind]
                local Style = ReadSetting(STYLE_KEYS[Kind], "Outline")

                C.Enabled = ReadSetting(ENABLED_KEYS[Kind], false) == true
                C.Outline = Style ~= "Box" and Style ~= "None"
                C.Box = Style == "Box"
                C.Label = ReadSetting(TEXT_KEYS[Kind], false) == true
                C.Color = HexToColor(SavedColors[Kind], COLORS[Kind])

                local StyleToggles = S.StyleToggles[Kind]
                if StyleToggles then
                    if StyleToggles.Outline then StyleToggles.Outline:Set(C.Outline, true) end
                    if StyleToggles.Box then StyleToggles.Box:Set(C.Box, true) end
                end

                if Controls.Kinds[Kind] then Controls.Kinds[Kind]:Set(C.Enabled, true) end
                if Controls.Text[Kind] then Controls.Text[Kind]:Set(C.Label, true) end
                if Controls.Colors[Kind] then Controls.Colors[Kind]:Set(C.Color, true) end
            end

            if Controls.BoxStyle then Controls.BoxStyle:Set(BOX_STYLE_NAMES[S.Settings.BoxStyle], true) end
            if Controls.OutlineRenderer then Controls.OutlineRenderer:Set(S.Settings.OutlineRenderer == "Smooth" and "Smooth (experimental)" or "Body contour", true) end
            if Controls.Thickness then Controls.Thickness:Set(S.Settings.Thickness, true) end
            if Controls.AutoThickness then Controls.AutoThickness:Set(S.Settings.AutoThickness, true) end
            if Controls.Range then Controls.Range:Set(S.Settings.Range, true) end

            --// A loaded profile may change a style or colour, so redraw.
            Clear()
            S.Timer = SCAN_INTERVAL
        end

        LoadSettings()

        ----------------------------------------------------------------------
        -- ScreenGui root
        ----------------------------------------------------------------------

        local Root

        local function TryParent(Gui, Parent)
            if not Parent then return false end
            local Ok = pcall(function() Gui.Parent = Parent end)
            return Ok and Gui.Parent == Parent
        end

        --// One ScreenGui holds labels and the no-Drawing fallback edges.
        --// It goes in the same UI container as the menu when
        --// the executor has one, then CoreGui, then PlayerGui.
        --// If it is ever lost (PlayerGui reset, etc.) it is rebuilt and all
        --// entries are redrawn on the same scan.
        local function GetRoot()
            if Root and Root.Parent then
                return Root
            end

            if Root then
                pcall(function() Root:Destroy() end)
            end
            Root = nil
            Clear()

            local Gui = Instance.new("ScreenGui")
            Gui.Name = "AICEsp"
            Gui.IgnoreGuiInset = true
            Gui.ResetOnSpawn = false
            Gui.ClipToDeviceSafeArea = false
            local Menu = Context.UI and Context.UI.Gui
            Gui.DisplayOrder = Menu and ((tonumber(Menu.DisplayOrder) or 1000) - 1) or 900

            local Parented = Menu and TryParent(Gui, Menu.Parent) or false
            if not Parented and type(gethui) == "function" then
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

            Root = Gui
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

        --// Players and mobs get a box that never changes shape. Its size was
        --// measured once (see MeasureUpright), so each frame only the centre
        --// moves: the top and bottom of that fixed height are projected, and
        --// the width follows the on-screen height. Turning, animating or
        --// changing camera angle can't stretch it.
        local function ProjectUpright(Position, Entry, Camera)
            local Center = Position + Vector3.new(0, Entry.BoxOffsetY, 0)
            local Half = Vector3.new(0, Entry.BoxHeight * 0.5, 0)

            local Top = Camera:WorldToViewportPoint(Center + Half)
            local Bottom = Camera:WorldToViewportPoint(Center - Half)
            if Top.Z <= 0 or Bottom.Z <= 0 then return nil end

            local MinY, MaxY = math.min(Top.Y, Bottom.Y), math.max(Top.Y, Bottom.Y)
            local Height = MaxY - MinY
            if Height < 1 then return nil end

            local HalfWidth = Height * (Entry.BoxWidth / Entry.BoxHeight) * 0.5
            local CenterX = (Top.X + Bottom.X) * 0.5
            return CenterX - HalfWidth, MinY, CenterX + HalfWidth, MaxY
        end

        --// A part the box can follow. Humanoid.RootPart is the engine's own
        --// answer for a character rig; the name lookup covers rigs that have
        --// no Humanoid, and the rest is a last resort. The box keeps whatever
        --// part it gets, so the choice has to be the same every time.
        local function GetAnchor(Target)
            local Humanoid = Target:FindFirstChildOfClass("Humanoid")
            local RootPart = Humanoid and Humanoid.RootPart

            if not (RootPart and RootPart.Parent) then
                RootPart = Target:FindFirstChild("HumanoidRootPart")
            end
            if not (RootPart and RootPart.Parent) then
                RootPart = Target.PrimaryPart
            end
            if RootPart and RootPart.Parent and RootPart:IsA("BasePart") then return RootPart end

            for _, Name in ipairs({ "Torso", "UpperTorso", "Head" }) do
                local Candidate = Target:FindFirstChild(Name)
                if Candidate and Candidate:IsA("BasePart") then return Candidate end
            end

            return Target:FindFirstChildWhichIsA("BasePart")
        end

        --// Size of a target, taken once. Every part is measured in a frame
        --// that only copies the anchor's turn around the vertical axis, so it
        --// makes no difference which way the model was facing when it was
        --// measured. Width is the larger of the two horizontal extents, which
        --// is why turning later can't change it. The vertical offset is how
        --// far the middle of the model sits above or below the anchor.
        local function MeasureUpright(Target, Anchor, Entry)
            local Origin = Anchor.CFrame.Position
            local Look = Anchor.CFrame.LookVector
            local Flat = Vector3.new(Look.X, 0, Look.Z)
            local Frame = Flat.Magnitude > 0.001
                and CFrame.lookAt(Origin, Origin + Flat)
                or CFrame.new(Origin)

            local MinX, MinY, MinZ = math.huge, math.huge, math.huge
            local MaxX, MaxY, MaxZ = -math.huge, -math.huge, -math.huge
            local Found = false
            local Parts = 0

            --// Invisible parts (hitboxes, the root part, effect holders) are
            --// left out, so the box hugs what can actually be seen. Only a
            --// model with nothing visible falls back to measuring everything.
            local Descendants = Target:GetDescendants()
            for Pass = 1, 2 do
                for _, Part in ipairs(Descendants) do
                    if Part:IsA("BasePart") and (Pass == 2 or Part.Transparency < 1) then
                        Found = true
                        Parts += 1
                        for _, Corner in ipairs(CORNERS) do
                            local Point = Frame:PointToObjectSpace(Part.CFrame:PointToWorldSpace(Corner * Part.Size))
                            MinX, MaxX = math.min(MinX, Point.X), math.max(MaxX, Point.X)
                            MinY, MaxY = math.min(MinY, Point.Y), math.max(MaxY, Point.Y)
                            MinZ, MaxZ = math.min(MinZ, Point.Z), math.max(MaxZ, Point.Z)
                        end
                    end
                end
                if Found then break end
            end

            if not Found or MaxY - MinY < 0.1 then return false end

            --// A rig that is still spawning measures as a stub: one part, a
            --// couple of studs tall. Storing that would leave a box far too
            --// small for the life of the target, so it is refused and tried
            --// again on a later scan. A genuinely small model is accepted
            --// after a few tries.
            if Entry.Kind ~= "Weapon" and (Parts < 2 or MaxY - MinY < 2)
                and (Entry.MeasureTries or 0) < 4 then
                return false
            end

            Entry.BoxHeight = MaxY - MinY
            Entry.BoxWidth = math.max(MaxX - MinX, MaxZ - MinZ, 0.5)
            Entry.BoxOffsetY = (MinY + MaxY) * 0.5
            return true
        end

        --// Measures a target once. The anchor is resolved here and then kept:
        --// the offsets belong to that part, and swapping the anchor for a
        --// different one (a limb, the head) would leave the box riding at the
        --// new part's offset, which reads as the box sitting beside the model.
        local function Measure(Target, Entry)
            local Anchor = Entry.Anchor
            if not (Anchor and Anchor.Parent) then
                Anchor = GetAnchor(Target)
                if not (Anchor and Anchor.Parent) then
                    Entry.Anchor = nil
                    return
                end

                --// A new part means the old offsets no longer apply.
                if Entry.Anchor ~= Anchor then
                    Entry.BoxHeight, Entry.BoxWidth, Entry.BoxOffsetY = nil, nil, nil
                end
                Entry.Anchor = Anchor
            end

            if Entry.BoxHeight then return end

            Entry.MeasureTries = (Entry.MeasureTries or 0) + 1
            MeasureUpright(Target, Anchor, Entry)
        end

        ----------------------------------------------------------------------
        -- Look
        ----------------------------------------------------------------------

        --// Thicker up close, thinner far away: the reference boxes taper the
        --// same way (their formula is 1/distance*100). The slider is the
        --// close-up width, so it stays the ceiling.
        local function ThicknessFor(Distance)
            local Base = S.Settings.Thickness
            if not S.Settings.AutoThickness or Distance == math.huge then
                return Base
            end

            --// math.clamp errors when the minimum is above the maximum, so a
            --// thickness saved below 1 must not reach it as the upper bound.
            local Ceiling = math.max(Base, 1)
            return math.clamp(Base * (250 / math.max(Distance, 1)), 1, Ceiling)
        end

        --// Corner brackets grow as the target gets closer, like the reference
        --// corner ESP (clamp(1/distance*750, 2, 300), scaled down to fit a
        --// box that is already on screen).
        local function CornerLength(Distance)
            if Distance == math.huge then return 8 end
            return math.clamp(600 / math.max(Distance, 1), 8, 40)
        end

        local function TextSizeFor()
            return TEXT_SIZE
        end

        --// One segment of the box, written as four numbers so the render loop
        --// allocates nothing per target per frame.
        local function SegmentAt(Style, Index, X1, Y1, X2, Y2, Arm)
            if Style == "Corners" then
                if Index == 1 then return X1, Y1, X1 + Arm, Y1 end
                if Index == 2 then return X1, Y1, X1, Y1 + Arm end
                if Index == 3 then return X2, Y1, X2 - Arm, Y1 end
                if Index == 4 then return X2, Y1, X2, Y1 + Arm end
                if Index == 5 then return X1, Y2, X1 + Arm, Y2 end
                if Index == 6 then return X1, Y2, X1, Y2 - Arm end
                if Index == 7 then return X2, Y2, X2 - Arm, Y2 end
                return X2, Y2, X2, Y2 - Arm
            end

            if Index == 1 then return X1, Y1, X2, Y1 end
            if Index == 2 then return X2, Y1, X2, Y2 end
            if Index == 3 then return X2, Y2, X1, Y2 end
            return X1, Y2, X1, Y1
        end

        ----------------------------------------------------------------------
        -- Labels
        ----------------------------------------------------------------------

        --// The EXP a mob gives is Config.EXP, which every mob in the game's
        --// dump carries. The rest are fallbacks for a place that names it
        --// differently; add one here if a mob's EXP never shows.
        local MOB_EXP_NAMES = { "EXP", "Exp", "XP", "ExpGive", "EXPGive", "ExpReward", "EXPReward", "Experience" }

        local function FindMobExp(Target, Config)
            for _, Name in ipairs(MOB_EXP_NAMES) do
                local Child = Config and Config:FindFirstChild(Name)
                if Child and Child:IsA("ValueBase") and tonumber(Child.Value) then
                    return function() return tonumber(Child.Value) end
                end
                for _, Holder in ipairs({ Config, Target }) do
                    if Holder and tonumber(Holder:GetAttribute(Name)) then
                        return function() return tonumber(Holder:GetAttribute(Name)) end
                    end
                end
            end
            return nil
        end

        --// The label is split into four pieces that sit around the box: Name
        --// and Hp (each centred on its own) above it, Right is the level
        --// (and, for a mob, the EXP it gives), Bottom is the distance.
        --// Missing pieces are left out.
        local function LabelParts(Target, Kind, Entry)
            local Owner = Kind == "Player" and Players:GetPlayerFromCharacter(Target) or nil
            local Config = Kind == "Mob" and Target:FindFirstChild("Config") or nil
            local MobEntity = Config and Config:FindFirstChild("Entity")

            local Name = Owner and Owner.Name
                or (MobEntity and MobEntity:IsA("StringValue") and MobEntity.Value ~= "" and MobEntity.Value)
                or Target.Name

            local Hp = ""
            local Humanoid = Target:FindFirstChildOfClass("Humanoid")
            if Humanoid and Kind ~= "Weapon" then
                Hp = math.floor(Humanoid.Health) .. " / " .. math.floor(Humanoid.MaxHealth) .. " HP"
            end

            local Right = {}

            if Owner then
                local Stats = Owner:FindFirstChild("PlayerStats")
                local LevelStat = Stats and Stats:FindFirstChild("Level")
                local Level = LevelStat and tonumber(LevelStat.Value)
                if Level then
                    table.insert(Right, "Lv " .. math.floor(Level))
                end
            elseif Config then
                local LvlStat = Config:FindFirstChild("LVL")
                local Level = LvlStat and tonumber(LvlStat.Value)
                if Level then
                    table.insert(Right, "Lv " .. math.floor(Level))
                end

                --// Found once and remembered, so it is not searched for on
                --// every refresh.
                if not Entry.ExpRead and os.clock() >= (Entry.ExpRetry or 0) then
                    Entry.ExpRead = FindMobExp(Target, Config)
                    Entry.ExpRetry = os.clock() + 2
                end
                local Exp = Entry.ExpRead and Entry.ExpRead()
                if Exp then
                    table.insert(Right, "EXP " .. math.floor(Exp))
                end
            end

            local Bottom = ""
            local Anchor = Entry and Entry.Anchor
            local Camera = workspace.CurrentCamera
            if Camera and Anchor and Anchor.Parent then
                local Distance = (Anchor.Position - Camera.CFrame.Position).Magnitude
                Bottom = math.floor(Distance + 0.5) .. " studs"
            end

            if Bottom ~= "" then table.insert(Right, Bottom) end
            local Ratio = Humanoid and Humanoid.MaxHealth > 0 and math.clamp(Humanoid.Health / Humanoid.MaxHealth, 0, 1) or 1
            return { Name = Name, Hp = Hp, Bottom = table.concat(Right, "  ·  "), HealthRatio = Ratio }
        end

        local function SetLabelText(Target, Kind, Entry)
            if not Entry.TextParts then return end
            local Texts = LabelParts(Target, Kind, Entry)
            Entry.HasHp = (Texts.Hp or "") ~= ""

            for _, Part in ipairs(Entry.TextParts) do
                local Text = Texts[Part.Key] or ""
                Part.Empty = Text == ""
                Part.Color = Part.Key == "Name" and S.Kinds[Kind].Color
                    or (Part.Key == "Hp" and Color3.fromRGB(245, 105, 105):Lerp(Color3.fromRGB(120, 225, 155), Texts.HealthRatio))
                    or Color3.fromRGB(220, 225, 235)

                Part.Lines = 1
                for _ in string.gmatch(Text, "\n") do
                    Part.Lines += 1
                end

                -- Text.Position is the top of Drawing text, not its centre.
                -- Cache its width on the text tick for viewport-safe placement.
                Part.Width = math.max(30, #Text * TEXT_SIZE * .58)
                if Part.Draw then
                    Part.Draw.Text = Text
                    Part.Draw.Color = Part.Color
                    pcall(function() Part.Width = math.max(30, Part.Draw.TextBounds.X) end)
                end
                if Part.Gui then
                    Part.Gui.Text = Text
                    Part.Gui.TextColor3 = Part.Color
                end
            end
        end

        --// Rewrites every live label from the render loop, so the numbers
        --// read live without re-projecting anything.
        local function RefreshLabels()
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent and Entry.TextParts then
                    SetLabelText(Target, Entry.Kind, Entry)
                end
            end
        end

        ----------------------------------------------------------------------
        -- Building the pieces
        ----------------------------------------------------------------------

        -- The readable Blissful references use Drawing.Line, with an opaque
        -- black backing and a thinner colored line. Keep that executor path.
        local DrawingApi
        do
            local Ok, Api = pcall(function() return Drawing end)
            if Ok and Api then
                local Created, Probe = pcall(function() return Api.new("Line") end)
                if Created and Probe then
                    Probe.Visible = false
                    Probe:Remove()
                    DrawingApi = Api
                end
            end
        end
        local ActiveOccluders = {}

        local function Subtract(Intervals, First, Last, Result)
            table.clear(Result)
            for I = 1, #Intervals, 2 do
                local A, B = Intervals[I], Intervals[I+1]
                if Last <= A or First >= B then
                    table.insert(Result, A); table.insert(Result, B)
                else
                    if First > A then table.insert(Result, A); table.insert(Result, First) end
                    if Last < B then table.insert(Result, Last); table.insert(Result, B) end
                end
            end
            return Result
        end

        -- Interval inside a convex, counterclockwise polygon. This is used
        -- for both menu clipping and removing seams between body-part hulls.
        local function InsideInterval(A, B, Polygon, Inset)
            local First, Last = 0, 1
            local DX, DY = B.X - A.X, B.Y - A.Y
            for Index, P in ipairs(Polygon) do
                local Q = Polygon[Index % #Polygon + 1]
                local EX, EY = Q.X - P.X, Q.Y - P.Y
                local F = EX * (A.Y - P.Y) - EY * (A.X - P.X) - (Inset or 0)
                local D = EX * DY - EY * DX
                if math.abs(D) < .00001 then
                    if F < 0 then return nil end
                elseif D > 0 then First = math.max(First, -F / D)
                else Last = math.min(Last, -F / D) end
                if First >= Last then return nil end
            end
            return First, Last
        end

        local function DisposeLines(List)
            if not List then return end
            for _, Line in ipairs(List) do
                pcall(function() Line:Remove() end)
            end
        end

        local function MakeLines(Count, Color, Thickness)
            local List = {}
            for Index = 1, Count do
                if DrawingApi then
                    local Data = { Color = Color, Thickness = Thickness, Objects = {},
                        Intervals = {}, Scratch = {}, Polygon = { {}, {}, {}, {} } }
                    local function ObjectAt(I)
                        if not Data.Objects[I] then
                            local Object = DrawingApi.new("Line")
                            Object.Transparency, Object.Visible = 1, false
                            pcall(function() Object.ZIndex = Color == BLACK and 1 or 2 end)
                            Data.Objects[I] = Object
                        end
                        return Data.Objects[I]
                    end
                    ObjectAt(1)
                    Data.Remove = function()
                        for _, Object in ipairs(Data.Objects) do Object:Remove() end
                    end
                    List[Index] = setmetatable({}, {
                        __index = Data,
                        __newindex = function(_, Key, Value)
                            Data[Key] = Value
                            if Key ~= "Visible" then return end
                            local Intervals, Scratch = Data.Intervals, Data.Scratch
                            table.clear(Intervals)
                            if Value and Data.From and Data.To then
                                Intervals[1], Intervals[2] = 0, 1
                                for _, Rect in ipairs(ActiveOccluders) do
                                    local Pad = Data.Thickness * .5 + 1
                                    local Polygon = Data.Polygon
                                    Polygon[1].X, Polygon[1].Y = Rect[1]-Pad, Rect[2]-Pad
                                    Polygon[2].X, Polygon[2].Y = Rect[3]+Pad, Rect[2]-Pad
                                    Polygon[3].X, Polygon[3].Y = Rect[3]+Pad, Rect[4]+Pad
                                    Polygon[4].X, Polygon[4].Y = Rect[1]-Pad, Rect[4]+Pad
                                    local First, Last = InsideInterval(Data.From, Data.To, Polygon)
                                    if First then
                                        Subtract(Intervals, First, Last, Scratch)
                                        Intervals, Scratch = Scratch, Intervals
                                    end
                                    if #Intervals == 0 then break end
                                end
                            end
                            for I = 1, #Intervals, 2 do
                                local Object = ObjectAt((I+1)/2)
                                local Delta = Data.To - Data.From
                                Object.From = Data.From + Delta * Intervals[I]
                                Object.To = Data.From + Delta * Intervals[I+1]
                                Object.Color, Object.Thickness = Data.Color, Data.Thickness
                                Object.Visible = true
                            end
                            for I = #Intervals/2 + 1, #Data.Objects do Data.Objects[I].Visible = false end
                        end,
                    })
                else
                local Frame = Instance.new("Frame")
                Frame.Name = "EspEdge"
                Frame.BorderSizePixel = 0
                Frame.BackgroundColor3 = Color
                Frame.AnchorPoint = Vector2.new(0, .5)
                Frame.Visible = false
                Frame.ZIndex = Color == BLACK and 1 or 2
                Frame.Parent = Root
                local Data = { Gui = Frame, Thickness = Thickness, Length = 0 }
                local Line = setmetatable({}, {
                    __index = Data,
                    __newindex = function(_, Key, Value)
                        Data[Key] = Value
                        if Key == "Visible" then Frame.Visible = Value
                        elseif Key == "Color" then Frame.BackgroundColor3 = Value
                        elseif Key == "Thickness" then Frame.Size = UDim2.fromOffset(Data.Length, Value)
                        end
                    end,
                })
                Data.Remove = function() Frame:Destroy() end
                List[Index] = Line
                end
            end
            return List
        end

        -- Player contours use only direct rig limbs, never equipment meshes.
        -- R15 matches the character tree; R6 names retain classic-rig support.
        local PLAYER_BODY_PARTS = {
            Head = true, UpperTorso = true, LowerTorso = true,
            LeftUpperArm = true, LeftLowerArm = true, LeftHand = true,
            RightUpperArm = true, RightLowerArm = true, RightHand = true,
            LeftUpperLeg = true, LeftLowerLeg = true, LeftFoot = true,
            RightUpperLeg = true, RightLowerLeg = true, RightFoot = true,
            Torso = true, ["Left Arm"] = true, ["Right Arm"] = true,
            ["Left Leg"] = true, ["Right Leg"] = true,
        }

        local function AddOutline(Entry, Target, C, Kind)
            -- DrawingLib Chams.lua projects actual body-part corners. Use those
            -- same parts, with boundary lines instead of filled faces. Never
            -- depend on a native Highlight pass to make outline mode visible.
            local Parts = {}
            for _, Part in ipairs(Target:GetDescendants()) do
                local Allowed = Kind ~= "Player" or (Part.Parent == Target and PLAYER_BODY_PARTS[Part.Name] == true)
                if Allowed and Part:IsA("BasePart") and Part.Name ~= "HumanoidRootPart" and Part.Transparency < 1 then
                    local Parent, Excluded = Part.Parent, false
                    while Parent and Parent ~= Target do
                        if Kind ~= "Weapon" and (Parent:IsA("Accessory") or Parent:IsA("Tool")
                            or Parent.Name == "Sword" or Parent.Name == "Sword2" or Parent.Name == "Weapon") then
                            Excluded = true
                            break
                        end
                        Parent = Parent.Parent
                    end
                    if not Excluded then table.insert(Parts, Part) end
                    if #Parts >= 24 then break end
                end
            end
            Entry.BodyParts = Parts
            if Entry.HullCache then
                for Part in pairs(Entry.HullCache) do
                    if not table.find(Parts, Part) then Entry.HullCache[Part] = nil end
                end
            end
        end

        local function EnsureOutline(Entry, Target, C, Kind)
            local Camera, Anchor = workspace.CurrentCamera, Entry.Anchor
            local InRange = Camera and Anchor and Anchor.Parent
                and (Anchor.Position - Camera.CFrame.Position).Magnitude <= S.Settings.Range
                and (not Entry.Humanoid or Entry.Humanoid.Health > 0)
            if not InRange then
                RemoveSmooth(Entry)
                Entry.BodyParts = nil
                Entry.HullCache, Entry.Hulls = nil, nil
                DisposeLines(Entry.ContourLines)
                DisposeLines(Entry.ContourShadow)
                Entry.ContourLines, Entry.ContourShadow = nil, nil
                return
            end
            local Ok, Error = pcall(AddOutline, Entry, Target, C, Kind)
            if not Ok and not Entry.OutlineError then
                warn("[AIC] ESP outline failed for " .. tostring(Target.Name) .. ": " .. tostring(Error))
            end
            Entry.OutlineError = not Ok and tostring(Error) or nil
        end

        local function AddBox(Entry, Target, C, Kind)
            local Style = S.Settings.BoxStyle
            local Count = Style == "Corners" and 8 or 4

            --// The black backing is made first so the coloured box is drawn
            --// on top of it: that two-layer edge is the reference look.
            local Shadow = MakeLines(Count, BLACK, S.Settings.Thickness + 2)
            local Lines = Shadow and MakeLines(Count, C.Color, S.Settings.Thickness)

            if Lines and Shadow then
                Entry.BoxLines, Entry.BoxShadow, Entry.BoxStyle = Lines, Shadow, Style
            else
                DisposeLines(Lines)
                DisposeLines(Shadow)
                Entry.BoxStyle = "Full"

                local ShadowFrame = Instance.new("Frame")
                ShadowFrame.Name = Kind .. "BoxShadow"
                ShadowFrame.BackgroundTransparency = 1
                ShadowFrame.BorderSizePixel = 0
                ShadowFrame.Visible = false
                ShadowFrame.ZIndex = 1
                local ShadowStroke = Instance.new("UIStroke")
                ShadowStroke.Color = BLACK
                ShadowStroke.Thickness = S.Settings.Thickness + 2
                ShadowStroke.Parent = ShadowFrame
                ShadowFrame.Parent = Root

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

                Entry.Frame, Entry.Stroke = Frame, Stroke
                Entry.ShadowFrame, Entry.ShadowStroke = ShadowFrame, ShadowStroke
            end
        end

        --// One text object per piece. Weapons only have a name and a
        --// distance, so they get no HP or right-hand piece.
        local function AddLabel(Entry, Target, C, Kind)
            local Keys = Kind == "Weapon" and { "Name", "Bottom" } or { "Name", "Hp", "Bottom" }
            Entry.TextParts = {}

            for _, Key in ipairs(Keys) do
                local Part = { Key = Key, Lines = 1, Empty = true }

                do
                    local Text = Instance.new("TextLabel")
                    Text.Name = Kind .. Key .. "Label"
                    Text.BackgroundTransparency = 1
                    Text.TextColor3 = C.Color
                    Text.TextStrokeColor3 = BLACK
                    Text.TextStrokeTransparency = 0
                    Text.Font = Key == "Name" and Enum.Font.GothamBold or Enum.Font.GothamMedium
                    Text.TextSize = TEXT_SIZE
                    Text.Visible = false
                    Text.ZIndex = 3

                    Text.AnchorPoint = Vector2.new(0.5, 0)
                    Text.Size = UDim2.fromOffset(340, TEXT_SIZE + 4)
                    Text.TextXAlignment = Enum.TextXAlignment.Center
                    Text.TextYAlignment = Enum.TextYAlignment.Top
                    Text.TextTruncate = Enum.TextTruncate.AtEnd

                    Text.Parent = Root
                    Part.Gui = Text
                end

                table.insert(Entry.TextParts, Part)
            end

            SetLabelText(Target, Kind, Entry)
        end

        local function Mark(Target, Kind)
            if not Target or Target.Parent == nil then return end
            if S.Entries[Target] then return end

            local C = S.Kinds[Kind]
            if not (C.Outline or C.Box or C.Label) then return end

            local Entry = { Kind = Kind, Humanoid = Target:FindFirstChildOfClass("Humanoid"),
                Owner = Kind == "Player" and Players:GetPlayerFromCharacter(Target) or nil }

            --// Measured first so the label can carry the distance straight away.
            if C.Box or C.Label or C.Outline then
                Measure(Target, Entry)
            end

            --// Each piece is built on its own so one failure can't stop the other.
            if C.Outline then
                EnsureOutline(Entry, Target, C, Kind)
            end
            if C.Box then
                pcall(AddBox, Entry, Target, C, Kind)
            end
            if C.Label then
                pcall(AddLabel, Entry, Target, C, Kind)
            end

            S.Entries[Target] = Entry
        end

        --// Drops entries whose target has gone, or whose kind is now off.
        local function Prune()
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent == nil or not IsEnabled(Entry.Kind)
                    or (Entry.Owner and Entry.Owner.Character ~= Target) then
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
                -- The roster includes your own rig and nested character models;
                -- NPCs must not use up the player outlines' native render slots.
                for _, Owner in ipairs(Players:GetPlayers()) do
                    local Child = Owner.Character
                    if Child and Child.Parent and Child:IsA("Model") then
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

            --// Only targets without a usable measurement are measured here,
            --// a few per scan, so a rig that was still spawning when it was
            --// first seen is picked up without one frame paying for every mob.
            local Measured = 0
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent and (Entry.BoxHeight == nil or not Entry.Anchor or not Entry.Anchor.Parent)
                    and (Entry.Frame or Entry.BoxLines or Entry.TextParts or Entry.BodyParts) then
                    if Measured >= MEASURE_PER_SCAN then break end
                    Measure(Target, Entry)
                    Measured += 1
                end
            end

            Prune()
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent and S.Kinds[Entry.Kind].Outline then
                    if not Entry.Humanoid or not Entry.Humanoid.Parent then
                        Entry.Humanoid = Target:FindFirstChildOfClass("Humanoid")
                    end
                    EnsureOutline(Entry, Target, S.Kinds[Entry.Kind], Entry.Kind)
                end
            end
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
            if Line.Gui then
                local DX, DY = X2 - X1, Y2 - Y1
                Line.Length = math.sqrt(DX * DX + DY * DY)
                Line.Gui.Position = UDim2.fromOffset(X1, Y1)
                Line.Gui.Size = UDim2.fromOffset(Line.Length, Line.Thickness)
                Line.Gui.Rotation = math.deg(math.atan2(DY, DX))
                return
            end
            Line.From = Vector2.new(X1, Y1)
            Line.To = Vector2.new(X2, Y2)
        end

        local function Cross(A, B, C)
            return (B.X-A.X)*(C.Y-A.Y) - (B.Y-A.Y)*(C.X-A.X)
        end

        local function ProjectHull(Part, Camera, Cache)
            if Cache.Camera == Camera and Cache.View == Camera.CFrame and Cache.Frame == Part.CFrame
                and Cache.Size == Part.Size and Cache.Viewport == Camera.ViewportSize
                and Cache.Fov == Camera.FieldOfView and Cache.FovMode == Camera.FieldOfViewMode then
                return Cache.Valid and Cache.Hull or nil
            end
            Cache.Camera, Cache.View, Cache.Frame = Camera, Camera.CFrame, Part.CFrame
            Cache.Size, Cache.Viewport = Part.Size, Camera.ViewportSize
            Cache.Fov, Cache.FovMode, Cache.Valid = Camera.FieldOfView, Camera.FieldOfViewMode, false
            local Points, Hull = Cache.Points, Cache.Hull
            table.clear(Hull)
            for I, Corner in ipairs(CORNERS) do
                local P = Camera:WorldToViewportPoint(Part.CFrame:PointToWorldSpace(Corner * Part.Size))
                if P.Z <= .05 then return nil end
                local Point = Points[I]
                if not Point then Point = {}; Points[I] = Point end
                Point.X, Point.Y = P.X, P.Y
            end
            table.sort(Points, function(A,B) return A.X < B.X or (A.X == B.X and A.Y < B.Y) end)
            for _, P in ipairs(Points) do
                while #Hull >= 2 and Cross(Hull[#Hull-1], Hull[#Hull], P) <= 0 do table.remove(Hull) end
                table.insert(Hull, P)
            end
            local Lower = #Hull
            for I = #Points-1, 1, -1 do
                local P = Points[I]
                while #Hull > Lower and Cross(Hull[#Hull-1], Hull[#Hull], P) <= 0 do table.remove(Hull) end
                table.insert(Hull, P)
            end
            table.remove(Hull)
            Cache.Valid = #Hull >= 3
            return Cache.Valid and Hull or nil
        end

        local function DrawContour(Entry, Camera, Show, Thickness)
            Entry.ContourLines = Entry.ContourLines or {}
            Entry.ContourShadow = Entry.ContourShadow or {}
            Entry.Hulls = Entry.Hulls or {}
            Entry.HullCache = Entry.HullCache or {}
            Entry.Intervals = Entry.Intervals or {}
            Entry.IntervalScratch = Entry.IntervalScratch or {}
            local Hulls = Entry.Hulls
            table.clear(Hulls)
            if Show then
                for _, Part in ipairs(Entry.BodyParts or {}) do
                    if Part.Parent then
                        local Cache = Entry.HullCache[Part]
                        if not Cache then Cache = { Points = {}, Hull = {} }; Entry.HullCache[Part] = Cache end
                        local Hull = ProjectHull(Part, Camera, Cache)
                        if Hull then
                            local X1,Y1,X2,Y2 = math.huge,math.huge,-math.huge,-math.huge
                            for _, P in ipairs(Hull) do
                                X1,Y1,X2,Y2 = math.min(X1,P.X),math.min(Y1,P.Y),math.max(X2,P.X),math.max(Y2,P.Y)
                            end
                            local Hidden = false
                            for _, Rect in ipairs(ActiveOccluders) do
                                if X1-Thickness>=Rect[1] and Y1-Thickness>=Rect[2]
                                    and X2+Thickness<=Rect[3] and Y2+Thickness<=Rect[4] then Hidden=true; break end
                            end
                            if not Hidden then table.insert(Hulls, Hull) end
                        end
                    end
                end
            end
            local Count, Color = 0, S.Kinds[Entry.Kind].Color
            for Index, Hull in ipairs(Hulls) do
                for I, A in ipairs(Hull) do
                    local B = Hull[I % #Hull + 1]
                    local Intervals, Scratch = Entry.Intervals, Entry.IntervalScratch
                    table.clear(Intervals)
                    Intervals[1], Intervals[2] = 0, 1
                    for OtherIndex, Other in ipairs(Hulls) do
                        if Index ~= OtherIndex then
                            local First, Last = InsideInterval(A, B, Other, .0001)
                            if First then
                                Subtract(Intervals, First, Last, Scratch)
                                Intervals, Scratch = Scratch, Intervals
                            end
                            if #Intervals == 0 then break end
                        end
                    end
                    for J = 1, #Intervals, 2 do
                        local DX, DY = B.X-A.X, B.Y-A.Y
                        local PX, PY = A.X+DX*Intervals[J], A.Y+DY*Intervals[J]
                        local QX, QY = A.X+DX*Intervals[J+1], A.Y+DY*Intervals[J+1]
                        if (QX-PX)^2 + (QY-PY)^2 >= .25 then
                            Count += 1
                            if not Entry.ContourLines[Count] then
                                Entry.ContourShadow[Count] = MakeLines(1, BLACK, Thickness+2)[1]
                                Entry.ContourLines[Count] = MakeLines(1, Color, Thickness)[1]
                            end
                            local Back, Line = Entry.ContourShadow[Count], Entry.ContourLines[Count]
                            Back.Thickness, Line.Thickness, Line.Color = Thickness+2, Thickness, Color
                            SetLine(Back, PX, PY, QX, QY)
                            SetLine(Line, PX, PY, QX, QY)
                            Back.Visible, Line.Visible = true, true
                        end
                    end
                end
            end
            for I = Count+1, #Entry.ContourLines do
                Entry.ContourLines[I].Visible = false
                Entry.ContourShadow[I].Visible = false
            end
        end

        -- Native Highlight follows the actual mesh silhouette. A separate,
        -- body-only model excludes equipment without touching the live rig.
        -- The contour renderer remains available if native rendering fails.
        local SmoothFolder
        local function DrawSmooth(Entry, Show)
            if not Show then RemoveSmooth(Entry); return false end
            if Entry.SmoothFailed then return false end
            local Ok, Error = pcall(function()
                if not SmoothFolder or not SmoothFolder.Parent then
                    SmoothFolder = Instance.new("Folder")
                    SmoothFolder.Name = "GildedEspBodies"
                    SmoothFolder.Parent = workspace
                end
                if not Entry.SmoothModel then
                    local Model = Instance.new("Model")
                    Entry.SmoothModel, Entry.SmoothParts, Entry.SmoothActive = Model, {}, {}
                    Model.Name = "EspBody"
                    -- A humanoid lets the native character highlight pass handle
                    -- nearly transparent body meshes; it never controls a rig.
                    local Humanoid = Instance.new("Humanoid")
                    Humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                    Humanoid.EvaluateStateMachine = false
                    Humanoid.Parent = Model
                    local Highlight = Instance.new("Highlight")
                    Highlight.Adornee = Model
                    Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    Highlight.FillTransparency = 1
                    Highlight.OutlineTransparency = 0
                    Highlight.Enabled = false
                    Highlight.Parent = Model
                    Entry.SmoothHighlight = Highlight
                end
                local Parts, Active = Entry.SmoothParts, Entry.SmoothActive
                table.clear(Active)
                for _, Part in ipairs(Entry.BodyParts or {}) do
                    if Part.Parent then
                        Active[Part] = true
                        local Copy = Parts[Part]
                        if not Copy then
                            Copy = assert(Part:Clone(), "body part cannot be cloned")
                            Parts[Part] = Copy
                            -- Keep mesh geometry only. No joints, effects,
                            -- textures, equipment or scripts enter workspace.
                            for _, Child in ipairs(Copy:GetDescendants()) do
                                if not Child:IsA("DataModelMesh") and not Child:IsA("Bone") then Child:Destroy() end
                            end
                            Copy.Anchored, Copy.CanCollide, Copy.CanTouch, Copy.CanQuery = true, false, false, false
                            Copy.CastShadow, Copy.LocalTransparencyModifier = false, 0
                            Copy.Transparency = .99
                            Copy.Material = Enum.Material.SmoothPlastic
                            Copy.Parent = Entry.SmoothModel
                        end
                        Copy.CFrame, Copy.Size = Part.CFrame, Part.Size
                    end
                end
                for Part, Copy in pairs(Parts) do
                    if not Active[Part] then Copy:Destroy(); Parts[Part] = nil end
                end
                assert(next(Parts), "no body meshes to outline")
                Entry.SmoothModel.Parent = SmoothFolder
                Entry.SmoothHighlight.OutlineColor = S.Kinds[Entry.Kind].Color
                Entry.SmoothHighlight.Enabled = true
            end)
            if not Ok then
                RemoveSmooth(Entry)
                Entry.SmoothFailed = true
                warn("[AIC] Smooth ESP unavailable; using body contour: " .. tostring(Error))
            end
            return Ok
        end

        local function MenuBounds()
            local UI = Context.UI
            if UI and not UI.Destroyed and type(UI.GetOcclusionRects) == "function" then
                return UI:GetOcclusionRects()
            end
            if not UI or UI.Destroyed or not UI.Root or not UI.Gui
                or not UI.Gui.Enabled or not UI.Root.Visible then return {} end
            local At, Size = UI.Root.AbsolutePosition, UI.Root.AbsoluteSize
            if not At or not Size or Size.X <= 0 or Size.Y <= 0 then return {} end
            return { { At.X, At.Y, At.X + Size.X, At.Y + Size.Y } }
        end

        local function Covered(X1, Y1, X2, Y2, Rects)
            for _, Rect in ipairs(Rects) do
                if X1 >= Rect[1] and Y1 >= Rect[2] and X2 <= Rect[3] and Y2 <= Rect[4] then return true end
            end
            return false
        end

        local function HideDrawings()
            for _, Entry in pairs(S.Entries) do
                if Entry.SmoothHighlight then Entry.SmoothHighlight.Enabled = false end
                if Entry.Frame then Entry.Frame.Visible = false end
                if Entry.ShadowFrame then Entry.ShadowFrame.Visible = false end
                for _, Lines in ipairs({ Entry.BoxLines or {}, Entry.BoxShadow or {}, Entry.ContourLines or {}, Entry.ContourShadow or {} }) do
                    for _, Line in ipairs(Lines) do Line.Visible = false end
                end
                for _, Part in ipairs(Entry.TextParts or {}) do
                    if Part.Draw then Part.Draw.Visible = false end
                    if Part.Gui then Part.Gui.Visible = false end
                end
            end
        end

        --// Boxes and labels follow the camera, so they move on RenderStepped
        --// rather than on the slower scan (otherwise they trail the target).
        local function UpdateDrawings()
            local Camera = workspace.CurrentCamera
            -- Drawing objects cannot be placed behind a ScreenGui by ZIndex.
            -- The full-screen intro hides everything; the menu hides only
            -- overlapping targets/labels, leaving the rest of the world visible.
            if (Context.Startup and not Context.Startup.IntroDone) or not Camera then
                HideDrawings()
                return
            end
            --// Drawing needs no ScreenGui, so a lost Root must not stop the
            --// box and text layers; the GUI pieces check their own parent.

            local CameraPosition = Camera.CFrame.Position
            local Viewport = Camera.ViewportSize
            local Range = S.Settings.Range
            local Occluders = MenuBounds()
            ActiveOccluders = Occluders
            local Outlined = 0

            for Target, Entry in pairs(S.Entries) do
                local Frame, ShadowFrame = Entry.Frame, Entry.ShadowFrame
                local TextParts = Entry.TextParts
                local Lines, Shadow = Entry.BoxLines, Entry.BoxShadow

                if Frame or TextParts or Lines or Entry.BodyParts or Entry.ContourLines then
                    local X1, Y1, X2, Y2
                    local Anchor = Entry.Anchor
                    local Distance = math.huge

                    --// One live part is read per frame; the box around it was
                    --// measured once, so turning, animating or walking can
                    --// move it but never resize or skew it.
                    if Anchor and Anchor.Parent then
                        Distance = (Anchor.Position - CameraPosition).Magnitude
                        local Alive = not Entry.Humanoid or Entry.Humanoid.Health > 0
                        if Target.Parent and Alive and Entry.BoxHeight and Distance <= Range then
                            X1, Y1, X2, Y2 = ProjectUpright(Anchor.Position, Entry, Camera)
                        end
                    end

                    --// Off-screen targets are hidden rather than moved, so a
                    --// busy zone does not pay for drawing it cannot show.
                    if X1 and (X2 < 0 or Y2 < 0 or X1 > Viewport.X or Y1 > Viewport.Y) then
                        X1 = nil
                    end

                    local Thickness = ThicknessFor(Distance)
                    local Edge = Thickness + 2
                    -- Cull only a target completely covered by a window. Partial
                    -- overlap stays rendered below it, right up to its edge.
                    if X1 and not Entry.BodyParts and Covered(X1 - Edge, Y1 - Edge, X2 + Edge, Y2 + Edge, Occluders) then
                        X1 = nil
                    end
                    local TextSize = TextSizeFor()
                    local Style = Entry.BoxStyle or "Full"
                    local Count = Style == "Corners" and 8 or 4
                    local Arm = CornerLength(Distance)

                    --// A far target is only a few pixels tall, so its corner
                    --// arms must not overrun each other.
                    if X1 and Style == "Corners" then
                        Arm = math.min(Arm, (X2 - X1) * 0.5, (Y2 - Y1) * 0.5)
                    end

                    if Lines then
                        for Index, Line in ipairs(Lines) do
                            if X1 and Index <= Count then
                                local A, B, C, D = SegmentAt(Style, Index, X1, Y1, X2, Y2, Arm)
                                SetLine(Line, A, B, C, D)
                                Line.Thickness = Thickness
                                Line.Visible = true
                            else
                                Line.Visible = false
                            end
                        end
                    end

                    if Shadow then
                        for Index, Line in ipairs(Shadow) do
                            if X1 and Index <= Count then
                                local A, B, C, D = SegmentAt(Style, Index, X1, Y1, X2, Y2, Arm)
                                SetLine(Line, A, B, C, D)
                                Line.Thickness = Thickness + 2
                                Line.Visible = true
                            else
                                Line.Visible = false
                            end
                        end
                    end

                    if Frame then
                        if X1 and Frame.Parent then
                            local Width, Height = X2 - X1, Y2 - Y1

                            if ShadowFrame and ShadowFrame.Parent then
                                ShadowFrame.Position = UDim2.fromOffset(X1, Y1)
                                ShadowFrame.Size = UDim2.fromOffset(Width, Height)
                                ShadowFrame.Visible = true
                                if Entry.ShadowStroke then
                                    Entry.ShadowStroke.Thickness = Thickness + 2
                                end
                            end

                            Frame.Position = UDim2.fromOffset(X1, Y1)
                            Frame.Size = UDim2.fromOffset(Width, Height)
                            Frame.Visible = true
                            if Entry.Stroke then Entry.Stroke.Thickness = Thickness end
                        else
                            Frame.Visible = false
                            if ShadowFrame then ShadowFrame.Visible = false end
                        end
                    end

                    if Entry.BodyParts or Entry.ContourLines then
                        local Show = X1 ~= nil and Entry.BodyParts ~= nil
                            and (Outlined < OUTLINE_BUDGET or Entry.Owner == Player)
                        if Show then Outlined += 1 end
                        local Smooth = S.Settings.OutlineRenderer == "Smooth" and DrawSmooth(Entry, Show)
                        if S.Settings.OutlineRenderer ~= "Smooth" then RemoveSmooth(Entry) end
                        DrawContour(Entry, Camera, Show and not Smooth, Thickness)
                    end

                    -- Drawing and GUI text share the same top-aligned layout.
                    if TextParts then
                        local Pad = 4 + Thickness
                        local RowHeight = TextSize + 4
                        local HpHeight = Entry.HasHp and RowHeight or 0
                        local CenterX = X1 and (X1 + X2) * 0.5
                        local BlockWidth = 30
                        for _, Part in ipairs(TextParts) do
                            BlockWidth = math.max(BlockWidth, Part.Width or 30)
                        end
                        BlockWidth = math.min(BlockWidth + 8, math.max(1, Viewport.X - 8))
                        local TopY, BottomY
                        if X1 then
                            CenterX = math.clamp(CenterX, BlockWidth * .5 + 4, Viewport.X - BlockWidth * .5 - 4)
                            BottomY = math.clamp(Y2 + Pad, 4, math.max(4, Viewport.Y - RowHeight - 4))
                            TopY = Y1 - Pad - RowHeight - HpHeight
                            if TopY < 4 then TopY = BottomY + RowHeight + 2 end
                            TopY = math.clamp(TopY, 4, math.max(4, Viewport.Y - RowHeight - HpHeight - 4))
                        end

                        for _, Part in ipairs(TextParts) do
                            local Show = X1 ~= nil and not Part.Empty
                            local Key = Part.Key
                            local Y = X1 and (Key == "Bottom" and BottomY or (TopY + (Key == "Hp" and RowHeight or 0)))
                            if Show and Covered(CenterX - BlockWidth * .5, Y, CenterX + BlockWidth * .5, Y + RowHeight, Occluders) then
                                Show = false
                            end

                            if Part.Draw then
                                if Show then
                                    Part.Draw.Size = TextSize
                                    Part.Draw.Position = Vector2.new(CenterX, Y)
                                end
                                Part.Draw.Visible = Show
                            elseif Part.Gui then
                                if Show and Part.Gui.Parent then
                                    Part.Gui.TextSize = TextSize
                                    Part.Gui.Position = UDim2.fromOffset(CenterX, Y)
                                    Part.Gui.Size = UDim2.fromOffset(BlockWidth, RowHeight)
                                    Part.Gui.Visible = true
                                else
                                    Part.Gui.Visible = false
                                end
                            end
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
            SaveSetting(ENABLED_KEYS[Kind], S.Kinds[Kind].Enabled)
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

            SaveStyle(Kind)
            Rebuild(Kind)
        end

        --// Colour changes are applied live, with no rebuild. The black backing
        --// stays black.
        local function Recolor(Kind)
            local Color = S.Kinds[Kind].Color
            for _, Entry in pairs(S.Entries) do
                if Entry.Kind == Kind then
                    if Entry.Stroke then Entry.Stroke.Color = Color end
                    if Entry.TextParts then
                        for _, Part in ipairs(Entry.TextParts) do
                            if Part.Key == "Name" then
                                if Part.Gui then Part.Gui.TextColor3 = Color end
                                if Part.Draw then Part.Draw.Color = Color end
                            end
                        end
                    end
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
            local SettingsSection = UIRef.EspTab:AddSection{ Title = "ESP Settings", Side = "Right", Description = "Visibility and overlay distance" }

            Controls.OutlineRenderer = SettingsSection:AddDropdown{
                Name = "Outline renderer",
                Options = { "Body contour", "Smooth (experimental)" },
                Default = S.Settings.OutlineRenderer == "Smooth" and "Smooth (experimental)" or "Body contour",
                Description = "Smooth follows body meshes using Highlight. If it does not appear, choose Body contour to restore the working lines.",
                Callback = function(Value)
                    S.Settings.OutlineRenderer = Value == "Smooth (experimental)" and "Smooth" or "Contour"
                    SaveSetting("ESP_OUTLINE_RENDERER", S.Settings.OutlineRenderer)
                    Clear()
                    S.Timer = SCAN_INTERVAL
                end,
            }

            Controls.BoxStyle = SettingsSection:AddDropdown{
                Name = "Box style",
                Options = BOX_STYLES,
                Default = BOX_STYLE_NAMES[S.Settings.BoxStyle],
                Callback = function(Value)
                    S.Settings.BoxStyle = BOX_STYLE_KEYS[Value] or "Full"
                    SaveSetting("ESP_BOX_STYLE", S.Settings.BoxStyle)
                    Clear()
                    S.Timer = SCAN_INTERVAL
                end,
            }
            Controls.Thickness = SettingsSection:AddSlider{
                Name = "Box thickness",
                Default = S.Settings.Thickness,
                Min = 1,
                Max = 6,
                Decimals = 1,
                Callback = function(Value)
                    S.Settings.Thickness = Value
                    SaveSetting("ESP_THICKNESS", Value)
                end,
            }
            Controls.AutoThickness = SettingsSection:AddToggle{
                Name = "Auto thickness",
                Default = S.Settings.AutoThickness,
                Callback = function(Value)
                    S.Settings.AutoThickness = Value == true
                    SaveSetting("ESP_AUTO_THICKNESS", S.Settings.AutoThickness)
                end,
            }
            Controls.Range = SettingsSection:AddSlider{
                Name = "Draw range",
                Default = S.Settings.Range,
                Min = 100,
                Max = 2000,
                Suffix = "m",
                Callback = function(Value)
                    S.Settings.Range = Value
                    SaveSetting("ESP_RANGE", Value)
                end,
            }

            for _, Kind in ipairs(KINDS) do
                local C = S.Kinds[Kind]
                local Sec = UIRef.EspTab:AddSection{ Title = TITLES[Kind], Side = "Right" }

                Controls.Kinds[Kind] = Sec:AddToggle{
                    Name = Kind .. " ESP",
                    Bold = true,
                    Default = C.Enabled,
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
                            SaveStyle(Kind)
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
                            SaveStyle(Kind)
                            Rebuild(Kind)
                        end
                    end,
                }
                S.StyleToggles[Kind] = { Outline = OutlineToggle, Box = BoxToggle }

                Controls.Text[Kind] = Sec:AddToggle{
                    Name = Kind .. " info text",
                    Default = C.Label,
                    Callback = function(Value)
                        C.Label = Value == true
                        SaveSetting(TEXT_KEYS[Kind], C.Label)
                        Rebuild(Kind)
                    end,
                }
                Controls.Colors[Kind] = Sec:AddColorPicker{
                    Name = Kind .. " colour",
                    Default = C.Color,
                    Callback = function(Color)
                        if type(Color) == "table" then
                            Color = Color.Color or Color.Value or Color[1]
                        end
                        if typeof(Color) == "Color3" then
                            C.Color = Color
                            SaveColor(Kind, Color)
                            Recolor(Kind)
                        end
                    end,
                }
            end
        end

        --// ProfileManager restores a profile after the features start and
        --// calls this through Components, the same hook Party and Mining use.
        AICUI.RefreshEspSettings = LoadSettings

        Context.Lifetime.OnEnd(function()
            if AICUI.RefreshEspSettings == LoadSettings then
                AICUI.RefreshEspSettings = nil
            end
            RenderConnection:Disconnect()
            Clear()
            if SmoothFolder then SmoothFolder:Destroy() end
            if Root then Root:Destroy() end
        end)

        return Feature
    end,
}
