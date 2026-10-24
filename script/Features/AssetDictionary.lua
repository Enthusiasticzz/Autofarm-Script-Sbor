-- AssetDictionary turns the game's assets (CoreCommons.getAssets, read by
-- SmithingRecipes) into one entry per item for the Asset Explorer
-- (AssetBrowser):
--
--   Entry = {
--       Name, Type (the asset's Value, "Other" when empty),
--       Stats = { { Key, Label, Value, Numeric } ... },  every value child
--       Worth, Flags = { Bound, Unobtainable, Badge, Pass, Group },
--       EventCurrency (the currency it is bought with, or nil),
--       Status = { Name, Props } or nil,
--   }
--
-- It also answers where an item comes from and goes: the recipe that makes
-- it, the recipes that use it, the mobs seen dropping it (MobDictionary),
-- and what the shop pays for it. Numbers are ranked against the other items
-- of the same type.
return {
    Name = "AssetDictionary",
    Dependencies = {"Runtime", "SmithingRecipes", "MobDictionary", "DetailKit"},

    Start = function(Context)
        local Recipes = Context.SmithingRecipes
        local Mobs = Context.MobDictionary
        local Kit = Context.DetailKit

        --// Children that are flags or shown on their own, not as stats.
        local FLAG_KEYS = { Bound = true, Unobtainable = true, Badge = true, Pass = true, Group = true }
        local SPECIAL_KEYS = { StatusEffect = true, EventCurrency = true, Worth = true }
        --// Stats an item's power is judged by, for the list bar.
        local POWER_KEYS = { "DMG", "DEF", "DEX" }
        --// The shop pays this share of Worth, or the second with the
        --// Agility pass. Items needing a pass, badge or group, or bought
        --// with an event currency, cannot be sold.
        local SELL_SHARE = 0.35
        local SELL_SHARE_AGILITY = 0.45

        local Dictionary = {
            Name = "AssetDictionary",
            SELL_SHARE = SELL_SHARE,
            SELL_SHARE_AGILITY = SELL_SHARE_AGILITY,
            S = {
                Entries = {},
                ByName = {},
                --// Type -> stat key -> { Max, Sorted (descending) }.
                Scales = {},
                Loaded = false,
                Error = nil,
            },
        }

        local S = Dictionary.S

        ------------------------------------------------------------------------
        --// Reading
        ------------------------------------------------------------------------

        local function SafeValue(Object)
            local Ok, Value = pcall(function()
                return Object.Value
            end)

            return Ok and Value or nil
        end

        --// Name -> { Value, Children } for every value child of an asset; an
        --// asset is an Instance, or a plain table of the same shape.
        local function ReadChildren(Asset)
            local Children = {}

            if typeof(Asset) == "Instance" then
                for _, Child in ipairs(Asset:GetChildren()) do
                    if Child:IsA("ValueBase") then
                        Children[Child.Name] = { Value = Child.Value, Children = ReadChildren(Child) }
                    end
                end
            elseif type(Asset) == "table" then
                for Name, Child in pairs(Asset) do
                    if type(Name) == "string" and Name ~= "Value" and type(Child) == "table" then
                        Children[Name] = { Value = Child.Value, Children = ReadChildren(Child) }
                    end
                end
            end

            return Children
        end

        local function ReadStatus(Child)
            local Effect = Child and Child.Value

            if Effect == nil or Effect == false or Effect == "" or string.lower(tostring(Effect)) == "none" then
                return nil
            end

            local Status = { Name = tostring(Effect), Props = {} }

            for Name, Prop in pairs(Child.Children) do
                table.insert(Status.Props, { Label = Kit.Prettify(Name), Value = Prop.Value })
            end

            table.sort(Status.Props, function(A, B)
                return A.Label < B.Label
            end)

            return Status
        end

        local function ReadEntry(Name, Asset)
            local Type = SafeValue(Asset)
            Type = Type ~= nil and tostring(Type) or ""

            local Children = ReadChildren(Asset)
            local Entry = {
                Name = Name,
                Type = Type ~= "" and Type or Recipes.UNKNOWN_TYPE,
                Stats = {},
                Flags = {},
                Worth = tonumber(Children.Worth and Children.Worth.Value),
                EventCurrency = Children.EventCurrency and tostring(Children.EventCurrency.Value) or nil,
                Status = ReadStatus(Children.StatusEffect),
            }

            for Key, Child in pairs(Children) do
                if FLAG_KEYS[Key] then
                    Entry.Flags[Key] = true
                elseif not SPECIAL_KEYS[Key] and Child.Value ~= nil then
                    table.insert(Entry.Stats, {
                        Key = Key,
                        Label = Kit.Prettify(Key),
                        Value = Child.Value,
                        Numeric = type(Child.Value) == "number",
                    })
                end
            end

            table.sort(Entry.Stats, function(A, B)
                return A.Label < B.Label
            end)

            return Entry
        end

        function Dictionary.GetStat(Entry, Key)
            for _, Stat in ipairs(Entry.Stats) do
                if Stat.Key == Key then
                    return Stat.Value
                end
            end

            return nil
        end

        --// Level, else the skill it needs, for sorting and the list.
        function Dictionary.GetLevel(Entry)
            local Level = Dictionary.GetStat(Entry, "LVL")

            if type(Level) == "number" then
                return Level, "LV"
            end

            local Skill = Dictionary.GetStat(Entry, "Skill")
            return type(Skill) == "number" and Skill or nil, "SKILL"
        end

        ------------------------------------------------------------------------
        --// Ranking within a type
        ------------------------------------------------------------------------

        local function BuildScales()
            local Values = {}

            for _, Entry in ipairs(S.Entries) do
                Values[Entry.Type] = Values[Entry.Type] or {}

                local Numbers = {}

                for _, Stat in ipairs(Entry.Stats) do
                    if Stat.Numeric then
                        Numbers[Stat.Key] = Stat.Value
                    end
                end

                Numbers.Worth = Entry.Worth

                for Key, Value in pairs(Numbers) do
                    Values[Entry.Type][Key] = Values[Entry.Type][Key] or {}
                    table.insert(Values[Entry.Type][Key], Value)
                end
            end

            S.Scales = {}

            for Type, Keys in pairs(Values) do
                S.Scales[Type] = {}

                for Key, List in pairs(Keys) do
                    table.sort(List, function(A, B)
                        return A > B
                    end)

                    S.Scales[Type][Key] = { Max = List[1], Sorted = List }
                end
            end
        end

        --// Fraction of the highest Value among the items of Type with this
        --// stat (0..1), its rank (1 = highest) and how many have it.
        function Dictionary.GetScale(Type, Key, Value)
            local Scales = S.Scales[Type]
            local Scale = Scales and Scales[Key]

            if not Scale or type(Value) ~= "number" then
                return 0, nil, 0
            end

            local Fraction = Scale.Max > 0 and math.clamp(Value / Scale.Max, 0, 1) or 0
            return Fraction, table.find(Scale.Sorted, Value), #Scale.Sorted
        end

        --// 0..1: the best of DMG / DEF / DEX against its type, or nil when
        --// it has none of them.
        function Dictionary.GetPower(Entry)
            local Best = nil

            for _, Key in ipairs(POWER_KEYS) do
                local Value = Dictionary.GetStat(Entry, Key)

                if type(Value) == "number" then
                    Best = math.max(Best or 0, (Dictionary.GetScale(Entry.Type, Key, Value)))
                end
            end

            return Best
        end

        --// "WEAPON  ·  LV 20  ·  DMG 45  ·  DEX 3".
        function Dictionary.Summarize(Entry)
            local Parts = { string.upper(Entry.Type) }
            local Level, LevelKind = Dictionary.GetLevel(Entry)

            if Level then
                table.insert(Parts, LevelKind .. " " .. Kit.FormatNumber(Level))
            end

            for _, Key in ipairs(POWER_KEYS) do
                local Value = Dictionary.GetStat(Entry, Key)

                if type(Value) == "number" then
                    table.insert(Parts, Key .. " " .. Kit.FormatNumber(Value))
                end
            end

            return table.concat(Parts, "  ·  ")
        end

        ------------------------------------------------------------------------
        --// Load
        ------------------------------------------------------------------------

        --// Reads the assets again. False (and S.Error) when they cannot be
        --// read right now.
        function Dictionary:Load()
            local Assets = Recipes:GetAssets()

            if type(Assets) ~= "table" then
                S.Error = "The game's assets cannot be read right now. Press RELOAD to try again."
                return false
            end

            local Entries, ByName = {}, {}

            for Name, Asset in pairs(Assets) do
                if type(Name) == "string" and (typeof(Asset) == "Instance" or type(Asset) == "table") then
                    local Entry = ReadEntry(Name, Asset)
                    table.insert(Entries, Entry)
                    ByName[Name] = Entry
                end
            end

            --// By type, then level (or skill), then name.
            table.sort(Entries, function(A, B)
                if A.Type ~= B.Type then
                    return A.Type < B.Type
                end

                local LevelA = Dictionary.GetLevel(A) or 0
                local LevelB = Dictionary.GetLevel(B) or 0

                if LevelA ~= LevelB then
                    return LevelA < LevelB
                end

                return A.Name < B.Name
            end)

            S.Entries = Entries
            S.ByName = ByName
            S.Error = nil
            S.Loaded = true
            BuildScales()

            --// Fixed for the load, and wanted for every list row.
            for _, Entry in ipairs(Entries) do
                Entry.Power = Dictionary.GetPower(Entry)
                Entry.Summary = Dictionary.Summarize(Entry)
            end

            return true
        end

        function Dictionary:GetAll()
            return S.Entries
        end

        function Dictionary:Get(Name)
            return S.ByName[Name]
        end

        ------------------------------------------------------------------------
        --// Where an item comes from and goes
        ------------------------------------------------------------------------

        --// The recipe that makes Name, or nil.
        function Dictionary:GetRecipe(Name)
            return Recipes:Get(Name)
        end

        --// Recipes using Name as a material: { { Recipe, Amount } ... }.
        function Dictionary:GetUses(Name)
            local Uses = {}

            for _, Recipe in ipairs(Recipes:GetAll()) do
                for _, Material in ipairs(Recipe.Materials) do
                    if Material.Name == Name then
                        table.insert(Uses, { Recipe = Recipe, Amount = Material.Amount })
                    end
                end
            end

            return Uses
        end

        --// Mobs seen (this run or saved) that drop Name, best chance first:
        --// { { Mob, Chance (with Luck), Drop } ... }.
        function Dictionary:GetDroppedBy(Name)
            local _, _, LuckPercent = Mobs.GetLuck()
            local Sources = {}

            for MobName, Drops in pairs(Mobs.S.Drops) do
                for _, Drop in ipairs(Drops) do
                    if Drop.Name == Name then
                        table.insert(Sources, {
                            Mob = MobName,
                            Drop = Drop,
                            Chance = (Mobs.GetDropOdds(Drop, LuckPercent)),
                        })
                    end
                end
            end

            table.sort(Sources, function(A, B)
                if A.Chance ~= B.Chance then
                    return A.Chance > B.Chance
                end

                return A.Mob < B.Mob
            end)

            return Sources
        end

        --// What the shop pays for one: { Normal, Agility }, or nil when it
        --// cannot be sold there.
        function Dictionary.GetSellPrice(Entry)
            local Flags = Entry.Flags

            if not Entry.Worth or Flags.Pass or Flags.Badge or Flags.Group or Entry.EventCurrency then
                return nil
            end

            return {
                Normal = math.floor(Entry.Worth * SELL_SHARE),
                Agility = math.floor(Entry.Worth * SELL_SHARE_AGILITY),
            }
        end

        --// How many the inventory holds.
        function Dictionary:GetHave(Name)
            return Recipes:GetInventory()[Name] or 0
        end

        return Dictionary
    end,
}
