-- DatabaseDump writes the game's own database to a single JSON file, so the
-- site's data can be built from what the game reports instead of from guesses.
--
-- None of it is stored in this repository, and none of it can be read outside
-- the game: every item comes from the game's assets (Commons.getAssets, the
-- table SmithingRecipes and AssetDictionary read), every recipe from
-- ReplicatedStorage.CraftingRecipes (SmithingRecipes), and every mob, with its
-- stats and drops, from BuildAssets("MobDict") (MobDictionary).
--
-- The dump is a snapshot of what those three hold at the moment it runs:
--   Items    Name, Type, Worth, EventCurrency, Flags, Sell, Status, Stats
--   Recipes  Name, CraftType, Skill, Materials { Name, Amount }
--   Mobs     Name, Kind, Stats, Status, AwardParam, DropsKnown,
--            Drops { Name, Rarity (1 in N), Rounds }
-- A mob whose drops have never been seen on a server yet is listed with
-- DropsKnown = false and no drops.
--
-- It is written to DATABASE_DUMP_FILE and copied to the clipboard. The Asset
-- Explorer's DUMP DATABASE button (AssetBrowser) calls it; anything else can
-- call DatabaseDump:Dump() the same way.
return {
    Name = "DatabaseDump",
    Dependencies = {"Runtime", "ProfileManager", "SmithingRecipes", "AssetDictionary", "MobDictionary"},

    Start = function(Context)
        local Assets = Context.AssetDictionary
        local Recipes = Context.SmithingRecipes
        local Mobs = Context.MobDictionary
        local AICProfile = Context.AICProfile
        local HttpService = Context.Services.HttpService
        local NotifyAction = Context.NotifyAction

        local DUMP_FILE = Context.PROFILE_FOLDER .. "/DatabaseDump.json"
        local FORMAT_VERSION = 1
        --// Loaded before the dump; the mob dictionary is answered by the
        --// server, so it is not ready until this long has passed at most.
        local MOB_WAIT_SECONDS = 20
        --// Polling step while waiting for it.
        local MOB_WAIT_STEP = 0.1
        --// A larger dump is saved but not copied: some executors stall on a
        --// clipboard write this big.
        local CLIPBOARD_LIMIT = 2 * 1024 * 1024

        local Dump = {
            Name = "DatabaseDump",
            FILE = DUMP_FILE,
            S = {
                Running = false,
            },
        }

        local S = Dump.S

        ------------------------------------------------------------------------
        --// Values
        ------------------------------------------------------------------------

        --// JSON holds numbers, strings, booleans and null. Anything else (an
        --// Instance, a Vector3) becomes its tostring, and a NaN or infinity
        --// is dropped rather than failing the encode.
        local function EncodeValue(Value)
            if Value == nil then
                return nil
            end

            local Kind = typeof(Value)

            if Kind == "number" then
                if Value ~= Value or Value == math.huge or Value == -math.huge then
                    return nil
                end

                return Value
            end

            if Kind == "string" or Kind == "boolean" then
                return Value
            end

            return tostring(Value)
        end

        ------------------------------------------------------------------------
        --// Loading
        ------------------------------------------------------------------------

        --// The assets are read in one go, so this either works now or not.
        local function EnsureAssets()
            if Assets.S.Loaded then
                return true
            end

            return Assets:Load() == true
        end

        --// False when the server has still not answered (the dump is then
        --// written without the mobs rather than not at all).
        local function EnsureMobs()
            if Mobs.S.Loaded then
                return true
            end

            if not Mobs.S.Loading then
                Mobs:Load()
            end

            local Deadline = os.clock() + MOB_WAIT_SECONDS

            while Mobs.S.Loading and os.clock() < Deadline do
                task.wait(MOB_WAIT_STEP)
            end

            return Mobs.S.Loaded == true
        end

        ------------------------------------------------------------------------
        --// Building
        ------------------------------------------------------------------------

        local function BuildStats(Stats)
            local List = {}

            for _, Stat in ipairs(Stats or {}) do
                local Value = EncodeValue(Stat.Value)

                if Value ~= nil then
                    table.insert(List, {
                        Key = Stat.Key,
                        Label = Stat.Label,
                        Value = Value,
                        Group = Stat.Group,
                        Numeric = Stat.Numeric == true,
                    })
                end
            end

            return List
        end

        local function BuildStatus(Status)
            if not Status then
                return nil
            end

            local Props = {}

            for _, Prop in ipairs(Status.Props or {}) do
                local Value = EncodeValue(Prop.Value)

                if Value ~= nil then
                    table.insert(Props, { Label = Prop.Label, Value = Value })
                end
            end

            return { Name = Status.Name, Props = Props }
        end

        local function BuildItems()
            local List = {}

            for _, Entry in ipairs(Assets:GetAll()) do
                local Flags = {}

                for Flag in pairs(Entry.Flags or {}) do
                    table.insert(Flags, Flag)
                end

                table.sort(Flags)

                local Sell = Assets.GetSellPrice(Entry)

                table.insert(List, {
                    Name = Entry.Name,
                    Type = Entry.Type,
                    Worth = EncodeValue(Entry.Worth),
                    EventCurrency = EncodeValue(Entry.EventCurrency),
                    Flags = Flags,
                    Sell = Sell and { Normal = Sell.Normal, Agility = Sell.Agility } or nil,
                    Status = BuildStatus(Entry.Status),
                    Stats = BuildStats(Entry.Stats),
                })
            end

            return List
        end

        local function BuildRecipes()
            local List = {}

            for _, Recipe in ipairs(Recipes:GetAll()) do
                local Materials = {}

                for _, Material in ipairs(Recipe.Materials or {}) do
                    table.insert(Materials, {
                        Name = Material.Name,
                        Amount = Material.Amount,
                    })
                end

                table.insert(List, {
                    Name = Recipe.Name,
                    CraftType = Recipe.CraftType,
                    Skill = Recipe.Skill,
                    Materials = Materials,
                })
            end

            return List
        end

        local function BuildMobs()
            local List = {}

            for _, Entry in ipairs(Mobs:GetAll()) do
                local Drops = {}
                local Known = Mobs:GetDrops(Entry.Name)

                for _, Drop in ipairs(Known or {}) do
                    table.insert(Drops, {
                        Name = Drop.Name,
                        Rarity = Drop.Rarity,
                        Rounds = Drop.Rounds,
                    })
                end

                table.insert(List, {
                    Name = Entry.Name,
                    Kind = Entry.Kind,
                    Stats = BuildStats(Entry.Stats),
                    Status = BuildStatus(Entry.Status),
                    AwardParam = EncodeValue(Mobs:GetAwardParam(Entry.Name)),
                    DropsKnown = Known ~= nil,
                    Drops = Drops,
                })
            end

            return List
        end

        --// The whole dump as a table: what Dump writes, before it is JSON.
        function Dump:Build()
            local Problems = {}
            local Items, MobList = {}, {}

            if EnsureAssets() then
                Items = BuildItems()
            else
                table.insert(Problems, Assets.S.Error or "The game's assets could not be read")
            end

            if EnsureMobs() then
                MobList = BuildMobs()
            else
                table.insert(Problems, Mobs.S.Error or "The mob dictionary could not be read")
            end

            local RecipeList = BuildRecipes()

            return {
                Generator = "AIC DatabaseDump",
                Version = FORMAT_VERSION,
                Game = game.Name,
                PlaceId = game.PlaceId,
                DumpedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                Counts = {
                    Items = #Items,
                    Recipes = #RecipeList,
                    Mobs = #MobList,
                },
                Problems = Problems,
                Items = Items,
                Recipes = RecipeList,
                Mobs = MobList,
            }
        end

        ------------------------------------------------------------------------
        --// Dumping
        ------------------------------------------------------------------------

        --// Builds, writes and copies the dump. Returns whether anything came
        --// out of it and the line that was shown.
        function Dump:Dump()
            if S.Running then
                return false, "A dump is already running"
            end

            S.Running = true

            local Ok, Data, Raw = pcall(function()
                local Built = Dump:Build()
                return Built, HttpService:JSONEncode(Built)
            end)

            if not Ok then
                S.Running = false

                local Message = "DUMP FAILED  //  " .. tostring(Data)
                NotifyAction("DATABASE", Message, 8)
                return false, Message
            end

            local Saved = false

            if AICProfile.CanUseFileStorage() then
                AICProfile.EnsureProfileFolder()
                Saved = pcall(writefile, DUMP_FILE, Raw)
            end

            local Copy = setclipboard or toclipboard
            local Copied = false

            if type(Copy) == "function" and #Raw <= CLIPBOARD_LIMIT then
                Copied = pcall(Copy, Raw)
            end

            local Summary = string.format(
                "%d items · %d recipes · %d mobs · %.1f KB",
                Data.Counts.Items,
                Data.Counts.Recipes,
                Data.Counts.Mobs,
                #Raw / 1024
            )

            local Places = {}

            if Saved then
                table.insert(Places, "saved to " .. DUMP_FILE)
            end

            if Copied then
                table.insert(Places, "copied")
            end

            local Message

            if #Places == 0 then
                Message = Summary .. "  //  no file storage or clipboard here"
            else
                Message = Summary .. "  //  " .. table.concat(Places, " · ")
            end

            if #Data.Problems > 0 then
                Message = Message .. "  //  " .. Data.Problems[1]
            end

            NotifyAction("DATABASE", Message, 8)
            S.Running = false

            return Saved or Copied, Message
        end

        return Dump
    end,
}
