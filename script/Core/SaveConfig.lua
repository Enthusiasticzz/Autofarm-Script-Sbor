-- SaveConfig is the single list of everything a profile saves.
--
-- Adding a saved feature toggle is one line in Features; adding a saved
-- setting is one line in Settings. Runtime builds its feature state and
-- CONFIG defaults from here, ProfileManager saves, loads, exports and
-- resets from here, and Components refreshes every toggle from here.
return {
    Name = "SaveConfig",
    Dependencies = {},

    Start = function()
        local SaveConfig = {}

        --// Feature toggles, saved in the profile's FEATURES table.
        --//   Name    : key in Context.Feature and in the save file
        --//   Default : value before any profile is loaded
        --//   Key     : short key in exported profile text. Must never change
        --//             or be reused, or old exports load into the wrong toggle.
        --//             Toggles without one are saved but not exported.
        --//   Global  : stored in ProfileManager's global file, shared by every
        --//             profile and PlaceId; profiles neither save, load nor
        --//             export it. Its Key stays reserved.
        SaveConfig.Features = {
            { Name = "AutoFarm",          Default = true,  Key = "a" },
            { Name = "AutoBlock",         Default = true,  Key = "b" },
            { Name = "SafeCombat",        Default = true,  Key = "c" },
            { Name = "AutoFind",          Default = false, Key = "d" },
            { Name = "IgnoreFarmZone",    Default = false, Key = "e" },
            { Name = "AutoPatrol",        Default = false, Key = "f" },
            { Name = "ReturnToFarmZone",  Default = true,  Key = "g" },
            { Name = "AutoSkill",         Default = true,  Key = "h" },
            --// Shown as "Refill Booster": resets the character when a boost
            --// runs out so the game refills it. Owned by AutoRefill.
            { Name = "ResetOnBoostOut",   Default = true,  Key = "i" },
            { Name = "ResetStats",        Default = true,  Key = "j" },
            { Name = "DebugVisualizer",   Default = true,  Key = "k" },
            { Name = "PartySystem",       Default = false, Key = "l" },
            { Name = "WaypointLoop",      Default = false, Key = "m" },
            --// Boss Route (BossNavigator): walks its own list of boss stops,
            --// fights at each and resets on its own timers. Its stops live on
            --// the place config (BOSS_ROUTE), not in WAYPOINTS.
            { Name = "BossRoute",         Default = false, Key = "z" },
            { Name = "SafeBoosterReset",  Default = false, Key = "n" },
            { Name = "AutoBlockConfirm",  Default = false, Key = "o" },
            { Name = "AutoMining",        Default = false, Key = "p" },
            { Name = "AutoSmithing",      Default = false, Key = "q" },
            --// Server tab (ServerUI): leave when a danger group member is here,
            --// and notify about players off the whitelist.
            { Name = "DangerGroupHop",    Default = false, Key = "r", Global = true },
            { Name = "JoinAlerts",        Default = false, Key = "s" },
            --// Leaves for another server when one player keeps joining
            --// yours, and stops Auto Farm only when it cannot leave
            --// (FollowerGuard). Its sightings and hold live in the shared
            --// FollowerLog.json, so it watches across profiles and places.
            { Name = "FollowerGuard",     Default = true,  Key = "y", Global = true },
            --// Pull a pack of mobs together, then use the skill (MobGather).
            { Name = "MobGather",         Default = false, Key = "t" },
            --// Click through the title screen (AutoStartGame). Shared by every
            --// profile: it runs before the farm's profile matters.
            { Name = "AutoStartGame",     Default = false, Key = "u", Global = true },
            --// Presses No on the confirm notice the game puts up when the
            --// character dies (DeathPrompt). Shared by every profile, like the
            --// other Utility tab controls, so every export key stays free for
            --// a toggle that belongs to a profile.
            { Name = "DeathPrompt",       Default = true, Global = true },
            --// Block Whitelist players never make Auto Block hop (even when
            --// blocked) or Leave On Danger Group leave. Owned by AutoBlock;
            --// shared by every profile, like the Block Whitelist.
            { Name = "WhitelistSkipsSafety", Default = true, Key = "v", Global = true },
            --// Auto Block's other half: instead of blocking an intruder, leave
            --// the server once the Block Delay has run out. Shared by every
            --// profile, like the whitelist that decides who counts.
            { Name = "AutoBlockLeaveOnly", Default = false, Global = true },
            --// A leave the script starts on its own (Leave Instead Of Block,
            --// the Follower Guard kick, the Danger Group hop) pauses a random
            --// 2-4 s first, so the client never drops the server the same
            --// instant a stranger appeared. Owned by AutoBlock; shared by
            --// every profile, like the toggles around it.
            { Name = "RandomLeaveDelay", Default = true, Global = true },

            --// Turns off shadows, effects and particles for frames (FpsBoost).
            --// Shared by every profile: it is about the machine, not the farm.
            { Name = "FpsBoost",          Default = false, Key = "w", Global = true },
            --// Jump over something in the way while chasing a target (the
            --// DoCombatJump* helpers in CombatUtils). Off, the character keeps
            --// its feet on the ground for the whole fight; the waypoint route,
            --// patrol, mining and smithing jumps are their own.
            { Name = "JumpWhileFighting", Default = false, Key = "x" },
            { Name = "DebugWaypoints",    Default = true },
            { Name = "DebugFarmZones",    Default = true },
            { Name = "DebugDeadzones",    Default = true },
            { Name = "DebugRadiusLabels", Default = true },
            { Name = "DebugMineZones",    Default = true },
            { Name = "DebugOres",         Default = true },
            { Name = "DebugSmithing",     Default = true },
        }

        --// The game holds at most this many of one item, so no mining or
        --// smithing target can be higher.
        SaveConfig.ITEM_MAX_STACK = 500

        --// Normalizers turn whatever a save file holds into a valid value.
        --// They receive nil for a missing entry and must return the default.

        --// Numeric IDs (UserIds, group IDs) as text, duplicates dropped.
        local function NormalizeIdList(Value)
            local Result = {}

            for _, Entry in ipairs(type(Value) == "table" and Value or {}) do
                local Text = tostring(Entry or ""):gsub("%s+", "")

                if Text:match("^%d+$") and not table.find(Result, Text) then
                    table.insert(Result, Text)
                end
            end

            return Result
        end

        --// Names as the game spells them: text entries only, trimmed, blanks
        --// and duplicates dropped, order kept.
        local function NormalizeNameList(Value)
            local Result = {}

            for _, Entry in ipairs(type(Value) == "table" and Value or {}) do
                local Text = type(Entry) == "string" and Entry:gsub("^%s*(.-)%s*$", "%1") or ""

                if Text ~= "" and not table.find(Result, Text) then
                    table.insert(Result, Text)
                end
            end

            return Result
        end

        --// { Name, UserId } of the party Leader, or {} when none is set.
        local function NormalizePartyLeader(Value)
            if type(Value) ~= "table" or type(Value.Name) ~= "string" or Value.Name == "" then
                return {}
            end

            return {
                Name = Value.Name,
                UserId = tonumber(Value.UserId),
            }
        end

        --// A normalizer for { { Name, <CountKey> }, ... } in priority order,
        --// each count a whole number from 0 to ITEM_MAX_STACK (Fallback when
        --// missing). Duplicate names keep the first entry.
        local function NormalizeCountList(CountKey, Fallback)
            return function(Value)
                local Result = {}
                local Seen = {}

                for _, Entry in ipairs(type(Value) == "table" and Value or {}) do
                    local Name = type(Entry) == "table" and Entry.Name

                    if type(Name) == "string" and Name ~= "" and not Seen[Name] then
                        Seen[Name] = true
                        table.insert(Result, {
                            Name = Name,
                            [CountKey] = math.clamp(
                                math.floor(tonumber(Entry[CountKey]) or Fallback),
                                0,
                                SaveConfig.ITEM_MAX_STACK
                            ),
                        })
                    end
                end

                return Result
            end
        end

        --// Settings, saved in the profile's SETTINGS table.
        --//   Key       : key in CONFIG (or the place config) and in the save
        --//   Default   : value before any profile is loaded
        --//   Min / Max : clamp for numbers
        --//   Options   : allowed values for a choice; anything else -> Default
        --//   Normalize : custom cleanup for structured values
        --//   Scope     : "Place" lives on the place config instead of CONFIG,
        --//               and defaults to that place's preset
        --//   Global    : stored outside profiles; a profile copy only seeds it
        SaveConfig.Settings = {
            { Key = "REACH_DISTANCE", Scope = "Place", Default = 5 },
            { Key = "AUTOBLOCK", Scope = "Place", Default = false },
            --// Boss Route loops back to its first stop after the last one;
            --// off, it plays the route once and switches itself off.
            { Key = "BOSS_ROUTE_LOOP", Default = true },
            --// Boss Route takes its Reset (s) before every reset, including one
            --// the EXP check would have fired at once; off, a reset that costs
            --// no EXP still happens immediately.
            { Key = "BOSS_RESET_ALWAYS_WAIT", Default = false },

            --// Retreat below this share of health (0 = never), and drink at or below the
            --// heal share.
            { Key = "RETREAT_HEALTH_PERCENT", Default = 40, Min = 0, Max = 80 },
            { Key = "AUTO_HEAL_HEALTH_PERCENT", Default = 65, Min = 30, Max = 80 },
            { Key = "SAFE_ENEMY_RANGE", Default = 4, Min = 0, Max = 30 },
            --// With Safe Combat off: how far from the target it fights
            --// (studs). 4 is just clear of its body, 12 the attack reach.
            { Key = "CLOSE_COMBAT_RANGE", Default = 6, Min = 4, Max = 12 },

            --// Tie break between mobs of equal priority.
            --// "Disabled" keeps the original nearest-first behaviour.
            { Key = "TARGET_HP_MODE", Default = "Disabled", Options = { "Disabled", "Highest HP", "Lowest HP" } },

            --// Below this share of its health a target is finished off instead
            --// of retreated from. An enemy skill still overrides it.
            { Key = "EXECUTE_CHARGE_HP_PERCENT", Default = 0, Min = 0, Max = 90 },

            --// Gather Mobs: a pack needs at least GATHER_MIN_MOBS within
            --// GATHER_RADIUS of each other; at most GATHER_MAX_MOBS are pulled.
            { Key = "GATHER_MIN_MOBS", Default = 3, Min = 2, Max = 8 },
            { Key = "GATHER_MAX_MOBS", Default = 5, Min = 2, Max = 10 },
            { Key = "GATHER_RADIUS", Default = 40, Min = 15, Max = 80 },

            --// Route hole jump (waypoint route and Waypoint Loop): the ground
            --// is sampled every ROUTE_HOLE_SAMPLE_STEP studs along the
            --// character's facing, up to ROUTE_HOLE_PROBE_DISTANCE ahead;
            --// missing ground, water or a drop of ROUTE_HOLE_MIN_DEPTH or
            --// more is a hole and the character jumps. Non-whole bounds
            --// give the sliders two decimals.
            { Key = "ROUTE_HOLE_PROBE_DISTANCE", Default = 2, Min = 0.5, Max = 6 },
            { Key = "ROUTE_HOLE_SAMPLE_STEP", Default = 0.5, Min = 0.25, Max = 2 },
            { Key = "ROUTE_HOLE_MIN_DEPTH", Default = 1, Min = 0.5, Max = 10 },

            --// Seconds Auto Block waits after first seeing a non-whitelisted
            --// player before blocking them and leaving. 0 acts at once.
            { Key = "AUTO_BLOCK_DELAY", Default = 0, Min = 0, Max = 120 },

            --// Party System Leader, followed between servers with the game's
            --// "tp friend <Name>" chat command. Empty table = no Leader.
            { Key = "PARTY_LEADER", Default = {}, Normalize = NormalizePartyLeader },

            --// Boosters Refill Booster resets the character for, by their
            --// PlayerStats value name - that is what the toggles in the Booster
            --// Reset section write. The game owns those names and the section
            --// scans for them, so anything it finds gets a toggle; this default
            --// is the two the script knows, and keeps an existing profile
            --// resetting for exactly what it did before.
            { Key = "RESET_BOOSTERS", Default = { "Boost", "BoostDrops" }, Normalize = NormalizeNameList },

            --// Ores Auto Mining collects, highest priority first, each mined
            --// until the inventory holds Target of it.
            { Key = "MINE_ORES", Default = {
                { Name = "Iron Ore", Target = 500 },
                { Name = "Copper Ore", Target = 500 },
            }, Normalize = NormalizeCountList("Target", SaveConfig.ITEM_MAX_STACK) },

            --// Recipes Auto Smithing crafts, highest priority first, each
            --// until the inventory holds Target of what it makes.
            { Key = "SMITH_RECIPES", Default = {
                { Name = "Iron Ingot", Target = 500 },
                { Name = "Copper Ingot", Target = 500 },
            }, Normalize = NormalizeCountList("Target", SaveConfig.ITEM_MAX_STACK) },

            --// Materials Auto Smithing never uses below Keep.
            { Key = "SMITH_RESERVES", Default = {}, Normalize = NormalizeCountList("Keep", 0) },

            --// ESP (Features/Esp.lua). Which kinds are on, how each one is
            --// drawn (Outline, Box or None), whether it carries info text,
            --// the three colours and the box controls. Saved per profile so
            --// an ESP setup survives re-executing the script.
            { Key = "ESP_PLAYER_ENABLED", Default = false },
            { Key = "ESP_MOB_ENABLED", Default = false },
            { Key = "ESP_WEAPON_ENABLED", Default = false },
            { Key = "ESP_PLAYER_STYLE", Default = "Outline", Options = { "Outline", "Box", "None" } },
            { Key = "ESP_MOB_STYLE", Default = "Outline", Options = { "Outline", "Box", "None" } },
            { Key = "ESP_WEAPON_STYLE", Default = "Outline", Options = { "Outline", "Box", "None" } },
            { Key = "ESP_PLAYER_TEXT", Default = false },
            { Key = "ESP_MOB_TEXT", Default = false },
            { Key = "ESP_WEAPON_TEXT", Default = false },
            --// Colours as RRGGBB, by kind, so a colour picked in the menu is
            --// restored with the rest of the settings.
            { Key = "ESP_COLORS", Default = { Player = "50C8FF", Mob = "FF5A5A", Weapon = "FFC83C" }, Normalize = function(Value)
                local Defaults = { Player = "50C8FF", Mob = "FF5A5A", Weapon = "FFC83C" }
                local Colors = {}

                for Kind, Fallback in pairs(Defaults) do
                    local Hex = type(Value) == "table" and Value[Kind] or nil

                    if type(Hex) == "string" then
                        local Clean = string.upper((string.gsub(Hex, "#", "")))
                        Colors[Kind] = string.match(Clean, "^%x%x%x%x%x%x$") and Clean or Fallback
                    else
                        Colors[Kind] = Fallback
                    end
                end

                return Colors
            end },
            { Key = "ESP_THICKNESS", Default = 1.5, Min = 1, Max = 6 },
            { Key = "ESP_AUTO_THICKNESS", Default = true },
            { Key = "ESP_RANGE", Default = 900, Min = 100, Max = 2000 },
            --// Box look: a closed box or corner brackets.
            { Key = "ESP_BOX_STYLE", Default = "Full", Options = { "Full", "Corners" } },

        }

        --// Settings kept in ProfileManager's global file instead of a
        --// profile, shared by every profile and PlaceId. Same fields as
        --// Settings, without Scope.
        SaveConfig.GlobalSettings = {
            --// Boss path markings are a display preference shared by profiles.
            { Key = "BOSS_PATH_VISIBLE", Default = true },
            { Key = "BOSS_PATH_COLOR", Default = "4F7CF5", Normalize = function(Value)
                if type(Value) == "string" and Value:match("^%x%x%x%x%x%x$") then
                    return string.upper(Value)
                end
                return "4F7CF5"
            end },
            --// Enum.Font name the UI uses, picked in Configuration; "" keeps
            --// the built-in fonts.
            { Key = "UI_FONT", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value or ""
            end },

            --// UI text scale, picked in Configuration (Utils clamps it).
            { Key = "UI_TEXT_SCALE", Default = 1, Normalize = function(Value)
                return type(Value) == "number" and Value == Value and Value or 1
            end },

            --// Theme colours changed in Configuration, as Theme key -> hex
            --// ("RRGGBB"); keys left out keep the built-in colour.
            { Key = "UI_THEME", Default = {}, Normalize = function(Value)
                local Theme = {}

                if type(Value) == "table" then
                    for Key, Hex in pairs(Value) do
                        if type(Key) == "string" and type(Hex) == "string" and string.match(Hex, "^#?%x%x%x%x%x%x$") then
                            Theme[Key] = Hex
                        end
                    end
                end

                return Theme
            end },

            --// The rest of the Settings tab: the window's own options, in the
            --// shape Utils keeps them. Shared by every profile and PlaceId,
            --// like the font, the theme and the text scale above.
            --// The key that opens and closes the menu, by Enum.KeyCode name.
            { Key = "UI_MENU_KEY", Default = "Insert", Normalize = function(Value)
                local Name = type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
                --// Indexing Enum with a name it does not have throws.
                local Ok, Code = pcall(function() return Enum.KeyCode[Name] end)

                return Ok and Code and Name or "Insert"
            end },
            --// The palette picked in Appearance; its colours land in UI_THEME.
            { Key = "UI_PALETTE", Default = "Default", Options = { "Default", "Navy", "Midnight", "Rose", "Forest", "Light" } },
            { Key = "UI_WINDOW_WIDTH", Default = 760, Min = 500, Max = 1400 },
            { Key = "UI_WINDOW_HEIGHT", Default = 500, Min = 260, Max = 900 },
            { Key = "UI_TAB_ANIMATION", Default = "Fade", Options = { "Fade", "Slide", "None" } },
            { Key = "UI_NOTIFICATIONS", Default = true },
            { Key = "UI_NOTIFICATION_POSITION", Default = "Bottom right", Options = { "Top left", "Top center", "Top right", "Bottom left", "Bottom right" } },
            { Key = "UI_WATERMARK", Default = false },
            { Key = "UI_KEYBIND_LIST", Default = false },
            --// The menu cursor: when it shows, how it is drawn, its size, the
            --// click ripple, and the colour behind its own tick.
            { Key = "UI_CURSOR", Default = { Mode = "Menu open", Style = "Arrow", Size = 100, Effects = true, CustomEnabled = false, Color = "46A0FF" }, Normalize = function(Value)
                local Defaults = { Mode = "Menu open", Style = "Arrow", Size = 100, Effects = true, CustomEnabled = false, Color = "46A0FF" }
                local Source = type(Value) == "table" and Value or {}
                local Color = type(Source.Color) == "string"
                    and string.upper((string.gsub(Source.Color, "#", "")))
                    or ""

                --// A switch that is false is a real answer: `x and false or
                --// default` would quietly turn it back on.
                local function Switch(Key)
                    if type(Source[Key]) == "boolean" then
                        return Source[Key]
                    end

                    return Defaults[Key]
                end

                return {
                    Mode = table.find({ "Menu open", "Always", "Never" }, Source.Mode) and Source.Mode or Defaults.Mode,
                    Style = table.find({ "Arrow", "Dot", "Cross", "Circle" }, Source.Style) and Source.Style or Defaults.Style,
                    Size = math.clamp(math.floor(tonumber(Source.Size) or Defaults.Size), 50, 300),
                    Effects = Switch("Effects"),
                    CustomEnabled = Switch("CustomEnabled"),
                    Color = string.match(Color, "^%x%x%x%x%x%x$") and Color or Defaults.Color,
                }
            end },

            --// UserIds allowed to share the server. Auto Block ignores these.
            --// Shared by every profile and PlaceId.
            { Key = "BLOCK_WHITELIST", Default = {}, Normalize = NormalizeIdList },

            --// Discord webhook reporting (Webhook). The switch, the URL, the
            --// mention sent with it, the duo's name and the report format
            --// are the same on every profile and PlaceId, like the whitelist.
            { Key = "DISCORD_ENABLED", Default = true },
            { Key = "DISCORD_WEBHOOK", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
            end },
            { Key = "DISCORD_PING", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
            end },
            --// The duo's own UserId, mentioned next to the ping above.
            { Key = "DISCORD_DUO_PING", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
            end },
            { Key = "DISCORD_DUO", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
            end },
            --// Blank means the currency the script already tracks for the
            --// current event (AICUI.S.TargetCurrency).
            { Key = "DISCORD_EC_ITEM", Default = "", Normalize = function(Value)
                return type(Value) == "string" and Value:gsub("^%s*(.-)%s*$", "%1") or ""
            end },
            { Key = "DISCORD_FORMAT", Default = "Event Currency", Options = { "Event Currency", "EXP Grind" } },

            --// Group IDs Leave On Danger Group leaves for.
            { Key = "DANGER_GROUP_IDS", Default = { "5928691" }, Normalize = NormalizeIdList },

            --// UserIds Leave On Danger Group stays for. Separate from
            --// BLOCK_WHITELIST.
            { Key = "DANGER_WHITELIST", Default = {}, Normalize = NormalizeIdList },
        }

        local FeatureByName = {}
        for _, Entry in ipairs(SaveConfig.Features) do
            FeatureByName[Entry.Name] = Entry
        end

        local SettingByKey = {}
        for _, Entry in ipairs(SaveConfig.Settings) do
            SettingByKey[Entry.Key] = Entry
        end

        local function DeepCopy(Value)
            if type(Value) ~= "table" then
                return Value
            end

            local Result = {}
            for Key, Item in pairs(Value) do
                Result[Key] = DeepCopy(Item)
            end
            return Result
        end

        function SaveConfig.GetFeature(Name)
            return FeatureByName[Name]
        end

        function SaveConfig.GetSetting(Key)
            return SettingByKey[Key]
        end

        --// Fallback is used instead of Default when given, which is how a
        --// place-scoped setting falls back to that place's preset.
        function SaveConfig.NormalizeSetting(Entry, Value, Fallback)
            local Default = DeepCopy(Fallback ~= nil and Fallback or Entry.Default)

            if Entry.Normalize then
                return Entry.Normalize(Value ~= nil and Value or Default)
            end

            if type(Entry.Default) == "number" then
                local Number = tonumber(Value)

                if Number == nil then
                    Number = tonumber(Default) or Entry.Default
                end

                if Entry.Min and Entry.Max then
                    Number = math.clamp(Number, Entry.Min, Entry.Max)
                end

                return Number
            end

            if type(Entry.Default) == "boolean" then
                if type(Value) == "boolean" then
                    return Value
                end

                return Default == true
            end

            if Entry.Options then
                return table.find(Entry.Options, Value) and Value or Entry.Default
            end

            if Value == nil then
                return Default
            end

            return DeepCopy(Value)
        end

        function SaveConfig.GetSettingDefault(Entry, Fallback)
            return SaveConfig.NormalizeSetting(Entry, nil, Fallback)
        end

        return SaveConfig
    end,
}
