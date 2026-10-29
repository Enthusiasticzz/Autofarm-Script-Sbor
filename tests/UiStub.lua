--[[
    Minimal Roblox stand-ins so script/UI/Utils.lua can be *constructed* outside
    Studio. Only what the library touches is implemented; this is a smoke test,
    not an emulator.
]]

local Errors = {}
local function Record(where, err)
    table.insert(Errors, where .. ": " .. tostring(err))
end

local function IsTable(v)
    return type(v) == "table"
end

------------------------------------------------------------------ signals
local Signal = {}
Signal.__index = Signal
function Signal.new()
    return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
    local entry = { fn = fn, connected = true }
    table.insert(self.handlers, entry)
    return {
        Connected = true,
        Disconnect = function()
            entry.connected = false
        end,
    }
end
function Signal:Once(fn)
    local c
    c = self:Connect(function(...)
        c:Disconnect()
        fn(...)
    end)
    return c
end
function Signal:Fire(...)
    for _, entry in ipairs(self.handlers) do
        if entry.connected then
            local ok, err = pcall(entry.fn, ...)
            if not ok then Record("signal handler", err) end
        end
    end
end
function Signal:Wait()
    return nil
end

------------------------------------------------------------------ math types
local Vector2 = {}
Vector2.__typename = "Vector2"
Vector2.__index = Vector2
function Vector2.new(x, y)
    return setmetatable({ X = x or 0, Y = y or 0 }, Vector2)
end
Vector2.__add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end
Vector2.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end
Vector2.__mul = function(a, b)
    if IsTable(b) then return Vector2.new(a.X * b.X, a.Y * b.Y) end
    return Vector2.new(a.X * b, a.Y * b)
end
function Vector2:__tostring() return string.format("(%.1f, %.1f)", self.X, self.Y) end
function Vector2:Dot(other) return self.X * other.X + self.Y * other.Y end
Vector2.__index = function(self, key)
    if key == "Magnitude" then return math.sqrt(self.X * self.X + self.Y * self.Y) end
    if key == "Unit" then
        local m = math.max(self.Magnitude, 1e-6)
        return Vector2.new(self.X / m, self.Y / m)
    end
    return Vector2[key]
end

local function ValueOr(value, fallback)
    if value == nil then return fallback end
    return value
end

local UDim = {}
UDim.__typename = "UDim"
function UDim.new(scale, offset)
    return setmetatable({ Scale = ValueOr(scale, 0), Offset = ValueOr(offset, 0) }, UDim)
end
function UDim.fromScale(s) return UDim.new(s, 0) end
function UDim.fromOffset(o) return UDim.new(0, o) end

local UDim2 = {}
UDim2.__typename = "UDim2"
function UDim2.new(xs, xo, ys, yo)
    return setmetatable({
        X = UDim.new(ValueOr(xs, 0), ValueOr(xo, 0)),
        Y = UDim.new(ValueOr(ys, 0), ValueOr(yo, 0)),
    }, UDim2)
end
function UDim2.fromScale(x, y) return UDim2.new(x, 0, y, 0) end
function UDim2.fromOffset(x, y) return UDim2.new(0, x, 0, y) end

------------------------------------------------------------------ Enum
local function MakeEnumItem(enumName, itemName, value)
    return setmetatable({ Name = itemName, Value = value or 0, EnumType = enumName }, { __typename = "EnumItem" })
end

local EnumTypeMT = {}
EnumTypeMT.__index = function(self, key)
    if key == "GetEnumItems" then
        return function()
            return self._items
        end
    end
    local item = MakeEnumItem(self._name, key, #self._items + 1)
    rawset(self, key, item)
    table.insert(self._items, item)
    return item
end

local EnumMT = {}
EnumMT.__index = function(self, key)
    local t = setmetatable({ _name = key, _items = {} }, EnumTypeMT)
    rawset(self, key, t)
    return t
end
local Enum = setmetatable({}, EnumMT)

-- Font list: one entry per family plus weight variants, so the family
-- collapsing in _GetFontChoices has something to collapse.
local FONT_NAMES = {
    "Arial", "ArialBold", "Bodoni", "Cartoon", "Code", "Fantasy", "Gotham",
    "GothamBlack", "GothamBold", "GothamMedium", "Highway", "Legacy", "Roboto",
    "RobotoBold", "RobotoMedium", "SciFi", "SourceSans", "SourceSansBold",
    "SourceSansLight", "Unknown",
}
for index, name in ipairs(FONT_NAMES) do
    rawset(Enum.Font, name, MakeEnumItem("Font", name, index))
    table.insert(Enum.Font._items, Enum.Font[name])
end

------------------------------------------------------------------ Color3
local Color3 = {}
Color3.__typename = "Color3"
Color3.__index = Color3
local function Clamp01(v) return math.clamp(v, 0, 1) end
function Color3.new(r, g, b)
    return setmetatable({ R = Clamp01(r or 0), G = Clamp01(g or 0), B = Clamp01(b or 0) }, Color3)
end
function Color3.fromRGB(r, g, b)
    return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h, s, v)
    -- standard HSV -> RGB
    h, s, v = (h or 0) % 1, Clamp01(s or 0), Clamp01(v or 0)
    local i = math.floor(h * 6)
    local f = h * 6 - i
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    local sector = i % 6
    if sector == 0 then r, g, b = v, t, p
    elseif sector == 1 then r, g, b = q, v, p
    elseif sector == 2 then r, g, b = p, v, t
    elseif sector == 3 then r, g, b = p, q, v
    elseif sector == 4 then r, g, b = t, p, v
    else r, g, b = v, p, q end
    return Color3.new(r, g, b)
end
function Color3.fromHex(hex)
    hex = tostring(hex or ""):gsub("#", "")
    if #hex == 3 then
        hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
    end
    if #hex ~= 6 then return Color3.new() end
    local r = tonumber(hex:sub(1, 2), 16) or 0
    local g = tonumber(hex:sub(3, 4), 16) or 0
    local b = tonumber(hex:sub(5, 6), 16) or 0
    return Color3.fromRGB(r, g, b)
end
function Color3:ToHSV()
    local r, g, b = self.R, self.G, self.B
    local max, min = math.max(r, g, b), math.min(r, g, b)
    local delta = max - min
    local h = 0
    if delta > 0 then
        if max == r then h = ((g - b) / delta) % 6
        elseif max == g then h = (b - r) / delta + 2
        else h = (r - g) / delta + 4 end
        h = h / 6
    end
    local s = max == 0 and 0 or delta / max
    return h, s, max
end
function Color3:ToHex()
    local function part(v) return string.format("%02X", math.floor(Clamp01(v) * 255 + .5)) end
    return part(self.R) .. part(self.G) .. part(self.B)
end
function Color3:Lerp(other, alpha)
    return Color3.new(
        self.R + (other.R - self.R) * alpha,
        self.G + (other.G - self.G) * alpha,
        self.B + (other.B - self.B) * alpha
    )
end
Color3.__eq = function(a, b)
    return a.R == b.R and a.G == b.G and a.B == b.B
end

local ColorSequenceKeypoint = {}
function ColorSequenceKeypoint.new(time, color) return { Time = time, Value = color } end
local ColorSequence = {}
function ColorSequence.new(a, b) return { Keypoints = { a, b } } end
local NumberSequenceKeypoint = {}
function NumberSequenceKeypoint.new(time, value) return { Time = time, Value = value } end
local NumberSequence = {}
function NumberSequence.new(a, b) return { Keypoints = { a, b } } end

------------------------------------------------------------------ Font
local function FamilyOf(name)
    local family = name
    for _, suffix in ipairs({ "SemiBold", "ExtraBold", "Bold", "Black", "Medium", "Light", "Italic" }) do
        family = family:gsub(suffix .. "$", "")
    end
    if family == "" then family = name end
    return family
end

local FontWeight = Enum.FontWeight
local FontStyle = Enum.FontStyle

local Font = {}
function Font.fromEnum(item)
    local name = item and item.Name or "Gotham"
    local weight = FontWeight.Regular
    if name:find("Black$") then weight = FontWeight.Heavy
    elseif name:find("Bold$") then weight = FontWeight.Bold
    elseif name:find("Medium$") then weight = FontWeight.Medium
    elseif name:find("Light$") then weight = FontWeight.Light end
    local style = name:find("Italic$") and FontStyle.Italic or FontStyle.Normal
    return { Family = FamilyOf(name), Weight = weight, Style = style }
end
function Font.new(family, weight, style)
    return { Family = family, Weight = weight or FontWeight.Regular, Style = style or FontStyle.Normal }
end

------------------------------------------------------------------ instances
local GUI_CLASSES = {
    Frame = true, TextLabel = true, TextButton = true, TextBox = true,
    ImageLabel = true, ImageButton = true, ScrollingFrame = true,
    CanvasGroup = true, ViewportFrame = true, VideoFrame = true,
}

local EVENT_NAMES = {
    MouseEnter = true, MouseLeave = true, MouseButton1Click = true, MouseButton2Click = true,
    InputBegan = true, InputEnded = true, InputChanged = true, Focused = true, FocusLost = true,
    Activated = true, Changed = true, Destroying = true,
    ChildAdded = true, ChildRemoved = true, AncestryChanged = true,
    DescendantAdded = true, DescendantRemoving = true,
    SelectionGained = true, SelectionLost = true,
}

local InstanceMethods = {}
local InstanceMT = {}

local function DefaultSize()
    return UDim2.new()
end

local DEFAULTS = {
    ClassName = function(self) return rawget(self, "_class") end,
    Size = DefaultSize,
    Position = DefaultSize,
    CanvasSize = DefaultSize,
    AnchorPoint = function() return Vector2.new() end,
    Visible = true,
    Text = "",
    PlaceholderText = "",
    TextSize = 14,
    TextTransparency = 0,
    TextColor3 = function() return Color3.new(1, 1, 1) end,
    PlaceholderColor3 = function() return Color3.new(.5, .5, .5) end,
    TextXAlignment = function() return Enum.TextXAlignment.Left end,
    TextYAlignment = function() return Enum.TextYAlignment.Top end,
    TextTruncate = function() return Enum.TextTruncate.None end,
    TextWrapped = false,
    TextScaled = false,
    RichText = false,
    BackgroundColor3 = function() return Color3.new(0, 0, 0) end,
    BackgroundTransparency = 0,
    BorderSizePixel = 1,
    BorderColor3 = function() return Color3.new(0, 0, 0) end,
    ZIndex = 1,
    LayoutOrder = 0,
    Rotation = 0,
    ClipsDescendants = false,
    AutoButtonColor = true,
    Active = false,
    Selectable = false,
    AutomaticSize = function() return Enum.AutomaticSize.None end,
    AutomaticCanvasSize = function() return Enum.AutomaticSize.None end,
    ScrollBarThickness = 12,
    ScrollBarImageTransparency = 0,
    ScrollBarImageColor3 = function() return Color3.new(1, 1, 1) end,
    ScrollingDirection = function() return Enum.ScrollingDirection.Y end,
    ElasticBehavior = function() return Enum.ElasticBehavior.WhenScrollable end,
    CanvasPosition = function() return Vector2.new() end,
    AbsoluteSize = function() return Vector2.new(600, 400) end,
    AbsolutePosition = function() return Vector2.new(0, 0) end,
    AbsoluteWindowSize = function() return Vector2.new(300, 300) end,
    AbsoluteCanvasSize = function() return Vector2.new(300, 400) end,
    AbsoluteContentSize = function() return Vector2.new(300, 400) end,
    TextBounds = function() return Vector2.new(120, 14) end,
    TextFits = true,
    Image = "",
    ImageColor3 = function() return Color3.new(1, 1, 1) end,
    ImageTransparency = 0,
    Scale = 1,
    GroupTransparency = 0,
    Transparency = 0,
    Thickness = 1,
    CornerRadius = function() return UDim.new() end,
    PaddingLeft = function() return UDim.new() end,
    PaddingRight = function() return UDim.new() end,
    PaddingTop = function() return UDim.new() end,
    PaddingBottom = function() return UDim.new() end,
    Padding = function() return UDim.new() end,
    FillDirection = function() return Enum.FillDirection.Vertical end,
    SortOrder = function() return Enum.SortOrder.LayoutOrder end,
    HorizontalAlignment = function() return Enum.HorizontalAlignment.Left end,
    VerticalAlignment = function() return Enum.VerticalAlignment.Top end,
    ApplyStrokeMode = function() return Enum.ApplyStrokeMode.Contextual end,
    LineJoinMode = function() return Enum.LineJoinMode.Round end,
    Color = function() return Color3.new(1, 1, 1) end,
    Enabled = true,
    ResetOnSpawn = true,
    IgnoreGuiInset = false,
    DisplayOrder = 0,
    ZIndexBehavior = function() return Enum.ZIndexBehavior.Sibling end,
    Modal = false,
    Interactable = true,
    Font = function() return Enum.Font.Gotham end,
    FontFace = function() return Font.new("Gotham") end,
}

local function ChildList(inst)
    local list = rawget(inst, "_children")
    if not list then
        list = {}
        rawset(inst, "_children", list)
    end
    return list
end

local function PropTable(inst)
    local props = rawget(inst, "_props")
    if not props then
        props = {}
        rawset(inst, "_props", props)
    end
    return props
end

function InstanceMethods:IsA(name)
    local class = rawget(self, "_class")
    if name == "Instance" or name == "Object" then return true end
    if class == name then return true end
    if name == "GuiObject" then return GUI_CLASSES[class] == true end
    if name == "GuiBase2d" then return GUI_CLASSES[class] == true or class == "ScreenGui" end
    if name == "LayerCollector" then return class == "ScreenGui" end
    if name == "TextObject" then return class == "TextLabel" or class == "TextButton" or class == "TextBox" end
    if name == "GuiButton" then return class == "TextButton" or class == "ImageButton" end
    return false
end

function InstanceMethods:GetChildren()
    local copy = {}
    for _, child in ipairs(ChildList(self)) do
        table.insert(copy, child)
    end
    return copy
end

function InstanceMethods:GetDescendants()
    local out = {}
    local function walk(inst)
        for _, child in ipairs(ChildList(inst)) do
            table.insert(out, child)
            walk(child)
        end
    end
    walk(self)
    return out
end

function InstanceMethods:FindFirstChild(name, recursive)
    for _, child in ipairs(ChildList(self)) do
        if child.Name == name then return child end
    end
    if recursive then
        for _, child in ipairs(ChildList(self)) do
            local found = child:FindFirstChild(name, true)
            if found then return found end
        end
    end
    return nil
end

function InstanceMethods:FindFirstChildOfClass(class)
    for _, child in ipairs(ChildList(self)) do
        if child.ClassName == class then return child end
    end
    return nil
end

function InstanceMethods:WaitForChild(name)
    local found = self:FindFirstChild(name)
    if found then return found end
    return MakeInstance("Folder")
end

function InstanceMethods:GetPropertyChangedSignal(prop)
    local signals = rawget(self, "_propSignals")
    if not signals then
        signals = {}
        rawset(self, "_propSignals", signals)
    end
    if not signals[prop] then
        signals[prop] = Signal.new()
    end
    return signals[prop]
end

function InstanceMethods:GetAttribute(name)
    local attrs = rawget(self, "_attrs")
    return attrs and attrs[name] or nil
end

function InstanceMethods:SetAttribute(name, value)
    local attrs = rawget(self, "_attrs")
    if not attrs then
        attrs = {}
        rawset(self, "_attrs", attrs)
    end
    attrs[name] = value
end

function InstanceMethods:Destroy()
    if rawget(self, "_destroyed") then return end
    rawset(self, "_destroyed", true)
    local parent = PropTable(self).Parent
    if parent then
        local siblings = ChildList(parent)
        for index, child in ipairs(siblings) do
            if child == self then
                table.remove(siblings, index)
                break
            end
        end
    end
    for _, child in ipairs(self:GetChildren()) do
        child:Destroy()
    end
end

function InstanceMethods:ClearAllChildren()
    for _, child in ipairs(self:GetChildren()) do
        child:Destroy()
    end
end

function InstanceMethods:Clone()
    local copy = MakeInstance(rawget(self, "_class"))
    local props = PropTable(self)
    for key, value in pairs(props) do
        if key ~= "Parent" then PropTable(copy)[key] = value end
    end
    return copy
end

function InstanceMethods:GetFullName() return self.Name end
function InstanceMethods:TweenPosition() end
function InstanceMethods:TweenSize() end

local function FirePropSignal(inst, key)
    local signals = rawget(inst, "_propSignals")
    local sig = signals and signals[key]
    if sig then sig:Fire() end
end

-- Fires an event only when something is listening (the stub creates event
-- objects lazily), used for the DescendantAdded chain.
local function FireEvent(inst, name, arg)
    local props = rawget(inst, "_props")
    local sig = props and props[name]
    if sig and sig.Fire then sig:Fire(arg) end
end

function InstanceMT.__index(self, key)
    local method = InstanceMethods[key]
    if method then return method end
    local props = rawget(self, "_props")
    local value = props and props[key]
    if value ~= nil then return value end
    if EVENT_NAMES[key] then
        local sig = Signal.new()
        props = PropTable(self)
        props[key] = sig
        return sig
    end
    local d = DEFAULTS[key]
    if d ~= nil then
        local computed = type(d) == "function" and d(self) or d
        PropTable(self)[key] = computed
        return computed
    end
    return nil
end

function InstanceMT.__newindex(self, key, value)
    local props = PropTable(self)
    if key == "Parent" then
        local old = props.Parent
        if old and old ~= value then
            local siblings = ChildList(old)
            for index, child in ipairs(siblings) do
                if child == self then
                    table.remove(siblings, index)
                    break
                end
            end
        end
        if value and value ~= old then
            table.insert(ChildList(value), self)
            -- Roblox reports new descendants to every ancestor.
            local ancestor = value
            while ancestor do
                FireEvent(ancestor, "DescendantAdded", self)
                ancestor = PropTable(ancestor).Parent
            end
        end
        props.Parent = value
        return
    end
    if key == "Name" then
        props.Name = value
        return
    end
    props[key] = value
    FirePropSignal(self, key)
end

InstanceMT.__typename = "Instance"

local function MakeInstance(class)
    local inst = setmetatable({}, InstanceMT)
    rawset(inst, "_class", class)
    rawset(inst, "_children", {})
    PropTable(inst).Name = class
    return inst
end

local Instance = {}
function Instance.new(class, parent)
    local inst = MakeInstance(class)
    if parent then inst.Parent = parent end
    return inst
end
function instance_is(v) return IsTable(v) and getmetatable(v) == InstanceMT end

------------------------------------------------------------------ services
local RunService = {
    RenderStepped = Signal.new(),
    Heartbeat = Signal.new(),
    Stepped = Signal.new(),
}
function RunService:UnbindFromRenderStep() end
function RunService:UnbindFromBindToRenderStep() end
function RunService:BindToRenderStep() end

local UserInputService = {
    InputBegan = Signal.new(),
    InputChanged = Signal.new(),
    InputEnded = Signal.new(),
    TouchStarted = Signal.new(),
    TouchEnded = Signal.new(),
    MouseBehavior = Enum.MouseBehavior.Default,
    MouseIconEnabled = true,
}
function UserInputService:GetMouseLocation()
    return Vector2.new(640, 360)
end

local TweenService = {}
function TweenService:Create(obj, info, props)
    local completed = Signal.new()
    local tween
    tween = {
        Play = function()
            for key, value in pairs(props or {}) do
                pcall(function() obj[key] = value end)
            end
            completed:Fire()
        end,
        Cancel = function() end,
        Pause = function() end,
        Completed = completed,
    }
    return tween
end

local HttpService = {
    JSONEncode = function(_, v) return "{}" end,
    JSONDecode = function(_, v) return {} end,
    GenerateGUID = function() return "00000000-0000-0000-0000-000000000000" end,
}

local PlayerGui = MakeInstance("PlayerGui")
local LocalPlayer = MakeInstance("Player")
PropTable(LocalPlayer).Name = "TestPlayer"
PropTable(LocalPlayer).DisplayName = "Test Player"
PropTable(LocalPlayer).UserId = 1
PropTable(LocalPlayer).PlayerGui = PlayerGui
PropTable(LocalPlayer).CharacterAdded = Signal.new()
PropTable(LocalPlayer).CharacterRemoving = Signal.new()
ChildList(LocalPlayer)

local Players = {
    LocalPlayer = LocalPlayer,
    PlayerAdded = Signal.new(),
    PlayerRemoving = Signal.new(),
    GetPlayers = function() return { LocalPlayer } end,
    GetUserThumbnailAsync = function()
        return "rbxthumb://type=AvatarHeadShot&id=1&w=100&h=100", false
    end,
}
function Players:get_local() return LocalPlayer end

local Stats = {
    Network = {
        ServerStatsItem = {
            ["Data Ping"] = { GetValue = function() return 42 end },
        },
    },
}

local CoreGui = MakeInstance("CoreGui")

local Services = {
    Players = Players,
    UserInputService = UserInputService,
    RunService = RunService,
    TweenService = TweenService,
    HttpService = HttpService,
    Stats = Stats,
    CoreGui = CoreGui,
}

local game = {
    PlaceId = 0,
    JobId = "job",
    GetService = function(_, name)
        local service = Services[name]
        if service then return service end
        service = {}
        Services[name] = service
        return service
    end,
}

------------------------------------------------------------------ globals
local task_queue = {}

local task = {
    spawn = function(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then Record("task.spawn", err) end
    end,
    defer = function(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then Record("task.defer", err) end
    end,
    delay = function(_, fn, ...)
        table.insert(task_queue, { fn = fn, args = { ... } })
    end,
    wait = function() end,
    cancel = function() end,
}

local function FlushDelayed(limit)
    local budget = limit or 200
    while #task_queue > 0 and budget > 0 do
        local job = table.remove(task_queue, 1)
        local ok, err = pcall(job.fn, table.unpack(job.args))
        if not ok then Record("task.delay", err) end
        budget -= 1
    end
end

local real_typeof = typeof
local function typeof_stub(v)
    if IsTable(v) then
        local mt = getmetatable(v)
        if mt and mt.__typename then return mt.__typename end
        return "table"
    end
    return real_typeof(v)
end

local SmokeEnv = {
    Errors = Errors,
    RunService = RunService,
    UserInputService = UserInputService,
    TweenService = TweenService,
    LocalPlayer = LocalPlayer,
    PlayerGui = PlayerGui,
    FlushDelayed = FlushDelayed,
    Record = Record,
}

-- The library is wrapped in a function inside this same chunk, so these locals
-- resolve as upvalues for it. No _G writes are needed (and Luau freezes _G).
local workspace = MakeInstance("Workspace")
local TweenInfo = { new = function(t, s, d) return { Time = t, EasingStyle = s, EasingDirection = d } end }
local typeof = typeof_stub
local warn = function(...) print("[warn]", ...) end
local setclipboard = function() end
local getgenv = function() return SmokeEnv end
local getgc = function() return {} end
local getreg = function() return {} end