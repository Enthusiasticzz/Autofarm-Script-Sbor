-- MobDetail is the right side of the Mob Dictionary (MobBrowser): the one
-- mob picked, laid out to be read at a glance:
--
--   * Its name, kind, level, how many are alive in this server, its status
--     effect, and a 5-step threat meter.
--   * Health, speed and damage in big numbers, with their rank.
--   * DROPS PER KILL: every item it drops with the chance per kill as the
--     server rolls it, with and without the player's Luck, and the average
--     number of kills for one.
--   * Every number as a bar against the strongest of its kind, its other
--     values as tags, and its status effect.
--   * ADD TO ENEMY PRIORITY and COPY NAME.
return {
    Name = "MobDetail",
    Dependencies = {"Runtime", "Components", "Floating", "DetailKit", "MobDictionary"},

    Start = function(Context)
        local UI = Context.UI
        local AICUI = Context.AICUI
        local AICCombat = Context.AICCombat
        local AICProfile = Context.AICProfile
        local Floating = Context.Floating
        local Kit = Context.DetailKit
        local Dictionary = Context.MobDictionary

        local New, Label, Button, ClearChildren = Floating.New, Floating.Label, Floating.Button, Floating.ClearChildren
        local FormatNumber, FormatPercent, TrimDecimals = Kit.FormatNumber, Kit.FormatPercent, Kit.TrimDecimals
        local Card, Heading, Note, Badge, Strip, Track, BarRow = Kit.Card, Kit.Heading, Kit.Note, Kit.Badge, Kit.Strip, Kit.Track, Kit.BarRow

        local STAT_BAR_HEIGHT = 30
        local DROP_ROW_HEIGHT = 42
        local THREAT_SEGMENTS = 5
        --// The game announces a drop of 1 in this many or rarer as rare.
        local RARE_RARITY = 10

        local HEALTH_COLOR = Kit.GOOD_COLOR
        local EXTREME_COLOR = Color3.fromRGB(255, 60, 60)

        local Detail = {
            Name = "MobDetail",
            HEALTH_COLOR = HEALTH_COLOR,
            THREAT_SEGMENTS = THREAT_SEGMENTS,
            S = {
                Selected = nil,
                --// Luck and known drops the detail was built with; a change
                --// rebuilds it.
                Signature = nil,
                --// Updated in place on every refresh.
                LiveBadge = nil,
                PriorityButton = nil,
            },
        }

        local S = Detail.S
        local Theme, Scroll

        ------------------------------------------------------------------------
        --// Describing
        ------------------------------------------------------------------------

        --// Average kills for one drop.
        local function FormatKills(Chance)
            if Chance <= 0 then
                return "NEVER"
            end

            local Kills = 1 / Chance

            if Kills < 1.05 then
                return "EVERY KILL"
            elseif Kills < 10 then
                return "~" .. TrimDecimals(string.format("%.1f", Kills)) .. " KILLS"
            end

            return "~" .. FormatNumber(math.floor(Kills + 0.5)) .. " KILLS"
        end

        local THREAT_LEVELS = {
            { Name = "LOW", Color = function() return HEALTH_COLOR end },
            { Name = "MODERATE", Color = function() return UI.Theme.Cyan end },
            { Name = "HIGH", Color = function() return UI.Theme.Warning end },
            { Name = "SEVERE", Color = function() return UI.Theme.Danger end },
            { Name = "EXTREME", Color = function() return EXTREME_COLOR end },
        }

        --// Filled segments (1..THREAT_SEGMENTS), level name and colour.
        function Detail.DescribeThreat(Entry)
            local Filled = math.clamp(math.ceil(Dictionary.GetThreat(Entry) * THREAT_SEGMENTS), 1, THREAT_SEGMENTS)
            local Level = THREAT_LEVELS[Filled]
            return Filled, Level.Name, Level.Color()
        end

        function Detail.GetKindColor(Entry)
            return Entry.Kind == "Boss" and UI.Theme.Danger or UI.Theme.Cyan
        end

        function Detail.IsInPriority(Name)
            return AICCombat.IsEntityInPriority ~= nil and AICCombat.IsEntityInPriority(Name)
        end

        local function GetStatColor(Stat)
            if Stat.Key == "Humanoid.MaxHealth" then
                return HEALTH_COLOR
            elseif Stat.Group == "Combat" then
                return Theme.Danger
            elseif Stat.Group == "Rewards" then
                return Theme.Cyan
            end

            return Theme.TextSecondary
        end

        local function DescribeLive(Name)
            local Count = Dictionary:GetLive(Name)

            if Count > 0 then
                return string.format("●  %d IN SERVER", Count), HEALTH_COLOR
            end

            return "○  NOT IN SERVER", Theme.TextMuted
        end

        ------------------------------------------------------------------------
        --// Sections
        ------------------------------------------------------------------------

        local function BuildThreatMeter(Parent, Entry, Order)
            local Filled, LevelName, Color = Detail.DescribeThreat(Entry)
            local Row = Strip(Parent, 16, Order)

            Label(Row, "THREAT", 9, {
                Size = UDim2.fromOffset(52, 16),
                TextColor3 = Theme.TextMuted,
                Font = Floating.Fonts.Bold,
                LayoutOrder = 0,
            })

            for Index = 1, THREAT_SEGMENTS do
                New("Frame", {
                    Parent = Row,
                    Size = UDim2.fromOffset(22, 8),
                    BackgroundColor3 = Index <= Filled and Color or Theme.Background,
                    BorderSizePixel = 0,
                    LayoutOrder = Index,
                })
            end

            Label(Row, "  " .. LevelName, 10, {
                Size = UDim2.fromOffset(90, 16),
                TextColor3 = Color,
                Font = Floating.Fonts.Bold,
                LayoutOrder = THREAT_SEGMENTS + 1,
            })
        end

        local function BuildHero(Entry, Order)
            local Hero = Card(Scroll, Order)

            Label(Hero, string.upper(Entry.Name), 16, {
                Font = Floating.Fonts.Bold,
                TextColor3 = Theme.Text,
                LayoutOrder = 1,
            })

            local Badges = Strip(Hero, 18, 2)
            Badge(Badges, string.upper(Entry.Kind), Detail.GetKindColor(Entry), 1)

            local Level = Dictionary.GetStat(Entry, "Config.LVL")

            if type(Level) == "number" then
                Badge(Badges, "LV " .. FormatNumber(Level), Theme.TextSecondary, 2)
            end

            local LiveText, LiveColor = DescribeLive(Entry.Name)
            S.LiveBadge = Badge(Badges, LiveText, LiveColor, 3)

            if Entry.Status then
                Badge(Badges, "☠  " .. string.upper(Entry.Status.Name), Theme.Warning, 4)
            end

            BuildThreatMeter(Hero, Entry, 3)
        end

        --// Health, speed and the first combat number in big type.
        local function BuildTiles(Entry, Order)
            local Picked = {}

            for _, Key in ipairs({ "Humanoid.MaxHealth", "Humanoid.WalkSpeed" }) do
                for _, Stat in ipairs(Entry.Stats) do
                    if Stat.Key == Key then
                        table.insert(Picked, Stat)
                    end
                end
            end

            for _, Stat in ipairs(Entry.Stats) do
                if Stat.Numeric and Stat.Group == "Combat" then
                    table.insert(Picked, Stat)
                    break
                end
            end

            local Tiles = {}

            for _, Stat in ipairs(Picked) do
                local _, Rank, Total = Dictionary.GetScale(Stat, Entry.Kind)

                table.insert(Tiles, {
                    Value = FormatNumber(Stat.Value),
                    Label = Stat.Label,
                    Note = Rank and string.format("#%d OF %d", Rank, Total) or nil,
                    Color = GetStatColor(Stat),
                })
            end

            Kit.Tiles(Scroll, Order, Tiles)
        end

        --// One item: the chance per kill with Luck (bright) over the chance
        --// without it (grey), and how it is rolled.
        local function BuildDropRow(Parent, Drop, LuckPercent, Order)
            local Chance, Expected = Dictionary.GetDropOdds(Drop, LuckPercent)
            local BaseChance = Dictionary.GetDropOdds(Drop, 0)
            local Holder = BarRow(
                Parent, DROP_ROW_HEIGHT, Order,
                string.upper(Drop.Name),
                FormatPercent(Chance) .. "   " .. FormatKills(Chance),
                Chance > 0 and Theme.Cyan or Theme.Danger
            )

            local Bars = { { Fraction = Chance, Color = Theme.Cyan } }

            if LuckPercent > 0 then
                table.insert(Bars, { Fraction = BaseChance, Color = Theme.TextSecondary })
            end

            Track(Holder, 18, Bars)

            local Parts = {
                "1 IN " .. FormatNumber(Drop.Rarity),
                FormatNumber(Drop.Rounds) .. (Drop.Rounds == 1 and " ROLL" or " ROLLS"),
                "~" .. TrimDecimals(string.format("%.2f", Expected)) .. " PER KILL",
            }

            if LuckPercent > 0 then
                table.insert(Parts, "NO LUCK " .. FormatPercent(BaseChance))
            end

            if Drop.Rarity >= RARE_RARITY then
                table.insert(Parts, "RARE")
            end

            Label(Holder, table.concat(Parts, "  ·  "), 8, {
                Position = UDim2.fromOffset(0, 27),
                Size = UDim2.new(1, 0, 0, 12),
                TextColor3 = Theme.TextMuted,
            })
        end

        local function BuildDrops(Entry, Order)
            local DropCard = Card(Scroll, Order)
            local Luck, Cap, LuckPercent = Dictionary.GetLuck()

            Heading(DropCard, "DROPS PER KILL", 0)

            Label(DropCard, string.format(
                "LUCK %s / %s   →   +%s%% ON EVERY ROLL",
                FormatNumber(Luck), FormatNumber(Cap), FormatNumber(LuckPercent)
            ), 10, {
                TextColor3 = LuckPercent > 0 and Theme.Cyan or Theme.TextMuted,
                Font = Floating.Fonts.Bold,
                LayoutOrder = 1,
            })

            local Drops = Dictionary:GetDrops(Entry.Name)

            if not Drops then
                Note(DropCard, "Drops are read from a live one: they show once this mob has been in the server, and are saved for later runs.", 2)
                return
            elseif #Drops == 0 then
                Note(DropCard, "Drops nothing.", 2)
                return
            end

            for Index, Drop in ipairs(Drops) do
                BuildDropRow(DropCard, Drop, LuckPercent, Index + 1)
            end

            Note(DropCard, "Bright bar = with your Luck, grey = without. Event items are not counted.", #Drops + 2)
        end

        local GROUP_ORDER = { "Core", "Combat", "Rewards", "Other" }
        local GROUP_TITLES = { Core = "BODY", Combat = "COMBAT", Rewards = "REWARDS", Other = "OTHER" }

        --// Every number as a bar against the strongest of its kind, by group.
        local function BuildBars(Entry, Order)
            local BarsCard = nil

            for _, Group in ipairs(GROUP_ORDER) do
                local Stats = {}

                for _, Stat in ipairs(Entry.Stats) do
                    if Stat.Numeric and Stat.Group == Group then
                        table.insert(Stats, Stat)
                    end
                end

                if #Stats > 0 then
                    if not BarsCard then
                        BarsCard = Card(Scroll, Order)
                        Heading(BarsCard, "COMPARED TO THE STRONGEST " .. string.upper(Entry.Kind), 0)
                    end

                    local GroupOrder = #BarsCard:GetChildren() * 100
                    Heading(BarsCard, GROUP_TITLES[Group], GroupOrder).TextColor3 = Theme.TextSecondary

                    for Index, Stat in ipairs(Stats) do
                        local Fraction, Rank, Total = Dictionary.GetScale(Stat, Entry.Kind)
                        local Value = FormatNumber(Stat.Value) .. (Rank and string.format("   #%d/%d", Rank, Total) or "")
                        local Holder = BarRow(BarsCard, STAT_BAR_HEIGHT, GroupOrder + Index, Stat.Label, Value)
                        Track(Holder, 18, { { Fraction = Fraction, Color = GetStatColor(Stat) } })
                    end
                end
            end
        end

        --// Values that are not numbers, and the status effect.
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

                Label(StatusCard, "☠  " .. string.upper(Entry.Status.Name), 13, {
                    TextColor3 = Theme.Warning,
                    Font = Floating.Fonts.Bold,
                    LayoutOrder = 1,
                })

                if #Entry.Status.Props > 0 then
                    Kit.Tags(StatusCard, Entry.Status.Props, Theme.Warning, 2)
                end
            end
        end

        local function UpdatePriorityButton()
            local PriorityButton = S.PriorityButton

            if not PriorityButton or not S.Selected then
                return
            end

            local Added = Detail.IsInPriority(S.Selected)
            PriorityButton.Text = Added and "✓  IN ENEMY PRIORITY" or "+  ADD TO ENEMY PRIORITY"
            PriorityButton.TextColor3 = Added and HEALTH_COLOR or Theme.Cyan
        end

        local function BuildActions(Entry, Order)
            local Row = Strip(Scroll, 28, Order)
            Row.Size = UDim2.new(1, -6, 0, 28)

            S.PriorityButton = Button(Row, "", Theme.Cyan, {
                Size = UDim2.new(0.62, -2, 1, 0),
                LayoutOrder = 1,
            })

            local CopyButton = Button(Row, "COPY NAME", Theme.TextMuted, {
                Size = UDim2.new(0.38, -2, 1, 0),
                LayoutOrder = 2,
            })

            S.PriorityButton.Activated:Connect(function()
                if Detail.IsInPriority(Entry.Name) then
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    Context.NotifyAction("Enemy Priority", "Load or create a profile first")
                    return
                end

                if AICUI.S.AddPriorityTarget then
                    AICUI.S.AddPriorityTarget(Entry.Name)
                end

                UpdatePriorityButton()
            end)

            CopyButton.Activated:Connect(function()
                local Copied = Floating.CopyText(Entry.Name)
                Context.NotifyAction("Mob Dictionary", Copied and "Name copied" or "No clipboard here")
            end)

            UpdatePriorityButton()
        end

        --// Changes when the Luck bonus changes or the drops or AwardParam
        --// become known.
        local function GetSignature()
            local _, _, LuckPercent = Dictionary.GetLuck()
            local Drops = S.Selected and Dictionary:GetDrops(S.Selected)
            local AwardParam = S.Selected and Dictionary:GetAwardParam(S.Selected)
            return tostring(LuckPercent) .. "|" .. (Drops and #Drops or "?") .. "|" .. tostring(AwardParam)
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

        function Detail:Rebuild()
            if not Scroll then
                return
            end

            ClearChildren(Scroll)
            S.LiveBadge = nil
            S.PriorityButton = nil
            S.Signature = GetSignature()

            local Entry = S.Selected and Dictionary:Get(S.Selected)

            if not Entry then
                local Message = "Pick a mob on the left"

                if Dictionary.S.Loading then
                    Message = "Loading the mob dictionary..."
                elseif Dictionary.S.Error then
                    Message = Dictionary.S.Error
                end

                Note(Scroll, Message, 0, Dictionary.S.Error and Theme.Danger or nil)
                return
            end

            BuildHero(Entry, 1)
            BuildTiles(Entry, 2)
            BuildDrops(Entry, 3)
            BuildBars(Entry, 4)
            BuildTraits(Entry, 5)
            BuildActions(Entry, 7)
        end

        function Detail:Select(Name)
            S.Selected = Name
            Detail:Rebuild()
        end

        --// Live count and priority mark in place; the whole detail again when
        --// Luck changed or the drops just became known.
        function Detail:Refresh()
            if not Scroll then
                return
            end

            if GetSignature() ~= S.Signature then
                Detail:Rebuild()
                return
            end

            if S.LiveBadge and S.Selected then
                Kit.SetBadge(S.LiveBadge, DescribeLive(S.Selected))
            end

            UpdatePriorityButton()
        end

        return Detail
    end,
}
