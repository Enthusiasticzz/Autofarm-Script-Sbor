-- Esp outlines players, mobs and equipped weapons in the world.
--
-- Each enabled kind draws either an outline (Highlight) or a 2D box, never
-- both, and can add text around the box: the name with the HP under it above
-- the box, the level (and the EXP a mob gives) down its right side, the
-- distance below it.
-- Outlines live in a folder inside one ScreenGui. Boxes and labels are drawn
-- with the executor's Drawing API when it has one, because a Drawing object
-- costs no GUI work per frame; otherwise they fall back to Frames and
-- TextLabels inside that same ScreenGui.
--
-- The box look follows the reference ESPs: a black backing behind a thinner
-- coloured box, and corner brackets instead of a closed box if that style is
-- picked.
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
        --// Every piece of text is the same pixel size at any distance, like
        --// the popular ESP libraries. Change this one number to resize all
        --// of it.
        local TEXT_SIZE = 16
        --// The Drawing font the text uses: UI, System, Plex or Monospace
        --// (some executors also have Roboto, Legacy, SourceSans, RobotoMono).
        local TEXT_FONT_NAME = "Monospace"

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
            --// [Target] = { Kind, BoxStyle, Highlight?, BoxLines?, BoxShadow?,
            --//              Frame?, Stroke?, TextParts?, Anchor?,
            --//              BoxHeight?/BoxWidth?/BoxOffsetY? }
            Entries = {},
            StyleToggles = {}, -- [Kind] = { Outline = toggle, Box = toggle }
            Settings = {
                Thickness = 1.5, -- box thickness at close range
                AutoThickness = true,
                Range = 900, -- studs; nothing past this is drawn
                BoxStyle = "Full",
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

        local function Remove(Target, Entry)
            if Entry.Highlight then pcall(function() Entry.Highlight:Destroy() end) end
            if Entry.Frame then pcall(function() Entry.Frame:Destroy() end) end
            if Entry.ShadowFrame then pcall(function() Entry.ShadowFrame:Destroy() end) end
            if Entry.TextParts then
                for _, Part in ipairs(Entry.TextParts) do
                    if Part.Draw then pcall(function() Part.Draw:Remove() end) end
                    if Part.Gui then pcall(function() Part.Gui:Destroy() end) end
                end
            end
            for _, Key in ipairs({ "BoxLines", "BoxShadow" }) do
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

        local Root, HighlightFolder

        local function TryParent(Gui, Parent)
            if not Parent then return false end
            local Ok = pcall(function() Gui.Parent = Parent end)
            return Ok and Gui.Parent == Parent
        end

        --// One ScreenGui holds the highlights and, when there is no Drawing
        --// API, every box and label. It goes in a hidden UI container when
        --// the executor has one, then CoreGui, then PlayerGui.
        --// If it is ever lost (PlayerGui reset, etc.) it is rebuilt and all
        --// entries are redrawn on the same scan.
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

        --// Some executors expose a Drawing table whose objects accept writes
        --// but never render (a stub, or an API that needs a different name).
        --// Creating an object is not enough to trust it: write a property and
        --// read it back, so a dead API falls through to the GUI instead of
        --// silently drawing nothing.
        local function ProbeDrawing(ClassName)
            if not DrawingApi then return false end

            local OkNew, Object = pcall(DrawingApi.new, ClassName)
            if not OkNew or not Object then return false end

            local OkWrite = pcall(function() Object.Visible = true end)
            local OkRead, Back = pcall(function() return Object.Visible end)
            pcall(function() Object:Remove() end)

            return OkWrite and OkRead and Back == true
        end

        local LineSupported = ProbeDrawing("Line")
        local TextSupported = ProbeDrawing("Text")

        --// The default Drawing font (UI) is thin and plain. The font is picked
        --// by name from the executor's own Drawing.Fonts table; when that
        --// table or the name is missing, the usual numbers are used instead.
        local FONT_NUMBERS = { UI = 0, System = 1, Plex = 2, Monospace = 3 }
        local TextFont = FONT_NUMBERS[TEXT_FONT_NAME] or 2
        do
            local Ok, Font = pcall(function() return DrawingApi.Fonts[TEXT_FONT_NAME] end)
            if Ok and Font ~= nil then
                TextFont = Font
            end
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

        --// Drawing objects differ between executors, so each property is set
        --// on its own. One unsupported property must not skip the rest (a
        --// Text whose Transparency never got set is an invisible label).
        local function SetProps(Object, Props)
            for Key, Value in pairs(Props) do
                pcall(function() Object[Key] = Value end)
            end
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
                Bottom = math.floor(Distance + 0.5) .. "m"
            end

            return { Name = Name, Hp = Hp, Right = table.concat(Right, "\n"), Bottom = Bottom }
        end

        local function SetLabelText(Target, Kind, Entry)
            if not Entry.TextParts then return end
            local Texts = LabelParts(Target, Kind, Entry)
            Entry.HasHp = (Texts.Hp or "") ~= ""

            for _, Part in ipairs(Entry.TextParts) do
                local Text = Texts[Part.Key] or ""
                Part.Empty = Text == ""

                Part.Lines = 1
                for _ in string.gmatch(Text, "\n") do
                    Part.Lines += 1
                end

                if Part.Draw then Part.Draw.Text = Text end
                if Part.Gui then Part.Gui.Text = Text end
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

        local function DisposeLines(List)
            if not List then return end
            for _, Line in ipairs(List) do
                pcall(function() Line:Remove() end)
            end
        end

        local function MakeLines(Count, Color, Thickness)
            if not LineSupported then return nil end

            local List = {}
            for Index = 1, Count do
                local Line = NewLine()
                if not Line then
                    DisposeLines(List)
                    return nil
                end

                SetProps(Line, {
                    Color = Color,
                    Thickness = Thickness,
                    Transparency = 1,
                    Visible = false,
                })
                List[Index] = Line
            end
            return List
        end

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
            local Keys = Kind == "Weapon" and { "Name", "Bottom" } or { "Name", "Hp", "Right", "Bottom" }
            Entry.TextParts = {}

            for _, Key in ipairs(Keys) do
                local Part = { Key = Key, Lines = 1, Empty = true }

                local DrawText = NewText()
                if DrawText then
                    SetProps(DrawText, {
                        Color = C.Color,
                        Size = TEXT_SIZE,
                        Font = TextFont,
                        Center = Key ~= "Right",
                        Transparency = 1,
                        Visible = false,
                    })
                    --// Outline is not on every executor's Text object.
                    pcall(function() DrawText.Outline = true end)
                    pcall(function() DrawText.OutlineColor = BLACK end)
                    Part.Draw = DrawText
                else
                    local Text = Instance.new("TextLabel")
                    Text.Name = Kind .. Key .. "Label"
                    Text.BackgroundTransparency = 1
                    Text.TextColor3 = C.Color
                    Text.TextStrokeColor3 = BLACK
                    Text.TextStrokeTransparency = 0
                    Text.Font = Enum.Font.GothamBold
                    Text.TextSize = TEXT_SIZE
                    Text.Visible = false
                    Text.ZIndex = 3

                    if Key == "Name" or Key == "Hp" then
                        Text.AnchorPoint = Vector2.new(0.5, 1)
                        Text.Size = UDim2.fromOffset(340, 40)
                        Text.TextXAlignment = Enum.TextXAlignment.Center
                        Text.TextYAlignment = Enum.TextYAlignment.Bottom
                    elseif Key == "Bottom" then
                        Text.AnchorPoint = Vector2.new(0.5, 0)
                        Text.Size = UDim2.fromOffset(340, 40)
                        Text.TextXAlignment = Enum.TextXAlignment.Center
                        Text.TextYAlignment = Enum.TextYAlignment.Top
                    else
                        Text.AnchorPoint = Vector2.new(0, 0.5)
                        Text.Size = UDim2.fromOffset(200, 100)
                        Text.TextXAlignment = Enum.TextXAlignment.Left
                        Text.TextYAlignment = Enum.TextYAlignment.Center
                    end

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

            --// Only targets without a usable measurement are measured here,
            --// a few per scan, so a rig that was still spawning when it was
            --// first seen is picked up without one frame paying for every mob.
            local Measured = 0
            for Target, Entry in pairs(S.Entries) do
                if Target.Parent and Entry.BoxHeight == nil
                    and (Entry.Frame or Entry.BoxLines or Entry.TextParts) then
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
            --// Drawing needs no ScreenGui, so a lost Root must not stop the
            --// box and text layers; the GUI pieces check their own parent.
            if not Camera then return end

            local CameraPosition = Camera.CFrame.Position
            local Viewport = Camera.ViewportSize
            local Range = S.Settings.Range

            for _, Entry in pairs(S.Entries) do
                local Frame, ShadowFrame = Entry.Frame, Entry.ShadowFrame
                local TextParts = Entry.TextParts
                local Lines, Shadow = Entry.BoxLines, Entry.BoxShadow

                if Frame or TextParts or Lines then
                    local X1, Y1, X2, Y2
                    local Anchor = Entry.Anchor
                    local Distance = math.huge

                    --// One live part is read per frame; the box around it was
                    --// measured once, so turning, animating or walking can
                    --// move it but never resize or skew it.
                    if Anchor and Anchor.Parent then
                        Distance = (Anchor.Position - CameraPosition).Magnitude
                        if Entry.BoxHeight and Distance <= Range then
                            X1, Y1, X2, Y2 = ProjectUpright(Anchor.Position, Entry, Camera)
                        end
                    end

                    --// Off-screen targets are hidden rather than moved, so a
                    --// busy zone does not pay for drawing it cannot show.
                    if X1 and (X2 < 0 or Y2 < 0 or X1 > Viewport.X or Y1 > Viewport.Y) then
                        X1 = nil
                    end

                    local Thickness = ThicknessFor(Distance)
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

                    --// Text is spaced around the box rather than stacked on
                    --// top of it: the HP just above the top edge with the name
                    --// above that (each centred on its own, so they line up),
                    --// the level (and a mob's EXP) down the right edge, the
                    --// distance below the bottom edge.
                    if TextParts then
                        local Pad = 4 + Thickness
                        local RowHeight = TextSize + 2
                        local HpHeight = Entry.HasHp and RowHeight or 0
                        local CenterX = X1 and (X1 + X2) * 0.5
                        local MiddleY = X1 and (Y1 + Y2) * 0.5

                        for _, Part in ipairs(TextParts) do
                            local Show = X1 ~= nil and not Part.Empty
                            local Key = Part.Key
                            local Block = Part.Lines * RowHeight * 0.5

                            if Part.Draw then
                                if Show then
                                    Part.Draw.Size = TextSize
                                    if Key == "Hp" then
                                        Part.Draw.Position = Vector2.new(CenterX, Y1 - Pad - Block)
                                    elseif Key == "Name" then
                                        Part.Draw.Position = Vector2.new(CenterX, Y1 - Pad - HpHeight - Block)
                                    elseif Key == "Bottom" then
                                        Part.Draw.Position = Vector2.new(CenterX, Y2 + Pad + Block)
                                    else
                                        Part.Draw.Position = Vector2.new(X2 + Pad, MiddleY - Block)
                                    end
                                end
                                Part.Draw.Visible = Show
                            elseif Part.Gui then
                                if Show and Part.Gui.Parent then
                                    Part.Gui.TextSize = TextSize
                                    if Key == "Hp" then
                                        Part.Gui.Position = UDim2.fromOffset(CenterX, Y1 - Pad)
                                    elseif Key == "Name" then
                                        Part.Gui.Position = UDim2.fromOffset(CenterX, Y1 - Pad - HpHeight)
                                    elseif Key == "Bottom" then
                                        Part.Gui.Position = UDim2.fromOffset(CenterX, Y2 + Pad)
                                    else
                                        Part.Gui.Position = UDim2.fromOffset(X2 + Pad, MiddleY)
                                    end
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
                    if Entry.Highlight then Entry.Highlight.OutlineColor = Color end
                    if Entry.Stroke then Entry.Stroke.Color = Color end
                    if Entry.TextParts then
                        for _, Part in ipairs(Entry.TextParts) do
                            if Part.Gui then Part.Gui.TextColor3 = Color end
                            if Part.Draw then Part.Draw.Color = Color end
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
            local SettingsSection = UIRef.EspTab:AddSection{ Title = "ESP Settings" }

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
                local Sec = UIRef.EspTab:AddSection{ Title = TITLES[Kind] }

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
            if Root then Root:Destroy() end
        end)

        return Feature
    end,
}