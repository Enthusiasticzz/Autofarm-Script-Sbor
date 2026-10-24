-- SmithingBrowser is the Recipe Browser, a window of its own opened from the
-- Crafting tab. Everything about crafting can be done from it, without the
-- main window:
--
--   * The left side lists every recipe, narrowed by the search box (recipe
--     or material name), the item type chips and READY ONLY.
--   * The RECIPE tab (SmithingDetail) shows the one picked, with CRAFT NOW
--     and the button that adds it to Recipe Priority.
--   * The PRIORITY tab is the Recipe Priority list itself, the same one as
--     on the Crafting tab.
return {
    Name = "SmithingBrowser",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components", "SmithingRecipes", "SmithingDetail", "Floating"},

    Start = function(Context)
        local UI = Context.UI
        local CONFIG = Context.CONFIG
        local AICUI = Context.AICUI
        local Recipes = Context.SmithingRecipes
        local Detail = Context.SmithingDetail
        local Floating = Context.Floating

        local New, Stroke = Floating.New, Floating.Stroke
        local Label, Button, ClearChildren = Floating.Label, Floating.Button, Floating.ClearChildren

        local ReadInventory, Describe, GetCraftMax = Detail.ReadInventory, Detail.Describe, Detail.GetCraftMax
        local IsInPriority, DescribeStatus, DescribeItem = Detail.IsInPriority, Detail.DescribeStatus, Detail.DescribeItem

        local MAX_STACK = Context.SaveConfig.ITEM_MAX_STACK
        local WINDOW_WIDTH = 820
        local WINDOW_HEIGHT = 540
        local MIN_WIDTH = 640
        local MIN_HEIGHT = 420
        --// Share of the window the recipe list takes; the tabs get the rest.
        local LIST_WIDTH_SCALE = 0.44
        local ROW_HEIGHT = 54
        local BAR_HEIGHT = 36
        local CHIP_HEIGHT = 32
        local ALL_TYPES = "ALL"
        --// Inventory and skill are read again this often while open.
        local REFRESH_INTERVAL = 1

        local Browser = {
            Name = "SmithingBrowser",
            IsFeature = true,
            --// Set by AutoSmithing: the PRIORITY tab changed the list.
            OnPriorityChanged = nil,
            S = {
                Built = false,
                IsOpen = false,
                --// "Recipe" or "Priority".
                Tab = "Recipe",
                TypeFilter = ALL_TYPES,
                ReadyOnly = false,
                --// Recipe name -> list row, kept between refreshes.
                Rows = {},
                --// Type -> chip button.
                Chips = {},
                ChipSignature = nil,
                LastRefresh = 0,
                --// Shows CONFIG.SMITH_RECIPES in the PRIORITY tab's list.
                LoadPriority = nil,
            },
        }

        local S = Browser.S
        local Theme, Window, SearchBox, ReadyButton, ChipScroll, ListScroll, EmptyLabel
        local DetailScroll, PriorityScroll, RecipeTabButton, PriorityTabButton

        ------------------------------------------------------------------------
        --// Filters
        ------------------------------------------------------------------------

        local function MatchesSearch(Recipe, Query)
            if Query == "" or string.find(string.lower(Recipe.Name), Query, 1, true) then
                return true
            end

            --// Also finds what a material is used in.
            for _, Material in ipairs(Recipe.Materials) do
                if string.find(string.lower(Material.Name), Query, 1, true) then
                    return true
                end
            end

            return false
        end

        local function IsShown(Recipe, Query, Stock)
            if S.TypeFilter ~= ALL_TYPES and Recipes:GetItemType(Recipe.Name) ~= S.TypeFilter then
                return false
            end

            if S.ReadyOnly and GetCraftMax(Describe(Recipe.Name, Stock)) < 1 then
                return false
            end

            return MatchesSearch(Recipe, Query)
        end

        ------------------------------------------------------------------------
        --// Tabs
        ------------------------------------------------------------------------

        local function StyleTab(TabButton, Active)
            TabButton.TextColor3 = Active and Theme.Cyan or Theme.TextMuted
            TabButton.BackgroundColor3 = Active and Theme.PanelHover or Theme.Element
        end

        local function RefreshTabs()
            DetailScroll.Visible = S.Tab == "Recipe"
            PriorityScroll.Visible = S.Tab == "Priority"
            PriorityTabButton.Text = string.format("PRIORITY  (%d)", #(CONFIG.SMITH_RECIPES or {}))
            StyleTab(RecipeTabButton, S.Tab == "Recipe")
            StyleTab(PriorityTabButton, S.Tab == "Priority")
        end

        local function SetTab(Tab)
            S.Tab = Tab
            Detail:HidePopup()
            RefreshTabs()
        end

        --// PRIORITY: the Utils priority list, bound to SMITH_RECIPES like the
        --// one on the Crafting tab. Either one changing reloads the other.
        local function BuildPriorityTab()
            local Section = Floating.Section(PriorityScroll, { Size = UDim2.new(1, -6, 0, 0) })

            Label(Section.Holder, "Recipes are crafted top to bottom until each reaches its Target. Add them from the RECIPE tab.", 10, {
                TextColor3 = Theme.TextMuted,
                TextWrapped = true,
                TextTruncate = Enum.TextTruncate.None,
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = 0,
            })

            local PriorityList = Section:AddPriority("Recipe Priority", {}, {
                Values = true,
                ValueLabel = "Target",
                Default = MAX_STACK,
                Min = 0,
                Max = MAX_STACK,
            })

            S.LoadPriority = AICUI.BindCountList(PriorityList, "SMITH_RECIPES", "Target", function()
                if Browser.OnPriorityChanged then
                    Browser.OnPriorityChanged()
                end

                Browser:Refresh()
            end)

            S.LoadPriority()
        end

        ------------------------------------------------------------------------
        --// Filters and recipe list
        ------------------------------------------------------------------------

        local function StyleChip(Chip, Active)
            Chip.TextColor3 = Active and Theme.Cyan or Theme.TextMuted
            Chip.BackgroundColor3 = Active and Theme.PanelHover or Theme.Element
        end

        --// One chip per item type among the recipes, rebuilt when the types
        --// change; the active one is highlighted.
        local function RefreshChips(All)
            local Counts = { [ALL_TYPES] = #All }
            local Types = {}

            for _, Recipe in ipairs(All) do
                local Type = Recipes:GetItemType(Recipe.Name)

                if not Counts[Type] then
                    Counts[Type] = 0
                    table.insert(Types, Type)
                end

                Counts[Type] += 1
            end

            table.sort(Types)
            table.insert(Types, 1, ALL_TYPES)

            local Parts = {}

            for _, Type in ipairs(Types) do
                table.insert(Parts, Type .. "=" .. Counts[Type])
            end

            local Signature = table.concat(Parts, "|")

            if Signature ~= S.ChipSignature then
                S.ChipSignature = Signature
                ClearChildren(ChipScroll)
                table.clear(S.Chips)

                if not Counts[S.TypeFilter] then
                    S.TypeFilter = ALL_TYPES
                end

                for Index, Type in ipairs(Types) do
                    local Text = string.format("%s  %d", Type:upper(), Counts[Type])
                    local Chip = Button(ChipScroll, Text, Theme.TextMuted, {
                        Size = UDim2.fromOffset(0, CHIP_HEIGHT),
                        AutomaticSize = Enum.AutomaticSize.X,
                        TextSize = 9,
                        LayoutOrder = Index,
                    })

                    New("UIPadding", { Parent = Chip, PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) })

                    UI:_Connect(Chip.Activated, function()
                        S.TypeFilter = Type
                        Browser:Refresh()
                    end)

                    S.Chips[Type] = Chip
                end
            end

            for Type, Chip in pairs(S.Chips) do
                StyleChip(Chip, Type == S.TypeFilter)
            end

            StyleChip(ReadyButton, S.ReadyOnly)
        end

        local function CreateRow(Name)
            local Row = New("TextButton", {
                Parent = ListScroll,
                Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
                BackgroundColor3 = Theme.Element,
                BackgroundTransparency = 0,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
            })

            Floating.Hover(Row)

            local Bar = New("Frame", {
                Parent = Row,
                Position = UDim2.fromOffset(0, 6),
                Size = UDim2.new(0, 3, 1, -12),
                BorderSizePixel = 0,
            })

            local NameLabel = Label(Row, string.upper(Name), 13, {
                Position = UDim2.fromOffset(14, 6),
                Size = UDim2.new(1, -22, 0, 20),
                Font = Floating.Fonts.Bold,
            })
            local InfoLabel = Label(Row, "", 10, { Position = UDim2.fromOffset(14, 29), Size = UDim2.new(1, -22, 0, 17) })

            UI:_Connect(Row.Activated, function()
                Browser:Select(Name)
            end)

            return { Button = Row, Bar = Bar, NameLabel = NameLabel, InfoLabel = InfoLabel }
        end

        local function UpdateRow(Row, Recipe, Stock)
            local Status, Color = DescribeStatus(Describe(Recipe.Name, Stock))
            local Selected = Detail:GetSelected() == Recipe.Name
            local Info = DescribeItem(Recipe.Name) .. "  ·  " .. Status

            if IsInPriority(Recipe.Name) then
                Info = "✓ " .. Info
            end

            Row.Bar.BackgroundColor3 = Color
            Row.InfoLabel.Text = Info
            Row.InfoLabel.TextColor3 = Color
            Row.NameLabel.TextColor3 = Selected and Theme.Cyan or Theme.Text
            Row.Button.BackgroundColor3 = Selected and Theme.PanelHover or Theme.Element
        end

        local function RefreshList(Stock)
            local Query = string.lower(SearchBox.Text or "")
            local All = Recipes:GetAll()
            local Seen = {}
            local Shown = 0

            RefreshChips(All)

            for Index, Recipe in ipairs(All) do
                Seen[Recipe.Name] = true

                local Row = S.Rows[Recipe.Name]

                if not Row then
                    Row = CreateRow(Recipe.Name)
                    S.Rows[Recipe.Name] = Row
                end

                local Visible = IsShown(Recipe, Query, Stock)
                Row.Button.Visible = Visible
                Row.Button.LayoutOrder = Index

                if Visible then
                    Shown += 1
                    UpdateRow(Row, Recipe, Stock)
                end
            end

            for Name, Row in pairs(S.Rows) do
                if not Seen[Name] then
                    Row.Button:Destroy()
                    S.Rows[Name] = nil
                end
            end

            EmptyLabel.Text = #All == 0 and "No recipes found" or "No recipes match the filters"
            EmptyLabel.Visible = Shown == 0
        end

        ------------------------------------------------------------------------
        --// Window
        ------------------------------------------------------------------------

        local function BuildFilterBar(Body)
            SearchBox = New("TextBox", {
                Parent = Body,
                Size = UDim2.new(1, -144, 0, BAR_HEIGHT),
                BackgroundColor3 = Theme.Element,
                BorderSizePixel = 0,
                Text = "",
                PlaceholderText = "SEARCH RECIPE OR MATERIAL...",
                PlaceholderColor3 = Theme.TextMuted,
                TextColor3 = Theme.Text,
                TextSize = 10,
                Font = Floating.Fonts.Regular,
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
            })

            Floating.Hover(SearchBox, Stroke(SearchBox, Theme.BorderDim, 0.15))
            New("UIPadding", { Parent = SearchBox, PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) })

            ReadyButton = Button(Body, "◇  READY ONLY", Theme.TextMuted, {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(136, BAR_HEIGHT),
            })

            ChipScroll = New("ScrollingFrame", {
                Parent = Body,
                Position = UDim2.fromOffset(0, BAR_HEIGHT + 6),
                Size = UDim2.new(1, 0, 0, CHIP_HEIGHT + 6),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.X,
                ScrollBarThickness = 3,
                ScrollBarImageColor3 = Theme.Border,
                ScrollingDirection = Enum.ScrollingDirection.X,
            })

            New("UIListLayout", {
                Parent = ChipScroll,
                FillDirection = Enum.FillDirection.Horizontal,
                SortOrder = Enum.SortOrder.LayoutOrder,
                Padding = UDim.new(0, 6),
            })

            UI:_Connect(SearchBox:GetPropertyChangedSignal("Text"), function()
                RefreshList(ReadInventory())
            end)

            UI:_Connect(ReadyButton.Activated, function()
                S.ReadyOnly = not S.ReadyOnly
                Browser:Refresh()
            end)
        end

        local function BuildRightSide(Lists)
            local Right = New("Frame", {
                Parent = Lists,
                BackgroundTransparency = 1,
                Position = UDim2.new(LIST_WIDTH_SCALE, 4, 0, 0),
                Size = UDim2.new(1 - LIST_WIDTH_SCALE, -4, 1, 0),
            })

            RecipeTabButton = Button(Right, "RECIPE", Theme.Cyan, { Size = UDim2.new(0.5, -2, 0, BAR_HEIGHT) })
            PriorityTabButton = Button(Right, "PRIORITY", Theme.TextMuted, {
                Position = UDim2.new(0.5, 2, 0, 0),
                Size = UDim2.new(0.5, -2, 0, BAR_HEIGHT),
            })

            local Below = UDim2.fromOffset(0, BAR_HEIGHT + 6)
            local BelowSize = UDim2.new(1, 0, 1, -(BAR_HEIGHT + 6))

            DetailScroll = Floating.Scroller(Right, Below, BelowSize, 8, 6)
            PriorityScroll = Floating.Scroller(Right, Below, BelowSize, 8, 6)
            Detail:Build(DetailScroll, Browser)

            UI:_Connect(RecipeTabButton.Activated, function()
                SetTab("Recipe")
            end)

            UI:_Connect(PriorityTabButton.Activated, function()
                SetTab("Priority")
            end)

            BuildPriorityTab()
        end

        local function Build()
            Theme = UI.Theme

            Window = Floating.CreateWindow({
                Title = "RECIPE BROWSER",
                Subtitle = "Find recipes  //  craft now  //  edit Recipe Priority",
                Width = WINDOW_WIDTH,
                Height = WINDOW_HEIGHT,
                MinWidth = MIN_WIDTH,
                MinHeight = MIN_HEIGHT,
                OnClose = function()
                    S.IsOpen = false
                    Detail:HidePopup()
                end,
                --// The popup belongs to a row that is now hidden.
                OnMinimize = function()
                    Detail:HidePopup()
                end,
            })

            BuildFilterBar(Window.Body)

            local Top = BAR_HEIGHT + CHIP_HEIGHT + 24
            local Lists = New("Frame", {
                Parent = Window.Body,
                BackgroundTransparency = 1,
                Position = UDim2.fromOffset(0, Top),
                Size = UDim2.new(1, 0, 1, -Top),
            })

            ListScroll = Floating.Scroller(Lists, UDim2.new(), UDim2.new(LIST_WIDTH_SCALE, -4, 1, 0), 4, 4)
            EmptyLabel = Label(ListScroll, "No recipes match the filters", 10, {
                TextColor3 = Theme.TextMuted,
                Visible = false,
                LayoutOrder = -1,
            })

            BuildRightSide(Lists)
            RefreshTabs()

            S.Built = true
        end

        ------------------------------------------------------------------------
        --// API
        ------------------------------------------------------------------------

        function Browser:Refresh()
            if not S.IsOpen then
                return
            end

            S.LastRefresh = os.clock()

            local Stock = ReadInventory()
            RefreshList(Stock)
            Detail:Refresh(Stock)
            RefreshTabs()
        end

        --// Recipe Priority changed outside the window (the Crafting tab, a
        --// profile load): show it in the PRIORITY tab too.
        function Browser:SyncPriority()
            if S.LoadPriority then
                S.LoadPriority()
            end

            Browser:Refresh()
        end

        function Browser:Select(Name)
            Detail:Select(Name)

            if S.Tab ~= "Recipe" then
                SetTab("Recipe")
            end

            Browser:Refresh()
        end

        function Browser:Open()
            if not Floating.Available() then
                return
            end

            if not S.Built then
                Build()
            end

            S.IsOpen = true
            Detail:Invalidate()
            Window:Open()
            Browser:Refresh()
        end

        function Browser:Close()
            if Window then
                Window:Close()
            end
        end

        function Browser:Toggle()
            if S.IsOpen then
                Browser:Close()
            else
                Browser:Open()
            end
        end

        function Browser:Update()
            if S.IsOpen and os.clock() - S.LastRefresh >= REFRESH_INTERVAL then
                Browser:Refresh()
            end
        end

        return Browser
    end,
}
