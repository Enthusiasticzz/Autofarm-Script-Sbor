-- A small camera/world model exercises both Drawing and GUI rendering paths.
local Vector3 = {}
Vector3.__index = function(v, key)
    if key == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
    return Vector3[key]
end
function Vector3.new(x, y, z) return setmetatable({ X=x, Y=y, Z=z }, Vector3) end
Vector3.__add = function(a,b) return Vector3.new(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end
Vector3.__sub = function(a,b) return Vector3.new(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end
local CFrame = {}
function CFrame.new(position)
    return { Position = position, LookVector = Vector3.new(0,0,1) }
end
CFrame.lookAt = CFrame.new
local Drawing
-- ESP_MODULE

local target = Instance.new("Model", workspace)
target.Name = "OtherPlayer"
local humanoid = Instance.new("Humanoid", target)
humanoid.Health, humanoid.MaxHealth = 75, 100
local anchor = Instance.new("Part", target)
anchor.Name = "HumanoidRootPart"
rawset(anchor, "IsA", function(_, kind) return kind == "Part" or kind == "BasePart" or kind == "Instance" end)
anchor.Position = Vector3.new(0,0,100)
anchor.CFrame = CFrame.new(anchor.Position)
humanoid.RootPart = anchor
-- Give the renderer a fixed measured rig; these tests do not emulate geometry.
rawset(target, "GetDescendants", function() return {} end)
local owner = Instance.new("Player")
owner.Name = "OtherPlayer"
owner.Character = target
Players.GetPlayers = function() return { Players.LocalPlayer, owner } end
local stats = Instance.new("Folder", owner)
stats.Name = "PlayerStats"
local level = Instance.new("IntValue", stats)
level.Name, level.Value = "Level", 250
Players.GetPlayerFromCharacter = function(_, model) return model == target and owner or nil end
workspace.CurrentCamera = {
    CFrame = CFrame.new(Vector3.new(0,0,0)), ViewportSize = Vector2.new(800,600),
    WorldToViewportPoint = function(_, p) return Vector3.new(400+p.X, 300-p.Y*10, p.Z), true end,
}

local function run(useDrawing, ownCharacter)
    Players.LocalPlayer.Character = ownCharacter and target or nil
    Drawing = useDrawing and { new = function()
        return { Remove = function(self) self.Removed = true; self.Visible = false end }
    end } or nil
    local cleanup
    local startup = { IntroDone = true }
    local menu = { Root = {
        Visible = false, AbsolutePosition = Vector2.new(350,240), AbsoluteSize = Vector2.new(100,120),
    }, Gui = { Enabled = true } }
    local feature = EspModule.Start({
        Services = { Players = Players }, Player = Players.LocalPlayer,
        UIRef = {}, AICUI = {}, CONFIG = {},
        Startup = startup, UI = menu,
        Lifetime = { OnEnd = function(fn) cleanup = fn end },
    })
    feature.S.Kinds.Player.Enabled = true
    feature.S.Kinds.Player.Label = true
    local newInstance = Instance.new
    Instance.new = function(class, ...)
        if class == "Highlight" then error("temporary highlight construction failure") end
        return newInstance(class, ...)
    end
    feature:Update(1)
    local entry = assert(feature.S.Entries[target], "player was not scanned")
    assert(not entry.Highlight and entry.OutlineError, "outline construction errors were silently lost")
    Instance.new = newInstance
    feature:Update(1)
    assert(entry.Highlight and not entry.OutlineError, "outline construction failure was never retried")
    entry.BoxHeight, entry.BoxWidth, entry.BoxOffsetY = 6, 4, 0
    local function render()
        RunService.RenderStepped:Fire()
        assert(#SmokeEnv.Errors == 0, table.concat(SmokeEnv.Errors, "\n"))
    end
    render()
    assert(entry.Highlight.Parent == target and entry.Highlight.Adornee == target, "outline is not bound directly to the rig")
    assert(entry.Highlight.FillTransparency < 1 and entry.Highlight.FillTransparency > .99, "outline has no nearly-invisible fill pass")
    assert(entry.Highlight.Enabled, "in-range live outline is hidden")
    assert(feature.S.OutlineCount == 1, "outline slot accounting is incorrect")
    assert(#entry.TextParts == 3, "info is still scattered around the box")
    local parts = {}
    for _, part in ipairs(entry.TextParts) do parts[part.Key] = part end
    assert(parts.Bottom.Gui and not parts.Bottom.Draw, "ESP text bypasses menu GUI ordering")
    assert(parts.Bottom.Gui.Parent.DisplayOrder < 1000, "ESP layer is above the menu")
    local function y(part) return part.Gui.Position.Y.Offset end
    local function text(part) return part.Gui.Text end
    assert(text(parts.Bottom):find("Lv 250",1,true) and text(parts.Bottom):find("100 studs",1,true), "metadata is missing")
    assert(y(parts.Name) < y(parts.Hp) and y(parts.Hp)+18 <= 270, "name/health overlap the box")
    assert(y(parts.Bottom) >= 330, "metadata overlaps the box")
    local function textVisible()
        return parts.Name.Gui.Visible
    end
    -- Cover every rendering primitive, including optional box styles, while
    -- keeping the existing entry so closing the menu restores it immediately.
    entry.BoxLines = { { Visible = true } }
    entry.BoxShadow = { { Visible = true } }
    entry.Frame = Instance.new("Frame", Services.CoreGui)
    entry.ShadowFrame = Instance.new("Frame", Services.CoreGui)
    menu.Root.Visible = true
    render()
    assert(not entry.Highlight.Enabled and not textVisible(), "ESP shows through the menu")
    assert(not entry.BoxLines[1].Visible and not entry.BoxShadow[1].Visible, "Drawing box shows through the menu")
    assert(not entry.Frame.Visible and not entry.ShadowFrame.Visible, "GUI box shows through the menu")
    entry.BoxLines, entry.BoxShadow = nil, nil
    menu.Root.AbsolutePosition = Vector2.new(10,10)
    render()
    assert(entry.Highlight.Enabled and textVisible(), "an open menu hides ESP outside its bounds")
    menu.Root.AbsolutePosition = Vector2.new(360,337)
    menu.Root.AbsoluteSize = Vector2.new(80,30)
    render()
    assert(entry.Highlight.Enabled and textVisible(), "a covered metadata line hides the entire target")
    assert(parts.Bottom.Gui.Visible, "partially covered metadata disappears before reaching the menu edge")
    menu.Root.AbsolutePosition = Vector2.new(400,240)
    menu.Root.AbsoluteSize = Vector2.new(100,120)
    render()
    assert(entry.Highlight.Enabled and textVisible(), "partial body overlap hides the entire target too early")
    menu.Root.Visible = false
    startup.IntroDone = false
    render()
    assert(not entry.Highlight.Enabled and not textVisible(), "ESP shows through the intro")
    startup.IntroDone = true
    render()
    assert(entry.Highlight.Enabled and textVisible(), "ESP did not resume when the menu/intro closed")
    assert(feature.S.Entries[target] == entry, "UI visibility rebuilt the ESP entry")
    feature.S.Settings.Range = 50
    render()
    assert(not entry.Highlight.Enabled, "out-of-range outline is still visible")
    assert(not parts.Name.Gui.Visible, "out-of-range text remains visible")
    feature:Update(1)
    assert(entry.Highlight == nil and feature.S.OutlineCount == 0, "out-of-range outline still occupies a native slot")
    feature.S.Settings.Range = 900
    feature:Update(1)
    humanoid.Health = 0
    render()
    assert(not entry.Highlight.Enabled, "dead target keeps its outline")
    humanoid.Health = 75
    anchor.Position = Vector3.new(-399,0,100)
    render()
    local x = parts.Name.Gui.Position.X.Offset
    assert(x > 4, "edge label was not moved into the viewport")
    entry.Highlight:Destroy()
    entry.Highlight.Parent = nil -- Match engine Destroy behavior in the UI stub.
    feature:Update(1)
    render()
    assert(entry.Highlight.Parent == target and entry.Highlight.Enabled, "a removed outline was not repaired")
    cleanup()
    assert(not workspace:FindFirstChild("Outlines"), "outline folder survived cleanup")
    anchor.Position = Vector3.new(0,0,100)
end
run(false, true)
run(true, true)
run(false, false)
run(true, false)

for _, style in ipairs({ "Full", "Corners" }) do
    Drawing = { new = function() error("ESP must use a layer below menus") end }
    local cleanup
    local occluders = {}
    local menu = { Gui = { Enabled = true, DisplayOrder = 1000, Parent = Services.CoreGui },
        GetOcclusionRects = function() return occluders end }
    local feature = EspModule.Start({
        Services = { Players = Players }, Player = Players.LocalPlayer,
        UIRef = {}, AICUI = {}, CONFIG = {}, UI = menu,
        Lifetime = { OnEnd = function(fn) cleanup = fn end },
    })
    feature.S.Settings.BoxStyle = style
    feature.S.Kinds.Player.Enabled = true
    feature.S.Kinds.Player.Outline = false
    feature.S.Kinds.Player.Box = true
    feature.S.Kinds.Player.Label = true
    feature:Update(1)
    local entry = assert(feature.S.Entries[target])
    entry.BoxHeight, entry.BoxWidth, entry.BoxOffsetY = 6, 4, 0
    RunService.RenderStepped:Fire()
    assert(#SmokeEnv.Errors == 0, table.concat(SmokeEnv.Errors, "\n"))
    assert(#entry.BoxLines == (style == "Corners" and 8 or 4), "box style lost its segments")
    for _, line in ipairs(entry.BoxLines) do
        assert(line.Gui and line.Gui.Parent.DisplayOrder < 1000 and line.Visible, "box edge bypasses menu layering")
        assert(line.Gui.Parent.Parent == menu.Gui.Parent, "ESP and menu use different GUI containers")
    end
    occluders = { {400,240,500,360} } -- Only half the body is under a window.
    RunService.RenderStepped:Fire()
    assert(entry.BoxLines[1].Visible, "a partial overlap still removes the whole box")
    occluders = { {0,0,100,100}, {350,200,500,380} } -- A floating menu covers it.
    RunService.RenderStepped:Fire()
    assert(not entry.BoxLines[1].Visible, "a fully covered floating-menu target was not culled")
    occluders = {}
    RunService.RenderStepped:Fire()
    assert(entry.BoxLines[1].Visible, "closing a floating menu did not restore the box")
    cleanup()
end
print("ESP SMOKE PASSED: outline repair/slots, own/other rigs, Full/Corners, GUI layering, partial/full coverage")
