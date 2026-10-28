--[[
    UILib - bottom-tab UI library for Roblox (Luau)

    local Library = loadstring(readfile("UILib.lua"))()   -- or require(module)
    local Window  = Library.new{ Title = "Menu", User = { Name = "You", Tag = "@player" } }
    local Tab     = Window:AddTab{ Name = "Main", Icon = "rbxassetid://0", Glyph = "M" }
    local Sec     = Tab:AddSection{ Side = "Left" }
    Sec:AddToggle{ Name = "Example", Default = true, Flag = "Example", Callback = print }
    Window:AddSettingsTab()   -- call LAST (builds settings + loads configs/autoload)
]]

local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")
local Stats        = game:GetService("Stats")

local rgb = Color3.fromRGB
local Library = {}
Library.__index = Library

Library.Palettes = {
	Default  = { Window = rgb(16,16,20),  Panel = rgb(22,22,27),  Element = rgb(30,30,37),  Border = rgb(40,40,48),  Text = rgb(240,240,246), SubText = rgb(120,120,136) },
	Midnight = { Window = rgb(9,11,21),   Panel = rgb(14,17,31),  Element = rgb(22,26,45),  Border = rgb(32,38,64),  Text = rgb(236,240,255), SubText = rgb(118,127,165) },
	Rose     = { Window = rgb(20,14,17),  Panel = rgb(28,19,23),  Element = rgb(40,27,33),  Border = rgb(58,39,47),  Text = rgb(250,238,242), SubText = rgb(150,118,129) },
	Forest   = { Window = rgb(12,18,15),  Panel = rgb(17,26,21),  Element = rgb(25,38,31),  Border = rgb(36,54,44),  Text = rgb(236,248,240), SubText = rgb(114,145,127) },
	Light    = { Window = rgb(236,237,241), Panel = rgb(248,248,251), Element = rgb(228,229,235), Border = rgb(206,208,218), Text = rgb(28,28,36), SubText = rgb(110,112,128) },
}

------------------------------------------------------------------ helpers
local function New(class, props, kids)
	local o = Instance.new(class)
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
	return New("UIStroke", { Color = c or rgb(40,40,48), Thickness = t or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p })
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

------------------------------------------------------------------ core
function Library.new(o)
	o = o or {}
	local self = setmetatable({}, Library)
	self.Title = o.Title or "Menu"
	self.User = o.User or {}
	self.Theme = { Accent = o.Accent or rgb(111,130,214), Hover = rgb(52,54,62) }
	for k, v in pairs(Library.Palettes.Default) do self.Theme[k] = v end
	self.Palette = "Default"
	self._binds, self.Flags, self._setters = {}, {}, {}
	self.Tabs, self.Keybinds, self.Configs = {}, {}, {}
	self.AnimSpeed = 1
	self.MenuKey = Enum.KeyCode.Insert
	self.TabAnimation = "Fade"
	self.Notifications = { Enabled = true, Position = "Top left" }
	self.Cursor = { Mode = "Always", Style = "Arrow", Size = 100, Effects = true, CustomEnabled = false, Color = rgb(70,160,255) }
	self.UnlockMouse = true
	self.ConfigName = "Main"
	self.Folder = o.Folder or (self.Title:gsub("[^%w]", "") .. "Configs")
	self._conns = {}

	local parent = o.Parent or GuiParent()
	self.Gui = New("ScreenGui", { Name = self.Title, ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = parent })

	self.Root = New("Frame", { Size = UDim2.fromOffset(750, 445), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5),
		BorderSizePixel = 0, ClipsDescendants = true, Parent = self.Gui })
	Round(self.Root, 8)
	self:Themed(self.Root, { BackgroundColor3 = "Window" })
	self:Themed(Stroke(self.Root), { Color = "Border" })
	self.Scale = New("UIScale", { Parent = self.Root })

	self.Content = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,1,-56), Parent = self.Root })
	self.Bar = New("Frame", { Position = UDim2.new(0,0,1,-56), Size = UDim2.new(1,0,0,56), BorderSizePixel = 0, Parent = self.Root })
	self:Themed(self.Bar, { BackgroundColor3 = "Window" })
	local line = New("Frame", { Size = UDim2.new(1,0,0,1), BorderSizePixel = 0, Parent = self.Bar })
	self:Themed(line, { BackgroundColor3 = "Border" })

	-- drag zone (behind the bar controls)
	local drag = New("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1,1), ZIndex = 1, Parent = self.Bar })
	drag.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			local start, sp = i.Position, self.Root.Position
			self._activeDrag = function(pos)
				local d = pos - start
				self.Root.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
			end
		end
	end)

	-- overlay (popups) + blocker
	self.Blocker = New("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1,1), Visible = false, ZIndex = 90, Parent = self.Gui })
	self.Blocker.MouseButton1Click:Connect(function() self:ClosePopup() end)
	self.Overlay = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(), ZIndex = 100, Parent = self.Gui })
	self.OverlayScale = New("UIScale", { Parent = self.Overlay })

	self:_buildBar()
	self:_buildNotifHolder()
	self:_buildWatermark()
	self:_buildKeybindList()
	self:_buildCursor()

	self.ModalButton = New("TextButton", { BackgroundTransparency = 1, Text = "", Modal = true, Size = UDim2.new(), Parent = self.Gui })

	-- global input
	table.insert(self._conns, UIS.InputChanged:Connect(function(i)
		if self._activeDrag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			self._activeDrag(Vector2.new(i.Position.X, i.Position.Y))
		end
	end))
	table.insert(self._conns, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then self._activeDrag = nil end
	end))
	table.insert(self._conns, UIS.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 and self.Cursor.Effects and self.CursorHolder.Visible then
			self:_ripple()
		end
		if self._listening or UIS:GetFocusedTextBox() then return end
		if KeyMatches(self.MenuKey, i) then self:Toggle() return end
		for _, kb in ipairs(self.Keybinds) do
			if kb.Callback and KeyMatches(kb.Key, i) then task.spawn(kb.Callback, kb.Key) end
		end
	end))
	local fps, frames, last = 0, 0, os.clock()
	table.insert(self._conns, RunService.RenderStepped:Connect(function()
		frames += 1
		if os.clock() - last >= 1 then fps, frames, last = frames, 0, os.clock(); self:_updateWatermark(fps) end
		self:_stepCursor()
	end))
	pcall(function()
		RunService:BindToRenderStep("UILibUnlock" .. self.Title, Enum.RenderPriority.Last.Value, function()
			local open = self.Root.Visible and self.UnlockMouse
			self.ModalButton.Modal = open
			if open then UIS.MouseBehavior = Enum.MouseBehavior.Default end
		end)
	end)

	self:Refresh()
	return self
end

function Library:Bind(fn) table.insert(self._binds, fn); pcall(fn); return fn end
function Library:Themed(obj, map)
	self:Bind(function() for p, k in pairs(map) do obj[p] = self.Theme[k] end end)
	return obj
end
function Library:Refresh() for _, f in ipairs(self._binds) do pcall(f) end end
function Library:Tween(obj, props, t, style)
	local tw = TweenService:Create(obj, TweenInfo.new((t or .15) / math.max(self.AnimSpeed, .1), style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end
function Library:Label(parent, text, p)
	p = p or {}
	local l = New("TextLabel", { BackgroundTransparency = 1, Text = text, TextSize = p.Size or 13, TextXAlignment = p.AlignRight and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
		Font = p.Bold and Enum.Font.GothamBold or Enum.Font.GothamMedium, Position = p.Position, Size = p.Size2 or p.SizeUDim or UDim2.new(1,0,1,0),
		TextTruncate = Enum.TextTruncate.AtEnd, Parent = parent })
	if p.SizeUDim then l.Size = p.SizeUDim end
	local ref = { k = p.Color or "Text" }
	self:Bind(function() l.TextColor3 = self.Theme[ref.k] end)
	return l, ref
end
function Library:_hover(btn, stroke)
	btn.MouseEnter:Connect(function() stroke.Color = self.Theme.Hover end)
	btn.MouseLeave:Connect(function() stroke.Color = self.Theme.Border end)
	self:Bind(function() stroke.Color = self.Theme.Border end)
end
function Library:SetAccent(c) self.Theme.Accent = c; self:Refresh() end
function Library:SetHover(c) self.Theme.Hover = c; self:Refresh() end
function Library:SetPalette(name)
	local p = Library.Palettes[name]; if not p then return end
	self.Palette = name
	for k, v in pairs(p) do self.Theme[k] = v end
	self:Refresh()
end
function Library:Toggle(state)
	if state == nil then state = not self.Root.Visible end
	self.Root.Visible = state
	if not state then self:ClosePopup() end
end
function Library:Destroy()
	for _, c in ipairs(self._conns) do c:Disconnect() end
	pcall(function() RunService:UnbindFromRenderStep("UILibUnlock" .. self.Title) end)
	UIS.MouseIconEnabled = true
	self.Gui:Destroy(); self.CursorGui:Destroy()
end

------------------------------------------------------------------ popups
function Library:ClosePopup()
	if self._popup then self._popup:Destroy(); self._popup = nil; self._popupOwner = nil end
	self.Blocker.Visible = false
end
function Library:_openPopup(owner, size, anchor, up)
	self:ClosePopup()
	local s = self.Scale.Scale
	self.OverlayScale.Scale = s
	local a, sz = anchor.AbsolutePosition, anchor.AbsoluteSize
	local y = (a.Y + sz.Y) / s + 4
	if up or (a.Y + sz.Y + 4 + size.Y * s) > self.Gui.AbsoluteSize.Y then y = a.Y / s - size.Y - 4 end
	local x = math.clamp(a.X / s, 4, math.max(4, self.Gui.AbsoluteSize.X / s - size.X - 4))
	local f = New("Frame", { Size = UDim2.fromOffset(size.X, size.Y), Position = UDim2.fromOffset(x, y), BorderSizePixel = 0, Parent = self.Overlay })
	Round(f, 6)
	self:Themed(f, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(f), { Color = "Border" })
	self._popup, self._popupOwner = f, owner
	self.Blocker.Visible = true
	return f
end
function Library:_popupList(anchor, options, current, onPick, up)
	local itemH, n = 24, #options
	local h = math.min(n, 6) * itemH + 8
	local f = self:_openPopup(anchor, Vector2.new(anchor.AbsoluteSize.X / self.Scale.Scale, h), anchor, up)
	local sc = New("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1,-8,1,-8), Position = UDim2.fromOffset(4,4),
		ScrollBarThickness = 2, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = f })
	New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = sc })
	for i, opt in ipairs(options) do
		local b = New("TextButton", { LayoutOrder = i, Size = UDim2.new(1,0,0,itemH), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = sc })
		local l, ref = self:Label(b, tostring(opt), { Position = UDim2.fromOffset(8,0), Color = opt == current and "Text" or "SubText" })
		if opt == current then self:Bind(function() l.TextColor3 = self.Theme.Accent end) end
		b.MouseEnter:Connect(function() l.TextColor3 = self.Theme.Text end)
		b.MouseLeave:Connect(function() l.TextColor3 = opt == current and self.Theme.Accent or self.Theme.SubText end)
		b.MouseButton1Click:Connect(function() self:ClosePopup(); onPick(opt) end)
	end
end

------------------------------------------------------------------ bottom bar
function Library:_buildBar()
	local bar = self.Bar
	-- profile (left)
	local prof = New("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromOffset(190, 44), Position = UDim2.fromOffset(8, 8), ZIndex = 3, Parent = bar })
	local av = New("Frame", { Size = UDim2.fromOffset(34,34), Position = UDim2.fromOffset(6,5), BorderSizePixel = 0, ZIndex = 3, Parent = prof })
	Round(av, 17)
	self:Bind(function() av.BackgroundColor3 = self.Theme.Accent end)
	local name = self.User.Name or (Players.LocalPlayer and Players.LocalPlayer.DisplayName) or "User"
	local tag = self.User.Tag or (Players.LocalPlayer and "@" .. Players.LocalPlayer.Name) or ""
	local initial = New("TextLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), Text = name:sub(1,1):upper(), Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = Color3.new(1,1,1), ZIndex = 4, Parent = av })
	local img = New("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1,1), ZIndex = 5, Image = "", Parent = av })
	Round(img, 17)
	local avatar = self.User.Avatar
	task.spawn(function()
		local ok, res = pcall(function()
			if type(avatar) == "string" then return avatar end
			local id = type(avatar) == "number" and avatar or (Players.LocalPlayer and Players.LocalPlayer.UserId)
			return (Players:GetUserThumbnailAsync(id, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100))
		end)
		if ok and res then img.Image = res; initial.Visible = false end
	end)
	self.ProfileNameLabel = self:Label(prof, name, { Bold = true, Size = 14, Position = UDim2.fromOffset(48,6), SizeUDim = UDim2.new(1,-52,0,16) })
	self.ProfileTagLabel = self:Label(prof, tag, { Size = 11, Color = "SubText", Position = UDim2.fromOffset(48,23), SizeUDim = UDim2.new(1,-52,0,14) })
	prof.MouseButton1Click:Connect(function()
		if self._popupOwner == prof then self:ClosePopup() return end
		self:_profilePopup(prof, name, tag, img.Image)
		if self.User.OnClick then task.spawn(self.User.OnClick, self) end
	end)
	self.ProfileButton = prof

	-- tabs (center)
	self.TabHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,-440,1,0), Position = UDim2.fromOffset(220,0), ZIndex = 2, Parent = bar })
	New("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = self.TabHolder })

	-- collapse chevron (top center)
	local col = New("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromOffset(30,12), AnchorPoint = Vector2.new(.5,0), Position = UDim2.new(.5,0,0,-12), ZIndex = 3, Parent = bar })
	local chev = Chevron(col, UDim2.fromScale(.5,.5)); chev.Rotation = 180
	self._collapsed = false
	col.MouseButton1Click:Connect(function()
		self._collapsed = not self._collapsed
		self:ClosePopup()
		local s = self.Scale.Scale
		local h = self._collapsed and 56 or 445
		self.Content.Visible = not self._collapsed
		chev.Rotation = self._collapsed and 0 or 180
		self:Tween(self.Root, { Size = UDim2.fromOffset(750, h) }, .2)
	end)
	col.Position = UDim2.new(.5,0,0,0)

	-- config dropdown (right)
	local cb = New("TextButton", { Size = UDim2.fromOffset(130,34), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-14,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, ZIndex = 3, Parent = bar })
	Round(cb, 6)
	self:Themed(cb, { BackgroundColor3 = "Element" })
	local st = Stroke(cb); self:_hover(cb, st)
	self.ConfigLabel = self:Label(cb, self.ConfigName, { Bold = true, Position = UDim2.fromOffset(14,0), SizeUDim = UDim2.new(1,-40,1,0) })
	Chevron(cb, UDim2.new(1,-16,.5,0))
	cb.MouseButton1Click:Connect(function()
		if self._popupOwner == cb then self:ClosePopup() return end
		local names = {}
		for n in pairs(self.Configs) do table.insert(names, n) end
		table.sort(names)
		if #names == 0 then names = { "Main" } end
		self:_popupList(cb, names, self.ConfigName, function(n) self:LoadConfig(n) end, true)
		self._popupOwner = cb
	end)
end

function Library:_profilePopup(anchor, name, tag, image)
	local f = self:_openPopup(anchor, Vector2.new(210, 120 + #(self.User.Buttons or {}) * 32), anchor, true)
	self._popupOwner = anchor
	local av = New("ImageLabel", { Size = UDim2.fromOffset(52,52), Position = UDim2.fromOffset(12,12), Image = image, BorderSizePixel = 0, Parent = f })
	Round(av, 26)
	self:Bind(function() av.BackgroundColor3 = self.Theme.Accent end)
	self:Label(f, name, { Bold = true, Size = 15, Position = UDim2.fromOffset(74,18), SizeUDim = UDim2.new(1,-84,0,18) })
	self:Label(f, tag, { Color = "SubText", Size = 12, Position = UDim2.fromOffset(74,38), SizeUDim = UDim2.new(1,-84,0,16) })
	local y = 76
	local btns = self.User.Buttons or {}
	if #btns == 0 then
		btns = { { Text = "Copy tag", Callback = function() if typeof(setclipboard) == "function" then setclipboard(tag) end self:Notify{ Title = "Copied", Text = tag } end } }
	end
	f.Size = UDim2.fromOffset(210, 80 + #btns * 32 + 8)
	for _, bt in ipairs(btns) do
		local b = New("TextButton", { Size = UDim2.new(1,-24,0,26), Position = UDim2.fromOffset(12,y), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = f })
		Round(b, 5); self:Themed(b, { BackgroundColor3 = "Element" })
		local st = Stroke(b); self:_hover(b, st)
		local l = self:Label(b, bt.Text, { Position = UDim2.new(), SizeUDim = UDim2.fromScale(1,1) }); l.TextXAlignment = Enum.TextXAlignment.Center
		b.MouseButton1Click:Connect(function() self:ClosePopup(); if bt.Callback then task.spawn(bt.Callback) end end)
		y += 32
	end
	local s = self.Scale.Scale
	f.Position = UDim2.fromOffset(f.Position.X.Offset, anchor.AbsolutePosition.Y / s - f.Size.Y.Offset - 6)
end

------------------------------------------------------------------ tabs
function Library:_paintTabs()
	for _, t in ipairs(self.Tabs) do
		local sel = (self.CurrentTab == t)
		self:Tween(t.Button, { BackgroundTransparency = sel and 0 or 1 }, .12)
		t.Stroke.Transparency = sel and 0 or 1
		local c = sel and self.Theme.Text or self.Theme.SubText
		if t.Icon then t.Icon.ImageColor3 = c end
		if t.GlyphLabel then t.GlyphLabel.TextColor3 = c end
	end
end

function Library:AddTab(o)
	local tab = { Name = o.Name or "Tab", Win = self, Sections = {} }
	local b = New("TextButton", { Size = UDim2.fromOffset(36,36), Text = "", AutoButtonColor = false, BorderSizePixel = 0, BackgroundTransparency = 1, LayoutOrder = #self.Tabs + 1, ZIndex = 3, Parent = self.TabHolder })
	Round(b, 7)
	self:Themed(b, { BackgroundColor3 = "Element" })
	tab.Stroke = Stroke(b); tab.Stroke.Transparency = 1
	self:Themed(tab.Stroke, { Color = "Border" })
	tab.Button = b
	if o.Icon then
		tab.Icon = New("ImageLabel", { BackgroundTransparency = 1, Image = o.Icon, Size = UDim2.fromOffset(18,18), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(.5,.5), ZIndex = 4, Parent = b })
	else
		tab.GlyphLabel = New("TextLabel", { BackgroundTransparency = 1, Text = o.Glyph or tab.Name:sub(1,1):upper(), Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.fromScale(1,1), ZIndex = 4, Parent = b })
	end
	-- tooltip
	b.MouseEnter:Connect(function()
		if self._popup then return end
		local s = self.Scale.Scale
		self.OverlayScale.Scale = s
		local tip = New("TextLabel", { Name = "Tip", AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0,22), BorderSizePixel = 0, Text = "  " .. tab.Name .. "  ",
			Font = Enum.Font.GothamMedium, TextSize = 12, AnchorPoint = Vector2.new(.5,1),
			Position = UDim2.fromOffset((b.AbsolutePosition.X + b.AbsoluteSize.X / 2) / s, b.AbsolutePosition.Y / s - 6), Parent = self.Overlay })
		Round(tip, 5)
		self:Themed(tip, { BackgroundColor3 = "Panel", TextColor3 = "Text" })
		self:Themed(Stroke(tip), { Color = "Border" })
		tab._tip = tip
	end)
	b.MouseLeave:Connect(function() if tab._tip then tab._tip:Destroy(); tab._tip = nil end end)

	-- page
	local page = New("CanvasGroup", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, Visible = false, Parent = self.Content })
	local sc = New("ScrollingFrame", { Size = UDim2.fromScale(1,1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = page })
	self:Bind(function() sc.ScrollBarImageColor3 = self.Theme.Border end)
	New("UIPadding", { PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,12), PaddingTop = UDim.new(0,10), PaddingBottom = UDim.new(0,10), Parent = sc })
	local inner = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, Parent = sc })
	New("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = inner })
	tab.Columns = {}
	for i, side in ipairs({ "Left", "Right" }) do
		local col = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(.5,-5,0,0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Parent = inner })
		New("UIListLayout", { Padding = UDim.new(0,10), SortOrder = Enum.SortOrder.LayoutOrder, Parent = col })
		tab.Columns[side] = col
	end
	tab.Page = page
	b.MouseButton1Click:Connect(function() self:SelectTab(tab) end)

	function tab:AddSection(so)
		so = so or {}
		local col = self.Columns[so.Side or (#self.Sections % 2 == 0 and "Left" or "Right")]
		local sec = setmetatable({ Win = self.Win, Tab = self, _n = 0 }, { __index = Library.Section })
		sec.Frame = New("Frame", { Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, LayoutOrder = #self.Sections + 1, Parent = col })
		Round(sec.Frame, 8)
		self.Win:Themed(sec.Frame, { BackgroundColor3 = "Panel" })
		self.Win:Themed(Stroke(sec.Frame), { Color = "Border" })
		New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Parent = sec.Frame })
		if so.Title then
			local r = sec:_row(30)
			self.Win:Label(r, so.Title, { Bold = true, Position = UDim2.fromOffset(12,0), SizeUDim = UDim2.new(1,-24,1,0) })
		end
		table.insert(self.Sections, sec)
		return sec
	end

	table.insert(self.Tabs, tab)
	self:Bind(function() self:_paintTabs() end)
	if not self.CurrentTab then self:SelectTab(tab) end
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
		pg.GroupTransparency, pg.Position = 0, UDim2.new()
	elseif mode == "Slide" then
		pg.GroupTransparency, pg.Position = 1, UDim2.fromOffset(0, 18)
		self:Tween(pg, { GroupTransparency = 0, Position = UDim2.new() }, .25)
	else
		pg.GroupTransparency, pg.Position = 1, UDim2.new()
		self:Tween(pg, { GroupTransparency = 0 }, .2)
	end
	self:_paintTabs()
end

------------------------------------------------------------------ sections / elements
local Section = {}
Library.Section = Section

function Section:_row(h)
	self._n += 1
	local r = New("Frame", { Size = UDim2.new(1,0,0,h), BackgroundTransparency = 1, LayoutOrder = self._n, Parent = self.Frame })
	if self._n > 1 then
		local l = New("Frame", { Size = UDim2.new(1,0,0,1), BorderSizePixel = 0, Parent = r })
		self.Win:Themed(l, { BackgroundColor3 = "Border" })
	end
	return r
end

function Section:_register(o, obj)
	if o.Flag then
		self.Win.Flags[o.Flag] = obj:Get()
		if not o.NoSave then self.Win._setters[o.Flag] = function(v) obj:Set(v) end else self.Win._setters[o.Flag] = nil end
	end
end

function Section:AddToggle(o)
	local win, row = self.Win, self:_row(34)
	local lbl, ref = win:Label(row, o.Name, { Bold = o.Bold, Color = o.Bold and "Text" or "SubText", Position = UDim2.fromOffset(12,0), SizeUDim = UDim2.new(1,-50,1,0) })
	local box = New("TextButton", { Size = UDim2.fromOffset(18,18), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-12,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(box, 4)
	local st = Stroke(box); win:_hover(box, st)
	local obj = { Value = o.Default or false }
	local function paint()
		box.BackgroundColor3 = obj.Value and win.Theme.Accent or win.Theme.Element
		ref.k = (o.Bold or obj.Value) and "Text" or "SubText"
		lbl.TextColor3 = win.Theme[ref.k]
	end
	win:Bind(paint)
	function obj:Set(v, silent)
		self.Value = v and true or false
		if o.Flag then win.Flags[o.Flag] = self.Value end
		paint()
		if o.Callback and not silent then task.spawn(o.Callback, self.Value) end
	end
	function obj:Get() return self.Value end
	box.MouseButton1Click:Connect(function() obj:Set(not obj.Value) end)
	self:_register(o, obj)
	if o.Callback and obj.Value then task.spawn(o.Callback, true) end
	return obj
end

function Section:AddSlider(o)
	local win, row = self.Win, self:_row(48)
	win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(12,7), SizeUDim = UDim2.new(1,-110,0,16) })
	local val = win:Label(row, "", { AlignRight = true, Position = UDim2.new(1,-112,0,7), SizeUDim = UDim2.fromOffset(100,16) })
	local min, max, dec = o.Min or 0, o.Max or 100, o.Decimals or 0
	local step = o.Step or 10 ^ -dec
	local track = New("Frame", { Position = UDim2.new(0,32,0,35), Size = UDim2.new(1,-64,0,3), BorderSizePixel = 0, Parent = row })
	Round(track, 2); win:Themed(track, { BackgroundColor3 = "Border" })
	local fill = New("Frame", { Size = UDim2.new(0,0,1,0), BorderSizePixel = 0, Parent = track }); Round(fill, 2)
	win:Bind(function() fill.BackgroundColor3 = win.Theme.Accent end)
	local knob = New("Frame", { Size = UDim2.fromOffset(11,11), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(0,.5), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0, ZIndex = 2, Parent = track })
	Round(knob, 6)
	local obj = { Value = o.Default or min }
	function obj:Set(v, silent)
		v = math.clamp(math.floor(v / step + .5) * step, min, max)
		self.Value = v
		local p = (max == min) and 0 or (v - min) / (max - min)
		fill.Size = UDim2.new(p, 0, 1, 0)
		knob.Position = UDim2.new(p, 0, .5, 0)
		val.Text = string.format("( %." .. dec .. "f%s )", v, o.Suffix or "")
		if o.Flag then win.Flags[o.Flag] = v end
		if o.Callback and not silent then task.spawn(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	local hit = New("TextButton", { BackgroundTransparency = 1, Text = "", Position = UDim2.new(0,26,0,27), Size = UDim2.new(1,-52,0,18), Parent = row })
	local function fromPos(pos) obj:Set(min + math.clamp((pos.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1) * (max - min)) end
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			win._activeDrag = fromPos
			fromPos(i.Position)
		end
	end)
	for i, sym in ipairs({ "<", ">" }) do
		local a = New("TextButton", { BackgroundTransparency = 1, Text = sym, Font = Enum.Font.GothamBold, TextSize = 11, Size = UDim2.fromOffset(16,16),
			Position = i == 1 and UDim2.fromOffset(8,29) or UDim2.new(1,-24,0,29), Parent = row })
		win:Bind(function() a.TextColor3 = win.Theme.SubText end)
		a.MouseButton1Click:Connect(function() obj:Set(obj.Value + (i == 1 and -step or step)) end)
	end
	obj:Set(obj.Value, true)
	self:_register(o, obj)
	if o.Callback then task.spawn(o.Callback, obj.Value) end
	return obj
end

function Section:AddDropdown(o)
	local win, row = self.Win, self:_row(60)
	win:Label(row, o.Name, { Bold = true, Position = UDim2.fromOffset(12,7), SizeUDim = UDim2.new(1,-24,0,16) })
	local box = New("TextButton", { Position = UDim2.fromOffset(12,28), Size = UDim2.new(1,-24,0,26), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(box, 5); win:Themed(box, { BackgroundColor3 = "Element" })
	local st = Stroke(box); win:_hover(box, st)
	local txt = win:Label(box, "", { Position = UDim2.fromOffset(10,0), SizeUDim = UDim2.new(1,-30,1,0) })
	Chevron(box, UDim2.new(1,-16,.5,0))
	local obj = { Options = o.Options or {}, Value = o.Default or (o.Options or {})[1] }
	function obj:Set(v, silent)
		self.Value = v; txt.Text = tostring(v)
		if o.Flag then win.Flags[o.Flag] = v end
		if o.Callback and not silent then task.spawn(o.Callback, v) end
	end
	function obj:Get() return self.Value end
	function obj:SetOptions(list) self.Options = list end
	box.MouseButton1Click:Connect(function()
		if win._popupOwner == box then win:ClosePopup() return end
		win:_popupList(box, obj.Options, obj.Value, function(v) obj:Set(v) end)
		win._popupOwner = box
	end)
	obj:Set(obj.Value, true)
	self:_register(o, obj)
	if o.Callback then task.spawn(o.Callback, obj.Value) end
	return obj
end

function Section:AddKeybind(o)
	local win, row = self.Win, self:_row(34)
	win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(12,0), SizeUDim = UDim2.new(1,-100,1,0) })
	local btn = New("TextButton", { AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-12,.5,0), Size = UDim2.fromOffset(60,22), AutomaticSize = Enum.AutomaticSize.X,
		Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(btn, 5); win:Themed(btn, { BackgroundColor3 = "Element" })
	local st = Stroke(btn); win:_hover(btn, st)
	New("UIPadding", { PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,10), Parent = btn })
	local txt = win:Label(btn, "", { Position = UDim2.new(), SizeUDim = UDim2.fromScale(1,1) })
	txt.AutomaticSize = Enum.AutomaticSize.X; txt.Size = UDim2.new(0,0,1,0); txt.TextXAlignment = Enum.TextXAlignment.Center
	local obj = { Key = o.Default }
	local entry = { Name = o.Name, Key = obj.Key, Callback = o.Callback }
	if not o.Hidden then table.insert(win.Keybinds, entry) end
	function obj:Set(k, silent)
		self.Key = k; entry.Key = k
		txt.Text = k and k.Name or "None"
		if o.Flag then win.Flags[o.Flag] = k end
		if o.OnChanged and not silent then task.spawn(o.OnChanged, k) end
		win:_updateKeybindList()
	end
	function obj:Get() return self.Key end
	btn.MouseButton1Click:Connect(function()
		if win._listening then return end
		win._listening = true; txt.Text = "..."
		local c; c = UIS.InputBegan:Connect(function(i)
			local k
			if i.UserInputType == Enum.UserInputType.Keyboard then
				k = (i.KeyCode ~= Enum.KeyCode.Escape) and i.KeyCode or nil
			elseif i.UserInputType == Enum.UserInputType.MouseButton2 or i.UserInputType == Enum.UserInputType.MouseButton3 then
				k = i.UserInputType
			else return end
			c:Disconnect()
			task.defer(function() win._listening = false end)
			obj:Set(k)
		end)
	end)
	obj:Set(obj.Key, true)
	self:_register(o, obj)
	return obj
end

function Section:AddColorPicker(o)
	local win, row = self.Win, self:_row(34)
	win:Label(row, o.Name, { Color = "SubText", Position = UDim2.fromOffset(12,0), SizeUDim = UDim2.new(1,-90,1,0) })
	local obj = { Color = o.Default or Color3.new(1,1,1), Enabled = o.DefaultEnabled or false }
	local hue, sat, val = obj.Color:ToHSV()
	local right = 12
	local check
	if o.Toggle then
		check = New("TextButton", { Size = UDim2.fromOffset(18,18), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-12,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
		Round(check, 4); local cs = Stroke(check); win:_hover(check, cs)
		right = 38
	end
	local sw = New("TextButton", { Size = UDim2.fromOffset(12,12), AnchorPoint = Vector2.new(1,.5), Position = UDim2.new(1,-right,.5,0), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(sw, 6)
	local function fire() if o.Callback then task.spawn(o.Callback, obj.Color, obj.Enabled) end end
	local function paint()
		sw.BackgroundColor3 = obj.Color
		if check then check.BackgroundColor3 = obj.Enabled and win.Theme.Accent or win.Theme.Element end
	end
	win:Bind(paint)
	function obj:Set(c, silent)
		if typeof(c) ~= "Color3" then return end
		self.Color = c; hue, sat, val = c:ToHSV()
		if o.Flag then win.Flags[o.Flag] = c end
		paint()
		if not silent then fire() end
	end
	function obj:SetEnabled(b, silent)
		self.Enabled = b
		if o.Flag and o.Toggle then win.Flags[o.Flag .. "_On"] = b end
		paint()
		if not silent then fire() end
	end
	function obj:Get() return self.Color end
	if check then
		check.MouseButton1Click:Connect(function() obj:SetEnabled(not obj.Enabled) end)
		if o.Flag then win._setters[o.Flag .. "_On"] = function(v) obj:SetEnabled(v) end; win.Flags[o.Flag .. "_On"] = obj.Enabled end
	end
	sw.MouseButton1Click:Connect(function()
		if win._popupOwner == sw then win:ClosePopup() return end
		local f = win:_openPopup(sw, Vector2.new(180, 168), sw)
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
		for i = 0, 6 do table.insert(seq, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV(i / 6 == 1 and .999 or i / 6, 1, 1))) end
		New("UIGradient", { Color = ColorSequence.new(seq), Parent = hb })
		local hcur = New("Frame", { Size = UDim2.fromOffset(4,16), AnchorPoint = Vector2.new(.5,.5), Position = UDim2.fromScale(0,.5), BackgroundColor3 = Color3.new(1,1,1), BorderSizePixel = 0, Parent = hb })
		Round(hcur, 2); Stroke(hcur, Color3.new(0,0,0), 1)
		local hex = win:Label(f, "", { Position = UDim2.fromOffset(8,144), SizeUDim = UDim2.new(1,-16,0,18), Color = "SubText", Size = 12 })
		local function redraw()
			svBox.BackgroundColor3 = Color3.fromHSV(hue, 1, 1)
			cur.Position = UDim2.fromScale(sat, 1 - val)
			hcur.Position = UDim2.fromScale(hue, .5)
			hex.Text = "#" .. obj.Color:ToHex():upper()
		end
		local function apply() obj:Set(Color3.fromHSV(hue, sat, val)); redraw() end
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

function Section:AddTextBox(o)
	local win, row = self.Win, self:_row(40)
	local tb = New("TextBox", { Position = UDim2.fromOffset(12,7), Size = UDim2.new(1,-24,0,26), Text = o.Default or "", PlaceholderText = o.Placeholder or o.Name or "",
		ClearTextOnFocus = false, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, BorderSizePixel = 0, Parent = row })
	Round(tb, 5); New("UIPadding", { PaddingLeft = UDim.new(0,10), Parent = tb })
	win:Themed(tb, { BackgroundColor3 = "Element", TextColor3 = "Text", PlaceholderColor3 = "SubText" })
	local st = Stroke(tb); win:_hover(tb, st)
	local obj = {}
	function obj:Get() return tb.Text end
	function obj:Set(v, silent) tb.Text = v; if o.Flag then win.Flags[o.Flag] = v end if o.Callback and not silent then task.spawn(o.Callback, v) end end
	tb.FocusLost:Connect(function(enter) obj:Set(tb.Text) end)
	self:_register(o, obj)
	obj.Box = tb
	return obj
end

function Section:AddButton(o)
	local win, row = self.Win, self:_row(40)
	local b = New("TextButton", { Position = UDim2.fromOffset(12,7), Size = UDim2.new(1,-24,0,26), Text = "", AutoButtonColor = false, BorderSizePixel = 0, Parent = row })
	Round(b, 5); win:Themed(b, { BackgroundColor3 = "Element" })
	local st = Stroke(b); win:_hover(b, st)
	local l = win:Label(b, o.Name, { Position = UDim2.new(), SizeUDim = UDim2.fromScale(1,1) }); l.TextXAlignment = Enum.TextXAlignment.Center
	b.MouseButton1Click:Connect(function()
		win:Tween(b, { Size = UDim2.new(1,-28,0,24), Position = UDim2.fromOffset(14,8) }, .06)
		task.delay(.08, function() win:Tween(b, { Size = UDim2.new(1,-24,0,26), Position = UDim2.fromOffset(12,7) }, .08) end)
		if o.Callback then task.spawn(o.Callback) end
	end)
	return { SetText = function(_, t) l.Text = t end }
end

function Section:AddLabel(text)
	local row = self:_row(30)
	local l = self.Win:Label(row, text, { Color = "SubText", Position = UDim2.fromOffset(12,0), SizeUDim = UDim2.new(1,-24,1,0) })
	return { Set = function(_, t) l.Text = t end }
end

------------------------------------------------------------------ notifications / watermark / keybind list
function Library:_buildNotifHolder()
	self.NotifHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(0,270,1,-24), Parent = self.Gui })
	self.NotifLayout = New("UIListLayout", { Padding = UDim.new(0,8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = self.NotifHolder })
	self:SetNotificationPosition("Top left")
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
function Library:Notify(o)
	if not self.Notifications.Enabled and not o.Force then return end
	self._nid = (self._nid or 0) + 1
	local dur = o.Duration or 4
	local wrap = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1,0,0,54), LayoutOrder = self._nid, Parent = self.NotifHolder })
	local right = self.Notifications.Position:find("right") ~= nil
	local card = New("Frame", { Size = UDim2.fromScale(1,1), Position = UDim2.fromOffset(right and 300 or -300, 0), BorderSizePixel = 0, Parent = wrap })
	Round(card, 7)
	self:Themed(card, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(card), { Color = "Border" })
	self:Label(card, o.Title or "Notification", { Bold = true, Position = UDim2.fromOffset(12,8), SizeUDim = UDim2.new(1,-24,0,16) })
	self:Label(card, o.Text or "", { Color = "SubText", Size = 12, Position = UDim2.fromOffset(12,26), SizeUDim = UDim2.new(1,-24,0,16) })
	local bar = New("Frame", { Position = UDim2.new(0,8,1,-4), Size = UDim2.new(1,-16,0,2), BorderSizePixel = 0, Parent = card })
	self:Bind(function() bar.BackgroundColor3 = self.Theme.Accent end)
	self:Tween(card, { Position = UDim2.new() }, .3, Enum.EasingStyle.Back)
	TweenService:Create(bar, TweenInfo.new(dur, Enum.EasingStyle.Linear), { Size = UDim2.new(0,0,0,2) }):Play()
	task.delay(dur, function()
		self:Tween(card, { Position = UDim2.fromOffset(right and 300 or -300, 0) }, .25)
		task.wait(.3 / math.max(self.AnimSpeed, .1)); wrap:Destroy()
	end)
end

function Library:_buildWatermark()
	local f = New("Frame", { AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0,26), AnchorPoint = Vector2.new(1,0), Position = UDim2.new(1,-12,0,12), BorderSizePixel = 0, Visible = false, Parent = self.Gui })
	Round(f, 6)
	self:Themed(f, { BackgroundColor3 = "Panel" })
	self:Themed(Stroke(f), { Color = "Border" })
	New("UIPadding", { PaddingLeft = UDim.new(0,10), PaddingRight = UDim.new(0,10), Parent = f })
	local l = New("TextLabel", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0,26), Font = Enum.Font.GothamMedium, TextSize = 12, Text = "", Parent = f })
	self:Themed(l, { TextColor3 = "Text" })
	self.Watermark, self.WatermarkLabel = f, l
	self:_updateWatermark(60)
end
function Library:_updateWatermark(fps)
	local ping = 0
	pcall(function() ping = math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue()) end)
	self.WatermarkLabel.Text = string.format("%s  |  %s  |  %d fps  |  %d ms  |  %s", self.Title, self.User.Name or "user", fps or 0, ping, os.date("%H:%M"))
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
		self:Label(r, text, { Bold = bold, Size = 12, Color = bold and "Text" or "SubText", SizeUDim = UDim2.new(1,-50,1,0) })
		if right then self:Label(r, right, { Size = 12, AlignRight = true, SizeUDim = UDim2.new(1,0,1,0) }) end
		table.insert(self._kbRows, r)
	end
	add("Keybinds", nil, true, 0)
	for i, kb in ipairs(self.Keybinds) do if kb.Key then add(kb.Name, "[" .. kb.Key.Name .. "]", false, i) end end
end

------------------------------------------------------------------ cursor
function Library:_buildCursor()
	self.CursorGui = New("ScreenGui", { Name = self.Title .. "Cursor", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 2147483647, Parent = self.Gui.Parent })
	self.CursorHolder = New("Frame", { BackgroundTransparency = 1, Size = UDim2.new(), Visible = false, Parent = self.CursorGui })
	self:_styleCursor()
end
function Library:_styleCursor()
	local h, c = self.CursorHolder, self.Cursor
	h:ClearAllChildren()
	local k = c.Size / 100
	local col = c.CustomEnabled and c.Color or Color3.new(1,1,1)
	if c.Style == "Dot" then
		local d = New("Frame", { Size = UDim2.fromOffset(7*k,7*k), AnchorPoint = Vector2.new(.5,.5), BackgroundColor3 = col, BorderSizePixel = 0, Parent = h }); Round(d, 8); Stroke(d, Color3.new(0,0,0), 1)
	elseif c.Style == "Cross" then
		for _, s in ipairs({ Vector2.new(12*k, 2), Vector2.new(2, 12*k) }) do
			local f = New("Frame", { Size = UDim2.fromOffset(s.X, s.Y), AnchorPoint = Vector2.new(.5,.5), BackgroundColor3 = col, BorderSizePixel = 0, Parent = h }); Stroke(f, Color3.new(0,0,0), 1)
		end
	elseif c.Style == "Circle" then
		local r = New("Frame", { Size = UDim2.fromOffset(16*k,16*k), AnchorPoint = Vector2.new(.5,.5), BackgroundTransparency = 1, Parent = h }); Round(r, 20); Stroke(r, col, 2)
	else
		New("ImageLabel", { BackgroundTransparency = 1, Image = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png", ImageColor3 = col,
			Size = UDim2.fromOffset(32*k, 32*k), Position = UDim2.fromOffset(-5*k, -5*k), Parent = h })
	end
end
function Library:_stepCursor()
	local m = UIS:GetMouseLocation()
	self.CursorHolder.Position = UDim2.fromOffset(m.X, m.Y)
	local mode = self.Cursor.Mode
	local show = mode == "Always" or (mode == "Menu open" and self.Root.Visible)
	self.CursorHolder.Visible = show
	if show then UIS.MouseIconEnabled = false; self._hid = true
	elseif self._hid then UIS.MouseIconEnabled = true; self._hid = false end
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
function Library:_loadFromDisk()
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
end
function Library:SaveConfig(name)
	name = (name and name ~= "") and name or self.ConfigName
	local data = {}
	for k, v in pairs(self.Flags) do if not self._noSave or not self._noSave[k] then data[k] = Encode(v) end end
	self.Configs[name] = data
	self.ConfigName = name; self.ConfigLabel.Text = name
	if HasFS then pcall(function()
		if not isfolder(self.Folder) then makefolder(self.Folder) end
		writefile(self.Folder .. "/" .. name .. ".json", HttpService:JSONEncode(data))
	end) end
	self:Notify{ Title = "Config saved", Text = name }
end
function Library:LoadConfig(name)
	local data = self.Configs[name]
	if not data then return end
	for k, v in pairs(data) do
		local s = self._setters[k]
		if s then pcall(s, Decode(v)) end
	end
	self.ConfigName = name; self.ConfigLabel.Text = name
	self:Notify{ Title = "Config loaded", Text = name }
end
function Library:SetAutoload(name)
	if HasFS then pcall(function() writefile(self.Folder .. "/autoload.txt", name) end) end
	self:Notify{ Title = "Autoload set", Text = name }
end

function Library:Walkthrough()
	task.spawn(function()
		local start = self.CurrentTab
		for _, t in ipairs(self.Tabs) do
			self:SelectTab(t)
			self:Notify{ Title = t.Name, Text = t.Description or ("This is the " .. t.Name .. " tab."), Duration = 2.5, Force = true }
			task.wait(2.6)
		end
		if start then self:SelectTab(start) end
	end)
end

------------------------------------------------------------------ settings tab
function Library:AddSettingsTab(o)
	o = o or {}
	local tab = self:AddTab{ Name = o.Name or "Settings", Icon = o.Icon, Glyph = o.Glyph or "S" }
	tab.Description = "Menu, cursor and config options."
	local L1 = tab:AddSection{ Side = "Left" }
	local L2 = tab:AddSection{ Side = "Left" }
	local L3 = tab:AddSection{ Side = "Left" }
	local R1 = tab:AddSection{ Side = "Right" }
	local R2 = tab:AddSection{ Side = "Right" }
	local R3 = tab:AddSection{ Side = "Right" }
	local R4 = tab:AddSection{ Side = "Right" }

	L1:AddSlider{ Name = "Menu scale", Min = 50, Max = 150, Default = 100, Flag = "MenuScale", Callback = function(v) self.Scale.Scale = v / 100 end }
	L1:AddKeybind{ Name = "Menu key", Default = Enum.KeyCode.Insert, Flag = "MenuKey", Hidden = true, OnChanged = function(k) if k then self.MenuKey = k end end }
	L1:AddSlider{ Name = "Speed of animations", Min = 25, Max = 300, Default = 100, Flag = "AnimSpeed", Callback = function(v) self.AnimSpeed = v / 100 end }

	L2:AddToggle{ Name = "Display notifications", Bold = true, Default = true, Flag = "Notifications", Callback = function(v) self.Notifications.Enabled = v end }
	L2:AddDropdown{ Name = "Notification position", Options = { "Top left", "Top center", "Top right", "Bottom left", "Bottom right" }, Default = "Top left", Flag = "NotifPos", Callback = function(v) self:SetNotificationPosition(v) end }
	L2:AddDropdown{ Name = "Animation of tab change", Options = { "Fade", "Slide", "None" }, Default = "Fade", Flag = "TabAnim", Callback = function(v) self.TabAnimation = v end }

	L3:AddColorPicker{ Name = "Accent color", Default = self.Theme.Accent, Flag = "Accent", Callback = function(c) self:SetAccent(c) end }
	L3:AddColorPicker{ Name = "Border hovered color", Default = self.Theme.Hover, Flag = "HoverColor", Callback = function(c) self:SetHover(c) end }
	L3:AddDropdown{ Name = "Menu palette", Options = { "Default", "Midnight", "Rose", "Forest", "Light" }, Default = "Default", Flag = "Palette", Callback = function(v) self:SetPalette(v) end }

	R1:AddToggle{ Name = "Watermark", Bold = true, Default = true, Flag = "Watermark", Callback = function(v) self.Watermark.Visible = v end }
	R1:AddToggle{ Name = "Keybind list", Default = false, Flag = "KeybindList", Callback = function(v) self.KeybindFrame.Visible = v end }

	R2:AddDropdown{ Name = "Cursor", Options = { "Always", "Menu open", "Never" }, Default = "Always", Flag = "CursorMode", Callback = function(v) self.Cursor.Mode = v end }
	R2:AddDropdown{ Name = "Cursor style", Options = { "Arrow", "Dot", "Cross", "Circle" }, Default = "Arrow", Flag = "CursorStyle", Callback = function(v) self.Cursor.Style = v; self:_styleCursor() end }
	R2:AddSlider{ Name = "Cursor size", Min = 50, Max = 300, Default = 100, Suffix = "%", Flag = "CursorSize", Callback = function(v) self.Cursor.Size = v; self:_styleCursor() end }
	R2:AddToggle{ Name = "Cursor effects", Default = true, Flag = "CursorEffects", Callback = function(v) self.Cursor.Effects = v end }
	R2:AddColorPicker{ Name = "Custom cursor color", Toggle = true, Default = self.Cursor.Color, Flag = "CursorColor", Callback = function(c, en) self.Cursor.Color, self.Cursor.CustomEnabled = c, en; self:_styleCursor() end }
	R2:AddToggle{ Name = "Unlock mouse", Bold = true, Default = true, Flag = "UnlockMouse", Callback = function(v) self.UnlockMouse = v end }

	local nameBox = R3:AddTextBox{ Name = "Config name", Placeholder = "Config name", NoSave = true }
	R3:AddButton{ Name = "Save", Callback = function() self:SaveConfig(nameBox:Get() ~= "" and nameBox:Get() or self.ConfigName) end }
	R3:AddButton{ Name = "Autoload", Callback = function() self:SetAutoload(self.ConfigName) end }
	R4:AddButton{ Name = "Replay walkthrough", Callback = function() self:Walkthrough() end }

	self._noSave = { ConfigName = true }
	self:_loadFromDisk()
	if HasFS then pcall(function()
		local p = self.Folder .. "/autoload.txt"
		if isfile(p) then
			local n = readfile(p)
			if self.Configs[n] then self:LoadConfig(n) end
		end
	end) end
	return tab
end

return Library
