-- EQUIP PANEL PROBE  (v2)
--
-- Paste this whole file into the executor. The menu may be open or closed; the
-- probe opens what it needs, measures, and puts the menu back the way it found
-- it. It only changes UI state (page/filter presses) and, in one gated section
-- (E), equips one item and puts the worn one back.
--
-- It answers the questions the fast path depends on:
--   A. every child of FrontRight, and what each one is
--   B. the Equipment page: its own children, and the Filters frame that
--      refills the list
--   C. how the list gets filled: pressing the Equipment tab vs a filter, how
--      long each takes, and whether a filter refills it while the page is
--      hidden
--   D. whether a card's equip button is still bound while the page is hidden
--      (that is what decides if the menu can be skipped entirely)
--   E. one real press on a hidden card, checked against PlayerStats, then the
--      worn item put back
--   F. whether the list holds every item or only a window of them: what the
--      search box says, the canvas size, and the card count after scrolling
--      to the bottom
--
-- Read the [PANEL] lines. Anything that throws is caught and printed, so one
-- bad node cannot swallow the rest of the report.
--
-- One thing v1 got wrong: the panel rebuilds (and re-pools) its cards the
-- moment an item goes on, so a card held from before the press is gone or has
-- another item's data on it. Section E now looks its card up again before every
-- press, which is what makes the undo work; a stale node was why v1 could not
-- put the worn item back.

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--// Set false to skip section E (the only part that equips anything).
local TEST_HIDDEN_PRESS = true

local MAX_LINES = 400
local MAX_CARDS = 400
local TEXT_LIMIT = 40
local MAX_DEPTH = 4

local lines = 0

local function out(fmt, ...)
    if lines >= MAX_LINES then
        return
    end

    lines += 1
    local Ok, Text = pcall(string.format, fmt, ...)
    print("[PANEL] " .. (Ok and Text or tostring(fmt)))
end

local function step(Name, Body)
    out("-- " .. Name)

    local Ok, Err = pcall(Body)

    if not Ok then
        out("   THREW: " .. tostring(Err))
    end
end

local function Trim(Text)
    return (tostring(Text or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function Clip(Text)
    local Clean = Trim(Text):gsub("%s+", " ")

    if #Clean > TEXT_LIMIT then
        return string.sub(Clean, 1, TEXT_LIMIT) .. "…"
    end

    return Clean
end

local function Follow(Root, ...)
    local Node = Root

    for _, Name in ipairs({ ... }) do
        Node = Node and Node:FindFirstChild(Name)

        if not Node then
            return nil
        end
    end

    return Node
end

local function Kids(Node)
    if not Node then
        return {}
    end

    local Ok, Children = pcall(function()
        return Node:GetChildren()
    end)

    return Ok and Children or {}
end

local function IsA(Node, Class)
    local Ok, Result = pcall(function()
        return Node:IsA(Class)
    end)

    return Ok and Result
end

local function TextOf(Node)
    local Ok, Text = pcall(function()
        return Node.ContentText
    end)

    if Ok and type(Text) == "string" and Text ~= "" then
        return Trim(Text)
    end

    local Ok2, Raw = pcall(function()
        return Node.Text
    end)

    return Ok2 and tostring(Raw) or ""
end

local function ValueOf(Node)
    local Ok, Value = pcall(function()
        return Node.Value
    end)

    return Ok and Value or nil
end

--// A property that may not exist on this class; nil instead of an error.
local function Prop(Node, Key)
    local Ok, Value = pcall(function()
        return Node[Key]
    end)

    return Ok and Value or nil
end

local function SizeOf(Node)
    local Ok, Size = pcall(function()
        return Node.AbsoluteSize
    end)

    if not Ok or not Size then
        return "?"
    end

    local OkX, X = pcall(function()
        return Size.X
    end)

    local OkY, Y = pcall(function()
        return Size.Y
    end)

    if not (OkX and OkY) then
        return "?"
    end

    return string.format("%dx%d", math.floor(X), math.floor(Y))
end

--// Drawn right now: every frame above it is visible and the screen is on.
--// PlayerGui has no Enabled, so reaching it counts as shown.
local function OnScreen(Node)
    if not Node then
        return false
    end

    local Current = Node

    while Current do
        local OkVisible, Visible = pcall(function()
            return Current.Visible
        end)

        if OkVisible and Visible == false then
            return false
        end

        local OkLayer, IsLayer = pcall(function()
            return Current:IsA("LayerCollector")
        end)

        if OkLayer and IsLayer then
            local OkEnabled, Enabled = pcall(function()
                return Current.Enabled
            end)

            return OkEnabled and Enabled ~= false or false
        end

        if Current.ClassName == "PlayerGui" then
            return true
        end

        Current = Current.Parent
    end

    return false
end

local function Describe(Node)
    local Parts = {}

    table.insert(Parts, "[" .. tostring(Node.ClassName) .. "] " .. tostring(Node.Name))
    table.insert(Parts, "visible " .. tostring((pcall(function()
        return Node.Visible
    end) and Node.Visible) or "n/a"))
    table.insert(Parts, "on screen " .. tostring(OnScreen(Node)))

    if IsA(Node, "GuiObject") then
        table.insert(Parts, "size " .. SizeOf(Node))
    end

    if IsA(Node, "TextButton") or IsA(Node, "TextLabel") or IsA(Node, "ImageButton") then
        local Text = Clip(TextOf(Node))

        if Text ~= "" then
            table.insert(Parts, "text \"" .. Text .. "\"")
        end
    end

    if IsA(Node, "StringValue") or IsA(Node, "BoolValue") or IsA(Node, "NumberValue") then
        table.insert(Parts, "value " .. tostring(ValueOf(Node)))
    end

    return table.concat(Parts, "  ")
end

--// A card is a button with a Type value and an Entry frame; the Base template
--// has neither name nor type, so it is not one.
local function IsCard(Node)
    if Node.Name == "Base" or Node.Name == "Template" then
        return false
    end

    if not IsA(Node, "GuiObject") then
        return false
    end

    if not Node:FindFirstChild("Entry") then
        return false
    end

    local TypeNode = Node:FindFirstChild("Type")

    return TypeNode ~= nil and Trim(ValueOf(TypeNode)) ~= ""
end

local function Cards(List)
    local Found = {}

    for _, Child in ipairs(Kids(List)) do
        if IsCard(Child) then
            table.insert(Found, Child)
        end
    end

    return Found
end

--// The card for this item right now. The panel rebuilds its cards after every
--// press, so this is looked up again each time instead of held.
local function FindCard(Name)
    for _, Card in ipairs(Cards(List)) do
        if Card.Name == Name then
            return Card
        end
    end

    return nil
end

local function CardSummary(Card)
    local Entry = Card:FindFirstChild("Entry")
    local Typed = Card:FindFirstChild("Type")
    local Worn = Card:FindFirstChild("isEquipped")

    return string.format(
        "%s  type \"%s\"  %s %s  worn %s",
        Card.Name,
        Clip(tostring(ValueOf(Typed) or "")),
        Clip(TextOf(Entry and Entry:FindFirstChild("Requirement") or nil)),
        Clip(TextOf(Entry and Entry:FindFirstChild("RequiredAmount") or nil)),
        tostring(Worn and ValueOf(Worn))
    )
end

local function Connections(Signal)
    if type(getconnections) ~= "function" then
        return "no getconnections"
    end

    local Ok, List = pcall(getconnections, Signal)

    if not Ok or type(List) ~= "table" then
        return "?"
    end

    return tostring(#List)
end

local Start = os.clock()

local function Now()
    return string.format("%.2fs", os.clock() - Start)
end

--// Measures how long a press takes to make Check() true. Returns the seconds
--// taken, or nil on timeout. .12 s poll: the game applies an equip on the next
--// frame, so a coarser poll would only add latency to the number.
local function TimeUntil(Check, Seconds)
    local Deadline = os.clock() + Seconds

    while os.clock() < Deadline do
        local Ok, Done = pcall(Check)

        if Ok and Done then
            return os.clock() - (Deadline - Seconds)
        end

        task.wait(0.12)
    end

    return nil
end

--// Fires the handlers of the FIRST signal that has any, and only that one:
--// a menu button that hears two signals would toggle twice and end up where
--// it started. Returns the signal that answered, or nil.
local function Press(Button)
    if not Button then
        return nil
    end

    for _, Name in ipairs({ "MouseButton1Click", "MouseButton1Down", "Activated" }) do
        local Signal = Button[Name]

        if Signal then
            if type(getconnections) == "function" then
                local Ok, Heard = pcall(getconnections, Signal)

                if Ok and type(Heard) == "table" and #Heard > 0 then
                    for _, Connection in ipairs(Heard) do
                        pcall(function()
                            Connection:Fire()
                        end)
                    end

                    return Name
                end
            elseif type(firesignal) == "function" then
                if pcall(firesignal, Signal) then
                    return Name
                end
            end
        end
    end

    return nil
end

local GameGui = PlayerGui:WaitForChild("GameGui")
local MenuGui = GameGui:FindFirstChild("MenuGui-NEW")
local FrontRight = MenuGui and MenuGui:FindFirstChild("FrontRight")
local Menu = FrontRight and FrontRight:FindFirstChild("Menu")
local Frames = Menu and Menu:FindFirstChild("Frames")
local Equipment = Frames and Frames:FindFirstChild("Equipment")
local FrameB = Equipment and Equipment:FindFirstChild("FrameB")
local List = FrameB and FrameB:FindFirstChild("List")
local Filters = FrameB and FrameB:FindFirstChild("Filters")

--// Whether the menu was up when the probe started, so it can be put back.
local MenuWasShown = OnScreen(MenuGui)

out("FrontRight found: %s   menu showing: %s", tostring(FrontRight ~= nil), tostring(MenuWasShown))
out("equipment page visible: %s   frameB: %s   list: %s   filters: %s", tostring(Equipment and Equipment.Visible), tostring(FrameB ~= nil), tostring(List ~= nil), tostring(Filters ~= nil))
out("cards already built: %d", #Cards(List))

------------------------------------------------------------------------
--// A. FrontRight, everything in it
------------------------------------------------------------------------

step("A. FrontRight children", function()
    for _, Child in ipairs(Kids(FrontRight)) do
        out("   %s   children %d", Describe(Child), #Kids(Child))

        --// One level deeper, but never into the item list: it holds hundreds
        --// of cards and would bury every section after it.
        for _, Grandchild in ipairs(Kids(Child)) do
            if Grandchild ~= List then
                out("      %s   children %d", Describe(Grandchild), #Kids(Grandchild))
            else
                out("      [TextButton] %s  (the item list, reported in C)", Grandchild.Name)
            end
        end
    end
end)

step("A2. FrontRight deep scan, names only (depth " .. MAX_DEPTH .. ")", function()
    local function Walk(Node, Depth)
        if Depth > MAX_DEPTH then
            return
        end

        for _, Child in ipairs(Kids(Node)) do
            if Child == List then
                out("%s%s  (list, skipped)", string.rep("  ", Depth), Child.Name)
            elseif IsCard(Child) then
                out("%s%s  (card, skipped)", string.rep("  ", Depth), Child.Name)
            else
                out(
                    "%s%s  [%s]  visible %s  on screen %s",
                    string.rep("  ", Depth),
                    Child.Name,
                    tostring(Child.ClassName),
                    tostring((pcall(function()
                        return Child.Visible
                    end) and Child.Visible) or "n/a"),
                    tostring(OnScreen(Child))
                )
                Walk(Child, Depth + 1)
            end
        end
    end

    Walk(FrontRight, 1)
end)

------------------------------------------------------------------------
--// B. The Equipment page and its filters
------------------------------------------------------------------------

step("B. Equipment page children", function()
    for _, Child in ipairs(Kids(Equipment)) do
        out("   %s", Describe(Child))
    end
end)

step("B2. FrameB children (the row above the list)", function()
    for _, Child in ipairs(Kids(FrameB)) do
        out("   %s", Describe(Child))
    end
end)

step("B3. Filters: what a filter button is", function()
    if not Filters then
        out("   no Filters frame at FrameB.Filters")
        return
    end

    out("   %s", Describe(Filters))

    for _, Child in ipairs(Kids(Filters)) do
        out("   %s   children %d", Describe(Child), #Kids(Child))

        for _, Flag in ipairs(Kids(Child)) do
            if IsA(Flag, "ValueBase") then
                out("      %s", Describe(Flag))
            end
        end
    end
end)

step("B4. Every button on the page that could open or refill it", function()
    local Seen = {}

    local function Walk(Node, Depth)
        if Depth > 5 then
            return
        end

        for _, Child in ipairs(Kids(Node)) do
            if Child ~= List and not IsCard(Child) then
                if IsA(Child, "GuiButton") then
                    local Key = Child:GetFullName()

                    if not Seen[Key] then
                        Seen[Key] = true
                        out("   %s", Describe(Child))
                    end
                end

                Walk(Child, Depth + 1)
            end
        end
    end

    Walk(FrontRight, 1)
end)

------------------------------------------------------------------------
--// C. How the list gets filled
------------------------------------------------------------------------

local Watched = 0
local Watcher = nil

if List then
    local Ok, Connection = pcall(function()
        return List.ChildAdded:Connect(function()
            Watched += 1
        end)
    end)

    if Ok then
        Watcher = Connection
    end
end

step("C0. list as it is now", function()
    out("   children %d   cards %d   ChildAdded seen %d", #Kids(List), #Cards(List), Watched)

    for Index, Card in ipairs(Cards(List)) do
        if Index > 5 then
            break
        end

        out("   %s", CardSummary(Card))
    end
end)

step("C1. Equip tab press: does it rebuild the cards, and how fast", function()
    local Tab = FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player", "Equipment")
        or FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player-PageLayout", "Equipment")

    if not Tab then
        out("   no Equipment tab found under MidFrames")
        return
    end

    out("   tab %s", Describe(Tab))

    local Before = #Cards(List)
    local Seen = Watched
    local Pressed = Press(Tab)
    local Took = TimeUntil(function()
        return #Cards(List) > 0
    end, 4)

    task.wait(0.4)

    out("   pressed via %s   first card after %s   cards %d -> %d   ChildAdded +%d   now %s", tostring(Pressed), Took and string.format("%.2fs", Took) or "4s timeout", Before, #Cards(List), Watched - Seen, Now())
end)

step("C2. Filter press: does it refill the list, and how fast", function()
    if not Filters then
        out("   no Filters frame")
        return
    end

    local First

    for _, Child in ipairs(Kids(Filters)) do
        if IsA(Child, "GuiButton") then
            First = First or Child
        end
    end

    if not First then
        out("   no filter button found")
        return
    end

    out("   filter %s", Describe(First))

    local Before = #Cards(List)
    local Seen = Watched
    local Pressed = Press(First)
    local Took = TimeUntil(function()
        return Watched > Seen or #Cards(List) ~= Before
    end, 4)

    task.wait(0.3)

    out("   pressed via %s   list changed after %s   cards %d -> %d   ChildAdded +%d", tostring(Pressed), Took and string.format("%.2fs", Took) or "4s timeout", Before, #Cards(List), Watched - Seen)

    --// Put the full list back: a filter press twice is the documented way.
    Press(First)
    task.wait(0.5)
    out("   pressed again   cards %d   ChildAdded +%d", #Cards(List), Watched - Seen)
end)

step("C3. Does the list keep its cards with the page put away", function()
    local MenuButton = Follow(PlayerGui, "DeviceGui", "ConsolePC", "MenuButton")
        or Follow(PlayerGui, "DeviceGui", "Mobile", "MobileMenuButton")

    out("   menu showing now: %s   page visible: %s", tostring(OnScreen(MenuGui)), tostring(Equipment and Equipment.Visible))

    if not MenuButton then
        out("   no menu button found: close the menu by hand and re-run to measure the hidden case")
        return
    end

    Press(MenuButton)
    task.wait(0.6)

    out("   menu pressed   menu showing: %s   page visible: %s   cards %d", tostring(OnScreen(MenuGui)), tostring(Equipment and Equipment.Visible), #Cards(List))

    --// With the page away, does a filter still refill it?
    local First

    for _, Child in ipairs(Kids(Filters)) do
        if IsA(Child, "GuiButton") then
            First = First or Child
        end
    end

    if First then
        local Before = #Cards(List)
        local Seen = Watched
        local Pressed = Press(First)
        local Took = TimeUntil(function()
            return Watched > Seen or #Cards(List) ~= Before
        end, 3)

        out("   filter pressed with the page away: via %s   changed after %s   cards %d -> %d   ChildAdded +%d", tostring(Pressed), Took and string.format("%.2fs", Took) or "3s timeout", Before, #Cards(List), Watched - Seen)

        Press(First)
        task.wait(0.3)
    end
end)

------------------------------------------------------------------------
--// D. The card's equip button while the page is away
------------------------------------------------------------------------

local ProbeCard

step("D. equip button: bound on screen vs hidden", function()
    local All = Cards(List)

    if #All == 0 then
        out("   no cards to inspect")
        return
    end

    --// An item that is not on: pressing it would be a change, and the point
    --// here is only to see whether the button is still wired.
    for _, Card in ipairs(All) do
        local Worn = Card:FindFirstChild("isEquipped")

        if not (Worn and ValueOf(Worn)) then
            ProbeCard = Card
            break
        end
    end

    ProbeCard = ProbeCard or All[1]

    local Buttons = ProbeCard:FindFirstChild("Buttons")
    local E = Buttons and Buttons:FindFirstChild("E")

    if not E then
        out("   %s has no Buttons.E", ProbeCard.Name)
        return
    end

    local function Report(When)
        out(
            "   %s: %s  visible %s  on screen %s  size %s  click conns %s  down conns %s  activated conns %s",
            When,
            ProbeCard.Name,
            tostring(E.Visible),
            tostring(OnScreen(E)),
            SizeOf(E),
            Connections(E.MouseButton1Click),
            Connections(E.MouseButton1Down),
            Connections(E.Activated)
        )
    end

    out("   card %s", CardSummary(ProbeCard))
    Report("hidden")

    --// Show the page, and look again: that is the difference that decides
    --// whether the menu can be skipped.
    local Tab = FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player", "Equipment")
        or FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player-PageLayout", "Equipment")

    local MenuButton = Follow(PlayerGui, "DeviceGui", "ConsolePC", "MenuButton")
        or Follow(PlayerGui, "DeviceGui", "Mobile", "MobileMenuButton")

    if MenuButton and not OnScreen(MenuGui) then
        Press(MenuButton)
        task.wait(0.5)
        Tab = FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player", "Equipment")
            or FrontRight and Follow(FrontRight, "Menu", "MidFrames", "Player-PageLayout", "Equipment")
    end

    if Tab then
        Press(Tab)
        task.wait(0.6)
    end

    Report("shown")

    local Fresh = ProbeCard

    for _, Card in ipairs(Cards(List)) do
        if Card.Name == ProbeCard.Name then
            Fresh = Card
            break
        end
    end

    ProbeCard = Fresh
end)

------------------------------------------------------------------------
--// E. One real press with the page hidden
------------------------------------------------------------------------

step("E. a press with the page hidden", function()
    if not TEST_HIDDEN_PRESS then
        out("   skipped (TEST_HIDDEN_PRESS = false)")
        return
    end

    if not ProbeCard then
        out("   no card to press")
        return
    end

    local PlayerStats = LocalPlayer:FindFirstChild("PlayerStats")

    if not PlayerStats then
        out("   no PlayerStats: nothing could be verified")
        return
    end

    --// The worn item's card has to be in the list, or the press could not be
    --// undone.
    local WornName = ""

    local Typed = ProbeCard:FindFirstChild("Type")
    local TypeText = Trim(tostring(ValueOf(Typed) or ""))

    local FieldByType = {
        ["One-Handed"] = "Weapon",
        ["Two-Handed"] = "Weapon",
        ["Rapier"] = "Weapon",
        ["Dagger"] = "Weapon",
        ["Melee"] = "Weapon",
        ["Shield"] = "Shield",
        ["Outfit"] = "Outfit",
        ["UpperHeadwear"] = "UpperHeadwear",
        ["LowerHeadwear"] = "LowerHeadwear",
        ["Facewear"] = "Facewear",
        ["Armor3D"] = "Armor3D",
    }

    local WornField = FieldByType[TypeText]

    if not WornField then
        out("   type \"%s\" has no known worn field, so nothing can be put back", TypeText)
        return
    end

    local Field = PlayerStats:FindFirstChild(WornField)
    WornName = Field and Trim(tostring(ValueOf(Field))) or ""

    if WornName ~= "" then
        if not FindCard(WornName) then
            out("   the worn %s \"%s\" has no card in the list, so a press could not be undone: skipped", WornField, WornName)
            return
        end
    end

    --// Put the page away first: the whole point is a press without it.
    local MenuButton = Follow(PlayerGui, "DeviceGui", "ConsolePC", "MenuButton")
        or Follow(PlayerGui, "DeviceGui", "Mobile", "MobileMenuButton")

    if MenuButton and OnScreen(MenuGui) then
        Press(MenuButton)
        task.wait(0.6)
    end

    out("   page away: menu showing %s   page visible %s", tostring(OnScreen(MenuGui)), tostring(Equipment and Equipment.Visible))

    --// Looked up again: section D may have rebuilt the list.
    local Live = FindCard(ProbeCard.Name) or ProbeCard
    local Buttons = Live:FindFirstChild("Buttons")
    local E = Buttons and Buttons:FindFirstChild("E")

    if not E then
        out("   card has no Buttons.E")
        return
    end

    local Before = WornName
    local Started = os.clock()
    local Via = Press(E)
    local Took = TimeUntil(function()
        local Now = Field and Trim(tostring(ValueOf(Field))) or ""
        return Now ~= Before
    end, 2.5)
    local After = Field and Trim(tostring(ValueOf(Field))) or ""

    out("   pressed %s via %s   worn %s -> %s   after %s (%.2fs)", Live.Name, tostring(Via), Before ~= "" and Before or "empty", After ~= "" and After or "empty", Took and string.format("%.2fs", Took) or "2.5s timeout", os.clock() - Started)

    if After == Before then
        out("   RESULT: a hidden press does NOT equip. The page has to be shown before the equip button works.")
        return
    end

    out("   RESULT: a hidden press DOES equip. The menu can be skipped once the cards exist.")

    if Before ~= "" then
        local Restored = false

        --// Three tries, each on a card looked up again: the press that just
        --// went through rebuilt the list, and the next one will too.
        for Attempt = 1, 3 do
            local Back = FindCard(Before)
            local BackButtons = Back and Back:FindFirstChild("Buttons")
            local BackE = BackButtons and BackButtons:FindFirstChild("E")

            if not BackE then
                out("   try %d: \"%s\" has no card on the page", Attempt, Before)
                task.wait(0.2)
            else
                Press(BackE)

                if TimeUntil(function()
                    return (Field and Trim(tostring(ValueOf(Field))) or "") == Before
                end, 2) then
                    out("   put \"%s\" back (try %d)", Before, Attempt)
                    Restored = true
                    break
                end
            end

            task.wait(0.2)
        end

        if not Restored then
            local Now = Field and Trim(tostring(ValueOf(Field))) or ""
            out("   WARNING: could not put \"%s\" back (worn is \"%s\"). Press Equip Now in the Gear tab.", Before, Now ~= "" and Now or "empty")
        end
    end
end)

------------------------------------------------------------------------
--// F. Is the panel showing every item, or only a window of them
------------------------------------------------------------------------

step("F. how much of the list exists at once", function()
    if not List then
        out("   no list")
        return
    end

    local function Number(Value)
        if not Value then
            return "?"
        end

        local Ok, Y = pcall(function()
            return Value.Y
        end)

        return Ok and string.format("%d", math.floor(Y)) or "?"
    end

    local SearchBar = FrameB and FrameB:FindFirstChild("SearchBar")
    local SearchBox = SearchBar and SearchBar:FindFirstChildWhichIsA("TextBox", true)
    local SearchText = ""

    if SearchBox then
        local Ok, Text = pcall(function()
            return SearchBox.Text
        end)

        SearchText = Ok and tostring(Text) or "?"
    end

    out("   list is a %s   cards %d of %d children", tostring(List.ClassName), #Cards(List), #Kids(List))
    out("   canvas %s   position %s   scrolling %s   search box \"%s\"", Number(Prop(List, "AbsoluteCanvasSize")), Number(Prop(List, "CanvasPosition")), tostring(Prop(List, "ScrollingEnabled")), Clip(SearchText))

    local Before = #Cards(List)
    local Seen = Watched

    --// Scrolling to the bottom is what tells a windowed list (more cards
    --// appear as you scroll) from one that holds every item at once.
    pcall(function()
        List.CanvasPosition = Vector2.new(0, List.AbsoluteCanvasSize.Y)
    end)

    task.wait(0.6)

    out("   scrolled to the bottom: cards %d -> %d   ChildAdded +%d", Before, #Cards(List), Watched - Seen)

    pcall(function()
        List.CanvasPosition = Vector2.new(0, 0)
    end)

    task.wait(0.4)

    out("   scrolled back: cards %d", #Cards(List))
end)

------------------------------------------------------------------------
--// G. Summary
------------------------------------------------------------------------

step("F. what this means", function()
    out("   cards in the list now: %d   ChildAdded events seen: %d", #Cards(List), Watched)
    out("   filters: %d   menu showing: %s   page visible: %s", #(Filters and Kids(Filters) or {}), tostring(OnScreen(MenuGui)), tostring(Equipment and Equipment.Visible))
    out("   done in %s — paste every [PANEL] line", Now())
end)

step("G. putting the menu back", function()
    if MenuWasShown or not OnScreen(MenuGui) then
        out("   left as found (menu showing: %s)", tostring(OnScreen(MenuGui)))
        return
    end

    local MenuButton = Follow(PlayerGui, "DeviceGui", "ConsolePC", "MenuButton")
        or Follow(PlayerGui, "DeviceGui", "Mobile", "MobileMenuButton")

    if MenuButton then
        Press(MenuButton)
        task.wait(0.4)
        out("   closed the menu this probe opened")
    else
        out("   no menu button, so the menu this probe opened is still up")
    end
end)

if Watcher then
    pcall(function()
        Watcher:Disconnect()
    end)
end
