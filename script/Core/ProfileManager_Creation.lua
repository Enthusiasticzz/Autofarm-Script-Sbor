-- ProfileManager_Creation - split from Core/ProfileManager.lua as part of Step 4.
return {
    Name = "ProfileManager_Creation",
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

        return { Name = "ProfileManager_Creation" }
    end,
}
