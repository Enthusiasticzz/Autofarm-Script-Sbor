-- AssetBrowser is the Asset Explorer, a window of its own opened from the
-- Crafting tab. It shows every item in the game's assets (AssetDictionary):
--
--   * The left side lists them by type, then level, narrowed by the search
--     box and the ALL / OWNED / <type> chips. A thin bar under each row is
--     its best DMG / DEF / DEX against its type.
--   * The right side (AssetDetail) is the one picked: type, level, trade
--     lock, how many you have, its stats with their rank, buy and sell
--     price, the recipe that makes it and the mobs that drop it, and the
--     recipes that use it.
--   * DUMP DATABASE, across the bottom, writes every item, recipe and mob
--     the script can read to a JSON file (DatabaseDump).
return {
    Name = "AssetBrowser",
    IsFeature = true,
    Dependencies = {"Runtime", "Components", "BrowserShell", "DetailKit", "SmithingRecipes", "AssetDictionary", "AssetDetail", "DatabaseDump"},

    Start = function(Context)
        local UI = Context.UI
        local UIRef = Context.UIRef
        local Kit = Context.DetailKit
        local Recipes = Context.SmithingRecipes
        local Assets = Context.AssetDictionary
        local Detail = Context.AssetDetail
        local Dump = Context.DatabaseDump

        --// The inventory is read again this often while open.
        local REFRESH_INTERVAL = 2
        local ALL = "ALL"
        local OWNED = "OWNED"

        local Browser = {
            Name = "AssetBrowser",
            IsFeature = true,
            S = {
                LastRefresh = 0,
                --// Item -> count, read once per refresh.
                Stock = {},
            },
        }

        local S = Browser.S

        local function MatchesChip(Entry, Key)
            if Key == OWNED then
                return (S.Stock[Entry.Name] or 0) > 0
            end

            return Key == ALL or Key == nil or Entry.Type == Key
        end

        local function GetChips(Entries)
            local Counts, Types = {}, {}
            local Owned = 0

            for _, Entry in ipairs(Entries) do
                if not Counts[Entry.Type] then
                    Counts[Entry.Type] = 0
                    table.insert(Types, Entry.Type)
                end

                Counts[Entry.Type] += 1

                if (S.Stock[Entry.Name] or 0) > 0 then
                    Owned += 1
                end
            end

            table.sort(Types)

            local Chips = {
                { Key = ALL, Text = string.format("ALL  %d", #Entries) },
                { Key = OWNED, Text = string.format("OWNED  %d", Owned) },
            }

            for _, Type in ipairs(Types) do
                table.insert(Chips, { Key = Type, Text = string.format("%s  %d", string.upper(Type), Counts[Type]) })
            end

            return Chips
        end

        local function DescribeRow(Entry)
            local Theme = UI.Theme
            local Have = S.Stock[Entry.Name] or 0

            return {
                Info = Have > 0 and Entry.Summary .. "  ·  ×" .. Kit.FormatNumber(Have) or Entry.Summary,
                InfoColor = Have > 0 and Kit.GOOD_COLOR or nil,
                Accent = Entry.Flags.Bound and Theme.Warning or Theme.Cyan,
                Bar = Entry.Power,
                BarColor = Theme.Cyan,
            }
        end

        --// Name, type and every text value, so "fire" finds fire swords.
        local function MatchesSearch(Entry, Query)
            if string.find(string.lower(Entry.Name), Query, 1, true)
                or string.find(string.lower(Entry.Type), Query, 1, true)
            then
                return true
            end

            for _, Stat in ipairs(Entry.Stats) do
                if type(Stat.Value) == "string" and string.find(string.lower(Stat.Value), Query, 1, true) then
                    return true
                end
            end

            return false
        end

        local Shell = Context.BrowserShell.New({
            Title = "ASSET EXPLORER",
            Subtitle = "Every item  //  stats, price, where it comes from and goes",
            Width = 760,
            Height = 520,
            MinWidth = 580,
            MinHeight = 380,
            SearchPlaceholder = "SEARCH ITEM, TYPE OR VALUE...",
            ReloadText = "↻  RELOAD",
            OnReload = function()
                Browser:Reload()
            end,
            GetItems = function()
                return Assets:GetAll()
            end,
            GetChips = GetChips,
            MatchesChip = MatchesChip,
            MatchesSearch = MatchesSearch,
            DescribeRow = DescribeRow,
            GetSelected = function()
                return Detail:GetSelected()
            end,
            OnSelect = function(Name)
                Browser:Select(Name)
            end,
            GetEmptyText = function(Count)
                if Count == 0 then
                    return Assets.S.Error and "Assets unavailable" or "No items found"
                end

                return "No items match the filters"
            end,
            FooterText = "DUMP DATABASE",
            OnFooter = function()
                Browser:Dump()
            end,
        })

        function Browser:Refresh()
            if not Shell:IsOpen() then
                return
            end

            S.LastRefresh = os.clock()
            S.Stock = Recipes:GetInventory()
            Shell:RefreshList()
            Detail:Refresh(S.Stock)
        end

        function Browser:Select(Name)
            S.Stock = Recipes:GetInventory()
            Detail:Select(Name, S.Stock)
            Browser:Refresh()
        end

        --// Writes every item, recipe and mob to a JSON file, for the site's
        --// database to be built from (DatabaseDump).
        function Browser:Dump()
            Dump:Dump()
        end

        --// Reads the assets again, keeping the pick.
        function Browser:Reload()
            Assets:Load()

            if not Shell.Built then
                return
            end

            Shell:ResetRows()

            local Selected = Detail:GetSelected()

            if not Selected or not Assets:Get(Selected) then
                local First = Assets:GetAll()[1]
                Selected = First and First.Name or nil
            end

            Browser:Select(Selected)
        end

        function Browser:Open()
            if not Shell:Open() then
                return
            end

            Detail:Build(Shell.DetailScroll)

            if not Assets.S.Loaded then
                Browser:Reload()
            else
                S.Stock = Recipes:GetInventory()
                Detail:Rebuild(S.Stock)
                Browser:Refresh()
            end
        end

        function Browser:Toggle()
            if Shell:IsOpen() then
                Shell:Close()
            else
                Browser:Open()
            end
        end

        function Browser:Update()
            if Shell:IsOpen() and os.clock() - S.LastRefresh >= REFRESH_INTERVAL then
                Browser:Refresh()
            end
        end

        --// Under Open Recipe Browser on the Crafting tab, which AutoSmithing
        --// builds late too (it starts first, so its controls come first).
        function Browser:BuildLateUI()
            if UIRef.CraftSection then
                UIRef.CraftSection:AddButton("Open Asset Explorer", function()
                    Browser:Toggle()
                end)
            end
        end

        return Browser
    end,
}
