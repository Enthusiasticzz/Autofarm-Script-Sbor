-- ProfileManager owns profile storage, serialization, import/export, and profile state.
return {
    Name = "ProfileManager",
    Dependencies = {"Runtime", "SaveConfig"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local SaveConfig = Context.SaveConfig
        local AICProfile = Context.AICProfile
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local CONFIG = Context.CONFIG
        local Feature = Context.Feature
        local UIRef = Context.UIRef
        local PatrolState = Context.PatrolState
        local HttpService = Context.Services.HttpService
        local BasePlaceConfig = Runtime:GetBasePlaceConfig()
        local PlaceConfig = Runtime:GetPlaceConfig()

        local PROFILE_FOLDER = "AutoFarmProfiles"
        local PROFILE_FILE = PROFILE_FOLDER .. "/" .. tostring(game.PlaceId) .. ".json"
        --// Not keyed by PlaceId: pinned items follow the player between places.
        local PINNED_FILE = PROFILE_FOLDER .. "/PinnedItems.json"
        --// Global toggles and SaveConfig.GlobalSettings, shared by every
        --// profile and PlaceId.
        local GLOBAL_FILE = PROFILE_FOLDER .. "/Global.json"

        --// Short keys for feature toggles in exported/imported profile text,
        --// taken from SaveConfig.Features so a new toggle exports on its own.
        --// Global toggles are not part of a profile, so they are not exported.
        local COMPACT_FEATURE_KEYS = {}

        for _, Entry in ipairs(SaveConfig.Features) do
            if Entry.Key and not Entry.Global then
                COMPACT_FEATURE_KEYS[Entry.Name] = Entry.Key
            end
        end

        AICProfile.S.ActiveProfileName = nil
        AICProfile.S.ProfileSaveQueued = false
        AICProfile.S.ProfileData = nil
        AICProfile.S.SelectedFarmZoneIndex = 1
        AICProfile.S.SelectedDeadzoneIndex = 1
        AICProfile.S.HasGlobalPinnedState = false
        AICProfile.S.PinnedSaveQueued = false
        --// Set when this run ends (the script was run again): no more writes,
        --// so a stopped run cannot save over what the new run loaded.
        AICProfile.S.StorageClosed = false

        function AICProfile.CanUseFileStorage()
            return not AICProfile.S.StorageClosed
                and type(readfile) == "function"
                and type(writefile) == "function"
                and type(isfile) == "function"
        end

        --// Writes any debounced save now, then closes storage. Runs before the
        --// new run reads the files.
        Context.Lifetime.OnEnd(function()
            if AICProfile.S.ProfileSaveQueued then
                AICProfile.S.ProfileSaveQueued = false
                AICProfile.SaveActiveProfile()
            end

            if AICProfile.S.PinnedSaveQueued then
                AICProfile.S.PinnedSaveQueued = false
                AICProfile.WritePinnedState(CONFIG.PINNED_STATE)
            end

            AICProfile.S.StorageClosed = true
        end)

        function AICProfile.EnsureProfileFolder()
            if type(makefolder) ~= "function" then
                return
            end

            pcall(function()
                makefolder(PROFILE_FOLDER)
            end)
        end

        function AICProfile.SerializeConfigValue(Value)
            if typeof(Value) == "Vector3" then
                return AICConfig.EncodeVector3(Value)
            end

            if type(Value) ~= "table" then
                return Value
            end

            local Result = {}
            for Key, Item in pairs(Value) do
                Result[Key] = AICProfile.SerializeConfigValue(Item)
            end
            return Result
        end

        function AICProfile.DeserializeConfigValue(Value)
            if type(Value) ~= "table" then
                return Value
            end

            if Value.X ~= nil and Value.Y ~= nil and Value.Z ~= nil
                and type(Value.X) == "number"
                and type(Value.Y) == "number"
                and type(Value.Z) == "number"
            then
                return AICConfig.DecodeVector3(Value)
            end

            local Result = {}
            for Key, Item in pairs(Value) do
                Result[Key] = AICProfile.DeserializeConfigValue(Item)
            end
            return Result
        end

        function AICProfile.MergeConfig(Base, Override)
            local Result = {}

            for Key, Value in pairs(Base or {}) do
                Result[Key] = AICProfile.DeserializeConfigValue(AICProfile.SerializeConfigValue(Value))
            end

            for Key, Value in pairs(Override or {}) do
                if type(Value) == "table" and type(Result[Key]) == "table" then
                    Result[Key] = AICProfile.MergeConfig(Result[Key], Value)
                else
                    Result[Key] = AICProfile.DeserializeConfigValue(Value)
                end
            end

            return Result
        end

        function AICProfile.BuildDefaultProfile()
            return {
                Name = "",
                PlaceId = game.PlaceId,
                --// Keep the complete place_config/default config inside the profile.
                PLACE_CONFIG = AICProfile.SerializeConfigValue(BasePlaceConfig),
                WAYPOINTS = AICConfig.CloneVectorList(BasePlaceConfig.WAYPOINTS),
                FARM_ZONES = AICConfig.CloneZoneList(BasePlaceConfig.FARM_ZONES),
                DEADZONES = AICConfig.CloneZoneList(BasePlaceConfig.DEADZONES),
                DEFAULT_TARGET_PRIORITY = table.clone(
                    BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                        or CONFIG.TARGET_ENTITY_PRIORITY
                        or {}
                ),
                FEATURES = {},
                SETTINGS = AICProfile.BuildDefaultSettings(),
            }
        end

        --// A new profile starts from defaults, except the pinned panel,
        --// which is global and never reset by a profile.
        function AICProfile.BuildDefaultSettings()
            local Settings = {}

            for _, Entry in ipairs(SaveConfig.Settings) do
                if not Entry.Global then
                    local Fallback = Entry.Scope == "Place" and BasePlaceConfig[Entry.Key] or nil
                    Settings[Entry.Key] = SaveConfig.GetSettingDefault(Entry, Fallback)
                end
            end

            return Settings
        end

        function AICProfile.CaptureSettings(FarmConfig)
            local Settings = {}

            for _, Entry in ipairs(SaveConfig.Settings) do
                local Value

                if Entry.Scope == "Place" then
                    Value = FarmConfig[Entry.Key]
                elseif Entry.Key == "PINNED_STATE" and UIRef.PinPanel then
                    --// Read from the panel, so a drag or a pop out is captured
                    --// without the panel having to announce every change.
                    Value = UIRef.PinPanel:GetState()
                else
                    Value = CONFIG[Entry.Key]
                end

                Settings[Entry.Key] = SaveConfig.NormalizeSetting(Entry, Value)
            end

            return Settings
        end

        --// Place-scoped settings are written onto FarmConfig, the rest onto
        --// CONFIG. A missing entry falls back to the default.
        function AICProfile.ApplySettings(Stored, FarmConfig)
            Stored = type(Stored) == "table" and Stored or {}

            for _, Entry in ipairs(SaveConfig.Settings) do
                local Value = Stored[Entry.Key]

                if Entry.Scope == "Place" then
                    FarmConfig[Entry.Key] = SaveConfig.NormalizeSetting(Entry, Value, FarmConfig[Entry.Key])
                elseif Entry.Global then
                    --// Pinned items are shared across every PlaceId and live
                    --// in their own file. A profile's copy only seeds that
                    --// file once, for saves made before pins were global.
                    if not AICProfile.S.HasGlobalPinnedState and type(Value) == "table" then
                        CONFIG[Entry.Key] = SaveConfig.NormalizeSetting(Entry, Value)
                        AICProfile.WritePinnedState(CONFIG[Entry.Key])
                    end
                else
                    CONFIG[Entry.Key] = SaveConfig.NormalizeSetting(Entry, Value)
                end
            end
        end

        function AICProfile.ResetSettings()
            for _, Entry in ipairs(SaveConfig.Settings) do
                if Entry.Scope ~= "Place" and not Entry.Global then
                    CONFIG[Entry.Key] = SaveConfig.GetSettingDefault(Entry)
                end
            end
        end

        function AICProfile.ReadProfileStore()
            if not AICProfile.CanUseFileStorage() then
                return {
                    Profiles = {},
                    LastUsed = nil,
                }
            end

            AICProfile.EnsureProfileFolder()

            if not isfile(PROFILE_FILE) then
                return {
                    Profiles = {},
                    LastUsed = nil,
                }
            end

            local Success, Raw = pcall(readfile, PROFILE_FILE)

            if not Success or type(Raw) ~= "string" or Raw == "" then
                return {
                    Profiles = {},
                    LastUsed = nil,
                }
            end

            local DecodeSuccess, Data = pcall(function()
                return HttpService:JSONDecode(Raw)
            end)

            if not DecodeSuccess or type(Data) ~= "table" then
                return {
                    Profiles = {},
                    LastUsed = nil,
                }
            end

            Data.Profiles = type(Data.Profiles) == "table" and Data.Profiles or {}
            return Data
        end

        function AICProfile.WriteProfileStore()
            if not AICProfile.CanUseFileStorage() then
                return false
            end

            AICProfile.EnsureProfileFolder()

            local Success, Raw = pcall(function()
                return HttpService:JSONEncode(AICProfile.S.ProfileStore)
            end)

            if not Success then
                warn("AutoFarm profile encode failed:", Raw)
                return false
            end

            local WriteSuccess, WriteError = pcall(writefile, PROFILE_FILE, Raw)

            if not WriteSuccess then
                warn("AutoFarm profile save failed:", WriteError)
                return false
            end

            return true
        end

        --// { Name, UserId } of the party Leader, or {} when none is set.
        function AICProfile.NormalizePartyLeader(Leader)
            return SaveConfig.NormalizeSetting(SaveConfig.GetSetting("PARTY_LEADER"), Leader)
        end

        function AICProfile.NormalizePinnedState(State)
            return SaveConfig.NormalizeSetting(SaveConfig.GetSetting("PINNED_STATE"), State)
        end

        function AICProfile.ReadPinnedState()
            if not AICProfile.CanUseFileStorage() then
                return nil
            end

            local CheckSuccess, Exists = pcall(isfile, PINNED_FILE)

            if not CheckSuccess or not Exists then
                return nil
            end

            local Success, Decoded = pcall(function()
                return HttpService:JSONDecode(readfile(PINNED_FILE))
            end)

            if not Success or type(Decoded) ~= "table" then
                warn("AutoFarm pinned items read failed:", Decoded)
                return nil
            end

            return AICProfile.NormalizePinnedState(Decoded)
        end

        function AICProfile.WritePinnedState(State)
            if not AICProfile.CanUseFileStorage() then
                return false
            end

            AICProfile.EnsureProfileFolder()

            local Success, Raw = pcall(function()
                return HttpService:JSONEncode(AICProfile.NormalizePinnedState(State))
            end)

            if not Success then
                warn("AutoFarm pinned items encode failed:", Raw)
                return false
            end

            local WriteSuccess, WriteError = pcall(writefile, PINNED_FILE, Raw)

            if not WriteSuccess then
                warn("AutoFarm pinned items save failed:", WriteError)
                return false
            end

            AICProfile.S.HasGlobalPinnedState = true
            return true
        end

        --// Dragging the panel reports a change per move, so writes are
        --// debounced the same way profile saves are.
        function AICProfile.QueuePinnedSave()
            if AICProfile.S.PinnedSaveQueued then
                return
            end

            AICProfile.S.PinnedSaveQueued = true

            task.delay(CONFIG.PROFILE_SAVE_DEBOUNCE, function()
                AICProfile.S.PinnedSaveQueued = false
                AICProfile.WritePinnedState(CONFIG.PINNED_STATE)
            end)
        end

        --// { FEATURES = { Name = bool }, SETTINGS = { Key = value } } from
        --// GLOBAL_FILE, or nil when there is none or it cannot be read.
        function AICProfile.ReadGlobalStore()
            if not AICProfile.CanUseFileStorage() then
                return nil
            end

            local CheckSuccess, Exists = pcall(isfile, GLOBAL_FILE)

            if not CheckSuccess or not Exists then
                return nil
            end

            local Success, Decoded = pcall(function()
                return HttpService:JSONDecode(readfile(GLOBAL_FILE))
            end)

            if not Success or type(Decoded) ~= "table" then
                warn("AutoFarm global settings read failed:", Decoded)
                return nil
            end

            return Decoded
        end

        --// Puts the stored global toggles on Feature and the global
        --// settings on CONFIG. A missing entry gets its default.
        --// Values that were saved per profile before they became global.
        --// The first time the global file lacks one, it is seeded from this
        --// PlaceId's profiles so nothing set before is lost: lists take
        --// every profile's entries, a toggle the last used profile's value.
        --// Returns whether Store was changed (and should be written).
        local MIGRATED_GLOBAL_LISTS = { "BLOCK_WHITELIST" }
        local MIGRATED_GLOBAL_TOGGLES = { "WhitelistSkipsSafety" }

        function AICProfile.MigrateToGlobalStore(Store, ProfileStore)
            local Profiles = type(ProfileStore) == "table" and type(ProfileStore.Profiles) == "table"
                and ProfileStore.Profiles or {}

            Store.FEATURES = type(Store.FEATURES) == "table" and Store.FEATURES or {}
            Store.SETTINGS = type(Store.SETTINGS) == "table" and Store.SETTINGS or {}

            local Changed = false

            for _, Key in ipairs(MIGRATED_GLOBAL_LISTS) do
                if Store.SETTINGS[Key] == nil then
                    local Merged = {}

                    for _, Profile in pairs(Profiles) do
                        local Settings = type(Profile) == "table" and Profile.SETTINGS
                        local List = type(Settings) == "table" and Settings[Key]

                        for _, Value in ipairs(type(List) == "table" and List or {}) do
                            if not table.find(Merged, tostring(Value)) then
                                table.insert(Merged, tostring(Value))
                            end
                        end
                    end

                    Store.SETTINGS[Key] = Merged
                    Changed = true
                end
            end

            local LastUsed = ProfileStore and ProfileStore.LastUsed and Profiles[ProfileStore.LastUsed]
            local LastFeatures = type(LastUsed) == "table" and type(LastUsed.FEATURES) == "table" and LastUsed.FEATURES or {}

            for _, Name in ipairs(MIGRATED_GLOBAL_TOGGLES) do
                if type(Store.FEATURES[Name]) ~= "boolean" and type(LastFeatures[Name]) == "boolean" then
                    Store.FEATURES[Name] = LastFeatures[Name]
                    Changed = true
                end
            end

            return Changed
        end

        function AICProfile.ApplyGlobalStore(Store)
            Store = type(Store) == "table" and Store or {}

            local Features = type(Store.FEATURES) == "table" and Store.FEATURES or {}
            local Settings = type(Store.SETTINGS) == "table" and Store.SETTINGS or {}

            for _, Entry in ipairs(SaveConfig.Features) do
                if Entry.Global then
                    local Value = Features[Entry.Name]

                    if type(Value) ~= "boolean" then
                        Value = Entry.Default
                    end

                    Feature[Entry.Name].Enabled = Value
                end
            end

            for _, Entry in ipairs(SaveConfig.GlobalSettings) do
                CONFIG[Entry.Key] = SaveConfig.NormalizeSetting(Entry, Settings[Entry.Key])
            end
        end

        function AICProfile.WriteGlobalStore()
            if not AICProfile.CanUseFileStorage() then
                return false
            end

            local Store = { FEATURES = {}, SETTINGS = {} }

            for _, Entry in ipairs(SaveConfig.Features) do
                if Entry.Global then
                    Store.FEATURES[Entry.Name] = Feature[Entry.Name].Enabled == true
                end
            end

            for _, Entry in ipairs(SaveConfig.GlobalSettings) do
                Store.SETTINGS[Entry.Key] = SaveConfig.NormalizeSetting(Entry, CONFIG[Entry.Key])
            end

            AICProfile.EnsureProfileFolder()

            local Success, Raw = pcall(function()
                return HttpService:JSONEncode(Store)
            end)

            if not Success then
                warn("AutoFarm global settings encode failed:", Raw)
                return false
            end

            local WriteSuccess, WriteError = pcall(writefile, GLOBAL_FILE, Raw)

            if not WriteSuccess then
                warn("AutoFarm global settings save failed:", WriteError)
                return false
            end

            return true
        end

        function AICProfile.CaptureFeatureState()
            local Result = {}

            for _, Entry in ipairs(SaveConfig.Features) do
                if not Entry.Global then
                    local Data = Feature[Entry.Name]
                    Result[Entry.Name] = Data and Data.Enabled == true
                end
            end

            --// AutoFarm runs off AICFeature.S.Enabled; the Feature entry only
            --// mirrors it for the toggle.
            Result.AutoFarm = AICFeature.S.Enabled == true

            return Result
        end

        --// Every saved toggle is set, and one the profile does not mention
        --// goes back to its default. Keeping the old value instead let a
        --// toggle from the previous profile leak into the one being loaded.
        --// Global toggles are left as they are.
        function AICProfile.ApplyFeatureState(State)
            State = type(State) == "table" and State or {}

            for _, Entry in ipairs(SaveConfig.Features) do
                if Entry.Global then
                    continue
                end

                local Data = Feature[Entry.Name]
                local Value = State[Entry.Name]

                --// AutoBlock's fallback is the place's AUTOBLOCK setting,
                --// which ApplyProfileData has already put on the toggle.
                if type(Value) ~= "boolean" then
                    if Entry.Name == "AutoBlock" then
                        Value = Data.Enabled == true
                    else
                        Value = Entry.Default
                    end
                end

                Data.Enabled = Value
            end

            AICFeature.S.Enabled = Feature.AutoFarm.Enabled

            --// Modules keep their own copy of the toggle; bring them in line.
            for _, Entry in ipairs(SaveConfig.Features) do
                local Module = Context.Modules[Entry.Name]

                if type(Module) == "table" and Module.Enabled ~= nil and Entry.Name ~= "AutoBlock" and not Entry.Global then
                    Module.Enabled = Feature[Entry.Name].Enabled
                end
            end

            --// Toggles that also drive state outside Feature.
            AICFeature.S.BlockEnabled = Feature.AutoBlock.Enabled

            local AutoBlock = Context.Modules.AutoBlock
            if AutoBlock and AutoBlock.SetEnabled then
                AutoBlock:SetEnabled(Feature.AutoBlock.Enabled, false)
            end

            AICCombat.S.SafeCombatPositionEnabled = Feature.SafeCombat.Enabled
            AICFeature.S.WaypointEnabled = not Feature.AutoFind.Enabled
        end

        function AICProfile.CaptureCurrentProfile(Name)
            local FarmConfig = AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig())

            --// The Auto Block toggle is the live value of the place setting.
            FarmConfig.AUTOBLOCK = AICFeature.S.BlockEnabled == true

            return {
                Name = Name or AICProfile.S.ActiveProfileName or "",
                PlaceId = game.PlaceId,
                PLACE_CONFIG = AICProfile.SerializeConfigValue(FarmConfig),
                WAYPOINTS = AICConfig.SerializeVectorList(FarmConfig.WAYPOINTS),
                FARM_ZONES = AICConfig.SerializeZoneList(FarmConfig.FARM_ZONES),
                DEADZONES = AICConfig.SerializeZoneList(FarmConfig.DEADZONES),
                DEFAULT_TARGET_PRIORITY = table.clone(CONFIG.TARGET_ENTITY_PRIORITY or {}),
                FEATURES = AICProfile.CaptureFeatureState(),
                SETTINGS = AICProfile.CaptureSettings(FarmConfig),
            }
        end

        function AICProfile.AreSerializedValuesEqual(A, B)
            local TypeA = type(A)
            local TypeB = type(B)

            if TypeA ~= TypeB then
                return false
            end

            if TypeA ~= "table" then
                return A == B
            end

            for Key, Value in pairs(A) do
                if not AICProfile.AreSerializedValuesEqual(Value, B[Key]) then
                    return false
                end
            end

            for Key in pairs(B) do
                if A[Key] == nil then
                    return false
                end
            end

            return true
        end

        function AICProfile.IsArrayTable(Value)
            if type(Value) ~= "table" then
                return false
            end

            for Key in pairs(Value) do
                if type(Key) ~= "number" then
                    return false
                end
            end

            return true
        end

        function AICProfile.BuildCompactConfig(Base, Current)
            local BaseData = AICProfile.SerializeConfigValue(Base or {})
            local CurrentData = AICProfile.SerializeConfigValue(Current or {})

            local function Diff(BaseValue, CurrentValue)
                if type(CurrentValue) ~= "table" then
                    if AICProfile.AreSerializedValuesEqual(BaseValue, CurrentValue) then
                        return nil
                    end
                    return CurrentValue
                end

                if AICProfile.IsArrayTable(CurrentValue) or AICProfile.IsArrayTable(BaseValue) then
                    if AICProfile.AreSerializedValuesEqual(BaseValue, CurrentValue) then
                        return nil
                    end
                    return CurrentValue
                end

                local Result = {}
                local Changed = false

                for Key, Value in pairs(CurrentValue) do
                    local Difference = Diff(BaseValue and BaseValue[Key], Value)
                    if Difference ~= nil then
                        Result[Key] = Difference
                        Changed = true
                    end
                end

                return Changed and Result or nil
            end

            return Diff(BaseData, CurrentData) or {}
        end

        function AICProfile.BuildCompactProfile(Name)
            local Full = AICProfile.CaptureCurrentProfile(Name)
            local BasePriority = BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                or CONFIG.TARGET_ENTITY_PRIORITY
                or {}

            local Compact = {
                n = Full.Name,
                p = Full.PlaceId,
                c = AICProfile.BuildCompactConfig(BasePlaceConfig, Runtime:GetPlaceConfig()),
                s = Full.SETTINGS,
            }

            if not AICProfile.AreSerializedValuesEqual(Full.DEFAULT_TARGET_PRIORITY, BasePriority) then
                Compact.t = Full.DEFAULT_TARGET_PRIORITY
            end

            local Features = {}
            for NameKey, CompactKey in pairs(COMPACT_FEATURE_KEYS) do
                local Value = Full.FEATURES and Full.FEATURES[NameKey]
                if type(Value) == "boolean" then
                    Features[CompactKey] = Value
                end
            end

            if next(Features) then
                Compact.f = Features
            end

            return Compact
        end

        function AICProfile.ExpandCompactProfile(Data)
            if type(Data) ~= "table" then
                return nil, "IMPORT FAILED: Invalid JSON"
            end

            --// New compact format.
            if Data.n ~= nil or Data.c ~= nil or Data.f ~= nil or Data.t ~= nil then
                local Features = {}
                for NameKey, CompactKey in pairs(COMPACT_FEATURE_KEYS) do
                    if type(Data.f) == "table" and type(Data.f[CompactKey]) == "boolean" then
                        Features[NameKey] = Data.f[CompactKey]
                    end
                end

                local Config = AICProfile.DeserializeConfigValue(Data.c or {})
                local Settings = type(Data.s) == "table" and Data.s or {}
                if Config.REACH_DISTANCE ~= nil then
                    Settings.REACH_DISTANCE = tonumber(Config.REACH_DISTANCE)
                end
                if Config.AUTOBLOCK ~= nil then
                    Settings.AUTOBLOCK = Config.AUTOBLOCK == true
                end

                return {
                    Name = Data.n,
                    PlaceId = Data.p,
                    PLACE_CONFIG = Data.c or {},
                    DEFAULT_TARGET_PRIORITY = Data.t,
                    FEATURES = Features,
                    SETTINGS = Settings,
                }, nil
            end

            --// Backwards compatibility: allow importing the old full JSON format.
            return Data, nil
        end

        function AICProfile.ExportActiveProfile()
            if not AICProfile.S.ActiveProfileName then
                return false, "EXPORT FAILED: No active profile"
            end

            if type(setclipboard) ~= "function" then
                return false, "EXPORT FAILED: setclipboard is unavailable"
            end

            local ExportData = AICProfile.BuildCompactProfile(AICProfile.S.ActiveProfileName)
            local Success, Raw = pcall(function()
                return HttpService:JSONEncode(ExportData)
            end)

            if not Success then
                return false, "EXPORT FAILED: JSON encode error"
            end

            local ClipboardSuccess, ClipboardError = pcall(setclipboard, Raw)
            if not ClipboardSuccess then
                return false, "EXPORT FAILED: " .. tostring(ClipboardError)
            end

            return true, Raw
        end

        function AICProfile.ImportProfileFromText(Raw)
            if type(Raw) ~= "string" or Raw == "" then
                return false, "IMPORT FAILED: Import textbox is empty"
            end

            local DecodeSuccess, Data = pcall(function()
                return HttpService:JSONDecode(Raw)
            end)

            if not DecodeSuccess or type(Data) ~= "table" then
                return false, "IMPORT FAILED: Invalid JSON"
            end

            local ExpandedData, ExpandError = AICProfile.ExpandCompactProfile(Data)
            if not ExpandedData then
                return false, ExpandError or "IMPORT FAILED: Invalid profile data"
            end

            if tonumber(ExpandedData.PlaceId) ~= tonumber(game.PlaceId) then
                return false, "IMPORT FAILED: PlaceId mismatch"
            end

            local Name = tostring(ExpandedData.Name or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if Name == "" then
                Name = "Imported Profile"
            end

            local BaseName = Name
            local Suffix = 2
            while AICProfile.S.ProfileStore.Profiles[Name] do
                Name = BaseName .. " " .. tostring(Suffix)
                Suffix += 1
            end

            ExpandedData.Name = Name
            ExpandedData.PlaceId = game.PlaceId
            AICProfile.S.ProfileStore.Profiles[Name] = ExpandedData
            AICProfile.S.ProfileStore.LastUsed = Name

            if not AICProfile.WriteProfileStore() then
                AICProfile.S.ProfileStore.Profiles[Name] = nil
                return false, "IMPORT FAILED: Could not save profile"
            end

            if not AICProfile.LoadProfile(Name) then
                return false, "IMPORT FAILED: Could not load profile"
            end

            return true, Name
        end

        function AICProfile.SaveActiveProfile()
            if not AICProfile.S.ActiveProfileName then
                return false
            end

            AICProfile.S.ProfileData = AICProfile.CaptureCurrentProfile(AICProfile.S.ActiveProfileName)
            AICProfile.S.ProfileStore.Profiles[AICProfile.S.ActiveProfileName] = AICProfile.S.ProfileData
            AICProfile.S.ProfileStore.LastUsed = AICProfile.S.ActiveProfileName

            return AICProfile.WriteProfileStore()
        end

        --// Sliders fire their callback on every step of a drag. Saving straight to
        --// disk from there means dozens of writefile calls for one gesture, so
        --// continuous controls queue a save instead of performing one.
        function AICProfile.QueueProfileSave()
            if not AICProfile.S.ActiveProfileName or AICProfile.S.ProfileSaveQueued then
                return
            end

            AICProfile.S.ProfileSaveQueued = true

            task.delay(CONFIG.PROFILE_SAVE_DEBOUNCE, function()
                AICProfile.S.ProfileSaveQueued = false
                AICProfile.SaveActiveProfile()
            end)
        end

        function AICProfile.ApplyProfileData(Data)
            if type(Data) ~= "table" then
                return false
            end

            local StoredPlaceConfig = AICProfile.DeserializeConfigValue(Data.PLACE_CONFIG)
            local FarmConfig = AICProfile.MergeConfig(BasePlaceConfig, StoredPlaceConfig)

            --// Backwards compatibility for profiles created before PLACE_CONFIG existed.
            FarmConfig.WAYPOINTS = AICConfig.CloneVectorList(Data.WAYPOINTS or FarmConfig.WAYPOINTS)
            FarmConfig.FARM_ZONES = AICConfig.CloneZoneList(Data.FARM_ZONES or FarmConfig.FARM_ZONES)
            FarmConfig.DEADZONES = AICConfig.CloneZoneList(Data.DEADZONES or FarmConfig.DEADZONES)
            AICProfile.ApplySettings(Data.SETTINGS, FarmConfig)

            PlaceConfig = AICConfig.NormalizePlaceConfig(FarmConfig)
            Runtime:SetPlaceConfig(PlaceConfig)

            CONFIG.TARGET_ENTITY_PRIORITY = table.clone(
                Data.DEFAULT_TARGET_PRIORITY
                    or BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                    or {}
            )

            Feature.AutoBlock.Enabled = PlaceConfig.AUTOBLOCK
            AICFeature.S.BlockEnabled = PlaceConfig.AUTOBLOCK

            local AutoBlock = Context.Modules.AutoBlock
            if AutoBlock and AutoBlock.SetEnabled then
                AutoBlock:SetEnabled(PlaceConfig.AUTOBLOCK, false)
            end

            AICProfile.ApplyFeatureState(Data.FEATURES)

            local AutoBlock = Context.Modules.AutoBlock
            if AutoBlock and AutoBlock.RefreshUI then
                AutoBlock:RefreshUI()
            end

            CONFIG.CURRENT_WAYPOINT_TARGET = 1
            AICFeature.S.WaypointWaitUntil = nil
            if AICFeature.ResetWaypointLoop then AICFeature.ResetWaypointLoop() end
            --// The new profile brings its own Boss Route with it.
            if AICFeature.ResetBossRoute then AICFeature.ResetBossRoute() end
            AICCombat.ResetTargetReposition()
            AICFeature.S.DeadzoneEscapePosition = nil
            PatrolState.PatrolPosition = nil
            AICFeature.S.FarmReturnPosition = nil
            AICProfile.S.SelectedFarmZoneIndex = 1
            AICProfile.S.SelectedDeadzoneIndex = 1
            PatrolState.LastPatrolCalculateTime = 0
            AICFeature.S.LastFarmReturnCalculateTime = 0

            return true
        end

        function AICProfile.LoadProfile(Name)
            local Data = AICProfile.S.ProfileStore.Profiles[Name]

            if type(Data) ~= "table" then
                return false
            end

            if AICProfile.ApplyProfileData(Data) then
                AICProfile.S.ActiveProfileName = Name
                AICProfile.S.ProfileData = Data
                AICProfile.S.ProfileStore.LastUsed = Name
                AICProfile.WriteProfileStore()
                return true
            end

            return false
        end

        function AICProfile.DeleteProfile(Name)
            if not Name or not AICProfile.S.ProfileStore.Profiles[Name] then
                return false
            end

            AICProfile.S.ProfileStore.Profiles[Name] = nil

            if AICProfile.S.ProfileStore.LastUsed == Name then
                AICProfile.S.ProfileStore.LastUsed = nil
            end

            if AICProfile.S.ActiveProfileName == Name then
                AICProfile.S.ActiveProfileName = nil
                AICProfile.S.ProfileData = nil
                PlaceConfig = AICConfig.NormalizePlaceConfig(AICConfig.IsValidPlace(game.PlaceId) or {})
                Runtime:SetPlaceConfig(PlaceConfig)
                CONFIG.TARGET_ENTITY_PRIORITY = table.clone(
                    BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                        or {}
                )
                Feature.AutoBlock.Enabled = BasePlaceConfig.AUTOBLOCK == true
                AICFeature.S.BlockEnabled = BasePlaceConfig.AUTOBLOCK == true
                CONFIG.CURRENT_WAYPOINT_TARGET = 1
            AICFeature.S.WaypointWaitUntil = nil
            if AICFeature.ResetWaypointLoop then AICFeature.ResetWaypointLoop() end
            end

            AICProfile.WriteProfileStore()
            return true
        end

        function AICProfile.CreateProfile(Name)
            Name = tostring(Name or ""):gsub("^%s+", ""):gsub("%s+$", "")

            if Name == "" or #Name > 32 then
                return false, "Invalid profile name"
            end

            if Name:find("[/\\:%*%?\"<>|]") then
                return false, "Invalid profile name"
            end

            if AICProfile.S.ProfileStore.Profiles[Name] then
                return false, "Profile already exists"
            end

            AICProfile.S.ActiveProfileName = Name
            AICProfile.S.ProfileData = AICProfile.BuildDefaultProfile()
            AICProfile.S.ProfileData.Name = Name

            AICProfile.ApplyProfileData(AICProfile.S.ProfileData)

            AICProfile.S.ProfileStore.Profiles[Name] = AICProfile.CaptureCurrentProfile(Name)
            AICProfile.S.ProfileStore.LastUsed = Name
            AICProfile.WriteProfileStore()

            return true
        end

        function AICProfile.GetProfileNames()
            local Names = {}

            for Name in pairs(AICProfile.S.ProfileStore.Profiles) do
                table.insert(Names, Name)
            end

            table.sort(Names, function(A, B)
                return string.lower(A) < string.lower(B)
            end)

            return Names
        end

        function AICProfile.ApplyDefaultPlaceConfig()
            AICProfile.S.ActiveProfileName = nil
            AICProfile.S.ProfileData = nil

            --// Never create a fake Vector3.zero farm zone. If the place config
            --// has no zones, NormalizePlaceConfig keeps the lists empty.
                PlaceConfig = AICConfig.NormalizePlaceConfig(AICProfile.DeserializeConfigValue(AICProfile.SerializeConfigValue(BasePlaceConfig)))
                Runtime:SetPlaceConfig(PlaceConfig)

            CONFIG.TARGET_ENTITY_PRIORITY = table.clone(
                BasePlaceConfig.DEFAULT_TARGET_PRIORITY
                    or {}
            )

            Feature.AutoBlock.Enabled = BasePlaceConfig.AUTOBLOCK == true
            AICFeature.S.BlockEnabled = BasePlaceConfig.AUTOBLOCK == true

            local AutoBlock = Context.Modules.AutoBlock
            if AutoBlock and AutoBlock.SetEnabled then
                AutoBlock:SetEnabled(BasePlaceConfig.AUTOBLOCK == true, false)
            end
            CONFIG.CURRENT_WAYPOINT_TARGET = 1
            AICFeature.S.WaypointWaitUntil = nil
            if AICFeature.ResetWaypointLoop then AICFeature.ResetWaypointLoop() end
            --// PINNED_STATE is global, so ResetSettings leaves it alone.
            AICProfile.ResetSettings()

            AICCombat.ResetTargetReposition()
            AICFeature.S.DeadzoneEscapePosition = nil
            PatrolState.PatrolPosition = nil
            AICFeature.S.FarmReturnPosition = nil
            PatrolState.LastPatrolCalculateTime = 0
            AICFeature.S.LastFarmReturnCalculateTime = 0

            return true
        end

        AICProfile.S.ProfileStore = AICProfile.ReadProfileStore()
        do
            local GlobalStore = AICProfile.ReadGlobalStore() or {}
            local Migrated = AICProfile.MigrateToGlobalStore(GlobalStore, AICProfile.S.ProfileStore)

            AICProfile.ApplyGlobalStore(GlobalStore)

            if Migrated then
                AICProfile.WriteGlobalStore()
            end
        end

        Context.PROFILE_FOLDER = PROFILE_FOLDER
        Context.PROFILE_FILE = PROFILE_FILE
        return AICProfile
    end,
}
