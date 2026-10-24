-- MobBrowser is the Mob Dictionary, a window of its own opened from the
-- Targeting section. It shows what the game's mob dictionary (MobDictionary)
-- says about every mob and boss, at a glance:
--
--   * The left side lists every mob, weakest to strongest by health,
--     narrowed by the search box and the ALL / MOBS / BOSSES / LIVE chips.
--     A thin bar under each row is its threat.
--   * The right side (MobDetail) is the one picked: kind, level, live count,
--     threat, big numbers, drops per kill with the player's Luck, every
--     number against the strongest of its kind, and Add to Enemy Priority.
return {
    Name = "MobBrowser",
    IsFeature = true,
    Dependencies = {"Runtime", "Components", "BrowserShell", "DetailKit", "MobDictionary", "MobDetail"},

    Start = function(Context)
        local UIRef = Context.UIRef
        local Kit = Context.DetailKit
        local Dictionary = Context.MobDictionary
        local Detail = Context.MobDetail

        local FormatNumber = Kit.FormatNumber

        --// Live counts, drops, Luck and priority marks are read again this
        --// often while open.
        local REFRESH_INTERVAL = 1
        local FILTERS = { "ALL", "MOBS", "BOSSES", "LIVE" }

        local Browser = {
            Name = "MobBrowser",
            IsFeature = true,
            S = {
                LastRefresh = 0,
            },
        }

        local S = Browser.S

        local function MatchesFilter(Entry, Filter)
            if Filter == "MOBS" then
                return Entry.Kind == "Mob"
            elseif Filter == "BOSSES" then
                return Entry.Kind == "Boss"
            elseif Filter == "LIVE" then
                return Dictionary:GetLive(Entry.Name) > 0
            end

            return true
        end

        local function DescribeRow(Entry)
            local Parts = { string.upper(Entry.Kind) }
            local Level = Dictionary.GetStat(Entry, "Config.LVL")
            local Health = Dictionary.GetStat(Entry, "Humanoid.MaxHealth")
            local Count = Dictionary:GetLive(Entry.Name)
            local Drops = Dictionary:GetDrops(Entry.Name)

            if type(Level) == "number" then
                table.insert(Parts, "LV " .. FormatNumber(Level))
            end

            if Health then
                table.insert(Parts, "HP " .. FormatNumber(Health))
            end

            if Drops and #Drops > 0 then
                table.insert(Parts, #Drops .. (#Drops == 1 and " DROP" or " DROPS"))
            end

            if Count > 0 then
                table.insert(Parts, string.format("● %d LIVE", Count))
            end

            if Detail.IsInPriority(Entry.Name) then
                table.insert(Parts, "✓")
            end

            local Filled, _, ThreatColor = Detail.DescribeThreat(Entry)

            return {
                Info = table.concat(Parts, "  ·  "),
                InfoColor = Count > 0 and Kit.GOOD_COLOR or nil,
                Accent = Detail.GetKindColor(Entry),
                Bar = Filled / Detail.THREAT_SEGMENTS,
                BarColor = ThreatColor,
            }
        end

        local Shell = Context.BrowserShell.New({
            Title = "MOB DICTIONARY",
            Subtitle = "Every mob and boss  //  drops with your Luck  //  add to Enemy Priority",
            Width = 760,
            Height = 520,
            MinWidth = 580,
            MinHeight = 380,
            SearchPlaceholder = "SEARCH MOB...",
            ReloadText = "↻  RELOAD",
            OnReload = function()
                Browser:Reload()
            end,
            GetItems = function()
                return Dictionary:GetAll()
            end,
            GetChips = function(Entries)
                local Chips = {}

                for _, Filter in ipairs(FILTERS) do
                    local Count = 0

                    for _, Entry in ipairs(Entries) do
                        if MatchesFilter(Entry, Filter) then
                            Count += 1
                        end
                    end

                    table.insert(Chips, { Key = Filter, Text = string.format("%s  %d", Filter, Count) })
                end

                return Chips
            end,
            MatchesChip = MatchesFilter,
            DescribeRow = DescribeRow,
            GetSelected = function()
                return Detail:GetSelected()
            end,
            OnSelect = function(Name)
                Browser:Select(Name)
            end,
            GetEmptyText = function(Count)
                if Dictionary.S.Loading then
                    return "Loading..."
                elseif Count == 0 then
                    return Dictionary.S.Error and "Mob dictionary unavailable" or "No mobs found"
                end

                return "No mobs match the filters"
            end,
        })

        function Browser:Refresh()
            if not Shell:IsOpen() then
                return
            end

            S.LastRefresh = os.clock()
            Dictionary:ScanLive()
            Shell:RefreshList()
            Detail:Refresh()
        end

        function Browser:Select(Name)
            Detail:Select(Name)
            Browser:Refresh()
        end

        --// The dictionary arrived (or failed): show it, keeping the pick, or
        --// the first mob when there is none.
        Dictionary.S.OnLoaded = function()
            if not Shell.Built then
                return
            end

            --// Rows draw their threat from the ranks; rebuild them.
            Shell:ResetRows()

            local Selected = Detail:GetSelected()

            if not Selected or not Dictionary:Get(Selected) then
                local First = Dictionary:GetAll()[1]
                Selected = First and First.Name or nil
            end

            Detail:Select(Selected)
            Browser:Refresh()
        end

        function Browser:Reload()
            Dictionary:Load()

            if Shell.Built then
                Shell:RefreshList()
                Detail:Rebuild()
            end
        end

        function Browser:Open()
            if not Shell:Open() then
                return
            end

            Detail:Build(Shell.DetailScroll)

            if not Dictionary.S.Loaded and not Dictionary.S.Loading then
                Browser:Reload()
            else
                Detail:Rebuild()
            end

            Browser:Refresh()
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

        --// Below Enemy Priority and the target pickers, which Bootstrap adds.
        function Browser:BuildLateUI()
            if UIRef.TargetSection then
                UIRef.TargetSection:AddButton("Open Mob Dictionary", function()
                    Browser:Toggle()
                end)
            end
        end

        return Browser
    end,
}
