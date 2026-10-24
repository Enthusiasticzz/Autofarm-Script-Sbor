-- MobDictionary reads the game's mob dictionary (ReplicatedStorage.BuildAssets
-- invoked with "MobDict": every model in ServerStorage Mobs and Bosses, with
-- its Value children, its Configuration values and its Humanoid's MaxHealth
-- and WalkSpeed) and turns it into one entry per mob for the Mob Dictionary
-- window (MobBrowser):
--
--   Entry = {
--       Name, Kind ("Mob" / "Boss"),
--       Stats = { { Key, Label, Value, Group, Numeric } ... },
--       Status = { Name, Props = { { Label, Value } ... } } or nil,
--   }
--
-- Numeric stats are also ranked against the other mobs of the same kind
-- (GetScale), so the window can show each one as a share of the strongest's,
-- and GetThreat rates a mob by where its health and damage rank among all.
--
-- Drops are not in the dictionary: they are read from the first live one of
-- each mob (Config.MaxDrops), and GetDropOdds works out the chance per kill
-- the way the server's AwardPlayer rolls it, with the player's Luck. Drops
-- read are saved to DROPS_FILE, so they are known in later runs before the
-- mob is seen again; the file is written only when a mob is not saved yet
-- or its live drops differ from the saved ones.
--
-- A mob whose Config.AwardType is "HealthPercent" only rewards a player who
-- dealt at least AwardParam percent of its health (an attribute on AwardType,
-- which the dictionary leaves out). It is read from a live one too, saved in
-- DROPS_FILE beside the drops, and shown as the AWARD_PARAM_KEY stat.
return {
    Name = "MobDictionary",
    Dependencies = {"Runtime", "ProfileManager"},

    Start = function(Context)
        local Replicated = Context.Services.Replicated
        local HttpService = Context.Services.HttpService
        local AICProfile = Context.AICProfile

        local REMOTE_NAME = "BuildAssets"
        local REMOTE_ARGUMENT = "MobDict"
        --// The server's folder names, and what each is shown as.
        local KIND_BY_FOLDER = { Mobs = "Mob", Bosses = "Boss" }
        --// Values already shown elsewhere (the mob's name, its drops).
        local HIDDEN_KEYS = { Entity = true, MaxDrops = true }
        --// Groups for names the words below would miss or misplace.
        local EXACT_GROUPS = { Col = "Rewards", LVL = "Core" }
        --// A stat whose name holds one of these words is grouped under it.
        --// Checked in order; the first match wins.
        local GROUP_WORDS = {
            { Group = "Rewards", Words = { "xp", "exp", "gold", "coin", "money", "cash", "drop", "loot", "reward", "chance" } },
            { Group = "Combat", Words = { "damage", "dmg", "attack", "atk", "range", "aggro", "cooldown", "crit", "defense", "armor", "hit", "power", "strength" } },
        }
        --// Stats that make a mob dangerous, for the threat meter.
        local THREAT_WORDS = { "damage", "dmg", "attack", "atk", "power", "strength" }
        --// Luck adds Luck / LUCK_DIVISOR percent to every drop roll, Luck
        --// capped at CoreCommons.PHYSICAL_STAT_MAX (this when unreadable).
        local LUCK_DIVISOR = 100
        local DEFAULT_LUCK_CAP = 500
        --// Odds like 100 / 3 * 3 land a hair under the integer.
        local ROUNDING_EPSILON = 1e-9
        --// Guard against a broken roll count.
        local MAX_ROUNDS = 1000
        --// A StatusEffect holding one of these means no effect.
        local NO_STATUS = { none = true, ["nil"] = true, ["0"] = true }
        --// Seconds before a server that never answers counts as failed, so
        --// RELOAD can ask again.
        local LOAD_TIMEOUT = 20
        --// Saved drops, shared by every profile and PlaceId.
        local DROPS_FILE = Context.PROFILE_FOLDER .. "/MobDrops.json"
        local DROPS_FILE_VERSION = 1
        --// Name:Rarity:Rounds, numbers to 10 significant digits.
        local DROPS_SIGNATURE_FORMAT = "%s:%.10g:%.10g"
        --// Seconds between background scans of workspace.Mobs for drops.
        local LIVE_SCAN_INTERVAL = 5
        --// Config.AwardType value whose AwardParam attribute is the share of
        --// the mob's health (percent) a player must deal to be rewarded.
        local AWARD_TYPE_HEALTH_PERCENT = "HealthPercent"
        local AWARD_PARAM_ATTRIBUTE = "AwardParam"
        local AWARD_PARAM_KEY = "Config.AwardParam"
        --// No THREAT_WORDS in it, so it does not count toward the threat meter.
        local AWARD_PARAM_LABEL = "AWARD MIN HEALTH %"

        local Dictionary = {
            Name = "MobDictionary",
            KIND_BY_FOLDER = KIND_BY_FOLDER,
            S = {
                Entries = {},
                ByName = {},
                --// Stat key -> { Max, Sorted (descending values) }, over
                --// every mob; KindScales[Kind] is the same per kind.
                Scales = {},
                KindScales = {},
                Loading = false,
                Loaded = false,
                Error = nil,
                --// Called after every load, whether it worked or not.
                OnLoaded = nil,
                --// Entity name -> mobs alive in workspace.Mobs.
                Live = {},
                --// Entity name -> drops read from a live one (ReadDrops) or
                --// loaded from DROPS_FILE.
                Drops = {},
                --// Entity name -> AwardParam (percent of health to deal to
                --// be rewarded), read from a live one or DROPS_FILE.
                AwardParams = {},
                --// Entity name -> DropsSignature of what DROPS_FILE holds.
                SavedSignatures = {},
                --// Entity names whose live drops were read this run; each is
                --// read once (to catch a game update), then trusted.
                CheckedLive = {},
                --// A recorded change is not in DROPS_FILE yet (the write
                --// failed); tried again on every scan.
                SavePending = false,
                LuckCap = nil,
                LuckCapRequested = false,
                --// Bumped by every load; a stale or timed-out answer is dropped.
                LoadToken = 0,
            },
        }

        local S = Dictionary.S

        local function HasWord(Text, Words)
            local Lower = string.lower(Text)

            for _, Word in ipairs(Words) do
                if string.find(Lower, Word, 1, true) then
                    return true
                end
            end

            return false
        end

        local function GetGroup(Name)
            if EXACT_GROUPS[Name] then
                return EXACT_GROUPS[Name]
            end

            for _, Rule in ipairs(GROUP_WORDS) do
                if HasWord(Name, Rule.Words) then
                    return Rule.Group
                end
            end

            return "Other"
        end

        function Dictionary.IsThreatStat(Stat)
            return Stat.Key == "Humanoid.MaxHealth" or HasWord(Stat.Label, THREAT_WORDS)
        end

        --// "AttackRange" -> "ATTACK RANGE".
        function Dictionary.Prettify(Name)
            local Spaced = string.gsub(Name, "(%l)(%u)", "%1 %2")
            Spaced = string.gsub(Spaced, "_", " ")
            return string.upper(Spaced)
        end

        --// The server sends each value as { Value = x }; anything else is
        --// passed through as it is.
        local function Unwrap(Raw)
            if type(Raw) == "table" then
                return Raw.Value
            end

            return Raw
        end

        local function AddStat(Stats, Key, Name, Value, Group)
            if Value == nil or HIDDEN_KEYS[Name] then
                return
            end

            table.insert(Stats, {
                Key = Key,
                Label = Dictionary.Prettify(Name),
                Value = Value,
                Group = Group or GetGroup(Name),
                Numeric = type(Value) == "number",
            })
        end

        local function ReadStatus(Raw)
            if type(Raw) ~= "table" then
                return nil
            end

            --// Most mobs carry an empty StatusEffect: they have none.
            local Effect = Raw.Value

            if Effect == nil or Effect == false or Effect == "" or NO_STATUS[string.lower(tostring(Effect))] then
                return nil
            end

            local Status = { Name = tostring(Effect), Props = {} }

            for Name, Child in pairs(Raw) do
                if Name ~= "Value" then
                    table.insert(Status.Props, { Label = Dictionary.Prettify(Name), Value = Unwrap(Child) })
                end
            end

            table.sort(Status.Props, function(A, B)
                return A.Label < B.Label
            end)

            return Status
        end

        local function ReadEntry(Name, Raw)
            local Entry = {
                Name = Name,
                Kind = KIND_BY_FOLDER[Raw.Value] or tostring(Raw.Value or "Mob"),
                Stats = {},
                Status = nil,
            }

            local Humanoid = Raw.Humanoid

            if type(Humanoid) == "table" then
                AddStat(Entry.Stats, "Humanoid.MaxHealth", "Health", tonumber(Humanoid.MaxHealth), "Core")
                AddStat(Entry.Stats, "Humanoid.WalkSpeed", "WalkSpeed", tonumber(Humanoid.WalkSpeed), "Core")
            end

            for Key, Child in pairs(Raw) do
                if Key == "Config" and type(Child) == "table" then
                    for ConfigKey, ConfigChild in pairs(Child) do
                        if ConfigKey == "StatusEffect" then
                            Entry.Status = ReadStatus(ConfigChild)
                        else
                            AddStat(Entry.Stats, "Config." .. ConfigKey, ConfigKey, Unwrap(ConfigChild))
                        end
                    end
                elseif Key ~= "Value" and Key ~= "Humanoid" then
                    AddStat(Entry.Stats, "Value." .. Key, Key, Unwrap(Child))
                end
            end

            --// Health and speed first, then by name.
            table.sort(Entry.Stats, function(A, B)
                if (A.Group == "Core") ~= (B.Group == "Core") then
                    return A.Group == "Core"
                end

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

        local function CollectScales(Entries)
            local Values = {}

            for _, Entry in ipairs(Entries) do
                for _, Stat in ipairs(Entry.Stats) do
                    if Stat.Numeric then
                        Values[Stat.Key] = Values[Stat.Key] or {}
                        table.insert(Values[Stat.Key], Stat.Value)
                    end
                end
            end

            local Scales = {}

            for Key, List in pairs(Values) do
                table.sort(List, function(A, B)
                    return A > B
                end)

                Scales[Key] = { Max = List[1], Sorted = List }
            end

            return Scales
        end

        --// One scale over every mob, and one per kind, so a mob's bars are
        --// measured against other mobs and a boss's against other bosses.
        local function BuildScales()
            local ByKind = {}

            for _, Entry in ipairs(S.Entries) do
                ByKind[Entry.Kind] = ByKind[Entry.Kind] or {}
                table.insert(ByKind[Entry.Kind], Entry)
            end

            S.Scales = CollectScales(S.Entries)
            S.KindScales = {}

            for Kind, Entries in pairs(ByKind) do
                S.KindScales[Kind] = CollectScales(Entries)
            end
        end

        local function FindScale(Stat, Kind)
            if not Stat.Numeric then
                return nil
            end

            if Kind then
                local Scales = S.KindScales[Kind]
                return Scales and Scales[Stat.Key]
            end

            return S.Scales[Stat.Key]
        end

        --// Fraction of the strongest value (0..1) and the rank (1 = highest)
        --// among the mobs of Kind that have this stat, or among every mob
        --// when Kind is nil.
        function Dictionary.GetScale(Stat, Kind)
            local Scale = FindScale(Stat, Kind)

            if not Scale then
                return 0, nil, 0
            end

            local Fraction = Scale.Max > 0 and math.clamp(Stat.Value / Scale.Max, 0, 1) or 0
            local Rank = table.find(Scale.Sorted, Stat.Value)
            return Fraction, Rank, #Scale.Sorted
        end

        --// 0..1: the mean of where each threat stat ranks among every mob
        --// (1 = the highest of all). Ranks rather than values, so one huge
        --// boss does not make every other mob look harmless.
        function Dictionary.GetThreat(Entry)
            local Total, Count = 0, 0

            for _, Stat in ipairs(Entry.Stats) do
                if Stat.Numeric and Dictionary.IsThreatStat(Stat) then
                    local _, Rank, Size = Dictionary.GetScale(Stat)

                    if Rank then
                        Total += Size > 1 and (Size - Rank) / (Size - 1) or 1
                        Count += 1
                    end
                end
            end

            return Count > 0 and Total / Count or 0
        end

        --// Adds (or updates) the AwardParam stat of a HealthPercent mob
        --// once its AwardParam is known. True when the entry changed.
        local function ApplyAwardParam(Entry)
            local Param = S.AwardParams[Entry.Name]

            if type(Param) ~= "number" or Dictionary.GetStat(Entry, "Config.AwardType") ~= AWARD_TYPE_HEALTH_PERCENT then
                return false
            end

            for _, Stat in ipairs(Entry.Stats) do
                if Stat.Key == AWARD_PARAM_KEY then
                    if Stat.Value == Param then
                        return false
                    end

                    Stat.Value = Param
                    return true
                end
            end

            table.insert(Entry.Stats, {
                Key = AWARD_PARAM_KEY,
                Label = AWARD_PARAM_LABEL,
                Value = Param,
                Group = "Rewards",
                Numeric = true,
            })

            return true
        end

        local function Apply(Raw)
            local Entries, ByName = {}, {}

            for Name, Data in pairs(Raw) do
                if type(Name) == "string" and type(Data) == "table" then
                    local Entry = ReadEntry(Name, Data)
                    ApplyAwardParam(Entry)
                    table.insert(Entries, Entry)
                    ByName[Name] = Entry
                end
            end

            table.sort(Entries, function(A, B)
                local HealthA = Dictionary.GetStat(A, "Humanoid.MaxHealth") or 0
                local HealthB = Dictionary.GetStat(B, "Humanoid.MaxHealth") or 0

                if HealthA ~= HealthB then
                    return HealthA < HealthB
                end

                return A.Name < B.Name
            end)

            S.Entries = Entries
            S.ByName = ByName
            BuildScales()
        end

        local function Finish(ErrorMessage)
            S.Loading = false
            S.Error = ErrorMessage

            if S.OnLoaded then
                S.OnLoaded()
            end
        end

        --// Asks the server for the dictionary in the background. The server
        --// builds it once and keeps it, so asking again is cheap.
        function Dictionary:Load()
            if S.Loading then
                return
            end

            local Remote = Replicated:FindFirstChild(REMOTE_NAME, true)

            if not Remote or not Remote:IsA("RemoteFunction") then
                Finish("Mob dictionary is not available in this place")
                return
            end

            S.Loading = true
            S.Error = nil
            S.LoadToken += 1

            local Token = S.LoadToken

            --// InvokeServer can wait forever; give up on it after a while.
            task.delay(LOAD_TIMEOUT, function()
                if Context.Lifetime.Alive and S.Loading and S.LoadToken == Token then
                    S.LoadToken += 1
                    Finish("The server did not answer. Press RELOAD to try again.")
                end
            end)

            task.spawn(function()
                local Ok, Result = pcall(Remote.InvokeServer, Remote, REMOTE_ARGUMENT)

                --// Stopped, timed out, or a newer load is running.
                if not Context.Lifetime.Alive or S.LoadToken ~= Token then
                    return
                end

                if not Ok then
                    Finish("Could not read the mob dictionary: " .. tostring(Result))
                    return
                end

                if type(Result) ~= "table" then
                    Finish("The server sent no mob dictionary")
                    return
                end

                Apply(Result)
                S.Loaded = true
                Finish(nil)
            end)
        end

        function Dictionary:GetAll()
            return S.Entries
        end

        function Dictionary:Get(Name)
            return S.ByName[Name]
        end

        ------------------------------------------------------------------------
        --// Drops and luck
        ------------------------------------------------------------------------

        --// A spawned mob is a full clone of its ServerStorage model, so its
        --// Config.MaxDrops can be read here (the dictionary leaves it out).
        --// Each child is one item: Value = how many times it is rolled,
        --// Rarity = 1 in N.
        local function ReadDrops(MaxDrops)
            local Drops = {}

            for _, Item in ipairs(MaxDrops:GetChildren()) do
                local Rarity = Item:FindFirstChild("Rarity")
                local Value = Rarity and Rarity:IsA("ValueBase") and tonumber(Rarity.Value)

                if Value and Value > 0 and Item.Name ~= "" then
                    table.insert(Drops, {
                        Name = Item.Name,
                        Rarity = Value,
                        Rounds = Item:IsA("ValueBase") and tonumber(Item.Value) or 0,
                    })
                end
            end

            table.sort(Drops, function(A, B)
                if A.Rarity ~= B.Rarity then
                    return A.Rarity < B.Rarity
                end

                return A.Name < B.Name
            end)

            return Drops
        end

        --// One string per drop list, to tell whether two lists are the same.
        --// Numbers are cut by DROPS_SIGNATURE_FORMAT so a value that lost a
        --// last digit going through JSON still matches the live one.
        local function DropsSignature(Drops)
            local Parts = {}

            for _, Drop in ipairs(Drops) do
                table.insert(Parts, string.format(DROPS_SIGNATURE_FORMAT, Drop.Name, Drop.Rarity, Drop.Rounds))
            end

            return table.concat(Parts, "|")
        end

        --// A saved drop list, or nil when it is not one.
        local function NormalizeSavedDrops(Raw)
            if type(Raw) ~= "table" then
                return nil
            end

            local Drops = {}

            for _, Drop in ipairs(Raw) do
                local Rarity = type(Drop) == "table" and tonumber(Drop.Rarity)

                if Rarity and Rarity > 0 and type(Drop.Name) == "string" and Drop.Name ~= "" then
                    table.insert(Drops, {
                        Name = Drop.Name,
                        Rarity = Rarity,
                        Rounds = tonumber(Drop.Rounds) or 0,
                    })
                end
            end

            return Drops
        end

        --// Fills S.Drops from DROPS_FILE before any mob is seen.
        local function LoadSavedDrops()
            if not AICProfile.CanUseFileStorage() then
                return
            end

            local CheckSuccess, Exists = pcall(isfile, DROPS_FILE)

            if not CheckSuccess or not Exists then
                return
            end

            local Success, Decoded = pcall(function()
                return HttpService:JSONDecode(readfile(DROPS_FILE))
            end)

            if not Success or type(Decoded) ~= "table" or type(Decoded.Mobs) ~= "table" then
                warn("AutoFarm mob drops read failed:", Decoded)
                return
            end

            for Name, Raw in pairs(Decoded.Mobs) do
                local Drops = type(Name) == "string" and NormalizeSavedDrops(Raw)

                if Drops then
                    S.Drops[Name] = Drops
                    S.SavedSignatures[Name] = DropsSignature(Drops)
                end
            end

            if type(Decoded.AwardParams) == "table" then
                for Name, Param in pairs(Decoded.AwardParams) do
                    if type(Name) == "string" and tonumber(Param) then
                        S.AwardParams[Name] = tonumber(Param)
                    end
                end
            end
        end

        --// Writes every non-empty drop list (an empty one may just be a mob
        --// that had not replicated, so it is not kept between runs).
        local function WriteSavedDrops()
            if not AICProfile.CanUseFileStorage() then
                return false
            end

            AICProfile.EnsureProfileFolder()

            local Mobs = {}

            for Name, Drops in pairs(S.Drops) do
                if #Drops > 0 then
                    Mobs[Name] = Drops
                end
            end

            local Success, Raw = pcall(function()
                return HttpService:JSONEncode({ Version = DROPS_FILE_VERSION, Mobs = Mobs, AwardParams = S.AwardParams })
            end)

            if not Success then
                warn("AutoFarm mob drops encode failed:", Raw)
                return false
            end

            local WriteSuccess, WriteError = pcall(writefile, DROPS_FILE, Raw)

            if not WriteSuccess then
                warn("AutoFarm mob drops save failed:", WriteError)
                return false
            end

            for Name, Drops in pairs(Mobs) do
                S.SavedSignatures[Name] = DropsSignature(Drops)
            end

            return true
        end

        --// Reads a live mob's drops (once per run once they are non-empty)
        --// into S.Drops. Returns whether S.Drops changed, and whether that
        --// change needs saving: not saved yet, or different from the save.
        local function RecordLiveDrops(Name, Config)
            if S.CheckedLive[Name] then
                return false, false
            end

            local MaxDrops = Config:FindFirstChild("MaxDrops")
            local Drops = MaxDrops and ReadDrops(MaxDrops) or {}

            --// No MaxDrops: it drops nothing. An empty read is read again
            --// from the next one, in case this one had not finished
            --// replicating, and never replaces a known list.
            if #Drops == 0 then
                if S.Drops[Name] then
                    return false, false
                end

                S.Drops[Name] = Drops
                return true, false
            end

            S.CheckedLive[Name] = true

            if S.SavedSignatures[Name] == DropsSignature(Drops) then
                return false, false
            end

            S.Drops[Name] = Drops
            return true, true
        end

        --// A live HealthPercent mob's AwardParam into S.AwardParams and its
        --// entry. Returns whether it changed, and so needs saving.
        local function RecordLiveAwardParam(Name, Config)
            local AwardType = Config:FindFirstChild("AwardType")

            if not AwardType or not AwardType:IsA("StringValue") or AwardType.Value ~= AWARD_TYPE_HEALTH_PERCENT then
                return false
            end

            local Param = tonumber(AwardType:GetAttribute(AWARD_PARAM_ATTRIBUTE))

            if not Param or S.AwardParams[Name] == Param then
                return false
            end

            S.AwardParams[Name] = Param

            local Entry = S.ByName[Name]

            if Entry and ApplyAwardParam(Entry) then
                BuildScales()
            end

            return true
        end

        --// Mobs alive in workspace.Mobs by Config.Entity (the dictionary
        --// name; the model itself is renamed "Mob<tick>"). The first one of
        --// each kind seen records its drops in S.Drops, and DROPS_FILE is
        --// rewritten only when that added or changed a saved mob.
        --// True when S.Drops changed.
        function Dictionary:ScanLive()
            local Counts = {}
            local NewDrops = false
            local Folder = workspace:FindFirstChild("Mobs")

            for _, Mob in (Folder and Folder:GetChildren() or {}) do
                local Config = Mob:IsA("Model") and Mob:FindFirstChild("Config")
                local Entity = Config and Config:FindFirstChild("Entity")

                if not Entity or not Entity:IsA("StringValue") or Entity.Value == "" then
                    continue
                end

                local Name = Entity.Value
                Counts[Name] = (Counts[Name] or 0) + 1

                local Changed, NeedsSave = RecordLiveDrops(Name, Config)
                local NewAwardParam = RecordLiveAwardParam(Name, Config)
                NewDrops = NewDrops or Changed or NewAwardParam
                S.SavePending = S.SavePending or NeedsSave or NewAwardParam
            end

            S.Live = Counts

            if S.SavePending and WriteSavedDrops() then
                S.SavePending = false
            end

            return NewDrops
        end

        function Dictionary:GetLive(Name)
            return S.Live[Name] or 0
        end

        --// nil until a live one has been seen (this run or an earlier one).
        function Dictionary:GetDrops(Name)
            return S.Drops[Name]
        end

        --// Percent of health to deal for a reward, for a HealthPercent mob
        --// once a live one has been seen; nil otherwise.
        function Dictionary:GetAwardParam(Name)
            return S.AwardParams[Name]
        end

        --// Most luck that counts (CoreCommons.PHYSICAL_STAT_MAX). Required in
        --// the background once, since a require can wait; DEFAULT_LUCK_CAP
        --// until then or when it cannot be read.
        local function GetLuckCap()
            if S.LuckCap then
                return S.LuckCap
            end

            if not S.LuckCapRequested then
                S.LuckCapRequested = true

                task.spawn(function()
                    local Commons = Replicated:FindFirstChild("CoreCommons")
                    local Ok, Module = false, nil

                    if Commons and Commons:IsA("ModuleScript") then
                        Ok, Module = pcall(require, Commons)
                    end

                    local Cap = Ok and type(Module) == "table" and tonumber(Module.PHYSICAL_STAT_MAX)
                    S.LuckCap = Cap and Cap > 0 and Cap or DEFAULT_LUCK_CAP
                end)
            end

            return S.LuckCap or DEFAULT_LUCK_CAP
        end

        --// The player's Luck stat, the cap, and the percent it adds to every
        --// drop roll (Luck / 100, Luck capped).
        function Dictionary.GetLuck()
            local Stats = Context.Player:FindFirstChild("PlayerStats")
            local Luck = Stats and Stats:FindFirstChild("Luck")
            local Value = Luck and Luck:IsA("ValueBase") and tonumber(Luck.Value) or 0
            local Cap = GetLuckCap()
            return Value, Cap, math.clamp(Value, 0, Cap) / LUCK_DIVISOR
        end

        --// The server rolls 1..100 and drops when the roll <= Odds + Luck.
        local function RollChance(Odds)
            return math.clamp(math.floor(Odds + ROUNDING_EPSILON), 0, 100) / 100
        end

        --// Odds of one item from one kill, as the server rolls it: Rounds
        --// rolls of 100 / Rarity (+ Luck%); until the item has dropped, roll
        --// N's odds are multiplied by N. Returns the chance of at least one
        --// (0..1) and the expected count.
        function Dictionary.GetDropOdds(Drop, LuckPercent)
            local Odds = 100 / Drop.Rarity
            local Rounds = math.min(Drop.Rounds, MAX_ROUNDS)
            local Missed, Expected = 1, 0
            local Again = RollChance(Odds + LuckPercent)

            for Round = 1, Rounds do
                local First = RollChance(Odds * Round + LuckPercent)
                Expected += Missed * First + (1 - Missed) * Again
                Missed *= 1 - First
            end

            return 1 - Missed, Expected
        end

        LoadSavedDrops()

        --// Mobs that come and go while the window is closed are recorded too.
        task.spawn(function()
            while Context.Lifetime.Alive do
                local Ok, ScanError = pcall(Dictionary.ScanLive, Dictionary)

                if not Ok then
                    warn("AutoFarm mob drops scan failed:", ScanError)
                end

                task.wait(LIVE_SCAN_INTERVAL)
            end
        end)

        return Dictionary
    end,
}
