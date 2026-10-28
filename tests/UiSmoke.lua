--[[
    Smoke test for script/UI/Utils.lua: builds the window, every widget the
    project uses, the Settings tab, the pinned panel and then tears it down.
    Run through ui_smoke.ps1, which concatenates this with the stub and the
    library.
]]

local failures = 0
local function Check(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("OK   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. " :: " .. tostring(err))
    end
end

local function Expect(condition, message)
    if not condition then error(message or "expectation failed", 2) end
end

local win
Check("Library.new", function()
    win = Library.new("AIC TEST", { ManualLoading = true })
    Expect(win and win.Root, "no window")
end)
if not win then
    print("ABORT: the window could not be built")
    return
end

Check("theme aliases", function()
    Expect(win.Theme.Cyan == win.Theme.Accent, "Cyan alias")
    Expect(win.Theme.TextSecondary == win.Theme.SubText, "TextSecondary alias")
    Expect(win.Theme.BorderDim == win.Theme.Border, "BorderDim alias")
end)

local tab, section, toggle, slider, dropdown, textbox, priority
Check("tab + section", function()
    tab = win:AddTab("Farming")
    section = tab:AddSection("Core")
    Expect(type(section.AddToggle) == "function", "section has no widgets")
end)

Check("AddToggle", function()
    toggle = section:AddToggle("Auto Farm", false, function() end, "Turns the farm on.")
    toggle:Set(true)
    Expect(toggle:Get() == true, "toggle did not turn on")
    toggle:Set(false)
    Expect(toggle:Get() == false, "toggle did not turn off")
end)

Check("AddSlider", function()
    slider = section:AddSlider("Safe Target Range", 10, 1, 50, function() end, "Range in studs.")
    slider:Set(25)
    Expect(slider:Get() == 25, "slider value " .. tostring(slider:Get()))
    slider:Set(999)
    Expect(slider:Get() == 50, "slider did not clamp")
end)

Check("AddDropdown", function()
    dropdown = section:AddDropdown("Target Type", { "Mob", "Player" }, function() end, "What to attack.")
    dropdown:Set("Player")
    Expect(dropdown:Get() == "Player", "dropdown value")
    dropdown:SetOptions({ "Mob", "Player", "Boss" })
end)

Check("AddTextbox", function()
    textbox = section:AddTextbox("Webhook", "", function() end, "Discord webhook.")
    textbox:Set("https://example.invalid/hook")
    Expect(textbox:Get() == "https://example.invalid/hook", "textbox value")
end)

Check("AddButton / AddLabel / AddDivider", function()
    local clicked = false
    section:AddButton("Run once", function() clicked = true end, "Runs once.")
    section:AddLabel("A longer label that has to wrap inside the card without overflowing it.")
    section:AddDivider()
    Expect(clicked == false, "button fired early")
end)

Check("AddPriority", function()
    priority = section:AddPriority("Enemy Priority", { "Slime", "Golem" }, {
        Values = true,
        ValueLabel = "Level",
        Default = 5,
        Min = 0,
        Max = 10,
        Checks = true,
        CheckLabel = "Use",
    })
    Expect(#priority.Priority >= 2, "priority list empty")
    Expect(priority:Add("Bat") == true or #priority.Priority >= 3, "Add failed")
    priority:SetPriority({ "A", "B" }, { 3, 4 }, { true, false })
    Expect(priority.Priority[1] == "A", "SetPriority did not replace")
    Expect(priority.Values[2] == 4, "SetPriority values")
    Expect(priority.Checks[1] == true, "SetPriority checks")
    priority:MoveUp("B")
    Expect(priority.Priority[1] == "B", "MoveUp")
    priority:MoveDown("B")
    Expect(priority.Priority[1] == "A", "MoveDown")
    priority:Remove("A")
    Expect(priority.Priority[1] == "B", "Remove")
    Expect(type(priority:GetPriority()) == "table", "GetPriority")
    Expect(type(priority:GetValues()) == "table", "GetValues")
    Expect(type(priority:GetChecks()) == "table", "GetChecks")
end)

Check("native color picker + keybind", function()
    local raw = tab:RawAddSection("Extras")
    local picker = raw:AddColorPicker({ Name = "Test colour", Toggle = true, Default = Color3.fromRGB(10, 20, 30) })
    picker:Set(Color3.fromRGB(1, 2, 3), true)
    picker:SetEnabled(true, true)
    Expect(picker:Get() == Color3.fromRGB(1, 2, 3), "picker value")
    local key = raw:AddKeybind({ Name = "Test key", Default = Enum.KeyCode.Insert, Hidden = true })
    key:Set(Enum.KeyCode.K)
    Expect(key:Get() == Enum.KeyCode.K, "keybind value")
end)

Check("tab switching", function()
    for _, t in ipairs(win.Tabs) do
        if t.Button then t.Button.MouseButton1Click:Fire() end
    end
end)

Check("search", function()
    win:_search("auto")
    win:_search("")
end)

Check("notifications", function()
    win:Notify({ Title = "Test", Text = "Hello", Duration = 2 })
    win:Notify("Short", "form")
end)

Check("appearance setters", function()
    win:SetTheme({ Accent = Color3.fromRGB(9, 8, 7) })
    Expect(win.Theme.Accent == Color3.fromRGB(9, 8, 7), "theme")
    win:SetPalette("Midnight")
    Expect(win.Palette == "Midnight", "palette")
    win:SetPalette("Default")
    win:SetTextScale(1.25)
    Expect(math.abs(win.TextScale - 1.25) < .001, "text scale")
    win:SetFont("SourceSans")
    Expect(win.FontName == "SourceSans", "font " .. tostring(win.FontName))
    win:SetFont("Gotham")
    win:SetWindowSize(1000, 600)
    Expect(win.Root.Size.X.Offset == 1000 and win.Root.Size.Y.Offset == 600, "window size")
    win:SetScale(1.2)
    win.AnimSpeed = 1.5
    Expect(type(win:GetFontNames()) == "table", "font names")
end)

Check("pinned panel", function()
    local pin = win:AddPin("Pinned Items")
    Expect(pin, "no pin panel")
    pin:SetItems({ "Board", "Stone" })
    pin:AddList("Iron", 3)
    pin:UpdateCounts({ Board = 7 })
    pin:SetSearchSource(function() return { "Board" } end)
    pin:SetCountSource(function() return { Board = 7 } end)
    pin:SetFloating(true)
    pin:SetPosition(30, 40)
    pin:SetMinimized(true)
    pin:SetMinimized(false)
    pin:SetVisible(false)
    pin:SetVisible(true)
    local state = pin:GetState()
    Expect(type(state) == "table" and state.Items, "pin state")
    pin:SetState(state)
    pin:MoveUp("Stone")
    pin:MoveDown("Stone")
    pin:Remove("Iron")
    Expect(#pin:GetItems() >= 1, "pin items")

    local value = Instance.new("StringValue")
    value.Value = "Ore|12,Wood|3"
    Expect(win:BindPinToValue(pin, value, nil) == true, "BindPinToValue")
    value.Value = "Ore|15"
end)

Check("loader + settings tab", function()
    win:SetLoadingProgress(.5, "Half way")
    win:SetLoadingProgress(nil, "Load failed", true)
    win:FinishLoading()
    Expect(win.SettingsTab ~= nil, "settings tab missing")
    local count = 0
    for _, sec in ipairs(win.SettingsTab.Sections) do
        count += #sec.Frame:GetChildren()
    end
    print("     settings sections: " .. #win.SettingsTab.Sections
        .. ", page children: " .. #win.SettingsTab.Page:GetChildren()
        .. ", page descendants: " .. #win.SettingsTab.Page:GetDescendants())
    print("     settings controls: " .. count)
    Expect(count > 20, "settings tab is nearly empty: " .. count)
    win:SelectTab(win.SettingsTab)
end)

local function RowFor(text)
    for _, d in ipairs(win.SettingsTab.Page:GetDescendants()) do
        if d.ClassName == "TextLabel" and d.Text == text then return d.Parent end
    end
end

local function PickOption(rowText, optionText)
    local row = RowFor(rowText)
    Expect(row ~= nil, rowText .. " row missing")
    local box
    for _, d in ipairs(row:GetChildren()) do
        if d.ClassName == "TextButton" then
            box = d
            break
        end
    end
    Expect(box ~= nil, rowText .. " box missing")
    box.MouseButton1Click:Fire()
    for _, d in ipairs(row:GetDescendants()) do
        if d.ClassName == "TextButton" then
            local label = d:FindFirstChildOfClass("TextLabel")
            if label and label.Text == optionText then
                d.MouseButton1Click:Fire()
                return
            end
        end
    end
    error("option not found: " .. optionText, 0)
end

Check("settings: palette dropdown", function()
    PickOption("Menu palette", "Rose")
    Expect(win.Palette == "Rose", "palette " .. tostring(win.Palette))
    local row = RowFor("Background")
    local swatch = row and row:FindFirstChildOfClass("TextButton")
    Expect(swatch ~= nil, "background swatch missing")
    Expect(swatch.BackgroundColor3 == win.Theme.Window, "swatch did not follow the palette")
end)

Check("settings: font dropdown", function()
    PickOption("Font", "SourceSans")
    Expect(win.FontName == "SourceSans", "font " .. tostring(win.FontName))
end)

Check("font follows new text", function()
    local label = win:Label(win.Root, "late label", { Bold = true })
    Expect(label.FontFace.Family == "SourceSans", "late label font " .. tostring(label.FontFace.Family))
end)

Check("settings: text scale slider", function()
    local row = RowFor("Text scale")
    local before = win.TextScale
    local moved = false
    for _, d in ipairs(row:GetDescendants()) do
        if d.ClassName == "TextButton" and d.Text == "›" then
            d.MouseButton1Click:Fire()
            moved = true
            break
        end
    end
    Expect(moved, "right arrow missing")
    Expect(win.TextScale > before, "text scale did not move")
end)

Check("settings: cursor style dropdown", function()
    PickOption("Cursor style", "Cross")
    Expect(win.Cursor.Style == "Cross", "cursor style " .. tostring(win.Cursor.Style))
end)

Check("settings: reset defaults", function()
    win:SetFont("SourceSans")
    win:SetTextScale(1.4)
    win:SetScale(1.3)
    win.AnimSpeed = 2

    local resetButton
    for _, object in ipairs(win.SettingsTab.Page:GetDescendants()) do
        if object.ClassName == "TextLabel" and object.Text == "Reset defaults" then
            resetButton = object.Parent
            break
        end
    end
    Expect(resetButton ~= nil, "Reset defaults button not found")
    resetButton.MouseButton1Click:Fire()

    Expect(win.FontName == "Gotham", "font not reset: " .. tostring(win.FontName))
    Expect(math.abs(win.TextScale - 1) < .001, "text scale not reset")
    Expect(math.abs(win.BaseScale - 1) < .001, "menu scale not reset")
    Expect(math.abs(win.AnimSpeed - 1) < .001, "animation speed not reset")
    Expect(win.Palette == "Default", "palette not reset")
    Expect(win.Theme.Accent == win._DefaultTheme.Accent, "accent colour not reset")
end)

Check("toggle window", function()
    win:Toggle(false)
    win:Toggle(true)
    win:SetVisible(false)
    win:SetVisible(true)
end)

Check("render step", function()
    for _ = 1, 3 do SmokeEnv.RunService.RenderStepped:Fire() end
end)

Check("delayed work", function()
    SmokeEnv.FlushDelayed(100)
end)

Check("destroy", function()
    win:Destroy()
end)

local errors = SmokeEnv.Errors
print(string.format("%d checks failed, %d captured handler errors", failures, #errors))
for index = 1, math.min(#errors, 30) do
    print("  ERR " .. errors[index])
end

if failures > 0 or #errors > 0 then
    error(string.format("%d check(s) failed, %d handler error(s)", failures, #errors), 0)
end

print("UI smoke test passed")
