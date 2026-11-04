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
-- Measurement is tested separately in game; give the renderer a stable rig.
rawset(target, "GetDescendants", function() return {} end)
local owner = Instance.new("Player")
owner.Name = "OtherPlayer"
local stats = Instance.new("Folder", owner)
stats.Name = "PlayerStats"
local level = Instance.new("IntValue", stats)
level.Name, level.Value = "Level", 250
Players.GetPlayerFromCharacter = function(_, model) return model == target and owner or nil end
workspace.CurrentCamera = {
    CFrame = CFrame.new(Vector3.new(0,0,0)), ViewportSize = Vector2.new(800,600),
    WorldToViewportPoint = function(_, p) return Vector3.new(400+p.X, 300-p.Y*10, p.Z), true end,
}

local function run(useDrawing)
    Drawing = useDrawing and { new = function()
        return { Remove = function(self) self.Removed = true; self.Visible = false end }
    end } or nil
    local cleanup
    local feature = EspModule.Start({
        Services = { Players = Players }, Player = Players.LocalPlayer,
        UIRef = {}, AICUI = {}, CONFIG = {},
        Lifetime = { OnEnd = function(fn) cleanup = fn end },
    })
    feature.S.Kinds.Player.Enabled = true
    feature.S.Kinds.Player.Label = true
    feature:Update(1)
    local entry = assert(feature.S.Entries[target], "player was not scanned")
    entry.BoxHeight, entry.BoxWidth, entry.BoxOffsetY = 6, 4, 0
    local function render()
        RunService.RenderStepped:Fire()
        assert(#SmokeEnv.Errors == 0, table.concat(SmokeEnv.Errors, "\n"))
    end
    render()
    assert(entry.Highlight.Parent.Parent == workspace, "outline is outside the world render tree")
    assert(entry.Highlight.Enabled, "in-range live outline is hidden")
    assert(#entry.TextParts == 3, "info is still scattered around the box")
    local parts = {}
    for _, part in ipairs(entry.TextParts) do parts[part.Key] = part end
    assert(parts.Bottom.Draw and useDrawing or parts.Bottom.Gui and not useDrawing, "wrong renderer")
    local function y(part) return useDrawing and part.Draw.Position.Y or part.Gui.Position.Y.Offset end
    local function text(part) return useDrawing and part.Draw.Text or part.Gui.Text end
    assert(text(parts.Bottom):find("Lv 250",1,true) and text(parts.Bottom):find("100 studs",1,true), "metadata is missing")
    assert(y(parts.Name) < y(parts.Hp) and y(parts.Hp)+18 <= 270, "name/health overlap the box")
    assert(y(parts.Bottom) >= 330, "metadata overlaps the box")
    feature.S.Settings.Range = 50
    render()
    assert(not entry.Highlight.Enabled, "out-of-range outline is still visible")
    assert(not (useDrawing and parts.Name.Draw.Visible or not useDrawing and parts.Name.Gui.Visible), "out-of-range text remains visible")
    feature.S.Settings.Range = 900
    humanoid.Health = 0
    render()
    assert(not entry.Highlight.Enabled, "dead target keeps its outline")
    humanoid.Health = 75
    anchor.Position = Vector3.new(-399,0,100)
    render()
    local x = useDrawing and parts.Name.Draw.Position.X or parts.Name.Gui.Position.X.Offset
    assert(x > 4, "edge label was not moved into the viewport")
    cleanup()
    assert(not workspace:FindFirstChild("Outlines"), "outline folder survived cleanup")
    anchor.Position = Vector3.new(0,0,100)
end
run(false)
run(true)
print("ESP SMOKE PASSED: GUI, Drawing, outline range/death, text layout, cleanup")
