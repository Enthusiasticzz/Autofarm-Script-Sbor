-- ProfileManager_Storage - split from Core/ProfileManager.lua as part of Step 4.
return {
    Name = "ProfileManager_Storage",
    Dependencies = {"Runtime", "SaveConfig", "Logger"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local SaveConfig = Context.SaveConfig
        local AICProfile = Context.AICProfile
        local CONFIG = Context.CONFIG
        local Feature = Context.Feature
        local HttpService = Context.Services.HttpService
        local Logger = Context.Logger

        local PROFILE_FOLDER = "AutoFarmProfiles"
        local PROFILE_FILE = PROFILE_FOLDER .. "/" .. tostring(game.PlaceId) .. ".json"
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
                Logger.debug("Profile store decode failed; starting empty")
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

        return { Name = "ProfileManager_Storage" }
    end,
}
