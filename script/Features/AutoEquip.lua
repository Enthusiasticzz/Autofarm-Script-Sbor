-- AutoEquip puts the best gear you own on, one button press at a time (there
-- is no loop: the Gear tab's Equip Now starts a single pass).
--
-- The game's Equipment panel is the source of what can be equipped. Every
-- owned item is a TextButton card under
--   PlayerGui.GameGui["MenuGui-NEW"].FrontRight.Menu.Frames.Equipment.FrameB.List
-- named after the item, with:
--   Type             StringValue  "One-Handed", "Rapier", "Dagger", "Outfit", ...
--   Entry.Requirement    TextLabel  "Level" or "Skill"
--   Entry.RequiredAmount TextLabel  the number
--   Entry.Amount         TextLabel  the stack count, NOT a stat
--   isEquipped           BoolValue  the item is on
--   Buttons.E / E2       ImageButton  equip slot 1 / 2
-- The list also holds a "Base" template whose labels read 999 / 9999 with an
-- empty Type; it is a template, never an item, and equipping it would be
-- nonsense, so it is rejected on the empty Type.
--
-- The card does not show damage. The real numbers live in the game's own asset
-- table, which AssetDictionary already reads for the Asset Browser: weapons
-- carry DMG, armour and shields DEF (and DEX), and the requirement is LVL or
-- Skill. So "best" is a real number, not the card's text.
--
-- The armour build setting picks which of DEF / DEX ranks the armour slots,
-- because the game's sets are built one way or the other: a helmet with
-- DEF 37 / DEX 592 is a DEX helmet, and almost no helmet has DEF at all.
-- A card with no value for the chosen stat can never beat one that has it, and
-- a slot whose cards carry neither is only filled when it is empty.
--
-- Nothing here moves the character or touches Auto Farm / Auto Quest. The
-- clicks go through Core/GuiClick, so an executor that can fire a button's
-- signals (or send a synthetic click) is required; without one the pass says
-- so instead of doing nothing quietly.
return {
    Name = "AutoEquip",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "GuiClick", "AssetDictionary", "Components"},

    Start = function(Context)
        local Player = Context.Player
        local GuiClick = Context.GuiClick
        local Dictionary = Context.AssetDictionary
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction
        local CONFIG = Context.CONFIG
        local AICProfile = Context.AICProfile
        local SaveConfig = Context.SaveConfig
        local Logger = Context.Logger

        --// Seconds to wait for the menu, the cards, and the game to write the
        --// equipped item back into PlayerStats.
        local OPEN_WAIT = 2
        local CARD_WAIT = 2.5
        local VERIFY_WAIT = 2.5
        --// How long one delivery style gets before the next is tried. An
        --// equip the game accepts shows up at once; this only has to outlast
        --// the frame the handler runs on.
        local ATTEMPT_WAIT = 0.9
        local POLL = 0.1
        --// Between the first button and the opposite one on a failed equip.
        local CLICK_SETTLE = 0.35
        --// How many slot results the status line keeps before "…".
        local STATUS_SLOTS = 3

        local MENU_BUTTONS = {
            { "DeviceGui", "ConsolePC", "MenuButton" },
            { "DeviceGui", "Mobile", "MobileMenuButton" },
        }
        --// The page's tab, two shapes seen in the menu: a plain button and one
        --// inside the page layout. Either switches to the Equipment page.
        local TAB_PATHS = {
            { "GameGui", "MenuGui-NEW", "FrontRight", "Menu", "MidFrames", "Player", "Equipment" },
            { "GameGui", "MenuGui-NEW", "FrontRight", "Menu", "MidFrames", "Player-PageLayout", "Equipment" },
        }
        local LIST_PATH = { "GameGui", "MenuGui-NEW", "FrontRight", "Menu", "Frames", "Equipment", "FrameB", "List" }
        local PAGE_PATH = { "GameGui", "MenuGui-NEW", "FrontRight", "Menu", "Frames", "Equipment" }
        --// The menu itself: its button toggles it, so it is only pressed when
        --// the menu is not already showing.
        local MENU_PATH = { "GameGui", "MenuGui-NEW" }

        --// The skill a Skill requirement is measured against is the Type
        --// itself; the player carries one number per Type.
        local SKILL_BY_TYPE = {
            ["One-Handed"] = "One-HandedSkill",
            ["Two-Handed"] = "Two-HandedSkill",
            ["Rapier"] = "RapierSkill",
            ["Dagger"] = "DaggerSkill",
            ["Melee"] = "MeleeSkill",
        }

        --// Every slot the Equipment panel can put on, in the order the tab
        --// shows them. Stat:
        --//   DMG   rank by damage (weapons)
        --//   DEF   rank by defence (shields: no shield has DEX)
        --//   BUILD the DEF/DEX choice from the Armour Build dropdown
        --//   NONE  no power stat at all: only fills an empty slot
        --// Button is the equip button a slot uses first; the other one is
        --// tried once if it does nothing.
        local SLOTS = {
            {
                Id = "WEAPON",
                Label = "Weapon",
                Setting = "EQUIP_SLOT_WEAPON",
                Field = "Weapon",
                Stat = "DMG",
                Button = "E",
                Types = { ["One-Handed"] = true, ["Two-Handed"] = true, ["Rapier"] = true, ["Dagger"] = true, ["Melee"] = true },
            },
            {
                Id = "DUAL",
                Label = "Dual weapon",
                Setting = "EQUIP_SLOT_DUAL",
                Field = "DualWeapon",
                Stat = "DMG",
                Button = "E2",
                Types = { ["One-Handed"] = true, ["Rapier"] = true, ["Dagger"] = true },
            },
            {
                Id = "SHIELD",
                Label = "Shield",
                Setting = "EQUIP_SLOT_SHIELD",
                Field = "Shield",
                Stat = "DEF",
                Button = "E",
                Types = { ["Shield"] = true },
            },
            {
                Id = "OUTFIT",
                Label = "Outfit",
                Setting = "EQUIP_SLOT_OUTFIT",
                Field = "Outfit",
                Stat = "BUILD",
                Button = "E",
                Types = { ["Outfit"] = true },
            },
            {
                Id = "UPPER",
                Label = "Upper headwear",
                Setting = "EQUIP_SLOT_UPPER_HEADWEAR",
                Field = "UpperHeadwear",
                Stat = "BUILD",
                Button = "E",
                Types = { ["UpperHeadwear"] = true },
            },
            {
                Id = "LOWER",
                Label = "Lower headwear",
                Setting = "EQUIP_SLOT_LOWER_HEADWEAR",
                Field = "LowerHeadwear",
                Stat = "BUILD",
                Button = "E",
                --// Capes, cloaks, mantles, amulets and pendants are all
                --// LowerHeadwear in this game, not a slot of their own.
                Types = { ["LowerHeadwear"] = true },
            },
            {
                Id = "FACEWEAR",
                Label = "Facewear",
                Setting = "EQUIP_SLOT_FACEWEAR",
                Field = "Facewear",
                Stat = "NONE",
                Button = "E",
                Types = { ["Facewear"] = true },
            },
            {
                Id = "ARMOR3D",
                Label = "3D armour",
                Setting = "EQUIP_SLOT_ARMOR3D",
                Field = "Armor3D",
                Stat = "NONE",
                Button = "E",
                Types = { ["Armor3D"] = true },
            },
        }

        local S = {
            Running = false,
            --// Bumped when the run ends, so a pass that is still waiting
            --// stops instead of writing into a fresh one.
            Token = 0,
            --// The click method that worked last, tried first next time.
            LastMethod = nil,
            --// The menu button was pressed by this pass, so it is pressed
            --// again at the end to leave the menu as it was found.
            PressedMenu = false,
            Assets = { Loaded = false, Error = nil, Index = nil },
            Status = nil,
            Button = nil,
            BuildDropdown = nil,
        }

        ------------------------------------------------------------------------
        --// Reading the game's UI
        ------------------------------------------------------------------------

        local function Trim(Text)
            return (tostring(Text or ""):gsub("^%s*(.-)%s*$", "%1"))
        end

        --// Item names as the inventory spells them against what the card and
        --// the asset table say: case and spacing folded, nothing else.
        local function NormalizeName(Name)
            return (string.lower(Trim(Name)):gsub("%s+", " "))
        end

        local function Follow(Root, Path)
            local Node = Root

            for _, Name in ipairs(Path) do
                Node = Node and Node:FindFirstChild(Name)

                if not Node then
                    return nil
                end
            end

            return Node
        end

        local function GetPlayerGui()
            return Player:FindFirstChildOfClass("PlayerGui") or Context.PlayerGui
        end

        local function GetPlayerStats()
            return Player:FindFirstChild("PlayerStats")
        end

        --// TextValue for a StringValue (Type), ContentText for a label
        --// (Requirement / RequiredAmount), so rich-text tags cannot leak in.
        local function ReadText(Node)
            if not Node then
                return ""
            end

            local Ok, Value = pcall(function()
                return Node.Value
            end)

            if Ok and type(Value) == "string" then
                return Trim(Value)
            end

            local OkText, Text = pcall(function()
                return Node.ContentText
            end)

            if OkText and type(Text) == "string" and Text ~= "" then
                return Trim(Text)
            end

            local OkRaw, Raw = pcall(function()
                return Node.Text
            end)

            if OkRaw and type(Raw) == "string" then
                return Trim(Raw)
            end

            return ""
        end

        local function ReadBool(Node)
            if not Node then
                return false
            end

            local Ok, Value = pcall(function()
                return Node.Value
            end)

            return Ok and Value == true
        end

        local function ReadName(Node)
            if not Node then
                return ""
            end

            local Ok, Value = pcall(function()
                return Node.Value
            end)

            return Ok and type(Value) == "string" and Trim(Value) or ""
        end

        local function IsA(Node, Class)
            local Ok, Result = pcall(function()
                return Node:IsA(Class)
            end)

            return Ok and Result
        end

        --// "1,200" -> 1200, "Skill 55" -> 55, "" -> nil.
        local function ParseNumber(Text)
            local Digits = string.gsub(tostring(Text or ""), "[^%d%.]", "")

            if Digits == "" or Digits == "." then
                return nil
            end

            return tonumber(Digits)
        end

        local function GetList()
            return Follow(GetPlayerGui(), LIST_PATH)
        end

        local function GetPage()
            return Follow(GetPlayerGui(), PAGE_PATH)
        end

        local function FindMenuButton()
            local Gui = GetPlayerGui()

            for _, Path in ipairs(MENU_BUTTONS) do
                local Button = Follow(Gui, Path)

                if Button and GuiClick.IsOnScreen(Button) then
                    return Button
                end
            end

            for _, Path in ipairs(MENU_BUTTONS) do
                local Button = Follow(Gui, Path)

                if Button then
                    return Button
                end
            end

            return nil
        end

        local function FindEquipmentTab()
            local Gui = GetPlayerGui()

            for _, Path in ipairs(TAB_PATHS) do
                local Tab = Follow(Gui, Path)

                if Tab and IsA(Tab, "GuiButton") then
                    return Tab
                end
            end

            return nil
        end

        ------------------------------------------------------------------------
        --// Clicking
        ------------------------------------------------------------------------

        local function WaitUntil(Check, Seconds)
            local Deadline = os.clock() + Seconds

            while true do
                local Ok, Done = pcall(Check)

                if Ok and Done then
                    return true
                end

                if os.clock() >= Deadline then
                    return false
                end

                task.wait(POLL)
            end
        end

        --// Our own window is hidden for the length of a pointer click, so a
        --// method that sends a mouse click cannot land on it when it covers
        --// the menu. Auto Start Game hides its window for the same reason.
        --// Signal presses move no pointer, so they run with the window left
        --// alone: hiding it for those only made the macro's own controls
        --// blink out for the length of a pass.
        local function WithWindowHidden(Action)
            local ScreenGui = Context.UI and Context.UI.ScreenGui
            local WasShown = ScreenGui ~= nil and ScreenGui.Enabled

            if WasShown then
                pcall(function()
                    ScreenGui.Enabled = false
                end)
            end

            local Ok, Result = pcall(Action)

            if WasShown then
                pcall(function()
                    ScreenGui.Enabled = true
                end)
            end

            if not Ok then
                return false
            end

            return Result
        end

        --// The signals an equip can be bound to. A handler may live on any
        --// one of them, so each is tried instead of only the first that
        --// answers: firing a signal nobody listens to used to count as a
        --// click and then wait 2.5 s for an item that was never going on.
        local PRESS_SIGNALS = { "MouseButton1Click", "MouseButton1Down", "Activated" }

        local function ConnectionCount(Signal)
            if type(getconnections) ~= "function" then
                return nil
            end

            local Ok, List = pcall(getconnections, Signal)

            if not Ok or type(List) ~= "table" then
                return nil
            end

            return #List
        end

        local function FireHandlers(Signal)
            if type(getconnections) ~= "function" then
                return false
            end

            local Ok, List = pcall(getconnections, Signal)

            if not Ok or type(List) ~= "table" then
                return false
            end

            local Fired = false

            for _, Connection in ipairs(List) do
                if pcall(function()
                    Connection:Fire()
                end) then
                    Fired = true
                end
            end

            return Fired
        end

        --// Fires one signal's handlers; false when nothing is listening.
        --// firesignal "succeeds" on a signal with no handlers, which is how a
        --// press that reached nothing still looked like a press.
        local function SendSignal(Button, SignalName)
            local Signal = Button and Button[SignalName]

            if not Signal then
                return false
            end

            local Count = ConnectionCount(Signal)

            if Count == 0 then
                return false
            end

            if FireHandlers(Signal) then
                return true
            end

            --// No getconnections to ask: firesignal is the only way in, and
            --// it cannot say whether anyone was listening.
            if Count == nil and type(firesignal) == "function" then
                return (pcall(firesignal, Signal))
            end

            return false
        end

        --// Drawn: every frame above it is Visible, and a ScreenGui above it
        --// is Enabled. The local player's own tree ends at PlayerGui, which
        --// has no Enabled, so reaching it means shown - GuiClick.IsOnScreen
        --// wants a ScreenGui ancestor and says no to the game's own menus.
        local function IsShowing(Node)
            if not Node then
                return false
            end

            local Current = Node

            while Current do
                local OkLayer, IsLayer = pcall(function()
                    return Current:IsA("LayerCollector")
                end)

                if OkLayer and IsLayer then
                    local OkEnabled, Enabled = pcall(function()
                        return Current.Enabled
                    end)

                    return not OkEnabled or Enabled ~= false
                end

                local OkVisible, Visible = pcall(function()
                    return Current.Visible
                end)

                if OkVisible and Visible == false then
                    return false
                end

                if Current.ClassName == "PlayerGui" then
                    return true
                end

                Current = Current.Parent
            end

            return false
        end

        --// A number off a Vector2 (userdata, not a table in Roblox) or a
        --// plain table holding the same fields.
        local function NumberField(Object, Key)
            if Object == nil then
                return nil
            end

            local Ok, Value = pcall(function()
                return Object[Key]
            end)

            return Ok and type(Value) == "number" and Value or nil
        end

        --// A pointer click only works where the button is drawn. A card
        --// scrolled out of the list would otherwise be clicked through
        --// whatever happens to be on top of it.
        local function IsPointerSafe(Button)
            if not (Button and IsShowing(Button)) then
                return false
            end

            local OkSize, Size = pcall(function()
                return Button.AbsoluteSize
            end)

            local Width = OkSize and NumberField(Size, "X") or nil
            local Height = OkSize and NumberField(Size, "Y") or nil

            if not (Width and Height) or Width < 1 or Height < 1 then
                return false
            end

            local Ancestor = Button.Parent

            while Ancestor do
                local Clips = false

                pcall(function()
                    Clips = Ancestor:IsA("ScrollingFrame") or Ancestor.ClipsDescendants == true
                end)

                if Clips then
                    local Ok, Pos, Size, FramePos, FrameSize = pcall(function()
                        return Button.AbsolutePosition,
                            Button.AbsoluteSize,
                            Ancestor.AbsolutePosition,
                            Ancestor.AbsoluteSize
                    end)

                    if not Ok then
                        return false
                    end

                    local X = NumberField(Pos, "X")
                    local Y = NumberField(Pos, "Y")
                    local W = NumberField(Size, "X")
                    local H = NumberField(Size, "Y")
                    local FX = NumberField(FramePos, "X")
                    local FY = NumberField(FramePos, "Y")
                    local FW = NumberField(FrameSize, "X")
                    local FH = NumberField(FrameSize, "Y")

                    if not (X and Y and W and H and FX and FY and FW and FH) then
                        return false
                    end

                    local CenterX = X + W / 2
                    local CenterY = Y + H / 2

                    if CenterX < FX or CenterX > FX + FW
                        or CenterY < FY or CenterY > FY + FH
                    then
                        return false
                    end
                end

                Ancestor = Ancestor.Parent
            end

            return true
        end

        --// Presses once, whatever signal answers, and does not wait. For a
        --// tab or the menu button, which toggle rather than confirm.
        local function PressNow(Button)
            if not Button then
                return false
            end

            for _, SignalName in ipairs(PRESS_SIGNALS) do
                if SendSignal(Button, SignalName) then
                    return true
                end
            end

            if IsPointerSafe(Button) then
                local Method = WithWindowHidden(function()
                    return GuiClick.Click(Button, S.LastMethod, PRESS_SIGNALS)
                end)

                if Method and Method ~= false then
                    S.LastMethod = Method
                    return true
                end
            end

            return false
        end

        --// Presses until the game shows the effect. A press that reaches
        --// nothing is not a press: every signal, then a real click, each
        --// followed by Verify(), and the escalation stops as soon as one
        --// takes. Returns whether it took, and what was tried.
        local function PressUntil(Button, Verify)
            if not Button then
                return false, "no button"
            end

            local Sent = false

            for _, SignalName in ipairs(PRESS_SIGNALS) do
                if SendSignal(Button, SignalName) then
                    Sent = true

                    if WaitUntil(Verify, ATTEMPT_WAIT) then
                        return true, SignalName
                    end
                end
            end

            --// A signal was heard and the game did not act: it got the press
            --// and refused it, so a pointer click would only fire the same
            --// handlers again. The pointer is for a button no signal of which
            --// could be fired at all.
            if not Sent and IsPointerSafe(Button) then
                local Method = WithWindowHidden(function()
                    return GuiClick.Click(Button, S.LastMethod, PRESS_SIGNALS)
                end)

                if Method and Method ~= false then
                    Sent = true
                    S.LastMethod = Method

                    if WaitUntil(Verify, VERIFY_WAIT) then
                        return true, Method
                    end
                end
            end

            return false, Sent and "ignored" or "no click"
        end

        ------------------------------------------------------------------------
        --// Player numbers
        ------------------------------------------------------------------------

        local function ReadStats()
            local Stats = { Level = 0, Worn = {}, Owned = {}, Found = false }
            local PlayerStats = GetPlayerStats()

            if not PlayerStats then
                return Stats
            end

            Stats.Found = true

            local Level = PlayerStats:FindFirstChild("Level")

            if Level then
                local Ok, Value = pcall(function()
                    return Level.Value
                end)

                if Ok and type(Value) == "number" then
                    Stats.Level = Value
                end
            end

            for _, Key in pairs(SKILL_BY_TYPE) do
                local Field = PlayerStats:FindFirstChild(Key)

                if Field then
                    local Ok, Value = pcall(function()
                        return Field.Value
                    end)

                    if Ok and type(Value) == "number" then
                        Stats[Key] = Value
                    end
                end
            end

            for _, Slot in ipairs(SLOTS) do
                local Field = PlayerStats:FindFirstChild(Slot.Field)
                Stats.Worn[Slot.Id] = ReadName(Field)
            end

            --// "Name|2,Name|1": what is owned. The panel should only hold
            --// owned items, and this makes sure a stale card cannot win.
            local Inventory = PlayerStats:FindFirstChild("Inventory")
            local Text = Inventory and Inventory.Value

            if type(Text) == "string" then
                for Entry in string.gmatch(Text, "([^,]+)") do
                    local Name = string.match(Entry, "([^|]+)|")

                    if Name then
                        Stats.Owned[NormalizeName(Name)] = true
                    end
                end
            end

            return Stats
        end

        ------------------------------------------------------------------------
        --// The game's item table (damage / defence / dexterity)
        ------------------------------------------------------------------------

        local function EnsureAssets()
            if S.Assets.Loaded then
                return true
            end

            if not Dictionary or type(Dictionary.Load) ~= "function" then
                S.Assets.Error = "the asset dictionary is not loaded"
                return false
            end

            local Ok, Result = pcall(function()
                return Dictionary:Load()
            end)

            if not Ok or Result == false then
                S.Assets.Error = "the game's item table cannot be read"
                return false
            end

            local Index = {}

            for _, Entry in ipairs(Dictionary:GetAll() or {}) do
                if type(Entry.Name) == "string" then
                    Index[NormalizeName(Entry.Name)] = Entry
                end
            end

            S.Assets.Index = Index
            S.Assets.Loaded = true
            S.Assets.Error = nil

            return true
        end

        local function AssetStat(Name, Key)
            local Index = S.Assets.Index
            local Entry = Index and Index[NormalizeName(Name)]

            if not Entry or type(Dictionary.GetStat) ~= "function" then
                return nil
            end

            local Value = Dictionary.GetStat(Entry, Key)

            return type(Value) == "number" and Value or nil
        end

        ------------------------------------------------------------------------
        --// Cards
        ------------------------------------------------------------------------

        local function IsCard(Node)
            if not Node or Node.Name == "Base" or Node.Name == "Template" then
                return false
            end

            if not IsA(Node, "GuiObject") then
                return false
            end

            if not Node:FindFirstChild("Entry") then
                return false
            end

            local TypeNode = Node:FindFirstChild("Type")

            return TypeNode ~= nil and ReadText(TypeNode) ~= ""
        end

        local function ReadCard(Card)
            local TypeNode = Card:FindFirstChild("Type")
            local Entry = Card:FindFirstChild("Entry")
            local Buttons = Card:FindFirstChild("Buttons")

            local Info = {
                Name = Card.Name,
                Card = Card,
                Type = ReadText(TypeNode),
                Kind = "",
                Amount = nil,
                Equipped = ReadBool(Card:FindFirstChild("isEquipped")),
                Buttons = Buttons,
                Stats = {},
            }

            Info.Kind = string.upper(ReadText(Entry and Entry:FindFirstChild("Requirement")))
            Info.Amount = ParseNumber(ReadText(Entry and Entry:FindFirstChild("RequiredAmount")))

            for _, Key in ipairs({ "DMG", "DEF", "DEX" }) do
                Info.Stats[Key] = AssetStat(Info.Name, Key)
            end

            return Info
        end

        local function EnumerateCards(List)
            local Cards = {}

            for _, Child in ipairs(List:GetChildren()) do
                if IsCard(Child) then
                    table.insert(Cards, ReadCard(Child))
                end
            end

            return Cards
        end

        --// The live card for a name. The game rebuilds the list when an item
        --// goes on, so a card read before the last equip may no longer be in
        --// the panel, and pressing its buttons would reach nothing.
        local function LiveCard(Card)
            local List = GetList()
            local Found = List and List:FindFirstChild(Card.Name)

            if Found and IsCard(Found) then
                return Found
            end

            return Card.Card
        end

        local function MeetsRequirement(Card, Stats)
            if Card.Amount == nil then
                return false
            end

            if Card.Kind == "LEVEL" then
                return Stats.Level >= Card.Amount
            end

            if Card.Kind == "SKILL" then
                local Skill = SKILL_BY_TYPE[Card.Type]

                if not Skill then
                    return false
                end

                return (Stats[Skill] or 0) >= Card.Amount
            end

            return false
        end

        ------------------------------------------------------------------------
        --// Choosing
        ------------------------------------------------------------------------

        local function HasStat(Cards, Key)
            for _, Card in ipairs(Cards) do
                if Card.Stats[Key] ~= nil then
                    return true
                end
            end

            return false
        end

        local function ByNumberThenName(A, B, Key)
            local Left = A.Stats[Key]
            local Right = B.Stats[Key]

            if (Left or -1) ~= (Right or -1) then
                return (Left or -1) > (Right or -1)
            end

            return nil
        end

        --// The stat a slot is chosen on: the build's stat for armour, falling
        --// back to the other one, or nil when nothing in the slot carries
        --// either (Facewear, 3D armour).
        local function RankKeyFor(Slot, Cards)
            if Slot.Stat == "DMG" or Slot.Stat == "DEF" then
                --// A weapon or shield the item table does not know cannot be
                --// ranked on its damage, so it is left alone rather than
                --// being equipped for having no number at all.
                if not HasStat(Cards, Slot.Stat) then
                    return nil, nil, true
                end

                return Slot.Stat, nil
            end

            if Slot.Stat == "BUILD" then
                local Preferred = CONFIG.EQUIP_ARMOUR_BUILD == "Defence" and "DEF" or "DEX"
                local Other = Preferred == "DEF" and "DEX" or "DEF"

                if HasStat(Cards, Preferred) then
                    return Preferred, Other
                end

                if HasStat(Cards, Other) then
                    return Other, Preferred
                end
            end

            return nil, nil
        end

        --// Used holds the items an earlier slot put on this pass. A dual
        --// weapon must be a second item: pressing E2 on the sword that was
        --// just equipped to slot 1 could move it out of the main hand.
        local function PickBest(Slot, Cards, Stats, Used)
            local Candidates = {}

            for _, Card in ipairs(Cards) do
                local Eligible = Slot.Types[Card.Type] == true
                    and not Card.Equipped
                    and Stats.Worn[Slot.Id] ~= Card.Name
                    and Used[Card.Name] ~= true
                    --// The panel only lists what is owned, so the inventory
                    --// is a second opinion; it is only used when it names
                    --// something on the panel (see RunPass).
                    and (not Stats.InventoryGate
                        or Card.Name == "Fists"
                        or Stats.Owned[NormalizeName(Card.Name)] == true)
                    and MeetsRequirement(Card, Stats)

                if Eligible then
                    table.insert(Candidates, Card)
                end
            end

            if #Candidates == 0 then
                return nil, "none"
            end

            local Primary, Secondary, StatMissing = RankKeyFor(Slot, Candidates)

            if StatMissing then
                return nil, "no stat"
            end

            if not Primary then
                --// Nothing to rank on: fill an empty slot, never swap.
                if Stats.Worn[Slot.Id] ~= "" then
                    return nil, "worn"
                end

                table.sort(Candidates, function(A, B)
                    if (A.Amount or 0) ~= (B.Amount or 0) then
                        return (A.Amount or 0) > (B.Amount or 0)
                    end

                    return A.Name < B.Name
                end)

                return Candidates[1], "fill"
            end

            table.sort(Candidates, function(A, B)
                local ByPrimary = ByNumberThenName(A, B, Primary)

                if ByPrimary ~= nil then
                    return ByPrimary
                end

                if Secondary then
                    local BySecondary = ByNumberThenName(A, B, Secondary)

                    if BySecondary ~= nil then
                        return BySecondary
                    end
                end

                if (A.Amount or 0) ~= (B.Amount or 0) then
                    return (A.Amount or 0) > (B.Amount or 0)
                end

                return A.Name < B.Name
            end)

            return Candidates[1], Primary
        end

        local function StatOf(Card, Key)
            local Value = Card and Card.Stats and Card.Stats[Key]

            return type(Value) == "number" and Value or nil
        end

        local function Wearing(Card, Slot)
            local PlayerStats = GetPlayerStats()
            local Field = PlayerStats and PlayerStats:FindFirstChild(Slot.Field)

            --// PlayerStats is the worn state the game itself keeps; the
            --// card's own marker is only a fallback, and only on the card
            --// that is in the panel now.
            if Field and ReadName(Field) == Card.Name then
                return true
            end

            local Node = LiveCard(Card)

            return ReadBool(Node and Node:FindFirstChild("isEquipped"))
        end

        ------------------------------------------------------------------------
        --// The pass
        ------------------------------------------------------------------------

        local function SetStatus(Text)
            if S.Status then
                pcall(function()
                    S.Status:Set(Text)
                end)
            end
        end

        local function Notify(Text)
            if NotifyAction then
                NotifyAction("AUTO EQUIP", Text, 6)
            end
        end

        local function HasCards()
            local List = GetList()

            if not List then
                return false
            end

            for _, Child in ipairs(List:GetChildren()) do
                if IsCard(Child) then
                    return true
                end
            end

            return false
        end

        --// The cards outlive the page that showed them, so a list with cards
        --// in it is not the same as an Equipment page you can press. The
        --// game ignores a button on a page that is not showing.
        local function IsPageShowing()
            local Page = GetPage()

            return Page ~= nil and Page.Visible == true and IsShowing(Page)
        end

        local function ReadyToClick()
            return HasCards() and IsPageShowing()
        end

        --// Selects the Equipment page, opening the menu only when the page
        --// cannot be reached without it. True once cards are readable on a
        --// page that is actually showing.
        local function EnsureCards()
            if ReadyToClick() then
                return true, "open"
            end

            local Tab = FindEquipmentTab()
            local MenuButton = FindMenuButton()

            --// Neither control exists: no point waiting two seconds twice.
            if not Tab and not MenuButton then
                return false, "no tab"
            end

            if Tab then
                PressNow(Tab)

                if WaitUntil(ReadyToClick, CARD_WAIT) then
                    return true, "tab"
                end
            end

            local Menu = Follow(GetPlayerGui(), MENU_PATH)

            --// The menu button is a toggle: pressing it with the menu already
            --// open would close the page instead of showing it.
            if MenuButton and not (Menu and IsShowing(Menu)) then
                S.PressedMenu = true
                PressNow(MenuButton)
                WaitUntil(function()
                    local Open = Follow(GetPlayerGui(), MENU_PATH)
                    return Open ~= nil and IsShowing(Open)
                end, OPEN_WAIT)
            end

            Tab = FindEquipmentTab()

            if Tab then
                PressNow(Tab)
            end

            if WaitUntil(ReadyToClick, CARD_WAIT) then
                return true, "opened"
            end

            return false, Tab and "empty" or "no tab"
        end

        --// The card the equip button acts on is the one the page is showing:
        --// a card that is not on display is selected first, so the press
        --// cannot land on the item the page was showing before it.
        local function FocusCard(Card)
            local Node = LiveCard(Card)
            local Flag = Node and Node:FindFirstChild("onDisplay")

            if not Flag or ReadBool(Flag) then
                return Node
            end

            PressUntil(Node, function()
                local Live = LiveCard(Card)
                local Marker = Live and Live:FindFirstChild("onDisplay")

                return Marker ~= nil and ReadBool(Marker)
            end)

            return LiveCard(Card)
        end

        local function EquipSlot(Slot, Card)
            local Order = { Slot.Button or "E", Slot.Button == "E2" and "E" or "E2" }
            local Node = FocusCard(Card)
            local Detail = "no button"

            for Index, ButtonName in ipairs(Order) do
                if Index > 1 then
                    task.wait(CLICK_SETTLE)
                    Node = LiveCard(Card)
                end

                local Buttons = Node and Node:FindFirstChild("Buttons")
                local Button = Buttons and Buttons:FindFirstChild(ButtonName)

                if Button then
                    local Took, Why = PressUntil(Button, function()
                        return Wearing(Card, Slot)
                    end)

                    if Took then
                        return true, ButtonName
                    end

                    Detail = Why
                end
            end

            return false, Detail
        end

        --// Key is the stat the slot was actually ranked on, so the number
        --// shown is the one the decision used (a DEF build shows DEF).
        local function Describe(Slot, Card, Key)
            local Shown = Key and StatOf(Card, Key) or nil

            if not Shown then
                Shown = StatOf(Card, "DEX") or StatOf(Card, "DEF") or StatOf(Card, "DMG")
            end

            if not Shown then
                return Card.Name
            end

            --// Armour carries halves (DEF 344.5); weapons are whole.
            local Number = Shown == math.floor(Shown) and string.format("%d", Shown) or string.format("%.1f", Shown)

            return Card.Name .. " (" .. Number .. ")"
        end

        local function RunPass(Equip)
            local Stats = ReadStats()

            --// Every gate is checked against these numbers, so without them
            --// no card could qualify and "ALREADY BEST" would be a lie.
            if not Stats.Found then
                SetStatus("NO PLAYER STATS  ·  cannot read Level or skills")
                Notify("PlayerStats is missing, so nothing could be checked or equipped.")
                return
            end

            --// The first pass reads every item in the game, which takes a
            --// moment: say so before it happens, not after.
            if not S.Assets.Loaded then
                SetStatus("READING ITEMS…")
            end

            if not EnsureAssets() then
                SetStatus("NO ITEM DATA  ·  " .. tostring(S.Assets.Error))
                Notify("Cannot read the game's item table, so nothing was equipped.")
                return
            end

            SetStatus(Equip and "READING THE EQUIPMENT PAGE…" or "READING THE LIST…")

            local Ready, How = EnsureCards()

            if not Ready then
                local Page = GetPage()

                if not Page then
                    SetStatus("NO EQUIPMENT PAGE  ·  " .. tostring(How))
                else
                    --// The page is there but no item card was readable: say
                    --// how far the pass got (tab found, menu opened, empty).
                    SetStatus("NO CARDS ON THE EQUIPMENT PAGE  ·  " .. tostring(How))
                end

                Notify("The Equipment page did not show any items.")
                return
            end

            local List = GetList()
            local Cards = List and EnumerateCards(List) or {}

            if #Cards == 0 then
                SetStatus("NO CARDS ON THE EQUIPMENT PAGE")
                Notify("The Equipment page showed no items.")
                return
            end

            --// "Name|2,Name|1" is the inventory, but it may hold only the
            --// crafting materials and not the gear (the panel is the proof
            --// of ownership). If not one card is named in it, the gate is
            --// switched off instead of rejecting every card on the page.
            Stats.InventoryGate = false

            for _, Card in ipairs(Cards) do
                if Stats.Owned[NormalizeName(Card.Name)] then
                    Stats.InventoryGate = true
                    break
                end
            end

            local Changed, Failed = {}, {}
            local Used = {}
            local Statless = 0

            for _, Slot in ipairs(SLOTS) do
                if CONFIG[Slot.Setting] == true then
                    local Card, Why = PickBest(Slot, Cards, Stats, Used)

                    if not Card and Why == "no stat" then
                        Statless += 1
                    end

                    --// "worn" / "none" / "no stat" are silent per slot:
                    --// there is nothing to do and nothing to name.
                    if Card then
                        if Equip then
                            SetStatus(string.format("EQUIPPING  ·  %s -> %s", Slot.Label, Card.Name))

                            local Took, Detail = EquipSlot(Slot, Card)

                            if Took then
                                table.insert(Changed, Slot.Label .. " -> " .. Describe(Slot, Card, Why))
                                Stats.Worn[Slot.Id] = Card.Name
                                Used[Card.Name] = true
                            else
                                --// Why it did not take matters: a press that
                                --// reached nothing is a different problem
                                --// from a game that refused the item.
                                table.insert(Failed, string.format("%s (%s, %s)", Slot.Label, Card.Name, tostring(Detail)))
                            end
                        else
                            table.insert(Changed, Slot.Label .. " -> " .. Describe(Slot, Card, Why))
                            Used[Card.Name] = true
                        end
                    end
                end
            end

            local Parts = {}

            for Index, Text in ipairs(Changed) do
                if Index > STATUS_SLOTS then
                    table.insert(Parts, "…")
                    break
                end

                table.insert(Parts, Text)
            end

            if #Parts == 0 then
                --// Every candidate in a damage slot had no number at all is
                --// not the same as everything worn being the best.
                Parts[1] = Statless > 0 and "NOTHING RANKABLE" or "ALREADY BEST"
            end

            if #Failed > 0 then
                table.insert(Parts, "FAILED " .. table.concat(Failed, ", "))
            end

            --// Nothing went on is not "DONE": the readout used to claim it
            --// for a pass whose every press was refused.
            local Prefix = "WOULD EQUIP"

            if Equip then
                Prefix = #Changed > 0 and "DONE" or (#Failed > 0 and "NOT EQUIPPED" or "DONE")
            end

            SetStatus(string.format("%s  ·  %d cards  ·  %s", Prefix, #Cards, table.concat(Parts, "  ·  ")))

            if Equip then
                if #Changed > 0 then
                    Notify(table.concat(Changed, "  ·  "))
                elseif #Failed > 0 then
                    Notify("Could not press the equip button for " .. table.concat(Failed, ", ") .. ".")
                else
                    Notify(string.format("Nothing better than what is worn (%d cards read).", #Cards))
                end
            else
                Notify(#Changed > 0 and table.concat(Changed, "  ·  ") or "Nothing better than what is worn.")
            end
        end

        local function StartPass(Equip)
            if S.Running then
                Notify("A pass is already running.")
                return
            end

            S.Running = true
            S.PressedMenu = false
            S.Token += 1
            local Token = S.Token

            task.spawn(function()
                local Ok, Err = pcall(RunPass, Equip)

                --// Leave the menu as it was found: only a pass that pressed
                --// the menu button itself puts it back.
                if S.PressedMenu then
                    local MenuButton = FindMenuButton()

                    if MenuButton then
                        PressNow(MenuButton)
                    end
                end

                S.PressedMenu = false
                S.Running = false

                if not Ok and Token == S.Token then
                    SetStatus("ERROR  ·  " .. tostring(Err))
                    Logger.warn("AutoEquip: %s", tostring(Err))
                end
            end)
        end

        ------------------------------------------------------------------------
        --// The Gear tab
        ------------------------------------------------------------------------

        local function SaveSetting(Key, Value)
            local Entry = SaveConfig.GetSetting(Key)

            if Entry then
                CONFIG[Key] = SaveConfig.NormalizeSetting(Entry, Value)
            else
                CONFIG[Key] = Value
            end

            if AICProfile and AICProfile.QueueProfileSave then
                AICProfile.QueueProfileSave()
            end
        end

        --// Every saved control is registered here so a profile load puts the
        --// saved value back on screen; Components refreshes this table.
        local function Register(Key, Control)
            AICUI.S.SettingControls[Key] = Control
        end

        local function AddSlotToggles(Section)
            Section:AddDivider()
            Section:AddLabel("SLOTS")

            for _, Slot in ipairs(SLOTS) do
                local Toggle = Section:AddToggle{
                    Name = Slot.Label,
                    Default = CONFIG[Slot.Setting] == true,
                    Callback = function(Value)
                        SaveSetting(Slot.Setting, Value == true)
                    end,
                }

                Register(Slot.Setting, Toggle)

                --// The note hangs off the row it explains.
                if Slot.Id == "LOWER" then
                    Section:AddNote("Capes, cloaks, mantles, amulets and pendants are all this slot.")
                elseif Slot.Id == "FACEWEAR" then
                    Section:AddNote("Facewear and 3D armour have no power stat, so they only fill an empty slot and never swap.")
                end
            end
        end

        local function BuildUI()
            local Section = UIRef.GearSection

            if not Section then
                return
            end

            S.Button = Section:AddButton{
                Name = "Equip Now",
                Primary = true,
                Callback = function()
                    StartPass(true)
                end,
            }

            S.Status = Section:AddLabel("READY  ·  press Equip Now")

            local BuildEntry = SaveConfig.GetSetting("EQUIP_ARMOUR_BUILD")
            local BuildOptions = BuildEntry and BuildEntry.Options or { "Dexterity", "Defence" }

            S.BuildDropdown = Section:AddDropdown{
                Name = "Armour Build",
                Options = BuildOptions,
                Default = CONFIG.EQUIP_ARMOUR_BUILD,
                Callback = function(Value)
                    SaveSetting("EQUIP_ARMOUR_BUILD", Value)
                end,
            }

            Register("EQUIP_ARMOUR_BUILD", S.BuildDropdown)
            Section:AddNote("Dexterity ranks armour by DEX, Defence by DEF. Weapons always use damage and shields always use DEF.")

            AddSlotToggles(Section)

            Section:AddButton{
                Name = "Refresh List",
                Callback = function()
                    StartPass(false)
                end,
            }
        end

        BuildUI()

        local Feature = {
            Name = "AutoEquip",
            IsFeature = true,
            S = S,
        }

        --// Nothing runs by itself: the whole feature is the two buttons.
        function Feature:Update()
        end

        function Feature:Stop()
            S.Token += 1
            S.Running = false
        end

        --// The panel is read again on every pass, so nothing is cached about
        --// it except the item table.
        function Feature:Refresh()
            S.Assets.Loaded = false
        end

        Context.Lifetime.OnEnd(function()
            Feature:Stop()
        end)

        return Feature
    end,
}
