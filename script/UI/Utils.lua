--!strict
--!optimize 2

local Players            = game:GetService("Players")
local UserInputService   = game:GetService("UserInputService")
local TweenService       = game:GetService("TweenService")
local RunService         = game:GetService("RunService")

local Player             = Players.LocalPlayer
local PlayerGui          = Player:WaitForChild("PlayerGui")

local Library = {}
Library.__index = Library

--//==============================================================
--// Theme
--//==============================================================

local Theme = {
    Background         = Color3.fromRGB(15, 18, 19),
    BackgroundLight    = Color3.fromRGB(23, 27, 28),

    Panel              = Color3.fromRGB(27, 32, 33),
    PanelLight         = Color3.fromRGB(34, 39, 40),
    PanelHover         = Color3.fromRGB(40, 46, 47),

    Element            = Color3.fromRGB(30, 35, 36),
    ElementHover       = Color3.fromRGB(39, 45, 46),

    Text               = Color3.fromRGB(232, 237, 235),
    TextSecondary      = Color3.fromRGB(171, 181, 179),
    TextMuted          = Color3.fromRGB(108, 119, 117),

    Cyan               = Color3.fromRGB(220, 205, 0),
    CyanDark           = Color3.fromRGB(150, 150, 150),
    CyanDim            = Color3.fromRGB(255, 255, 255),

    White              = Color3.fromRGB(242, 244, 242),

    Border             = Color3.fromRGB(79, 91, 91),
    BorderDim          = Color3.fromRGB(51, 61, 61),

    Danger             = Color3.fromRGB(218, 79, 79),
    Warning            = Color3.fromRGB(222, 181, 75),

    Black              = Color3.fromRGB(7, 9, 10),
}

--//==============================================================
--// Constants
--//==============================================================

local WINDOW_SIZE      = Vector2.new(760, 480)
local MIN_WINDOW_SIZE  = Vector2.new(560, 360)
local MAX_WINDOW_SIZE  = Vector2.new(1100, 760)
local TEXT_SCALE       = 1
local TEXT_SCALE_MIN   = 0.8
local TEXT_SCALE_MAX   = 2.2
local TEXT_SIZE_MIN    = 6
--// Attribute holding a text's unscaled TextSize, so scaling is always
--// base * scale and never drifts from repeated rounding.
local BASE_TEXT_SIZE_ATTRIBUTE = "AICBaseTextSize"

--// The one font the whole UI uses: the regular weight for text, the bold
--// weight of the same font for names and headings. Text created without a
--// Font gets FONT_REGULAR (see New). Other modules read these as UI.Fonts.
local FONT_REGULAR     = Enum.Font.GothamMedium
local FONT_BOLD        = Enum.Font.GothamBold
local TEXT_CLASSES     = { TextLabel = true, TextButton = true, TextBox = true }
--// Text marked with this keeps its own font when the UI font changes (the
--// font dropdown's options, each drawn in the font it names).
local FONT_PREVIEW_ATTRIBUTE = "AICFontPreview"
--// Sample text a font must lay out to count as loaded.
local FONT_CHECK_TEXT = "Ag"

Library.Fonts = {
    Regular = FONT_REGULAR,
    Bold = FONT_BOLD,
}

--// Moves one text object onto the chosen font family, keeping its own
--// weight and style, so bold text stays bold.
local function ApplyFontFamily(object: Instance, family: string)
    if object:GetAttribute(FONT_PREVIEW_ATTRIBUTE) then
        return true
    end

    local ok = pcall(function()
        local face = (object :: any).FontFace
        ;(object :: any).FontFace = Font.new(family, face.Weight, face.Style)
    end)

    return ok
end

local TWEEN_FAST   = TweenInfo.new(0.12, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_NORMAL = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_SMOOTH = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

--//==============================================================
--// Utility
--//==============================================================

local function New(className: string, properties: {[string]: any}?): Instance
    local object = Instance.new(className)

    --// Roblox's default font differs from ours; set before properties so an
    --// explicit Font still wins.
    if TEXT_CLASSES[className] then
        (object :: any).Font = FONT_REGULAR
    end

    if properties then
        for property, value in pairs(properties) do
            object[property] = value
        end
    end

    return object
end

local function Tween(object: Instance, info: TweenInfo, properties: {[string]: any})
    local tween = TweenService:Create(object, info, properties)
    tween:Play()

    return tween
end

local function AddCorner(parent: Instance, radius: number?)
    local corner = New("UICorner", {
        CornerRadius = UDim.new(0, radius or 3),
    })

    corner.Parent = parent

    return corner
end

local function AddStroke(parent: Instance, color: Color3?, transparency: number?, thickness: number?)
    local stroke = New("UIStroke", {
        Color = color or Theme.Border,
        Transparency = transparency or 0,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })

    stroke.Parent = parent

    return stroke
end

local function AddPadding(parent: Instance, left: number?, right: number?, top: number?, bottom: number?)
    local padding = New("UIPadding", {
        PaddingLeft = UDim.new(0, left or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    })

    padding.Parent = parent

    return padding
end

local function AddGradient(parent: Instance, rotation: number?, transparency: NumberSequence?)
    local gradient = New("UIGradient", {
        Rotation = rotation or 0,
        Transparency = transparency,
    })

    gradient.Parent = parent

    return gradient
end

local function AddLine(parent: Instance, position: UDim2, size: UDim2, color: Color3?, transparency: number?)
    return New("Frame", {
        Parent = parent,
        BackgroundColor3 = color or Theme.Border,
        BackgroundTransparency = transparency or 0,
        BorderSizePixel = 0,
        Position = position,
        Size = size,
    })
end

local function AddText(
    parent: Instance,
    text: string,
    size: number,
    position: UDim2,
    dimensions: UDim2
)
    local label = New("TextLabel", {
        Parent = parent,

        BackgroundTransparency = 1,

        Position = position,
        Size = dimensions,

        Text = text,
        TextColor3 = Theme.Text,
        TextSize = math.round(size * TEXT_SCALE),

        Font = FONT_REGULAR,

        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,

        ClipsDescendants = true,
    })

    return label
end

--//==============================================================
--// Angular Decoration
--//==============================================================

local function AddAngularCorners(parent: Instance, color: Color3?)
    local holder = New("Frame", {
        Parent = parent,

        BackgroundTransparency = 1,

        Size = UDim2.fromScale(1, 1),

        ZIndex = parent.ZIndex + 2,

        ClipsDescendants = true,
    })

    local accent = color or Theme.Cyan

    -- Top left
    AddLine(
        holder,
        UDim2.fromOffset(0, 0),
        UDim2.fromOffset(28, 1),
        accent
    )

    AddLine(
        holder,
        UDim2.fromOffset(0, 0),
        UDim2.fromOffset(1, 18),
        accent
    )

    AddLine(
        holder,
        UDim2.fromOffset(0, 17),
        UDim2.fromOffset(8, 1),
        accent
    )

    -- Top right
    AddLine(
        holder,
        UDim2.new(1, -28, 0, 0),
        UDim2.fromOffset(28, 1),
        accent
    )

    AddLine(
        holder,
        UDim2.new(1, -1, 0, 0),
        UDim2.fromOffset(1, 18),
        accent
    )

    -- Bottom left
    AddLine(
        holder,
        UDim2.new(0, 0, 1, -1),
        UDim2.fromOffset(28, 1),
        accent
    )

    AddLine(
        holder,
        UDim2.new(0, 0, 1, -18),
        UDim2.fromOffset(1, 18),
        accent
    )

    -- Bottom right
    AddLine(
        holder,
        UDim2.new(1, -28, 1, -1),
        UDim2.fromOffset(28, 1),
        accent
    )

    AddLine(
        holder,
        UDim2.new(1, -1, 1, -18),
        UDim2.fromOffset(1, 18),
        accent
    )

    return holder
end

--//==============================================================
--// Descriptions and hover highlight
--//==============================================================

--// A widget with a description is this much taller; the description
--// line sits under its name.
local DESCRIPTION_EXTRA = 12
local DESCRIPTION_TEXT_SIZE = 8

--// The muted line under a widget's name.
local function AddDescription(library, parent: Instance, text: string, position: UDim2, size: UDim2)
    local label = AddText(parent, text, DESCRIPTION_TEXT_SIZE, position, size)

    label.TextColor3 = library.Theme.TextMuted
    label.TextTruncate = Enum.TextTruncate.AtEnd
    label.ZIndex = 16

    return label
end

--// Hovering the target lights its stroke up in the accent colour.
local function AddHoverHighlight(library, target: GuiObject, stroke: UIStroke)
    local baseColor = stroke.Color
    local baseTransparency = stroke.Transparency

    library:_Connect(target.MouseEnter, function()
        Tween(stroke, TWEEN_FAST, { Color = library.Theme.Cyan, Transparency = 0 })
    end)

    library:_Connect(target.MouseLeave, function()
        Tween(stroke, TWEEN_FAST, { Color = baseColor, Transparency = baseTransparency })
    end)
end

--//==============================================================
--// Connection Manager
--//==============================================================

function Library:_Connect(signal, callback)
    local connection = signal:Connect(callback)

    table.insert(self._connections, connection)

    return connection
end

--// Name -> description shown under that widget's name. Looked up by the
--// name in upper case, so the label's own casing does not matter. A
--// description passed to a widget directly wins over this map.
function Library:SetDescriptions(map: {[string]: string})
    self.Descriptions = {}

    for name, text in pairs(map) do
        self.Descriptions[string.upper(name)] = text
    end
end

function Library:_GetDescription(name: string, description: string?): string?
    if type(description) == "string" and description ~= "" then
        return description
    end

    return self.Descriptions and self.Descriptions[string.upper(tostring(name))] or nil
end

--// For windows built outside this file (UI/Floating), in the same look.
function Library:_AddAngularCorners(parent: Instance, color: Color3?)
    return AddAngularCorners(parent, color)
end

function Library:_AddHoverHighlight(target: GuiObject, stroke: UIStroke)
    return AddHoverHighlight(self, target, stroke)
end

--//==============================================================
--// Window Settings / Theme Panel
--//==============================================================

local THEME_KEYS = {
    "Background", "BackgroundLight", "Panel", "PanelLight", "PanelHover",
    "Element", "ElementHover", "Text", "TextSecondary", "TextMuted",
    "Cyan", "CyanDark", "CyanDim", "White", "Border", "BorderDim",
    "Danger", "Warning", "Black",
}

local function ColorToHex(color: Color3): string
    return string.format("#%02X%02X%02X",
        math.round(color.R * 255),
        math.round(color.G * 255),
        math.round(color.B * 255)
    )
end

local function ParseHexColor(value: string): Color3?
    value = tostring(value or '')
    local hex = string.gsub(value, "#", "")
    if #hex == 3 then
        hex = string.sub(hex, 1, 1) .. string.sub(hex, 1, 1)
            .. string.sub(hex, 2, 2) .. string.sub(hex, 2, 2)
            .. string.sub(hex, 3, 3) .. string.sub(hex, 3, 3)
    end
    if #hex ~= 6 or not string.match(hex, "^[%da-fA-F]+$") then
        return nil
    end
    local r = tonumber(string.sub(hex, 1, 2), 16)
    local g = tonumber(string.sub(hex, 3, 4), 16)
    local b = tonumber(string.sub(hex, 5, 6), 16)
    if not r or not g or not b then
        return nil
    end
    return Color3.fromRGB(r, g, b)
end

local function ParseRGBColor(value: string): Color3?
    local text = tostring(value or '')
    local r, g, b = string.match(text, '^%s*(%d+)%s*[,; ]%s*(%d+)%s*[,; ]%s*(%d+)%s*$')
    if not r or not g or not b then
        return nil
    end
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not r or not g or not b then
        return nil
    end
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then
        return nil
    end
    return Color3.fromRGB(r, g, b)
end

local function ParseColor(value: string): Color3?
    return ParseHexColor(value) or ParseRGBColor(value)
end

local function ColorToRGB(color: Color3): (number, number, number)
    return math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255)
end


function Library:_CreateSettingsPanel()
    -- The trigger intentionally lives below the Navigation ScrollingFrame.
    local sidebar = self.Sidebar
    local header = self.Header

    local configButton = New("TextButton", {
        Name = "ConfigButton",
        Parent = sidebar,
        BackgroundColor3 = self.Theme.Element,
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 10, 1, -52),
        Size = UDim2.new(1, -20, 0, 42),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 25,
    })
    AddStroke(configButton, self.Theme.BorderDim, 0.25, 1)

    local cfgDiamond = AddText(configButton, "◇", 13, UDim2.fromOffset(13, 0), UDim2.fromOffset(22, 42))
    cfgDiamond.TextColor3 = self.Theme.Cyan
    cfgDiamond.Font = FONT_BOLD

    local cfgLabel = AddText(configButton, "CONFIGURATION", 9, UDim2.fromOffset(42, 0), UDim2.new(1, -72, 1, 0))
    cfgLabel.TextColor3 = self.Theme.Cyan
    cfgLabel.Font = FONT_BOLD

    local cfgMark = AddText(configButton, "›", 18, UDim2.new(1, -34, 0, 0), UDim2.fromOffset(24, 42))
    cfgMark.TextColor3 = self.Theme.TextMuted
    cfgMark.TextXAlignment = Enum.TextXAlignment.Right

    self.ConfigButton = configButton
    self.ConfigAccent = cfgDiamond
    self.ConfigDiamond = cfgDiamond
    self.ConfigMark = cfgMark

    self:_Connect(configButton.MouseEnter, function()
        Tween(configButton, TWEEN_FAST, {BackgroundColor3 = self.Theme.ElementHover})
        Tween(cfgDiamond, TWEEN_FAST, {TextColor3 = self.Theme.White})
        Tween(cfgLabel, TWEEN_FAST, {TextColor3 = self.Theme.White})
        Tween(cfgMark, TWEEN_FAST, {TextColor3 = self.Theme.Cyan})
    end)

    self:_Connect(configButton.MouseLeave, function()
        Tween(configButton, TWEEN_FAST, {BackgroundColor3 = self.Theme.Element})
        Tween(cfgDiamond, TWEEN_FAST, {TextColor3 = self.Theme.Cyan})
        Tween(cfgLabel, TWEEN_FAST, {TextColor3 = self.Theme.Cyan})
        Tween(cfgMark, TWEEN_FAST, {TextColor3 = self.Theme.TextMuted})
    end)

    -- Connected after the settings transition function is created below.


    -- Full content overlay: Settings replaces both Navigation + Tab content,
    -- while the main Window Header remains visible for context.
    local panel = New("TextButton", {
        --// A button, so a click on it stops here instead of reaching the UI
        --// underneath; it draws like a frame.
        Text = "",
        AutoButtonColor = false,
        Name = "SettingsPanel",
        Parent = self.Window,
        BackgroundColor3 = self.Theme.Background,
        BackgroundTransparency = 0.015,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 58),
        Size = UDim2.new(1, 0, 1, -58),
        Visible = false,
        Active = true,
        Selectable = false,
        ZIndex = 80,
        ClipsDescendants = true,
    })
    self.SettingsPanel = panel
    AddStroke(panel, self.Theme.Border, 0.05, 1)
    AddAngularCorners(panel, self.Theme.CyanDark)

    local topLine = New("Frame", {
        Parent = panel,
        BackgroundColor3 = self.Theme.Cyan,
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 16),
        Size = UDim2.fromOffset(44, 2),
        ZIndex = 82,
    })

    local panelTitle = AddText(panel, "SYSTEM CONFIGURATION", 14, UDim2.fromOffset(18, 23), UDim2.new(1, -150, 0, 24))
    panelTitle.TextColor3 = self.Theme.White
    panelTitle.Font = FONT_BOLD
    panelTitle.ZIndex = 82

    local panelSub = AddText(panel, "THEME / WINDOW / TYPOGRAPHY", 8, UDim2.fromOffset(19, 47), UDim2.new(1, -150, 0, 16))
    panelSub.TextColor3 = self.Theme.TextMuted
    panelSub.Font = FONT_REGULAR
    panelSub.ZIndex = 82

    local scroll = New("ScrollingFrame", {
        Parent = panel, Name = "SettingsScroll", BackgroundTransparency = 1, BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 74), Size = UDim2.new(1, -36, 1, -144),
        CanvasSize = UDim2.fromOffset(0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 3, ScrollBarImageColor3 = self.Theme.CyanDark,
        ZIndex = 81,
    })
    AddPadding(scroll, 2, 8, 2, 14)
    New("UIListLayout", {Parent = scroll, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6)})

    local themeHeader = AddText(scroll, "THEME COLORS", 9, UDim2.fromOffset(4, 0), UDim2.new(1, -8, 0, 22))
    themeHeader.TextColor3 = self.Theme.Cyan
    themeHeader.Font = FONT_BOLD
    themeHeader.LayoutOrder = 1

    self._ThemeInputs = {}
    self._ThemeSwatches = {}
    self._ActiveColorKey = nil

    local picker = New("TextButton", {
        --// A button, so a click on it stops here instead of reaching the UI
        --// underneath; it draws like a frame.
        Text = "",
        AutoButtonColor = false,
        Name = "ThemeColorPicker",
        Parent = panel,
        BackgroundColor3 = self.Theme.Panel,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 0),
        Size = UDim2.fromOffset(360, 232),
        Visible = false,
        ClipsDescendants = true,
        ZIndex = 120,
    })
    AddAngularCorners(picker, self.Theme.Cyan)
    AddStroke(picker, self.Theme.Border, 0.03, 1)
    self.ThemeColorPicker = picker

    local pickerTitle = AddText(picker, "COLOR PICKER", 9, UDim2.fromOffset(12, 8), UDim2.new(1, -50, 0, 20))
    pickerTitle.TextColor3 = self.Theme.Cyan
    pickerTitle.Font = FONT_BOLD
    pickerTitle.ZIndex = 121

    local pickerClose = New("TextButton", {Parent=picker, BackgroundTransparency=1, BorderSizePixel=0, Position=UDim2.new(1,-32,0,5), Size=UDim2.fromOffset(24,24), Text="X", TextColor3=self.Theme.TextMuted, TextSize=9, Font=FONT_BOLD, AutoButtonColor=false, ZIndex=122})
    self:_Connect(pickerClose.MouseButton1Click, function() picker.Visible = false end)

    -- Color picker: spectrum + grayscale, with explicit HEX and RGB fields.
    local palette = New("Frame", {Parent=picker, BackgroundTransparency=1, Position=UDim2.fromOffset(12,38), Size=UDim2.new(1,-24,0,136), ZIndex=121})
    New("UIGridLayout", {Parent=palette, CellSize=UDim2.fromOffset(24,20), CellPadding=UDim2.fromOffset(4,4), SortOrder=Enum.SortOrder.LayoutOrder})

    local paletteColors = {}
    for i = 0, 23 do
        table.insert(paletteColors, Color3.fromHSV(i / 24, 0.88, 1))
    end
    for _, value in ipairs({1, 0.9, 0.78, 0.62, 0.46, 0.30, 0.14, 0.04}) do
        table.insert(paletteColors, Color3.new(value, value, value))
    end
    self._PickerPalette = paletteColors

    for index, color in ipairs(paletteColors) do
        local swatch = New("TextButton", {Parent=palette, BackgroundColor3=color, BorderSizePixel=0, Text="", AutoButtonColor=false, LayoutOrder=index, ZIndex=122})
        AddStroke(swatch, self.Theme.BorderDim, 0.15, 1)
        self:_Connect(swatch.MouseButton1Click, function()
            if not self._ActiveColorKey then return end
            self:_SetPickerColor(color)
        end)
    end

    local inputHeader = AddText(picker, "VALUE INPUT", 7, UDim2.fromOffset(12,178), UDim2.new(1,-24,0,14))
    inputHeader.TextColor3 = self.Theme.TextMuted
    inputHeader.Font = FONT_BOLD
    inputHeader.ZIndex = 122

    local hexLabel = AddText(picker, "HEX", 7, UDim2.fromOffset(12,194), UDim2.fromOffset(32,16))
    hexLabel.TextColor3 = self.Theme.Cyan
    hexLabel.Font = FONT_BOLD
    hexLabel.ZIndex = 122

    local hexInput = New("TextBox", {Parent=picker, BackgroundColor3=self.Theme.Element, BackgroundTransparency=0.05, BorderSizePixel=0, Position=UDim2.fromOffset(43,190), Size=UDim2.fromOffset(92,28), Text="#DCCD00", PlaceholderText="#RRGGBB", TextColor3=self.Theme.Text, PlaceholderColor3=self.Theme.TextMuted, TextSize=9, Font=FONT_REGULAR, ClearTextOnFocus=false, ZIndex=122})
    AddAngularCorners(hexInput, self.Theme.BorderDim)
    AddStroke(hexInput, self.Theme.BorderDim, 0.15, 1)
    AddPadding(hexInput, 7, 7, 0, 0)
    self._PickerHexInput = hexInput

    local rgbInputs = {}
    self._PickerRGBInputs = rgbInputs
    for index, channel in ipairs({"R", "G", "B"}) do
        local x = 143 + ((index - 1) * 49)
        local label = AddText(picker, channel, 7, UDim2.fromOffset(x,194), UDim2.fromOffset(12,16))
        label.TextColor3 = self.Theme.Cyan
        label.Font = FONT_BOLD
        label.ZIndex = 122
        local input = New("TextBox", {Parent=picker, BackgroundColor3=self.Theme.Element, BackgroundTransparency=0.05, BorderSizePixel=0, Position=UDim2.fromOffset(x+13,190), Size=UDim2.fromOffset(32,28), Text="0", PlaceholderText="0", TextColor3=self.Theme.Text, PlaceholderColor3=self.Theme.TextMuted, TextSize=8, Font=FONT_REGULAR, ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center, ZIndex=122})
        AddAngularCorners(input, self.Theme.BorderDim)
        AddStroke(input, self.Theme.BorderDim, 0.15, 1)
        rgbInputs[channel] = input
    end

    local pickerApply = New("TextButton", {Parent=picker, BackgroundColor3=self.Theme.ElementHover, BorderSizePixel=0, Position=UDim2.new(1,-64,0,190), Size=UDim2.fromOffset(52,28), Text="SET", TextColor3=self.Theme.Cyan, TextSize=8, Font=FONT_BOLD, AutoButtonColor=false, ZIndex=122})
    AddStroke(pickerApply, self.Theme.BorderDim, 0.25, 1)
    AddAngularCorners(pickerApply, self.Theme.CyanDark)
    self:_Connect(pickerApply.MouseButton1Click, function()
        if not self._ActiveColorKey then return end
        local color = ParseHexColor(hexInput.Text)
        if not color then
            color = ParseRGBColor((rgbInputs.R.Text or "") .. "," .. (rgbInputs.G.Text or "") .. "," .. (rgbInputs.B.Text or ""))
        end
        if color then self:_SetPickerColor(color) end
    end)

    function self:_SetPickerColor(color: Color3)
        if not self._ActiveColorKey then return end
        local input = self._ThemeInputs[self._ActiveColorKey]
        if not input then return end
        local r, g, b = ColorToRGB(color)
        input.Text = ColorToHex(color)
        if self._PickerHexInput then self._PickerHexInput.Text = ColorToHex(color) end
        if self._PickerRGBInputs then
            self._PickerRGBInputs.R.Text = tostring(r)
            self._PickerRGBInputs.G.Text = tostring(g)
            self._PickerRGBInputs.B.Text = tostring(b)
        end
        self:_UpdateThemeSwatch(self._ActiveColorKey)
    end

    self:_Connect(hexInput.FocusLost, function()
        local color = ParseHexColor(hexInput.Text)
        if color then
            self:_SetPickerColor(color)
        end
    end)

    for _, channel in ipairs({"R", "G", "B"}) do
        self:_Connect(rgbInputs[channel].FocusLost, function()
            local color = ParseRGBColor((rgbInputs.R.Text or "") .. "," .. (rgbInputs.G.Text or "") .. "," .. (rgbInputs.B.Text or ""))
            if color then
                self:_SetPickerColor(color)
            end
        end)
    end

    function self:_UpdateThemeSwatch(key)
        local swatch = self._ThemeSwatches[key]
        local input = self._ThemeInputs[key]
        if swatch and input then
            local color = ParseColor(input.Text)
            if color then swatch.BackgroundColor3 = color end
        end
    end

    function self:_OpenThemePicker(key, anchor)
        self._ActiveColorKey = key
        local input = self._ThemeInputs[key]
        if input then
            local color = ParseColor(input.Text)
            if color then
                self:_SetPickerColor(color)
            else
                self._PickerHexInput.Text = input.Text
            end
        end
        picker.Visible = true
        local y = anchor.AbsolutePosition.Y - panel.AbsolutePosition.Y + anchor.AbsoluteSize.Y + 5
        local maxY = math.max(8, panel.AbsoluteSize.Y - picker.AbsoluteSize.Y - 8)
        picker.Position = UDim2.fromOffset(math.clamp(anchor.AbsolutePosition.X - panel.AbsolutePosition.X, 8, math.max(8, panel.AbsoluteSize.X - 368)), math.clamp(y, 8, maxY))
    end

    for index, key in ipairs(THEME_KEYS) do
        local row = New("Frame", {Parent=scroll, BackgroundColor3=self.Theme.Element, BackgroundTransparency=0.12, BorderSizePixel=0, Size=UDim2.new(1,-4,0,34), LayoutOrder=index+1, ZIndex=102})
        AddAngularCorners(row, self.Theme.BorderDim)
        local label = AddText(row, key:upper(), 8, UDim2.fromOffset(10,0), UDim2.new(1,-178,1,0))
        label.TextColor3 = self.Theme.TextSecondary
        local swatch = New("TextButton", {Parent=row, BackgroundColor3=self.Theme[key], BorderSizePixel=0, Position=UDim2.new(1,-158,0,6), Size=UDim2.fromOffset(22,22), Text="", AutoButtonColor=false, ZIndex=104})
        AddStroke(swatch, self.Theme.BorderDim, 0.2, 1)
        AddStroke(swatch, self.Theme.White, 0.55, 1)
        self._ThemeSwatches[key] = swatch
        local input = New("TextBox", {Parent=row, BackgroundColor3=self.Theme.Background, BackgroundTransparency=0.1, BorderSizePixel=0, Position=UDim2.new(1,-128,0,5), Size=UDim2.fromOffset(116,24), Text=ColorToHex(self.Theme[key]), PlaceholderText="#RRGGBB", TextColor3=self.Theme.Text, PlaceholderColor3=self.Theme.TextMuted, TextSize=8, Font=FONT_REGULAR, ClearTextOnFocus=false, ZIndex=103})
        AddAngularCorners(input, self.Theme.BorderDim)
        AddStroke(input, self.Theme.BorderDim, 0.2, 1)
        self._ThemeInputs[key] = input
        self:_Connect(swatch.MouseButton1Click, function() self:_OpenThemePicker(key, row) end)
        self:_Connect(input.FocusLost, function()
            local color = ParseColor(input.Text)
            if color then
                input.Text = ColorToHex(color)
                self:_UpdateThemeSwatch(key)
            end
        end)
    end

    local settingsHeader = AddText(scroll, "WINDOW / TYPOGRAPHY", 9, UDim2.fromOffset(4,0), UDim2.new(1,-8,0,22))
    settingsHeader.TextColor3 = self.Theme.Cyan
    settingsHeader.Font = FONT_BOLD
    settingsHeader.LayoutOrder = #THEME_KEYS + 2

    local function makeNumberRow(order, labelText, value, key, minValue, maxValue, decimals)
        local row = New("Frame", {Parent=scroll, BackgroundColor3=self.Theme.Element, BackgroundTransparency=0.12, BorderSizePixel=0, Size=UDim2.new(1,-4,0,34), LayoutOrder=order, ZIndex=102})
        AddAngularCorners(row, self.Theme.BorderDim)
        local label = AddText(row, labelText, 8, UDim2.fromOffset(10,0), UDim2.new(1,-140,1,0))
        label.TextColor3 = self.Theme.TextSecondary
        local input = New("TextBox", {Parent=row, BackgroundColor3=self.Theme.Background, BackgroundTransparency=0.1, BorderSizePixel=0, Position=UDim2.new(1,-128,0,5), Size=UDim2.fromOffset(116,24), Text=tostring(value), TextColor3=self.Theme.Text, TextSize=8, Font=FONT_REGULAR, ClearTextOnFocus=false, ZIndex=103})
        AddAngularCorners(input, self.Theme.BorderDim)
        AddStroke(input,self.Theme.BorderDim,0.2,1)
        self:_Connect(input.FocusLost,function()
            local n=tonumber(input.Text)
            if not n then input.Text=tostring(value); return end
            n=math.clamp(n,minValue,maxValue)
            if decimals==0 then n=math.round(n) end
            input.Text=tostring(n)
            if key=="TextScale" then self:SetTextScale(n) else self:SetWindowSizeLimits(key,n) end
        end)
        return input
    end

    self._MinWidthInput=makeNumberRow(#THEME_KEYS+3,"MIN WIDTH",self.MinWindowSize.X,"MinWidth",360,2000,0)
    self._MinHeightInput=makeNumberRow(#THEME_KEYS+4,"MIN HEIGHT",self.MinWindowSize.Y,"MinHeight",240,1400,0)
    self._MaxWidthInput=makeNumberRow(#THEME_KEYS+5,"MAX WIDTH",self.MaxWindowSize.X,"MaxWidth",400,3000,0)
    self._MaxHeightInput=makeNumberRow(#THEME_KEYS+6,"MAX HEIGHT",self.MaxWindowSize.Y,"MaxHeight",300,2200,0)
    self._TextScaleInput=makeNumberRow(#THEME_KEYS+7,"TEXT SCALE",self.TextScale,"TextScale",TEXT_SCALE_MIN,TEXT_SCALE_MAX,2)

    --// FONT: every Roblox font; picking one applies it to the whole UI at
    --// once. Built with the section dropdown on a stand-in section.
    local fontSection = setmetatable({ Library = self, Holder = scroll, Components = {} }, { __index = Library.SectionMethods })
    local fontDropdown = fontSection:AddDropdown("Font", self:GetFontNames(), function(name)
        self:SetFont(name)
    end, "Font used by the whole UI, saved for every profile")
    fontDropdown.Frame.Size = UDim2.new(1, -4, 0, fontDropdown.Frame.Size.Y.Offset)
    fontDropdown.Frame.LayoutOrder = #THEME_KEYS + 8
    fontDropdown:Set(self.FontName or self:_GetFontChoiceName(FONT_REGULAR), false)
    self._FontDropdown = fontDropdown
    self:_PreviewFontOptions(fontDropdown)

    local hint=AddText(scroll,"SELECT SWATCH TO OPEN COLOR PICKER  //  HEX / RGB + LIMITS",7,UDim2.fromOffset(4,0),UDim2.new(1,-8,0,18))
    hint.TextColor3=self.Theme.TextMuted
    hint.LayoutOrder=#THEME_KEYS+10

    local function refreshInputs()
        for key,input in pairs(self._ThemeInputs) do input.Text=ColorToHex(self.Theme[key]); self:_UpdateThemeSwatch(key) end
        if self._MinWidthInput then self._MinWidthInput.Text=tostring(self.MinWindowSize.X) end
        if self._MinHeightInput then self._MinHeightInput.Text=tostring(self.MinWindowSize.Y) end
        if self._MaxWidthInput then self._MaxWidthInput.Text=tostring(self.MaxWindowSize.X) end
        if self._MaxHeightInput then self._MaxHeightInput.Text=tostring(self.MaxWindowSize.Y) end
        if self._TextScaleInput then self._TextScaleInput.Text=tostring(self.TextScale) end
    end
    self._RefreshSettingsInputs=refreshInputs

    local setOpen

    -- Configuration actions stay outside the ScrollingFrame, matching Navigation's footer pattern.
    local footer = New("Frame", {
        Name = "SettingsFooter",
        Parent = panel,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 0),
        Size = UDim2.new(1, -36, 0, 42),
        ZIndex = 103,
    })
    footer.AnchorPoint = Vector2.new(0, 1)
    footer.Position = UDim2.new(0, 18, 1, -14)

    local footerLayout = New("UIListLayout", {
        Parent = footer, FillDirection = Enum.FillDirection.Horizontal,
        HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center,
        SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6),
    })

    local function makeFooterButton(name, order, callback, accentColor)
        local button = New("TextButton", {
            Parent = footer, BackgroundColor3 = self.Theme.Element, BackgroundTransparency = 0.1,
            BorderSizePixel = 0, Size = UDim2.new(1/3, -4, 0, 42), Text = "",
            AutoButtonColor = false, LayoutOrder = order, ZIndex = 104,
        })
        AddStroke(button, self.Theme.BorderDim, 0.25, 1)
        local diamond = AddText(button, "◇", 13, UDim2.fromOffset(13, 0), UDim2.fromOffset(22, 42))
        diamond.TextColor3 = accentColor or self.Theme.Cyan; diamond.Font = FONT_BOLD
        local label = AddText(button, name:upper(), 9, UDim2.fromOffset(42, 0), UDim2.new(1, -72, 1, 0))
        label.Font = FONT_BOLD
        local arrow = AddText(button, "›", 18, UDim2.new(1, -34, 0, 0), UDim2.fromOffset(24, 42))
        arrow.TextColor3 = self.Theme.TextMuted; arrow.TextXAlignment = Enum.TextXAlignment.Right
        self:_Connect(button.MouseEnter, function()
            Tween(button, TWEEN_FAST, {BackgroundColor3=self.Theme.ElementHover})
            Tween(diamond, TWEEN_FAST, {TextColor3=self.Theme.White})
            Tween(label, TWEEN_FAST, {TextColor3=self.Theme.White})
            Tween(arrow, TWEEN_FAST, {TextColor3=accentColor or self.Theme.Cyan})
        end)
        self:_Connect(button.MouseLeave, function()
            Tween(button, TWEEN_FAST, {BackgroundColor3=self.Theme.Element})
            Tween(diamond, TWEEN_FAST, {TextColor3=accentColor or self.Theme.Cyan})
            Tween(label, TWEEN_FAST, {TextColor3=accentColor or self.Theme.Cyan})
            Tween(arrow, TWEEN_FAST, {TextColor3=self.Theme.TextMuted})
        end)
        self:_Connect(button.MouseButton1Click, callback)
        return button
    end

    self.SettingsApply = makeFooterButton("APPLY", 1, function()
        local colors={}
        for key,input in pairs(self._ThemeInputs) do local color=ParseColor(input.Text); if color then colors[key]=color end end
        self:SetTheme(colors); refreshInputs(); self:Notify("CONFIGURATION","Theme applied successfully.",2)
    end)
    self.SettingsReset = makeFooterButton("RESET DEFAULT", 2, function()
        self:SetTheme(table.clone(self._DefaultTheme))
        self.MinWindowSize=Vector2.new(self._DefaultMinWindowSize.X,self._DefaultMinWindowSize.Y)
        self.MaxWindowSize=Vector2.new(self._DefaultMaxWindowSize.X,self._DefaultMaxWindowSize.Y)
        self:SetWindowSize(Vector2.new(self._DefaultWindowSize.X,self._DefaultWindowSize.Y)); self:SetTextScale(self._DefaultTextScale)
        self:SetFont(FONT_REGULAR)
        refreshInputs(); self:Notify("CONFIGURATION","Default configuration restored.",2)
    end)
    self.SettingsReturn = makeFooterButton("RETURN", 3, function() setOpen(false) end)

    -- The Config button itself uses the same footer button language.
    self:_Connect(configButton.MouseButton1Click, function()
        if setOpen then setOpen(true) end
    end)

    local settingsTransitionToken = 0

    setOpen = function(open)
        settingsTransitionToken += 1
        local token = settingsTransitionToken
        self._SettingsOpen = open

        if open then
            -- Keep the old page mounted underneath the config surface.
            -- This prevents clicks from reaching it and also gives us a clean
            -- crossfade when leaving Configuration.
            panel.Visible = true
            panel.Active = true
            panel.BackgroundTransparency = 1
            panel.Position = UDim2.fromOffset(0, 58)
            panel.Size = UDim2.new(1, 0, 1, -58)

            if self.TabContainer then self.TabContainer.Visible = false end
            if self.NavigationSearchResults then self.NavigationSearchResults.Visible = false end
            if self.Sidebar then self.Sidebar.Visible = false end
            if self.Content then self.Content.Visible = false end

            Tween(panel, TWEEN_SMOOTH, {BackgroundTransparency = 0.015})
        else
            picker.Visible = false

            -- Reveal the existing Navigation + Section page underneath the
            -- configuration surface. Because the panel is still above them,
            -- the user sees a smooth crossfade instead of a hard pop.
            if self.Sidebar then self.Sidebar.Visible = true end
            if self.Content then self.Content.Visible = true end
            if self.TabContainer and not self.NavigationCollapsed then
                self.TabContainer.Visible = true
            end

            panel.Active = true
            local tween = Tween(panel, TweenInfo.new(0.34, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
                BackgroundTransparency = 1,
            })

            tween.Completed:Connect(function()
                if settingsTransitionToken ~= token or self._SettingsOpen then
                    return
                end

                panel.Visible = false
                panel.Active = false
            end)
        end
    end
    self:_Connect(configButton.MouseButton1Click,function() setOpen(not self._SettingsOpen) end)
    self:_Connect(configButton.MouseEnter,function()
        Tween(configButton,TWEEN_FAST,{BackgroundColor3=self.Theme.PanelHover})
        Tween(cfgLabel,TWEEN_FAST,{TextColor3=self.Theme.White})
        Tween(cfgDiamond,TWEEN_FAST,{BackgroundColor3=self.Theme.White})
        Tween(cfgMark,TWEEN_FAST,{TextColor3=self.Theme.Cyan, Rotation=0})
    end)
    self:_Connect(configButton.MouseLeave,function()
        Tween(configButton,TWEEN_FAST,{BackgroundColor3=self.Theme.Element})
        Tween(cfgLabel,TWEEN_FAST,{TextColor3=self.Theme.Cyan})
        Tween(cfgDiamond,TWEEN_FAST,{BackgroundColor3=self.Theme.Cyan})
        Tween(cfgMark,TWEEN_FAST,{TextColor3=self.Theme.TextMuted})
    end)
end

--//==============================================================
--// Window
--//==============================================================

--// options.ManualLoading keeps the boot loader up until FinishLoading is
--// called, with SetLoadingProgress reporting real progress meanwhile.
function Library.new(title: string?, options: {ManualLoading: boolean?}?)
    local self = setmetatable({}, Library)

    self.Title             = title or "SYSTEM"
    self._ManualLoading    = options ~= nil and options.ManualLoading == true
    self.Theme             = table.clone(Theme)
    self._DefaultTheme     = table.clone(Theme)

    self.Tabs              = {}
    self.Sections          = {}
    self.Components        = {}
    self._connections      = {}

    self.CurrentTab        = nil
    self.Visible           = true
    self.Destroyed         = false
    self.NavigationCollapsed = false
    self.WindowSize        = Vector2.new(WINDOW_SIZE.X, WINDOW_SIZE.Y)
    self.MinWindowSize     = Vector2.new(MIN_WINDOW_SIZE.X, MIN_WINDOW_SIZE.Y)
    self.MaxWindowSize     = Vector2.new(MAX_WINDOW_SIZE.X, MAX_WINDOW_SIZE.Y)
    self.TextScale         = TEXT_SCALE
    self._DefaultWindowSize = Vector2.new(WINDOW_SIZE.X, WINDOW_SIZE.Y)
    self._DefaultMinWindowSize = Vector2.new(MIN_WINDOW_SIZE.X, MIN_WINDOW_SIZE.Y)
    self._DefaultMaxWindowSize = Vector2.new(MAX_WINDOW_SIZE.X, MAX_WINDOW_SIZE.Y)
    self._DefaultTextScale = TEXT_SCALE
    self._introPlaying     = true

    self._dropdowns        = {}
    self._notifications    = {}
    self.NavigationCollapsed = false
    self.NavigationSearchText = ""
    self.NavigationSearchIndex = 0
    self.NavigationSearchMatches = {}

    --==========================================================
    -- ScreenGui
    --==========================================================

    local screenGui = New("ScreenGui", {
        Name = "ENDFIELD_INDUSTRIES_UI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
        Parent = PlayerGui,
    })

    self.ScreenGui = screenGui

    --// The font chosen in Configuration (nil: the built-in fonts) and the
    --// other places, outside this ScreenGui, whose text follows it.
    self.FontName = nil
    self.FontFamily = nil
    self._FontRoots = {}
    self:AddFontRoot(screenGui)
    self:_WatchTextScale()

    --==========================================================
    -- Scale
    --==========================================================

    local scale = New("UIScale", {
        Scale = 1,
        Parent = screenGui,
    })

    self.UIScale = scale

    -- Separate animation scale so open/close never modifies responsive scale.
    local windowScale = New("UIScale", {
        Scale = 1,
        Parent = nil,
    })

    self.WindowUIScale = windowScale

    --==========================================================
    -- Window
    --==========================================================

    local window = New("Frame", {
        Name = "Window",

        Parent = screenGui,

        AnchorPoint = Vector2.new(0.5, 0.5),

        Position = UDim2.fromScale(0.5, 0.5),

        Size = UDim2.fromOffset(
            self.WindowSize.X,
            self.WindowSize.Y
        ),

        BackgroundColor3 = self.Theme.Background,

        BorderSizePixel = 0,

        ClipsDescendants = true,

        ZIndex = 10,
    })

    windowScale.Parent = window
    self.Window = window

    -- Single overlay for open/close fades. Avoids creating a Tween for every
    -- descendant on each toggle, which can cause a noticeable frame spike.
    local fadeOverlay = New("Frame", {
        Name = "FadeOverlay",
        Parent = window,
        BackgroundColor3 = self.Theme.Background,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromScale(0, 0),
        Size = UDim2.fromScale(1, 1),
        Active = false,
        ZIndex = 90,
    })
    self.FadeOverlay = fadeOverlay

    AddStroke(window, self.Theme.Border, 0.15, 1)
    AddAngularCorners(window)

    --==========================================================
    -- Resize Handle
    --==========================================================
    local resizeHandle = New("TextButton", {
        Name = "ResizeHandle",
        Parent = window,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, 0, 1, 0),
        Size = UDim2.fromOffset(24, 24),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 40,
    })

    -- Subtle diagonal resize grip.
    for index = 0, 2 do
        AddLine(
            resizeHandle,
            UDim2.new(1, -7 - (index * 5), 1, -2),
            UDim2.fromOffset(7 + (index * 5), 1),
            self.Theme.Border,
            0.15
        )
    end

    self.ResizeHandle = resizeHandle

    --==========================================================
    -- Window Header
    --==========================================================

    local header = New("Frame", {
        Name = "Header",

        Parent = window,

        BackgroundColor3 = self.Theme.BackgroundLight,

        BackgroundTransparency = 0.05,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(0, 0),

        Size = UDim2.new(1, 0, 0, 58),

        ZIndex = 12,
    })

    self.Header = header

    -- Header bottom line
    AddLine(
        header,
        UDim2.new(0, 0, 1, -1),
        UDim2.new(1, 0, 0, 1),
        self.Theme.BorderDim
    )

    -- Logo mark
    local logo = New("TextLabel", {
        Parent = header,

        BackgroundTransparency = 1,

        Position = UDim2.fromOffset(18, 7),

        Size = UDim2.fromOffset(42, 42),

        Text = "◇",

        TextColor3 = self.Theme.Cyan,

        TextSize = 32,

        Font = FONT_BOLD,

        ZIndex = 14,
    })

    self.Logo = logo

    -- Title
    local titleText = self.Title:upper()
    local titleSize = #titleText > 30 and 14 or (#titleText > 24 and 16 or 18)

    local titleLabel = AddText(
        header,
        titleText,
        titleSize,
        UDim2.fromOffset(66, 8),
        UDim2.fromOffset(430, 25)
    )

    titleLabel.Font = FONT_BOLD
    titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
    titleLabel.ZIndex = 14

    self.TitleLabel = titleLabel

    -- Subtitle
    local subtitle = AddText(
        header,
        "CREATED BY ENDMIN1STRATOR // UTILITY SYSTEM  //  ONLINE",
        9,
        UDim2.fromOffset(67, 31),
        UDim2.fromOffset(430, 17)
    )

    subtitle.TextColor3 = self.Theme.TextMuted
    subtitle.Font = FONT_REGULAR
    subtitle.ZIndex = 14

    self.Subtitle = subtitle

    -- System status
    local status = AddText(
        header,
        "SYSTEM  //  01",
        9,
        UDim2.new(1, -260, 0, 10),
        UDim2.fromOffset(130, 18)
    )

    status.TextColor3 = self.Theme.TextMuted
    status.TextXAlignment = Enum.TextXAlignment.Right
    status.ZIndex = 14

    self.StatusLabel = status

    -- Cyan status dot
    local statusDot = New("Frame", {
        Parent = header,

        BackgroundColor3 = self.Theme.Cyan,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -108, 0, 15),

        Size = UDim2.fromOffset(5, 5),

        ZIndex = 14,
    })

    self.StatusDot = statusDot

    -- Close
    local close = New("TextButton", {
        Name = "Close",

        Parent = header,

        BackgroundColor3 = self.Theme.Danger,

        BackgroundTransparency = 0.08,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -45, 0, 10),

        Size = UDim2.fromOffset(34, 34),

        Text = "×",

        TextColor3 = self.Theme.White,

        TextSize = 25,

        Font = FONT_REGULAR,

        AutoButtonColor = false,

        ZIndex = 15,
    })

    self.CloseButton = close

    AddCorner(close, 2)

    self:_Connect(close.MouseEnter, function()
        Tween(close, TWEEN_FAST, {
            BackgroundColor3 = Color3.fromRGB(235, 91, 91),
        })
    end)

    self:_Connect(close.MouseLeave, function()
        Tween(close, TWEEN_FAST, {
            BackgroundColor3 = self.Theme.Danger,
        })
    end)

    self:_Connect(close.MouseButton1Click, function()
        self:SetVisible(false)
    end)

    -- Settings is created after the Navigation footer so its trigger lives at the bottom of the sidebar.

    --==========================================================
    -- Sidebar
    --==========================================================

    local sidebar = New("Frame", {
        Name = "Sidebar",

        Parent = window,

        BackgroundColor3 = self.Theme.Panel,

        BackgroundTransparency = 0.05,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(0, 58),

        Size = UDim2.new(0, 188, 1, -58),

        ZIndex = 11,
    })

    self.Sidebar = sidebar

    AddLine(
        sidebar,
        UDim2.new(1, -1, 0, 0),
        UDim2.fromOffset(1, 532),
        self.Theme.BorderDim
    )

    -- Sidebar header
    local navCollapse = New("TextButton", {
        Name = "NavigationCollapse",
        Parent = sidebar,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(7, 10),
        Size = UDim2.fromOffset(20, 24),
        Text = "›",
        TextColor3 = self.Theme.Cyan,
        TextSize = 18,
        Font = FONT_BOLD,
        AutoButtonColor = false,
        ZIndex = 15,
    })

    self.NavigationCollapseButton = navCollapse

    local navTitle = AddText(
        sidebar,
        "NAVIGATION",
        9,
        UDim2.fromOffset(29, 17),
        UDim2.new(1, -52, 0, 18)
    )

    navTitle.TextColor3 = self.Theme.TextMuted
    navTitle.Font = FONT_BOLD
    navTitle.ZIndex = 14
    navTitle.Active = true

    self.NavigationTitle = navTitle

    -- Explorer-style navigation search
    local searchBox = New("TextBox", {
        Name = "NavigationSearch",
        Parent = sidebar,
        BackgroundColor3 = self.Theme.Background,
        BackgroundTransparency = 0.12,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 48),
        Size = UDim2.new(1, -24, 0, 32),
        ClearTextOnFocus = false,
        PlaceholderText = "🔍  SEARCH // TAB / SECTION...",
        PlaceholderColor3 = self.Theme.TextMuted,
        Text = "",
        TextColor3 = self.Theme.Text,
        TextSize = 9,
        Font = FONT_REGULAR,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 15,
    })
    self.NavigationSearch = searchBox
    AddStroke(searchBox, self.Theme.BorderDim, 0.18, 1)

    -- Give the placeholder/text breathing room so it never hugs the search frame.
    New("UIPadding", {
        Parent = searchBox,
        PaddingLeft = UDim.new(0, 16),
        PaddingRight = UDim.new(0, 16),
    })

    searchBox.TextXAlignment = Enum.TextXAlignment.Center
    searchBox.TextEditable = true
    self:_Connect(searchBox:GetPropertyChangedSignal("Text"), function()
        self.NavigationSearchText = searchBox.Text
        self:_RefreshNavigationSearch()
    end)

    -- Keyboard navigation: ↑ / ↓ move through results, Enter selects, ESC closes.
    self:_Connect(UserInputService.InputBegan, function(input, gameProcessed)
        if gameProcessed or not searchBox:IsFocused() then
            return
        end

        local key = input.KeyCode
        local count = #self.NavigationSearchMatches

        if key == Enum.KeyCode.Escape then
            searchBox:ReleaseFocus(false)
            if self.NavigationSearchResults then
                self.NavigationSearchResults.Visible = false
            end
            self.NavigationSearchIndex = 0
            return
        end

        if count == 0 then
            return
        end

        if key == Enum.KeyCode.Down then
            self.NavigationSearchIndex = math.min(count, (self.NavigationSearchIndex or 0) + 1)
            self:_HighlightNavigationSearchResult()
        elseif key == Enum.KeyCode.Up then
            self.NavigationSearchIndex = math.max(1, (self.NavigationSearchIndex or 1) - 1)
            self:_HighlightNavigationSearchResult()
        elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
            local match = self.NavigationSearchMatches[self.NavigationSearchIndex]
            if match then
                self:_SelectNavigationSearchResult(match)
            end
        end
    end)

    -- Search results are deliberately separate from the real tab list.
    -- This keeps AddTab/SelectTab and their layout untouched.
    local searchResults = New("ScrollingFrame", {
        Name = "NavigationSearchResults",
        Parent = sidebar,
        BackgroundColor3 = self.Theme.Panel,
        BackgroundTransparency = 0.02,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 86),
        Size = UDim2.new(1, -24, 0, 0),
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = self.Theme.CyanDark,
        Visible = false,
        ZIndex = 40,
        ClipsDescendants = true,
    })
    self.NavigationSearchResults = searchResults
    AddStroke(searchResults, self.Theme.BorderDim, 0.2, 1)
    AddPadding(searchResults, 4, 4, 4, 4)

    local resultLayout = New("UIListLayout", {
        Parent = searchResults,
        FillDirection = Enum.FillDirection.Vertical,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 3),
    })
    self.NavigationSearchLayout = resultLayout

    -- Tab container / scrollable navigation
    -- Kept as the same TabContainer reference so existing AddTab/SelectTab
    -- logic and external code do not need to change.
    local tabContainer = New("ScrollingFrame", {
        Name = "Tabs",

        Parent = sidebar,

        BackgroundTransparency = 1,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(10, 84),

        Size = UDim2.new(1, -20, 1, -180),

        CanvasSize = UDim2.fromOffset(0, 0),

        AutomaticCanvasSize = Enum.AutomaticSize.Y,

        ScrollBarThickness = 2,

        ScrollBarImageColor3 = self.Theme.CyanDark,

        ScrollBarImageTransparency = 0.15,

        ScrollingDirection = Enum.ScrollingDirection.Y,

        ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,

        ZIndex = 12,

        ClipsDescendants = true,
    })

    self.TabContainer = tabContainer

    AddPadding(tabContainer, 2, 4, 0, 3)

    local tabLayout = New("UIListLayout", {
        Parent = tabContainer,

        FillDirection = Enum.FillDirection.Vertical,

        HorizontalAlignment = Enum.HorizontalAlignment.Center,

        SortOrder = Enum.SortOrder.LayoutOrder,

        Padding = UDim.new(0, 2),
    })

    self.NavigationLayout = tabLayout

    self:_Connect(searchBox.Focused, function()
        Tween(searchBox, TWEEN_FAST, {BackgroundTransparency = 0.02})
    end)

    self:_Connect(searchBox.FocusLost, function()
        Tween(searchBox, TWEEN_FAST, {BackgroundTransparency = 0.12})
    end)
    self.NavigationLayout = tabLayout

    self:_Connect(navCollapse.MouseEnter, function()
        Tween(navCollapse, TWEEN_FAST, {
            TextColor3 = self.Theme.White,
        })
    end)

    self:_Connect(navCollapse.MouseLeave, function()
        Tween(navCollapse, TWEEN_FAST, {
            TextColor3 = self.Theme.Cyan,
        })
    end)

    self:_Connect(navCollapse.MouseButton1Click, function()
        self:SetNavigationCollapsed(not self.NavigationCollapsed)
    end)

    -- Clicking the NAVIGATION label also toggles the pane, Explorer-style.
    self:_Connect(navTitle.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            self:SetNavigationCollapsed(not self.NavigationCollapsed)
        end
    end)

    -- Sidebar footer
    local footer = AddText(
        sidebar,
        "ENDMIN1STRATOR  //  UTILITY",
        8,
        UDim2.new(0, 20, 1, -72),
        UDim2.new(1, -40, 0, 18)
    )

    footer.AnchorPoint = Vector2.new(0, 1)
    footer.TextColor3 = self.Theme.TextMuted
    self.NavigationFooter = footer

    local version = AddText(
        sidebar,
        "SYSTEM BUILD  //  01",
        8,
        UDim2.new(0, 20, 1, -54),
        UDim2.new(1, -40, 0, 18)
    )

    version.AnchorPoint = Vector2.new(0, 1)
    version.TextColor3 = self.Theme.CyanDark
    self.NavigationVersion = version

    self:_CreateSettingsPanel()

    -- Industrial navigation accents
    local navAccent = New("Frame", {
        Parent = sidebar,
        BackgroundColor3 = self.Theme.Cyan,
        BackgroundTransparency = 0.15,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(20, 42),
        Size = UDim2.fromOffset(34, 2),
        ZIndex = 13,
    })

    local navCorner = New("UICorner", {
        CornerRadius = UDim.new(0, 1),
        Parent = navAccent,
    })

    self.NavigationAccent = navAccent

    self:_Connect(RunService.RenderStepped, function()
        if self.Destroyed or not navAccent.Parent then
            return
        end

        local pulse = (math.sin(os.clock() * 2.2) + 1) * 0.5
        navAccent.BackgroundTransparency = 0.08 + (pulse * 0.22)
    end)

    local navRail = New("Frame", {
        Name = "NavigationRail",
        Parent = sidebar,
        BackgroundColor3 = self.Theme.CyanDark,
        BackgroundTransparency = 0.72,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(26, 68),
        Size = UDim2.fromOffset(2, 34),
        Visible = false,
        ZIndex = 13,
    })

    self.NavigationRail = navRail

    --==========================================================
    -- Content
    --==========================================================

    local content = New("Frame", {
        Name = "Content",

        Parent = window,

        BackgroundTransparency = 1,

        Position = UDim2.fromOffset(188, 58),

        Size = UDim2.new(1, -188, 1, -58),

        ZIndex = 11,

        ClipsDescendants = true,
    })

    self.Content = content

    --==========================================================
    -- Overlay
    --==========================================================

    local overlay = New("Frame", {
        Name = "Overlay",

        Parent = screenGui,

        BackgroundTransparency = 1,

        Size = UDim2.fromScale(1, 1),

        ZIndex = 100,

        Active = false,
    })

    self.Overlay = overlay

    --// The Configuration font dropdown was built before the overlay.
    if self._FontDropdown and self._FontDropdown.Popup then
        self._FontDropdown.Popup.Parent = overlay
    end

    --==========================================================
    -- Reopen Button
    --==========================================================

    local reopen = New("TextButton", {
        Name = "Reopen",

        Parent = screenGui,

        AnchorPoint = Vector2.new(1, 1),

        Position = UDim2.new(1, -24, 1, -24),

        Size = UDim2.fromOffset(54, 54),

        BackgroundColor3 = self.Theme.Panel,

        BackgroundTransparency = 0.05,

        BorderSizePixel = 0,

        Text = "◇",

        TextColor3 = self.Theme.Cyan,

        TextSize = 26,

        Font = FONT_BOLD,

        AutoButtonColor = false,

        Visible = false,

        ZIndex = 200,
    })

    self.ReopenButton = reopen

    AddStroke(reopen, self.Theme.CyanDark, 0.1, 1)
    AddCorner(reopen, 2)

    self:_Connect(reopen.MouseEnter, function()
        Tween(reopen, TWEEN_FAST, {
            BackgroundColor3 = self.Theme.CyanDim,
        })
    end)

    self:_Connect(reopen.MouseLeave, function()
        Tween(reopen, TWEEN_FAST, {
            BackgroundColor3 = self.Theme.Panel,
        })
    end)

    self:_Connect(reopen.MouseButton1Click, function()
        self:SetVisible(true)
    end)

    --==========================================================
    -- Responsive
    --==========================================================

    self:_Connect(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"), function()
        self:_UpdateScale()
    end)

    self:_UpdateScale()

    --==========================================================
    -- Drag
    --==========================================================

    self:_MakeDraggable(header, window)

    --==========================================================
    -- Resize
    --==========================================================

    self:_MakeResizable(resizeHandle, window)

    --==========================================================
    -- Initial Loading Intro
    --==========================================================

    self:_PlayIntro()

    return self
end

--//==============================================================
--// Responsive Scale
--//==============================================================

function Library:_UpdateScale()
    if self.Destroyed then
        return
    end

    local camera = workspace.CurrentCamera

    if not camera then
        return
    end

    local viewport = camera.ViewportSize

    local windowSize = self.WindowSize or WINDOW_SIZE
    local scaleX = (viewport.X - 40) / windowSize.X
    local scaleY = (viewport.Y - 40) / windowSize.Y

    local scale = math.min(scaleX, scaleY)

    -- Mobile/portrait screens need a smaller window scale.
    -- Text has its own global multiplier above, so the UI can shrink
    -- without making the text disproportionately small.
    local minimumScale = viewport.X <= 700 and 0.42 or 0.55
    scale = math.clamp(scale, minimumScale, 1)

    self.UIScale.Scale = scale
end

--//==============================================================
--// Draggable
--//==============================================================

--// Pulls a GuiObject back inside its parent if any edge is past the parent's
--// bounds. Worked out from Position, AnchorPoint and AbsoluteSize rather than
--// AbsolutePosition, which can lag a frame behind a Position change.
local function ClampToParent(target: GuiObject)
    local parent = target.Parent

    if not parent or not parent:IsA("GuiBase2d") then
        return
    end

    local bounds = parent.AbsoluteSize
    local size = target.AbsoluteSize

    if bounds.X <= 0 or bounds.Y <= 0 then
        return
    end

    local position = target.Position
    local anchor = target.AnchorPoint
    local left = bounds.X * position.X.Scale + position.X.Offset - anchor.X * size.X
    local top = bounds.Y * position.Y.Scale + position.Y.Offset - anchor.Y * size.Y

    local clampedLeft = math.clamp(left, 0, math.max(0, bounds.X - size.X))
    local clampedTop = math.clamp(top, 0, math.max(0, bounds.Y - size.Y))

    if clampedLeft ~= left or clampedTop ~= top then
        target.Position = UDim2.new(
            position.X.Scale,
            position.X.Offset + (clampedLeft - left),
            position.Y.Scale,
            position.Y.Offset + (clampedTop - top)
        )
    end
end

Library._ClampToParent = ClampToParent

function Library:_MakeDraggable(handle: GuiObject, target: GuiObject, keepOnScreen: boolean?)
    local dragging = false
    local dragStart: Vector2
    local startPosition: UDim2

    self:_Connect(handle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then
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

    self:_Connect(UserInputService.InputChanged, function(input)
        if not dragging then
            return
        end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        local delta = input.Position - dragStart

        target.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )

        if keepOnScreen then
            ClampToParent(target)
        end
    end)
end

--//==============================================================
--// Resizable
--//==============================================================

function Library:_MakeResizable(handle: GuiObject, target: GuiObject)
    local resizing = false
    local resizeStart: Vector2
    local startSize: Vector2
    local startPosition: UDim2

    self:_Connect(handle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        resizing = true
        resizeStart = input.Position
        startSize = self.WindowSize
        startPosition = target.Position

        self:_CloseDropdowns()
    end)

    self:_Connect(UserInputService.InputChanged, function(input)
        if not resizing then
            return
        end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        local uiScale = math.max(self.UIScale.Scale, 0.01)
        local delta = (input.Position - resizeStart) / uiScale

        local newSize = Vector2.new(
            math.clamp(startSize.X + delta.X, self.MinWindowSize.X, self.MaxWindowSize.X),
            math.clamp(startSize.Y + delta.Y, self.MinWindowSize.Y, self.MaxWindowSize.Y)
        )

        -- Keep the top-left edge visually stable while resizing from bottom-right.
        local sizeDelta = newSize - startSize

        self.WindowSize = newSize
        target.Size = UDim2.fromOffset(newSize.X, newSize.Y)
        target.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + (sizeDelta.X * 0.5),
            startPosition.Y.Scale,
            startPosition.Y.Offset + (sizeDelta.Y * 0.5)
        )

        self:_UpdateScale()
    end)

    self:_Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            resizing = false
        end
    end)
end

--//==============================================================
--// Initial Loading Intro
--//==============================================================

function Library:_PlayIntro()
    if self.Destroyed then
        return
    end

    local window = self.Window
    if not window then
        self._introPlaying = false
        return
    end

    window.Visible = false

    -- Larger Endfield-style boot panel. It remains compact enough to avoid
    -- covering the screen while giving the initial load a stronger identity.
    local loader = New("Frame", {
        Name = "BootLoader",
        Parent = self.ScreenGui,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(360, 154),
        BackgroundColor3 = self.Theme.BackgroundLight,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 300,
        ClipsDescendants = true,
    })

    AddStroke(loader, self.Theme.Border, 1, 1)
    AddCorner(loader, 3)

    local topLine = New("Frame", {
        Parent = loader,
        BackgroundColor3 = self.Theme.Cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(0, 74, 0, 2),
        ZIndex = 304,
    })

    local brand = AddText(
        loader,
        "ENDFIELD INDUSTRIES",
        13,
        UDim2.fromOffset(20, 18),
        UDim2.new(1, -40, 0, 22)
    )
    brand.Font = FONT_BOLD
    brand.TextColor3 = self.Theme.Cyan
    brand.TextTransparency = 1
    brand.ZIndex = 301

    local introTitleText = self.Title:upper()
    local introTitleSize = #introTitleText > 30 and 14 or (#introTitleText > 24 and 15 or 17)

    local title = AddText(
        loader,
        introTitleText,
        introTitleSize,
        UDim2.fromOffset(20, 43),
        UDim2.new(1, -40, 0, 26)
    )
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.Font = FONT_BOLD
    title.TextTransparency = 1
    title.ZIndex = 301

    local status = AddText(
        loader,
        "INITIALIZING SYSTEM  //  ESTABLISHING LINK",
        8,
        UDim2.fromOffset(20, 73),
        UDim2.new(1, -40, 0, 17)
    )
    status.TextColor3 = self.Theme.TextMuted
    status.TextTransparency = 1
    status.ZIndex = 301

    local statusDot = New("Frame", {
        Parent = loader,
        BackgroundColor3 = self.Theme.Cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -35, 0, 78),
        Size = UDim2.fromOffset(5, 5),
        ZIndex = 302,
    })

    local bar = New("Frame", {
        Parent = loader,
        BackgroundColor3 = self.Theme.PanelLight,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 20, 1, -31),
        Size = UDim2.new(1, -40, 0, 3),
        ZIndex = 301,
    })

    local fill = New("Frame", {
        Parent = bar,
        BackgroundColor3 = self.Theme.Cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
        ZIndex = 302,
    })

    local footer = AddText(
        loader,
        "ENDFIELD INDUSTRIES  //  SYSTEM BOOT",
        7,
        UDim2.fromOffset(20, -19),
        UDim2.new(1, -40, 0, 14)
    )
    footer.AnchorPoint = Vector2.new(0, 1)
    footer.TextColor3 = self.Theme.TextMuted
    footer.TextTransparency = 1
    footer.ZIndex = 301

    Tween(loader, TWEEN_SMOOTH, {BackgroundTransparency = 0.06})
    Tween(topLine, TWEEN_SMOOTH, {BackgroundTransparency = 0.05})
    Tween(brand, TWEEN_SMOOTH, {TextTransparency = 0})
    Tween(title, TWEEN_SMOOTH, {TextTransparency = 0})
    Tween(status, TWEEN_SMOOTH, {TextTransparency = 0.15})
    Tween(statusDot, TWEEN_SMOOTH, {BackgroundTransparency = 0})
    Tween(bar, TWEEN_SMOOTH, {BackgroundTransparency = 0.15})
    Tween(footer, TWEEN_SMOOTH, {TextTransparency = 0.25})
    Tween(fill, TWEEN_SMOOTH, {BackgroundTransparency = 0})

    -- Subtle status pulse while the boot sequence is active.
    local pulseConnection
    pulseConnection = RunService.RenderStepped:Connect(function()
        if self.Destroyed or not loader.Parent then
            if pulseConnection then pulseConnection:Disconnect() end
            return
        end
        statusDot.BackgroundTransparency = 0.05 + ((math.sin(os.clock() * 5) + 1) * 0.12)
    end)

    -- Driven by SetLoadingProgress / FinishLoading when the window was made
    -- with ManualLoading; otherwise the bar simply runs to the end.
    self._BootLoader = {
        Status = status,
        Fill = fill,
        Finishing = false,
    }

    local function close()
        if pulseConnection then
            pulseConnection:Disconnect()
        end

        if self.Destroyed then
            return
        end

        task.wait(0.16)

        Tween(loader, TWEEN_NORMAL, {BackgroundTransparency = 1})
        Tween(topLine, TWEEN_NORMAL, {BackgroundTransparency = 1})
        Tween(brand, TWEEN_NORMAL, {TextTransparency = 1})
        Tween(title, TWEEN_NORMAL, {TextTransparency = 1})
        Tween(status, TWEEN_NORMAL, {TextTransparency = 1})
        Tween(statusDot, TWEEN_NORMAL, {BackgroundTransparency = 1})
        Tween(bar, TWEEN_NORMAL, {BackgroundTransparency = 1})
        Tween(fill, TWEEN_NORMAL, {BackgroundTransparency = 1})
        Tween(footer, TWEEN_NORMAL, {TextTransparency = 1})

        task.wait(0.26)

        if self.Destroyed then
            return
        end

        loader:Destroy()
        self._introPlaying = false
        self._BootLoader = nil

        if self.Visible then
            window.Visible = true
            self.WindowUIScale.Scale = 0.94
            Tween(self.WindowUIScale, TWEEN_SMOOTH, {Scale = 1})
            self:_FadeWindow(0)
        end
    end

    self._BootLoader.Close = close

    if not self._ManualLoading then
        self:FinishLoading()
    end
end

--// Boot loader progress, for callers that load in stages (ManualLoading).
--// Fraction is 0..1; Text replaces the status line when given. IsError
--// paints the status red and leaves the loader up.
function Library:SetLoadingProgress(fraction: number?, text: string?, isError: boolean?)
    local boot = self._BootLoader

    if self.Destroyed or not boot or boot.Finishing then
        return
    end

    if text then
        boot.Status.Text = string.upper(text)
    end

    boot.Status.TextColor3 = isError and self.Theme.Danger or self.Theme.TextMuted

    if fraction then
        Tween(boot.Fill, TWEEN_FAST, {
            Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1),
        })
    end
end

--// Runs the bar to the end, fades the loader out and shows the window.
function Library:FinishLoading()
    local boot = self._BootLoader

    if self.Destroyed or not boot or boot.Finishing then
        return
    end

    boot.Finishing = true

    task.spawn(function()
        local progress = Tween(boot.Fill, TweenInfo.new(0.35, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Size = UDim2.fromScale(1, 1),
        })

        progress.Completed:Wait()
        boot.Close()
    end)
end

--//==============================================================
--// Set Visible
--//==============================================================

function Library:SetVisible(value: boolean)
    if self.Destroyed then
        return
    end

    if self.Visible == value then
        return
    end

    self._VisibilityToken = (self._VisibilityToken or 0) + 1
    local visibilityToken = self._VisibilityToken
    self.Visible = value

    local windowScale = self.WindowUIScale

    if value then
        self.ReopenButton.Visible = false

        if self._introPlaying then
            return
        end

        self.Window.Visible = true

        -- Always start from the same animation scale.
        windowScale.Scale = 0.94

        Tween(windowScale, TWEEN_SMOOTH, {
            Scale = 1,
        })

        self:_FadeWindow(0)
    else
        self:_CloseDropdowns()
        if self._SettingsOpen then
            self._SettingsOpen = false
            if self.SettingsPanel then
                self.SettingsPanel.Visible = false
                self.SettingsPanel.Active = false
            end

            -- Configuration temporarily hides the main UI. Restore it before
            -- the window is closed so reopening can never come back blank.
            if self.Sidebar then
                self.Sidebar.Visible = true
            end
            if self.Content then
                self.Content.Visible = true
            end
            if self.TabContainer then
                self.TabContainer.Visible = not self.NavigationCollapsed
            end
            if self.NavigationSearchResults then
                self.NavigationSearchResults.Visible = (not self.NavigationCollapsed)
                    and self.NavigationSearchText ~= ""
            end
        end

        -- Softer shutdown: fade content first, then slightly shrink the window.
        self:_FadeWindow(1, 0.22)
        Tween(windowScale, TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {
            Scale = 0.92,
        })

        task.delay(0.30, function()
            if self.Destroyed or self.Visible or self._VisibilityToken ~= visibilityToken then
                return
            end

            self.Window.Visible = false
            self.ReopenButton.Visible = true
            windowScale.Scale = 1
        end)
    end
end

function Library:_FadeWindow(transparency: number, duration: number?)
    local overlay = self.FadeOverlay
    if not overlay then
        return
    end

    local target = transparency == 1 and 0 or 1
    overlay.BackgroundColor3 = self.Theme.Background
    overlay.BackgroundTransparency = (target == 0) and math.min(overlay.BackgroundTransparency, 0.02) or overlay.BackgroundTransparency

    Tween(overlay, TweenInfo.new(
        duration or 0.22,
        Enum.EasingStyle.Quint,
        Enum.EasingDirection.Out
    ), {
        BackgroundTransparency = target,
    })
end

function Library:Toggle()
    self:SetVisible(not self.Visible)
end

--//==============================================================
--// Tab
--//==============================================================

local TabMethods = {}
TabMethods.__index = TabMethods

function Library:AddTab(name: string)
    local tab = setmetatable({}, TabMethods)

    tab.Library      = self
    tab.Name         = name
    tab.Sections     = {}
    tab._layoutOrder = #self.Tabs + 1

    --==========================================================
    -- Tab Button
    --==========================================================

    local button = New("TextButton", {
        Parent = self.TabContainer,

        BackgroundColor3 = self.Theme.Panel,

        BackgroundTransparency = 1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 46),

        Text = "",

        AutoButtonColor = false,

        LayoutOrder = tab._layoutOrder,

        ZIndex = 13,
    })

    tab.Button = button

    -- Active bar
    local activeBar = New("Frame", {
        Parent = button,

        BackgroundColor3 = self.Theme.Cyan,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(0, 0),

        Size = UDim2.fromOffset(3, 46),

        BackgroundTransparency = 1,

        ZIndex = 14,
    })

    tab.ActiveBar = activeBar

    -- Diamond
    local diamond = AddText(
        button,
        "◇",
        14,
        UDim2.fromOffset(14, 0),
        UDim2.fromOffset(25, 46)
    )

    diamond.TextColor3 = self.Theme.TextMuted
    diamond.ZIndex = 14

    tab.Diamond = diamond

    -- Name
    local label = AddText(
        button,
        name:upper(),
        11,
        UDim2.fromOffset(43, 0),
        UDim2.new(1, -70, 1, 0)
    )

    label.Font = FONT_BOLD
    label.TextColor3 = self.Theme.TextSecondary
    label.ZIndex = 14

    tab.Label = label

    -- Number
    local number = AddText(
        button,
        string.format("%02d", tab._layoutOrder),
        8,
        UDim2.new(1, -32, 0, 0),
        UDim2.fromOffset(24, 46)
    )

    number.TextColor3 = self.Theme.TextMuted
    number.TextXAlignment = Enum.TextXAlignment.Right
    number.ZIndex = 14

    tab.Number = number

    self:_Connect(button.MouseEnter, function()
        if self.CurrentTab ~= tab then
            Tween(button, TWEEN_FAST, {
                BackgroundColor3 = self.Theme.PanelHover,
                BackgroundTransparency = 0.65,
            })

            Tween(label, TWEEN_FAST, {
                TextColor3 = self.Theme.Text,
            })
        end
    end)

    self:_Connect(button.MouseLeave, function()
        if self.CurrentTab ~= tab then
            Tween(button, TWEEN_FAST, {
                BackgroundTransparency = 1,
            })

            Tween(label, TWEEN_FAST, {
                TextColor3 = self.Theme.TextSecondary,
            })
        end
    end)

    self:_Connect(button.MouseButton1Click, function()
        self:SelectTab(tab)
    end)

    -- Content page
    local page = New("ScrollingFrame", {
        Name = name,

        Parent = self.Content,

        BackgroundTransparency = 1,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(0, 0),

        Size = UDim2.fromScale(1, 1),

        ScrollBarThickness = 2,

        ScrollBarImageColor3 = self.Theme.CyanDark,

        CanvasSize = UDim2.fromOffset(0, 0),

        AutomaticCanvasSize = Enum.AutomaticSize.Y,

        Visible = false,

        ZIndex = 12,

        ClipsDescendants = true,
    })

    tab.Page = page

    AddPadding(page, 22, 22, 20, 30)

    local layout = New("UIListLayout", {
        Parent = page,

        FillDirection = Enum.FillDirection.Vertical,

        SortOrder = Enum.SortOrder.LayoutOrder,

        Padding = UDim.new(0, 14),
    })

    tab.Layout = layout

    local emptyState = AddText(
        page,
        "NO CONFIGURATION  //  ADD A SECTION TO BEGIN",
        8,
        UDim2.fromOffset(8, 0),
        UDim2.new(1, -16, 0, 30)
    )
    emptyState.TextColor3 = self.Theme.TextMuted
    emptyState.TextXAlignment = Enum.TextXAlignment.Center
    emptyState.LayoutOrder = 0
    emptyState.Visible = true
    emptyState.ZIndex = 13
    tab.EmptyState = emptyState

    table.insert(self.Tabs, tab)
    self:_RefreshNavigationSearch()

    if not self.CurrentTab then
        self:SelectTab(tab)
    end

    return tab
end

function Library:_RefreshNavigationSearch()
    if self.Destroyed or not self.NavigationSearchResults then
        return
    end

    local query = string.lower(string.gsub(self.NavigationSearchText or "", "^%s*(.-)%s*$", "%1"))
    local results = self.NavigationSearchResults

    for _, child in ipairs(results:GetChildren()) do
        if child:IsA("GuiObject") and child ~= self.NavigationSearchLayout then
            child:Destroy()
        end
    end

    self.NavigationSearchMatches = {}
    self.NavigationSearchIndex = 0

    if query == "" then
        results.Visible = false
        results.Size = UDim2.new(1, -20, 0, 0)
        self.TabContainer.Visible = not self.NavigationCollapsed
        return
    end

    local matches = {}

    local function addMatch(tab, section, kind, name, order)
        if #matches >= 50 then
            return
        end

        if string.find(string.lower(name), query, 1, true) then
            table.insert(matches, {
                Tab = tab,
                Section = section,
                Kind = kind,
                Name = name,
                Order = order,
            })
        end
    end

    for _, tab in ipairs(self.Tabs) do
        addMatch(tab, nil, "TAB", tab.Name, tab._layoutOrder)

        for _, section in ipairs(tab.Sections) do
            addMatch(tab, section, "SECTION", section.Name, tab._layoutOrder * 1000 + section.Frame.LayoutOrder)
        end
    end

    table.sort(matches, function(a, b)
        return a.Order < b.Order
    end)

    self.NavigationSearchMatches = matches

    if #matches == 0 then
        local empty = AddText(
            results,
            "NO MATCHES  //  TRY ANOTHER QUERY",
            8,
            UDim2.fromOffset(8, 0),
            UDim2.new(1, -16, 0, 30)
        )
        empty.TextColor3 = self.Theme.TextMuted
        empty.ZIndex = 42

        local hint = AddText(
            results,
            "ESC TO CLOSE SEARCH",
            7,
            UDim2.fromOffset(8, 0),
            UDim2.new(1, -16, 0, 22)
        )
        hint.TextColor3 = self.Theme.CyanDark
        hint.ZIndex = 42
    else
        for index, match in ipairs(matches) do
            local button = New("TextButton", {
                Parent = results,
                BackgroundColor3 = self.Theme.Element,
                BackgroundTransparency = 0.18,
                BorderSizePixel = 0,
                Size = UDim2.new(1, 0, 0, 36),
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = index,
                ZIndex = 41,
            })

            AddStroke(button, self.Theme.BorderDim, 0.55, 1)

            local marker = AddText(
                button,
                match.Kind == "TAB" and "◇" or "└",
                11,
                UDim2.fromOffset(8, 0),
                UDim2.fromOffset(18, 36)
            )
            marker.TextColor3 = match.Kind == "TAB" and self.Theme.Cyan or self.Theme.TextMuted
            marker.ZIndex = 42

            local label = AddText(
                button,
                match.Name:upper(),
                9,
                UDim2.fromOffset(29, 0),
                UDim2.new(1, -68, 0, 36)
            )
            label.Font = FONT_BOLD
            label.TextColor3 = self.Theme.TextSecondary
            label.TextTruncate = Enum.TextTruncate.AtEnd
            label.ZIndex = 42

            local typeLabel = AddText(
                button,
                match.Kind,
                7,
                UDim2.new(1, -42, 0, 0),
                UDim2.fromOffset(34, 36)
            )
            typeLabel.TextColor3 = self.Theme.CyanDark
            typeLabel.TextXAlignment = Enum.TextXAlignment.Right
            typeLabel.ZIndex = 42

            match.Button = button
            match.Label = label
            match.Marker = marker
            match.TypeLabel = typeLabel

            self:_Connect(button.MouseEnter, function()
                self.NavigationSearchIndex = index
                self:_HighlightNavigationSearchResult()
            end)

            self:_Connect(button.MouseLeave, function()
                if self.NavigationSearchIndex ~= index then
                    self:_HighlightNavigationSearchResult()
                end
            end)

            self:_Connect(button.MouseButton1Click, function()
                self:_SelectNavigationSearchResult(match)
            end)
        end
    end

    local visibleRows = math.min(#matches, 5)
    local height = #matches == 0 and 58 or math.max(36, visibleRows * 36 + 8)

    results.Size = UDim2.new(1, -24, 0, height)
    results.CanvasPosition = Vector2.zero
    results.Visible = not self.NavigationCollapsed
    self.TabContainer.Visible = false

    if #matches > 0 then
        self.NavigationSearchIndex = 1
        self:_HighlightNavigationSearchResult()
    end
end

function Library:_HighlightNavigationSearchResult()
    local matches = self.NavigationSearchMatches or {}
    local selected = self.NavigationSearchIndex or 0

    for index, match in ipairs(matches) do
        if match.Button and match.Button.Parent then
            local active = index == selected

            Tween(match.Button, TWEEN_FAST, {
                BackgroundColor3 = active and self.Theme.CyanDim or self.Theme.Element,
                BackgroundTransparency = active and 0.55 or 0.18,
            })

            Tween(match.Label, TWEEN_FAST, {
                TextColor3 = active and self.Theme.White or self.Theme.TextSecondary,
            })

            Tween(match.Marker, TWEEN_FAST, {
                TextColor3 = active and self.Theme.Cyan or (match.Kind == "TAB" and self.Theme.CyanDark or self.Theme.TextMuted),
            })

            Tween(match.TypeLabel, TWEEN_FAST, {
                TextColor3 = active and self.Theme.Cyan or self.Theme.CyanDark,
            })
        end
    end
end

function Library:_SelectNavigationSearchResult(match)
    if not match or not match.Tab then
        return
    end

    self:SelectTab(match.Tab)

    if match.Section and match.Section.Frame then
        local page = match.Tab.Page
        task.defer(function()
            if self.Destroyed or not page.Parent or not match.Section.Frame.Parent then
                return
            end

            local y = match.Section.Frame.AbsolutePosition.Y - page.AbsolutePosition.Y
            page.CanvasPosition = Vector2.new(0, math.max(0, y - 12))
        end)
    end

    if self.NavigationSearch then
        self.NavigationSearch:ReleaseFocus(false)
    end

    self.NavigationSearchIndex = 0
    if self.NavigationSearchResults then
        self.NavigationSearchResults.Visible = false
    end
    if self.TabContainer then
        self.TabContainer.Visible = not self.NavigationCollapsed
    end
end

function Library:SelectTab(tab)
    if self.Destroyed then
        return
    end

    if self.CurrentTab == tab then
        return
    end

    self:_CloseDropdowns()

    for _, current in ipairs(self.Tabs) do
        local selected = current == tab

        current.Page.Visible = selected

        if current.EmptyState then
            current.EmptyState.Visible = (#current.Sections == 0)
        end

        if selected then
            current.Button.BackgroundColor3 = self.Theme.CyanDim
            current.Button.BackgroundTransparency = 0.65

            current.ActiveBar.BackgroundTransparency = 0

            current.Diamond.TextColor3 = self.Theme.Cyan
            current.Label.TextColor3 = self.Theme.White
            current.Number.TextColor3 = self.Theme.Cyan
        else
            current.Button.BackgroundTransparency = 1

            current.ActiveBar.BackgroundTransparency = 1

            current.Diamond.TextColor3 = self.Theme.TextMuted
            current.Label.TextColor3 = self.Theme.TextSecondary
            current.Number.TextColor3 = self.Theme.TextMuted
        end
    end

    self.CurrentTab = tab
end

--//==============================================================
--// Navigation Collapse
--//==============================================================

function Library:SetNavigationCollapsed(value: boolean)
    if self.Destroyed then
        return
    end

    value = value and true or false

    if self.NavigationCollapsed == value then
        return
    end

    self.NavigationCollapsed = value

    local sidebar = self.Sidebar
    local content = self.Content
    local tabContainer = self.TabContainer
    local collapseButton = self.NavigationCollapseButton
    local searchBox = self.NavigationSearch
    local searchResults = self.NavigationSearchResults

    if not sidebar or not content or not tabContainer then
        return
    end

    local sidebarWidth = value and 54 or 188
    local contentX = sidebarWidth

    Tween(sidebar, TWEEN_SMOOTH, {
        Size = UDim2.new(0, sidebarWidth, 1, -58),
    })

    Tween(content, TWEEN_SMOOTH, {
        Position = UDim2.fromOffset(contentX, 58),
        Size = UDim2.new(1, -contentX, 1, -58),
    })

    if collapseButton then
        Tween(collapseButton, TWEEN_FAST, {
            Rotation = value and 90 or 0,
        })
    end

    if searchBox then
        searchBox.Visible = not value
    end

    if self.ConfigButton then
        self.ConfigButton.Visible = not value
    end

    -- Footer belongs to the expanded navigation pane and should disappear
    -- with it instead of remaining under the collapsed rail.
    if self.NavigationFooter then
        Tween(self.NavigationFooter, TWEEN_FAST, {
            TextTransparency = value and 1 or 0,
        })
    end

    if self.NavigationVersion then
        Tween(self.NavigationVersion, TWEEN_FAST, {
            TextTransparency = value and 1 or 0,
        })
    end

    if searchResults then
        searchResults.Visible = (not value) and searchResults.Visible and (self.NavigationSearchText ~= "")
    end

    if self.NavigationTitle then
        Tween(self.NavigationTitle, TWEEN_FAST, {
            TextTransparency = value and 1 or 0,
        })
    end

    if self.NavigationRail then
        self.NavigationRail.Visible = value
    end

    if self.NavigationAccent then
        Tween(self.NavigationAccent, TWEEN_FAST, {
            Size = value and UDim2.fromOffset(18, 2) or UDim2.fromOffset(34, 2),
        })
    end

    if value then
        -- Fade labels/icons first; only hide the container after the fade.
        for _, tab in ipairs(self.Tabs) do
            if tab.Diamond then Tween(tab.Diamond, TWEEN_FAST, {TextTransparency = 1}) end
            if tab.Label then Tween(tab.Label, TWEEN_FAST, {TextTransparency = 1}) end
            if tab.Number then Tween(tab.Number, TWEEN_FAST, {TextTransparency = 1}) end
        end

        task.delay(0.16, function()
            if self.Destroyed or not self.NavigationCollapsed then
                return
            end

            tabContainer.Visible = false
        end)
    else
        tabContainer.Visible = true
        for _, tab in ipairs(self.Tabs) do
            if tab.Diamond then Tween(tab.Diamond, TWEEN_FAST, {TextTransparency = 0}) end
            if tab.Label then Tween(tab.Label, TWEEN_FAST, {TextTransparency = 0}) end
            if tab.Number then Tween(tab.Number, TWEEN_FAST, {TextTransparency = 0}) end
        end
    end
end

--//==============================================================
--// Section
--//==============================================================

function TabMethods:AddSection(name: string)
    local section = {}

    section.Library = self.Library
    section.Tab = self
    section.Name = name
    section.Components = {}
    section.Collapsed = false

    local frame = New("Frame", {
        Name = name,

        Parent = self.Page,

        BackgroundColor3 = self.Library.Theme.Panel,

        BackgroundTransparency = 0.12,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 0),

        AutomaticSize = Enum.AutomaticSize.Y,

        LayoutOrder = #self.Sections + 1,

        ZIndex = 13,
    })

    section.Frame = frame

    AddStroke(
        frame,
        self.Library.Theme.BorderDim,
        0.1,
        1
    )

    AddAngularCorners(frame)

    --==========================================================
    -- Header
    --==========================================================

    local header = New("Frame", {
        Parent = frame,

        BackgroundTransparency = 1,

        Size = UDim2.new(1, 0, 0, 54),

        ZIndex = 14,
    })

    local collapseButton = New("TextButton", {
        Name = "Collapse",
        Parent = header,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -42, 0, 10),
        Size = UDim2.fromOffset(28, 34),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 18,
    })

    -- Draw the chevron from Frames instead of a font glyph. This avoids
    -- the square/tofu icon issue on fonts that do not contain ▾/⌄.
    local chevronLeft = New("Frame", {
        Parent = collapseButton,
        BackgroundColor3 = self.Library.Theme.TextMuted,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, 15),
        Size = UDim2.fromOffset(8, 2),
        Rotation = 45,
        ZIndex = 19,
    })
    local chevronRight = New("Frame", {
        Parent = collapseButton,
        BackgroundColor3 = self.Library.Theme.TextMuted,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(13, 15),
        Size = UDim2.fromOffset(8, 2),
        Rotation = -45,
        ZIndex = 19,
    })
    section.ChevronLeft = chevronLeft
    section.ChevronRight = chevronRight
    section.CollapseButton = collapseButton
    section.Header = header

    local headerButton = New("TextButton", {
        Name = "HeaderButton",
        Parent = header,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.new(1, 0, 1, 0),
        Text = "",
        AutoButtonColor = false,
        ZIndex = 15,
    })
    section.HeaderButton = headerButton

    -- Toggle the section from anywhere on the header. The dedicated
    -- chevron button also has its own connection below so the whole
    -- header remains clickable without relying on a text glyph.
    self.Library:_Connect(headerButton.MouseButton1Click, function()
        section:SetCollapsed(not section.Collapsed)
    end)

    self.Library:_Connect(collapseButton.MouseButton1Click, function()
        section:SetCollapsed(not section.Collapsed)
    end)

    local activeAccent = New("Frame", {
        Name = "Accent",
        Parent = header,
        BackgroundColor3 = self.Library.Theme.Cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, 13),
        Size = UDim2.fromOffset(2, 28),
        ZIndex = 16,
    })
    section.ActiveAccent = activeAccent

    local icon = AddText(
        header,
        "◇",
        18,
        UDim2.fromOffset(16, 0),
        UDim2.fromOffset(30, 54)
    )

    icon.TextColor3 = self.Library.Theme.Cyan
    icon.Font = FONT_BOLD
    icon.ZIndex = 16

    local title = AddText(
        header,
        name:upper(),
        12,
        UDim2.fromOffset(48, 7),
        UDim2.new(1, -70, 0, 22)
    )

    title.Font = FONT_BOLD
    title.ZIndex = 16

    local description = AddText(
        header,
        "CONFIGURATION / PARAMETERS",
        8,
        UDim2.fromOffset(49, 29),
        UDim2.new(1, -70, 0, 16)
    )

    description.TextColor3 = self.Library.Theme.TextMuted
    description.ZIndex = 16

    AddLine(
        header,
        UDim2.fromOffset(16, 53),
        UDim2.new(1, -32, 0, 1),
        self.Library.Theme.BorderDim
    )

    --==========================================================
    -- Components Holder
    --==========================================================

    local holder = New("Frame", {
        Parent = frame,

        BackgroundTransparency = 1,

        Position = UDim2.fromOffset(14, 60),

        Size = UDim2.new(1, -28, 0, 0),

        AutomaticSize = Enum.AutomaticSize.Y,

        ZIndex = 14,
    })

    section.Holder = holder

    -- Keep the last component visually separated from the section bottom edge.
    AddPadding(holder, 0, 0, 0, 7)

    local layout = New("UIListLayout", {
        Parent = holder,

        FillDirection = Enum.FillDirection.Vertical,

        SortOrder = Enum.SortOrder.LayoutOrder,

        Padding = UDim.new(0, 5),
    })

    section.Layout = layout

    if self.EmptyState then
        self.EmptyState.Visible = false
    end

    function section:SetCollapsed(value: boolean)
        value = value and true or false

        if self.Collapsed == value then
            return
        end

        self.Collapsed = value

        -- Section collapse is intentionally immediate. Navigation collapse
        -- keeps its tweened transition, but sections should snap cleanly so
        -- AutomaticSize/UIListLayout cannot push visible text during a tween.
        self.Holder.Visible = not value

        if self.CollapseButton then
            self.CollapseButton.Rotation = value and -90 or 0
            self.CollapseButton.TextColor3 = value
                and self.Library.Theme.Cyan
                or self.Library.Theme.TextMuted
        end

        if self.ActiveAccent then
            self.ActiveAccent.BackgroundTransparency = value and 0.15 or 1
        end

        if self.HeaderButton then
            self.HeaderButton.BackgroundColor3 = self.Library.Theme.CyanDim
            self.HeaderButton.BackgroundTransparency = value and 0.92 or 1
        end

        if self.ChevronLeft and self.ChevronRight then
            self.ChevronLeft.Rotation = value and -45 or 45
            self.ChevronRight.Rotation = value and 45 or -45

            local color = value
                and self.Library.Theme.Cyan
                or self.Library.Theme.TextMuted

            self.ChevronLeft.BackgroundColor3 = color
            self.ChevronRight.BackgroundColor3 = color
        end
    end

    table.insert(self.Sections, section)
    self.Library:_RefreshNavigationSearch()

    return setmetatable(section, {
        __index = Library.SectionMethods,
    })
end

Library.SectionMethods = {}

--//==============================================================
--// Label
--//==============================================================

function Library.SectionMethods:AddLabel(text: string)
    local label = AddText(
        self.Holder,
        text,
        10,
        UDim2.fromOffset(8, 0),
        UDim2.new(1, -16, 0, 28)
    )

    label.TextColor3 = self.Library.Theme.TextSecondary
    label.LayoutOrder = #self.Components + 1

    table.insert(self.Components, label)

    return label
end

--//==============================================================
--// Button
--//==============================================================

--// A thin line between two groups of controls. Section elements are laid
--// out by LayoutOrder, so a divider is just another component in the list.
function Library.SectionMethods:AddDivider()
    local divider = New("Frame", {
        Parent = self.Holder,

        BackgroundTransparency = 1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 7),

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    AddLine(
        divider,
        UDim2.new(0, 0, 0.5, 0),
        UDim2.new(1, 0, 0, 1),
        self.Library.Theme.Border
    )

    table.insert(self.Components, divider)

    return divider
end

function Library.SectionMethods:AddButton(name: string, callback, description: string?)
    local descriptionText = self.Library:_GetDescription(name, description)
    local height = descriptionText and 42 + DESCRIPTION_EXTRA or 42

    local button = New("TextButton", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, height),

        Text = "",

        AutoButtonColor = false,

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    local stroke = AddStroke(
        button,
        self.Library.Theme.BorderDim,
        0.25,
        1
    )

    AddHoverHighlight(self.Library, button, stroke)

    local diamond = AddText(
        button,
        "◇",
        13,
        UDim2.fromOffset(13, 0),
        UDim2.new(0, 22, 1, 0)
    )

    diamond.TextColor3 = self.Library.Theme.Cyan

    local label = AddText(
        button,
        name:upper(),
        10,
        UDim2.fromOffset(42, 0),
        UDim2.new(1, -60, 1, 0)
    )

    label.Font = FONT_BOLD

    if descriptionText then
        label.Position = UDim2.fromOffset(42, 8)
        label.Size = UDim2.new(1, -70, 0, 18)
        AddDescription(self.Library, button, descriptionText, UDim2.fromOffset(42, 27), UDim2.new(1, -70, 0, 14))
    end

    local arrow = AddText(
        button,
        "›",
        18,
        UDim2.new(1, -34, 0, 0),
        UDim2.new(0, 24, 1, 0)
    )

    arrow.TextColor3 = self.Library.Theme.TextMuted
    arrow.TextXAlignment = Enum.TextXAlignment.Right

    self.Library:_Connect(button.MouseEnter, function()
        Tween(button, TWEEN_FAST, {
            BackgroundColor3 = self.Library.Theme.ElementHover,
        })

        Tween(diamond, TWEEN_FAST, {
            TextColor3 = self.Library.Theme.White,
        })

        Tween(arrow, TWEEN_FAST, {
            TextColor3 = self.Library.Theme.Cyan,
        })
    end)

    self.Library:_Connect(button.MouseLeave, function()
        Tween(button, TWEEN_FAST, {
            BackgroundColor3 = self.Library.Theme.Element,
        })

        Tween(diamond, TWEEN_FAST, {
            TextColor3 = self.Library.Theme.Cyan,
        })

        Tween(arrow, TWEEN_FAST, {
            TextColor3 = self.Library.Theme.TextMuted,
        })
    end)

    self.Library:_Connect(button.MouseButton1Click, function()
        if callback then
            callback()
        end
    end)

    table.insert(self.Components, button)

    return button
end

--//==============================================================
--// Toggle
--//==============================================================

function Library.SectionMethods:AddToggle(name: string, default: boolean?, callback, description: string?)
    local component = {}
    component.Library = self.Library

    component.Value = default == true
    component.Callback = callback

    local descriptionText = self.Library:_GetDescription(name, description)
    local height = descriptionText and 42 + DESCRIPTION_EXTRA or 42

    local button = New("TextButton", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, height),

        Text = "",

        AutoButtonColor = false,

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = button

    AddHoverHighlight(self.Library, button, AddStroke(button, self.Library.Theme.BorderDim, 0.25, 1))

    local label = AddText(
        button,
        name:upper(),
        10,
        UDim2.fromOffset(13, 0),
        UDim2.new(1, -130, 1, 0)
    )

    label.Font = FONT_BOLD

    if descriptionText then
        label.Position = UDim2.fromOffset(13, 8)
        label.Size = UDim2.new(1, -130, 0, 18)
        AddDescription(self.Library, button, descriptionText, UDim2.fromOffset(13, 27), UDim2.new(1, -130, 0, 14))
    end

    -- Toggle background
    local toggle = New("Frame", {
        Parent = button,

        BackgroundColor3 = self.Library.Theme.PanelLight,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -68, 0.5, -10),

        Size = UDim2.fromOffset(42, 20),

        ZIndex = 16,
    })

    AddStroke(toggle, self.Library.Theme.Border, 0.15, 1)
    AddCorner(toggle, 30)

    local knob = New("Frame", {
        Parent = toggle,

        BackgroundColor3 = self.Library.Theme.TextMuted,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(3, 3),

        Size = UDim2.fromOffset(14, 14),

        ZIndex = 17,
    })

    AddCorner(knob, 30)

    local state = AddText(
        button,
        component.Value and "ON" or "OFF",
        8,
        UDim2.new(1, -116, 0, 0),
        UDim2.new(0, 40, 1, 0)
    )

    state.TextXAlignment = Enum.TextXAlignment.Right
    state.Font = FONT_BOLD

    function component:Set(value: boolean, fireCallback: boolean?)
        self.Value = value

        state.Text = value and "ON" or "OFF"

        if value then
            Tween(toggle, TWEEN_NORMAL, {
                BackgroundColor3 = self.Library.Theme.CyanDark,
            })

            Tween(knob, TWEEN_NORMAL, {
                Position = UDim2.new(1, -17, 0, 3),
                BackgroundColor3 = self.Library.Theme.Cyan,
            })

            Tween(state, TWEEN_NORMAL, {
                TextColor3 = self.Library.Theme.Cyan,
            })
        else
            Tween(toggle, TWEEN_NORMAL, {
                BackgroundColor3 = self.Library.Theme.PanelLight,
            })

            Tween(knob, TWEEN_NORMAL, {
                Position = UDim2.fromOffset(3, 3),
                BackgroundColor3 = self.Library.Theme.TextMuted,
            })

            Tween(state, TWEEN_NORMAL, {
                TextColor3 = self.Library.Theme.TextMuted,
            })
        end

        if fireCallback ~= false and self.Callback then
            self.Callback(value)
        end
    end

    function component:Get()
        return self.Value
    end

    self.Library:_Connect(button.MouseButton1Click, function()
        component:Set(not component.Value)
    end)

    self.Library:_Connect(button.MouseEnter, function()
        Tween(button, TWEEN_FAST, {
            BackgroundColor3 = self.Library.Theme.ElementHover,
        })
    end)

    self.Library:_Connect(button.MouseLeave, function()
        Tween(button, TWEEN_FAST, {
            BackgroundColor3 = self.Library.Theme.Element,
        })
    end)

    table.insert(self.Components, component)

    component:Set(component.Value, false)

    return component
end

--//==============================================================
--// Slider
--//==============================================================

function Library.SectionMethods:AddSlider(
    name: string,
    default: number,
    minimum: number,
    maximum: number,
    callback,
    description: string?
)
    local component = {}
    component.Library = self.Library

    component.Value = math.clamp(default, minimum, maximum)
    component.Minimum = minimum
    component.Maximum = maximum
    component.Callback = callback

    local descriptionText = self.Library:_GetDescription(name, description)
    --// The track moves down to make room for the description.
    local trackY = descriptionText and 34 + DESCRIPTION_EXTRA or 34

    local frame = New("Frame", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, trackY + 24),

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = frame

    local label = AddText(
        frame,
        name:upper(),
        9,
        UDim2.fromOffset(13, 5),
        UDim2.fromOffset(180, 20)
    )

    label.Font = FONT_BOLD

    local valueLabel = AddText(
        frame,
        tostring(component.Value),
        9,
        UDim2.new(1, -75, 5, 0),
        UDim2.fromOffset(60, 20)
    )

    valueLabel.AnchorPoint = Vector2.new(0, 0)
    valueLabel.Position = UDim2.new(1, -75, 0, 5)
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right
    valueLabel.TextColor3 = self.Library.Theme.Cyan
    valueLabel.Font = FONT_BOLD

    if descriptionText then
        AddDescription(self.Library, frame, descriptionText, UDim2.fromOffset(13, 24), UDim2.new(1, -28, 0, 14))
    end

    -- Track
    local track = New("Frame", {
        Parent = frame,

        BackgroundColor3 = self.Library.Theme.PanelLight,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(14, trackY),

        Size = UDim2.new(1, -28, 0, 5),

        ZIndex = 16,
    })

    AddCorner(track, 2)

    local fill = New("Frame", {
        Parent = track,

        BackgroundColor3 = self.Library.Theme.Cyan,

        BorderSizePixel = 0,

        Size = UDim2.fromScale(0, 1),

        ZIndex = 17,
    })

    AddCorner(fill, 2)

    local knob = New("Frame", {
        Parent = track,

        BackgroundColor3 = self.Library.Theme.White,

        BorderSizePixel = 0,

        AnchorPoint = Vector2.new(0.5, 0.5),

        Position = UDim2.fromScale(0, 0.5),

        Size = UDim2.fromOffset(10, 10),

        ZIndex = 18,
    })

    AddCorner(knob, 2)

    local dragging = false

    local function UpdateFromX(x: number)
        local relative = math.clamp(
            (x - track.AbsolutePosition.X) / track.AbsoluteSize.X,
            0,
            1
        )

        local value = minimum + (maximum - minimum) * relative

        if math.floor(minimum) == minimum
            and math.floor(maximum) == maximum then
            value = math.round(value)
        else
            value = math.round(value * 100) / 100
        end

        component:Set(value)
    end

    function component:Set(value: number, fireCallback: boolean?)
        self.Value = math.clamp(value, self.Minimum, self.Maximum)

        local percent =
            (self.Value - self.Minimum)
            / (self.Maximum - self.Minimum)

        valueLabel.Text = tostring(self.Value)

        Tween(fill, TWEEN_FAST, {
            Size = UDim2.fromScale(percent, 1),
        })

        Tween(knob, TWEEN_FAST, {
            Position = UDim2.fromScale(percent, 0.5),
        })

        if fireCallback ~= false and self.Callback then
            self.Callback(self.Value)
        end
    end

    function component:Get()
        return self.Value
    end

    self.Library:_Connect(track.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            dragging = true
            UpdateFromX(input.Position.X)
        end
    end)

    self.Library:_Connect(UserInputService.InputChanged, function(input)
        if not dragging then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then

            UpdateFromX(input.Position.X)
        end
    end)

    self.Library:_Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            dragging = false
        end
    end)

    table.insert(self.Components, component)

    component:Set(component.Value, false)

    return component
end

--//==============================================================
--// Textbox
--//==============================================================

function Library.SectionMethods:AddTextbox(name: string, default: string?, callback, description: string?)
    local component = {}
    component.Library = self.Library

    component.Value = default or ""
    component.Callback = callback

    local descriptionText = self.Library:_GetDescription(name, description)
    local height = descriptionText and 42 + DESCRIPTION_EXTRA or 42

    local frame = New("Frame", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, height),

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = frame

    local label = AddText(
        frame,
        name:upper(),
        9,
        UDim2.fromOffset(13, 0),
        UDim2.new(1, -235, 1, 0)
    )

    label.Font = FONT_BOLD

    if descriptionText then
        label.Position = UDim2.fromOffset(13, 8)
        label.Size = UDim2.new(1, -235, 0, 18)
        AddDescription(self.Library, frame, descriptionText, UDim2.fromOffset(13, 27), UDim2.new(1, -235, 0, 14))
    end

    local box = New("TextBox", {
        Parent = frame,

        BackgroundColor3 = self.Library.Theme.PanelLight,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -220, 0.5, -14),

        Size = UDim2.fromOffset(205, 28),

        Text = component.Value,

        PlaceholderText = "ENTER VALUE",

        PlaceholderColor3 = self.Library.Theme.TextMuted,

        TextColor3 = self.Library.Theme.Text,

        TextSize = 11,

        Font = FONT_REGULAR,

        ClearTextOnFocus = false,

        TextXAlignment = Enum.TextXAlignment.Left,

        ZIndex = 16,
    })

    AddPadding(box, 9, 9, 0, 0)
    AddHoverHighlight(self.Library, box, AddStroke(box, self.Library.Theme.BorderDim, 0.15, 1))

    component.TextBox = box

    function component:Set(value: string, fireCallback: boolean?)
        self.Value = value
        box.Text = value

        if self.Callback and fireCallback ~= false then
            self.Callback(value)
        end
    end

    function component:Get()
        return self.Value
    end

    self.Library:_Connect(box.FocusLost, function()
        component:Set(box.Text)
    end)

    table.insert(self.Components, component)

    return component
end

--//==============================================================
--// Dropdown
--//==============================================================

function Library.SectionMethods:AddDropdown(
    name: string,
    options: {string},
    callback,
    description: string?
)
    local component = {}
    component.Library = self.Library

    component.Options = options
    component.Value = options[1]
    component.Callback = callback
    component.IsOpen = false

    --// Every connection this dropdown makes, so Destroy can cut them.
    --// Dropdowns rebuilt for new options (player lists, zone pickers...)
    --// used to leave a RenderStepped and an InputBegan listener behind
    --// each time, piling up for as long as the script ran.
    local connections = {}

    local function Connect(signal, handler)
        local connection = self.Library:_Connect(signal, handler)
        table.insert(connections, connection)
        return connection
    end

    local descriptionText = self.Library:_GetDescription(name, description)
    local height = descriptionText and 48 + DESCRIPTION_EXTRA or 48

    local frame = New("Frame", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, height),

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = frame

    local label = AddText(
        frame,
        name:upper(),
        9,
        UDim2.fromOffset(13, 0),
        UDim2.new(1, -245, 1, 0)
    )

    label.Font = FONT_BOLD

    if descriptionText then
        label.Position = UDim2.fromOffset(13, 10)
        label.Size = UDim2.new(1, -245, 0, 18)
        AddDescription(self.Library, frame, descriptionText, UDim2.fromOffset(13, 29), UDim2.new(1, -245, 0, 14))
    end

    local button = New("TextButton", {
        Parent = frame,

        BackgroundColor3 = self.Library.Theme.PanelLight,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -230, 0.5, -16),

        Size = UDim2.fromOffset(215, 32),

        Text = "",

        AutoButtonColor = false,

        ZIndex = 16,
    })

    AddHoverHighlight(self.Library, button, AddStroke(button, self.Library.Theme.BorderDim, 0.15, 1))

    local valueLabel = AddText(
        button,
        component.Value or "",
        9,
        UDim2.fromOffset(10, 0),
        UDim2.new(1, -40, 1, 0)
    )

    valueLabel.TextColor3 = self.Library.Theme.Text

    local arrow = AddText(
        button,
        "›",
        18,
        UDim2.new(1, -28, 0, 0),
        UDim2.fromOffset(20, 32)
    )

    arrow.TextXAlignment = Enum.TextXAlignment.Right
    arrow.TextColor3 = self.Library.Theme.Cyan
    arrow.Rotation = 0

    local MAX_VISIBLE_OPTIONS = 5
    local OPTION_HEIGHT = 32
    local OPTION_PADDING = 2

    local popup = New("TextButton", {
        --// A button, so a click on it stops here instead of reaching the UI
        --// underneath; it draws like a frame.
        Text = "",
        AutoButtonColor = false,
        Name = "Dropdown",

        Parent = self.Library.Overlay,

        BackgroundColor3 = self.Library.Theme.Panel,

        BorderSizePixel = 0,

        Size = UDim2.fromOffset(215, 0),

        Visible = false,

        ZIndex = 200,

        ClipsDescendants = true,
    })

    AddStroke(popup, self.Library.Theme.CyanDark, 0.1, 1)
    AddAngularCorners(popup, self.Library.Theme.Cyan)

    local list = New("ScrollingFrame", {
        Parent = popup,

        BackgroundTransparency = 1,

        BorderSizePixel = 0,

        Position = UDim2.fromOffset(0, 0),

        Size = UDim2.fromScale(1, 1),

        CanvasSize = UDim2.fromOffset(0, 0),

        AutomaticCanvasSize = Enum.AutomaticSize.Y,

        ScrollBarThickness = 3,

        ScrollBarImageColor3 = self.Library.Theme.CyanDark,

        ZIndex = 201,
    })

    component.List = list

    AddPadding(list, 4, 4, 4, 4)

    local layout = New("UIListLayout", {
        Parent = list,

        SortOrder = Enum.SortOrder.LayoutOrder,

        Padding = UDim.new(0, OPTION_PADDING),
    })

    -- Height the popup should be: fits every option up to MAX_VISIBLE_OPTIONS, then scrolls.
    local visibleCount = math.min(#options, MAX_VISIBLE_OPTIONS)
    local popupHeight = (visibleCount * OPTION_HEIGHT)
        + (math.max(visibleCount - 1, 0) * OPTION_PADDING)
        + 8 -- top/bottom padding

    popup.Size = UDim2.fromOffset(215, popupHeight)
    popup:SetAttribute("DropdownDesiredHeight", popupHeight)

    local optionRows = {}

    for index, option in ipairs(options) do
        local optionButton = New("TextButton", {
            Parent = list,

            BackgroundColor3 = self.Library.Theme.Element,

            BackgroundTransparency = 1,

            BorderSizePixel = 0,

            Size = UDim2.new(1, 0, 0, OPTION_HEIGHT),

            Text = "",

            AutoButtonColor = false,

            LayoutOrder = index,

            ZIndex = 202,
        })

        local check = AddText(
            optionButton,
            "✓",
            9,
            UDim2.fromOffset(8, 0),
            UDim2.fromOffset(16, OPTION_HEIGHT)
        )

        check.TextColor3 = self.Library.Theme.Cyan
        check.Font = FONT_BOLD
        check.TextTransparency = 1

        local optionLabel = AddText(
            optionButton,
            option,
            9,
            UDim2.fromOffset(24, 0),
            UDim2.new(1, -34, 1, 0)
        )

        optionLabel.TextColor3 = self.Library.Theme.TextSecondary

        optionRows[option] = {
            Button = optionButton,
            Label = optionLabel,
            Check = check,
        }

        Connect(optionButton.MouseEnter, function()
            Tween(optionButton, TWEEN_FAST, {
                BackgroundColor3 = self.Library.Theme.CyanDim,
                BackgroundTransparency = 0.35,
            })

            Tween(optionLabel, TWEEN_FAST, {
                TextColor3 = self.Library.Theme.White,
            })
        end)

        Connect(optionButton.MouseLeave, function()
            if component.Value == option then
                return
            end

            Tween(optionButton, TWEEN_FAST, {
                BackgroundTransparency = 1,
            })

            Tween(optionLabel, TWEEN_FAST, {
                TextColor3 = self.Library.Theme.TextSecondary,
            })
        end)

        Connect(optionButton.MouseButton1Click, function()
            component:Set(option)
            component:Close()
        end)
    end

    component.Popup = popup
    --// Option name -> {Button, Label, Check}, for callers that restyle rows.
    component.OptionRows = optionRows

    local function RefreshSelection()
        for option, row in pairs(optionRows) do
            local selected = option == component.Value

            row.Label.TextColor3 = selected
                and self.Library.Theme.White
                or self.Library.Theme.TextSecondary

            row.Check.TextTransparency = selected and 0 or 1

            row.Button.BackgroundTransparency = selected and 0.65 or 1
            row.Button.BackgroundColor3 = selected
                and self.Library.Theme.CyanDim
                or self.Library.Theme.Element
        end
    end

    --// Pass false as the second argument to update the shown value without
    --// running the callback, the same as Toggle and Slider. Callers already
    --// passed false expecting that; ignoring it caused callback loops.
    function component:Set(value: string, fireCallback: boolean?)
        self.Value = value
        valueLabel.Text = value

        RefreshSelection()

        if self.Callback and fireCallback ~= false then
            self.Callback(value)
        end
    end

    function component:Get()
        return self.Value
    end

    function component:Open()
        if self.IsOpen then
            return
        end

        self.Library:_CloseDropdowns(self)

        self.IsOpen = true
        popup.Visible = true

        --// Scroll to the selected option so it is visible on open. The list
        --// layout never sets Position, so its place is counted from the
        --// shown rows above it (hidden rows, such as fonts that failed to
        --// load, take no space).
        local row = optionRows[self.Value]

        if row then
            local shownBefore = 0

            for _, option in ipairs(options) do
                if option == self.Value then
                    break
                end

                local other = optionRows[option]

                if other and other.Button.Visible then
                    shownBefore += 1
                end
            end

            local rowTop = 4 + shownBefore * (OPTION_HEIGHT + OPTION_PADDING)
            local target = math.max(0, rowTop - (popupHeight / 2) + (OPTION_HEIGHT / 2))

            list.CanvasPosition = Vector2.new(0, target)
        end

        -- Position immediately, then keep the popup attached to the
        -- dropdown button while the root ScrollingFrame is moving.
        self.Library:_PositionDropdown(button, popup)

        -- Remember every ScrollingFrame between the button and the UI root.
        -- The nearest one is the page and is allowed to move (the popup
        -- follows). If one further out moves, close the dropdown
        -- because its content has changed independently from the anchor.
        component.RootScrollingFrame = nil
        component.ScrollingParents = {}

        local ancestor = button.Parent
        while ancestor do
            if ancestor:IsA("ScrollingFrame") then
                if not component.RootScrollingFrame then
                    component.RootScrollingFrame = ancestor
                end

                table.insert(component.ScrollingParents, {
                    Object = ancestor,
                    Position = ancestor.AbsolutePosition,
                    Size = ancestor.AbsoluteSize,
                    CanvasPosition = ancestor.CanvasPosition,
                })
            end

            ancestor = ancestor.Parent
        end

        arrow.Text = "›"
        arrow.Rotation = 90
    end

    function component:Close()
        if not self.IsOpen then
            return
        end

        self.IsOpen = false
        popup.Visible = false

        arrow.Text = "›"
        arrow.Rotation = 0
    end

    Connect(button.MouseButton1Click, function()
        if component.IsOpen then
            component:Close()
        else
            component:Open()
        end
    end)

    -- The popup lives outside the ScrollingFrame, so Roblox will not move it
    -- automatically when the page scrolls. Keep it locked to the button.
    Connect(RunService.RenderStepped, function()
        if not component.IsOpen or not popup.Visible then
            return
        end

        if not button:IsDescendantOf(self.Library.ScreenGui) then
            component:Close()
            return
        end

        for _, state in ipairs(component.ScrollingParents) do
            local scrollingFrame = state.Object

            if not scrollingFrame:IsDescendantOf(self.Library.ScreenGui) then
                component:Close()
                return
            end

            if scrollingFrame == component.RootScrollingFrame then
                --// The page may move: touch momentum and elastic bounce
                --// keep scrolling it after a swipe, and a page whose
                --// content shrinks clamps its CanvasPosition. Closing on
                --// that shut a dropdown the frame after it opened on long
                --// pages. The popup follows the button instead, and closes
                --// only once the button has left the page's visible area.
                local pageTop = scrollingFrame.AbsolutePosition.Y
                local pageBottom = pageTop + scrollingFrame.AbsoluteSize.Y
                local buttonTop = button.AbsolutePosition.Y

                if buttonTop + button.AbsoluteSize.Y < pageTop or buttonTop > pageBottom then
                    component:Close()
                    return
                end
            else
                local positionChanged = scrollingFrame.AbsolutePosition ~= state.Position
                local sizeChanged     = scrollingFrame.AbsoluteSize ~= state.Size
                local canvasChanged   = scrollingFrame.CanvasPosition ~= state.CanvasPosition

                --// A scroll further out moved: the button's place in it
                --// changed, so close rather than follow.
                if positionChanged or sizeChanged or canvasChanged then
                    component:Close()
                    return
                end
            end
        end

        self.Library:_PositionDropdown(button, popup)
    end)

    --// A click or tap outside closes it. Whether a press was inside is told
    --// by the GUI's own InputBegan on the button, the list and every option
    --// (Roblox's hit test), not by comparing the pointer position with
    --// AbsolutePosition: that comparison is off by the top bar inset or the
    --// ScreenInsets on some clients, so a press on an option counted as
    --// outside, closed the list on mouse-down, and the option's click never
    --// fired. The outside check waits a frame so every InputBegan of the
    --// same press has run first.
    local pressedInside = false

    local function IsPress(input)
        return input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
    end

    --// Only while open, so the press that opens it leaves nothing behind.
    local function MarkPressInside(input)
        if component.IsOpen and IsPress(input) then
            pressedInside = true
        end
    end

    Connect(button.InputBegan, MarkPressInside)
    Connect(popup.InputBegan, MarkPressInside)
    Connect(list.InputBegan, MarkPressInside)

    for _, row in pairs(optionRows) do
        Connect(row.Button.InputBegan, MarkPressInside)
    end

    Connect(UserInputService.InputBegan, function(input)
        if not component.IsOpen or not IsPress(input) then
            return
        end

        task.delay(0, function()
            local wasInside = pressedInside
            pressedInside = false

            if not wasInside and component.IsOpen then
                component:Close()
            end
        end)
    end)

    RefreshSelection()

    local destroyed = false

    --// Disconnects everything, removes the popup and drops the dropdown
    --// from the library. Runs once, from Destroy or when the frame is
    --// destroyed (what callers that rebuild a dropdown do).
    local function Cleanup()
        if destroyed then
            return
        end

        destroyed = true
        component.IsOpen = false

        local library = component.Library
        local libraryConnections = library._connections

        for _, connection in ipairs(connections) do
            connection:Disconnect()

            local index = table.find(libraryConnections, connection)

            if index then
                table.remove(libraryConnections, index)
            end
        end

        table.clear(connections)

        local index = table.find(library._dropdowns, component)

        if index then
            table.remove(library._dropdowns, index)
        end

        popup:Destroy()
    end

    function component:Destroy()
        Cleanup()
        frame:Destroy()
    end

    frame.Destroying:Connect(Cleanup)

    table.insert(self.Library._dropdowns, component)
    table.insert(self.Components, component)

    return component
end

--//==============================================================
--// Keybind
--//==============================================================

function Library.SectionMethods:AddKeybind(
    name: string,
    defaultKey: Enum.KeyCode,
    callback
)
    local component = {}
    component.Library = self.Library

    component.Key = defaultKey
    component.Callback = callback
    component.Listening = false

    local frame = New("Frame", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 42),

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = frame

    local label = AddText(
        frame,
        name:upper(),
        9,
        UDim2.fromOffset(13, 0),
        UDim2.new(1, -150, 1, 0)
    )

    label.Font = FONT_BOLD

    local keyButton = New("TextButton", {
        Parent = frame,

        BackgroundColor3 = self.Library.Theme.PanelLight,

        BorderSizePixel = 0,

        Position = UDim2.new(1, -125, 0, 7),

        Size = UDim2.fromOffset(110, 28),

        Text = defaultKey.Name,

        TextColor3 = self.Library.Theme.Cyan,

        TextSize = 11,

        Font = FONT_BOLD,

        AutoButtonColor = false,

        ZIndex = 16,
    })

    AddStroke(keyButton, self.Library.Theme.BorderDim, 0.15, 1)

    component.Button = keyButton

    function component:SetKey(key: Enum.KeyCode)
        self.Key = key
        keyButton.Text = key.Name
        self.Listening = false
    end

    function component:GetKey()
        return self.Key
    end

    self.Library:_Connect(keyButton.MouseButton1Click, function()
        component.Listening = true
        keyButton.Text = "PRESS KEY"
        keyButton.TextColor3 = self.Library.Theme.Warning
    end)

    self.Library:_Connect(UserInputService.InputBegan, function(input, processed)
        if processed then
            return
        end

        if component.Listening then
            if input.KeyCode ~= Enum.KeyCode.Unknown then
                component:SetKey(input.KeyCode)

                keyButton.TextColor3 = self.Library.Theme.Cyan
            end

            return
        end

        if input.KeyCode == component.Key then
            if component.Callback then
                component.Callback()
            end
        end
    end)

    table.insert(self.Components, component)

    return component
end

--//==============================================================
--// Priority
--//==============================================================

--// options (all optional):
--//   Values       true to give every row an editable number (e.g. a wait time)
--//   ValueLabel   short caption shown in the header, e.g. "WAIT (S)"
--//   Default      value for rows added without one (default 0)
--//   Min, Max     clamp for typed values (default 0 .. math.huge)
--//   Checks       true to give every row a checkbox (e.g. "jump here")
--//   CheckLabel   short caption for the checkbox, shown in the header
--//   Draggable    false to turn off drag-to-reorder (default on)
--//
--// Rows are reordered by dragging the name. The drop is applied as a run of
--// MoveUp / MoveDown calls, so any override a caller installed on those two
--// still sees every step.
function Library.SectionMethods:AddPriority(
    name: string,
    values: {string}?,
    options: {[string]: any}?
)
    options = options or {}

    local component = {}
    component.Library = self.Library

    component.Priority = {}
    component.Values = {}
    component.Checks = {}

    local hasValues = options.Values == true
    local hasChecks = options.Checks == true
    local draggable = options.Draggable ~= false
    local defaultValue = tonumber(options.Default) or 0
    local minValue = tonumber(options.Min) or 0
    local maxValue = tonumber(options.Max) or math.huge

    local ROW_HEIGHT = 34
    local ROW_GAP = 3
    local ROW_STRIDE = ROW_HEIGHT + ROW_GAP

    local function ClampValue(value)
        return math.clamp(tonumber(value) or defaultValue, minValue, maxValue)
    end

    --// Keeps Values the same length as Priority.
    local function FitValues()
        for index = 1, #component.Priority do
            component.Values[index] = ClampValue(component.Values[index])
        end

        for index = #component.Values, #component.Priority + 1, -1 do
            component.Values[index] = nil
        end

        --// Checks the same, as true/false.
        for index = 1, #component.Priority do
            component.Checks[index] = component.Checks[index] == true
        end

        for index = #component.Checks, #component.Priority + 1, -1 do
            component.Checks[index] = nil
        end
    end

    if values then
        for _, value in ipairs(values) do
            table.insert(component.Priority, value)
        end
    end

    FitValues()

    local frame = New("Frame", {
        Parent = self.Holder,

        BackgroundColor3 = self.Library.Theme.Element,

        BackgroundTransparency = 0.1,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 0),

        AutomaticSize = Enum.AutomaticSize.Y,

        LayoutOrder = #self.Components + 1,

        ZIndex = 15,
    })

    component.Frame = frame

    AddStroke(
        frame,
        self.Library.Theme.BorderDim,
        0.15,
        1
    )

    AddPadding(frame, 10, 10, 10, 10)

    -- Header
    local header = New("Frame", {
        Parent = frame,

        BackgroundTransparency = 1,

        Size = UDim2.new(1, 0, 0, 36),

        ZIndex = 16,
    })

    local title = AddText(
        header,
        name:upper(),
        10,
        UDim2.fromOffset(0, 0),
        UDim2.new(1, 0, 0, 20)
    )

    title.Font = FONT_BOLD

    --// The description (options.Description or the map) replaces the
    --// generic first part of the subtitle.
    local descriptionText = self.Library:_GetDescription(name, options.Description)
    local subtitleText = descriptionText and string.upper(descriptionText) or "TARGET PRIORITY LIST"

    if draggable then
        subtitleText = subtitleText .. "  ·  DRAG TO REORDER"
    end

    if hasValues and options.ValueLabel then
        subtitleText = subtitleText .. "  ·  " .. tostring(options.ValueLabel):upper()
    end

    if hasChecks and options.CheckLabel then
        subtitleText = subtitleText .. "  ·  ☐ " .. tostring(options.CheckLabel):upper()
    end

    local subtitle = AddText(
        header,
        subtitleText,
        7,
        UDim2.fromOffset(0, 18),
        UDim2.new(1, 0, 0, 15)
    )

    subtitle.TextColor3 = self.Library.Theme.TextMuted
    subtitle.TextTruncate = Enum.TextTruncate.AtEnd

    -- List
    local list = New("Frame", {
        Parent = frame,

        BackgroundTransparency = 1,

        Position = UDim2.fromOffset(0, 36),

        Size = UDim2.new(1, 0, 0, 0),

        AutomaticSize = Enum.AutomaticSize.Y,

        ZIndex = 16,
    })

    New("UIListLayout", {
        Parent = list,

        FillDirection = Enum.FillDirection.Vertical,

        SortOrder = Enum.SortOrder.LayoutOrder,

        Padding = UDim.new(0, ROW_GAP),
    })

    component.List = list

    --// Drop marker. Lives on the outer frame, not in the list, so the list
    --// layout does not move it around.
    local dropIndicator = New("Frame", {
        Parent = frame,

        BackgroundColor3 = self.Library.Theme.Cyan,

        BorderSizePixel = 0,

        Size = UDim2.new(1, 0, 0, 2),

        Visible = false,

        ZIndex = 20,
    })

    local rows = {}

    --// Active drag, or nil. Index is the row being dragged, Target where it
    --// would land, StartY the pointer height when the drag began.
    local dragState = nil

    --// Space kept clear on the right of each row for its buttons. The
    --// checkbox, when there is one, sits left of the value box.
    local CHECK_SIZE = 22
    local valueReserve = hasValues and 190 or 130
    local checkX = -(valueReserve + CHECK_SIZE - 2)
    local rightReserve = hasChecks and valueReserve + CHECK_SIZE + 4 or valueReserve

    local function TargetIndexFor(pointerY)
        local offset = pointerY - dragState.StartY
        local target = dragState.Index + math.floor(offset / ROW_STRIDE + 0.5)

        return math.clamp(target, 1, #component.Priority)
    end

    local function ShowDropIndicator(target)
        if target == dragState.Index then
            dropIndicator.Visible = false
            return
        end

        --// Above the target row when moving up, below it when moving down.
        local slot = target < dragState.Index and target - 1 or target
        dropIndicator.Position = UDim2.fromOffset(0, 36 + slot * ROW_STRIDE - ROW_GAP)
        dropIndicator.Visible = true
    end

    local function FinishDrag()
        if not dragState then
            return
        end

        local from = dragState.Index
        local target = dragState.Target

        dragState = nil
        dropIndicator.Visible = false

        if not target or target == from then
            --// Nothing moved, but the dragged row is still highlighted.
            component:_Refresh()
            return
        end

        --// Step by index, not by value: an override may relabel every row
        --// after each step (waypoint labels include their number).
        if target < from then
            for index = from, target + 1, -1 do
                local value = component.Priority[index]

                if value == nil then
                    break
                end

                component:MoveUp(value)
            end
        else
            for index = from, target - 1 do
                local value = component.Priority[index]

                if value == nil then
                    break
                end

                component:MoveDown(value)
            end
        end

        component:_Refresh()
    end

    local function Refresh()
        for _, row in pairs(rows) do
            row:Destroy()
        end

        table.clear(rows)
        FitValues()

        for index, value in ipairs(component.Priority) do
            local row = New("Frame", {
                Parent = list,

                BackgroundColor3 = self.Library.Theme.PanelLight,

                BackgroundTransparency = 0.25,

                BorderSizePixel = 0,

                Size = UDim2.new(1, 0, 0, ROW_HEIGHT),

                LayoutOrder = index,

                ZIndex = 17,
            })

            local number = AddText(
                row,
                string.format("%02d", index),
                8,
                UDim2.fromOffset(8, 0),
                UDim2.fromOffset(28, ROW_HEIGHT)
            )

            number.TextColor3 = self.Library.Theme.CyanDark
            number.Font = FONT_BOLD

            local marker = AddText(
                row,
                index == 1 and "◆" or "◇",
                12,
                UDim2.fromOffset(36, 0),
                UDim2.fromOffset(20, ROW_HEIGHT)
            )

            marker.TextColor3 =
                index == 1
                and self.Library.Theme.Cyan
                or self.Library.Theme.TextMuted

            --// component.Format(value), when set, gives the shown text (the
            --// stored value stays as it is); otherwise the value in capitals.
            local nameLabel = AddText(
                row,
                component.Format and component.Format(value) or value:upper(),
                9,
                UDim2.fromOffset(60, 0),
                UDim2.new(1, -(rightReserve + 60), 1, 0)
            )

            nameLabel.Font = FONT_BOLD

            if hasValues then
                local valueBox = New("TextBox", {
                    Parent = row,

                    BackgroundColor3 = self.Library.Theme.Element,

                    BackgroundTransparency = 0.1,

                    BorderSizePixel = 0,

                    Position = UDim2.new(1, -182, 0.5, -11),

                    Size = UDim2.fromOffset(52, 22),

                    Text = tostring(component.Values[index]),

                    PlaceholderText = tostring(defaultValue),

                    TextColor3 = self.Library.Theme.Text,

                    TextSize = 10,

                    Font = FONT_BOLD,

                    ClearTextOnFocus = false,

                    ZIndex = 18,
                })

                AddCorner(valueBox, 4)

                self.Library:_Connect(valueBox.FocusLost, function()
                    local newValue = ClampValue(valueBox.Text)
                    valueBox.Text = tostring(newValue)
                    component:SetValue(index, newValue)
                end)
            end

            if hasChecks then
                local checked = component.Checks[index] == true

                local checkBox = New("TextButton", {
                    Parent = row,

                    BackgroundColor3 = checked and self.Library.Theme.CyanDim or self.Library.Theme.Element,

                    BackgroundTransparency = checked and 0.2 or 0.1,

                    BorderSizePixel = 0,

                    Position = UDim2.new(1, checkX, 0.5, -CHECK_SIZE / 2),

                    Size = UDim2.fromOffset(CHECK_SIZE, CHECK_SIZE),

                    Text = checked and "✓" or "",

                    TextColor3 = self.Library.Theme.Cyan,

                    TextSize = 12,

                    Font = FONT_BOLD,

                    AutoButtonColor = false,

                    ZIndex = 18,
                })

                AddCorner(checkBox, 4)
                AddHoverHighlight(self.Library, checkBox, AddStroke(checkBox, self.Library.Theme.BorderDim, 0.15, 1))

                self.Library:_Connect(checkBox.MouseButton1Click, function()
                    component:SetCheck(index, not component.Checks[index])
                end)
            end

            -- Up
            local up = New("TextButton", {
                Parent = row,

                BackgroundTransparency = 1,

                Position = UDim2.new(1, -125, 0, 0),

                Size = UDim2.fromOffset(35, ROW_HEIGHT),

                Text = "▲",

                TextColor3 = self.Library.Theme.TextMuted,

                TextSize = 11,

                Font = FONT_BOLD,

                AutoButtonColor = false,

                ZIndex = 18,
            })

            -- Down
            local down = New("TextButton", {
                Parent = row,

                BackgroundTransparency = 1,

                Position = UDim2.new(1, -90, 0, 0),

                Size = UDim2.fromOffset(35, ROW_HEIGHT),

                Text = "▼",

                TextColor3 = self.Library.Theme.TextMuted,

                TextSize = 11,

                Font = FONT_BOLD,

                AutoButtonColor = false,

                ZIndex = 18,
            })

            -- Remove
            local remove = New("TextButton", {
                Parent = row,

                BackgroundTransparency = 1,

                Position = UDim2.new(1, -48, 0, 0),

                Size = UDim2.fromOffset(35, ROW_HEIGHT),

                Text = "×",

                TextColor3 = self.Library.Theme.Danger,

                TextSize = 18,

                Font = FONT_REGULAR,

                AutoButtonColor = false,

                ZIndex = 18,
            })

            self.Library:_Connect(up.MouseButton1Click, function()
                component:MoveUp(value)
            end)

            self.Library:_Connect(down.MouseButton1Click, function()
                component:MoveDown(value)
            end)

            self.Library:_Connect(remove.MouseButton1Click, function()
                component:Remove(value)
            end)

            if draggable then
                --// Invisible grip over the number, marker and name. The
                --// buttons on the right stay clickable.
                local grip = New("TextButton", {
                    Parent = row,

                    BackgroundTransparency = 1,

                    Position = UDim2.fromOffset(0, 0),

                    Size = UDim2.new(1, -rightReserve, 1, 0),

                    Text = "",

                    AutoButtonColor = false,

                    ZIndex = 19,
                })

                self.Library:_Connect(grip.InputBegan, function(input)
                    if input.UserInputType ~= Enum.UserInputType.MouseButton1
                        and input.UserInputType ~= Enum.UserInputType.Touch
                    then
                        return
                    end

                    if dragState or #component.Priority < 2 then
                        return
                    end

                    dragState = {
                        Index = index,
                        Target = index,
                        StartY = input.Position.Y,
                    }

                    row.BackgroundColor3 = self.Library.Theme.CyanDark
                    row.BackgroundTransparency = 0.45

                    local endConnection

                    endConnection = input.Changed:Connect(function()
                        if input.UserInputState ~= Enum.UserInputState.End then
                            return
                        end

                        endConnection:Disconnect()
                        FinishDrag()
                    end)
                end)
            end

            table.insert(rows, row)
        end
    end

    --// One pointer listener per list, not per row: rows are rebuilt on every
    --// change and would otherwise leak a connection each time.
    self.Library:_Connect(UserInputService.InputChanged, function(input)
        if not dragState then
            return
        end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch
        then
            return
        end

        dragState.Target = TargetIndexFor(input.Position.Y)
        ShowDropIndicator(dragState.Target)
    end)

    function component:_Refresh()
        Refresh()
    end

    --// newValues and newChecks are optional. Without them the current ones
    --// are kept, trimmed or padded with the default to fit the new list.
    function component:SetPriority(newPriority: {string}, newValues: {number}?, newChecks: {boolean}?)
        table.clear(self.Priority)

        for _, value in ipairs(newPriority) do
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

    function component:GetChecks()
        FitValues()
        return table.clone(self.Checks)
    end

    --// Callers hook OnCheckChanged(index, checked, label) to persist edits.
    function component:SetCheck(index: number, checked: boolean)
        if not self.Priority[index] then
            return
        end

        self.Checks[index] = checked == true
        Refresh()

        if self.OnCheckChanged then
            self.OnCheckChanged(index, self.Checks[index], self.Priority[index])
        end
    end

    function component:GetPriority()
        return table.clone(self.Priority)
    end

    function component:GetValues()
        FitValues()
        return table.clone(self.Values)
    end

    function component:GetValue(index: number)
        return ClampValue(self.Values[index])
    end

    --// Callers hook OnValueChanged(index, value, label) to persist edits.
    function component:SetValue(index: number, value: number)
        if not self.Priority[index] then
            return
        end

        self.Values[index] = ClampValue(value)

        if self.OnValueChanged then
            self.OnValueChanged(index, self.Values[index], self.Priority[index])
        end
    end

    function component:Add(value: string, initialValue: number?)
        if table.find(self.Priority, value) then
            return false
        end

        table.insert(self.Priority, value)
        self.Values[#self.Priority] = ClampValue(initialValue)
        self.Checks[#self.Priority] = false

        Refresh()

        return true
    end

    function component:Remove(value: string)
        local index = table.find(self.Priority, value)

        if not index then
            return false
        end

        table.remove(self.Priority, index)
        table.remove(self.Values, index)
        table.remove(self.Checks, index)

        Refresh()

        return true
    end

    function component:MoveUp(value: string)
        local index = table.find(self.Priority, value)

        if not index or index <= 1 then
            return
        end

        self.Priority[index], self.Priority[index - 1] =
            self.Priority[index - 1], self.Priority[index]
        self.Values[index], self.Values[index - 1] =
            self.Values[index - 1], self.Values[index]
        self.Checks[index], self.Checks[index - 1] =
            self.Checks[index - 1], self.Checks[index]

        Refresh()
    end

    function component:MoveDown(value: string)
        local index = table.find(self.Priority, value)

        if not index or index >= #self.Priority then
            return
        end

        self.Priority[index], self.Priority[index + 1] =
            self.Priority[index + 1], self.Priority[index]
        self.Values[index], self.Values[index + 1] =
            self.Values[index + 1], self.Values[index]
        self.Checks[index], self.Checks[index + 1] =
            self.Checks[index + 1], self.Checks[index]

        Refresh()
    end

    table.insert(self.Components, component)

    Refresh()

    return component
end

--//==============================================================
--// Dropdown Position
--//==============================================================

function Library:_PositionDropdown(button: GuiObject, popup: GuiObject)
    if not button.Visible or not popup.Visible then
        return
    end

    local camera  = workspace.CurrentCamera
    local overlay = self.Overlay

    if not camera or not overlay then
        return
    end

    local buttonPosition = button.AbsolutePosition
    local buttonSize     = button.AbsoluteSize
    local viewport       = camera.ViewportSize
    local uiScale        = self.UIScale.Scale

    if uiScale <= 0 then
        return
    end

    --// Sizes are popup offsets (inside the UIScale); positions and spaces
    --// are screen pixels. Mixing them shrank or grew the popup whenever
    --// the scale was not 1.
    local overlayPosition = overlay.AbsolutePosition
    local popupWidth      = popup.Size.X.Offset

    -- Keep a small margin from the screen edges.
    local edgePadding = 10
    local gap          = 4

    -- Calculate how much room exists above and below the button.
    local spaceAbove = buttonPosition.Y - edgePadding - gap
    local spaceBelow = viewport.Y - (buttonPosition.Y + buttonSize.Y) - edgePadding - gap

    -- The dropdown has at most five visible rows. If the screen is too short
    -- to fit all five, shrink the popup to the available space and let its
    -- ScrollingFrame handle the remaining options.
    local rowHeight   = 32
    local rowPadding  = 2
    local framePadding = 8
    local maxRows     = 5
    local normalHeight = (maxRows * rowHeight)
        + ((maxRows - 1) * rowPadding)
        + framePadding

    local desiredHeight = popup:GetAttribute("DropdownDesiredHeight") or popup.Size.Y.Offset
    local popupHeight   = math.min(desiredHeight, normalHeight)

    -- Prefer below when it fits. Otherwise place it above. If neither side
    -- can fit the full dropdown, use whichever side has more space.
    local placeAbove = false
    local availableSpace = spaceBelow

    local neededSpace = popupHeight * uiScale

    if spaceBelow >= neededSpace then
        placeAbove = false
        availableSpace = spaceBelow
    elseif spaceAbove >= neededSpace then
        placeAbove = true
        availableSpace = spaceAbove
    elseif spaceAbove > spaceBelow then
        placeAbove = true
        availableSpace = spaceAbove
    else
        placeAbove = false
        availableSpace = spaceBelow
    end

    -- If there is not enough room for five rows, use all available space.
    -- Keep at least one row visible on very small screens.
    local maxAvailableHeight = math.max(rowHeight + framePadding, availableSpace / uiScale)
    popupHeight = math.min(popupHeight, maxAvailableHeight)

    if popup.Size.Y.Offset ~= popupHeight then
        popup.Size = UDim2.fromOffset(popupWidth, popupHeight)
    end

    local screenWidth = popupWidth * uiScale
    local screenHeight = popupHeight * uiScale
    local screenX = buttonPosition.X
    local screenY

    if placeAbove then
        screenY = buttonPosition.Y - screenHeight - gap
    else
        screenY = buttonPosition.Y + buttonSize.Y + gap
    end

    -- Keep the popup inside the horizontal viewport.
    if screenX + screenWidth > viewport.X - edgePadding then
        screenX = viewport.X - screenWidth - edgePadding
    end

    screenX = math.max(edgePadding, screenX)
    screenY = math.max(edgePadding, screenY)

    popup.Position = UDim2.fromOffset(
        (screenX - overlayPosition.X) / uiScale,
        (screenY - overlayPosition.Y) / uiScale
    )
end

function Library:_CloseDropdowns(exception)
    for _, dropdown in ipairs(self._dropdowns) do
        if dropdown ~= exception then
            dropdown:Close()
        end
    end
end

--//==============================================================
--// Notification
--//==============================================================

--//==============================================================
--// Inventory binding
--//
--// The pin panel deals in names and numbers only. Everything that knows how
--// a particular game stores its inventory lives here, in one adapter, and the
--// format is replaceable: pass a parser and the library never has to care.
--//
--// The default understands the common flat encoding of one string holding
--// "Name|Amount" pairs separated by commas.
--//==============================================================
local function ParseDelimitedInventory(text: string?)
    local counts = {}
    local names = {}

    if type(text) ~= "string" then
        return counts, names
    end

    for entry in string.gmatch(text, "([^,]+)") do
        local itemName, amount = string.match(entry, "([^|]+)|(.+)")

        if itemName and counts[itemName] == nil then
            counts[itemName] = tonumber(amount) or 0
            table.insert(names, itemName)
        end
    end

    table.sort(names, function(a, b)
        return string.lower(a) < string.lower(b)
    end)

    return counts, names
end

--// Wires a pin panel to a StringValue holding an inventory. One call replaces
--// the search source, the count source and the change watcher, so a caller
--// never has to reimplement the same three hookups.
function Library:BindPinToValue(pin, valueObject: Instance?, parser)
    if not pin or not valueObject then
        return false
    end

    parser = parser or ParseDelimitedInventory

    local function Read()
        local ok, counts, names = pcall(parser, valueObject.Value)

        if not ok or type(counts) ~= "table" then
            return {}, {}
        end

        return counts, type(names) == "table" and names or {}
    end

    pin:SetSearchSource(function()
        local _, names = Read()
        return names
    end)

    pin:SetCountSource(function()
        local counts = Read()
        return counts
    end)

    local function Refresh()
        local counts = Read()
        pin:UpdateCounts(counts)
    end

    --// Event driven: the value only changes when the server says so, and one
    --// parse refreshes every pinned count.
    self:_Connect(valueObject:GetPropertyChangedSignal("Value"), Refresh)
    Refresh()

    return true
end

--//==============================================================
--// Pin Panel
--//
--// A compact list of named items with a count each, in its own frame beside
--// the window rather than inside a tab. It knows nothing about where the
--// counts come from: the caller pushes them in with UpdateCounts and supplies
--// the searchable names with SetSearchSource, which keeps this library free
--// of any single inventory format.
--//
--// Attached it sits at the right edge; popped out it is dragged anywhere and
--// keeps its own position. GetState and SetState hand that arrangement to the
--// caller to persist, since the library does no file access of its own.
--//==============================================================
function Library:AddPin(name: string?)
    local component = {}
    component.Library = self
    component.Items = {}
    component.Floating = false
    component.SearchSource = nil
    component.CountSource = nil
    component.MaxResults = 12
    component.Minimized = false
    component.Visible = true

    local panel = New("TextButton", {
        --// A button, so a click on it stops here instead of reaching the UI
        --// underneath; it draws like a frame.
        Text = "",
        AutoButtonColor = false,
        Name = "PinPanel",
        Parent = self.ScreenGui,
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 130),
        Size = UDim2.new(0, 194, 0, 0),
        ClipsDescendants = false,
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = self.Theme.Panel,
        BackgroundTransparency = 0.06,
        BorderSizePixel = 0,
        ZIndex = 40,
    })

    AddCorner(panel, 6)
    AddStroke(panel, self.Theme.BorderDim)
    AddPadding(panel, 8, 8, 8, 8)

    New("UIListLayout", {
        Parent = panel,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 5),
    })

    component.Panel = panel

    local header = New("Frame", {
        Parent = panel,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 24),
        LayoutOrder = 1,
        ZIndex = 41,
    })

    local title = AddText(header, name or "Pinned Items", 13, UDim2.new(0, 0, 0, 0), UDim2.new(1, -82, 1, 0))
    title.TextColor3 = self.Theme.Cyan
    title.ZIndex = 42

    local function HeaderButton(text, xOffset, color)
        local button = New("TextButton", {
            Parent = header,
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, xOffset, 0.5, 0),
            Size = UDim2.new(0, 20, 0, 18),
            BackgroundColor3 = self.Theme.Element,
            BackgroundTransparency = 0.15,
            BorderSizePixel = 0,
            Text = text,
            TextColor3 = color or self.Theme.TextMuted,
            TextSize = 11,
            Font = FONT_BOLD,
            AutoButtonColor = false,
            ZIndex = 42,
        })
        AddCorner(button, 3)
        AddStroke(button, self.Theme.BorderDim, 0.35, 1)
        return button
    end

    local closeButton = HeaderButton("×", -2, self.Theme.Danger)
    local minimizeButton = HeaderButton("—", -24, self.Theme.TextMuted)
    local popButton = HeaderButton("<>", -46, self.Theme.TextMuted)

    component.CloseButton = closeButton
    component.MinimizeButton = minimizeButton

    --// A dropdown is unusable here: an inventory can hold hundreds of entries,
    --// so this filters by substring and shows only the first few matches.
    local searchBox = New("TextBox", {
        Parent = panel,
        Size = UDim2.new(1, 0, 0, 22),
        LayoutOrder = 2,
        BackgroundColor3 = self.Theme.Element,
        BackgroundTransparency = 0.15,
        BorderSizePixel = 0,
        Text = "",
        PlaceholderText = "search item...",
        PlaceholderColor3 = self.Theme.TextMuted,
        TextColor3 = self.Theme.Text,
        TextSize = 12,
        Font = FONT_REGULAR,
        ClearTextOnFocus = false,
        ZIndex = 41,
    })

    AddCorner(searchBox, 4)
    AddPadding(searchBox, 6, 6, 0, 0)

    local resultHolder = New("Frame", {
        Parent = panel,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 3,
        Visible = false,
        ZIndex = 41,
    })

    New("UIListLayout", {
        Parent = resultHolder,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 2),
    })

    local itemHolder = New("Frame", {
        Parent = panel,
        BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        LayoutOrder = 4,
        ZIndex = 41,
    })

    New("UIListLayout", {
        Parent = itemHolder,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 3),
    })

    local emptyLabel = AddText(panel, "no pinned items", 11, UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, 16))
    emptyLabel.TextColor3 = self.Theme.TextMuted
    emptyLabel.LayoutOrder = 5
    emptyLabel.ZIndex = 41

    --// Closed, the panel leaves nothing on screen; the caller offers a way
    --// to show it again (SetVisible), and hears of a close via OnChanged.
    local resizeHandle = New("TextButton", {
        Name = "PinResizeHandle",
        Parent = self.ScreenGui,
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(18, 18),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "↘",
        TextColor3 = self.Theme.TextMuted,
        TextSize = 13,
        Font = FONT_BOLD,
        AutoButtonColor = false,
        Visible = true,
        ZIndex = 81,
    })
    component.ResizeHandle = resizeHandle

    --// Counts pushed in with UpdateCounts only arrive when the caller notices
    --// a change. An item pinned just now, or restored from a saved list, has
    --// to be able to ask for its number straight away or it reads 0 until the
    --// next change happens to come along.
    local function ResolveCounts()
        if not component.CountSource then
            return nil
        end

        local ok, counts = pcall(component.CountSource)

        if not ok or type(counts) ~= "table" then
            return nil
        end

        return counts
    end

    local function IndexOf(itemName)
        for index, entry in ipairs(component.Items) do
            if entry.Name == itemName then
                return index
            end
        end

        return nil
    end

    local RefreshResults

    local function RefreshItems()
        for _, child in ipairs(itemHolder:GetChildren()) do
            if not child:IsA("UIListLayout") then
                child:Destroy()
            end
        end

        emptyLabel.Visible = #component.Items == 0

        for index, entry in ipairs(component.Items) do
            local row = New("Frame", {
                Parent = itemHolder,
                Size = UDim2.new(1, 0, 0, 20),
                BackgroundColor3 = self.Theme.PanelLight,
                BackgroundTransparency = 0.25,
                BorderSizePixel = 0,
                LayoutOrder = index,
                ZIndex = 42,
            })

            AddCorner(row, 4)

            local rowName = AddText(row, entry.Name, 11, UDim2.new(0, 6, 0, 0), UDim2.new(1, -96, 1, 0))
            rowName.TextColor3 = self.Theme.Text
            rowName.ZIndex = 43

            local count = AddText(row, tostring(entry.Count or 0), 11, UDim2.new(1, -92, 0, 0), UDim2.new(0, 34, 1, 0))
            count.TextColor3 = (entry.Count or 0) > 0 and self.Theme.Cyan or self.Theme.TextMuted
            count.TextXAlignment = Enum.TextXAlignment.Right
            count.ZIndex = 43

            local function SmallButton(text, offset, colour)
                return New("TextButton", {
                    Parent = row,
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, offset, 0.5, 0),
                    Size = UDim2.new(0, 16, 0, 16),
                    BackgroundTransparency = 1,
                    Text = text,
                    TextColor3 = colour,
                    TextSize = 11,
                    Font = FONT_REGULAR,
                    AutoButtonColor = false,
                    ZIndex = 43,
                })
            end

            local up = SmallButton("^", -38, self.Theme.TextMuted)
            local down = SmallButton("v", -21, self.Theme.TextMuted)
            local remove = SmallButton("x", -4, self.Theme.Danger)

            self:_Connect(up.MouseButton1Click, function()
                component:MoveUp(entry.Name)
            end)

            self:_Connect(down.MouseButton1Click, function()
                component:MoveDown(entry.Name)
            end)

            self:_Connect(remove.MouseButton1Click, function()
                component:Remove(entry.Name)
            end)
        end

        if component.OnChanged then
            task.spawn(component.OnChanged, component)
        end
    end

    RefreshResults = function()
        for _, child in ipairs(resultHolder:GetChildren()) do
            if not child:IsA("UIListLayout") then
                child:Destroy()
            end
        end

        local query = string.lower(searchBox.Text or "")

        if query == "" or not component.SearchSource then
            resultHolder.Visible = false
            return
        end

        local ok, names = pcall(component.SearchSource)

        if not ok or type(names) ~= "table" then
            resultHolder.Visible = false
            return
        end

        local shown = 0

        for _, itemName in ipairs(names) do
            if shown >= component.MaxResults then
                break
            end

            if type(itemName) == "string"
                and string.find(string.lower(itemName), query, 1, true)
                and not IndexOf(itemName)
            then
                shown += 1

                local result = New("TextButton", {
                    Parent = resultHolder,
                    Size = UDim2.new(1, 0, 0, 18),
                    BackgroundColor3 = self.Theme.Element,
                    BackgroundTransparency = 0.25,
                    BorderSizePixel = 0,
                    Text = "",
                    AutoButtonColor = false,
                    LayoutOrder = shown,
                    ZIndex = 42,
                })

                AddCorner(result, 4)

                local resultName = AddText(result, itemName, 11, UDim2.new(0, 6, 0, 0), UDim2.new(1, -12, 1, 0))
                resultName.TextColor3 = self.Theme.TextSecondary
                resultName.ZIndex = 43

                self:_Connect(result.MouseButton1Click, function()
                    component:AddList(itemName)
                    searchBox.Text = ""
                    RefreshResults()
                end)
            end
        end

        resultHolder.Visible = shown > 0
    end

    self:_Connect(searchBox:GetPropertyChangedSignal("Text"), RefreshResults)

    function component:AddList(itemName: string, count: number?)
        if type(itemName) ~= "string" or itemName == "" then
            return false
        end

        local existing = IndexOf(itemName)

        if existing then
            --// Already pinned. Re-adding with a number means the caller is
            --// giving a fresh count, so take it rather than doing nothing.
            self.Items[existing].Count = tonumber(count) or self.Items[existing].Count or 0
            RefreshItems()
            return false
        end

        local resolved = tonumber(count)

        if not resolved then
            local counts = ResolveCounts()
            resolved = counts and tonumber(counts[itemName]) or 0
        end

        table.insert(self.Items, {
            Name = itemName,
            Count = resolved,
        })

        RefreshItems()
        RefreshResults()
        return true
    end

    function component:Remove(itemName: string)
        local index = IndexOf(itemName)

        if not index then
            return false
        end

        table.remove(self.Items, index)
        RefreshItems()
        RefreshResults()
        return true
    end

    function component:MoveUp(itemName: string)
        local index = IndexOf(itemName)

        if not index or index <= 1 then
            return false
        end

        self.Items[index], self.Items[index - 1] = self.Items[index - 1], self.Items[index]
        RefreshItems()
        return true
    end

    function component:MoveDown(itemName: string)
        local index = IndexOf(itemName)

        if not index or index >= #self.Items then
            return false
        end

        self.Items[index], self.Items[index + 1] = self.Items[index + 1], self.Items[index]
        RefreshItems()
        return true
    end

    function component:GetItems()
        local names = {}

        for _, entry in ipairs(self.Items) do
            table.insert(names, entry.Name)
        end

        return names
    end

    function component:SetItems(names)
        table.clear(self.Items)

        --// Resolved once for the whole list rather than per item, so a long
        --// restored list costs one lookup.
        local counts = ResolveCounts()

        for _, itemName in ipairs(names or {}) do
            if type(itemName) == "string" and itemName ~= "" and not IndexOf(itemName) then
                table.insert(self.Items, {
                    Name = itemName,
                    Count = counts and tonumber(counts[itemName]) or 0,
                })
            end
        end

        RefreshItems()
        RefreshResults()
    end

    --// Counts arrive from outside. Anything not mentioned reads as zero, so a
    --// pinned item that has left the inventory shows 0 rather than a stale
    --// number from the last update.
    function component:UpdateCounts(counts)
        counts = counts or {}

        for _, entry in ipairs(self.Items) do
            entry.Count = tonumber(counts[entry.Name]) or 0
        end

        RefreshItems()
    end

    function component:SetSearchSource(source)
        self.SearchSource = source
        RefreshResults()
    end

    --// Returns the same name to number map UpdateCounts takes. Called only
    --// when an item is added or a list is restored, never from RefreshItems,
    --// which would recurse through OnChanged.
    function component:SetCountSource(source)
        self.CountSource = source

        if #self.Items > 0 then
            self:UpdateCounts(ResolveCounts())
        end
    end

    function component:SetFloating(value: boolean)
        self.Floating = value and true or false

        popButton.Text = self.Floating and ">|" or "<>"
        popButton.TextColor3 = self.Floating and self.Library.Theme.Cyan or self.Library.Theme.TextMuted

        if not self.Floating then
            panel.AnchorPoint = Vector2.new(1, 0)
            panel.Position = UDim2.new(1, -16, 0, 130)
        end
    end

    function component:SetPosition(x: number?, y: number?)
        if not tonumber(x) or not tonumber(y) then
            return
        end

        panel.AnchorPoint = Vector2.new(0, 0)
        panel.Position = UDim2.fromOffset(tonumber(x), tonumber(y))

        --// A saved position can come from a larger screen or another device.
        ClampToParent(panel)
    end

    --// Docks the panel back to its default spot at the right edge.
    function component:ResetPosition()
        self:SetFloating(false)

        if self.OnChanged then
            task.spawn(self.OnChanged, self)
        end
    end

    function component:GetState()
        return {
            Items = self:GetItems(),
            Floating = self.Floating,
            Visible = self.Visible,
            X = math.round(panel.AbsolutePosition.X),
            Y = math.round(panel.AbsolutePosition.Y),
        }
    end

    function component:SetState(state)
        if type(state) ~= "table" then
            return
        end

        self:SetItems(state.Items)
        self:SetFloating(state.Floating == true)
        self:SetVisible(state.Visible ~= false)

        if state.Floating then
            self:SetPosition(state.X, state.Y)
        end
    end

    local function UpdatePinControls()
        if not panel.Parent then
            return
        end

        local pos = panel.AbsolutePosition
        local size = panel.AbsoluteSize
        resizeHandle.Position = UDim2.fromOffset(pos.X + size.X, pos.Y + size.Y)
        resizeHandle.Visible = component.Visible and not component.Minimized
    end

    function component:SetMinimized(value: boolean)
        value = value and true or false
        if self.Minimized == value then
            return
        end

        self.Minimized = value
        searchBox.Visible = not value
        resultHolder.Visible = not value and resultHolder.Visible
        itemHolder.Visible = not value
        emptyLabel.Visible = not value and #self.Items == 0
        resizeHandle.Visible = self.Visible and not value

        if value then
            minimizeButton.Text = "□"
        else
            minimizeButton.Text = "—"
        end

        UpdatePinControls()
    end

    function component:ToggleMinimize()
        self:SetMinimized(not self.Minimized)
    end

    function component:SetVisible(value: boolean)
        self.Visible = value and true or false
        panel.Visible = self.Visible
        resizeHandle.Visible = self.Visible and not self.Minimized
        UpdatePinControls()
    end

    function component:Destroy()
        panel:Destroy()
        resizeHandle:Destroy()
    end

    self:_Connect(minimizeButton.MouseButton1Click, function()
        component:ToggleMinimize()
    end)

    self:_Connect(closeButton.MouseButton1Click, function()
        component:SetVisible(false)

        if component.OnChanged then
            task.spawn(component.OnChanged, component)
        end
    end)

    self:_Connect(popButton.MouseButton1Click, function()
        component:SetFloating(not component.Floating)

        if component.OnChanged then
            task.spawn(component.OnChanged, component)
        end
    end)

    local resizing = false
    local resizeStart: Vector2
    local startWidth: number

    self:_Connect(resizeHandle.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        resizing = true
        resizeStart = input.Position
        startWidth = panel.AbsoluteSize.X
    end)

    self:_Connect(UserInputService.InputChanged, function(input)
        if not resizing then
            return
        end

        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        local delta = input.Position.X - resizeStart.X
        local width = math.clamp(startWidth + delta, 170, 360)
        panel.Size = UDim2.new(0, width, 0, 0)
        UpdatePinControls()
    end)

    self:_Connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            resizing = false
        end
    end)

    self:_Connect(panel:GetPropertyChangedSignal("AbsolutePosition"), UpdatePinControls)
    self:_Connect(panel:GetPropertyChangedSignal("AbsoluteSize"), UpdatePinControls)

    --// Dragging works in both modes, and dragging while attached pops it out,
    --// which is the gesture someone will reach for first. It is kept on
    --// screen so it cannot be dragged somewhere it can no longer be grabbed.
    self:_MakeDraggable(header, panel, true)

    --// Rotating a device or resizing the window can leave a floating panel
    --// off screen, so it is pulled back whenever the bounds change.
    self:_Connect(self.ScreenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
        if component.Floating then
            ClampToParent(panel)
        end
    end)

    --// The panel grows as items are pinned, which can push its bottom edge
    --// past the screen.
    self:_Connect(panel:GetPropertyChangedSignal("AbsoluteSize"), function()
        if component.Floating then
            ClampToParent(panel)
        end
    end)

    self:_Connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch
        then
            if not component.Floating then
                component:SetFloating(true)
            end

            --// Report the drag once it ends, so the new spot is saved.
            local endConnection

            endConnection = input.Changed:Connect(function()
                if input.UserInputState ~= Enum.UserInputState.End then
                    return
                end

                endConnection:Disconnect()
                ClampToParent(panel)

                if component.OnChanged then
                    task.spawn(component.OnChanged, component)
                end
            end)
        end
    end)

    component:SetFloating(false)
    RefreshItems()
    UpdatePinControls()

    self.Pins = self.Pins or {}
    table.insert(self.Pins, component)

    return component
end

function Library:Notify(title: string, message: string, duration: number?)
    duration = duration or 3

    local notification = New("Frame", {
        Parent = self.ScreenGui,

        AnchorPoint = Vector2.new(1, 1),

        Position = UDim2.new(1, 20, 1, -25),

        Size = UDim2.fromOffset(310, 72),

        BackgroundColor3 = self.Theme.Panel,

        BorderSizePixel = 0,

        ZIndex = 300,
    })

    AddStroke(
        notification,
        self.Theme.CyanDark,
        0.1,
        1
    )

    AddAngularCorners(notification)

    local icon = AddText(
        notification,
        "◇",
        18,
        UDim2.fromOffset(13, 10),
        UDim2.fromOffset(32, 28)
    )

    icon.TextColor3 = self.Theme.Cyan
    icon.Font = FONT_BOLD

    local titleLabel = AddText(
        notification,
        title:upper(),
        9,
        UDim2.fromOffset(48, 8),
        UDim2.new(1, -60, 0, 18)
    )

    titleLabel.Font = FONT_BOLD

    local messageLabel = AddText(
        notification,
        message,
        9,
        UDim2.fromOffset(48, 29),
        UDim2.new(1, -60, 0, 28)
    )

    messageLabel.TextColor3 = self.Theme.TextSecondary
    messageLabel.TextWrapped = true

    -- Time line
    local timerLine = New("Frame", {
        Parent = notification,

        BackgroundColor3 = self.Theme.Cyan,

        BorderSizePixel = 0,

        Position = UDim2.new(0, 0, 1, -2),

        Size = UDim2.new(1, 0, 0, 2),

        ZIndex = 301,
    })

    table.insert(self._notifications, notification)

    -- Reposition existing notifications
    for index, existing in ipairs(self._notifications) do
        if existing ~= notification then
            local targetY = -25 - ((#self._notifications - index) * 82)

            Tween(existing, TWEEN_NORMAL, {
                Position = UDim2.new(1, -25, 1, targetY),
            })
        end
    end

    Tween(notification, TWEEN_SMOOTH, {
        Position = UDim2.new(1, -25, 1, -25),
    })

    Tween(timerLine, TweenInfo.new(
        duration,
        Enum.EasingStyle.Linear,
        Enum.EasingDirection.Out
        ), {
            Size = UDim2.new(0, 0, 0, 2),
        })

    task.delay(duration, function()
        if not notification.Parent then
            return
        end

        Tween(notification, TWEEN_NORMAL, {
            Position = UDim2.new(1, 25, 1, -25),
        })

        task.wait(0.2)

        if notification.Parent then
            notification:Destroy()
        end

        local index = table.find(self._notifications, notification)

        if index then
            table.remove(self._notifications, index)
        end
    end)

    return notification
end

--//==============================================================
--// Theme
--//==============================================================

function Library:SetTheme(theme: {[string]: any})
    local previous = table.clone(self.Theme)

    for key, value in pairs(theme) do
        if self.Theme[key] ~= nil and typeof(value) == "Color3" then
            self.Theme[key] = value
        end
    end

    -- Rebind existing UI colors without recreating components. This keeps
    -- the original library structure and callbacks intact.
    for _, object in ipairs(self.Window:GetDescendants()) do
        for key, oldColor in pairs(previous) do
            local newColor = self.Theme[key]
            if newColor and oldColor ~= newColor then
                if object:IsA("GuiObject") then
                    if object.BackgroundColor3 == oldColor then object.BackgroundColor3 = newColor end
                    if object.BorderColor3 == oldColor then object.BorderColor3 = newColor end
                end
                if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                    if object.TextColor3 == oldColor then object.TextColor3 = newColor end
                end
                if object:IsA("ImageLabel") or object:IsA("ImageButton") then
                    if object.ImageColor3 == oldColor then object.ImageColor3 = newColor end
                end
                if object:IsA("ScrollingFrame") and object.ScrollBarImageColor3 == oldColor then
                    object.ScrollBarImageColor3 = newColor
                end
            end
        end
    end

    self.Window.BackgroundColor3 = self.Theme.Background
    self.Header.BackgroundColor3 = self.Theme.BackgroundLight
    self.Sidebar.BackgroundColor3 = self.Theme.Panel
    self.TitleLabel.TextColor3 = self.Theme.Text
    self.Subtitle.TextColor3 = self.Theme.TextMuted
    self.StatusDot.BackgroundColor3 = self.Theme.Cyan
    self.CloseButton.BackgroundColor3 = self.Theme.Danger
    self.ReopenButton.BackgroundColor3 = self.Theme.Panel
    self.ReopenButton.TextColor3 = self.Theme.Cyan

    if self.ConfigButton then
        self.ConfigButton.BackgroundColor3 = self.Theme.Element
        self.ConfigButton.TextColor3 = self.Theme.Cyan
    end
    if self.ConfigAccent then
        self.ConfigAccent.BackgroundColor3 = self.Theme.Cyan
    end
    if self.ConfigMark then
        self.ConfigMark.TextColor3 = self.Theme.TextMuted
    end
    if self.SettingsReset then
        self.SettingsReset.TextColor3 = self.Theme.TextSecondary
    end
    if self.SettingsReturn then
        self.SettingsReturn.TextColor3 = self.Theme.TextSecondary
    end
    if self.SettingsPanel then
        self.SettingsPanel.BackgroundColor3 = self.Theme.Panel
    end
    if self._RefreshSettingsInputs then
        self._RefreshSettingsInputs()
    end
    if self.OnThemeChanged then
        task.spawn(self.OnThemeChanged, table.clone(self.Theme))
    end
end

--// One Enum.Font per font family. Items such as GothamBold, GothamBlack or
--// SourceSansItalic are only another weight or style of a family, and the
--// UI keeps each text's own weight (ApplyFontFamily), so picking them set
--// exactly the same font as their base and looked like they did nothing.
--// The regular, upright item of each family stands for it, else the
--// shortest name. Built once.
function Library:_GetFontChoices()
    if self._FontChoices then
        return self._FontChoices
    end

    local best = {}

    for _, item in ipairs(Enum.Font:GetEnumItems()) do
        local ok, face = pcall(Font.fromEnum, item)

        if item.Name ~= "Unknown" and ok and face then
            local score = (face.Weight == Enum.FontWeight.Regular and 0 or 1)
                + (face.Style == Enum.FontStyle.Normal and 0 or 2)
            local current = best[face.Family]

            if not current
                or score < current.Score
                or (score == current.Score and #item.Name < #current.Name)
            then
                best[face.Family] = { Name = item.Name, Score = score }
            end
        end
    end

    local names, byFamily = {}, {}

    for family, entry in pairs(best) do
        table.insert(names, entry.Name)
        byFamily[family] = entry.Name
    end

    table.sort(names)

    self._FontChoices = { Names = names, ByFamily = byFamily }
    return self._FontChoices
end

--// The dropdown name that stands for this Enum.Font's family.
function Library:_GetFontChoiceName(item: EnumItem): string
    local ok, face = pcall(Font.fromEnum, item)

    if ok and face then
        return self:_GetFontChoices().ByFamily[face.Family] or item.Name
    end

    return item.Name
end

--// Every font family that can be chosen in Configuration, by name, sorted.
function Library:GetFontNames(): {string}
    return table.clone(self:_GetFontChoices().Names)
end

--// Draws each option of the font dropdown in the font it names, then,
--// in the background, lays out sample text in every one and hides those
--// that fail to load in this client. The failures go to the console.
function Library:_PreviewFontOptions(dropdown)
    local faces = {}

    for name, row in pairs(dropdown.OptionRows) do
        local ok, face = pcall(function()
            return Font.fromEnum((Enum.Font :: any)[name])
        end)

        if ok and face then
            faces[name] = face
            row.Label:SetAttribute(FONT_PREVIEW_ATTRIBUTE, true)
            row.Label.FontFace = Font.new(face.Family, Enum.FontWeight.Regular, Enum.FontStyle.Normal)
        end
    end

    task.spawn(function()
        local TextService = game:GetService("TextService")
        local failed = {}

        for name, row in pairs(dropdown.OptionRows) do
            --// The window was closed for good meanwhile.
            if not dropdown.Frame.Parent then
                return
            end

            local face = faces[name]
            local ok = face ~= nil and pcall(function()
                local params = Instance.new("GetTextBoundsParams")
                params.Text = FONT_CHECK_TEXT
                params.Font = Font.new(face.Family)
                params.Size = 14
                params.Width = 1000
                TextService:GetTextBoundsAsync(params)
            end)

            if not ok then
                row.Button.Visible = false
                table.insert(failed, name)
            end
        end

        if #failed > 0 then
            table.sort(failed)
            warn("[UI] Fonts that failed to load, hidden from the Font list: " .. table.concat(failed, ", "))
        end
    end)
end

--// Text under root (now and added later) follows the chosen font. The
--// ScreenGui is one; other modules add places such as world billboards.
function Library:AddFontRoot(root: Instance)
    if table.find(self._FontRoots, root) then
        return
    end

    table.insert(self._FontRoots, root)

    self:_Connect(root.DescendantAdded, function(object)
        if self.FontFamily and TEXT_CLASSES[object.ClassName] then
            --// Deferred: whoever created it sets its Font right after.
            task.defer(function()
                if self.FontFamily and object.Parent then
                    ApplyFontFamily(object, self.FontFamily)
                end
            end)
        end
    end)

    if self.FontFamily then
        for _, object in ipairs(root:GetDescendants()) do
            if TEXT_CLASSES[object.ClassName] then
                ApplyFontFamily(object, self.FontFamily)
            end
        end
    end
end

--// Puts the whole UI on one Roblox font (an Enum.Font or its name),
--// keeping each text's weight. Returns false for an unknown font.
function Library:SetFont(font: any): boolean
    if type(font) == "string" then
        local ok, item = pcall(function()
            return (Enum.Font :: any)[font]
        end)

        font = ok and item or nil
    end

    if typeof(font) ~= "EnumItem" then
        return false
    end

    local ok, face = pcall(Font.fromEnum, font)

    if not ok then
        return false
    end

    --// A weight item (a saved "GothamBold") shows as its family's entry.
    local name = self:_GetFontChoices().ByFamily[face.Family] or font.Name

    self.FontName = name
    self.FontFamily = face.Family

    for _, root in ipairs(self._FontRoots) do
        for _, object in ipairs(root:GetDescendants()) do
            if TEXT_CLASSES[object.ClassName] then
                ApplyFontFamily(object, face.Family)
            end
        end
    end

    if self._FontDropdown then
        self._FontDropdown:Set(name, false)
    end

    if self.OnFontChanged then
        task.spawn(self.OnFontChanged, name)
    end

    return true
end

--// Sizes one text from its unscaled size. The first call records the
--// current TextSize as that base. TextScaled text sizes itself.
local function ApplyTextScale(object: Instance, scale: number)
    if not TEXT_CLASSES[object.ClassName] or (object :: any).TextScaled then
        return
    end

    local base = object:GetAttribute(BASE_TEXT_SIZE_ATTRIBUTE)

    if type(base) ~= "number" then
        base = (object :: any).TextSize
        object:SetAttribute(BASE_TEXT_SIZE_ATTRIBUTE, base)
    end

    (object :: any).TextSize = math.max(TEXT_SIZE_MIN, math.round(base * scale))
end

--// Text added under the ScreenGui later (dropdown items, notifications,
--// floating windows, rebuilt rows) takes the current scale too.
function Library:_WatchTextScale()
    self:_Connect(self.ScreenGui.DescendantAdded, function(object)
        if not TEXT_CLASSES[object.ClassName] then
            return
        end

        --// Deferred: whoever created it sets its TextSize right after.
        task.defer(function()
            if object.Parent and self.TextScale ~= TEXT_SCALE then
                ApplyTextScale(object, self.TextScale)
            end
        end)
    end)
end

--// Scales every text in the UI (window, popups and floating windows).
--// Returns the scale actually applied.
function Library:SetTextScale(scale: number): number
    scale = math.clamp(tonumber(scale) or self.TextScale or TEXT_SCALE, TEXT_SCALE_MIN, TEXT_SCALE_MAX)
    scale = math.round(scale * 100) / 100
    self.TextScale = scale

    for _, object in ipairs(self.ScreenGui:GetDescendants()) do
        ApplyTextScale(object, scale)
    end

    if self._TextScaleInput then
        self._TextScaleInput.Text = tostring(scale)
    end

    if self.OnTextScaleChanged then
        task.spawn(self.OnTextScaleChanged, scale)
    end

    return scale
end

function Library:SetWindowSizeLimits(kind: string, value: number)
    value = tonumber(value)
    if not value then return end

    if kind == "MinWidth" then
        self.MinWindowSize = Vector2.new(math.clamp(value, 360, 2000), self.MinWindowSize.Y)
    elseif kind == "MinHeight" then
        self.MinWindowSize = Vector2.new(self.MinWindowSize.X, math.clamp(value, 240, 1400))
    elseif kind == "MaxWidth" then
        self.MaxWindowSize = Vector2.new(math.clamp(value, 400, 3000), self.MaxWindowSize.Y)
    elseif kind == "MaxHeight" then
        self.MaxWindowSize = Vector2.new(self.MaxWindowSize.X, math.clamp(value, 300, 2200))
    end

    -- Never leave min larger than max.
    self.MaxWindowSize = Vector2.new(
        math.max(self.MaxWindowSize.X, self.MinWindowSize.X),
        math.max(self.MaxWindowSize.Y, self.MinWindowSize.Y)
    )
    self.WindowSize = Vector2.new(
        math.clamp(self.WindowSize.X, self.MinWindowSize.X, self.MaxWindowSize.X),
        math.clamp(self.WindowSize.Y, self.MinWindowSize.Y, self.MaxWindowSize.Y)
    )
    self.Window.Size = UDim2.fromOffset(self.WindowSize.X, self.WindowSize.Y)
    self:_UpdateScale()
end

function Library:SetWindowSize(size: Vector2)
    local width = math.clamp(size.X, self.MinWindowSize.X, self.MaxWindowSize.X)
    local height = math.clamp(size.Y, self.MinWindowSize.Y, self.MaxWindowSize.Y)
    self.WindowSize = Vector2.new(width, height)
    self.Window.Size = UDim2.fromOffset(width, height)
    self:_UpdateScale()
end

--//==============================================================
--// Destroy
--//==============================================================

function Library:Destroy()
    if self.Destroyed then
        return
    end

    self.Destroyed = true

    for _, connection in ipairs(self._connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end

    table.clear(self._connections)

    if self.ScreenGui then
        self.ScreenGui:Destroy()
    end

    table.clear(self.Tabs)
    table.clear(self.Sections)
    table.clear(self.Components)
    table.clear(self._dropdowns)
    table.clear(self._notifications)
end

--//==============================================================
--// Return
--//==============================================================

return Library
