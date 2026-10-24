-- AssetDetail is the right side of the Asset Explorer (AssetBrowser): the
-- one item picked, laid out to be read at a glance:
--
--   * Its name, type, level, whether it can be traded, how it is locked
--     (pass, badge, group, event currency), and how many you have.
--   * DMG / DEF / DEX in big numbers with their rank among its type.
--   * VALUE: what the shop asks for it and pays for it.
--   * HOW TO GET: the recipe that makes it (materials against your
--     inventory) and the mobs seen dropping it, with the chance per kill.
--   * USED IN: the recipes that need it.
--   * Every number as a bar against the best of its type, its other values
--     as tags, its status effect, and COPY NAME / OPEN RECIPE.
return {
    Name = "AssetDetail",
    Dependencies = {"Runtime", "Floating", "DetailKit", "AssetDictionary", "MobDictionary"},

    Start = function(Context)
        local UI = Context.UI
        local Floating = Context.Floating
        local Kit = Context.DetailKit
        local Assets = Context.AssetDictionary
        local Mobs = Context.MobDictionary

        local Label, Button, ClearChildren = Floating.Label, Floating.Button, Floating.ClearChildren
        local FormatNumber, FormatPercent = Kit.FormatNumber, Kit.FormatPercent
        local Card, Heading, Note, Badge, Strip, Track, BarRow = Kit.Card, Kit.Heading, Kit.Note, Kit.Badge, Kit.Strip, Kit.Track, Kit.BarRow

        local STAT_BAR_HEIGHT = 30
        local LINE_HEIGHT = 16
        local POWER_KEYS = { "DMG", "DEF", "DEX" }
        local STAT_COLORS = { DMG = "Danger", DEF = "Cyan", DEX = "Warning" }

        local Detail = {
            Name = "AssetDetail",
            S = {
                Selected = nil,
                --// Inventory count, Luck and known drop sources the detail
                --// was built with; a change rebuilds it.
                Signature = nil,
            },
        }

        local S = Detail.S
        local Theme, Scroll

        local function GetStatColor(Key)
            local ThemeKey = STAT_COLORS[Key]
            return ThemeKey and Theme[ThemeKey] or Theme.TextSecondary
        end

        --// "1,200 COL", or the event currency it is bought with.
        local function FormatPrice(Entry, Amount)
            return FormatNumber(Amount) .. " " .. string.upper(Entry.EventCurrency or "Col")
        end

        --// A plain line of text, Color optional.
        local function Line(Parent, Text, Order, Color, Bold)
            return Label(Parent, Text, 10, {
                Size = UDim2.new(1, 0, 0, LINE_HEIGHT),
                TextColor3 = Color or Theme.Text,
                Font = Bold and Floating.Fonts.Bold or Floating.Fonts.Regular,
                LayoutOrder = Order,
            })
        end

        ------------------------------------------------------------------------
        --// Sections
        ------------------------------------------------------------------------

        local function BuildHero(Entry, Have, Order)
            local Hero = Card(Scroll, Order)

            Label(Hero, string.upper(Entry.Name), 16, {
                Font = Floating.Fonts.Bold,
                TextColor3 = Theme.Text,
                LayoutOrder = 1,
            })

            local Badges = Strip(Hero, 18, 2, true)
            local Flags = Entry.Flags
            local Level, LevelKind = Assets.GetLevel(Entry)
            local Index = 0

            local function Add(Text, Color)
                Index += 1
                Badge(Badges, Text, Color, Index)
            end

            Add(string.upper(Entry.Type), Theme.Cyan)

            if Level then
                Add(LevelKind .. " " .. FormatNumber(Level), Theme.TextSecondary)
            end

            Add(Flags.Bound and "BOUND" or "TRADEABLE", Flags.Bound and Theme.Warning or Kit.GOOD_COLOR)

            if Flags.Unobtainable then
                Add("UNOBTAINABLE", Theme.Danger)
            end

            if Flags.Pass then
                Add("GAME PASS", Theme.Warning)
            end

            if Flags.Badge then
                Add("BADGE", Theme.Warning)
            end

            if Flags.Group then
                Add("GROUP", Theme.Warning)
            end

            if Entry.EventCurrency then
                Add("EVENT  " .. string.upper(Entry.EventCurrency), Theme.Warning)
            end

            if Entry.Status then
                Add("☠  " .. string.upper(Entry.Status.Name), Theme.Warning)
            end

            Add(Have > 0 and ("HAVE  " .. FormatNumber(Have)) or "NOT OWNED", Have > 0 and Kit.GOOD_COLOR or Theme.TextMuted)
        end

        --// DMG / DEF / DEX in big type, or its worth when it has none.
        local function BuildTiles(Entry, Order)
            local Tiles = {}

            for _, Key in ipairs(POWER_KEYS) do
                local Value = Assets.GetStat(Entry, Key)

                if type(Value) == "number" then
                    local _, Rank, Total = Assets.GetScale(Entry.Type, Key, Value)

                    table.insert(Tiles, {
                        Value = FormatNumber(Value),
                        Label = Key,
                        Note = Rank and string.format("#%d OF %d", Rank, Total) or nil,
                        Color = GetStatColor(Key),
                    })
                end
            end

            if #Tiles == 0 and Entry.Worth then
                table.insert(Tiles, {
                    Value = FormatPrice(Entry, Entry.Worth),
                    Label = "WORTH",
                    Color = Theme.Cyan,
                })
            end

            Kit.Tiles(Scroll, Order, Tiles)
        end

        local function BuildValue(Entry, Order)
            if not Entry.Worth then
                return
            end

            local ValueCard = Card(Scroll, Order)
            Heading(ValueCard, "VALUE", 0)

            if Entry.Flags.Unobtainable then
                Line(ValueCard, "BUY  ·  not sold in shops", 1, Theme.TextMuted)
            else
                Line(ValueCard, "BUY  ·  " .. FormatPrice(Entry, Entry.Worth), 1, Theme.Cyan, true)
            end

            local Sell = Assets.GetSellPrice(Entry)

            if Sell then
                Line(ValueCard, string.format(
                    "SELL  ·  %s COL   (%s with the Agility pass)",
                    FormatNumber(Sell.Normal), FormatNumber(Sell.Agility)
                ), 2, Kit.GOOD_COLOR, true)
            else
                Line(ValueCard, "SELL  ·  the shop does not buy it", 2, Theme.TextMuted)
            end
        end

        --// The recipe: skill, and each material against the inventory.
        local function BuildRecipe(Parent, Recipe, Stock, Order)
            local Skill = Context.SmithingRecipes:GetSkill()
            local Locked = Recipe.Skill > Skill

            Line(Parent, string.format(
                "CRAFTED  ·  SMITHING SKILL %s  (YOURS %s)",
                FormatNumber(Recipe.Skill), FormatNumber(Skill)
            ), Order, Locked and Theme.Danger or Theme.Cyan, true)

            for Index, Material in ipairs(Recipe.Materials) do
                local Have = Stock[Material.Name] or 0

                Line(Parent, string.format(
                    "    %s   %s / %s",
                    Material.Name, FormatNumber(Have), FormatNumber(Material.Amount)
                ), Order + Index, Have >= Material.Amount and Theme.Text or Theme.Warning)
            end
        end

        local function BuildSources(Entry, Stock, Order)
            local Recipe = Assets:GetRecipe(Entry.Name)
            local Sources = Assets:GetDroppedBy(Entry.Name)
            local SourceCard = Card(Scroll, Order)

            Heading(SourceCard, "HOW TO GET", 0)

            if Recipe then
                BuildRecipe(SourceCard, Recipe, Stock, 1)
            end

            for Index, Source in ipairs(Sources) do
                local Holder = BarRow(
                    SourceCard, STAT_BAR_HEIGHT, 100 + Index,
                    "DROPPED BY  " .. string.upper(Source.Mob),
                    FormatPercent(Source.Chance) .. " / KILL",
                    Source.Chance > 0 and Theme.Cyan or Theme.Danger
                )

                Track(Holder, 18, { { Fraction = Source.Chance, Color = Theme.Cyan } })
            end

            if not Recipe and #Sources == 0 then
                Note(SourceCard, Entry.Flags.Unobtainable
                    and "No recipe makes it and no known mob drops it."
                    or "No recipe makes it and no known mob drops it. It may be sold in a shop.", 1)
            end

            Note(SourceCard, "Drops are known for mobs that have been in the server, now or in an earlier run (Mob Dictionary).", 999)
        end

        local function BuildUses(Entry, Order)
            local Uses = Assets:GetUses(Entry.Name)

            if #Uses == 0 then
                return
            end

            local UsesCard = Card(Scroll, Order)
            Heading(UsesCard, string.format("USED IN  %d RECIPE%s", #Uses, #Uses == 1 and "" or "S"), 0)

            for Index, Use in ipairs(Uses) do
                Line(UsesCard, string.format(
                    "%s   ×%s   ·   SKILL %s",
                    string.upper(Use.Recipe.Name), FormatNumber(Use.Amount), FormatNumber(Use.Recipe.Skill)
                ), Index)
            end
        end

        --// Every number, and its worth, against the best of its type.
        local function BuildBars(Entry, Order)
            local Rows = {}

            for _, Stat in ipairs(Entry.Stats) do
                if Stat.Numeric then
                    table.insert(Rows, { Key = Stat.Key, Label = Stat.Label, Value = Stat.Value })
                end
            end

            if Entry.Worth then
                table.insert(Rows, { Key = "Worth", Label = "WORTH", Value = Entry.Worth })
            end

            if #Rows == 0 then
                return
            end

            local BarsCard = Card(Scroll, Order)
            Heading(BarsCard, "COMPARED TO THE BEST " .. string.upper(Entry.Type), 0)

            for Index, Row in ipairs(Rows) do
                local Fraction, Rank, Total = Assets.GetScale(Entry.Type, Row.Key, Row.Value)
                local Value = FormatNumber(Row.Value) .. (Rank and string.format("   #%d/%d", Rank, Total) or "")
                local Holder = BarRow(BarsCard, STAT_BAR_HEIGHT, Index, Row.Label, Value)
                Track(Holder, 18, { { Fraction = Fraction, Color = GetStatColor(Row.Key) } })
            end
        end

        local function BuildTraits(Entry, Order)
            local Traits = {}

            for _, Stat in ipairs(Entry.Stats) do
                if not Stat.Numeric then
                    table.insert(Traits, Stat)
                end
            end

            if #Traits > 0 then
                local TraitsCard = Card(Scroll, Order)
                Heading(TraitsCard, "TRAITS", 0)
                Kit.Tags(TraitsCard, Traits, Theme.TextSecondary, 1)
            end

            if Entry.Status then
                local StatusCard = Card(Scroll, Order + 1)
                Heading(StatusCard, "STATUS EFFECT", 0)
                Line(StatusCard, "☠  " .. string.upper(Entry.Status.Name), 1, Theme.Warning, true)

                if #Entry.Status.Props > 0 then
                    Kit.Tags(StatusCard, Entry.Status.Props, Theme.Warning, 2)
                end
            end
        end

        local function BuildActions(Entry, Order)
            local Row = Strip(Scroll, 28, Order)
            Row.Size = UDim2.new(1, -6, 0, 28)

            local HasRecipe = Assets:GetRecipe(Entry.Name) ~= nil
            local CopyButton = Button(Row, "COPY NAME", Theme.TextMuted, {
                Size = UDim2.new(HasRecipe and 0.5 or 1, HasRecipe and -2 or 0, 1, 0),
                LayoutOrder = 1,
            })

            CopyButton.Activated:Connect(function()
                local Copied = Floating.CopyText(Entry.Name)
                Context.NotifyAction("Asset Explorer", Copied and "Name copied" or "No clipboard here")
            end)

            if HasRecipe then
                local RecipeButton = Button(Row, "OPEN RECIPE  ›", Theme.Cyan, {
                    Size = UDim2.new(0.5, -2, 1, 0),
                    LayoutOrder = 2,
                })

                RecipeButton.Activated:Connect(function()
                    local Browser = Context.SmithingBrowser

                    if Browser then
                        Browser:Open()
                        Browser:Select(Entry.Name)
                    end
                end)
            end
        end

        --// Changes with the counts held of it and its materials, Luck, and
        --// the mobs known to drop it.
        local function GetSignature(Stock)
            local _, _, LuckPercent = Mobs.GetLuck()
            local Name = S.Selected
            local Parts = { tostring(Stock[Name] or 0), tostring(LuckPercent), tostring(#Assets:GetDroppedBy(Name)) }
            local Recipe = Assets:GetRecipe(Name)

            for _, Material in ipairs(Recipe and Recipe.Materials or {}) do
                table.insert(Parts, tostring(Stock[Material.Name] or 0))
            end

            return table.concat(Parts, "|")
        end

        ------------------------------------------------------------------------
        --// API
        ------------------------------------------------------------------------

        function Detail:Build(Parent)
            Theme = UI.Theme
            Scroll = Parent
        end

        function Detail:GetSelected()
            return S.Selected
        end

        --// Stock is the inventory (item -> count), read once by the caller.
        function Detail:Rebuild(Stock)
            if not Scroll then
                return
            end

            ClearChildren(Scroll)

            local Entry = S.Selected and Assets:Get(S.Selected)

            if not Entry then
                local Error = Assets.S.Error
                Note(Scroll, Error or "Pick an item on the left", 0, Error and Theme.Danger or nil)
                S.Signature = nil
                return
            end

            local Have = Stock[Entry.Name] or 0
            S.Signature = GetSignature(Stock)

            BuildHero(Entry, Have, 1)
            BuildTiles(Entry, 2)
            BuildValue(Entry, 3)
            BuildSources(Entry, Stock, 4)
            BuildUses(Entry, 5)
            BuildBars(Entry, 6)
            BuildTraits(Entry, 7)
            BuildActions(Entry, 9)
        end

        function Detail:Select(Name, Stock)
            S.Selected = Name
            Detail:Rebuild(Stock)
        end

        --// Rebuilt when the count held, Luck or the known drops changed.
        function Detail:Refresh(Stock)
            if not Scroll or not S.Selected then
                return
            end

            if GetSignature(Stock) ~= S.Signature then
                Detail:Rebuild(Stock)
            end
        end

        return Detail
    end,
}
