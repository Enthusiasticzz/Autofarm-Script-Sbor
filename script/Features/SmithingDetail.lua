-- SmithingDetail is the RECIPE tab of the Recipe Browser (SmithingBrowser):
-- the recipe picked in the list with its type, level or skill and stats
-- from the game's assets, whether it can be traded, what one craft needs
-- and what is missing, a popup showing what a tapped material is crafted
-- from, CRAFT NOW (a craft order in AutoSmithing, up to what the materials
-- allow) and the button that adds it to Recipe Priority or takes it out.
-- It also holds the recipe helpers the browser's list shares.
return {
    Name = "SmithingDetail",
    Dependencies = {"Runtime", "SaveConfig", "SmithingRecipes", "AutoSmithing", "Floating"},

    Start = function(Context)
        local UI = Context.UI
        local UIRef = Context.UIRef
        local CONFIG = Context.CONFIG
        local NotifyAction = Context.NotifyAction
        local Recipes = Context.SmithingRecipes
        local AutoSmithing = Context.AutoSmithing
        local Floating = Context.Floating
        local UserInputService = Context.Services.UserInputService

        local New, Stroke, Padding, List = Floating.New, Floating.Stroke, Floating.Padding, Floating.List
        local Label, Button, ClearChildren, IsInside = Floating.Label, Floating.Button, Floating.ClearChildren, Floating.IsInside

        local MAX_STACK = Context.SaveConfig.ITEM_MAX_STACK
        local ROW_HEIGHT = 34
        local POPUP_WIDTH = 240

        local Detail = {
            Name = "SmithingDetail",
            S = {
                Selected = nil,
                --// CRAFT NOW amount, kept while the details are rebuilt.
                CraftAmount = 1,
                CraftMax = 0,
                --// Material name -> its row in the details, for the popup.
                MaterialRows = {},
                DetailSignature = nil,
                PopupFor = nil,
                PopupAnchor = nil,
            },
        }

        local S = Detail.S
        local Theme, DetailScroll, Popup, PopupContent
        --// Set by Build: Select(Name) opens a recipe, Refresh() redraws
        --// the whole browser.
        local Browser
        --// Parts of the details updated in place by every refresh.
        local Craft = {}

        ------------------------------------------------------------------------
        --// What the inventory says about a recipe or a material
        ------------------------------------------------------------------------

        local function ReadInventory()
            return {
                Inventory = Recipes:GetInventory(),
                Reserves = Recipes:GetReserves(),
                Skill = Recipes:GetSkill(),
            }
        end

        local function Describe(Name, Stock)
            return Recipes:Describe({ Name = Name, Target = 0 }, Stock.Inventory, Stock.Reserves, Stock.Skill)
        end

        --// One material of one craft: Have counts the whole inventory, Usable
        --// what is left after Material Reserve, Missing what one craft lacks.
        local function DescribeMaterial(Material, Stock)
            local Have = Stock.Inventory[Material.Name] or 0
            local Keep = Stock.Reserves[Material.Name] or 0
            local Usable = math.max(0, Have - Keep)

            return {
                Have = Have,
                Keep = Keep,
                Usable = Usable,
                Missing = math.max(0, Material.Amount - Usable),
            }
        end

        --// The most CRAFT NOW may ask for: what the materials allow, and no
        --// more than the inventory can hold of the item.
        local function GetCraftMax(State)
            if not State.Known or State.Locked then
                return 0
            end

            return math.max(0, math.min(State.Craftable, MAX_STACK - State.Have))
        end

        local function IsInPriority(Name)
            for _, Entry in ipairs(CONFIG.SMITH_RECIPES or {}) do
                if Entry.Name == Name then
                    return true
                end
            end

            return false
        end

        --// The status line of a recipe and its colour.
        local function DescribeStatus(State)
            local Theme = UI.Theme

            if State.Locked then
                return "LOCKED", Theme.TextMuted
            elseif State.Craftable > 0 or not State.Short then
                return string.format("READY  x%d", State.Craftable), Theme.Cyan
            end

            return string.format("NEED %s %d/%d", State.Short.Name, State.Short.Have, State.Short.Need), Theme.Warning
        end

        --// "WEAPON  ·  LV 20  ·  BOUND": type, level (or skill) and whether
        --// it can be traded, from the assets.
        local function DescribeItem(Name)
            local Info = Recipes:GetItemInfo(Name)

            if not Info then
                return Recipes.UNKNOWN_TYPE:upper()
            end

            local Parts = { Info.Type:upper() }

            if Info.Level ~= nil then
                table.insert(Parts, "LV " .. tostring(Info.Level))
            elseif Info.Skill ~= nil then
                table.insert(Parts, "SKILL " .. tostring(Info.Skill))
            end

            if Info.Bound then
                table.insert(Parts, "BOUND")
            end

            return table.concat(Parts, "  ·  ")
        end

        --// "DMG 12  ·  DEF 3  ·  DEX 4", or nil when it has none of them.
        local function DescribeStats(Name)
            local Info = Recipes:GetItemInfo(Name)
            local Parts = {}

            for _, Stat in ipairs({ "DMG", "DEF", "DEX" }) do
                if Info and Info[Stat] ~= nil then
                    table.insert(Parts, Stat .. " " .. tostring(Info[Stat]))
                end
            end

            return #Parts > 0 and table.concat(Parts, "  ·  ") or nil
        end

        Detail.ReadInventory = ReadInventory
        Detail.Describe = Describe
        Detail.GetCraftMax = GetCraftMax
        Detail.IsInPriority = IsInPriority
        Detail.DescribeStatus = DescribeStatus
        Detail.DescribeItem = DescribeItem

        ------------------------------------------------------------------------
        --// Material popup
        ------------------------------------------------------------------------

        local function HidePopup()
            S.PopupFor = nil
            S.PopupAnchor = nil

            if Popup then
                Popup.Visible = false
            end
        end

        --// Beside the tapped row, flipped to its left when it would run off
        --// the screen, then pulled inside once its height is known.
        --// Deferred: a row just rebuilt has no position until layout runs.
        local function PlacePopup(Anchor)
            task.defer(function()
                if not Popup.Visible or S.PopupAnchor ~= Anchor or not Anchor.Parent then
                    return
                end

                local Screen = UI.ScreenGui.AbsoluteSize
                local Left = Anchor.AbsolutePosition.X + Anchor.AbsoluteSize.X + 6

                if Left + POPUP_WIDTH > Screen.X - Floating.SCREEN_MARGIN then
                    Left = Anchor.AbsolutePosition.X - POPUP_WIDTH - 6
                end

                Popup.Position = UDim2.fromOffset(Left, Anchor.AbsolutePosition.Y)
                UI._ClampToParent(Popup)
            end)
        end

        local function ShowPopup(MaterialName, Anchor)
            local Stock = ReadInventory()
            local Recipe = Recipes:Get(MaterialName)
            local Have = Stock.Inventory[MaterialName] or 0
            local Keep = Stock.Reserves[MaterialName] or 0

            ClearChildren(PopupContent)

            local Header = New("Frame", { Parent = PopupContent, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = 1 })
            Label(Header, MaterialName, 12, { Size = UDim2.new(1, -24, 1, 0), TextColor3 = Theme.Cyan, Font = Floating.Fonts.Bold })

            local Close = Button(Header, "×", Theme.Danger, {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = UDim2.fromOffset(20, 18),
            })
            UI:_Connect(Close.Activated, HidePopup)

            local HaveText = string.format("HAVE  %d", Have)

            if Keep > 0 then
                HaveText ..= string.format("   (KEEP %d)", Keep)
            end

            Label(PopupContent, HaveText, 9, { TextColor3 = Theme.TextSecondary, LayoutOrder = 2 })

            if not Recipe then
                Label(PopupContent, "Not craftable: no smithing recipe makes it", 9, {
                    TextColor3 = Theme.TextMuted,
                    TextWrapped = true,
                    TextTruncate = Enum.TextTruncate.None,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    LayoutOrder = 3,
                })
            else
                local Locked = Recipe.Skill > Stock.Skill

                Label(PopupContent, string.format("CRAFTED FROM  ·  SKILL %s", tostring(Recipe.Skill)), 9, {
                    TextColor3 = Locked and Theme.Danger or Theme.TextSecondary,
                    LayoutOrder = 3,
                })

                for Index, Material in ipairs(Recipe.Materials) do
                    local Info = DescribeMaterial(Material, Stock)

                    Label(PopupContent, string.format("  %s   %d / %d", Material.Name, Info.Usable, Material.Amount), 9, {
                        TextColor3 = Info.Missing > 0 and Theme.Warning or Theme.Text,
                        LayoutOrder = 3 + Index,
                    })
                end

                local Open = Button(PopupContent, "OPEN RECIPE", Theme.Cyan, { LayoutOrder = 100, Size = UDim2.new(1, 0, 0, 22) })

                UI:_Connect(Open.Activated, function()
                    Browser:Select(MaterialName)
                end)
            end

            S.PopupFor = MaterialName
            S.PopupAnchor = Anchor
            Popup.Visible = true
            PlacePopup(Anchor)
        end

        ------------------------------------------------------------------------
        --// RECIPE tab: details and CRAFT NOW
        ------------------------------------------------------------------------

        local function GetDetailSignature(Recipe, Stock)
            local Parts = { Recipe.Name, tostring(Stock.Skill), tostring(Stock.Inventory[Recipe.Name] or 0), tostring(IsInPriority(Recipe.Name)) }

            for _, Material in ipairs(Recipe.Materials) do
                local Info = DescribeMaterial(Material, Stock)
                table.insert(Parts, Material.Name .. ":" .. Info.Have .. ":" .. Info.Keep)
            end

            return table.concat(Parts, "|")
        end

        local function AddMaterialRow(Material, Stock, Order)
            local Info = DescribeMaterial(Material, Stock)
            local Craftable = Recipes:Get(Material.Name) ~= nil

            local Row = New("TextButton", {
                Parent = DetailScroll,
                Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
                BackgroundColor3 = Theme.Element,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = Order,
            })

            local RowStroke = Stroke(Row, Info.Missing > 0 and Theme.Warning or Theme.BorderDim, Info.Missing > 0 and 0.4 or 0.3)
            Floating.Hover(Row, RowStroke)

            Label(Row, Material.Name .. (Craftable and "  ›" or ""), 10, {
                Position = UDim2.fromOffset(8, 3),
                Size = UDim2.new(1, -90, 0, 15),
            })

            Label(Row, string.format("%d / %d", Info.Usable, Material.Amount), 10, {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, -8, 0, 3),
                Size = UDim2.fromOffset(80, 15),
                TextXAlignment = Enum.TextXAlignment.Right,
                TextColor3 = Info.Missing > 0 and Theme.Warning or Theme.Cyan,
            })

            local Note = Info.Missing > 0 and string.format("MISSING %d", Info.Missing) or "OK"

            if Info.Keep > 0 then
                Note ..= string.format("   ·   HAVE %d, KEEP %d", Info.Have, Info.Keep)
            end

            Label(Row, Note, 10, {
                Position = UDim2.fromOffset(8, 18),
                Size = UDim2.new(1, -16, 0, 13),
                TextColor3 = Info.Missing > 0 and Theme.Warning or Theme.TextMuted,
            })

            UI:_Connect(Row.Activated, function()
                if S.PopupFor == Material.Name then
                    HidePopup()
                else
                    ShowPopup(Material.Name, Row)
                end
            end)

            S.MaterialRows[Material.Name] = Row
        end

        local function TogglePriority(Name)
            local RecipeList = UIRef.RecipePriorityComponent

            if not RecipeList then
                return
            end

            if IsInPriority(Name) then
                RecipeList:Remove(Name)
                NotifyAction("AUTO SMITHING", "Removed " .. Name)
            elseif RecipeList:Add(Name, MAX_STACK) then
                NotifyAction("AUTO SMITHING", "Added " .. Name)
            end

            Browser:Refresh()
        end

        --// Clamped to what can be crafted; at least 1 whenever any can.
        local function SetCraftAmount(Value)
            local Amount = math.clamp(math.floor(tonumber(Value) or 0), math.min(1, S.CraftMax), S.CraftMax)
            S.CraftAmount = Amount

            if Craft.Slider then
                Craft.Slider:Set(Amount, false)
            end

            if Craft.AmountBox then
                Craft.AmountBox.Text = tostring(Amount)
            end
        end

        local function StartCraft(Name)
            if S.CraftMax < 1 then
                NotifyAction("CRAFT NOW", Name .. ": nothing to craft with (locked, missing materials or a full stack)")
                return
            end

            local Amount = math.clamp(S.CraftAmount, 1, S.CraftMax)

            if AutoSmithing:StartOrder(Name, Amount) then
                NotifyAction("CRAFT NOW", string.format("Crafting %d x %s", Amount, Name))
                Browser:Refresh()
            end
        end

        --// The order line and CANCEL under CRAFT NOW, kept current.
        local function RefreshOrderLine()
            if not Craft.OrderLabel or not Craft.OrderLabel.Parent then
                return
            end

            local Order = AutoSmithing:GetOrder()

            Craft.OrderLabel.Text = Order
                and string.format("ORDER  %s  %d / %d", Order.Name, Order.Done, Order.Count)
                or "NO CRAFT ORDER RUNNING"
            Craft.OrderLabel.TextColor3 = Order and Theme.Cyan or Theme.TextMuted
            Craft.CancelButton.Visible = Order ~= nil
        end

        local function BuildCraftPanel(Recipe, State, Order)
            S.CraftMax = GetCraftMax(State)

            local Panel = New("Frame", {
                Parent = DetailScroll,
                Size = UDim2.new(1, -6, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundColor3 = Theme.Element,
                BorderSizePixel = 0,
                LayoutOrder = Order,
            })

            Panel.BackgroundTransparency = 0.1
            Stroke(Panel, Theme.BorderDim, 0.25)
            Padding(Panel, 8, 8)
            List(Panel, 5)

            Label(Panel, string.format("CRAFT NOW  ·  UP TO %d", S.CraftMax), 10, {
                TextColor3 = S.CraftMax > 0 and Theme.Cyan or Theme.TextMuted,
                Font = Floating.Fonts.Bold,
                LayoutOrder = 1,
            })

            local SliderSection = Floating.Section(Panel, { LayoutOrder = 2 })

            Craft.Slider = SliderSection:AddSlider("Amount", 0, 0, math.max(1, S.CraftMax), function(Value)
                SetCraftAmount(Value)
            end)

            local Controls = New("Frame", { Parent = Panel, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 3 })

            Craft.AmountBox = New("TextBox", {
                Parent = Controls,
                Size = UDim2.fromOffset(64, 26),
                BackgroundColor3 = Theme.PanelLight,
                BorderSizePixel = 0,
                Text = "",
                PlaceholderText = "amount",
                PlaceholderColor3 = Theme.TextMuted,
                TextColor3 = Theme.Text,
                TextSize = 10,
                Font = Floating.Fonts.Bold,
                ClearTextOnFocus = false,
            })

            Floating.Hover(Craft.AmountBox, Stroke(Craft.AmountBox, Theme.BorderDim, 0.15))

            local MaxButton = Button(Controls, "MAX", Theme.Text, {
                Position = UDim2.fromOffset(70, 0),
                Size = UDim2.fromOffset(52, 26),
            })

            local CraftButton = Button(Controls, "CRAFT", S.CraftMax > 0 and Theme.Cyan or Theme.TextMuted, {
                Position = UDim2.fromOffset(128, 0),
                Size = UDim2.new(1, -128, 0, 26),
            })

            local OrderRow = New("Frame", { Parent = Panel, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 4 })
            Craft.OrderLabel = Label(OrderRow, "", 9, { Size = UDim2.new(1, -76, 1, 0) })
            Craft.CancelButton = Button(OrderRow, "CANCEL", Theme.Danger, {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(70, 22),
            })

            UI:_Connect(Craft.AmountBox.FocusLost, function()
                SetCraftAmount(Craft.AmountBox.Text)
            end)

            UI:_Connect(MaxButton.Activated, function()
                SetCraftAmount(S.CraftMax)
            end)

            UI:_Connect(CraftButton.Activated, function()
                StartCraft(Recipe.Name)
            end)

            UI:_Connect(Craft.CancelButton.Activated, function()
                AutoSmithing:CancelOrder()
                RefreshOrderLine()
            end)

            SetCraftAmount(S.CraftAmount)
            RefreshOrderLine()
        end

        local function BuildDetail(Recipe, Stock)
            ClearChildren(DetailScroll)
            table.clear(S.MaterialRows)
            table.clear(Craft)

            if not Recipe then
                Label(DetailScroll, "Pick a recipe from the list", 10, { TextColor3 = Theme.TextMuted, LayoutOrder = 1 })
                return
            end

            local State = Describe(Recipe.Name, Stock)
            local Status, StatusColor = DescribeStatus(State)
            local Info = Recipes:GetItemInfo(Recipe.Name)
            local Stats = DescribeStats(Recipe.Name)

            Label(DetailScroll, "◇  " .. string.upper(Recipe.Name), 13, { TextColor3 = Theme.Cyan, Font = Floating.Fonts.Bold, LayoutOrder = 1 })
            Label(DetailScroll, DescribeItem(Recipe.Name) .. ((Info and not Info.Bound) and "  ·  TRADEABLE" or ""), 9, {
                TextColor3 = (Info and Info.Bound) and Theme.Warning or Theme.TextSecondary,
                LayoutOrder = 2,
            })

            if Stats then
                Label(DetailScroll, Stats, 10, { TextColor3 = Theme.Text, LayoutOrder = 3 })
            end

            Label(DetailScroll, string.format("SMITHING SKILL  %s  ·  YOURS  %s  ·  HAVE  %d", tostring(Recipe.Skill), tostring(Stock.Skill), State.Have), 9, {
                TextColor3 = State.Locked and Theme.Danger or Theme.TextSecondary,
                LayoutOrder = 4,
            })
            Label(DetailScroll, Status, 10, { TextColor3 = StatusColor, Font = Floating.Fonts.Bold, LayoutOrder = 5 })
            Label(DetailScroll, "MATERIALS PER CRAFT  (tap one to see how it is made)", 10, {
                TextColor3 = Theme.TextMuted,
                LayoutOrder = 6,
            })

            if #Recipe.Materials == 0 then
                Label(DetailScroll, "  none", 9, { TextColor3 = Theme.TextMuted, LayoutOrder = 7 })
            end

            for Index, Material in ipairs(Recipe.Materials) do
                AddMaterialRow(Material, Stock, 6 + Index)
            end

            BuildCraftPanel(Recipe, State, 500)

            local InPriority = IsInPriority(Recipe.Name)
            local Toggle = Button(DetailScroll, InPriority and "REMOVE FROM RECIPE PRIORITY" or "ADD TO RECIPE PRIORITY",
                InPriority and Theme.Danger or Theme.Cyan, { Size = UDim2.new(1, -6, 0, 26), LayoutOrder = 1000 })

            UI:_Connect(Toggle.Activated, function()
                TogglePriority(Recipe.Name)
            end)
        end

        --// Rebuilt only when something it shows changed, so a refresh does
        --// not reset the scroll or drop an open popup.
        local function RefreshDetail(Stock)
            local Recipe = S.Selected and Recipes:Get(S.Selected)

            if S.Selected and not Recipe then
                S.Selected = nil
            end

            local Signature = Recipe and GetDetailSignature(Recipe, Stock) or ""

            if Signature == S.DetailSignature then
                RefreshOrderLine()
                return
            end

            S.DetailSignature = Signature
            BuildDetail(Recipe, Stock)

            --// The popup's row was replaced: follow the new one, or close.
            if S.PopupFor then
                local Anchor = S.MaterialRows[S.PopupFor]

                if Anchor then
                    ShowPopup(S.PopupFor, Anchor)
                else
                    HidePopup()
                end
            end
        end

        local function BuildPopup()
            Popup = New("TextButton", {
                --// A button, so a click on it stops here instead of reaching the UI
                --// underneath; it draws like a frame.
                Text = "",
                AutoButtonColor = false,
                Name = "SmithingBrowserPopup",
                Parent = UI.ScreenGui,
                Size = UDim2.fromOffset(POPUP_WIDTH, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundColor3 = Theme.Panel,
                BorderSizePixel = 0,
                Active = true,
                Visible = false,
                ZIndex = Floating.POPUP_Z,
            })

            Stroke(Popup, Theme.CyanDark, 0.1)
            Padding(Popup, 8, 8)

            PopupContent = New("Frame", {
                Parent = Popup,
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
            })

            List(PopupContent, 3)

            --// A tap anywhere but the popup or its row closes the popup.
            UI:_Connect(UserInputService.InputBegan, function(Input)
                if not Popup.Visible
                    or (Input.UserInputType ~= Enum.UserInputType.MouseButton1
                        and Input.UserInputType ~= Enum.UserInputType.Touch)
                then
                    return
                end

                local Position = Vector2.new(Input.Position.X, Input.Position.Y)

                if not IsInside(Popup, Position) and not IsInside(S.PopupAnchor, Position) then
                    HidePopup()
                end
            end)
        end

        ------------------------------------------------------------------------
        --// API (for SmithingBrowser)
        ------------------------------------------------------------------------

        --// Builds the tab into Scroll. Owner is the browser: Owner:Select(Name)
        --// opens a recipe, Owner:Refresh() redraws the window.
        function Detail:Build(Scroll, Owner)
            Theme = UI.Theme
            DetailScroll = Scroll
            Browser = Owner
            BuildPopup()
        end

        function Detail:Refresh(Stock)
            RefreshDetail(Stock)
        end

        function Detail:Select(Name)
            S.Selected = Name
            S.DetailSignature = nil
            S.CraftAmount = 1
            HidePopup()
        end

        function Detail:GetSelected()
            return S.Selected
        end

        --// Rebuilt on the next refresh even when nothing it shows changed.
        function Detail:Invalidate()
            S.DetailSignature = nil
        end

        function Detail:HidePopup()
            HidePopup()
        end

        return Detail
    end,
}
