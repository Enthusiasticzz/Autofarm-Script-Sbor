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
    win = Library.new{ Title = "AIC TEST", ManualLoading = true }
    Expect(win and win.Root, "no window")
end)
if not win then
    print("ABORT: the window could not be built")
    return
end

Check("theme aliases", function()
    Expect(win.Sidebar.BackgroundTransparency == 1, "sidebar covers the rounded window corner")
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

Check("inline labeled controls", function()
    local calls = 0
    local inlineBox = section:AddTextBox{ Name = "Stop name", Default = "One", Inline = true, Callback = function() calls += 1 end }
    Expect(inlineBox.Box.Position.X.Scale == .5, "text box is not on the right")
    local label = inlineBox.Row:FindFirstChildOfClass("TextLabel")
    Expect(label and label.Text == "Stop name", "left label missing")
    inlineBox:Set("Two", true)
    Expect(inlineBox:Get() == "Two" and calls == 0, "silent textbox set failed")
    inlineBox.Box.FocusLost:Fire()
    Expect(calls == 1, "text box callback missing")
    local check = section:AddToggle{ Name = "Reset", Default = false, Callback = function() calls += 1 end }
    check:Set(true)
    Expect(check:Get() and calls == 2, "inline checkmark callback missing")
    local picker = section:AddDropdown{ Name = "Stop", Options = { "A", "B" }, Inline = true, Callback = function() calls += 1 end }
    Expect(picker.Row.Size.Y.Offset == 42, "inline dropdown is not compact")
    picker:OpenList()
    Expect(picker.Open and picker.Row.Size.Y.Offset > 42, "inline dropdown did not open")
    picker:Set("B")
    Expect(picker:Get() == "B" and calls == 3, "inline dropdown selection failed")
    picker:Close()
    Expect(not picker.Open and picker.Row.Size.Y.Offset == 42, "inline dropdown did not close")
end)

Check("AddButton / AddLabel / AddDivider", function()
    local clicked = false
    section:AddButton("Run once", function() clicked = true end, "Runs once.")
    section:AddLabel("A longer label that has to wrap inside the card without overflowing it.")
    section:AddDivider()
    Expect(clicked == false, "button fired early")
end)

Check("tab row + its description as a hover tip", function()
    local t = win.Tabs[1]
    Expect(t ~= nil and t.Label ~= nil, "no tab row")
    Expect(t.Label.Text == "Farming", "tab row lost its name: " .. tostring(t.Label and t.Label.Text))
    Expect(t.Button.Parent == win.TabHolder, "tab row is not in the sidebar list")

    --// A tab's description is shown on hover, not as a heading on the page.
    local described = win:AddTab{ Name = "Notes", Description = "Where the help lines went." }
    described.Button.MouseEnter:Fire()
    FlushDelayed()

    local tip = win._tip
    Expect(tip ~= nil, "hovering a tab opened no tip")
    Expect(tip.Text == "Where the help lines went.", "the tip is not the tab's description")
    described.Button.MouseLeave:Fire()

    --// The page itself starts with its sections, not with a title row.
    for _, child in ipairs(described.Page:GetChildren()) do
        Expect(not child:IsA("TextLabel"), "a heading was added to the page")
    end

    win:SelectTab(described)
    Expect(described.Page.Visible == true, "selecting the tab did not show its page")
    win:SelectTab(t)
    Expect(described.Page.Visible == false, "the page it replaced stayed visible")
end)

Check("status icons sit in the sidebar and toggle", function()
    local heard
    local icon = win:AddStatusIcon{ Name = "Auto Farm", Callback = function(v) heard = v end }
    Expect(icon ~= nil, "no icon")
    Expect(icon.Button.Parent == win.Sidebar, "the icon is not in the sidebar")
    Expect(icon.Button.Position.Y.Scale == 1, "the icon is not docked to the bottom")

    icon:Set(true)
    Expect(icon:Get() == true, "the icon did not light up")
    icon.Button.MouseButton1Click:Fire()
    Expect(icon:Get() == false, "a click did not turn it off")
    Expect(heard == false, "the callback did not hear the new state")
    Expect(#win.StatusIcons == 1, "the icon was not registered")
end)

Check("AddNote joins the hover tip", function()
    local sec = tab:AddSection{ Title = "Notes" }
    local row = sec:AddToggle{ Name = "Auto Block", Default = false, Description = "Blocks anyone off the whitelist." }
    local before = #sec.Frame:GetChildren()
    sec:AddNote("On: the game is closed to the Roblox app once Block Delay runs out")
    Expect(#sec.Frame:GetChildren() == before, "a note still takes a row of its own")

    row.Row.MouseEnter:Fire()
    FlushDelayed()
    local tip = win._tip
    Expect(tip ~= nil, "hovering the control opened no tip")
    Expect(tip.Text:find("Blocks anyone", 1, true) ~= nil, "the tip lost the description")
    Expect(tip.Text:find("Block Delay", 1, true) ~= nil, "the tip lost the note")
    win:_hideTip(true)
end)

Check("a long tip wraps instead of running off the window", function()
    local sec = tab:AddSection{ Title = "Long notes" }
    local row = sec:AddToggle{ Name = "Whitelist Skips Safety", Default = false }
    sec:AddNote(string.rep("Whitelisted players never make Auto Block or Leave On Danger Group leave the server, even if they were blocked earlier. ", 3))

    row.Row.MouseEnter:Fire()
    FlushDelayed()
    local tip = win._tip
    Expect(tip ~= nil, "no tip")
    Expect(tip.TextWrapped == true, "a long tip was not wrapped")
    Expect(tip.Size.Y.Offset > 24, "a wrapped tip kept a single line's height")
    Expect(tip.Size.X.Offset <= 300, "tip ran past the window")
    -- no room above the row in the stub (it sits at 0,0), so it drops below it
    Expect(tip.AnchorPoint.Y == 0, "a tip with no room above did not drop below its control")
    win:_hideTip(true)
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

Check("a priority row can show a name and a second line", function()
    --// The whitelist shows a username with the id under it. The row used to
    --// squeeze both onto one line inside the width of one, which cut it off.
    priority:SetPriority({ "4285700311", "123" }, { 0, 0 }, { false, false })
    priority.Format = function(value)
        if value == "4285700311" then return "@Builder", "ID 4285700311" end
        return "User 123"
    end
    priority:Refresh()
    Expect(priority.Holder:FindFirstChildOfClass("UIPadding").PaddingTop.Offset >= 6, "first row has no top inset")
    for _, child in ipairs(priority.Frame:GetChildren()) do
        Expect(not child:IsA("Frame"), "separator overlaps the first priority row")
    end

    local texts = {}

    for _, child in ipairs(priority.Holder:GetChildren()) do
        if child:IsA("Frame") then
            for _, label in ipairs(child:GetChildren()) do
                if label:IsA("TextLabel") then table.insert(texts, label.Text) end
            end
        end
    end

    local joined = table.concat(texts, "\n")

    Expect(joined:find("@Builder", 1, true) ~= nil, "the name line is missing: " .. joined)
    Expect(joined:find("ID 4285700311", 1, true) ~= nil, "the id line is missing: " .. joined)
    Expect(joined:find("User 123", 1, true) ~= nil, "a one line row lost its text: " .. joined)

    --// No separator may be written as two bytes again: that is what showed
    --// up as a stray second byte in front of the cut.
    Expect(joined:find(string.char(194), 1, true) == nil, "mojibake in a row: " .. joined)
end)

Check("a priority list says how many entries it holds", function()
    priority:SetPriority({ "A", "B", "C" })

    Expect(priority.CountLabel ~= nil, "the list has no count label")
    Expect(priority.CountLabel.Text == "3 ENTRIES", "count reads " .. tostring(priority.CountLabel.Text))

    priority:SetPriority({ "A" })
    Expect(priority.CountLabel.Text == "1 ENTRY", "one entry reads " .. tostring(priority.CountLabel.Text))

    priority:SetPriority({})
    Expect(priority.CountLabel.Text == "EMPTY", "an empty list reads " .. tostring(priority.CountLabel.Text))

    priority:SetPriority({ "A", "B" }, { 3, 4 }, { true, false })
end)

Check("setting a toggle to what it already is does nothing", function()
    --// Auto Block syncs its own toggle from inside that toggle's callback.
    --// Without this, turning it on called itself until the stack ran out.
    local calls = 0
    local t

    t = section:AddToggle{ Name = "Self sync", Default = false, Callback = function()
        calls += 1
        t:Set(t:Get(), true)
    end }

    t:Set(true)
    Expect(calls == 1, "a toggle reported the same value twice: " .. calls)
    t:Set(true)
    Expect(calls == 1, "setting the same value fired the callback: " .. calls)
    t:Set(false)
    Expect(calls == 2, "turning it off did not report: " .. calls)
end)

Check("native color picker + keybind", function()
    local raw = tab:AddSection{ Title = "Extras" }
    local picker = raw:AddColorPicker({ Name = "Test colour", Toggle = true, Default = Color3.fromRGB(10, 20, 30) })
    picker:Set(Color3.fromRGB(1, 2, 3), true)
    picker:SetEnabled(true, true)
    Expect(picker:Get() == Color3.fromRGB(1, 2, 3), "picker value")
    local key = raw:AddKeybind({ Name = "Test key", Default = Enum.KeyCode.Insert, Hidden = true })
    key:Set(Enum.KeyCode.K)
    Expect(key:Get() == Enum.KeyCode.K, "keybind value")
end)

Check("project patterns", function()
    -- a picker rebuilt in place: remove the row, keep its slot, address the new one
    local extra = tab:AddSection{ Title = "Patterns" }
    local first = extra:AddDropdown{ Name = "Picker", Options = { "A" }, Callback = function() end }
    local order = first.Row.LayoutOrder
    local holder = first.Row.Parent
    first:Remove()
    local stillThere = false
    for _, child in ipairs(holder:GetChildren()) do
        if child == first.Row then stillThere = true end
    end
    Expect(not stillThere, "dropdown row survived Remove")
    local second = extra:AddDropdown{ Name = "Picker", Options = { "A", "B" }, Callback = function() end }
    second.Row.LayoutOrder = order
    Expect(second.Row ~= nil, "rebuilt dropdown has no row")

    -- status line that colours itself and a log row that hides
    local status = extra:AddLabel("STATUS")
    status:Set("STATUS  RUNNING")
    status:SetColor(Color3.fromRGB(10, 200, 10))
    Expect(status.Instance.Text == "STATUS  RUNNING", "label Set")
    Expect(status.Instance.TextColor3 == Color3.fromRGB(10, 200, 10), "label SetColor")
    status:SetVisible(false)
    Expect(status.Instance.Visible == false, "label SetVisible")

    -- the old spelling still builds a text box
    local legacy = extra:AddTextbox("Legacy", "seed", function() end)
    Expect(legacy:Get() == "seed", "AddTextbox default")
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

Check("the search box searches once, not per key", function()
    --// The search walks every row and every label in the menu. Running it on
    --// every keystroke is what made typing in the box feel heavy.
    local calls = 0
    local original = win._search

    win._search = function(_, query)
        calls += 1
        win._searchedQuery = query
    end

    win.SearchBox.Text = "a"
    win.SearchBox.Text = "au"
    win.SearchBox.Text = "aut"

    Expect(calls == 0, "the search ran while typing: " .. calls)

    SmokeEnv.FlushDelayed()

    Expect(calls == 1, "three keys searched " .. calls .. " times")
    Expect(win._searchedQuery == "aut", "searched \"" .. tostring(win._searchedQuery) .. "\" instead of the last query")

    --// The same text again (a cursor move) is not a new search.
    win.SearchBox.Text = "aut"
    SmokeEnv.FlushDelayed()

    Expect(calls == 1, "an unchanged query searched again: " .. calls)

    win._search = original
end)

Check("the window is not built from canvas groups", function()
    --// A CanvasGroup renders everything inside it to its own texture. One
    --// around the window (and one per tab page) put a full-screen texture pass
    --// in front of every frame while the menu was open.
    local groups = 0

    for _, obj in ipairs(win.Gui:GetDescendants()) do
        if obj.ClassName == "CanvasGroup" then
            groups += 1
        end
    end

    Expect(groups == 0, "the window still holds " .. groups .. " CanvasGroup(s)")
end)

Check("the menu never takes the camera's mouse away", function()
    --// A Modal GuiButton grabs every input on the screen, and so does any
    --// button as big as the screen: either one kills the right mouse drag that
    --// turns the camera. The window must have neither.
    local step

    for _, fn in pairs(RunService.Steps or {}) do
        step = fn
    end

    Expect(step ~= nil, "the window registered no render step")

    win:Toggle(true)
    step()
    Expect(UserInputService.MouseBehavior == Enum.MouseBehavior.Default, "the menu did not free the cursor")

    local function insideWindow(obj)
        local p = obj.Parent
        while p do
            if p == win.Root then return true end
            p = p.Parent
        end
        return false
    end

    --// Nothing may be modal, and nothing outside the window (which is only as
    --// big as the window) may cover the screen with a button.
    for _, obj in ipairs(win.Gui:GetDescendants()) do
        if obj:IsA("GuiButton") then
            if obj.Modal == true then
                error("modal button in the window: " .. tostring(obj.Name))
            end
            local size = obj.Size
            if not insideWindow(obj) and size.X.Scale >= 1 and size.Y.Scale >= 1 then
                error("a screen sized button covers the game: " .. tostring(obj.Name))
            end
        end
    end

    win:Toggle(false)
    step()
end)

Check("widgets do not call back while they are built", function()
    --// The C stack overflow: a dropdown that rebuilds its own options used to
    --// be told about its own starting value during construction, and called
    --// itself until the stack ran out.
    local calls = 0
    local rebuilt

    rebuilt = section:AddDropdown{ Name = "Rebuild", Options = { "a", "b" }, Default = "a", Callback = function()
        calls += 1
        rebuilt:SetOptions({ "a", "b" })
    end }

    section:AddToggle{ Name = "Rebuild Toggle", Default = false, Callback = function() calls += 1 end }
    section:AddSlider{ Name = "Rebuild Slider", Default = 1, Min = 0, Max = 5, Callback = function() calls += 1 end }

    Expect(calls == 0, "a widget ran its callback while being built (" .. calls .. " times)")

    --// And still answers the user.
    rebuilt:Set("b")
    Expect(calls == 1, "a dropdown no longer reports a change: " .. calls)
end)

Check("notifications stay bounded", function()
    --// A loop that reports one thing per recipe used to stack a card each.
    for i = 1, 12 do
        win:Notify({ Title = "AUTO SMITHING", Text = "Recipe " .. i .. " failed 3 times; paused 60s", Duration = 2 })
    end

    Expect(#win._notifs == 4, "the notification stack is not capped: " .. #win._notifs)

    local cards = 0

    for _, child in ipairs(win.NotifHolder:GetChildren()) do
        if child:IsA("Frame") then
            cards += 1
        end
    end

    Expect(cards == 4, "the holder kept " .. cards .. " cards")

    --// The same message twice is one card, not two.
    win:Notify({ Title = "Same", Text = "message", Duration = 2 })
    local before = #win._notifs
    win:Notify({ Title = "Same", Text = "message", Duration = 2 })
    Expect(#win._notifs == before, "an identical message stacked a second card")
end)

Check("appearance setters", function()
    win:SetTheme({ Accent = Color3.fromRGB(9, 8, 7) })
    Expect(win.Theme.Accent == Color3.fromRGB(9, 8, 7), "theme")
    win:SetPalette("Midnight")
    Expect(win.Palette == "Midnight", "palette")
    win:SetPalette("Default")
    win:SetTextScale(1.25)
    Expect(math.abs(win.TextScale - 1.25) < .001, "text scale")
    local fontNames = win:_GetFontChoices().Names
    Expect(#fontNames > 0, "no fonts offered")
    win:SetFont(fontNames[1])
    Expect(win.FontName == fontNames[1], "font " .. tostring(win.FontName))
    win:SetFont("Gotham")
    win:SetWindowSize(1000, 600)
    Expect(win.Root.Size.X.Offset == 1000 and win.Root.Size.Y.Offset == 600, "window size")
    win:SetScale(1.2)
    win.AnimSpeed = 1.5
    Expect(type(win:_GetFontChoices().Names) == "table", "font names")
end)

Check("no pinned items panel is built any more", function()
    --// It sat outside the tabs and was bound to the inventory, which changes
    --// constantly; it is gone, so the library must not offer it either.
    Expect(win.AddPin == nil, "the window still has AddPin")
    Expect(win.BindPinToValue == nil, "the window still has BindPinToValue")

    for _, obj in ipairs(win.Gui:GetDescendants()) do
        Expect(obj.Name ~= "PinPanel", "a pinned items panel is still in the window")
    end
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
    local pick = win:_GetFontChoices().Names[2]
    PickOption("Font", pick)
    Expect(win.FontName == pick, "font " .. tostring(win.FontName))
end)

Check("font follows new text", function()
    local label = win:Label(win.Root, "late label", { Bold = true })
    Expect(label.Font == Enum.Font[win.FontName], "late label font " .. tostring(win.FontName))
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

    -- the slider has to reach the text, not just the number
    local sample = win:Label(win.Root, "scale sample", { TextSize = 14 })
    win:SetTextScale(1.5)
    Expect(sample.TextSize == 21, "label did not follow text scale: " .. tostring(sample.TextSize))
    win:SetTextScale(before)
end)

Check("settings: cursor style dropdown", function()
    PickOption("Cursor style", "Cross")
    Expect(win.Cursor.Style == "Cross", "cursor style " .. tostring(win.Cursor.Style))
end)

Check("settings: every saved option reports a change", function()
    --// The project writes these to its global file from this one hook, so
    --// each setter has to hand it the new state.
    local seen, calls = nil, 0
    win.OnSettingsChanged = function(state)
        seen = state
        calls += 1
    end

    win:SetMenuKey(Enum.KeyCode.J)
    Expect(calls == 1, "menu key did not report a change")
    Expect(seen.MenuKey == "J", "saved menu key " .. tostring(seen and seen.MenuKey))

    win:SetCursor{ Mode = "Always", Size = 140 }
    Expect(seen.Cursor.Mode == "Always" and seen.Cursor.Size == 140, "cursor not in the saved state")

    win:SetWindowSize(900, 620)
    Expect(seen.WindowWidth == 900 and seen.WindowHeight == 620, "window size not in the saved state")

    win:SetNotificationsEnabled(false)
    Expect(seen.Notifications == false, "notifications not in the saved state")
    win:SetNotificationsEnabled(true)

    win:SetNotificationPosition("Top center")
    Expect(seen.NotificationPosition == "Top center", "notification position not in the saved state")
    win:SetNotificationPosition("Bottom right")

    win:SetTabAnimation("Slide")
    Expect(seen.TabAnimation == "Slide", "tab animation not in the saved state")

    win:SetWatermark(true)
    Expect(seen.Watermark == true, "watermark not in the saved state")
    win:SetWatermark(false)

    win:SetKeybindList(true)
    Expect(seen.KeybindList == true, "keybind list not in the saved state")
    win:SetKeybindList(false)

    win.OnSettingsChanged = nil
end)

Check("settings: a palette saves its colours", function()
    local themed = 0
    win.OnThemeChanged = function() themed += 1 end
    win:SetPalette("Forest")
    Expect(win.Theme.Window == Library.Palettes.Forest.Window, "palette did not reach the theme")
    Expect(themed == 1, "a palette change did not report the new theme")
    win.OnThemeChanged = nil
    win:SetPalette("Default")
end)

Check("settings: saved values are applied before the tab is built", function()
    win:ApplyUISettings{
        MenuKey = "K",
        Palette = "Forest",
        WindowWidth = 820,
        WindowHeight = 540,
        TabAnimation = "None",
        Notifications = false,
        NotificationPosition = "Top left",
        Watermark = true,
        KeybindList = true,
        Cursor = { Mode = "Never", Style = "Circle", Size = 70, Effects = false, CustomEnabled = true, Color = "FF8800" },
    }

    Expect(win.MenuKey == Enum.KeyCode.K, "menu key not applied")
    Expect(win.Palette == "Forest", "palette not applied")
    Expect(win.Root.Size.X.Offset == 820 and win.Root.Size.Y.Offset == 540, "window size not applied")
    Expect(win.Sidebar.Size.Y.Offset == 540, "the sidebar did not follow the height")
    Expect(win.TabAnimation == "None", "tab animation not applied")
    Expect(win.Notifications.Enabled == false and win.Notifications.Position == "Top left", "notifications not applied")
    Expect(win.Watermark.Visible == true and win.KeybindFrame.Visible == true, "watermark / keybind list not applied")
    Expect(win.Cursor.Mode == "Never" and win.Cursor.Style == "Circle" and win.Cursor.Size == 70, "cursor not applied")
    Expect(win.Cursor.Effects == false and win.Cursor.CustomEnabled == true, "cursor switches not applied")
    Expect(win.Cursor.Color == Color3.fromHex("FF8800"), "cursor colour not applied")

    local state = win:GetUISettings()
    Expect(state.MenuKey == "K" and state.WindowWidth == 820, "the state does not round trip")
    Expect(state.Cursor.Color == "FF8800", "the cursor colour does not round trip: " .. tostring(state.Cursor.Color))
    Expect(state.Palette == "Forest", "the palette does not round trip")
end)

Check("settings: restore defaults", function()
    win:SetTextScale(1.4)
    win.AnimSpeed = 2
    win:SetPalette("Rose")

    local resetButton
    for _, object in ipairs(win.SettingsTab.Page:GetDescendants()) do
        if object.ClassName == "TextLabel" and object.Text == "Restore defaults" then
            resetButton = object.Parent
            break
        end
    end
    Expect(resetButton ~= nil, "Restore defaults button not found")
    resetButton.MouseButton1Click:Fire()

    Expect(math.abs(win.TextScale - 1) < .001, "text scale not reset")
    Expect(math.abs(win.AnimSpeed - 1) < .001, "animation speed not reset")
    Expect(win.Palette == "Default", "palette not reset")
    Expect(win.Theme.Accent == win._DefaultTheme.Accent, "accent colour not reset")
end)

Check("error screen", function()
    win:ShowError("Bootstrap failed to start\nBootstrap.lua:319: attempt to index nil with 'UIRef'\n(error value: string)")
    Expect(win.ErrorPanel ~= nil, "no error panel")
    Expect(string.find(win.ErrorPanel.Text.Text, "UIRef") ~= nil, "error text missing")
    win:ShowError("second failure")
    Expect(win.ErrorPanel.Text.Text == "second failure", "error text did not update")
end)

Check("toggle window", function()
    win:Toggle(false)
    SmokeEnv.FlushDelayed(50)
    Expect(win.Root.Visible == false, "window did not close")
    win:Toggle(true)
    Expect(win.Root.Visible == true, "window did not reopen")
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
