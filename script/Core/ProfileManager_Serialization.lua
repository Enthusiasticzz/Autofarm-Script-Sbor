-- ProfileManager_Serialization - split from Core/ProfileManager.lua as part of Step 4.
return {
    Name = "ProfileManager_Serialization",
    Dependencies = {"Runtime", "SaveConfig"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local SaveConfig = Context.SaveConfig
        local AICProfile = Context.AICProfile
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local CONFIG = Context.CONFIG
        local Feature = Context.Feature
        local HttpService = Context.Services.HttpService
        local BasePlaceConfig = Runtime:GetBasePlaceConfig()

        local PROFILE_FOLDER = "AutoFarmProfiles"
        --// Global toggles and SaveConfig.GlobalSettings, shared by every
        --// profile and PlaceId.

        --// Short keys for feature toggles in exported/imported profile text,
        --// taken from SaveConfig.Features so a new toggle exports on its own.
        --// Global toggles are not part of a profile, so they are not exported.
        local COMPACT_FEATURE_KEYS = {}

        for _, Entry in ipairs(SaveConfig.Features) do
            if Entry.Key and not Entry.Global then
                COMPACT_FEATURE_KEYS[Entry.Name] = Entry.Key
            end
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

                --// A saved state naming a toggle this build no longer has used
                --// to index nil here, and the throw aborted the whole restore.
                if type(Data) ~= "table" then
                    continue
                end

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

                local Stored = Feature[Entry.Name]

                if type(Module) == "table"
                    and type(Stored) == "table"
                    and Module.Enabled ~= nil
                    and Entry.Name ~= "AutoBlock"
                    and not Entry.Global
                then
                    Module.Enabled = Stored.Enabled
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

            local PreviousLastUsed = AICProfile.S.ProfileStore.LastUsed

            AICProfile.S.ProfileStore.Profiles[Name] = ExpandedData
            AICProfile.S.ProfileStore.LastUsed = Name

            --// LoadProfile writes the store itself, so the import used to
            --// encode and write every profile twice - the whole file, twice,
            --// on the frame the button was pressed. A load that fails leaves
            --// the file as it was, since nothing was written yet.
            if not AICProfile.LoadProfile(Name) then
                AICProfile.S.ProfileStore.Profiles[Name] = nil
                AICProfile.S.ProfileStore.LastUsed = PreviousLastUsed
                return false, "IMPORT FAILED: Could not load profile"
            end

            return true, Name
        end

        return { Name = "ProfileManager_Serialization" }
    end,
}
