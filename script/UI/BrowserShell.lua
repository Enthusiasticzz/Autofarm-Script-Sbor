-- BrowserShell is the frame of a list-and-detail browser window (Mob
-- Dictionary, Asset Explorer): a search box, an optional reload button, a
-- row of filter chips, the list on the left and a scroller on the right for
-- the detail, which the caller draws (with DetailKit).
--
-- BrowserShell.New(Options) takes:
--   Title, Subtitle, Width, Height, MinWidth, MinHeight
--   SearchPlaceholder
--   ReloadText, OnReload()     a button right of the search box (optional)
--   FooterText, OnFooter()     a button across the bottom of the window (optional)
--   GetItems()                 the list, in order; each item has a Name
--   GetChips(Items)            { { Key, Text } ... }; the first is selected
--                              when the selected one goes away
--   MatchesChip(Item, Key)     whether Item is shown under chip Key
--   MatchesSearch(Item, Query) optional; the name by default
--   DescribeRow(Item)          { Info, InfoColor, Accent, Bar, BarColor }
--                              Bar is 0..1 under the row, or nil
--   GetSelected()              the selected Name, highlighted
--   OnSelect(Name)
--   GetEmptyText(AllCount)     shown when no row is
--   OnClose()
-- and returns a shell with Open, Close, IsOpen, RefreshList, ResetRows (the
-- rows are rebuilt next refresh) and DetailScroll (once opened).
return {
    Name = "BrowserShell",
    Dependencies = {"Runtime", "Floating"},

    Start = function(Context)
        local UI = Context.UI
        local Floating = Context.Floating

        local New, Stroke = Floating.New, Floating.Stroke
        local Label, Button, ClearChildren = Floating.Label, Floating.Button, Floating.ClearChildren

        --// Share of the window the list takes; the detail gets the rest.
        local LIST_WIDTH_SCALE = 0.42
        local ROW_HEIGHT = 52
        local BAR_HEIGHT = 36
        local CHIP_HEIGHT = 30
        local RELOAD_WIDTH = 112
        --// The optional footer button, and the gap above it.
        local FOOTER_HEIGHT = 30
        local FOOTER_GAP = 8
        --// Row text: name over info, stacked by a layout and centred; the
        --// row grows past ROW_HEIGHT when the text does (Text Scale).
        local ROW_TEXT_X = 12
        local ROW_TEXT_GAP = 4
        local ROW_TEXT_PAD_Y = 10
        local ROW_NAME_SIZE = 12
        local ROW_INFO_SIZE = 10

        local Shell = { Name = "BrowserShell" }

        local function DefaultSearch(Item, Query)
            return string.find(string.lower(Item.Name), Query, 1, true) ~= nil
        end

        function Shell.New(Options)
            local Browser = {
                Built = false,
                Opened = false,
                ChipKey = nil,
                ChipSignature = nil,
                Chips = {},
                --// Name -> list row, kept between refreshes.
                Rows = {},
                DetailScroll = nil,
            }

            local Theme, Window, SearchBox, ChipScroll, ListScroll, EmptyLabel
            local MatchesSearch = Options.MatchesSearch or DefaultSearch

            local function StyleChip(Chip, Active)
                Chip.TextColor3 = Active and Theme.Cyan or Theme.TextMuted
                Chip.BackgroundColor3 = Active and Theme.PanelHover or Theme.Element
                Chip.AutoButtonColor = false
            end

            --// Rebuilt only when the chips themselves change.
            local function RefreshChips(Items)
                local Chips = Options.GetChips(Items)
                local Parts, Known = {}, {}

                for _, Chip in ipairs(Chips) do
                    table.insert(Parts, Chip.Key .. "=" .. Chip.Text)
                    Known[Chip.Key] = true
                end

                if not Known[Browser.ChipKey] then
                    Browser.ChipKey = Chips[1] and Chips[1].Key or nil
                end

                local Signature = table.concat(Parts, "|")

                if Signature ~= Browser.ChipSignature then
                    Browser.ChipSignature = Signature
                    ClearChildren(ChipScroll)
                    table.clear(Browser.Chips)

                    for Index, Chip in ipairs(Chips) do
                        local Object = Button(ChipScroll, Chip.Text, Theme.TextMuted, {
                            Size = UDim2.fromOffset(0, CHIP_HEIGHT),
                            AutomaticSize = Enum.AutomaticSize.X,
                            TextSize = 12,
                            LayoutOrder = Index,
                        })

                        New("UIPadding", { Parent = Object, PaddingLeft = UDim.new(0, 13), PaddingRight = UDim.new(0, 13) })

                        UI:_Connect(Object.Activated, function()
                            Browser.ChipKey = Chip.Key
                            Browser:RefreshList()
                        end)

                        Browser.Chips[Chip.Key] = Object
                    end
                end

                for Key, Object in pairs(Browser.Chips) do
                    StyleChip(Object, Key == Browser.ChipKey)
                end
            end

            local function CreateRow(Item)
                local Name = Item.Name
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

                local Accent = New("Frame", {
                    Parent = Row,
                    Position = UDim2.fromOffset(0, 6),
                    Size = UDim2.new(0, 3, 1, -12),
                    BorderSizePixel = 0,
                })

                local TextStack = New("Frame", {
                    Parent = Row,
                    BackgroundTransparency = 1,
                    AnchorPoint = Vector2.new(0, 0.5),
                    Position = UDim2.new(0, ROW_TEXT_X, 0.5, 0),
                    Size = UDim2.new(1, -(ROW_TEXT_X + 8), 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                })

                New("UIListLayout", {
                    Parent = TextStack,
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    Padding = UDim.new(0, ROW_TEXT_GAP),
                })

                local NameLabel = Label(TextStack, string.upper(Name), ROW_NAME_SIZE, {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    Font = Floating.Fonts.Bold,
                    LayoutOrder = 1,
                })

                local InfoLabel = Label(TextStack, "", ROW_INFO_SIZE, {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    TextColor3 = Theme.TextMuted,
                    LayoutOrder = 2,
                })

                --// Taller when Text Scale makes the text bigger.
                local function FitRow()
                    local Needed = NameLabel.TextSize + InfoLabel.TextSize + ROW_TEXT_GAP + ROW_TEXT_PAD_Y * 2
                    Row.Size = UDim2.new(1, -6, 0, math.max(ROW_HEIGHT, Needed))
                end

                NameLabel:GetPropertyChangedSignal("TextSize"):Connect(FitRow)
                InfoLabel:GetPropertyChangedSignal("TextSize"):Connect(FitRow)
                FitRow()

                --// A thin bar along the bottom (threat, power...).
                local Bar = New("Frame", {
                    Parent = Row,
                    Position = UDim2.new(0, 10, 1, -4),
                    Size = UDim2.new(0, 0, 0, 2),
                    BorderSizePixel = 0,
                })

                UI:_Connect(Row.Activated, function()
                    Options.OnSelect(Name)
                end)

                return { Button = Row, Accent = Accent, NameLabel = NameLabel, InfoLabel = InfoLabel, Bar = Bar }
            end

            local function UpdateRow(Row, Item)
                local Look = Options.DescribeRow(Item)
                local Selected = Options.GetSelected() == Item.Name
                local Share = math.clamp(Look.Bar or 0, 0, 1)

                Row.InfoLabel.Text = Look.Info or ""
                Row.InfoLabel.TextColor3 = Look.InfoColor or Theme.TextMuted
                Row.Accent.BackgroundColor3 = Look.Accent or Theme.BorderDim
                Row.Bar.Visible = Share > 0
                Row.Bar.Size = UDim2.new(Share, -28 * Share, 0, 3)
                Row.Bar.BackgroundColor3 = Look.BarColor or Theme.Cyan
                Row.NameLabel.TextColor3 = Selected and Theme.Cyan or Theme.Text
                Row.Button.BackgroundColor3 = Selected and Theme.PanelHover or Theme.Element
            end

            function Browser:RefreshList()
                if not Browser.Built then
                    return
                end

                local Query = string.lower(SearchBox.Text or "")
                local Items = Options.GetItems()
                local Seen = {}
                local Shown = 0

                RefreshChips(Items)

                for Index, Item in ipairs(Items) do
                    Seen[Item.Name] = true

                    local Row = Browser.Rows[Item.Name]

                    if not Row then
                        Row = CreateRow(Item)
                        Browser.Rows[Item.Name] = Row
                    end

                    local Visible = Options.MatchesChip(Item, Browser.ChipKey)
                        and (Query == "" or MatchesSearch(Item, Query))

                    Row.Button.Visible = Visible
                    Row.Button.LayoutOrder = Index

                    if Visible then
                        Shown += 1
                        UpdateRow(Row, Item)
                    end
                end

                for Name, Row in pairs(Browser.Rows) do
                    if not Seen[Name] then
                        Row.Button:Destroy()
                        Browser.Rows[Name] = nil
                    end
                end

                EmptyLabel.Text = Options.GetEmptyText(#Items)
                EmptyLabel.Visible = Shown == 0
            end

            --// Drops every row; the next refresh builds them again.
            function Browser:ResetRows()
                for _, Row in pairs(Browser.Rows) do
                    Row.Button:Destroy()
                end

                table.clear(Browser.Rows)
            end

            local function BuildFilterBar(Body)
                local HasReload = Options.ReloadText ~= nil

                SearchBox = New("TextBox", {
                    Parent = Body,
                    Size = UDim2.new(1, HasReload and -(RELOAD_WIDTH + 8) or 0, 0, BAR_HEIGHT),
                    BackgroundColor3 = Theme.Element,
                    BorderSizePixel = 0,
                    Text = "",
                    PlaceholderText = Options.SearchPlaceholder or "SEARCH...",
                    PlaceholderColor3 = Theme.TextMuted,
                    TextColor3 = Theme.Text,
                    TextSize = 10,
                    Font = Floating.Fonts.Regular,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    ClearTextOnFocus = false,
                })

                Floating.Hover(SearchBox, Stroke(SearchBox, Theme.BorderDim, 0.15))
                New("UIPadding", { Parent = SearchBox, PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) })

                UI:_Connect(SearchBox:GetPropertyChangedSignal("Text"), function()
                    Browser:RefreshList()
                end)

                if HasReload then
                    local Reload = Button(Body, Options.ReloadText, Theme.TextMuted, {
                        AnchorPoint = Vector2.new(1, 0),
                        Position = UDim2.new(1, 0, 0, 0),
                        Size = UDim2.fromOffset(RELOAD_WIDTH, BAR_HEIGHT),
                    })

                    UI:_Connect(Reload.Activated, function()
                        Options.OnReload()
                    end)
                end

                --// Scrolls sideways when there are more chips than fit.
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
            end

            local function Build()
                Theme = UI.Theme

                Window = Floating.CreateWindow({
                    Title = Options.Title,
                    Subtitle = Options.Subtitle,
                    Width = Options.Width,
                    Height = Options.Height,
                    MinWidth = Options.MinWidth,
                    MinHeight = Options.MinHeight,
                    OnClose = function()
                        Browser.Opened = false

                        if Options.OnClose then
                            Options.OnClose()
                        end
                    end,
                })

                BuildFilterBar(Window.Body)

                local HasFooter = type(Options.FooterText) == "string" and Options.FooterText ~= ""
                local FooterHeight = HasFooter and (FOOTER_HEIGHT + FOOTER_GAP) or 0
                local Top = BAR_HEIGHT + CHIP_HEIGHT + 24
                local Lists = New("Frame", {
                    Parent = Window.Body,
                    BackgroundTransparency = 1,
                    Position = UDim2.fromOffset(0, Top),
                    Size = UDim2.new(1, 0, 1, -(Top + FooterHeight)),
                })

                ListScroll = Floating.Scroller(Lists, UDim2.new(), UDim2.new(LIST_WIDTH_SCALE, -6, 1, 0), 6, 6)
                EmptyLabel = Label(ListScroll, "", 10, {
                    TextColor3 = Theme.TextMuted,
                    Visible = false,
                    LayoutOrder = -1,
                })

                local Divider = New("Frame", {
                    Parent = Lists,
                    Position = UDim2.new(LIST_WIDTH_SCALE, 0, 0, 0),
                    Size = UDim2.new(0, 1, 1, 0),
                    BackgroundColor3 = Theme.BorderDim,
                    BorderSizePixel = 0,
                })

                Browser.DetailScroll = Floating.Scroller(
                    Lists,
                    UDim2.new(LIST_WIDTH_SCALE, 4, 0, 0),
                    UDim2.new(1 - LIST_WIDTH_SCALE, -4, 1, 0),
                    10, 10, 10
                )

                if HasFooter then
                    local Footer = Button(Window.Body, Options.FooterText, Theme.Cyan, {
                        AnchorPoint = Vector2.new(0, 1),
                        Position = UDim2.new(0, 0, 1, 0),
                        Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
                    })

                    UI:_Connect(Footer.Activated, function()
                        if Options.OnFooter then
                            Options.OnFooter()
                        end
                    end)
                end

                Browser.Built = true
            end

            --// False when there is no window library to draw in.
            function Browser:Open()
                if not Floating.Available() then
                    return false
                end

                if not Browser.Built then
                    Build()
                end

                Browser.Opened = true
                Window:Open()
                return true
            end

            function Browser:Close()
                if Window then
                    Window:Close()
                end
            end

            function Browser:IsOpen()
                return Browser.Opened
            end

            return Browser
        end

        return Shell
    end,
}
