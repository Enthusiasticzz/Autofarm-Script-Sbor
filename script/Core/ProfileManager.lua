-- ProfileManager owns profile storage, serialization, import/export, and profile state.
return {
    Name = "ProfileManager",
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager_Storage", "ProfileManager_Global", "ProfileManager_Serialization", "ProfileManager_Creation"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local SaveConfig = Context.SaveConfig
        local AICProfile = Context.AICProfile

        local PROFILE_FOLDER = "AutoFarmProfiles"
        local PROFILE_FILE = PROFILE_FOLDER .. "/" .. tostring(game.PlaceId) .. ".json"
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

        AICProfile.S.ActiveProfileName = nil
        AICProfile.S.ProfileSaveQueued = false
        AICProfile.S.ProfileData = nil
        AICProfile.S.SelectedFarmZoneIndex = 1
        AICProfile.S.SelectedDeadzoneIndex = 1
        --// Set when this run ends (the script was run again): no more writes,
        --// so a stopped run cannot save over what the new run loaded.
        AICProfile.S.StorageClosed = false

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
