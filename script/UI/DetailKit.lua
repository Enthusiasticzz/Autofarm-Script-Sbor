-- DetailKit is the set of pieces the detail side of a browser window (Mob
-- Dictionary, Asset Explorer) is drawn with, in the AIC look of Floating:
-- cards, headings, badges, thin bars, big number tiles, and the number
-- formatting they share. Colours come from the window library's theme at
-- the time of each call.
return {
    Name = "DetailKit",
    Dependencies = {"Runtime", "Floating"},

    Start = function(Context)
        local UI = Context.UI
        local Floating = Context.Floating

        local New, Stroke, Label = Floating.New, Floating.Stroke, Floating.Label

        local TILE_HEIGHT = 54
        local TRACK_HEIGHT = 6
        --// A bar for a value above 0 is never drawn thinner than this share.
        local MIN_BAR_SHARE = 0.01
        --// A badge is at least this tall; longer text wraps and grows it.
        local BADGE_HEIGHT = 18
        local BADGE_PAD_X = 7
        local BADGE_PAD_Y = 2

        local Kit = {
            Name = "DetailKit",
            TILE_HEIGHT = TILE_HEIGHT,
            GOOD_COLOR = Color3.fromRGB(96, 196, 120),
        }

        ------------------------------------------------------------------------
        --// Formatting
        ------------------------------------------------------------------------

        function Kit.TrimDecimals(Text)
            return (string.gsub(string.gsub(Text, "0+$", ""), "%.$", ""))
        end

        --// 12345 -> "12,345"; 1.5 -> "1.5".
        function Kit.FormatNumber(Value)
            if Value == math.floor(Value) and math.abs(Value) < 1e15 then
                local Text = tostring(math.floor(math.abs(Value)))
                local Grouped = string.reverse((string.gsub(string.reverse(Text), "(%d%d%d)", "%1,")))
                Grouped = string.gsub(Grouped, "^,", "")
                return (Value < 0 and "-" or "") .. Grouped
            end

            return Kit.TrimDecimals(string.format("%.2f", Value))
        end

        function Kit.FormatValue(Value)
            local Type = typeof(Value)

            if Type == "number" then
                return Kit.FormatNumber(Value)
            elseif Type == "boolean" then
                return Value and "YES" or "NO"
            elseif Type == "Instance" then
                return Value.Name
            elseif Value == nil or Value == "" then
                return "-"
            end

            return tostring(Value)
        end

        --// 0..1 -> "12.5%", with two decimals under 1%.
        function Kit.FormatPercent(Fraction)
            local Percent = Fraction * 100

            if Percent > 0 and Percent < 1 then
                return string.format("%.2f%%", Percent)
            end

            return Kit.TrimDecimals(string.format("%.1f", Percent)) .. "%"
        end

        --// "AttackRange" -> "ATTACK RANGE".
        function Kit.Prettify(Name)
            local Spaced = string.gsub(tostring(Name), "(%l)(%u)", "%1 %2")
            Spaced = string.gsub(Spaced, "_", " ")
            return string.upper(Spaced)
        end

        ------------------------------------------------------------------------
        --// Pieces
        ------------------------------------------------------------------------

        --// A row laid out left to right. Wraps lets it run onto more lines
        --// (tags); Height is then its least height.
        function Kit.Strip(Parent, Height, Order, Wraps)
            local Frame = New("Frame", {
                Parent = Parent,
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, Height),
                AutomaticSize = Wraps and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
                LayoutOrder = Order,
            })

            local Layout = New("UIListLayout", {
                Parent = Frame,
                FillDirection = Enum.FillDirection.Horizontal,
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
                Padding = UDim.new(0, 4),
            })

            --// Wraps is missing on older clients; tags then run on in one line.
            if Wraps then
                pcall(function()
                    Layout.Wraps = true
                end)
            end

            return Frame
        end

        --// A bordered panel whose children stack top to bottom.
        function Kit.Card(Parent, Order)
            local Theme = UI.Theme
            local Frame = New("Frame", {
                Parent = Parent,
                BackgroundColor3 = Theme.Element,
                BackgroundTransparency = 0.1,
                BorderSizePixel = 0,
                Size = UDim2.new(1, -6, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = Order,
            })

            Stroke(Frame, Theme.BorderDim, 0.2)
            Floating.Padding(Frame, 10, 8)
            Floating.List(Frame, 6)
            return Frame
        end

        function Kit.Heading(Parent, Text, Order)
            return Label(Parent, Text, 9, {
                TextColor3 = UI.Theme.TextMuted,
                Font = Floating.Fonts.Bold,
                LayoutOrder = Order,
            })
        end

        --// Muted text that wraps onto as many lines as it needs.
        function Kit.Note(Parent, Text, Order, Color)
            return Label(Parent, Text, 9, {
                TextColor3 = Color or UI.Theme.TextMuted,
                TextWrapped = true,
                TextTruncate = Enum.TextTruncate.None,
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = Order,
            })
        end

        --// Product of the UIScales above Object: AbsoluteSize is measured
        --// after them, sizes and constraints before.
        local function GetUIScale(Object)
            local Scale = 1
            local Current = Object

            while Current do
                local Found = Current:FindFirstChildOfClass("UIScale")

                if Found and Found.Scale > 0 then
                    Scale *= Found.Scale
                end

                Current = Current.Parent
            end

            return Scale
        end

        --// A small tinted label sized to its text. Never wider than Parent:
        --// text longer than that wraps onto more lines.
        function Kit.Badge(Parent, Text, Color, Order)
            local Object = Label(Parent, Text, 9, {
                Size = UDim2.fromOffset(0, BADGE_HEIGHT),
                AutomaticSize = Enum.AutomaticSize.XY,
                BackgroundColor3 = Color,
                BackgroundTransparency = 0.82,
                TextColor3 = Color,
                Font = Floating.Fonts.Bold,
                TextXAlignment = Enum.TextXAlignment.Center,
                TextWrapped = true,
                TextTruncate = Enum.TextTruncate.None,
                LayoutOrder = Order,
            })

            Stroke(Object, Color, 0.5)
            New("UIPadding", {
                Parent = Object,
                PaddingLeft = UDim.new(0, BADGE_PAD_X),
                PaddingRight = UDim.new(0, BADGE_PAD_X),
                PaddingTop = UDim.new(0, BADGE_PAD_Y),
                PaddingBottom = UDim.new(0, BADGE_PAD_Y),
            })

            local Limit = New("UISizeConstraint", { Parent = Object })

            --// Follows the parent as the window is resized.
            local function FitWidth()
                local Width = Parent.AbsoluteSize.X / GetUIScale(Parent)

                if Width > BADGE_PAD_X * 2 then
                    Limit.MaxSize = Vector2.new(Width, math.huge)
                end
            end

            local Resize = Parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(FitWidth)

            Object.Destroying:Connect(function()
                Resize:Disconnect()
            end)

            FitWidth()
            return Object
        end

        function Kit.SetBadge(Object, Text, Color)
            Object.Text = Text
            Object.TextColor3 = Color
            Object.BackgroundColor3 = Color

            local BadgeStroke = Object:FindFirstChildOfClass("UIStroke")

            if BadgeStroke then
                BadgeStroke.Color = Color
            end
        end

        --// Badges for every { Label, Value } in List, wrapping.
        function Kit.Tags(Parent, List, Color, Order)
            local Flow = Kit.Strip(Parent, 0, Order, true)

            for Index, Item in ipairs(List) do
                Kit.Badge(Flow, Item.Label .. "  " .. Kit.FormatValue(Item.Value), Color, Index)
            end

            return Flow
        end

        --// A thin track at Y with bars from 0 laid over it, the first one at
        --// the back: { { Fraction, Color } ... }.
        function Kit.Track(Parent, Y, Bars)
            local Back = New("Frame", {
                Parent = Parent,
                Position = UDim2.fromOffset(0, Y),
                Size = UDim2.new(1, 0, 0, TRACK_HEIGHT),
                BackgroundColor3 = UI.Theme.Background,
                BorderSizePixel = 0,
            })

            for _, Bar in ipairs(Bars) do
                if Bar.Fraction > 0 then
                    New("Frame", {
                        Parent = Back,
                        Size = UDim2.new(math.max(Bar.Fraction, MIN_BAR_SHARE), 0, 1, 0),
                        BackgroundColor3 = Bar.Color,
                        BorderSizePixel = 0,
                    })
                end
            end

            return Back
        end

        --// A name on the left and a value on the right, Height tall; put a
        --// Track under them at Y 18.
        function Kit.BarRow(Parent, Height, Order, Name, Value, ValueColor)
            local Theme = UI.Theme
            local Holder = New("Frame", {
                Parent = Parent,
                BackgroundTransparency = 1,
                Size = UDim2.new(1, 0, 0, Height),
                LayoutOrder = Order,
            })

            Label(Holder, Name, 9, {
                Size = UDim2.new(0.55, 0, 0, 14),
                TextColor3 = Theme.TextSecondary,
            })

            Label(Holder, Value, 9, {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.fromScale(1, 0),
                Size = UDim2.new(0.45, 0, 0, 14),
                TextColor3 = ValueColor or Theme.Text,
                Font = Floating.Fonts.Bold,
                TextXAlignment = Enum.TextXAlignment.Right,
            })

            return Holder
        end

        --// Big numbers side by side: { { Value, Label, Note, Color } ... }.
        function Kit.Tiles(Parent, Order, Tiles)
            if #Tiles == 0 then
                return nil
            end

            local Theme = UI.Theme
            local Row = Kit.Strip(Parent, TILE_HEIGHT, Order)
            Row.Size = UDim2.new(1, -6, 0, TILE_HEIGHT)

            for Index, Tile in ipairs(Tiles) do
                local Color = Tile.Color or Theme.Text
                local Frame = New("Frame", {
                    Parent = Row,
                    BackgroundColor3 = Theme.Element,
                    BackgroundTransparency = 0.1,
                    BorderSizePixel = 0,
                    Size = UDim2.new(1 / #Tiles, -4, 1, 0),
                    LayoutOrder = Index,
                })

                Stroke(Frame, Theme.BorderDim, 0.2)

                New("Frame", {
                    Parent = Frame,
                    BackgroundColor3 = Color,
                    BorderSizePixel = 0,
                    Size = UDim2.new(1, 0, 0, 2),
                })

                Label(Frame, Tile.Value, 18, {
                    Position = UDim2.fromOffset(10, 7),
                    Size = UDim2.new(1, -20, 0, 22),
                    Font = Floating.Fonts.Bold,
                    TextColor3 = Color,
                })

                Label(Frame, Tile.Label .. (Tile.Note and "  ·  " .. Tile.Note or ""), 8, {
                    Position = UDim2.fromOffset(10, 33),
                    Size = UDim2.new(1, -20, 0, 12),
                    TextColor3 = Theme.TextMuted,
                })
            end

            return Row
        end

        return Kit
    end,
}
