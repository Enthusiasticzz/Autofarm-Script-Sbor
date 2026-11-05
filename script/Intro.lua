-- GILDED ARCHIVE - CINEMATIC INTRO (v4 cinematic transitions)
-- Refined from the original. Progress is cinematic timing, not asset loading.
-- Init.lua loads the menu concurrently; gameplay stays parked until cleanup.
-- No external images, asset IDs, or modules are needed.

return {
Name = "Intro",
Start = function(Context)
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local rng = Random.new()
local gui, blur
local running = true
local cleaned = false
local topbarWasEnabled = true
pcall(function()
	topbarWasEnabled = StarterGui:GetCore("TopbarEnabled")
end)

local function cleanup()
	if cleaned then return end
	cleaned = true
	running = false
	if gui then gui:Destroy() end
	if blur then blur:Destroy() end
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", topbarWasEnabled)
	end)
end

if Context and Context.Lifetime then
	Context.Lifetime.OnEnd(cleanup)
end
if Context and Context.Startup then
	Context.Startup.CancelIntro = cleanup
end

local function play()
if Context and Context.Lifetime and not Context.Lifetime.Alive then return end

-- SETTINGS
local INTRO_HOLD_AFTER_LOAD = 0.45
local BAR_FILL_DURATION = 5.5
local BLUR_AMOUNT = 6
local SCENE_IN_SECONDS = 1.35
local TITLE_IN_SECONDS = 1.55
local TITLE_STAGGER = 0.18
local SCENE_OUT_SECONDS = 1.4

-- Remove previous test copies.
local oldGui = playerGui:FindFirstChild("GildedArchiveIntro")
if oldGui then oldGui:Destroy() end

local oldBlur = Lighting:FindFirstChild("GildedArchiveBlur")
if oldBlur then oldBlur:Destroy() end

pcall(function()
	StarterGui:SetCore("TopbarEnabled", false)
end)

gui = Instance.new("ScreenGui")
gui.Name = "GildedArchiveIntro"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 2147483647
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui
if Context and Context.Startup and Context.Startup.AttachIntro then
	Context.Startup.AttachIntro(gui)
end

-- CanvasGroup lets the entire composition fade together without separate
-- elements popping out of sync.
local scene = Instance.new("CanvasGroup")
scene.Name = "Scene"
scene.Size = UDim2.fromScale(1, 1)
scene.BackgroundColor3 = Color3.fromRGB(12, 10, 7)
scene.BackgroundTransparency = 0
scene.GroupTransparency = 1
scene.BorderSizePixel = 0
scene.Parent = gui

local background = Instance.new("Frame")
background.Name = "Background"
background.Size = UDim2.fromScale(1, 1)
background.BackgroundColor3 = Color3.fromRGB(12, 10, 7)
background.BorderSizePixel = 0
background.Parent = scene

-- Warm, low-contrast base lighting.
local baseTint = Instance.new("Frame")
baseTint.Name = "WarmTint"
baseTint.Size = UDim2.fromScale(1, 1)
baseTint.BackgroundColor3 = Color3.fromRGB(45, 28, 10)
baseTint.BackgroundTransparency = 0.76
baseTint.BorderSizePixel = 0
baseTint.ZIndex = 1
baseTint.Parent = background

local tintGradient = Instance.new("UIGradient")
tintGradient.Rotation = 90
tintGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(72, 47, 20)),
	ColorSequenceKeypoint.new(0.48, Color3.fromRGB(12, 10, 7)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(73, 45, 17))
})
tintGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.32),
	NumberSequenceKeypoint.new(0.5, 0.91),
	NumberSequenceKeypoint.new(1, 0.30)
})
tintGradient.Parent = baseTint

-- Smooth 2D haze: narrow columns each carry a continuous vertical gradient.
-- No concentric disks or hard circular boundaries. Build once, not every frame.
local function fitScale()
	local size = scene.AbsoluteSize
	return math.max(0.01, math.min(size.X / 1672, size.Y / 941))
end

local glowLayer = Instance.new("Frame")
glowLayer.Name = "GradientHaze"
glowLayer.Size = UDim2.fromScale(1, 1)
glowLayer.BackgroundTransparency = 1
glowLayer.ZIndex = 2
glowLayer.Parent = background

local pools = {
	{x = -0.035, y = -0.08, sx = 0.22, sy = 0.39, strength = 0.24},
	{x = 1.035, y = -0.08, sx = 0.23, sy = 0.40, strength = 0.23},
	{x = -0.015, y = 1.07, sx = 0.24, sy = 0.40, strength = 0.35},
	{x = 1.025, y = 1.07, sx = 0.24, sy = 0.40, strength = 0.34},
	{x = 0.50, y = 0.46, sx = 0.23, sy = 0.18, strength = 0.095},
}
local function hazeOpacity(x, y)
	local density = 0
	for _, pool in ipairs(pools) do
		local dx, dy = (x - pool.x) / pool.sx, (y - pool.y) / pool.sy
		density = density + pool.strength * math.exp(-2 * (dx * dx + dy * dy))
	end
	return math.clamp(density, 0, 0.88)
end

local HAZE_COLUMNS = 256
local GRADIENT_KEYS = 20
for column = 1, HAZE_COLUMNS do
	local x = (column - 0.5) / HAZE_COLUMNS
	local strip = Instance.new("Frame")
	strip.Name = "HazeColumn"
	strip.BorderSizePixel = 0
	strip.Position = UDim2.fromScale((column - 1) / HAZE_COLUMNS, 0)
	strip.Size = UDim2.fromScale(1 / HAZE_COLUMNS, 1)
	strip.BackgroundColor3 = Color3.fromRGB(207, 139, 49)
	strip.ZIndex = 2
	strip.Parent = glowLayer
	local keys = {}
	for i = 0, GRADIENT_KEYS - 1 do
		local y = i / (GRADIENT_KEYS - 1)
		keys[i + 1] = NumberSequenceKeypoint.new(y, 1 - hazeOpacity(x, y))
	end
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = 90
	gradient.Transparency = NumberSequence.new(keys)
	gradient.Parent = strip
end

-- Soft radial bloom made from faint circles, without an outlined ring.
local function softHalo(parent, diameter, strength)
	for i = 1, 16 do
		local radius = 1 - (i - 1) / 16
		local layer = Instance.new("Frame")
		layer.Name = "SoftHalo"
		layer.AnchorPoint = Vector2.new(0.5, 0.5)
		layer.Position = UDim2.fromScale(0.5, 0.5)
		layer.Size = UDim2.fromOffset(diameter * radius, diameter * radius)
		layer.BackgroundColor3 = Color3.fromRGB(255, 177, 55)
		layer.BackgroundTransparency = 1 - strength * (0.012 + 0.032 * (1 - radius))
		layer.BorderSizePixel = 0
		layer.ZIndex = 1
		layer.Parent = parent
		Instance.new("UICorner", layer).CornerRadius = UDim.new(1, 0)
	end
end

-- Background world blur; the UI softness is built separately.
blur = Instance.new("BlurEffect")
blur.Name = "GildedArchiveBlur"
blur.Size = 0
blur.Parent = Lighting

-- Particle layer.
local particleLayer = Instance.new("Frame")
particleLayer.Name = "Particles"
particleLayer.Size = UDim2.fromScale(1, 1)
particleLayer.BackgroundTransparency = 1
particleLayer.ZIndex = 3
particleLayer.Parent = background

local function makeParticle(seed)
	local dot = Instance.new("Frame")
	dot.Name = "GoldParticle"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)

	local bokeh = rng:NextNumber() < 0.14
	local size = bokeh and rng:NextNumber(12, 32) or rng:NextNumber(1.5, 4)
	local width, height = size, size

	local x = rng:NextNumber(0.015, 0.985)
	local y = seed and rng:NextNumber(0.02, 0.98) or 1.04
	dot.Position = UDim2.fromScale(x, y)
	dot.Size = UDim2.fromOffset(width, height)
	dot.Rotation = 0
	dot.BackgroundColor3 = Color3.fromRGB(255, rng:NextInteger(184, 212), 115)
	dot.BackgroundTransparency = 1
	dot.BorderSizePixel = 0
	dot.ZIndex = 3
	dot.Parent = particleLayer

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	local bokehLayers = {}
	if bokeh then
		for i = 1, 10 do
			local layer = Instance.new("Frame")
			layer.AnchorPoint = Vector2.new(0.5, 0.5)
			layer.Position = UDim2.fromScale(0.5, 0.5)
			layer.Size = UDim2.fromScale(1 - (i - 1) / 10, 1 - (i - 1) / 10)
			layer.BackgroundColor3 = Color3.fromRGB(203, 142, 47)
			layer.BackgroundTransparency = 1
			layer.BorderSizePixel = 0
			layer.Parent = dot
			Instance.new("UICorner", layer).CornerRadius = UDim.new(1, 0)
			table.insert(bokehLayers, layer)
			TweenService:Create(layer, TweenInfo.new(0.9), {BackgroundTransparency = 0.96}):Play()
		end
	elseif size > 3 then
		softHalo(dot, size * 4, 0.48)
	end

	local travel = rng:NextNumber(10, 15)
	local endX = math.clamp(x + rng:NextNumber(-0.045, 0.045), 0.005, 0.995)
	local endY = seed and (y - rng:NextNumber(0.10, 0.28)) or -0.06

	TweenService:Create(dot, TweenInfo.new(0.9, Enum.EasingStyle.Sine), {
		BackgroundTransparency = bokeh and 1 or rng:NextNumber(0.18, 0.65)
	}):Play()

	TweenService:Create(dot, TweenInfo.new(travel, Enum.EasingStyle.Linear), {
		Position = UDim2.fromScale(endX, endY)
	}):Play()

	task.delay(travel - 1, function()
		if dot.Parent then
			for _, layer in ipairs(bokehLayers) do
				TweenService:Create(layer, TweenInfo.new(1), {BackgroundTransparency = 1}):Play()
			end
			TweenService:Create(dot, TweenInfo.new(1, Enum.EasingStyle.Sine), {
				BackgroundTransparency = 1
			}):Play()
		end
	end)

	task.delay(travel + 0.15, function()
		if dot.Parent then dot:Destroy() end
	end)
end

for _ = 1, 72 do makeParticle(true) end

task.spawn(function()
	while running and gui.Parent do
		makeParticle(false)
		task.wait(rng:NextNumber(0.12, 0.24))
	end
end)

-- Brighter sparkles with a small halo.
local function makeSparkle()
	local sparkle = Instance.new("Frame")
	sparkle.Name = "Sparkle"
	sparkle.AnchorPoint = Vector2.new(0.5, 0.5)
	sparkle.Position = UDim2.fromScale(rng:NextNumber(0.03, 0.97), rng:NextNumber(0.04, 0.96))
	sparkle.Size = UDim2.fromOffset(4, 4)
	sparkle.BackgroundColor3 = Color3.fromRGB(255, 226, 169)
	sparkle.BackgroundTransparency = 1
	sparkle.BorderSizePixel = 0
	sparkle.ZIndex = 4
	sparkle.Parent = particleLayer
	Instance.new("UICorner", sparkle).CornerRadius = UDim.new(1, 0)

	softHalo(sparkle, 27, 0.75)

	TweenService:Create(sparkle, TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.02,
		Size = UDim2.fromOffset(3, 3)
	}):Play()

	task.delay(1.0, function()
		if sparkle.Parent then
			TweenService:Create(sparkle, TweenInfo.new(1.25, Enum.EasingStyle.Sine), {
				BackgroundTransparency = 1
			}):Play()
			for _, layer in ipairs(sparkle:GetChildren()) do
				if layer:IsA("Frame") then
					TweenService:Create(layer, TweenInfo.new(1.25), {BackgroundTransparency = 1}):Play()
				end
			end
		end
	end)

	task.delay(2.5, function()
		if sparkle.Parent then sparkle:Destroy() end
	end)
end

task.spawn(function()
	while running and gui.Parent do
		makeSparkle()
		task.wait(rng:NextNumber(0.5, 1.0))
	end
end)

-- Original composition with a larger reference-proportioned title.
local content = Instance.new("Frame")
content.Name = "Content"
content.AnchorPoint = Vector2.new(0.5, 0.5)
content.Position = UDim2.fromScale(0.5, 0.49)
content.Size = UDim2.fromOffset(1140, 452)
content.BackgroundTransparency = 1
content.ZIndex = 6
content.Parent = background

local contentScale = Instance.new("UIScale")
contentScale.Scale = fitScale() * 0.985
contentScale.Parent = content

-- Separate lines give predictable type proportions on different screen sizes.
local titleTop = Instance.new("TextLabel")
titleTop.Name = "TitleGilded"
titleTop.AnchorPoint = Vector2.new(0.5, 0.5)
titleTop.Position = UDim2.fromScale(0.5, 0.27)
titleTop.Size = UDim2.fromScale(0.82, 0.38)
titleTop.BackgroundTransparency = 1
titleTop.Text = "GILDED"
titleTop.Font = Enum.Font.Bodoni
titleTop.TextSize = 100
titleTop.TextScaled = false
titleTop.TextColor3 = Color3.new(1, 1, 1)
titleTop.TextTransparency = 1
titleTop.TextStrokeTransparency = 1
titleTop.RichText = false
titleTop.ZIndex = 20
titleTop.Parent = content

local titleBottom = Instance.new("TextLabel")
titleBottom.Name = "TitleArchive"
titleBottom.AnchorPoint = Vector2.new(0.5, 0.5)
titleBottom.Position = UDim2.fromScale(0.5, 0.59)
titleBottom.Size = UDim2.fromScale(0.96, 0.38)
titleBottom.BackgroundTransparency = 1
titleBottom.Text = "ARCHIVE"
titleBottom.Font = Enum.Font.Bodoni
titleBottom.TextSize = 100
titleBottom.TextScaled = false
titleBottom.TextColor3 = Color3.new(1, 1, 1)
titleBottom.TextTransparency = 1
titleBottom.TextStrokeTransparency = 1
titleBottom.RichText = false
titleBottom.ZIndex = 20
titleBottom.Parent = content

-- Size the title by its measured width, rather than requesting an oversized
-- TextSize. Both lines use the same font scale, with more vertical breathing room.
local TextService = game:GetService("TextService")
local TITLE_WIDTH = 620 -- increase/decrease this to tune both title lines
local measured = TextService:GetTextSize("ARCHIVE", 100, Enum.Font.Bodoni, Vector2.new(10000, 10000))
local titleZoom = TITLE_WIDTH / math.max(measured.X, 1)

for _, label in ipairs({titleTop, titleBottom}) do
	label.Size = UDim2.fromOffset(1100 / titleZoom, 180 / titleZoom)
	local zoom = Instance.new("UIScale")
	zoom.Scale = titleZoom
	zoom.Parent = label

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 235)),
		ColorSequenceKeypoint.new(0.52, Color3.fromRGB(255, 225, 177)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 247, 224))
	})
	gradient.Rotation = 90
	gradient.Parent = label
end

local loadingLabel = Instance.new("TextLabel")
loadingLabel.Name = "LoadingLabel"
loadingLabel.AnchorPoint = Vector2.new(0.5, 0.5)
loadingLabel.Position = UDim2.fromScale(0.5, 0.83)
loadingLabel.Size = UDim2.fromScale(0.5, 0.08)
loadingLabel.BackgroundTransparency = 1
loadingLabel.Text = "L O A D I N G . . ."
loadingLabel.TextScaled = false
loadingLabel.TextStrokeTransparency = 1
loadingLabel.RichText = false
loadingLabel.Font = Enum.Font.Bodoni
loadingLabel.TextSize = 25
loadingLabel.TextColor3 = Color3.fromRGB(255, 222, 164)
loadingLabel.TextTransparency = 1
loadingLabel.ZIndex = 7
loadingLabel.Parent = content

-- Thin track, bright fill, and a multi-layer glow at the moving leading edge.
local barBack = Instance.new("Frame")
barBack.Name = "LoadingBarTrack"
barBack.AnchorPoint = Vector2.new(0.5, 0.5)
barBack.Position = UDim2.fromScale(0.5, 0.908)
barBack.Size = UDim2.new(0.503, 0, 0, 3)
barBack.BackgroundColor3 = Color3.fromRGB(128, 88, 39)
barBack.BackgroundTransparency = 1
barBack.BorderSizePixel = 0
barBack.ZIndex = 7
barBack.Parent = content
Instance.new("UICorner", barBack).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Name = "Fill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Color3.fromRGB(255, 218, 153)
barFill.BorderSizePixel = 0
barFill.ZIndex = 8
barFill.Parent = barBack
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

local fillGradient = Instance.new("UIGradient")
fillGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 202, 112)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 246, 215)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 190, 91))
})
fillGradient.Parent = barFill

local glowHolder = Instance.new("Frame")
glowHolder.Name = "ProgressGlow"
glowHolder.AnchorPoint = Vector2.new(0.5, 0.5)
glowHolder.Position = UDim2.fromScale(0, 0.5)
glowHolder.Size = UDim2.fromOffset(7, 7)
glowHolder.BackgroundColor3 = Color3.fromRGB(255, 238, 196)
glowHolder.BackgroundTransparency = 0.02
glowHolder.BorderSizePixel = 0
glowHolder.ZIndex = 9
glowHolder.Parent = barBack

local glintCorner = Instance.new("UICorner")
glintCorner.CornerRadius = UDim.new(1, 0)
glintCorner.Parent = glowHolder

softHalo(glowHolder, 58, 1.1)
local resizeConnection = scene:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	contentScale.Scale = fitScale()
end)
gui.Destroying:Connect(function()
	running = false
	resizeConnection:Disconnect()
end)

local glintStroke = Instance.new("UIStroke")
glintStroke.Color = Color3.fromRGB(255, 190, 103)
glintStroke.Thickness = 1
glintStroke.Transparency = 0.38
glintStroke.Parent = glowHolder

-- Transition helpers. Movement uses the same design coordinates as the
-- approved layout, so the motion scales down naturally on smaller displays.
local function animate(object, seconds, properties, style, direction)
	local animation = TweenService:Create(object, TweenInfo.new(
		seconds, style or Enum.EasingStyle.Sine,
		direction or Enum.EasingDirection.InOut
	), properties)
	animation:Play()
	return animation
end

local function alive()
	return not cleaned and gui.Parent ~= nil
		and (not Context or not Context.Lifetime or Context.Lifetime.Alive)
end

local function pause(seconds)
	task.wait(seconds)
	return alive()
end

local topRest = titleTop.Position
local bottomRest = titleBottom.Position
local loadingRest = loadingLabel.Position
titleTop.Position = topRest + UDim2.fromOffset(0, 12)
titleBottom.Position = bottomRest + UDim2.fromOffset(0, 16)
loadingLabel.Position = loadingRest + UDim2.fromOffset(0, 5)

-- Fade every part of the bar, including its halo. This prevents the leading
-- light appearing before the loading UI and prevents stray glows on exit.
local barVisuals = {}
local function registerVisual(object, property, restingValue)
	table.insert(barVisuals, {
		object = object, property = property, restingValue = restingValue,
	})
	object[property] = 1
end
registerVisual(barBack, "BackgroundTransparency", 0.22)
for _, object in ipairs(barBack:GetDescendants()) do
	if object:IsA("Frame") then
		registerVisual(object, "BackgroundTransparency", object.BackgroundTransparency)
	elseif object:IsA("UIStroke") then
		registerVisual(object, "Transparency", object.Transparency)
	end
end
local function fadeBar(seconds, visible)
	for _, entry in ipairs(barVisuals) do
		animate(entry.object, seconds, {
			[entry.property] = visible and entry.restingValue or 1,
		})
	end
end

-- ENTRANCE: atmosphere first, then a gentle staggered upward title settle.
-- No bounce, large zoom, or changes to the approved resting composition.
animate(scene, SCENE_IN_SECONDS, {GroupTransparency = 0})
animate(blur, 1.6, {Size = BLUR_AMOUNT})
if not pause(0.45) then return end

animate(titleTop, TITLE_IN_SECONDS, {
	TextTransparency = 0,
	Position = topRest,
}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
animate(contentScale, 2.0, {Scale = fitScale()},
	Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

if not pause(TITLE_STAGGER) then return end
local titleSettled = animate(titleBottom, TITLE_IN_SECONDS, {
	TextTransparency = 0,
	Position = bottomRest,
}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
titleSettled.Completed:Wait()
if not alive() then return end
if not pause(0.2) then return end

-- The title gets a quiet beat before the loading details emerge.
animate(loadingLabel, 0.7, {
	TextTransparency = 0,
	Position = loadingRest,
}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
fadeBar(0.8, true)
if not pause(0.8) then return end

-- Keep the established progress timing and easing.
local fillTween = animate(barFill, BAR_FILL_DURATION, {
	Size = UDim2.fromScale(1, 1),
}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
animate(glowHolder, BAR_FILL_DURATION, {
	Position = UDim2.fromScale(1, 0.5),
}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
fillTween.Completed:Wait()
if not alive() then return end
if not pause(INTRO_HOLD_AFTER_LOAD) then return end

-- Finish the cinematic timing, then hold until the actual startup is ready.
-- The menu is built before Ready is set; feature updates remain parked.
while Context and Context.Startup and not Context.Startup.Ready do
	if Context.Startup.Failed or not pause(0.1) then return end
end

-- Render the ready menu underneath the still-opaque scene. The exit title
-- animation gives the client time to lay it out before the background fades.
if Context and Context.Startup and Context.Startup.RevealMenu then
	Context.Startup.RevealMenu()
end

-- EXIT: loading details soften away first. The two title lines follow with
-- a tiny upward drift, then the atmosphere dissolves to the menu underneath.
running = false
fadeBar(0.45, false)
animate(loadingLabel, 0.45, {
	TextTransparency = 1,
	Position = loadingRest - UDim2.fromOffset(0, 4),
})

if not pause(0.2) then return end
animate(titleBottom, 0.95, {
	TextTransparency = 1,
	Position = bottomRest - UDim2.fromOffset(0, 7),
})
if not pause(0.12) then return end
animate(titleTop, 0.95, {
	TextTransparency = 1,
	Position = topRest - UDim2.fromOffset(0, 7),
})

-- Overlap the end of the title fade with the background fade so there is
-- no abrupt cut or empty pause between the intro and the menu.
if not pause(0.5) then return end
local sceneOut = animate(scene, SCENE_OUT_SECONDS, {GroupTransparency = 1})
local blurOut = animate(blur, SCENE_OUT_SECONDS, {Size = 0})
sceneOut.Completed:Wait()
if not alive() then return end
if blurOut.PlaybackState == Enum.PlaybackState.Playing then
	blurOut.Completed:Wait()
end
if not alive() then return end

end

local ok, err = xpcall(play, debug.traceback)
cleanup()
if not ok then error(err, 0) end
end,
}
