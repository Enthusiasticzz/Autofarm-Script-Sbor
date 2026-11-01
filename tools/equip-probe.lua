-- EQUIP PROBE  (v2)
--
-- Run this **with the equipment page open**: open the game menu, click the
-- Equipment tab so the item cards are on screen, then paste this whole file
-- into the executor and read the [EQUIP] lines. It only reads: nothing is
-- equipped, clicked or changed.
--
-- v2 exists because v1 proved the list is not one child per item. Under
-- `Frames.Equipment.FrameB.List` there is a `UIListLayout` and a `Base`
-- TextButton that is a **template** (its labels read 999 / 9999 and `Type` is
-- empty); the real cards are cloned from it and only exist once the page is
-- shown. So this version ignores the template and reports the cards.
--
-- It answers:
--   A. your level, every skill number, and what is worn
--   B. where the list is, whether the equipment page is showing, and what the
--      template holds (so the template can be excluded safely)
--   C. the real cards: every label, and for Type / Requirement / isEquipped
--      every distinct value with how many cards carry it — this is the slot
--      vocabulary and the worn marker
--   D. three whole cards in full, preferring ones that are equipped
--   E. what Buttons.E and Buttons.E2 are and which slot each one equips
--   F. which menu page is selected, the tab buttons that switch pages, and
--      every button in the whole PlayerGui that might open the menu

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local EXAMPLES = 3
local SAMPLES = 6
local MAX_CARDS = 400
local MAX_LINES = 700
-- The list holds a few hundred cards; printing them all buried every later
-- section the first time this ran.
local MAX_LISTED = 10
local TEXT_LIMIT = 44
local MAX_DEPTH = 3

local lines = 0

local function out(fmt, ...)
    if lines >= MAX_LINES then
        return
    end

    lines += 1
    local Ok, Text = pcall(string.format, fmt, ...)
    print("[EQUIP] " .. (Ok and Text or tostring(fmt)))
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

local function ShownText(Gui)
    local Ok, Text = pcall(function()
        return Gui.ContentText
    end)

    if Ok and type(Text) == "string" and Text ~= "" then
        return Text
    end

    local Ok2, Text2 = pcall(function()
        return Gui.Text
    end)

    return Ok2 and tostring(Text2) or ""
end

local function ReadValue(Node)
    local Ok, Value = pcall(function()
        return Node.Value
    end)

    return Ok and Value or nil
end

local function IsTextGui(Gui)
    local Ok, IsText = pcall(function()
        return Gui:IsA("TextLabel") or Gui:IsA("TextButton")
    end)

    return Ok and IsText
end

local function IsGuiObject(Node)
    local Ok, IsGui = pcall(function()
        return Node:IsA("GuiObject")
    end)

    return Ok and IsGui
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

local function Children(Root)
    local Ok, List = pcall(function()
        return Root:GetChildren()
    end)

    return Ok and List or {}
end

local function Descendants(Root)
    local Ok, List = pcall(function()
        return Root:GetDescendants()
    end)

    return Ok and List or {}
end

local function IsOnScreen(Gui)
    if not Gui or not Gui.Parent then
        return false
    end

    local Ok, Size = pcall(function()
        return Gui.AbsoluteSize
    end)

    if not Ok or Size.X < 1 or Size.Y < 1 then
        return false
    end

    local Node = Gui

    while Node do
        if Node:IsA("GuiObject") and not Node.Visible then
            return false
        end

        if Node:IsA("LayerCollector") then
            return Node.Enabled
        end

        Node = Node.Parent
    end

    return false
end

-- Every distinct value of one label across the cards, with counts.
local function Tally(Cards, Read)
    local Counts = {}
    local Order = {}

    for _, Card in ipairs(Cards) do
        local Text = Read(Card)

        if Text ~= nil then
            if Counts[Text] == nil then
                Counts[Text] = 0
                table.insert(Order, Text)
            end

            Counts[Text] += 1
        end
    end

    table.sort(Order, function(A, B)
        return Counts[A] > Counts[B]
    end)

    local Parts = {}

    for Index, Text in ipairs(Order) do
        if Index > 10 then
            table.insert(Parts, "...")
            break
        end

        table.insert(Parts, string.format("%q x%d", Text, Counts[Text]))
    end

    return table.concat(Parts, ", ")
end

--////////////////////////////////////////////////////////////////////////
-- A. What the player has
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- A. player")

local PlayerStats = LocalPlayer:FindFirstChild("PlayerStats")

local WORN = {
    "Weapon", "WeaponOverlay",
    "DualWeapon", "DualWeaponOverlay",
    "Shield", "ShieldOverlay",
    "Outfit", "OutfitOverlay",
    "UpperHeadwear", "UpperHeadwearOverlay",
    "LowerHeadwear", "LowerHeadwearOverlay",
    "Facewear", "Necklace", "Armor3D",
}

if not PlayerStats then
    out("PlayerStats: NOT FOUND")
else
    for _, Name in ipairs(WORN) do
        local Field = PlayerStats:FindFirstChild(Name)

        if Field then
            out("  worn %-22s %s", Name, tostring(ReadValue(Field)))
        end
    end

    out("  --- level and skills")

    for _, Child in ipairs(Children(PlayerStats)) do
        local Name = Child.Name

        if string.match(Name, "Skill$") or Name == "Level" or Name == "LevelPoints" then
            out("  %-22s %s", Name, tostring(ReadValue(Child)))
        end
    end
end

--////////////////////////////////////////////////////////////////////////
-- B. Finding the list
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- B. the list")

local GameGui = PlayerGui:FindFirstChild("GameGui")
local MenuGui = GameGui and GameGui:FindFirstChild("MenuGui-NEW")
local Frames = Follow(MenuGui, "FrontRight", "Menu", "Frames")
local Equipment = Frames and Frames:FindFirstChild("Equipment")
local FrameB = Equipment and Equipment:FindFirstChild("FrameB")
local List = FrameB and FrameB:FindFirstChild("List")

out("GameGui %s / MenuGui-NEW %s / Frames %s / Equipment %s / FrameB %s / List %s",
    tostring(GameGui ~= nil), tostring(MenuGui ~= nil), tostring(Frames ~= nil),
    tostring(Equipment ~= nil), tostring(FrameB ~= nil), tostring(List ~= nil))

if MenuGui then
    out("MenuGui-NEW visible %s, on screen %s", tostring(MenuGui.Visible), tostring(IsOnScreen(MenuGui)))
end

if Equipment then
    out("Equipment page visible %s, on screen %s", tostring(Equipment.Visible), tostring(IsOnScreen(Equipment)))
end

if not List then
    out("--- no List; every node named List or Equipment under PlayerGui")

    local Found = 0

    for _, Node in ipairs(Descendants(PlayerGui)) do
        if Node.Name == "List" or Node.Name == "Equipment" then
            Found += 1
            out("  [%s] %s", Node.ClassName, Node:GetFullName())

            if Found >= 8 then
                break
            end
        end
    end
end

-- What the List actually holds: a layout, a template, and (once the page is
-- shown) one TextButton per owned item named after the item.
local Cards = {}
local Template = nil

if List then
    local Children_ = Children(List)
    local Listed = 0

    out("List children (%d):", #Children_)

    for _, Child in ipairs(Children_) do
        local IsCard = IsGuiObject(Child) and Child.Name ~= "Base" and Child:FindFirstChild("Entry") ~= nil

        if Listed < MAX_LISTED then
            Listed += 1
            out("  [%s] %-30s visible %-5s card %s",
                Child.ClassName,
                Child.Name,
                tostring(IsGuiObject(Child) and Child.Visible or "n/a"),
                tostring(IsCard))
        end

        if Child.Name == "Base" or Child.Name == "Template" then
            Template = Child
        elseif IsCard and #Cards < MAX_CARDS then
            table.insert(Cards, Child)
        end
    end

    if #Children_ > MAX_LISTED then
        out("  ... %d more", #Children_ - MAX_LISTED)
    end
end

out("cards (real items): %d", #Cards)

if #Cards == 0 then
    out("!! no cards. The equipment page was not open, or nothing is owned.")
    out("!! Re-run with the menu open and the Equipment tab selected.")
end

if Template then
    local TypeLabel = Template:FindFirstChild("Type")
    local RequiredAmount = Follow(Template, "Entry", "RequiredAmount")
    local Amount = Follow(Template, "Entry", "Amount")
    local Requirement = Follow(Template, "Entry", "Requirement")
    local IsEquipped = Template:FindFirstChild("isEquipped")
    local OnDisplay = Template:FindFirstChild("onDisplay")

    out("template %q: Type %q, Requirement %q, RequiredAmount %q, Amount %q, isEquipped %s, onDisplay %s",
        Template.Name,
        tostring(TypeLabel and ReadValue(TypeLabel) or "?"),
        tostring(Requirement and ShownText(Requirement) or "?"),
        tostring(RequiredAmount and ShownText(RequiredAmount) or "?"),
        tostring(Amount and ShownText(Amount) or "?"),
        tostring(IsEquipped and ReadValue(IsEquipped) or "?"),
        tostring(OnDisplay and ReadValue(OnDisplay) or "?"))
end

--////////////////////////////////////////////////////////////////////////
-- C. The cards
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- C. card shape")

-- A compact table first: the columns that decide the feature, one line per
-- card, for as many cards as fit. If the rest of the probe is ever cut short,
-- this is the part that still answers the questions.
local function CardColumn(Card, Read)
    local Text = Read(Card)
    return Text ~= nil and Trim(tostring(Text)) or "-"
end

out("  name | type | requirement | amount | equipped | E | E2")

for Index, Card in ipairs(Cards) do
    if Index > 14 then
        out("  ... %d more cards", #Cards - 14)
        break
    end

    local TypeNode = Card:FindFirstChild("Type")
    local Requirement = Follow(Card, "Entry", "Requirement")
    local RequiredAmount = Follow(Card, "Entry", "RequiredAmount")
    local Amount = Follow(Card, "Entry", "Amount")
    local IsEquipped = Card:FindFirstChild("isEquipped")

    out("  %-28s | %-16s | %-9s %-5s | %-6s | %-5s | %s | %s",
        string.sub(Card.Name, 1, 28),
        string.sub(CardColumn(TypeNode, ReadValue), 1, 16),
        string.sub(CardColumn(Requirement, ShownText), 1, 9),
        string.sub(CardColumn(RequiredAmount, ShownText), 1, 5),
        string.sub(CardColumn(Amount, ShownText), 1, 6),
        tostring(IsEquipped and ReadValue(IsEquipped)),
        tostring(Follow(Card, "Buttons", "E") ~= nil),
        tostring(Follow(Card, "Buttons", "E2") ~= nil))
end

local Shape = {}

local function RelativePath(Card, Node)
    local Parts = {}
    local Current = Node

    while Current and Current ~= Card do
        table.insert(Parts, 1, Current.Name)
        Current = Current.Parent
    end

    return table.concat(Parts, ".")
end

local function Record(Card, Node, Depth)
    local Key = RelativePath(Card, Node)
    local Slot = Shape[Key]

    if not Slot then
        Slot = { Key = Key, Class = Node.ClassName, Count = 0, Samples = {}, Seen = {} }
        Shape[Key] = Slot
    end

    Slot.Count += 1

    local Text

    if IsTextGui(Node) then
        Text = Clip(ShownText(Node))
    else
        local Value = ReadValue(Node)
        Text = Value ~= nil and Clip(tostring(Value)) or ("<" .. Node.ClassName .. ">")
    end

    if Text ~= "" and not Slot.Seen[Text] and #Slot.Samples < SAMPLES then
        Slot.Seen[Text] = true
        table.insert(Slot.Samples, Text)
    end

    if Depth < MAX_DEPTH then
        for _, Child in ipairs(Children(Node)) do
            Record(Card, Child, Depth + 1)
        end
    end
end

for _, Card in ipairs(Cards) do
    Record(Card, Card, 0)
end

local Keys = {}

for Key in pairs(Shape) do
    if Key ~= "" then
        table.insert(Keys, Key)
    end
end

table.sort(Keys)

for _, Key in ipairs(Keys) do
    local Slot = Shape[Key]
    out("  %-34s %-18s in %3d  %s", Slot.Key, Slot.Class, Slot.Count, table.concat(Slot.Samples, " | "))
end

-- The values that decide everything: the slot vocabulary, the requirement
-- kind, the numbers, and the worn flag.
out("--- distinct values")

local function TypeOf(Card)
    local Node = Card:FindFirstChild("Type")
    return Node and tostring(ReadValue(Node) or "")
end

local function RequirementOf(Card)
    local Node = Follow(Card, "Entry", "Requirement")
    return Node and Trim(ShownText(Node)) or ""
end

local function RequiredAmountOf(Card)
    local Node = Follow(Card, "Entry", "RequiredAmount")
    return Node and Trim(ShownText(Node)) or ""
end

local function AmountOf(Card)
    local Node = Follow(Card, "Entry", "Amount")
    return Node and Trim(ShownText(Node)) or ""
end

local function EquippedOf(Card)
    local Node = Card:FindFirstChild("isEquipped")
    return Node and tostring(ReadValue(Node)) or "?"
end

out("  Type:            %s", Tally(Cards, TypeOf))
out("  Requirement:     %s", Tally(Cards, RequirementOf))
out("  RequiredAmount:  %s", Tally(Cards, RequiredAmountOf))
out("  Entry.Amount:    %s", Tally(Cards, AmountOf))
out("  isEquipped:      %s", Tally(Cards, EquippedOf))

--////////////////////////////////////////////////////////////////////////
-- D. Whole cards
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- D. whole cards")

local Chosen = {}
local ChosenSeen = {}

local function Choose(Card, Why)
    if Card and not ChosenSeen[Card] and #Chosen < EXAMPLES then
        ChosenSeen[Card] = true
        table.insert(Chosen, { Card = Card, Why = Why })
    end
end

for _, Card in ipairs(Cards) do
    if EquippedOf(Card) == "true" then
        Choose(Card, "equipped")
        break
    end
end

for _, Card in ipairs(Cards) do
    if string.find(string.lower(TypeOf(Card)), "overlay", 1, true) then
        Choose(Card, "an overlay")
        break
    end
end

for _, Card in ipairs(Cards) do
    Choose(Card, "first card")
end

local function Dump(Card, Indent)
    out("%s[%s] %s", Indent, Card.ClassName, Card.Name)

    for _, Child in ipairs(Children(Card)) do
        if IsTextGui(Child) then
            out("%s  %-22s [%s] %q", Indent, Child.Name, Child.ClassName, Clip(ShownText(Child)))
        elseif ReadValue(Child) ~= nil then
            out("%s  %-22s [%s] = %q", Indent, Child.Name, Child.ClassName, Clip(tostring(ReadValue(Child))))
        elseif #Children(Child) == 0 then
            out("%s  %-22s [%s]", Indent, Child.Name, Child.ClassName)
        else
            out("%s  %-22s [%s] %d children", Indent, Child.Name, Child.ClassName, #Children(Child))
        end
    end
end

for _, Item in ipairs(Chosen) do
    out("--- %s", Item.Why)
    Dump(Item.Card, "  ")
end

--////////////////////////////////////////////////////////////////////////
-- E. Buttons.E and Buttons.E2
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- E. equip buttons")

local Example = Chosen[1] and Chosen[1].Card or Cards[1]

if Example then
    local Buttons = Example:FindFirstChild("Buttons")

    out("card %q buttons:", Example.Name)

    for _, Button in ipairs(Buttons and Children(Buttons) or {}) do
        local SlotLabel = Button:FindFirstChild("Slot")
        out("  %-6s [%s] %s%s",
            Button.Name,
            Button.ClassName,
            tostring(Button:IsA("GuiButton")),
            SlotLabel and ("  slot " .. Clip(ShownText(SlotLabel))) or "")
    end

    local WithE, WithE2 = 0, 0

    for _, Card in ipairs(Cards) do
        if Follow(Card, "Buttons", "E") then
            WithE += 1
        end

        if Follow(Card, "Buttons", "E2") then
            WithE2 += 1
        end
    end

    out("cards with E: %d, with E2: %d", WithE, WithE2)
end

--////////////////////////////////////////////////////////////////////////
-- F. The menu
--////////////////////////////////////////////////////////////////////////

print("[EQUIP] -- F. the menu")

if Frames then
    out("pages and which one is showing:")

    for _, Page in ipairs(Children(Frames)) do
        local Ok, Visible = pcall(function()
            return Page.Visible
        end)

        if Ok and IsGuiObject(Page) then
            out("  %-14s [%s] visible %s%s", Page.Name, Page.ClassName, tostring(Visible),
                IsOnScreen(Page) and "  ON SCREEN" or "")
        end
    end
end

out("equipment tab buttons:")

for _, Node in ipairs(Descendants(MenuGui or PlayerGui)) do
    if IsGuiObject(Node) and Node.Name == "Equipment" and Node:IsA("GuiButton") then
        local Ok, Size = pcall(function()
            return Node.AbsoluteSize
        end)

        out("  %s  (%s, %s, on screen %s)", Node:GetFullName(), Node.ClassName, tostring(Ok and Size or "?"), tostring(IsOnScreen(Node)))
    end
end

out("--- buttons anywhere in the PlayerGui whose name or label suggests the menu")

local Hits = 0

for _, Node in ipairs(Descendants(PlayerGui)) do
    if IsGuiObject(Node) and Node:IsA("GuiButton") then
        local Label = IsTextGui(Node) and string.lower(ShownText(Node)) or ""
        local Name = string.lower(Node.Name)
        local Hit = false

        for _, Word in ipairs({ "menu", "inventory", "bag", "backpack", "equip", "character" }) do
            if string.find(Name, Word, 1, true) or string.find(Label, Word, 1, true) then
                Hit = true
                break
            end
        end

        if Hit and Hits < 15 then
            Hits += 1
            out("  %s  (%s, on screen %s)%s",
                Node:GetFullName(),
                Node.ClassName,
                tostring(IsOnScreen(Node)),
                Label ~= "" and (" label " .. string.format("%q", Clip(Label))) or "")
        end
    end
end

-- GameGui.Switch sits next to the menu and may be what opens it.
local Switch = GameGui and GameGui:FindFirstChild("Switch")

if Switch then
    out("GameGui.Switch: [%s] on screen %s, size %s",
        Switch.ClassName, tostring(IsOnScreen(Switch)), tostring(Switch.AbsoluteSize))
end

--////////////////////////////////////////////////////////////////////////
-- G. Optional: can the script build the list itself?
--////////////////////////////////////////////////////////////////////////
--
-- Set TEST_TAB_CLICK to true and run this with the menu CLOSED (press Escape
-- first). It presses the Equipment tab button, which only switches a page and
-- equips nothing, then reports whether the cards appeared. If they do, the
-- feature can populate the list without anyone opening the menu by hand, and
-- the menu's open button stops mattering.

local TEST_TAB_CLICK = false

local function CountCards(Root)
    local Count = 0

    for _, Child in ipairs(Children(Root)) do
        if IsGuiObject(Child) and Child.Name ~= "Base" and Child:FindFirstChild("Entry") then
            Count += 1
        end
    end

    return Count
end

local function PressTab(Tab)
    local Fired = false

    if type(getconnections) == "function" then
        for _, SignalName in ipairs({ "MouseButton1Click", "Activated", "MouseButton1Down" }) do
            local Ok, Connections = pcall(getconnections, Tab[SignalName])

            for _, Connection in ipairs(Ok and Connections or {}) do
                if pcall(function()
                    Connection:Fire()
                end) then
                    Fired = true
                end
            end
        end
    end

    if not Fired and type(firesignal) == "function" then
        for _, SignalName in ipairs({ "MouseButton1Click", "Activated" }) do
            if pcall(firesignal, Tab[SignalName]) then
                Fired = true
            end
        end
    end

    return Fired
end

if TEST_TAB_CLICK then
    out("--- G. tab press test")

    local Tab = Follow(MenuGui, "FrontRight", "Menu", "MidFrames", "Player", "Equipment")
        or Follow(MenuGui, "FrontRight", "Menu", "MidFrames", "Player-PageLayout", "Equipment")

    if not Tab then
        out("  no Equipment tab button found")
    else
        local Before = List and CountCards(List) or 0
        out("  tab %s (%s, on screen %s)", Tab:GetFullName(), Tab.ClassName, tostring(IsOnScreen(Tab)))
        out("  cards before: %d", Before)
        out("  press sent: %s", tostring(PressTab(Tab)))

        task.wait(1.5)

        local After = List and CountCards(List) or 0
        out("  cards after:  %d", After)
        out("  equipment page visible: %s", tostring(Equipment and Equipment.Visible))
        out("  %s", After > Before and "the list built without the menu being opened" or "the list did NOT build; the menu has to be open")
    end
end

print("[EQUIP] done — paste every [EQUIP] line")
