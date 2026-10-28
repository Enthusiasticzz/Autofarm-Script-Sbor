-- ProfileManager_Global - split from Core/ProfileManager.lua as part of Step 4.
return {
    Name = "ProfileManager_Global",
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

        --// Lists migrated from per-profile settings into the global store.
        local MIGRATED_GLOBAL_LISTS = { "BLOCK_WHITELIST" }
        local MIGRATED_GLOBAL_TOGGLES = { "WhitelistSkipsSafety" }

        for _, Entry in ipairs(SaveConfig.Features) do
            if Entry.Key and not Entry.Global then
                COMPACT_FEATURE_KEYS[Entry.Name] = Entry.Key
            end
        end


        function AICProfile.NormalizePartyLeader(Leader)
            return SaveConfig.NormalizeSetting(SaveConfig.GetSetting("PARTY_LEADER"), Leader)
        end

        function AICProfile.NormalizePinnedState(State)
            return SaveConfig.NormalizeSetting(SaveConfig.GetSetting("PINNED_STATE"), State)
        end

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

        return { Name = "ProfileManager_Global" }
    end,
}
