--[[
    UILib - sidebar-tab UI library for Roblox (Luau)

    local Library = require(module)                       -- or loadstring(readfile("UILib.lua"))()
    local Window  = Library.new{
        Title = "Menu",
        User  = { Name = "Display Name", Tag = "@username", UID = 1234, Buttons = { { Text = "Copy UID", Callback = function() end } } },
        Text  = { Search = "Search" },                      -- every library string can be overridden
    }
    local Tab = Window:AddTab{ Name = "Main", Icon = "rbxassetid://0" }   -- Icon | Glyph | (nothing = placeholder)

    -- sections sit in two columns by default; Full = true spans the whole page
    local Left  = Tab:AddSection{ Side = "Left",  Title = "Left"  }
    local Right = Tab:AddSection{ Side = "Right", Title = "Right" }
    local Wide  = Tab:AddSection{ Full = true,    Title = "Wide"  }
    Left:AddToggle{ Name = "Example", Default = true, Flag = "Example", Callback = print }

    -- status icons (the little grid above the config selector). They light up with the accent
    -- colour while their Flag is true, and clicking one toggles that feature. They are split evenly
    -- over two rows, StatusPerRow per row (default 4, so 8 icons = 4 + 4): Library.new{ StatusPerRow = 4 }
    Window:AddStatusIcon{ Name = "Example", Flag = "Example", Icon = "rbxassetid://0" }

    -- Menu behaviour is driven through public methods so YOU build the settings tab:
    --   SetScale, SetMenuKey, SetAnimSpeed, SetNotificationsEnabled, SetNotificationPosition,
    --   SetTabAnimation, SetAccent, SetHover, SetPalette, SetWatermark, SetKeybindList,
    --   SetCursor{Mode,Style,Size,Effects,Color,CustomEnabled},
    --   SaveConfig, LoadConfig, GetConfigNames, LoadConfigs, Autoload, SetAutoload,
    --   AddStatusIcon, SetStatusPerRow, SetSettingsTab, SetMinimized, Copy, Notify, Toggle, Destroy
]]

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local Stats        = game:GetService("Stats")
local GuiService   = game:GetService("GuiService")
local TextService  = game:GetService("TextService")

local rgb = Color3.fromRGB
local Library = {}
Library.__index = Library

local ROOT_W, ROOT_H, SIDEBAR = 760, 500, 190
local HEADER, MINI_W = 30, 250        -- top strip (minimize / close live here) and the width of the minimized bar

-- Fonts. BuilderSans is the closest built-in Roblox font to the reference (clean humanist
-- sans). Override any entry with Library.new{ Fonts = { Medium = Enum.Font.Roboto } }.
local function FontEnum(name, fallback)
	local ok, f = pcall(function() return Enum.Font[name] end)
	return (ok and f) or fallback
end
Library.Fonts = {
	Regular = FontEnum("BuilderSans", Enum.Font.Gotham),
	Medium  = FontEnum("BuilderSansMedium", Enum.Font.GothamMedium),
	Bold    = FontEnum("BuilderSansBold", Enum.Font.GothamBold),
}
local Fonts = Library.Fonts

Library.Palettes = {
	Default  = { Window = rgb(21,21,27),  Panel = rgb(27,27,34),  Element = rgb(36,36,45),  Border = rgb(45,45,56),  Text = rgb(240,240,246), SubText = rgb(122,122,140) },
	Navy     = { Window = rgb(14,16,29),  Panel = rgb(19,22,38),  Element = rgb(28,32,52),  Border = rgb(36,41,64),  Text = rgb(240,243,252), SubText = rgb(100,112,150) },
	Midnight = { Window = rgb(9,11,21),   Panel = rgb(14,17,31),  Element = rgb(22,26,45),  Border = rgb(32,38,64),  Text = rgb(236,240,255), SubText = rgb(118,127,165) },
	Rose     = { Window = rgb(20,14,17),  Panel = rgb(28,19,23),  Element = rgb(40,27,33),  Border = rgb(58,39,47),  Text = rgb(250,238,242), SubText = rgb(150,118,129) },
	Forest   = { Window = rgb(12,18,15),  Panel = rgb(17,26,21),  Element = rgb(25,38,31),  Border = rgb(36,54,44),  Text = rgb(236,248,240), SubText = rgb(114,145,127) },
	Light    = { Window = rgb(236,237,241), Panel = rgb(248,248,251), Element = rgb(228,229,235), Border = rgb(206,208,218), Text = rgb(28,28,36), SubText = rgb(110,112,128) },
}

-- Names the rest of the script already uses (UI.Theme.Cyan, Panel, TextMuted...)
-- resolved to the palette above on every refresh, so old modules keep working.
Library.ThemeAliases = {
	Background = "Window", BackgroundLight = "Window", Black = "Window",
	PanelLight = "Panel", PanelHover = "Element",
	ElementHover = "Hover",
	TextSecondary = "SubText", TextMuted = "SubText",
	Cyan = "Accent", CyanDark = "Accent", CyanDim = "Accent",
	White = "Text",
	BorderDim = "Border",
}

-- Fallback strings. Pass Library.new{ Text = { ... } } to override any of them.
Library.DefaultText = {
	Search               = "Search",
	Notification         = "Notification",
	ConfigSaved          = "Config saved",
	ConfigLoaded         = "Config loaded",
	AutoloadSet          = "Autoload set",
	Copied               = "Copied",
	CopyUID              = "Copy UID",
	ClipboardUnavailable = "Clipboard is not available here",
	UserFallback         = "User",
	KeybindListTitle     = "Keybinds",
	KeyNone              = "None",
	Close                = "×",
}

------------------------------------------------------------------ helpers

-- Any press that lands on a control (button, textbox), a section panel, a dropdown list or a popup stamps BlockClock.
-- The window only starts dragging when a press happened WITHOUT such a stamp. No coordinates, no z-order guessing.
local BlockClock = -1
local function Blocks(obj)
	obj.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then BlockClock = os.clock() end
	end)
end
local function New(class, props, kids)
	local o = Instance.new(class)
	if class == "TextButton" or class == "TextBox" or class == "ImageButton" then Blocks(o) end
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then parent = v else o[k] = v end
	end
	for _, c in ipairs(kids or {}) do c.Parent = o end
	if parent then o.Parent = parent end
	return o
end
local function Round(p, r) return New("UICorner", { CornerRadius = UDim.new(0, r), Parent = p }) end
local function Stroke(p, c, t)
	return New("UIStroke", { Color = c or rgb(45,45,56), Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p })
end
local function Chevron(parent, pos)
	local c = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(10, 6), AnchorPoint = Vector2.new(.5,.5), Position = pos, Parent = parent })
	for i, sx in ipairs({ 2.5, 7.5 }) do
		New("Frame", { Size = UDim2.fromOffset(7, 1.6), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromOffset(sx, 2.5),
			Rotation = i == 1 and 45 or -45, BackgroundColor3 = rgb(150,150,165), BorderSizePixel = 0, Parent = c })
	end
	return c
end

local HasFS = (typeof(writefile) == "function") and (typeof(readfile) == "function") and (typeof(isfolder) == "function")

local function Encode(v)
	local t = typeof(v)
	if t == "Color3" then return { _t = "c", v.R, v.G, v.B }
	elseif t == "EnumItem" then return { _t = "e", tostring(v.EnumType), v.Name } end
	return v
end
local function Decode(v)
	if type(v) == "table" and v._t == "c" then return Color3.new(v[1], v[2], v[3]) end
	if type(v) == "table" and v._t == "e" then
		local ok, r = pcall(function() return Enum[v[1]][v[2]] end)
		return ok and r or nil
	end
	return v
end

local function KeyMatches(key, input)
	if not key then return false end
	if typeof(key) == "EnumItem" and key.EnumType == Enum.KeyCode then
		return input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == key
	end
	return input.UserInputType == key
end

local function GuiParent()
	if typeof(gethui) == "function" then
		local ok, h = pcall(gethui)
		if ok and h then return h end
	end
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok and cg then
		local probe = Instance.new("Folder")
		local ok2 = pcall(function() probe.Parent = cg end)
		probe:Destroy()
		if ok2 then return cg end
	end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- polygon scanline fill (used to draw the arrow cursor without any image asset)
local ARROW = { {0,0}, {0,16}, {3.8,12.6}, {6.6,18.6}, {9,17.5}, {6.3,11.6}, {11.4,11.6} }
local function PolySpans(poly, k)
	local spans, maxY = {}, 0
	for _, p in ipairs(poly) do maxY = math.max(maxY, p[2]) end
	for y = 0, math.ceil(maxY * k) - 1 do
		local sy, xs = (y + .5) / k, {}
		for i = 1, #poly do
			local a, b = poly[i], poly[i % #poly + 1]
			if (a[2] <= sy and b[2] > sy) or (b[2] <= sy and a[2] > sy) then
				table.insert(xs, a[1] + (sy - a[2]) / (b[2] - a[2]) * (b[1] - a[1]))
			end
		end
		table.sort(xs)
		for i = 1, #xs - 1, 2 do table.insert(spans, { xs[i] * k, y, (xs[i + 1] - xs[i]) * k }) end
	end
	return spans
end

------------------------------------------------------------------ core
function Library.new(o)
	o = o or {}
	local self = setmetatable({}, Library)
	for k, v in pairs(o.Fonts or {}) do Fonts[k] = v end
	self.Title = o.Title or "Menu"
	self.User = o.User or {}
	self.Text = {}
	for k, v in pairs(Library.DefaultText) do self.Text[k] = v end
	for k, v in pairs(o.Text or {}) do self.Text[k] = v end
	self.Theme = { Accent = o.Accent or rgb(79,124,245), Hover = rgb(72,76,92), Danger = rgb(255,92,92), Warning = rgb(255,190,92) }
	for k, v in pairs(Library.Palettes.Default) do self.Theme[k] = v end
	self.Palette = "Default"
	--// Only the colours that differ from these are saved as a custom theme.
	self._DefaultTheme = table.clone(self.Theme)
	self._DefaultTextScale = 1
	self._DefaultWindowSize = Vector2.new(ROOT_W, ROOT_H)
	self._binds, self.Flags, self._setters, self._flagListeners = {}, {}, {}, {}
	self.Tabs, self.Keybinds, self.Configs, self.StatusIcons, self.ConfigSelectors = {}, {}, {}, {}, {}
	self.AnimSpeed = 1
	self.StatusPerRow = math.max(1, math.floor(o.StatusPerRow or 4))
	self.BaseScale = 1
	self.SingleColumn = o.SingleColumn == true   -- true = every section is full width
	self._open = true
	self.MenuKey = Enum.KeyCode.Insert
	self.TabAnimation = "Fade"
	self.Notifications = { Enabled = true, Position = "Bottom right" }
	self.Cursor = { Mode = "Menu open", Style = "Arrow", Size = 100, Effects = true, CustomEnabled = false, Color = rgb(70,160,255) }
	self.ConfigName = o.ConfigName or "Default"
	self.Folder = o.Folder or (self.Title:gsub("[^%w]", "") .. "Configs")
	self._conns = {}

	local parent = o.Parent or GuiParent()
	self.Gui = New("ScreenGui", { Name = self.Title, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = parent })
	self.ScreenGui = self.Gui

	-- Active = true makes the whole window sink input, so clicks (left AND right)
	-- over the menu never reach the game / camera underneath it.
	--
	-- A plain Frame, not a CanvasGroup: a group renders everything inside it
	-- to its own texture first, and this one wraps the largest thing on screen
	-- -- every tab, every row, the whole list -- so the client pays for that
	-- extra full-screen pass on every frame the window is open. There is no
	-- fading left to do that would need one.
	self.Root = New("Frame", { Size = UDim2.fromOffset(ROOT_W, ROOT_H), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5),
		BorderSizePixel = 0, Active = true, Parent = self.Gui })
	Round(self.Root, 10)
	self:Themed(self.Root, { BackgroundColor3 = "Window" })
	self:Themed(Stroke(self.Root), { Color = "Border" })
	self.Scale = New("UIScale", { Parent = self.Root })
	self.Window = self.Root
	-- Root receives every press made inside the window (Roblox also reports presses on children to their ancestors).
	-- One frame later we know whether a control / panel / list claimed it; only unclaimed presses drag the window.
	self.Root.InputBegan:Connect(function(i)
		if i.UserInputType ~= Enum.UserInputType.MouseButton1 and i.UserInputType ~= Enum.UserInputType.Touch then return end
		if self._activeDrag or self._listening or not self.Root.Visible then return end
		local token = {}
		self._pending = token
		local start, sp = Vector2.new(i.Position.X, i.Position.Y), self.Root.Position
		task.spawn(function()
			task.wait()
			if self._pending ~= token then return end                  -- released already
			self._pending = nil
			if os.clock() - BlockClock < .08 then return end             -- a control / panel claimed the press
			self:_beginWindowDrag(start, sp)
		end)
	end)

	self.Sidebar = New("Frame", { Size = UDim2.new(0, SIDEBAR, 0, ROOT_H), BackgroundTransparency = 1, BorderSizePixel = 0, Parent = self.Root })
	local sline = New("Frame", { Size = UDim2.new(0,1,1,0), Position = UDim2.fromOffset(SIDEBAR - 1, 0), BorderSizePixel = 0, ZIndex = 2, Parent = self.Root })
	self.SidebarLine = sline
	self:Themed(sline, { BackgroundColor3 = "Border" })
	self.Content = New("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(SIDEBAR, HEADER), Size = UDim2.new(1, -SIDEBAR, 0, ROOT_H - HEADER), Parent = self.Root })

	-- popups live INSIDE the window, so they are positioned relative to it
	self.Blocker = New("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1,1), Visible = false, ZIndex = 90, Parent = self.Root })
	self.Blocker.MouseButton1Click:Connect(function() self:ClosePopup() end)
	self.Overlay = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 100, Parent = self.Root })
	-- window-coloured sheet that fades over the sidebar + page while minimizing / restoring (title bar stays above it)
	self.Curtain = New("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1,1), ZIndex = 10, Visible = false, Parent = self.Root })
	self:Themed(self.Curtain, { BackgroundColor3 = "Window" })

	-- Popups that must be able to leave the window (the config list opens BELOW the sidebar) live here,
	-- outside the clipped window. They are closed from the pointer's position (see the InputBegan
	-- connection below), not by a full screen button: a screen sized GuiButton takes the mouse from
	-- the game, and with it the right drag that turns the camera.
	self.FloatLayer = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 50, Parent = self.Gui })

	self:_buildSidebar()
	self:_buildHeader()
	self:_buildNotifHolder()
	self:_buildWatermark()
	self:_buildKeybindList()
	self:_buildCursor()
	self:Bind(function() self:_paintTabs(true) end)

	--// There is deliberately no modal button and no screen sized button of any
	--// kind. Either one takes every input on the screen, and with it the right
	--// mouse drag that turns the camera. The window itself (Root.Active) takes
	--// only the clicks that land on it.

	-- global input
	table.insert(self._conns, UIS.InputChanged:Connect(function(i)
		if self._activeDrag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			self._activeDrag(Vector2.new(i.Position.X, i.Position.Y))
		end
	end))
	table.insert(self._conns, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then self._activeDrag = nil; self._pending = nil end
	end))
	table.insert(self._conns, UIS.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 and self.Cursor.Effects and self.CursorHolder.Visible then
			self:_ripple()
		end
		--// A float popup can hang outside the window, where nothing covers the
		--// click, so it is dismissed by measuring the pointer against it.
		local float = self._popupFloat
		if float and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			local pos = UIS:GetMouseLocation()
			local ap, asz = float.AbsolutePosition, float.AbsoluteSize
			if pos.X < ap.X or pos.Y < ap.Y or pos.X > ap.X + asz.X or pos.Y > ap.Y + asz.Y then
				self:ClosePopup()
			end
		end
		if self._listening or UIS:GetFocusedTextBox() then return end
		if KeyMatches(self.MenuKey, i) then self:Toggle() return end
		for _, kb in ipairs(self.Keybinds) do
			if kb.Callback and KeyMatches(kb.Key, i) then task.spawn(kb.Callback, kb.Key) end
		end
	end))
	local frames, last = 0, os.clock()
	table.insert(self._conns, RunService.RenderStepped:Connect(function()
		frames += 1
		if os.clock() - last >= 1 then self:_updateWatermark(frames); frames, last = 0, os.clock() end
		self:_stepCursor()
	end))
	pcall(function()
		RunService:BindToRenderStep("UILibUnlock" .. self.Title, Enum.RenderPriority.Last.Value, function()
			--// A clickable cursor over the window, and nothing else. The mouse is
			--// only released while the pointer is actually over the menu: that
			--// is what lets a button be clicked, and it leaves the camera alone
			--// everywhere else. Holding it at Default every frame -- the old way
			--// -- stopped a right drag from turning the camera at all, because
			--// the game locks the pointer for as long as the drag lasts.
			local open = self.Root.Visible and not self._minimized

			if open then
				local Pointer = UIS:GetMouseLocation()
				local At, Size = self.Root.AbsolutePosition, self.Root.AbsoluteSize
				local Over = Pointer.X >= At.X
					and Pointer.X <= At.X + Size.X
					and Pointer.Y >= At.Y
					and Pointer.Y <= At.Y + Size.Y

				if Over then
					-- Remember what the game had the mouse doing, so leaving the
					-- window puts it back instead of leaving the camera unlocked.
					if not self._mouseUnlocked then
						self._mouseUnlocked = true
						self._prevMouseBehavior = UIS.MouseBehavior
					end

					if UIS.MouseBehavior ~= Enum.MouseBehavior.Default then
						UIS.MouseBehavior = Enum.MouseBehavior.Default
					end
				elseif self._mouseUnlocked then
					self._mouseUnlocked = false
					pcall(function()
						UIS.MouseBehavior = self._prevMouseBehavior or Enum.MouseBehavior.Default
					end)
				end
			elseif self._mouseUnlocked then
				self._mouseUnlocked = false
				pcall(function()
					UIS.MouseBehavior = self._prevMouseBehavior or Enum.MouseBehavior.Default
				end)
			end
		end)
	end)

	if o.ManualLoading then
		self:_buildLoader()
	end

	self:Refresh()
	return self
end

-- owner (optional): the instance this binding paints. Once it is destroyed the binding is dropped on the
-- next Refresh. Before, every popup / tooltip / notification left its bindings behind forever, so each
-- Refresh got slower the more you had opened things.
function Library:Bind(fn, owner) table.insert(self._binds, { fn = fn, owner = owner }); pcall(fn); return fn end

function Library:Themed(obj, map)
	self:Bind(function() for p, k in pairs(map) do obj[p] = self.Theme[k] end end, obj)
	return obj
end

function Library:Refresh()
	for old, new in pairs(Library.ThemeAliases) do
		if self.Theme[new] ~= nil then self.Theme[old] = self.Theme[new] end
	end
	local alive = {}
	for _, b in ipairs(self._binds) do
		if not b.owner or b.owner.Parent then
			alive[#alive + 1] = b
			pcall(b.fn)
		end
	end
	self._binds = alive
end
-- Several changes in one frame (dragging a colour picker fires one per mouse move) collapse into ONE Refresh.
function Library:QueueRefresh()
	if self._refreshQueued then return end
	self._refreshQueued = true
	task.defer(function() self._refreshQueued = false; self:Refresh() end)
end
function Library:Tween(obj, props, t, style)
	local tw = TweenService:Create(obj, TweenInfo.new((t or .15) / math.max(self.AnimSpeed, .1), style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
function Library:Label(parent, text, p)
	p = p or {}
	local baseSize = p.TextSize or p.Size or 14
	--// A nil Text assignment is accepted by a stub but throws in the client, so
	--// every label goes through here with a real string.
	local l = New("TextLabel", { BackgroundTransparency = 1, Text = text ~= nil and tostring(text) or "", TextSize = math.round(baseSize * (self.TextScale or 1)),
		TextXAlignment = p.AlignRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
		Font = p.Bold and Fonts.Bold or Fonts.Medium, Position = p.Position or UDim2.new(),
		Size = p.SizeUDim or UDim2.fromScale(1,1), TextTruncate = Enum.TextTruncate.AtEnd, Parent = parent })
	local ref = { k = p.Color or "Text" }
	self:Bind(function() l.TextColor3 = self.Theme[ref.k] end, l)
	--// Font and text scale are global, so a label made before either changes
	--// follows it.
	local weight = p.Bold and "Bold" or "Medium"
	self:Bind(function()
		l.Font = Fonts[weight]
		l.TextSize = math.round(baseSize * (self.TextScale or 1))
	end, l)
	return l, ref
end
function Library:_hover(btn, stroke)
	btn.MouseEnter:Connect(function() self:Tween(stroke, { Color = self.Theme.Hover }, .12) end)
	btn.MouseLeave:Connect(function() self:Tween(stroke, { Color = self.Theme.Border }, .12) end)
	self:Bind(function() stroke.Color = self.Theme.Border end, stroke)
end
function Library:_focusStroke(box, stroke)
	box.Focused:Connect(function() self:Tween(stroke, { Color = self.Theme.Accent }, .12) end)
	box.FocusLost:Connect(function() self:Tween(stroke, { Color = self.Theme.Border }, .12) end)
end

-- flags: every element writes through _setFlag so status icons (and anything else) can react
function Library:_setFlag(flag, value)
	self.Flags[flag] = value
	local l = self._flagListeners[flag]
	if l then for _, fn in ipairs(l) do pcall(fn, value) end end
end
function Library:OnFlag(flag, fn)
	self._flagListeners[flag] = self._flagListeners[flag] or {}
	table.insert(self._flagListeners[flag], fn)
end

-- checkmark drawn from two rotated bars (renders on every font); returns setter(on, animate)
function Library:_checkMark(box)
	local bars = {}
	for _, d in ipairs({ { 5, 6.0, 11.0, 45 }, { 9.8, 10.5, 9.0, -49.4 } }) do
		local f = New("Frame", { Size = UDim2.fromOffset(d[1], 2), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromOffset(d[2], d[3]),
			Rotation = d[4], BackgroundColor3 = Color3.new(1,1,1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2, Parent = box })
		Round(f, 1)
		table.insert(bars, f)
	end
	return function(on, animate)
		for _, f in ipairs(bars) do
			if animate then self:Tween(f, { BackgroundTransparency = on and 0 or 1 }, .14)
			else f.BackgroundTransparency = on and 0 or 1 end
		end
	end
end

-- icon slot used by tabs and status icons: Icon (asset id) | Glyph (text) | placeholder shape
-- returns { SetColor = function(color, animate) }
function Library:_makeIcon(parent, o, size, pos, z)
	local win, targets = self, {}
	local obj = {}
	if o.Icon and o.Icon ~= "" then
		local img = New("ImageLabel", { BackgroundTransparency = 1, Image = o.Icon, Size = UDim2.fromOffset(size,size), Position = pos, ZIndex = z, Parent = parent })
		targets = { { img, "ImageColor3" } }
	elseif o.Glyph then
		local l = New("TextLabel", { BackgroundTransparency = 1, Text = o.Glyph, Font = Fonts.Bold, TextSize = size, Size = UDim2.fromOffset(size,size),
			Position = pos, ZIndex = z, Parent = parent })
		targets = { { l, "TextColor3" } }
	else
		local box = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size,size), Position = pos, ZIndex = z, Parent = parent })
		Round(box, math.max(3, size * .22))
		local st = Stroke(box, nil, 1.5)
		local dot = New("Frame", { Size = UDim2.fromOffset(size * .3, size * .3), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5),
			BorderSizePixel = 0, ZIndex = z, Parent = box })
		Round(dot, size)
		targets = { { st, "Color" }, { dot, "BackgroundColor3" } }
	end
	function obj.SetColor(c, animate)
		for _, t in ipairs(targets) do
			if animate then win:Tween(t[1], { [t[2]] = c }, .15) else t[1][t[2]] = c end
		end
	end
	return obj
end

------------------------------------------------------------------ public settings API
function Library:SetAccent(c) self.Theme.Accent = c; self:QueueRefresh() end
function Library:SetHover(c) self.Theme.Hover = c; self:QueueRefresh() end
function Library:SetPalette(name)
	local p = Library.Palettes[name]; if not p then return end
	self.Palette = name
	for k, v in pairs(p) do self.Theme[k] = v end
	self:QueueRefresh()
end
function Library:SetScale(v)
	self.BaseScale = v
	if self._open then self.Scale.Scale = v end
end
function Library:SetMenuKey(k) if k then self.MenuKey = k end end
function Library:SetAnimSpeed(v) self.AnimSpeed = math.max(v, .1) end
function Library:SetTabAnimation(name) self.TabAnimation = name end
function Library:SetNotificationsEnabled(b) self.Notifications.Enabled = b and true or false end
function Library:SetWatermark(b) self.Watermark.Visible = b and true or false end
function Library:SetKeybindList(b) self.KeybindFrame.Visible = b and true or false end
function Library:SetCursor(opts)
	for k, v in pairs(opts or {}) do self.Cursor[k] = v end
	self:_styleCursor()
end
function Library:SetSettingsTab(tab) self.SettingsTab = tab end

function Library:SetStatusPerRow(n) self.StatusPerRow = math.max(1, math.floor(n or 4)); self:_layoutStatus() end

-- Collapses the window to a small title bar and back (the top-left corner stays put). The x hides the menu.
function Library:SetMinimized(state)
	if state == nil then state = not self._minimized end
	state = state and true or false
	if state == (self._minimized or false) or self._minBusy then return end
	self._minimized, self._minBusy = state, true
	if self._setMinIcon then self._setMinIcon(state) end
	self:ClosePopup(true); self:_hideTip(true)
	local sp = math.max(self.AnimSpeed, .1)
	local s = self.BaseScale
	local dx, dy = (MINI_W - ROOT_W) / 2 * s, (HEADER - ROOT_H) / 2 * s
	if not state then dx, dy = -dx, -dy end
	local curtain = self.Curtain
	local function setBody(v) self.Sidebar.Visible, self.Content.Visible, self.HeaderLine.Visible, self.SidebarLine.Visible = v, v, v, v end
	local function resize()
		local p = self.Root.Position
		self:Tween(self.Root, {
			Size = state and UDim2.fromOffset(MINI_W, HEADER) or UDim2.fromOffset(ROOT_W, ROOT_H),
			Position = UDim2.new(p.X.Scale, p.X.Offset + dx, p.Y.Scale, p.Y.Offset + dy),
		}, .22, Enum.EasingStyle.Quint)
		self:Tween(self.HeaderTitle, { Position = UDim2.fromOffset(state and 14 or SIDEBAR + 16, 0) }, .22, Enum.EasingStyle.Quint)
	end
	task.spawn(function()
		if state then
			-- 1) the sidebar and page fade out while the window is still full size ...
			curtain.BackgroundTransparency = 1; curtain.Visible = true
			self:Tween(curtain, { BackgroundTransparency = 0 }, .12)
			task.wait(.13 / sp)
			setBody(false); curtain.Visible = false
			-- 2) ... and only then does the empty window shrink down to the title bar
			resize()
			task.wait(.23 / sp)
		else
			-- 1) the empty window grows back first ...
			resize()
			task.wait(.23 / sp)
			-- 2) ... then the sidebar and page fade in
			curtain.BackgroundTransparency = 0; curtain.Visible = true
			setBody(true)
			self:Tween(curtain, { BackgroundTransparency = 1 }, .16)
			task.wait(.17 / sp)
			curtain.Visible = false
		end
		self._minBusy = false
	end)
end
function Library:Copy(text, title)
	local fn = (typeof(setclipboard) == "function" and setclipboard) or (typeof(toclipboard) == "function" and toclipboard) or nil
	if fn and pcall(fn, tostring(text)) then
		self:Notify{ Title = title or self.Text.Copied, Text = tostring(text), Force = true }
	else
		self:Notify{ Title = title or self.Text.Copied, Text = self.Text.ClipboardUnavailable, Force = true }
	end
end

--// Whether the window is on screen. A minimised window is a title bar in the
--// corner, so it does not cover the world the way the full window does.
function Library:IsOpen()
	return self._open == true and self._minimized ~= true
end
function Library:Toggle(state)
	if state == nil then state = not self._open end
	if state == self._open then return end
	self._open = state
	if state then
		self.Root.Visible = true
		self.Scale.Scale = self.BaseScale * .95
		self:Tween(self.Scale, { Scale = self.BaseScale }, .22, Enum.EasingStyle.Quint)
	else
		self:ClosePopup(true)
		self:_hideTip()
		self:Tween(self.Scale, { Scale = self.BaseScale * .96 }, .15)
		task.delay(.16 / math.max(self.AnimSpeed, .1), function() if not self._open then self.Root.Visible = false end end)
	end
end
function Library:Destroy()
	for _, c in ipairs(self._conns) do c:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep("UILibUnlock" .. self.Title) end)
	if self._mouseUnlocked then
		self._mouseUnlocked = false
		pcall(function()
			UIS.MouseBehavior = self._prevMouseBehavior or Enum.MouseBehavior.Default
		end)
	end
	UIS.MouseIconEnabled = true
	self.Gui:Destroy(); self.CursorGui:Destroy()
end

function Library:_listenKey(cb, onCancel)
	if self._listening then return end
	self._listening = true
	local c; c = UIS.InputBegan:Connect(function(i)
		local k
		if i.UserInputType == Enum.UserInputType.Keyboard then
			k = (i.KeyCode ~= Enum.KeyCode.Escape) and i.KeyCode or false
		elseif i.UserInputType == Enum.UserInputType.MouseButton2 or i.UserInputType == Enum.UserInputType.MouseButton3 then
			k = i.UserInputType
		elseif i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			c:Disconnect()
			task.defer(function() self._listening = false end)
			if onCancel then task.spawn(onCancel) end
			return
		else
			return
		end
		c:Disconnect()
		task.defer(function() self._listening = false end)
		cb(k or nil)
	end)
end

------------------------------------------------------------------ dragging + header
-- Starts a window drag (called from the Root.InputBegan handler in Library.new).
function Library:_beginWindowDrag(start, sp)
	if self._activeDrag or not self.Root.Visible then return end
	self._activeDrag = function(pos)
		local d = pos - start
		self.Root.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
	end
end

-- top strip of the window: title on the left, minimize (-) and close (x) in the top-right corner
function Library:_buildHeader()
	local root = self.Root
	self.HeaderTitle = (self:Label(root, self.Title, { Bold = true, TextSize = 13, Color = "SubText", Position = UDim2.fromOffset(SIDEBAR + 16, 0), SizeUDim = UDim2.new(1, -80, 0, HEADER) }))
	self.HeaderTitle.ZIndex = 20
	self.HeaderLine = New("Frame", { Position = UDim2.fromOffset(SIDEBAR, HEADER - 1), Size = UDim2.new(1, -SIDEBAR, 0, 1), BorderSizePixel = 0, ZIndex = 2, Parent = root })
	self:Themed(self.HeaderLine, { BackgroundColor3 = "Border" })

	local close = New("TextButton", { AnchorPoint = Vector2.new(1,0), Position = UDim2.new(1,-12,0,(HEADER - 18) / 2), Size = UDim2.fromOffset(18,18),
		Text = self.Text.Close, Font = Fonts.Bold, TextSize = 14, TextColor3 = Color3.new(1,1,1), AutoButtonColor = false,
		BackgroundColor3 = self.Theme.Danger, BorderSizePixel = 0, ZIndex = 20, Parent = root })
	Round(close, 4)
	self:Bind(function() close.BackgroundColor3 = self.Theme.Danger end)
	close.MouseEnter:Connect(function() self:Tween(close, { BackgroundColor3 = rgb(235,91,91) }, .1) end)
	close.MouseLeave:Connect(function() self:Tween(close, { BackgroundColor3 = self.Theme.Danger }, .1) end)
	close.MouseButton1Click:Connect(function() self:Toggle(false) end)
	self.CloseButton = close

	local min = New("TextButton", { AnchorPoint = Vector2.new(1,0), Position = UDim2.new(1,-36,0,(HEADER - 18) / 2), Size = UDim2.fromOffset(18,18),
		Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 20, Parent = root })
	Round(min, 4)
	self:Themed(min, { BackgroundColor3 = "Element" })
	local dash = New("Frame", { AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5), Size = UDim2.fromOffset(9,2), BorderSizePixel = 0, ZIndex = 21, Parent = min })
	Round(dash, 1)
	self:Themed(dash, { BackgroundColor3 = "SubText" })
	-- while the window is collapsed the dash turns into a small square outline ("restore")
	local sq = New("Frame", { AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5), Size = UDim2.fromOffset(6,6), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 21, Parent = min })
	Round(sq, 2)
	local sqs = Stroke(sq, nil, 1.5); sqs.Transparency = 1
	self:Themed(sqs, { Color = "SubText" })
	min.MouseEnter:Connect(function()
		self:Tween(min, { BackgroundTransparency = .4 }, .1)
		self:Tween(dash, { BackgroundColor3 = self.Theme.Text }, .1)
		self:Tween(sqs, { Color = self.Theme.Text }, .1)
	end)
	min.MouseLeave:Connect(function()
		self:Tween(min, { BackgroundTransparency = 1 }, .1)
		self:Tween(dash, { BackgroundColor3 = self.Theme.SubText }, .1)
		self:Tween(sqs, { Color = self.Theme.SubText }, .1)
	end)
	min.MouseButton1Click:Connect(function() self:SetMinimized() end)
	self._setMinIcon = function(collapsed)
		self:Tween(dash, { BackgroundTransparency = collapsed and 1 or 0 }, .15)
		self:Tween(sqs, { Transparency = collapsed and 0 or 1 }, .15)
	end
	self.MinimizeButton = min
end

------------------------------------------------------------------ popups / tooltips

function Library:ClosePopup(instant)
	local p = self._popup
	if p then
		self._popup, self._popupOwner = nil, nil
		local close = self._popupClose
		self._popupClose = nil
		if close then close(p, instant) else p:Destroy() end   -- the config drawer slides shut, everything else just goes
	end
	self.Blocker.Visible = false
	self._popupFloat = nil
end

-- Popups are children of the window, so everything is measured against the
-- window itself (anchor position minus window position, divided by its scale).
-- When opening upwards the popup's BOTTOM edge sits 4px above the anchor.

function Library:_relative(anchor)
	local rs = self.Scale.Scale
	if rs <= 0 then rs = 1 end
	return (anchor.AbsolutePosition - self.Root.AbsolutePosition) / rs, anchor.AbsoluteSize / rs
end

-- float = true: the popup is NOT clipped by the window, so it can hang below / outside it (used by the
-- config selector, which sits at the very bottom of the sidebar). It flips upwards only if the screen ends.
function Library:_openPopup(owner, size, anchor, up, bare, float)
	self:ClosePopup()
	local f
	if float then
		local rs = math.max(self.Scale.Scale, .01)
		local ap, asz, screen = anchor.AbsolutePosition, anchor.AbsoluteSize, self.Gui.AbsoluteSize
		local below = ap.Y + asz.Y + 4 * rs
		if not up and below + size.Y * rs > screen.Y - 4 then up = true end
		local x = math.clamp(ap.X, 4, math.max(4, screen.X - size.X * rs - 4))
		f = New("Frame", { Size = UDim2.fromOffset(size.X, size.Y), Position = UDim2.fromOffset(x, up and (ap.Y - 4 * rs) or below),
			AnchorPoint = Vector2.new(0, up and 1 or 0), BorderSizePixel = 0, BackgroundTransparency = bare and 1 or 0, Active = true, ZIndex = 2, Parent = self.FloatLayer })
		New("UIScale", { Scale = rs, Parent = f })
		self._popupFloat = f
	else
		local rel, asz = self:_relative(anchor)
		if not up and rel.Y + asz.Y + 4 + size.Y > ROOT_H - 4 then up = true end
		local y = up and (rel.Y - 4) or (rel.Y + asz.Y + 4)
		if up then y = math.max(y, size.Y + 4) end
		local x = math.clamp(rel.X, 4, math.max(4, ROOT_W - size.X - 4))
		f = New("Frame", { Size = UDim2.fromOffset(size.X, size.Y), Position = UDim2.fromOffset(x, y), AnchorPoint = Vector2.new(0, up and 1 or 0), BorderSizePixel = 0,
			BackgroundTransparency = bare and 1 or 0, Active = true, Parent = self.Overlay })
	end
	Blocks(f)
	if not bare then
		Round(f, 8)
		self:Themed(f, { BackgroundColor3 = "Panel" })
		self:Themed(Stroke(f), { Color = "Border" })
	end
	self._popup, self._popupOwner = f, owner
	self.Blocker.Visible = true
	return f
end

-- Tooltips fade + slide in after a short hover delay and fade + slide out again, instead of popping.
function Library:_hideTip(instant)
	self._tipToken = (self._tipToken or 0) + 1      -- also cancels a tooltip that is still waiting to appear
	local tip = self._tip
	if not tip then return end
	self._tip = nil
	if instant then tip:Destroy() return end
	local st = tip:FindFirstChildOfClass("UIStroke")
	self:Tween(tip, { BackgroundTransparency = 1, TextTransparency = 1, Position = tip.Position + UDim2.fromOffset(0, 3) }, .12)
	if st then self:Tween(st, { Transparency = 1 }, .12) end
	task.delay(.14 / math.max(self.AnimSpeed, .1), function() tip:Destroy() end)
end
--// How much room text needs inside a box of the given width. Both the width
--// of a one line tip and the height of a wrapped one come from here, so a
--// tip with a line break in it is sized for its lines rather than for its
--// character count.
function Library:_measureText(text, width, size, font)
	text = tostring(text)

	local ok, bounds = pcall(function()
		return TextService:GetTextSize(text, size, font or Fonts.Medium, Vector2.new(width, 4096))
	end)

	if ok and typeof(bounds) == "Vector2" then
		return bounds
	end

	--// Fallback where the measuring service is not reachable.
	local perLine = math.max(1, math.floor(width / math.max(1, size * 0.52)))
	local lines = 0

	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		lines += math.max(1, math.ceil(#line / perLine))
	end

	return Vector2.new(width, math.max(1, lines) * (size + 4))
end

--// A tooltip is as wide as its text until that would run past the window, at
--// which point it wraps onto more lines. It sits above the control, or drops
--// below it when there is no room left at the top.
function Library:_showTip(anchor, text)
	self:_hideTip()
	local token = self._tipToken

	task.delay(.12, function()
		if self._tipToken ~= token or not anchor.Parent then return end

		local rel, asz = self:_relative(anchor)
		local size = 12
		local maxWidth = math.min(300, ROOT_W - 40)
		local natural = self:_measureText(text, 10000, size).X
		local wrapped = natural > maxWidth
		local width = wrapped and maxWidth or math.ceil(natural) + 18
		local height = math.ceil(self:_measureText(text, width - 18, size).Y) + 10

		local tip = New("TextLabel", {
			Size = UDim2.fromOffset(width, height), BorderSizePixel = 0, Text = text,
			TextWrapped = wrapped, TextTruncate = wrapped and Enum.TextTruncate.None or Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
			Font = Fonts.Medium, TextSize = size, BackgroundTransparency = 1, TextTransparency = 1,
			Parent = self.Overlay,
		})
		New("UIPadding", { PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9), PaddingTop = UDim.new(0, 5), PaddingBottom = UDim.new(0, 5), Parent = tip })
		Round(tip, 6)
		self:Themed(tip, { BackgroundColor3 = "Panel", TextColor3 = "Text" })
		local st = Stroke(tip); st.Transparency = 1
		self:Themed(st, { Color = "Border" })

		local x = math.clamp(rel.X + asz.X / 2, width / 2 + 6, ROOT_W - width / 2 - 6)
		local above = rel.Y - 6
		local hasRoom = above - height >= 4
		local y = hasRoom and above or (rel.Y + asz.Y + 6)
		local anchorPoint = hasRoom and Vector2.new(.5, 1) or Vector2.new(.5, 0)

		tip.AnchorPoint = anchorPoint
		tip.Position = UDim2.fromOffset(x, y + (hasRoom and 4 or -4))

		self._tip = tip
		self:Tween(tip, { BackgroundTransparency = 0, TextTransparency = 0, Position = UDim2.fromOffset(x, y) }, .18, Enum.EasingStyle.Quint)
		self:Tween(st, { Transparency = 0 }, .18)
	end)
end

-- custom scrollbar with arrow buttons (matches the reference look)
function Library:_scrollbar(sc, parent)
	sc.ScrollBarThickness = 0
	local track = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0,10,1,-6), Position = UDim2.new(1,-13,0,3), ZIndex = 3, Parent = parent })
	local function arrow(txt, pos)
		local b = New("TextButton", { BackgroundTransparency = 1, Text = txt, TextSize = 8, Font = Fonts.Regular, Size = UDim2.fromOffset(10,10), Position = pos, ZIndex = 3, Parent = track })
		self:Themed(b, { TextColor3 = "SubText" })
		return b
	end
	local up, dn = arrow("▲", UDim2.new()), arrow("▼", UDim2.new(0,0,1,-10))
	local rail = New("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0,12), Size = UDim2.new(1,0,1,-24), ZIndex = 3, Parent = track })
	local thumb = New("Frame", { Size = UDim2.new(0,4,0,10), Position = UDim2.fromOffset(3,0), BorderSizePixel = 0, ZIndex = 4, Parent = rail })
	Round(thumb, 2)
	self:Bind(function() thumb.BackgroundColor3 = self.Theme.SubText end, thumb)
	thumb.BackgroundTransparency = .5
	local function frac()
		local cs, ws = sc.AbsoluteCanvasSize.Y, sc.AbsoluteWindowSize.Y
		return cs, ws, math.clamp(ws / math.max(cs, 1), math.min(1, 14 / math.max(rail.AbsoluteSize.Y, 1)), 1)
	end
	local function upd()
		local cs, ws, f = frac()
		track.Visible = cs > ws + 1
		if not track.Visible then return end
		local p = (cs - ws) > 0 and math.clamp(sc.CanvasPosition.Y / (cs - ws), 0, 1) or 0
		thumb.Size = UDim2.new(0, 4, f, 0)
		thumb.Position = UDim2.new(0, 3, p * (1 - f), 0)
	end
	for _, sig in ipairs({ "CanvasPosition", "AbsoluteCanvasSize", "AbsoluteWindowSize" }) do sc:GetPropertyChangedSignal(sig):Connect(upd) end
	up.MouseButton1Click:Connect(function() self:Tween(sc, { CanvasPosition = Vector2.new(0, math.max(0, sc.CanvasPosition.Y - 25)) }, .1) end)
	dn.MouseButton1Click:Connect(function() self:Tween(sc, { CanvasPosition = Vector2.new(0, sc.CanvasPosition.Y + 25) }, .1) end)
	thumb.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			local startY, startC = i.Position.Y, sc.CanvasPosition.Y
			self._activeDrag = function(pos)
				local cs, ws, f = frac()
				local room = rail.AbsoluteSize.Y * (1 - f)
				if room <= 0 then return end
				sc.CanvasPosition = Vector2.new(0, math.clamp(startC + (pos.Y - startY) / room * (cs - ws), 0, cs - ws))
			end
		end
	end)
	task.defer(upd)
end

-- scrollable option list (used by inline dropdowns, listboxes and popups)
function Library:_makeList(parent, options, current, onPick, visible)
	local itemH = 25
	local shown = math.max(1, math.min(#options, visible or 5))
	local h = shown * itemH + 8
	local frame = New("Frame", { Size = UDim2.new(1,0,0,h), BorderSizePixel = 0, Active = true, Parent = parent })
	Blocks(frame)
	Round(frame, 6)
	self:Themed(frame, { BackgroundColor3 = "Window" })
	self:Themed(Stroke(frame), { Color = "Border" })
	local sc = New("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(4,4), Size = UDim2.new(1,-8,1,-8),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 0, Parent = frame })
	New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = sc })
	local scrollable = #options > shown
	local labels, cur = {}, current
	local function colorFor(i) return options[i] == cur and self.Theme.Accent or self.Theme.SubText end
	local function paint() for i, l in pairs(labels) do l.TextColor3 = colorFor(i) end end
	for i, opt in ipairs(options) do
		local b = New("TextButton", { LayoutOrder = i, Size = UDim2.new(1, scrollable and -14 or 0, 0, itemH), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = sc })
		local l = New("TextLabel", { BackgroundTransparency = 1, Text = tostring(opt), Font = Fonts.Medium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(10,0), Size = UDim2.new(1,-10,1,0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = b })
		labels[i] = l
		b.MouseEnter:Connect(function() self:Tween(l, { TextColor3 = options[i] == cur and self.Theme.Accent or self.Theme.Text }, .1) end)
		b.MouseLeave:Connect(function() self:Tween(l, { TextColor3 = colorFor(i) }, .1) end)
		b.MouseButton1Click:Connect(function() cur = opt; paint(); onPick(opt) end)
	end
	self:Bind(paint, frame)
	if scrollable then self:_scrollbar(sc, frame) end
	local obj = { Frame = frame, Height = h }
	function obj:SetCurrent(v) cur = v; paint() end
	return obj
end

-- Config dropdown. It is a DRAWER: the list slides out directly under the button, INSIDE the window, and the
-- window grows downward to make room (and is nudged up if the screen has no room below), then shrinks back
-- when the list closes. The last parameters are kept for compatibility and ignored.
function Library:_popupList(anchor, options, current, onPick)
	self:ClosePopup(true)
	local ITEM, GAP, PAD = 28, 6, 12                               -- row height, gap under the button, space under the list
	local rs = math.max(self.Scale.Scale, .01)
	local rel, asz = self:_relative(anchor)
	local rootSize, rootTop, screenH = self.Root.AbsoluteSize, self.Root.AbsolutePosition.Y, self.Gui.AbsoluteSize.Y

	-- rows that fit: the window may only grow as far as the screen allows
	local spare = (screenH - rootSize.Y - 8) / rs
	local base = rel.Y + asz.Y + GAP + PAD - ROOT_H
	local rows = math.clamp(math.floor((spare - base - 8) / ITEM), 1, 6)
	local n = math.min(#options, rows)
	local H = n * ITEM + 8
	local extra = math.max(0, rel.Y + asz.Y + GAP + H + PAD - ROOT_H)   -- how much taller the window gets (unscaled)

	-- keep the window on screen: grow downward, and shift up by whatever does not fit below (Root is centre-anchored)
	local growPx = extra * rs
	local freeBelow = screenH - (rootTop + rootSize.Y) - 4
	local shiftUp = math.min(math.max(0, growPx - freeBelow), math.max(0, rootTop - 4))
	local dy = growPx / 2 - shiftUp

	local box = New("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, ZIndex = 95,
		Position = UDim2.fromOffset(rel.X - 1, rel.Y + asz.Y), Size = UDim2.fromOffset(asz.X + 2, H + GAP + 2), Parent = self.Root })
	Blocks(box)
	local frame = New("Frame", { Size = UDim2.fromOffset(asz.X, H), Position = UDim2.fromOffset(1, -H), BorderSizePixel = 0, Active = true, Parent = box })
	Blocks(frame)
	Round(frame, 8)
	self:Themed(frame, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(frame), { Color = "Border" })
	local sc = New("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(4,4), Size = UDim2.new(1,-8,1,-8),
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, ScrollBarThickness = 0, Parent = frame })
	New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = sc })
	local scrollable = #options > n

	-- rows: the chosen one gets the same accent pill as the selected tab, hovering lights a row up softly
	local cur, items = current, {}
	local function look(i, animate)
		local it = items[i]
		local sel = options[i] == cur
		local bg = sel and self.Theme.Window:Lerp(self.Theme.Accent, .22) or self.Theme.Element
		local tr = sel and 0 or (it.hover and .5 or 1)
		local tc = sel and self.Theme.Accent or (it.hover and self.Theme.Text or self.Theme.SubText)
		it.btn.BackgroundColor3 = bg
		if animate then
			self:Tween(it.btn, { BackgroundTransparency = tr }, .12)
			self:Tween(it.label, { TextColor3 = tc }, .12)
		else
			it.btn.BackgroundTransparency, it.label.TextColor3 = tr, tc
		end
	end
	for i, opt in ipairs(options) do
		local btn = New("TextButton", { LayoutOrder = i, Size = UDim2.new(1, scrollable and -14 or 0, 0, ITEM), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = sc })
		Round(btn, 6)
		local label = New("TextLabel", { BackgroundTransparency = 1, Text = tostring(opt), Font = Fonts.Medium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(12,0), Size = UDim2.new(1,-12,1,0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn })
		items[i] = { btn = btn, label = label, hover = false }
		btn.MouseEnter:Connect(function() items[i].hover = true; look(i, true) end)
		btn.MouseLeave:Connect(function() items[i].hover = false; look(i, true) end)
		btn.MouseButton1Click:Connect(function()
			cur = opt
			for k in pairs(items) do look(k, true) end
			self:ClosePopup()
			onPick(opt)
		end)
	end
	self:Bind(function() for k in pairs(items) do look(k, false) end end, frame)
	if scrollable then self:_scrollbar(sc, frame) end

	local chev = (anchor == self.ConfigButton) and self.ConfigChevron or nil
	if chev then self:Tween(chev, { Rotation = 180 }, .18) end

	self._popup, self._popupOwner = box, anchor
	self.Blocker.Visible = true
	local basePos = self.Root.Position
	local plain = UDim2.fromOffset(ROOT_W, ROOT_H)
	self:Tween(self.Root, { Size = UDim2.fromOffset(ROOT_W, ROOT_H + extra), Position = UDim2.new(basePos.X.Scale, basePos.X.Offset, basePos.Y.Scale, basePos.Y.Offset + dy) }, .22, Enum.EasingStyle.Quint)
	self:Tween(frame, { Position = UDim2.fromOffset(1, GAP) }, .22, Enum.EasingStyle.Quint)

	self._popupClose = function(p, instant)
		if chev then
			if instant then chev.Rotation = 0 else self:Tween(chev, { Rotation = 0 }, .18) end
		end
		if instant or not self.Root.Visible then
			self.Root.Size, self.Root.Position = plain, basePos
			p:Destroy()
			return
		end
		p.Active = false
		for _, d in ipairs(p:GetDescendants()) do
			if d:IsA("GuiButton") then d.Interactable = false end
		end
		self:Tween(self.Root, { Size = plain, Position = basePos }, .2, Enum.EasingStyle.Quint)
		self:Tween(frame, { Position = UDim2.fromOffset(1, -H) }, .2, Enum.EasingStyle.Quint)
		task.delay(.22 / math.max(self.AnimSpeed, .1), function() p:Destroy() end)
	end
end

------------------------------------------------------------------ sidebar
function Library:_keyIcon(parent)
	local c = New("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(15,10), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5), Parent = parent })
	Round(c, 2)
	self:Themed(Stroke(c, nil, 1), { Color = "SubText" })
	for r = 0, 1 do
		for col = 0, (r == 0 and 3 or 0) do
			local d = New("Frame", { BorderSizePixel = 0, Parent = c,
				Size = r == 0 and UDim2.fromOffset(2,2) or UDim2.fromOffset(7,2),
				Position = r == 0 and UDim2.fromOffset(2 + col * 3, 2) or UDim2.fromOffset(4, 6) })
			self:Themed(d, { BackgroundColor3 = "SubText" })
		end
	end
	return c
end

function Library:_buildSidebar()
	local sb = self.Sidebar
	local lp = Players.LocalPlayer

	------------------------------------------------ header: avatar viewport + names
	local name = self.User.Name or (lp and lp.DisplayName) or self.Text.UserFallback
	local tag = self.User.Tag or (lp and "@" .. lp.Name) or ""
	local prof = New("TextButton", { Size = UDim2.new(1,-16,0,56), Position = UDim2.fromOffset(8,10), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2, Parent = sb })
	Round(prof, 10)
	self:Themed(prof, { BackgroundColor3 = "Element" })
	prof.MouseEnter:Connect(function() self:Tween(prof, { BackgroundTransparency = .5 }, .12) end)
	prof.MouseLeave:Connect(function() self:Tween(prof, { BackgroundTransparency = 1 }, .12) end)

	local av = New("Frame", { Size = UDim2.fromOffset(44,44), Position = UDim2.fromOffset(6,6), BorderSizePixel = 0, ZIndex = 3, ClipsDescendants = true, Parent = prof })
	Round(av, 8)                      -- rounded SQUARE behind the head (was a circle)
	self:Bind(function() av.BackgroundColor3 = self.Theme.Accent end)
	local initial = New("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Text = name:sub(1,1):upper(), Font = Fonts.Bold, TextSize = 18, TextColor3 = Color3.new(1,1,1), ZIndex = 4, Parent = av })
	local img = New("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 5, Image = "", Visible = false, Parent = av })
	Round(img, 8)
	local view = New("ViewportFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 6, Visible = false,
		Ambient = Color3.fromRGB(190,190,190), LightColor = Color3.fromRGB(255,255,255), Parent = av })

	local function renderViewport()
		local char = lp and lp.Character
		local head = char and char:FindFirstChild("Head")
		if not head then return false end
		local oldArch = char.Archivable
		char.Archivable = true
		local clone = char:Clone()
		char.Archivable = oldArch
		if not clone then return false end
		for _, d in ipairs(clone:GetDescendants()) do
			if d:IsA("BaseScript") then d:Destroy() end
		end
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None end
		local cHead = clone:FindFirstChild("Head")
		if not cHead then clone:Destroy() return false end
		for _, c in ipairs(view:GetChildren()) do c:Destroy() end
		clone.Parent = view
		local cam = New("Camera", { FieldOfView = 26, Parent = view })
		view.CurrentCamera = cam
		local root = clone:FindFirstChild("HumanoidRootPart")
		local forward = (root and root.CFrame.LookVector) or cHead.CFrame.LookVector
		local target = cHead.Position - Vector3.new(0, .15, 0)
		cam.CFrame = CFrame.lookAt(target + forward * 5, target)
		view.Visible = true
		img.Visible = false
		initial.Visible = false
		return true
	end

	local avatar = self.User.Avatar
	task.spawn(function()
		-- explicit avatar (image id or userId): just show that image
		local ok, res = pcall(function()
			if type(avatar) == "string" then return avatar end
			local id = type(avatar) == "number" and avatar or (lp and lp.UserId)
			return (Players:GetUserThumbnailAsync(id, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100))
		end)
		if ok and res then img.Image = res; img.Visible = true; initial.Visible = false end
		if avatar ~= nil or self.User.Viewport == false or not lp then return end
		-- otherwise render a live viewport of the character
		local waited = 0
		while not (lp.Character and lp.Character:FindFirstChild("Head")) and waited < 6 do task.wait(.25); waited += .25 end
		task.wait(.4)
		pcall(renderViewport)
	end)
	if lp and avatar == nil and self.User.Viewport ~= false then
		table.insert(self._conns, lp.CharacterAdded:Connect(function()
			task.wait(1.5)
			pcall(renderViewport)
		end))
	end

	local pn = self:Label(prof, name, { Bold = true, TextSize = 16, Position = UDim2.fromOffset(60,8), SizeUDim = UDim2.new(1,-72,0,20) })
	pn.ZIndex = 3
	local pt = self:Label(prof, tag, { TextSize = 12, Color = "SubText", Position = UDim2.fromOffset(60,29), SizeUDim = UDim2.new(1,-66,0,16) })
	pt.ZIndex = 3
	prof.MouseButton1Click:Connect(function()
		if self._popupOwner == prof then self:ClosePopup() return end
		self:_profilePopup(prof, name, tag)
		if self.User.OnClick then task.spawn(self.User.OnClick, self) end
	end)
	self.ProfileButton = prof


	------------------------------------------------ search
	local sbx = New("Frame", { Size = UDim2.new(1,-20,0,28), Position = UDim2.fromOffset(10,74), BorderSizePixel = 0, ZIndex = 2, Parent = sb })
	Round(sbx, 7); self:Themed(sbx, { BackgroundColor3 = "Element" })
	local sbs = Stroke(sbx); self:Themed(sbs, { Color = "Border" })
	local ring = New("Frame", { Size = UDim2.fromOffset(9,9), Position = UDim2.fromOffset(10,8), BackgroundTransparency = 1, ZIndex = 3, Parent = sbx })
	Round(ring, 5); self:Themed(Stroke(ring, nil, 1.5), { Color = "SubText" })
	local handle = New("Frame", { Size = UDim2.fromOffset(5,1.6), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromOffset(21,19), Rotation = 45, BorderSizePixel = 0, ZIndex = 3, Parent = sbx })
	self:Themed(handle, { BackgroundColor3 = "SubText" })
	local tb = New("TextBox", { BackgroundTransparency = 1, Position = UDim2.fromOffset(30,0), Size = UDim2.new(1,-36,1,0), Text = "", PlaceholderText = self.Text.Search,
		ClearTextOnFocus = false, Font = Fonts.Medium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3, Parent = sbx })
	self:Themed(tb, { TextColor3 = "Text", PlaceholderColor3 = "SubText" })
	self:_focusStroke(tb, sbs)
	--// The search walks every row and every label in the window, so it runs a
	--// moment after typing stops rather than once per keystroke; a query that
	--// did not change (a cursor move, focus) searches nothing at all.
	local SearchQueued = nil

	tb:GetPropertyChangedSignal("Text"):Connect(function()
		local Query = tb.Text

		if Query == self._searchQuery then
			return
		end

		--// The newest query owns the next search; a timer left over from an
		--// earlier keystroke sees a stale token and does nothing, so the box
		--// never has to rely on a cancel landing in time.
		self._searchQuery = Query
		self._searchToken = (self._searchToken or 0) + 1

		local Token = self._searchToken

		if SearchQueued and task.cancel then
			task.cancel(SearchQueued)
		end

		SearchQueued = task.delay(.12, function()
			SearchQueued = nil

			if self._searchToken ~= Token then
				return
			end

			self:_search(Query)
		end)
	end)
	self.SearchBox = tb

	------------------------------------------------ tabs (scrolls: there can be more tabs than fit)
	self.TabHolder = New("ScrollingFrame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10,112), Size = UDim2.new(1,-20,1,-112-132),
		ClipsDescendants = true, ZIndex = 2, Parent = sb, BorderSizePixel = 0, ScrollBarThickness = 2,
		ScrollingDirection = Enum.ScrollingDirection.Y, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ElasticBehavior = Enum.ElasticBehavior.Never })
	self:Bind(function()
		self.TabHolder.ScrollBarImageColor3 = self.Theme.SubText
		self.TabHolder.ScrollBarImageTransparency = .45
	end)
	-- the sliding highlight behind the selected tab: the accent colour blended into the window colour
	self.TabIndicator = New("Frame", { Size = UDim2.new(1,0,0,36), BorderSizePixel = 0, Visible = false, ZIndex = 2, Parent = self.TabHolder })
	Round(self.TabIndicator, 8)
	self:Bind(function() self.TabIndicator.BackgroundColor3 = self.Theme.Window:Lerp(self.Theme.Accent, .22) end)

	------------------------------------------------ divider above status icons
	local divider = New("Frame", { Size = UDim2.new(1,-24,0,1), Position = UDim2.new(0,12,1,-72), BorderSizePixel = 0, ZIndex = 2, Parent = sb })
	self:Themed(divider, { BackgroundColor3 = "Border" })
end

-- Status icons: the grid above the config selector. Each lights up with the accent colour while
-- its Flag is true. Clicking toggles the feature (through the flag's element) or fires Callback.
-- o = { Name, Icon | Glyph | (placeholder), Flag, Default, Callback }
function Library:AddStatusIcon(o)
	if #self.StatusIcons >= self.StatusPerRow * 2 then return end
	local obj = { Name = o.Name or "", State = o.Default and true or false }
	local btn = New("TextButton", { Size = UDim2.fromOffset(28,24), AnchorPoint = Vector2.new(.5,0), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, ZIndex = 3, Parent = self.Sidebar })
	local icon = self:_makeIcon(btn, o, 16, UDim2.new(.5,-8,.5,-8), 4)
	local function paint(animate) icon.SetColor(obj.State and self.Theme.Accent or self.Theme.SubText, animate) end
	self:Bind(function() paint(false) end)
	function obj:Set(b) self.State = b and true or false; paint(true) end
	function obj:Get() return self.State end
	obj.Button = btn
	if o.Flag then
		local cur = self.Flags[o.Flag]
		if cur ~= nil then obj.State = (cur ~= false); paint(false) end
		self:OnFlag(o.Flag, function(v) obj:Set(v ~= nil and v ~= false) end)
	end
	btn.MouseEnter:Connect(function() if obj.Name ~= "" then self:_showTip(btn, obj.Name) end end)
	btn.MouseLeave:Connect(function() self:_hideTip() end)
	btn.MouseButton1Click:Connect(function()
		local setter = o.Flag and self._setters[o.Flag]
		if setter then
			setter(not obj.State)
		else
			obj:Set(not obj.State)
			if o.Callback then task.spawn(o.Callback, obj.State) end
		end
	end)
	table.insert(self.StatusIcons, obj)
	self:_layoutStatus()
	return obj
end

function Library:_layoutStatus()
	local n = #self.StatusIcons
	if n == 0 then return end
	local per = math.max(self.StatusPerRow, math.ceil(n / 2))     -- never more than two rows
	local rows = math.ceil(n / per)
	local base, extra = math.floor(n / rows), n % rows            -- spread evenly: 8 -> 4+4, 7 -> 4+3, 6 -> 3+3
	local i = 0
	for r = 1, rows do
		local count = base + (r <= extra and 1 or 0)
		local y = (rows == 1) and 30 or ((r - 1) * 30)
		for c = 1, count do
			i += 1
			self.StatusIcons[i].Button.Position = UDim2.new((c - .5) / count, 0, 1, -66 + y)
		end
	end
end

function Library:_profilePopup(anchor, name, tag)
	local btns = self.User.Buttons
	if not btns or #btns == 0 then
		local uid = self.User.UID or (Players.LocalPlayer and Players.LocalPlayer.UserId) or 0
		btns = { { Text = self.Text.CopyUID, Callback = function() self:Copy(tostring(uid), self.Text.Copied) end } }
	end
	local w, h = 210, 64 + #btns * 32 + 6
	local f = self:_openPopup(anchor, Vector2.new(w, h), anchor, false)   -- opens just below the header
	self._popupOwner = anchor
	self:Label(f, name, { Bold = true, TextSize = 16, Position = UDim2.fromOffset(14,10), SizeUDim = UDim2.new(1,-28,0,20) })
	self:Label(f, tag, { Color = "SubText", TextSize = 12, Position = UDim2.fromOffset(14,31), SizeUDim = UDim2.new(1,-28,0,16) })
	local y = 58
	for _, bt in ipairs(btns) do
		local b = New("TextButton", { Size = UDim2.new(1,-24,0,26), Position = UDim2.fromOffset(12,y), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = f })
		Round(b, 6); self:Themed(b, { BackgroundColor3 = "Element" })
		local st = Stroke(b); self:_hover(b, st)
		local l = self:Label(b, bt.Text, { Bold = true, TextSize = 13 }); l.TextXAlignment = Enum.TextXAlignment.Center
		b.MouseButton1Click:Connect(function() self:ClosePopup(); if bt.Callback then task.spawn(bt.Callback) end end)
		y += 32
	end
end

------------------------------------------------------------------ tabs
local TAB_H, TAB_PITCH = 36, 40


function Library:_paintTabs(instant)
	local idx
	for i, t in ipairs(self.Tabs) do
		local sel = (self.CurrentTab == t)
		if sel then idx = i end
		local col = sel and self.Theme.Text or self.Theme.SubText
		if instant then t.Label.TextColor3 = col else self:Tween(t.Label, { TextColor3 = col }, .15) end
		t.IconObj.SetColor(sel and self.Theme.Accent or self.Theme.SubText, not instant)
		if sel then
			if instant then t.Button.BackgroundTransparency = 1 else self:Tween(t.Button, { BackgroundTransparency = 1 }, .1) end
		end
	end
	if idx then
		self.TabIndicator.Visible = true
		local pos = UDim2.fromOffset(0, (idx - 1) * TAB_PITCH)
		if instant then self.TabIndicator.Position = pos else self:Tween(self.TabIndicator, { Position = pos }, .22, Enum.EasingStyle.Quint) end
		-- Scroll the selected tab into view (there can be more tabs than fit).
		local view = self.TabHolder
		if view:IsA("ScrollingFrame") then
			local y = (idx - 1) * TAB_PITCH
			local top = view.CanvasPosition.Y
			local height = view.AbsoluteWindowSize.Y
			if y < top then
				view.CanvasPosition = Vector2.new(0, y)
			elseif height > 0 and y + TAB_H > top + height then
				view.CanvasPosition = Vector2.new(0, y + TAB_H - height)
			end
		end
	end
end

-- o = { Name, Icon = "rbxassetid://..." | Glyph = "X" | (neither: placeholder), Description }
function Library:AddTab(o)
	if type(o) == "string" then o = { Name = o } end

	local tab = { Name = o.Name or "Tab", Win = self, Sections = {}, Description = o.Description, _order = 0 }
	local idx = #self.Tabs + 1
	local b = New("TextButton", { Size = UDim2.new(1,0,0,TAB_H), Position = UDim2.fromOffset(0, (idx - 1) * TAB_PITCH), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 3, Parent = self.TabHolder })
	Round(b, 8)
	self:Themed(b, { BackgroundColor3 = "Element" })
	tab.Button = b
	self.TabHolder.CanvasSize = UDim2.new(0, 0, 0, idx * TAB_PITCH)
	tab.IconObj = self:_makeIcon(b, o, 18, UDim2.fromOffset(13, 9), 4)
	tab.Label = self:Label(b, tab.Name, { Color = "SubText", Position = UDim2.fromOffset(44,0), SizeUDim = UDim2.new(1,-50,1,0) })
	tab.Label.ZIndex = 4
	b.MouseEnter:Connect(function()
		if self.CurrentTab ~= tab then
			self:Tween(tab.Label, { TextColor3 = self.Theme.Text }, .12)
			self:Tween(b, { BackgroundTransparency = .55 }, .12)
		end

		--// A tab's Description is what the page is for; it is shown on hover
		--// rather than spending a row of the page on a heading.
		if tab.Description then
			self:_showTip(b, tab.Description)
		end
	end)
	b.MouseLeave:Connect(function()
		if self.CurrentTab ~= tab then self:Tween(tab.Label, { TextColor3 = self.Theme.SubText }, .12) end
		self:Tween(b, { BackgroundTransparency = 1 }, .12)
		self:_hideTip()
	end)

	-- page: a vertical stack of "blocks". A block is either one full-width section
	-- or a split row holding a left and a right column. A Frame, so switching
	-- tabs costs nothing beyond hiding one and showing the next; a group per
	-- page stacked a second full-size texture pass on top of the window's.
	local page = New("Frame", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, Visible = false, Parent = self.Content })
	local sc = New("ScrollingFrame", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = page })
	self:Bind(function() sc.ScrollBarImageColor3 = self.Theme.Border end)
	local holder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, Parent = sc })
	New("UIPadding", { PaddingLeft = UDim.new(0,12), PaddingRight = UDim.new(0,16), PaddingTop = UDim.new(0,12), PaddingBottom = UDim.new(0,12), Parent = holder })
	tab.Body = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, Parent = holder })
	New("UIListLayout", { Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = tab.Body })
	tab.Page = page
	b.MouseButton1Click:Connect(function() self:SelectTab(tab) end)

	-- so.Side = "Left" | "Right" (omit to balance the columns) ; so.Full = true spans the whole page
	function tab:AddSection(so)
		so = so or {}
		local win = self.Win
		local parentFrame, order
		if so.Full or win.SingleColumn then
			self._split = nil
			self._order += 1
			parentFrame, order = self.Body, self._order
		else
			if not self._split then
				self._order += 1
				local split = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = self._order, Parent = self.Body })
				New("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = split })
				self._split = { Count = { Left = 0, Right = 0 } }
				for i, side in ipairs({ "Left", "Right" }) do
					local col = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(.5,-5,0,0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = split })
					New("UIListLayout", { Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
					self._split[side] = col
				end
			end
			local side = so.Side
			if side ~= "Left" and side ~= "Right" then
				side = (self._split.Count.Left <= self._split.Count.Right) and "Left" or "Right"
			end
			self._split.Count[side] += 1
			parentFrame, order = self._split[side], self._split.Count[side]
		end
		local sec = setmetatable({ Win = win, Tab = self, _n = 0, Components = {} }, { __index = Library.Section })
		sec.Frame = New("Frame", { Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Active = true, LayoutOrder = order, Parent = parentFrame })
		Round(sec.Frame, 8)
		Blocks(sec.Frame)
		win:Themed(sec.Frame, { BackgroundColor3 = "Panel" })
		win:Themed(Stroke(sec.Frame), { Color = "Border" })
		New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = sec.Frame })
		if so.Title then
			local r = sec:_row(34)
			win:Label(r, so.Title, { Bold = true, TextSize = 15, Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-28,1,0) })
		end
		table.insert(self.Sections, sec)
		return sec
	end

	table.insert(self.Tabs, tab)
	if not self.CurrentTab then self:SelectTab(tab) else self:_paintTabs() end
	return tab
end

function Library:SelectTab(tab)
	if self.CurrentTab == tab then return end
	local old = self.CurrentTab
	self.CurrentTab = tab
	if old then old.Page.Visible = false end
	local pg = tab.Page
	pg.Visible = true
	local mode = self.TabAnimation
	if mode == "None" then
		pg.Position = UDim2.new()
	elseif mode == "Slide" then
		pg.Position = UDim2.fromOffset(0, 18)
		self:Tween(pg, { Position = UDim2.new() }, .26, Enum.EasingStyle.Quint)
	else
		pg.Position = UDim2.fromOffset(0, 6)
		self:Tween(pg, { Position = UDim2.new() }, .2)
	end
	self:_paintTabs()
end

function Library:_search(q)
	q = q:lower()
	local matches = {}
	for _, tab in ipairs(self.Tabs) do
		for _, sec in ipairs(tab.Sections) do
			local secAny = false
			for _, row in ipairs(sec.Frame:GetChildren()) do
				-- A row is a Frame of controls; AddLabel adds its TextLabel
				-- straight to the section, so it is searched by its own text.
				if row:IsA("Frame") or row:IsA("TextLabel") then
					local m = (q == "")
					if not m then
						if row:IsA("TextLabel") then
							m = row.Text:lower():find(q, 1, true) ~= nil
						else
							for _, d in ipairs(row:GetDescendants()) do
								if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
									local t = (d:IsA("TextBox") and d.PlaceholderText or d.Text):lower()
									if t:find(q, 1, true) then m = true break end
								end
							end
						end
					end
					row.Visible = m
					if m then secAny = true end
				end
			end
			sec.Frame.Visible = secAny or q == ""
			if secAny then matches[tab] = true end
		end
	end
	if q ~= "" and not matches[self.CurrentTab] then
		for _, tab in ipairs(self.Tabs) do
			if matches[tab] then self:SelectTab(tab) break end
		end
	end
end

------------------------------------------------------------------ sections / elements
local Section = {}
Library.Section = Section

function Section:_row(h, noSeparator)
	self._n += 1
	local r = New("Frame", { Size = UDim2.new(1,0,0,h), BackgroundTransparency = 1, LayoutOrder = self._n, Parent = self.Frame })
	if self._n > 1 and not noSeparator then
		local l = New("Frame", { Size = UDim2.new(1,0,0,1), BorderSizePixel = 0, Parent = r })
		self.Win:Themed(l, { BackgroundColor3 = "Border" })
	end
	self._lastRow = r
	return r
end

function Section:_register(o, obj)
	if o.Flag then
		self.Win:_setFlag(o.Flag, obj:Get())
		if not o.NoSave then self.Win._setters[o.Flag] = function(v) obj:Set(v) end else self.Win._setters[o.Flag] = nil end
	end

	return self:_decorate(self._lastRow, o, obj)
end

function Section:AddToggle(o, ...)
	if type(o) == "string" then
		local default, callback = ...
		o = { Name = o, Default = default, Callback = callback }
	end
	local win, row = self.Win, self:_row(36)
	local lbl, ref = win:Label(row, o.Name, { Bold = o.Bold, Color = o.Bold and "Text" or "SubText", Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-90,1,0) })
	local box = New("TextButton", { Size = UDim2.fromOffset(18,18), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-14,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(box, 5)
	local st = Stroke(box); win:_hover(box, st)
	local setCheck = win:_checkMark(box)
	local obj = { Value = o.Default or false }
	local function paint(animate)
		local c = obj.Value and win.Theme.Accent or win.Theme.Element
		ref.k = (o.Bold or obj.Value) and "Text" or "SubText"
		setCheck(obj.Value, animate)
		if animate then
			win:Tween(box, { BackgroundColor3 = c }, .14)
			win:Tween(lbl, { TextColor3 = win.Theme[ref.k] }, .14)
		else
			box.BackgroundColor3 = c; lbl.TextColor3 = win.Theme[ref.k]
		end
	end
	win:Bind(function() paint(false) end)
	function obj:Set(v, silent)
		v = v and true or false
		--// Setting a toggle to what it already is does nothing. A feature that
		--// syncs its own toggle from inside that toggle's callback used to
		--// call itself until the stack ran out, which is what made turning
		--// Auto Block on and off stutter.
		if v == self.Value then return end
		self.Value = v
		if o.Flag then win:_setFlag(o.Flag, self.Value) end
		paint(true)
		if o.Callback and not silent then task.spawn(o.Callback, self.Value) end
	end
	function obj:Get() return self.Value end
	box.MouseButton1Click:Connect(function() obj:Set(not obj.Value) end)

	if o.Bind then
		local kb = New("TextButton", { AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-40,.5,0), Size = UDim2.fromOffset(30,20), Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Parent = row })
		local icon = win:_keyIcon(kb)
		local kl = win:Label(kb, "", { Color = "SubText", TextSize = 11 }); kl.TextXAlignment = Enum.TextXAlignment.Right; kl.Visible = false
		local entry = { Name = o.Name, Key = o.DefaultBind, Callback = function() obj:Set(not obj.Value) end }
		table.insert(win.Keybinds, entry)
		local function setKey(k)
			entry.Key = k
			icon.Visible = (k == nil); kl.Visible = (k ~= nil)
			kl.Text = k and k.Name:sub(1, 5) or ""
			if o.Flag then win:_setFlag(o.Flag .. "_Key", k) end
			win:_updateKeybindList()
		end
		if o.Flag then win._setters[o.Flag .. "_Key"] = setKey end
		kb.MouseButton1Click:Connect(function()
			if win._listening then return end
			icon.Visible = false; kl.Visible = true; kl.Text = "..."
			local prev = entry.Key
			win:_listenKey(setKey, function()
				entry.Key = prev
				icon.Visible = (prev == nil); kl.Visible = (prev ~= nil)
				kl.Text = prev and prev.Name:sub(1, 5) or ""
				win:_updateKeybindList()
			end)
		end)
		setKey(entry.Key)
	end
	self:_register(o, obj)
	--// The callback is for the user turning it on or off, not for the build.
	--// Firing it here meant a callback that rebuilds its own widget (the
	--// whitelist list, a material picker) called itself while this toggle was
	--// still under construction: C stack overflow. The starting state is
	--// already on screen from obj:Set above.
	return obj
end

function Section:AddSlider(o, ...)
	if type(o) == "string" then
		local default, min, max, callback = ...
		o = { Name = o, Default = default, Min = min, Max = max, Callback = callback }
	end
	local win, row = self.Win, self:_row(56)
	local nameLbl = win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(14,9), SizeUDim = UDim2.new(1,-28,0,18) })
	local val = win:Label(row, "", { AlignRight = true, Position = UDim2.new(1,-14,0,9), SizeUDim = UDim2.fromOffset(0,18) })
	-- The value hugs its own text and the name gets every pixel that is left. Before, a fixed 150px was
	-- reserved for the value, which squeezed "Speed of animations" down to "Speed of...".
	val.AnchorPoint = Vector2.new(1, 0); val.AutomaticSize = Enum.AutomaticSize.X; val.TextTruncate = Enum.TextTruncate.None
	val:GetPropertyChangedSignal("TextBounds"):Connect(function()
		nameLbl.Size = UDim2.new(1, -(14 + 14 + 10 + val.TextBounds.X), 0, 18)
	end)
	local min, max, dec = o.Min or 0, o.Max or 100, o.Decimals or 0
	local step = o.Step or 10 ^ -dec
	local track = New("Frame", { Position = UDim2.new(0,34,0,41), Size = UDim2.new(1,-68,0,4), BorderSizePixel = 0, Parent = row })
	Round(track, 2); win:Themed(track, { BackgroundColor3 = "Border" })
	local fill = New("Frame", { Size = UDim2.new(0,0,1,0), BorderSizePixel = 0, Parent = track }); Round(fill, 2)
	win:Bind(function() fill.BackgroundColor3 = win.Theme.Accent end)
	local knob = New("Frame", { Size = UDim2.fromOffset(12,12), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(0,.5), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0, ZIndex = 2, Parent = track })
	Round(knob, 7)
	local obj = { Value = o.Default or min }
	function obj:Set(v, silent, animate)
		v = math.clamp(math.floor(v / step + .5) * step, min, max)
		self.Value = v
		local p = (max == min) and 0 or (v - min) / (max - min)
		if animate then
			win:Tween(fill, { Size = UDim2.new(p, 0, 1, 0) }, .12)
			win:Tween(knob, { Position = UDim2.new(p, 0, .5, 0) }, .12)
		else
			fill.Size = UDim2.new(p, 0, 1, 0); knob.Position = UDim2.new(p, 0, .5, 0)
		end
		val.Text = string.format("( %." .. dec .. "f%s )", v, o.Suffix or "")
		if o.Flag then win:_setFlag(o.Flag, v) end
		if o.Callback and not silent then task.spawn(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	local hit = New("TextButton", { BackgroundTransparency = 1, Text = "", Position = UDim2.new(0,28,0,33), Size = UDim2.new(1,-56,0,20), Parent = row })
	local function fromPos(pos) obj:Set(min + math.clamp((pos.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1) * (max - min)) end
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			win._activeDrag = fromPos
			fromPos(i.Position)
		end
	end)
	hit.MouseEnter:Connect(function() win:Tween(knob, { Size = UDim2.fromOffset(14,14) }, .1) end)
	hit.MouseLeave:Connect(function() win:Tween(knob, { Size = UDim2.fromOffset(12,12) }, .1) end)
	for i, sym in ipairs({ "‹", "›" }) do
		local a = New("TextButton", { BackgroundTransparency = 1, Text = sym, Font = Fonts.Medium, TextSize = 18, Size = UDim2.fromOffset(16,18),
			Position = i == 1 and UDim2.fromOffset(10,35) or UDim2.new(1,-26,0,35), Parent = row })
		win:Bind(function() a.TextColor3 = win.Theme.SubText end)
		a.MouseEnter:Connect(function() win:Tween(a, { TextColor3 = win.Theme.Text }, .1) end)
		a.MouseLeave:Connect(function() win:Tween(a, { TextColor3 = win.Theme.SubText }, .1) end)
		a.MouseButton1Click:Connect(function() obj:Set(obj.Value + (i == 1 and -step or step), false, true) end)
	end
	obj:Set(obj.Value, true)
	self:_register(o, obj)
	--// Never at build time: see AddToggle. A slider's callback changes the
	--// setting it was built from, which can rebuild the row it lives in.
	return obj
end

-- inline dropdown: expands inside the section and pushes the rows below it down
function Section:AddDropdown(o, ...)
	if type(o) == "string" then
		local options, callback = ...
		o = { Name = o, Options = options, Callback = callback }
	end
	local inline = o.Inline == true
	local height = inline and 42 or 62
	local win, row = self.Win, self:_row(height)
	row.ClipsDescendants = true
	win:Label(row, o.Name, inline
		and { Bold = true, Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(.5,-22,0,42) }
		or { Bold = true, Position = UDim2.fromOffset(14,8), SizeUDim = UDim2.new(1,-28,0,18) })
	local box = New("TextButton", { Position = inline and UDim2.new(.5,0,0,8) or UDim2.fromOffset(14,30), Size = inline and UDim2.new(.5,-14,0,26) or UDim2.new(1,-28,0,26), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(box, 6); win:Themed(box, { BackgroundColor3 = "Element" })
	local st = Stroke(box); win:_hover(box, st)
	local txt = win:Label(box, "", { Position = UDim2.fromOffset(10,0), SizeUDim = UDim2.new(1,-30,1,0), TextSize = 13 })
	local chev = Chevron(box, UDim2.new(1,-16,.5,0))
	local obj = { Options = o.Options or {}, Value = o.Default or (o.Options or {})[1], Open = false }
	local list
	function obj:Set(v, silent)
		self.Value = v; txt.Text = tostring(v)
		if list then list:SetCurrent(v) end
		if o.Flag then win:_setFlag(o.Flag, v) end
		if o.Callback and not silent then task.spawn(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	function obj:SetOptions(l) self.Options = l; if list then list.Container:Destroy(); list = nil end end
	function obj:Close()
		if not self.Open then return end
		self.Open = false
		win:Tween(chev, { Rotation = 0 }, .18)
		win:Tween(row, { Size = UDim2.new(1,0,0,height) }, .2, Enum.EasingStyle.Quint)
		if list then win:Tween(list.Frame, { Position = UDim2.fromOffset(14, -list.Height) }, .2, Enum.EasingStyle.Quint) end
	end
	function obj:OpenList()
		if self.Open then return end
		self.Open = true
		if not list then
			-- the list lives in a clipping container that starts right under the box, so it slides out of
			-- the box (rather than being revealed by a wipe) and never overlaps the title or the box
			local holder = New("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(0, height), Size = UDim2.new(1,0,0,0), Parent = row })
			list = win:_makeList(holder, self.Options, self.Value, function(v) self:Set(v); self:Close() end, o.Visible or 5)
			list.Container = holder
			holder.Size = UDim2.new(1,0,0,list.Height + 10)
			list.Frame.Size = UDim2.new(1,-28,0,list.Height)
			list.Frame.Position = UDim2.fromOffset(14, -list.Height)
		end
		win:Tween(chev, { Rotation = 180 }, .18)
		win:Tween(row, { Size = UDim2.new(1,0,0,height + list.Height + 10) }, .22, Enum.EasingStyle.Quint)
		win:Tween(list.Frame, { Position = UDim2.fromOffset(14, 0) }, .22, Enum.EasingStyle.Quint)
	end
	box.MouseButton1Click:Connect(function() if obj.Open then obj:Close() else obj:OpenList() end end)
	obj:Set(obj.Value, true)
	self:_register(o, obj)
	--// Never at build time: see AddToggle. Opening a picker rebuilds its own
	--// option list, so a callback here is the shortest path to a stack overflow.
	return obj
end

-- always-visible scrollable list
function Section:AddListbox(o)
	local win = self.Win
	local row = self:_row(30)
	win:Label(row, o.Name, { Bold = true, Position = UDim2.fromOffset(14,8), SizeUDim = UDim2.new(1,-28,0,18) })
	local obj = { Options = o.Options or {}, Value = o.Default or (o.Options or {})[1] }
	local list = win:_makeList(row, obj.Options, obj.Value, function(v) obj:Set(v) end, o.Visible or 5)
	list.Frame.Position = UDim2.fromOffset(14,30)
	list.Frame.Size = UDim2.new(1,-28,0,list.Height)
	row.Size = UDim2.new(1,0,0,30 + list.Height + 10)
	function obj:Set(v, silent)
		self.Value = v; list:SetCurrent(v)
		if o.Flag then win:_setFlag(o.Flag, v) end
		if o.Callback and not silent then task.spawn(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	self:_register(o, obj)
	return obj
end

function Section:AddKeybind(o)
	local win, row = self.Win, self:_row(36)
	win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-100,1,0) })
	local btn = New("TextButton", { AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-14,.5,0), Size = UDim2.fromOffset(60,22), AutomaticSize = Enum.AutomaticSize.X,
		Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(btn, 6); win:Themed(btn, { BackgroundColor3 = "Element" })
	local st = Stroke(btn); win:_hover(btn, st)
	New("UIPadding", { PaddingLeft = UDim.new(0,12), PaddingRight = UDim.new(0,12), Parent = btn })
	local txt = win:Label(btn, "", { TextSize = 13 })
	txt.AutomaticSize = Enum.AutomaticSize.X; txt.Size = UDim2.new(0,0,1,0); txt.TextXAlignment = Enum.TextXAlignment.Center; txt.TextTruncate = Enum.TextTruncate.None
	local obj = { Key = o.Default }
	local entry = { Name = o.Name, Key = obj.Key, Callback = o.Callback }
	if not o.Hidden then table.insert(win.Keybinds, entry) end
	function obj:Set(k, silent)
		self.Key = k; entry.Key = k
		txt.Text = k and k.Name or win.Text.KeyNone
		if o.Flag then win:_setFlag(o.Flag, k) end
		if o.OnChanged and not silent then task.spawn(o.OnChanged, k) end
		win:_updateKeybindList()
	end
	function obj:Get() return self.Key end
	btn.MouseButton1Click:Connect(function()
		if win._listening then return end
		txt.Text = "..."
		local prev = obj.Key
		win:_listenKey(function(k) obj:Set(k) end, function()
			obj.Key = prev; entry.Key = prev
			txt.Text = prev and prev.Name or win.Text.KeyNone
			win:_updateKeybindList()
		end)
	end)
	obj:Set(obj.Key, true)
	self:_register(o, obj)
	return obj
end

function Section:AddColorPicker(o)
	local win, row = self.Win, self:_row(36)
	win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-90,1,0) })
	local obj = { Color = o.Default or Color3.new(1,1,1), Enabled = o.DefaultEnabled or false }
	local hue, sat, val = obj.Color:ToHSV()
	local right = 14
	local check, setCheck
	if o.Toggle then
		check = New("TextButton", { Size = UDim2.fromOffset(18,18), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-14,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
		Round(check, 5); local cs = Stroke(check); win:_hover(check, cs)
		setCheck = win:_checkMark(check)
		right = 40
	end
	local sw = New("TextButton", { Size = UDim2.fromOffset(12,12), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-right,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(sw, 6)
	local function fire() if o.Callback then task.spawn(o.Callback, obj.Color, obj.Enabled) end end
	local function paint()
		sw.BackgroundColor3 = obj.Color
		if check then
			win:Tween(check, { BackgroundColor3 = obj.Enabled and win.Theme.Accent or win.Theme.Element }, .14)
			setCheck(obj.Enabled, true)
		end
	end
	win:Bind(paint)
	function obj:Set(c, silent, keepHSV)
		if typeof(c) ~= "Color3" then return end
		self.Color = c; if not keepHSV then hue, sat, val = c:ToHSV() end
		if o.Flag then win:_setFlag(o.Flag, c) end
		sw.BackgroundColor3 = c      -- only the swatch changes while dragging (paint() also tweened the checkbox)
		if not silent then fire() end
	end
	function obj:SetEnabled(b, silent)
		self.Enabled = b
		if o.Flag and o.Toggle then win:_setFlag(o.Flag .. "_On", b) end
		paint()
		if not silent then fire() end
	end
	function obj:Get() return self.Color end
	if check then
		check.MouseButton1Click:Connect(function() obj:SetEnabled(not obj.Enabled) end)
		if o.Flag then win._setters[o.Flag .. "_On"] = function(v) obj:SetEnabled(v) end; win:_setFlag(o.Flag .. "_On", obj.Enabled) end
	end
	sw.MouseButton1Click:Connect(function()
		if win._popupOwner == sw then win:ClosePopup() return end
		local f = win:_openPopup(sw, Vector2.new(180, 170), sw)
		win._popupOwner = sw
		local svBox = New("TextButton", { Position = UDim2.fromOffset(8,8), Size = UDim2.fromOffset(164,110), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = f })
		Round(svBox, 4)
		svBox.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
		local w = New("Frame", { Size = UDim2.fromScale(1,1), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0, Parent = svBox })
		New("UIGradient", { Transparency = NumberSequence.new(0, 1), Parent = w }); Round(w, 4)
		local k = New("Frame", { Size = UDim2.fromScale(1,1), BackgroundColor3 = Color3.new(0,0,0), BorderSizePixel = 0, Parent = svBox })
		New("UIGradient", { Rotation = 90, Transparency = NumberSequence.new(1, 0), Parent = k }); Round(k, 4)
		local cur = New("Frame", { Size = UDim2.fromOffset(8,8), AnchorPoint = Vector2.new(.5,.5), BackgroundTransparency = 1, ZIndex = 3, Parent = svBox })
		Round(cur, 4); Stroke(cur, Color3.new(1,1,1), 2)
		local hb = New("TextButton", { Position = UDim2.fromOffset(8,126), Size = UDim2.fromOffset(164,12), Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundColor3 = Color3.new(1,1,1), Parent = f })
		Round(hb, 4)
		local seq = {}
		for i = 0, 6 do table.insert(seq, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i == 6 and .999 or i / 6, 1, 1))) end
		New("UIGradient", { Color = ColorSequence.new(seq), Parent = hb })
		local hcur = New("Frame", { Size = UDim2.fromOffset(4,16), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(0,.5), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0, Parent = hb })
		Round(hcur, 2); Stroke(hcur, Color3.new(0,0,0), 1)
		local hex = win:Label(f, "", { Position = UDim2.fromOffset(8,146), SizeUDim = UDim2.new(1,-16,0,18), Color = "SubText", TextSize = 12 })
		local function redraw()
			svBox.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
			cur.Position = UDim2.fromScale(sat, 1 - val)
			hcur.Position = UDim2.fromScale(hue, .5)
			hex.Text = "#" .. obj.Color:ToHex():upper()
		end
		local function apply() obj:Set(Color3.fromHSV(hue, sat, val), false, true); redraw() end
		svBox.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				local function mv(pos)
					sat = math.clamp((pos.X - svBox.AbsolutePosition.X) / svBox.AbsoluteSize.X, 0, 1)
					val = 1 - math.clamp((pos.Y - svBox.AbsolutePosition.Y) / svBox.AbsoluteSize.Y, 0, 1)
					apply()
				end
				win._activeDrag = mv; mv(i.Position)
			end
		end)
		hb.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				local function mv(pos) hue = math.clamp((pos.X - hb.AbsolutePosition.X) / hb.AbsoluteSize.X, 0, .999); apply() end
				win._activeDrag = mv; mv(i.Position)
			end
		end)
		redraw()
	end)
	obj:Set(obj.Color, true); paint()
	self:_register(o, obj)
	fire()
	return obj
end

function Section:AddTextBox(o, ...)
	if type(o) == "string" then
		local default, callback = ...
		o = { Name = o, Default = default, Callback = callback }
	end
	local win, row = self.Win, self:_row(42)
	local inline = o.Inline == true
	if inline then
		win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(.5,-22,1,0) })
	end
	local tb = New("TextBox", { Position = inline and UDim2.new(.5,0,0,8) or UDim2.fromOffset(14,8), Size = inline and UDim2.new(.5,-14,0,26) or UDim2.new(1,-28,0,26), Text = o.Default or "", PlaceholderText = o.Placeholder or o.Name or "",
		ClearTextOnFocus = false, Font = Fonts.Medium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0, Parent = row })
	Round(tb, 6); New("UIPadding", { PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,10), Parent = tb })
	win:Themed(tb, { BackgroundColor3 = "Element", TextColor3 = "Text", PlaceholderColor3 = "SubText" })
	local st = Stroke(tb); win:_hover(tb, st); win:_focusStroke(tb, st)
	local obj = {}
	function obj:Get() return tb.Text end
	function obj:Set(v, silent) tb.Text = v; if o.Flag then win:_setFlag(o.Flag, v) end if o.Callback and not silent then task.spawn(o.Callback, v) end end
	tb.FocusLost:Connect(function() obj:Set(tb.Text) end)
	self:_register(o, obj)
	obj.Box = tb
	return obj
end

function Section:AddConfigSelector(o)
	o = o or {}
	local win = self.Win
	local dd = self:AddDropdown{ Name = o.Name or "Config", Options = win:GetConfigNames(), Default = win.ConfigName, Flag = o.Flag, Callback = function(v) win:LoadConfig(v) end }
	table.insert(win.ConfigSelectors, dd)
	return dd
end

function Section:AddButton(o, ...)
	if type(o) == "string" then
		local callback = ...
		o = { Name = o, Callback = callback }
	end
	local win, row = self.Win, self:_row(42)
	local b = New("TextButton", { Position = UDim2.fromOffset(14,8), Size = UDim2.new(1,-28,0,26), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(b, 6)
	--// Primary is the one action of a group (Add, Save); everything else stays
	--// quiet on the panel colour so the eye lands on the one that matters.
	if o.Primary then
		win:Bind(function() b.BackgroundColor3 = win.Theme.Accent end, b)
	else
		win:Themed(b, { BackgroundColor3 = "Element" })
	end
	local st = Stroke(b); win:_hover(b, st)
	if o.Primary then st.Transparency = .7 end
	local l = win:Label(b, o.Name, { Bold = true, TextSize = 13, Color = o.Primary and "Window" or nil }); l.TextXAlignment = Enum.TextXAlignment.Center
	b.MouseButton1Click:Connect(function()
		win:Tween(b, { Size = UDim2.new(1,-32,0,24), Position = UDim2.fromOffset(16,9) }, .06)
		task.delay(.08 / math.max(win.AnimSpeed, .1), function() win:Tween(b, { Size = UDim2.new(1,-28,0,26), Position = UDim2.fromOffset(14,8) }, .1) end)
		if o.Callback then task.spawn(o.Callback) end
	end)
	return self:_decorate(row, o, { SetText = function(_, t) l.Text = t end })
end

function Section:AddDivider()
	self._n += 1
	local r = New("Frame", { Size = UDim2.new(1,0,0,8), BackgroundTransparency = 1, LayoutOrder = self._n, Parent = self.Frame })
	local l = New("Frame", { Size = UDim2.new(1,-28,0,1), Position = UDim2.fromOffset(14,3), BorderSizePixel = 0, Parent = r })
	self.Win:Themed(l, { BackgroundColor3 = "Border" })
	return r
end

function Section:AddLabel(text)
	local row = self:_row(32)
	local l = self.Win:Label(row, text, { Color = "SubText", Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-28,1,0) })
	local obj = { Instance = l }

	function obj:Set(t) l.Text = t end
	--// A status line that colours itself (green / amber / red) and a log row
	--// that hides when the list shrinks both need the label itself.
	function obj:SetColor(c) l.TextColor3 = c end
	function obj:SetVisible(v) l.Visible = v and true or false end

	return self:_decorate(row, { Name = text }, obj)
end

------------------------------------------------------------------ notifications / watermark / keybind list
function Library:_buildNotifHolder()
	self.NotifHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0,270,1,-24), Parent = self.Gui })
	self.NotifLayout = New("UIListLayout", { Padding = UDim.new(0,8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = self.NotifHolder })
	self:SetNotificationPosition("Bottom right")
end
function Library:SetNotificationPosition(p)
	self.Notifications.Position = p
	local h, L = self.NotifHolder, self.NotifLayout
	local right, center = p:find("right") ~= nil, p:find("center") ~= nil
	local bottom = p:find("Bottom") ~= nil
	h.AnchorPoint = Vector2.new(center and .5 or (right and 1 or 0), bottom and 1 or 0)
	h.Position = UDim2.new(center and .5 or (right and 1 or 0), center and 0 or (right and -12 or 12), bottom and 1 or 0, bottom and -12 or 12)
	L.HorizontalAlignment = center and Enum.HorizontalAlignment.Center or (right and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left)
	L.VerticalAlignment = bottom and Enum.VerticalAlignment.Bottom or Enum.VerticalAlignment.Top
end
--// At most this many cards at once. A loop that reports one thing per entry
--// (every recipe, every ore) used to stack them all, and every card is a frame
--// with a tween and a delayed task of its own.
local MAX_NOTIFS = 4

function Library:Notify(o)
	if not self.Notifications.Enabled and not o.Force then return end

	self._notifs = self._notifs or {}

	local title = o.Title or self.Text.Notification
	local text = o.Text or ""

	--// The same message already on screen is not news: the card stays as it is
	--// and nothing new is built.
	for Index = #self._notifs, 1, -1 do
		local Entry = self._notifs[Index]

		if not Entry.Wrap.Parent then
			table.remove(self._notifs, Index)
		elseif Entry.Title == title and Entry.Text == text then
			return Entry
		end
	end

	--// Oldest leaves early once the stack is full, rather than off the screen.
	while #self._notifs >= MAX_NOTIFS do
		local Oldest = table.remove(self._notifs, 1)

		if Oldest and Oldest.Wrap then
			pcall(function()
				Oldest.Wrap:Destroy()
			end)
		end
	end

	self._nid = (self._nid or 0) + 1
	local dur = o.Duration or 4
	local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,54), LayoutOrder = self._nid, Parent = self.NotifHolder })
	local right = self.Notifications.Position:find("right") ~= nil
	local card = New("Frame", { Size = UDim2.fromScale(1,1), Position = UDim2.fromOffset(right and 300 or -300, 0), BorderSizePixel = 0, Parent = wrap })
	Round(card, 8)
	self:Themed(card, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(card), { Color = "Border" })
	self:Label(card, title, { Bold = true, Position = UDim2.fromOffset(12,8), SizeUDim = UDim2.new(1,-24,0,16) })
	self:Label(card, text, { Color = "SubText", TextSize = 12, Position = UDim2.fromOffset(12,26), SizeUDim = UDim2.new(1,-24,0,16) })
	local bar = New("Frame", { Position = UDim2.new(0,8,1,-4), Size = UDim2.new(1,-16,0,2), BorderSizePixel = 0, Parent = card })
	Round(bar, 1)
	self:Bind(function() bar.BackgroundColor3 = self.Theme.Accent end, bar)
	self:Tween(card, { Position = UDim2.new() }, .35, Enum.EasingStyle.Quint)
	TweenService:Create(bar, TweenInfo.new(dur, Enum.EasingStyle.Linear), { Size = UDim2.new(0,0,0,2) }):Play()
	local entry = { Title = title, Text = text, Wrap = wrap }
	table.insert(self._notifs, entry)

	task.delay(dur, function()
		self:Tween(card, { Position = UDim2.fromOffset(right and 300 or -300, 0) }, .25)
		task.wait(.3 / math.max(self.AnimSpeed, .1)); wrap:Destroy()

		local Index = table.find(self._notifs, entry)

		if Index then
			table.remove(self._notifs, Index)
		end
	end)

	return entry
end

function Library:_buildWatermark()
	local f = New("Frame", { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0,26), AnchorPoint = Vector2.new(1,0), Position = UDim2.new(1,-12,0,12), BorderSizePixel = 0, Visible = false, Parent = self.Gui })
	Round(f, 6)
	self:Themed(f, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(f), { Color = "Border" })
	New("UIPadding", { PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,10), Parent = f })
	local l = New("TextLabel", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0,26), Font = Fonts.Medium, TextSize = 12, Text = "", Parent = f })
	self:Themed(l, { TextColor3 = "Text" })
	self.Watermark, self.WatermarkLabel = f, l
	self:_updateWatermark(60)
end
function Library:_updateWatermark(fps)
	local ping = 0
	pcall(function() ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue()) end)
	self.WatermarkLabel.Text = string.format("%s  |  %s  |  %d fps  |  %d ms  |  %s", self.Title, self.User.Name or self.Text.UserFallback, fps or 0, ping, os.date("%H:%M"))
end

function Library:_buildKeybindList()
	local f = New("Frame", { AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.fromOffset(170,0), AnchorPoint = Vector2.new(0,.5), Position = UDim2.new(0,12,.5,0), BorderSizePixel = 0, Visible = false, Parent = self.Gui })
	Round(f, 6)
	self:Themed(f, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(f), { Color = "Border" })
	New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = f })
	New("UIPadding", { PaddingTop = UDim.new(0,6), PaddingBottom = UDim.new(0,6), PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,10), Parent = f })
	self.KeybindFrame = f
	self._kbRows = {}
	self:_updateKeybindList()
end
function Library:_updateKeybindList()
	if not self.KeybindFrame then return end
	for _, r in ipairs(self._kbRows) do r:Destroy() end
	self._kbRows = {}
	local function add(text, right, bold, order)
		local r = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,20), LayoutOrder = order, Parent = self.KeybindFrame })
		self:Label(r, text, { Bold = bold, TextSize = 12, Color = bold and "Text" or "SubText", SizeUDim = UDim2.new(1,-50,1,0) })
		if right then self:Label(r, right, { TextSize = 12, AlignRight = true }) end
		table.insert(self._kbRows, r)
	end
	add(self.Text.KeybindListTitle, nil, true, 0)
	for i, kb in ipairs(self.Keybinds) do if kb.Key then add(kb.Name, "[" .. kb.Key.Name .. "]", false, i) end end
end

------------------------------------------------------------------ cursor
function Library:_buildCursor()
	self.CursorGui = New("ScreenGui", { Name = self.Title .. "Cursor", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 2147483647, Parent = self.Gui.Parent })
	self.CursorHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(), Visible = false, Parent = self.CursorGui })
	self:_styleCursor()
end
function Library:_styleCursor()
	if self._styleQueued then return end
	self._styleQueued = true
	task.defer(function()
		self._styleQueued = false
		self:_drawCursor()
	end)
end

function Library:_drawCursor()
	local h, c = self.CursorHolder, self.Cursor
	local k = c.Size / 100
	local col = c.CustomEnabled and c.Color or Color3.new(1,1,1)
	-- Only the colour changed (dragging the cursor colour picker): recolour what exists, build nothing.
	local key = tostring(c.Style) .. "|" .. tostring(c.Size)
	if self._cursorKey == key and self._cursorFills then
		for _, f in ipairs(self._cursorFills) do f[1][f[2]] = col end
		return
	end
	self._cursorKey, self._cursorFills = key, {}
	local fills = self._cursorFills
	h:ClearAllChildren()
	if c.Style == "Dot" then
		local d = New("Frame", { Size = UDim2.fromOffset(7*k,7*k), AnchorPoint = Vector2.new(.5,.5), BackgroundColor3 = col, BorderSizePixel = 0, Parent = h }); Round(d, 8); Stroke(d, Color3.new(0,0,0), 1)
		table.insert(fills, { d, "BackgroundColor3" })
	elseif c.Style == "Cross" then
		for _, s in ipairs({ Vector2.new(12*k, 2), Vector2.new(2, 12*k) }) do
			local f = New("Frame", { Size = UDim2.fromOffset(s.X, s.Y), AnchorPoint = Vector2.new(.5,.5), BackgroundColor3 = col, BorderSizePixel = 0, Parent = h }); Stroke(f, Color3.new(0,0,0), 1)
			table.insert(fills, { f, "BackgroundColor3" })
		end
	elseif c.Style == "Circle" then
		local r = New("Frame", { Size = UDim2.fromOffset(16*k,16*k), AnchorPoint = Vector2.new(.5,.5), BackgroundTransparency = 1, Parent = h }); Round(r, 20)
		table.insert(fills, { Stroke(r, col, 2), "Color" })
	else
		-- arrow: tip sits exactly on the real mouse position. The black outline is the filled shape grown by
		-- `o` pixels, merged into one bar per row (about 60 frames instead of about 170).
		local spans = PolySpans(ARROW, k)
		local o = math.max(1, math.floor(k + .5))
		local rows = {}
		for _, s in ipairs(spans) do
			local x0 = math.floor(s[1])
			local x1 = x0 + math.max(1, math.ceil(s[3]))
			for dy = -o, o do
				local y = s[2] + dy
				rows[y] = rows[y] or {}
				table.insert(rows[y], { x0 - o, x1 + o })
			end
		end
		local function bar(x0, x1, y, color, z)
			return New("Frame", { Position = UDim2.fromOffset(x0, y), Size = UDim2.fromOffset(x1 - x0, 1), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z, Parent = h })
		end
		for y, list in pairs(rows) do
			table.sort(list, function(a, b) return a[1] < b[1] end)
			local cur = list[1]
			for n = 2, #list do
				local nx = list[n]
				if nx[1] <= cur[2] then cur[2] = math.max(cur[2], nx[2])
				else bar(cur[1], cur[2], y, Color3.new(0,0,0), 1); cur = nx end
			end
			bar(cur[1], cur[2], y, Color3.new(0,0,0), 1)
		end
		for _, s in ipairs(spans) do
			local x0 = math.floor(s[1])
			table.insert(fills, { bar(x0, x0 + math.max(1, math.ceil(s[3])), s[2], col, 2), "BackgroundColor3" })
		end
	end
end
function Library:_stepCursor()
	local mode = self.Cursor.Mode
	local show = mode == "Always" or (mode == "Menu open" and self.Root.Visible)

	--// A hidden cursor has no position to keep up to date.
	if show then
		local m = UIS:GetMouseLocation()
		self.CursorHolder.Position = UDim2.fromOffset(m.X, m.Y)
	end

	--// Written only when it changes: both of these are per-frame properties,
	--// and the cursor runs on every frame whether the window is up or not.
	if self.CursorHolder.Visible ~= show then
		self.CursorHolder.Visible = show
	end

	if show then
		if self._hid ~= true then
			self._hid = true
			UIS.MouseIconEnabled = false
		end
	elseif self._hid then
		self._hid = false
		UIS.MouseIconEnabled = true
	end
end
function Library:_ripple()
	local m = UIS:GetMouseLocation()
	local r = New("Frame", { AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromOffset(m.X, m.Y), Size = UDim2.fromOffset(4,4), BackgroundTransparency = 1, Parent = self.CursorGui })
	Round(r, 40)
	local s = Stroke(r, self.Cursor.CustomEnabled and self.Cursor.Color or self.Theme.Accent, 2)
	self:Tween(r, { Size = UDim2.fromOffset(40,40) }, .35)
	TweenService:Create(s, TweenInfo.new(.35), { Transparency = 1 }):Play()
	task.delay(.4, function() r:Destroy() end)
end

------------------------------------------------------------------ configs
-- Reads every saved config from disk (executors with file access only).
function Library:LoadConfigs()
	if not HasFS then return end
	pcall(function()
		if not isfolder(self.Folder) then makefolder(self.Folder) end
		for _, path in ipairs(listfiles(self.Folder)) do
			local n = path:match("([^/\\]+)%.json$")
			if n then
				local ok, data = pcall(function() return HttpService:JSONDecode(readfile(path)) end)
				if ok then self.Configs[n] = data end
			end
		end
	end)
	for _, sel in ipairs(self.ConfigSelectors or {}) do
		pcall(function() sel:SetOptions(self:GetConfigNames()) end)
		pcall(function() sel:Set(self.ConfigName, true) end)
	end
end
function Library:GetConfigNames()
	local names = {}
	for n in pairs(self.Configs) do table.insert(names, n) end
	table.sort(names)
	if #names == 0 then names = { self.ConfigName } end
	return names
end
function Library:SaveConfig(name)
	name = (name and name ~= "") and name or self.ConfigName
	local data = {}
	for k, v in pairs(self.Flags) do data[k] = Encode(v) end
	self.Configs[name] = data
	self.ConfigName = name
	if HasFS then pcall(function()
			if not isfolder(self.Folder) then makefolder(self.Folder) end
			writefile(self.Folder .. "/" .. name .. ".json", HttpService:JSONEncode(data))
		end) end
	for _, sel in ipairs(self.ConfigSelectors or {}) do
		pcall(function() sel:SetOptions(self:GetConfigNames()) end)
		pcall(function() sel:Set(name, true) end)
	end
	self:Notify{ Title = self.Text.ConfigSaved, Text = name }
end
function Library:LoadConfig(name)
	local data = self.Configs[name]
	if not data then
		self.ConfigName = name
		for _, sel in ipairs(self.ConfigSelectors or {}) do pcall(function() sel:Set(name, true) end) end
		return
	end
	for k, v in pairs(data) do
		local s = self._setters[k]
		if s then pcall(s, Decode(v)) end
	end
	self.ConfigName = name
	for _, sel in ipairs(self.ConfigSelectors or {}) do pcall(function() sel:Set(name, true) end) end
	self:Notify{ Title = self.Text.ConfigLoaded, Text = name }
end
function Library:SetAutoload(name)
	name = name or self.ConfigName
	if HasFS then pcall(function() writefile(self.Folder .. "/autoload.txt", name) end) end
	self:Notify{ Title = self.Text.AutoloadSet, Text = name }
end
-- Applies the config named in autoload.txt (call after every element exists).
function Library:Autoload()
	if not HasFS then return end
	pcall(function()
		local p = self.Folder .. "/autoload.txt"
		if isfile(p) then
			local n = readfile(p)
			if self.Configs[n] then self:LoadConfig(n) end
		end
	end)
end

Section.AddTextbox = Section.AddTextBox

function Section:AddPriority(name, values, options)
	local lib = self.Win
	options = options or {}

	local hasValues = options.Values == true
	local hasChecks = options.Checks == true
	local defaultValue = tonumber(options.Default) or 0
	local minValue = tonumber(options.Min) or 0
	local maxValue = tonumber(options.Max) or math.huge

	local header = self:_row((hasValues or hasChecks) and 46 or 36)
	lib:Label(header, string.upper(tostring(name or "")), {
		Bold = true,
		TextSize = 12,
		Position = UDim2.fromOffset(14, 7),
		SizeUDim = UDim2.new(1, -110, 0, 16),
	})

	--// How many entries the list holds, on the header it belongs to rather
	--// than in a line of its own further down the section.
	local countLabel = lib:Label(header, "", {
		TextSize = 10,
		Color = "SubText",
		Position = UDim2.new(1, -14, 0, 9),
		SizeUDim = UDim2.fromOffset(88, 12),
	})
	countLabel.AnchorPoint = Vector2.new(1, 0)
	countLabel.TextXAlignment = Enum.TextXAlignment.Right

	--// A count sits over its own column instead of a caption floating at the
	--// left where it described nothing.
	if hasValues then
		local cap = lib:Label(header, string.upper(tostring(options.ValueLabel or "Value")), {
			TextSize = 9,
			Color = "SubText",
			Position = UDim2.new(1, -108, 0, 24),
			SizeUDim = UDim2.fromOffset(64, 12),
		})
		cap.AnchorPoint = Vector2.new(1, 0)
		cap.TextXAlignment = Enum.TextXAlignment.Center
	end
	if hasChecks then
		local cap = lib:Label(header, string.upper(tostring(options.CheckLabel or "Check")), {
			TextSize = 9,
			Color = "SubText",
			Position = UDim2.fromOffset(14, 24),
			SizeUDim = UDim2.fromOffset(20, 12),
		})
		cap.TextXAlignment = Enum.TextXAlignment.Center
	end

	local listRow = self:_row(0, true)
	listRow.Size = UDim2.new(1, 0, 0, 0)

	--// The rows live in a scrolling box with an explicit height. A list that
	--// is part of the page's automatic layout grows without limit: every row
	--// added re-measures the section, the page and the window above it, which
	--// is what makes a long whitelist or waypoint list feel like a freeze.
	local PRIORITY_LIST_MAX = 300

	local listFrame = New("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageTransparency = .4,
		Parent = listRow,
	})

	New("UIListLayout", {
		Padding = UDim.new(0, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = listFrame,
	})
	--// Every entry is its own card, inset from the section edge, so a list
	--// reads as rows of things rather than one striped block.
	New("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 6),
		PaddingBottom = UDim.new(0, 10),
		Parent = listFrame,
	})

	local component = {
		Library = lib,
		Priority = {},
		Values = {},
		Checks = {},
		CountLabel = countLabel,
		Header = header,
		Frame = listRow,
		Holder = listFrame,
		Scroll = listFrame,
		Format = options.Format,
		OnChanged = nil,
		OnSelect = options.OnSelect,
		OnValueChanged = nil,
		OnCheckChanged = nil,
	}

	local function ClampValue(value)
		return math.clamp(tonumber(value) or defaultValue, minValue, maxValue)
	end

	local function Fit()
		for index = 1, #component.Priority do
			component.Values[index] = ClampValue(component.Values[index])
			component.Checks[index] = component.Checks[index] == true
		end
		for index = #component.Values, #component.Priority + 1, -1 do
			component.Values[index] = nil
		end
		for index = #component.Checks, #component.Priority + 1, -1 do
			component.Checks[index] = nil
		end
	end

	local Refresh

	--// A small round-cornered glyph button on the right of a row: faint at rest
	--// so a list of entries reads as text, and filled in under the pointer so
	--// the controls are still visible as controls, not discovered by accident.
	local function IconButton(parent, glyph, x, danger, textSize)
		local button = New("TextButton", {
			AnchorPoint = Vector2.new(1, .5),
			Position = UDim2.new(1, x, .5, 0),
			Size = UDim2.fromOffset(24, 24),
			BackgroundColor3 = lib.Theme.Element,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Text = glyph,
			Font = Fonts.Bold,
			TextSize = textSize or 11,
			TextColor3 = danger and lib.Theme.Danger or lib.Theme.SubText,
			TextTransparency = .35,
			AutoButtonColor = false,
			Parent = parent,
		})
		Round(button, 6)
		local stroke = Stroke(button, lib.Theme.Border, 1)
		stroke.Transparency = 1
		button.MouseEnter:Connect(function()
			lib:Tween(button, { BackgroundTransparency = 0, BackgroundColor3 = (danger and lib.Theme.Danger) or lib.Theme.Element, TextTransparency = 0 }, .12)
			lib:Tween(button, { TextColor3 = danger and lib.Theme.Window or lib.Theme.Text }, .12)
			lib:Tween(stroke, { Transparency = .5 }, .12)
		end)
		button.MouseLeave:Connect(function()
			lib:Tween(button, { BackgroundTransparency = 1, TextTransparency = .35 }, .12)
			lib:Tween(button, { TextColor3 = danger and lib.Theme.Danger or lib.Theme.SubText }, .12)
			lib:Tween(stroke, { Transparency = 1 }, .12)
		end)
		return button
	end

	Refresh = function()
		for _, child in ipairs(listFrame:GetChildren()) do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
		Fit()

		local Count = #component.Priority
		countLabel.Text = Count == 0 and "EMPTY" or (Count .. (Count == 1 and " ENTRY" or " ENTRIES"))

		--// Height of everything inside the box, padding included.
		local Total = 16

		if #component.Priority == 0 then
			local empty = New("Frame", {
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, 38),
				BackgroundColor3 = lib.Theme.Element,
				BackgroundTransparency = .55,
				BorderSizePixel = 0,
				Parent = listFrame,
			})
			Round(empty, 6)
			Stroke(empty, lib.Theme.Border).Transparency = .5
			local text = lib:Label(empty, "Nothing in this list yet", { Color = "SubText", TextSize = 11 })
			text.Size = UDim2.fromScale(1, 1)
			text.TextXAlignment = Enum.TextXAlignment.Center
			listRow.Size = UDim2.new(1, 0, 0, Total + 38)
			return
		end

		--// Where the text has to stop: the count box and the three buttons sit
		--// at the right, packed from the edge inwards.
		local rightInset = hasValues and 172 or 100

		for index, value in ipairs(component.Priority) do
			local shown, sub

			if component.Format then
				shown, sub = component.Format(value)
			end

			shown = shown or tostring(value)

			local row = New("Frame", {
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, sub and 46 or 38),
				BackgroundColor3 = lib.Theme.Element,
				BackgroundTransparency = .45,
				BorderSizePixel = 0,
				Parent = listFrame,
			})
			Round(row, 6)

			local rowStroke = Stroke(row, lib.Theme.Border)
			rowStroke.Transparency = .4

			--// The whole row answers the pointer, so it reads as something that
			--// can be moved and removed rather than a printed line.
			row.MouseEnter:Connect(function()
				lib:Tween(row, { BackgroundTransparency = .3 }, .12)
				lib:Tween(rowStroke, { Transparency = .12 }, .12)
			end)
			row.MouseLeave:Connect(function()
				lib:Tween(row, { BackgroundTransparency = .45 }, .12)
				lib:Tween(rowStroke, { Transparency = .4 }, .12)
			end)

			Total += (sub and 46 or 38) + 5

			local left = 14
			if hasChecks then
				local checked = component.Checks[index] == true
				local check = New("TextButton", {
					Size = UDim2.fromOffset(18, 18),
					AnchorPoint = Vector2.new(0, .5),
					Position = UDim2.new(0, 12, .5, 0),
					BackgroundColor3 = checked and lib.Theme.Accent or lib.Theme.Element,
					BorderSizePixel = 0,
					Text = checked and "✓" or "",
					Font = Fonts.Bold,
					TextSize = 11,
					TextColor3 = lib.Theme.Window,
					AutoButtonColor = false,
					Parent = row,
				})
				Round(check, 5)
				Stroke(check, checked and lib.Theme.Accent or lib.Theme.Border).Transparency = checked and 0 or .2
				lib:_Connect(check.MouseButton1Click, function()
					component:SetCheck(index, not component.Checks[index])
				end)
				left = 40
			end

			if sub then
				local title = lib:Label(row, shown, {
					Color = "Text",
					TextSize = 12,
					Position = UDim2.fromOffset(left, 7),
					SizeUDim = UDim2.new(1, -(left + rightInset), 0, 15),
				})
				title.Font = Fonts.Medium
				title.TextTruncate = Enum.TextTruncate.AtEnd
				lib:Label(row, sub, {
					Color = "SubText",
					TextSize = 10,
					Position = UDim2.fromOffset(left, 24),
					SizeUDim = UDim2.new(1, -(left + rightInset), 0, 13),
				})
			else
				local title = lib:Label(row, shown, {
					Color = "Text",
					TextSize = 12,
					Position = UDim2.fromOffset(left, 0),
					SizeUDim = UDim2.new(1, -(left + rightInset), 1, 0),
				})
				title.Font = Fonts.Medium
				title.TextTruncate = Enum.TextTruncate.AtEnd
			end

			if component.OnSelect then
				local select = New("TextButton", {
					Name = "SelectEntry", BackgroundTransparency = 1, BorderSizePixel = 0,
					Text = "", AutoButtonColor = false, Position = UDim2.fromOffset(left, 0),
					Size = UDim2.new(1, -(left + rightInset), 1, 0), Parent = row,
				})
				select.MouseButton1Click:Connect(function()
					component.OnSelect(value)
				end)
			end

			if hasValues then
				local box = New("TextBox", {
					AnchorPoint = Vector2.new(1, .5),
					Position = UDim2.new(1, -98, .5, 0),
					Size = UDim2.fromOffset(64, 24),
					BackgroundColor3 = lib.Theme.Window,
					BackgroundTransparency = .25,
					BorderSizePixel = 0,
					Text = tostring(component.Values[index]),
					Font = Fonts.Medium,
					TextSize = 11,
					TextColor3 = lib.Theme.Text,
					TextXAlignment = Enum.TextXAlignment.Center,
					ClearTextOnFocus = false,
					Parent = row,
				})
				Round(box, 6)
				local boxStroke = Stroke(box, lib.Theme.Border, 1)
				boxStroke.Transparency = .2
				lib:_focusStroke(box, boxStroke)
				lib:_Connect(box.FocusLost, function()
					local number = tonumber(box.Text)
					if not number then
						box.Text = tostring(component.Values[index])
						return
					end
					component.Values[index] = ClampValue(number)
					box.Text = tostring(component.Values[index])
					if component.OnValueChanged then
						task.spawn(component.OnValueChanged, index, component.Values[index], component.Priority[index])
					end
				end)
			end

			local up = IconButton(row, "▲", -66, false, 8)
			local down = IconButton(row, "▼", -38, false, 8)
			local remove = IconButton(row, "X", -10, true)

			lib:_Connect(up.MouseButton1Click, function()
				component:MoveUp(value)
			end)
			lib:_Connect(down.MouseButton1Click, function()
				component:MoveDown(value)
			end)
			lib:_Connect(remove.MouseButton1Click, function()
				component:Remove(value)
			end)
		end

		--// The box is as tall as its rows, up to the cap; past that it scrolls.
		listRow.Size = UDim2.new(1, 0, 0, math.min(Total - 5, PRIORITY_LIST_MAX))
	end

	function component:_Refresh()
		Refresh()
	end

	--// newValues and newChecks are optional; without them the current ones
	--// are kept, trimmed or padded with the default to fit the new list.
	function component:SetPriority(newPriority, newValues, newChecks)
		table.clear(self.Priority)
		for _, value in ipairs(newPriority or {}) do
			table.insert(self.Priority, value)
		end

		if newValues then
			table.clear(self.Values)
			for index, value in ipairs(newValues) do
				self.Values[index] = value
			end
		end

		if newChecks then
			table.clear(self.Checks)
			for index = 1, #self.Priority do
				self.Checks[index] = newChecks[index] == true
			end
		end

		Refresh()
	end

	function component:GetPriority()
		return table.clone(self.Priority)
	end

	function component:GetValues()
		Fit()
		return table.clone(self.Values)
	end

	function component:GetChecks()
		Fit()
		return table.clone(self.Checks)
	end

	function component:GetValue(index)
		return ClampValue(self.Values[index])
	end

	function component:SetValue(index, value)
		if not self.Priority[index] then return end
		self.Values[index] = ClampValue(value)
		if self.OnValueChanged then
			self.OnValueChanged(index, self.Values[index], self.Priority[index])
		end
	end

	function component:SetCheck(index, checked)
		if not self.Priority[index] then return end
		self.Checks[index] = checked == true
		Refresh()
		if self.OnCheckChanged then
			self.OnCheckChanged(index, self.Checks[index], self.Priority[index])
		end
	end

	function component:Add(value, initialValue)
		if table.find(self.Priority, value) then
			return false
		end
		table.insert(self.Priority, value)
		self.Values[#self.Priority] = ClampValue(initialValue)
		self.Checks[#self.Priority] = false
		Refresh()
		return true
	end

	function component:Remove(value)
		local index = table.find(self.Priority, value)
		if not index then return false end
		table.remove(self.Priority, index)
		table.remove(self.Values, index)
		table.remove(self.Checks, index)
		Refresh()
		return true
	end

	function component:MoveUp(value)
		local index = table.find(self.Priority, value)
		if not index or index <= 1 then return end
		self.Priority[index], self.Priority[index - 1] = self.Priority[index - 1], self.Priority[index]
		self.Values[index], self.Values[index - 1] = self.Values[index - 1], self.Values[index]
		self.Checks[index], self.Checks[index - 1] = self.Checks[index - 1], self.Checks[index]
		Refresh()
	end

	function component:MoveDown(value)
		local index = table.find(self.Priority, value)
		if not index or index >= #self.Priority then return end
		self.Priority[index], self.Priority[index + 1] = self.Priority[index + 1], self.Priority[index]
		self.Values[index], self.Values[index + 1] = self.Values[index + 1], self.Values[index]
		self.Checks[index], self.Checks[index + 1] = self.Checks[index + 1], self.Checks[index]
		Refresh()
	end

	self.Components[#self.Components + 1] = component
	--// Redraws the rows after a change the component cannot see itself, such
	--// as a name arriving for a row.
	component.Refresh = function()
		Refresh()
	end
	component:SetPriority(values or {})
	return component
end


--// Theme / font / window helpers needed by the Settings tab.
function Library:SetTheme(themeMap)
	if type(themeMap) ~= "table" then return end
	for k, v in pairs(themeMap) do
		if typeof(v) == "Color3" then self.Theme[k] = v end
	end
	if self.OnThemeChanged then task.spawn(self.OnThemeChanged, self.Theme) end
	self:QueueRefresh()
end
function Library:SetTextScale(scale)
	if not scale then return end
	scale = math.clamp(tonumber(scale) or 1, 0.5, 2.5)
	self.TextScale = scale
	if self.OnTextScaleChanged then task.spawn(self.OnTextScaleChanged, scale) end
	self:QueueRefresh()
	return scale
end
function Library:SetWindowSize(w, h)
	if not w then return end
	w = math.clamp(tonumber(w) or ROOT_W, 500, 2000)
	h = h and math.clamp(tonumber(h) or ROOT_H, 260, 1200) or ROOT_H
	ROOT_W, ROOT_H = w, h
	if self.Root then self.Root.Size = UDim2.fromOffset(w, h) end
	if self.Content then self.Content.Size = UDim2.new(1, -SIDEBAR, 1, -HEADER) end
end
function Library:_GetFontChoices()
	local names, byFamily = {}, {}
	local families = { "BuilderSans", "BuilderSansMedium", "BuilderSansBold", "Gotham", "GothamMedium", "GothamBold", "Arial", "Roboto" }
	for _, fam in ipairs(families) do
		local ok, f = pcall(function() return Enum.Font[fam] end)
		if ok and f then
			table.insert(names, fam)
			byFamily[fam] = f
		end
	end
	return { Names = names, ByFamily = byFamily }
end
function Library:SetFont(name)
	if not name then return false end
	local ok, f = pcall(function() return Enum.Font[name] end)
	if not ok then return false end
	self.FontName = name
	Library.Fonts.Regular = f
	Library.Fonts.Medium = f
	Library.Fonts.Bold = f
	Fonts.Regular, Fonts.Medium, Fonts.Bold = f, f, f
	if self.OnFontChanged then task.spawn(self.OnFontChanged, name) end
	self:QueueRefresh()
	return true
end

function Library:_BuildSettingsTab()
	if self.SettingsTab then return self.SettingsTab end

	local tab = self:AddTab{ Name = "Settings", Description = "Menu, cursor and config options." }
	self.SettingsTab = tab

	local fontChoices = self:_GetFontChoices()
	local defaultFont = self.FontName or fontChoices.Names[1]
	--// The slider starts where the text actually is. It used to be corrected
	--// by its own build time callback; now that widgets do not call back while
	--// they are built, it has to read the current scale itself.
	local defaultTextScale = math.round(((self.TextScale or self._DefaultTextScale or 1) * 100))
	local defaultWidth = self._DefaultWindowSize and self._DefaultWindowSize.X or ROOT_W
	local defaultHeight = self._DefaultWindowSize and self._DefaultWindowSize.Y or ROOT_H

	--// Appearance
	local appearance = tab:AddSection{ Full = true, Title = "Appearance" }
	local themePickers = {}
	local themeRows = {
		{ "Accent", "Accent colour" },
		{ "Window", "Background" },
		{ "Panel", "Panel" },
		{ "Element", "Element" },
		{ "Border", "Border" },
		{ "Text", "Text" },
		{ "SubText", "Muted text" },
		{ "Hover", "Hovered border" },
		{ "Danger", "Danger" },
		{ "Warning", "Warning" },
	}
	for _, entry in ipairs(themeRows) do
		local key, label = entry[1], entry[2]
		themePickers[key] = appearance:AddColorPicker{
			Name = label,
			Default = self.Theme[key],
			Flag = "Theme_" .. key,
			Callback = function(color) self:SetTheme({ [key] = color }) end,
		}
	end
	appearance:AddDropdown{
		Name = "Menu palette",
		Options = { "Default", "Navy", "Midnight", "Rose", "Forest", "Light" },
		Default = self.Palette,
		Flag = "Palette",
		Callback = function(value)
			if value ~= self.Palette then
				self:SetPalette(value)
				for key, picker in pairs(themePickers) do
					if self.Theme[key] then picker:Set(self.Theme[key], true) end
				end
			end
		end,
	}

	--// Interface
	local interface = tab:AddSection{ Full = true, Title = "Interface" }
	interface:AddSlider{
		Name = "Text scale",
		Min = 80,
		Max = 220,
		Default = defaultTextScale,
		Suffix = "%",
		Flag = "TextScale",
		Callback = function(value) self:SetTextScale(value / 100) end,
	}
	self._FontDropdown = interface:AddDropdown{
		Name = "Font",
		Options = fontChoices.Names,
		Default = defaultFont,
		Visible = 6,
		Flag = "Font",
		Callback = function(value)
			if value ~= (self.FontName or defaultFont) then
				if not self:SetFont(value) then
					self:Notify{ Title = "Font", Text = "That font could not be used.", Duration = 2 }
				end
			end
		end,
	}
	interface:AddSlider{
		Name = "Window width",
		Min = 500,
		Max = 1400,
		Default = defaultWidth,
		Suffix = " px",
		Flag = "WindowWidth",
		Callback = function(value) self:SetWindowSize(value, nil) end,
	}
	interface:AddSlider{
		Name = "Window height",
		Min = 260,
		Max = 900,
		Default = defaultHeight,
		Suffix = " px",
		Flag = "WindowHeight",
		Callback = function(value) self:SetWindowSize(nil, value) end,
	}
	interface:AddButton{
		Name = "Restore defaults",
		Callback = function()
			self:SetTheme({ Accent = rgb(79,124,245), Window = rgb(21,21,27), Panel = rgb(27,27,34),
				Element = rgb(36,36,45), Border = rgb(45,45,56), Text = rgb(240,240,246),
				SubText = rgb(122,122,140), Hover = rgb(72,76,92), Danger = rgb(255,92,92), Warning = rgb(255,190,92) })
			self:SetPalette("Default")
			self:SetTextScale(1)
			self:SetWindowSize(ROOT_W, ROOT_H)
			self:SetAnimSpeed(1)
			if self._FontDropdown then self._FontDropdown:Set(defaultFont, true) end
			self:Notify{ Title = "Appearance", Text = "Default configuration restored.", Duration = 2 }
		end,
	}

	--// Notifications and tabs
	local behavior = tab:AddSection{ Full = true, Title = "Notifications and tabs" }
	behavior:AddToggle{
		Name = "Display notifications",
		Default = self.Notifications.Enabled,
		Flag = "Notifications",
		Callback = function(value) self:SetNotificationsEnabled(value) end,
	}
	behavior:AddDropdown{
		Name = "Notification position",
		Options = { "Top left", "Top center", "Top right", "Bottom left", "Bottom right" },
		Default = self.Notifications.Position,
		Flag = "NotifPos",
		Callback = function(value) self:SetNotificationPosition(value) end,
	}
	behavior:AddDropdown{
		Name = "Animation of tab change",
		Options = { "Fade", "Slide", "None" },
		Default = self.TabAnimation,
		Flag = "TabAnim",
		Callback = function(value) self:SetTabAnimation(value) end,
	}
	behavior:AddToggle{
		Name = "Watermark",
		Default = self.Watermark and self.Watermark.Visible or false,
		Flag = "Watermark",
		Callback = function(value) self:SetWatermark(value) end,
	}
	behavior:AddToggle{
		Name = "Keybind list",
		Default = self.KeybindFrame and self.KeybindFrame.Visible or false,
		Flag = "KeybindList",
		Callback = function(value) self:SetKeybindList(value) end,
	}
	behavior:AddKeybind{
		Name = "Menu key",
		Default = self.MenuKey or Enum.KeyCode.Insert,
		Flag = "MenuKey",
		Hidden = true,
		OnChanged = function(key) self:SetMenuKey(key) end,
	}

	--// Cursor
	local cursor = tab:AddSection{ Full = true, Title = "Cursor" }
	cursor:AddDropdown{
		Name = "Cursor",
		Options = { "Menu open", "Always", "Never" },
		Default = self.Cursor and self.Cursor.Mode or "Menu open",
		Flag = "CursorMode",
		Callback = function(value) self:SetCursor{ Mode = value } end,
	}
	cursor:AddDropdown{
		Name = "Cursor style",
		Options = { "Arrow", "Dot", "Cross", "Circle" },
		Default = self.Cursor and self.Cursor.Style or "Arrow",
		Flag = "CursorStyle",
		Callback = function(value) self:SetCursor{ Style = value } end,
	}
	cursor:AddSlider{
		Name = "Cursor size",
		Min = 50,
		Max = 300,
		Default = self.Cursor and self.Cursor.Size or 100,
		Suffix = "%",
		Flag = "CursorSize",
		Callback = function(value) self:SetCursor{ Size = value } end,
	}
	cursor:AddToggle{
		Name = "Cursor effects",
		Default = self.Cursor and self.Cursor.Effects ~= false,
		Flag = "CursorEffects",
		Callback = function(value) self:SetCursor{ Effects = value } end,
	}
	cursor:AddColorPicker{
		Name = "Custom cursor colour",
		Toggle = true,
		Default = self.Cursor and self.Cursor.Color or rgb(70,160,255),
		Flag = "CursorColor",
		Callback = function(color, enabled) self:SetCursor{ Color = color, CustomEnabled = enabled } end,
	}


	--// Configuration
	local configs = tab:AddSection{ Full = true, Title = "Configuration" }
	configs:AddConfigSelector{ Name = "Config", Flag = "ConfigSelect", NoSave = true }
	local configName = configs:AddTextBox{ Name = "Config name", Placeholder = "Config name", NoSave = true }
	configs:AddButton{
		Name = "Save",
		Callback = function()
			local n = configName:Get() ~= "" and configName:Get() or self.ConfigName
			self:SaveConfig(n)
			configName:Set("", true)
		end,
	}
	configs:AddButton{
		Name = "Load",
		Callback = function()
			local n = configName:Get()
			if n ~= "" then self:LoadConfig(n) end
		end,
	}
	configs:AddButton{
		Name = "Autoload",
		Callback = function() self:SetAutoload(self.ConfigName) end,
	}

	return tab
end

--// A load failure replaces the window with the full message, wrapped and
--// scrollable, because a traceback is far longer than a status line. The text
--// also goes to the clipboard where the executor offers one.
function Library:ShowError(text)
	text = tostring(text)

	if self.ErrorPanel then
		self.ErrorPanel.Text.Text = text
		return self.ErrorPanel
	end

	local sheet = New("Frame", { Name = "LoadError", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 210, Parent = self.Root })
	Round(sheet, 10)
	self:Themed(sheet, { BackgroundColor3 = "Panel" })

	local title = self:Label(sheet, "LOAD FAILED", {
		Bold = true, TextSize = 20, Color = "Danger",
		Position = UDim2.fromOffset(24, 18), SizeUDim = UDim2.new(1, -48, 0, 26),
	})
	title.TextXAlignment = Enum.TextXAlignment.Left

	local hint = self:Label(sheet, "The message is copied to the clipboard where available.", {
		Color = "SubText", TextSize = 11,
		Position = UDim2.fromOffset(24, 44), SizeUDim = UDim2.new(1, -48, 0, 16),
	})
	hint.TextXAlignment = Enum.TextXAlignment.Left

	local scroll = New("ScrollingFrame", {
		Position = UDim2.fromOffset(24, 66), Size = UDim2.new(1, -48, 1, -90),
		BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = sheet,
	})

	local body = New("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -12, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Text = text, TextWrapped = true, TextSize = 12, Font = Fonts.Regular,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Parent = scroll,
	})
	self:Themed(body, { TextColor3 = "SubText" })

	if type(setclipboard) == "function" then
		pcall(setclipboard, text)
	end

	self.ErrorPanel = { Sheet = sheet, Text = body }

	return self.ErrorPanel
end

function Library:FinishLoading()
	local boot = self.Loader

	--// Runs the bar to the end, fades the sheet out and reveals the menu.
	if boot and not boot.Finishing then
		boot.Finishing = true

		task.spawn(function()
			self:Tween(boot.Fill, { Size = UDim2.fromScale(1, 1) }, .3, Enum.EasingStyle.Quart)
			task.wait(.34 / math.max(self.AnimSpeed, .1))

			if self.Destroyed then
				return
			end

			self:Tween(boot.Sheet, { BackgroundTransparency = 1 }, .2)
			self:Tween(boot.Status, { TextTransparency = 1 }, .2)
			task.wait(.22)

			if boot.Sheet then
				boot.Sheet:Destroy()
			end

			self.Loader = nil
		end)
	end

	if not self._settingsBuilt then
		self._settingsBuilt = true
		pcall(function() self:_BuildSettingsTab() end)
	end
end

--------------------------------------------------------------------------------
-- Project surface
--
-- script/ builds its menu out of feature modules rather than from this file
-- alone, so the pieces those modules reach for live here: tooltips looked up
-- by control name, the boot loader, connection bookkeeping, the drag and
-- clamp helpers the detail panels use, and the pinned items panel.
--------------------------------------------------------------------------------

--// Connections made through this are dropped together with the window.
function Library:_Connect(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(self._conns, connection)
	return connection
end

--// Name -> description for the hover tips, upper case keyed so the label's
--// own casing does not matter. A description passed to a widget wins over
--// the map.
function Library:SetDescriptions(map)
	self.Descriptions = {}

	for name, text in pairs(type(map) == "table" and map or {}) do
		self.Descriptions[string.upper(tostring(name))] = text
	end
end

function Library:_GetDescription(name, description)
	if type(description) == "string" and description ~= "" then
		return description
	end

	return self.Descriptions and self.Descriptions[string.upper(tostring(name))] or nil
end

--// Per row: what its hover tip says. Kept beside the row instead of inside a
--// closure so a note added later, or a description set after the control was
--// built, is picked up by the tip that is already connected.
local RowTips = setmetatable({}, { __mode = "k" })

--// Called for every control a section builds. One hover handler per row: the
--// description and any note are read when the tip opens, never copied into
--// it, so the two always agree.
function Library:_attachTip(row, name, description)
	if not row then
		return
	end

	local entry = RowTips[row]

	if entry then
		entry.Name, entry.Description = name, description
		return
	end

	entry = { Name = name, Description = description }
	RowTips[row] = entry

	row.MouseEnter:Connect(function()
		local text = self:_rowTipText(entry)

		if text and row.Parent then
			self:_showTip(row, text)
		end
	end)
	row.MouseLeave:Connect(function()
		self:_hideTip()
	end)
end

--// The tip for a row: its description, then any notes below it, one per line.
function Library:_rowTipText(entry)
	local text = self:_GetDescription(entry.Name, entry.Description)

	if entry.Note and entry.Note ~= "" then
		text = (text and text ~= "" and (text .. "\n" .. entry.Note)) or entry.Note
	end

	return text
end

function Section:_decorate(row, o, obj)
	if not row then
		return obj
	end

	if o and o.Name then
		row.Name = tostring(o.Name)
	end

	if type(obj) == "table" then
		obj.Row = row

		if not obj.Remove then
			obj.Remove = function(self)
				if row then
					row:Destroy()
				end
			end
		end
	end

	self.Win:_attachTip(row, o and o.Name, o and o.Description)

	return obj
end

--// Help text for the control above it. A note used to take a whole row under
--// its control, which pushed every section taller than it needed to be; it now
--// joins that control's hover tip. Notes that stack on one control are shown
--// one per line. Without a control above (nothing built yet) it stays visible,
--// so a caller cannot lose its text.
function Section:AddNote(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end

	local row = self._lastRow

	if not row then
		return self:AddLabel(text)
	end

	local entry = RowTips[row]

	if not entry then
		self.Win:_attachTip(row, nil, nil)
		entry = RowTips[row]
	end

	if entry then
		entry.Note = entry.Note and (entry.Note .. "\n" .. text) or text
	end

	return nil
end

--------------------------------------------------------------------------------
-- Boot loader: the window can be shown while modules still load, and
-- SetLoadingProgress reports how far along that is. Without ManualLoading the
-- loader never appears and FinishLoading just builds the Settings tab.
--------------------------------------------------------------------------------

function Library:_buildLoader()
	if self.Loader then
		return self.Loader
	end

	local sheet = New("Frame", { Name = "Loader", Size = UDim2.fromScale(1, 1), BorderSizePixel = 0, ZIndex = 200, Parent = self.Root })
	Round(sheet, 10)
	self:Themed(sheet, { BackgroundColor3 = "Window" })

	local brand = self:Label(sheet, string.upper(self.Title), {
		Bold = true, TextSize = 22,
		Position = UDim2.fromOffset(40, ROOT_H / 2 - 66),
		SizeUDim = UDim2.new(1, -80, 0, 30),
	})
	brand.TextXAlignment = Enum.TextXAlignment.Left

	local status = self:Label(sheet, "STARTING", {
		Color = "SubText", TextSize = 11,
		Position = UDim2.fromOffset(42, ROOT_H / 2 - 34),
		SizeUDim = UDim2.new(1, -84, 0, 16),
	})
	status.TextXAlignment = Enum.TextXAlignment.Left

	local track = New("Frame", { Position = UDim2.fromOffset(42, ROOT_H / 2 - 8), Size = UDim2.new(1, -84, 0, 4), BorderSizePixel = 0, Parent = sheet })
	Round(track, 2)
	self:Themed(track, { BackgroundColor3 = "Border" })

	local fill = New("Frame", { Size = UDim2.fromScale(0, 1), BorderSizePixel = 0, Parent = track })
	Round(fill, 2)
	self:Bind(function() fill.BackgroundColor3 = self.Theme.Accent end, fill)

	self.Loader = { Sheet = sheet, Status = status, Fill = fill, Finishing = false }

	return self.Loader
end

function Library:SetLoadingProgress(fraction, text, isError)
	local boot = self.Loader

	if self.Destroyed or not boot or boot.Finishing then
		return
	end

	if text then
		boot.Status.Text = string.upper(tostring(text))
	end

	boot.Status.TextColor3 = isError and self.Theme.Danger or self.Theme.SubText

	if fraction then
		self:Tween(boot.Fill, { Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1) }, .2)
	end
end

--------------------------------------------------------------------------------
-- Small helpers the detail / floating panels were written against.
--------------------------------------------------------------------------------

function Library:_AddAngularCorners(parent, color)
	Round(parent, 8)
	return self:Themed(Stroke(parent), { Color = "Border" })
end

function Library:_AddHoverHighlight(target, stroke)
	return self:_hover(target, stroke)
end

--// Keeps a popup inside its parent when it is dragged or placed near an edge.
local function ClampToParent(target)
	local parent = target and target.Parent

	if not parent or not parent:IsA("GuiBase2d") then
		return
	end

	local bounds, size = parent.AbsoluteSize, target.AbsoluteSize

	if bounds.X <= 0 or bounds.Y <= 0 then
		return
	end

	local position, anchor = target.Position, target.AnchorPoint
	local left = bounds.X * position.X.Scale + position.X.Offset - anchor.X * size.X
	local top = bounds.Y * position.Y.Scale + position.Y.Offset - anchor.Y * size.Y
	local clampedLeft = math.clamp(left, 0, math.max(0, bounds.X - size.X))
	local clampedTop = math.clamp(top, 0, math.max(0, bounds.Y - size.Y))

	if clampedLeft ~= left or clampedTop ~= top then
		target.Position = UDim2.new(
			position.X.Scale, position.X.Offset + (clampedLeft - left),
			position.Y.Scale, position.Y.Offset + (clampedTop - top)
		)
	end
end

function Library:_ClampToParent(target)
	return ClampToParent(target)
end

function Library:_MakeDraggable(handle, target, keepOnScreen)
	local dragging, dragStart, startPosition = false

	self:_Connect(handle.InputBegan, function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		startPosition = target.Position

		local changedConnection

		changedConnection = input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false

				if changedConnection then
					changedConnection:Disconnect()
				end
			end
		end)
	end)

	self:_Connect(UIS.InputChanged, function(input)
		if not dragging then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local delta = input.Position - dragStart

		target.Position = UDim2.new(
			startPosition.X.Scale, startPosition.X.Offset + delta.X,
			startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
		)

		if keepOnScreen then
			self:_ClampToParent(target)
		end
	end)
end


return Library
