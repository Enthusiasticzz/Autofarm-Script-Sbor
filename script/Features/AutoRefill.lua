-- AutoRefill owns the "Refill Booster" toggle (saved as ResetOnBoostOut) and
-- the boost watcher behind it: when a selected boost runs out, the character
-- is reset so the game refills it.
--
-- The boosters belong to the game, not to this file: PlayerStats is scanned for
-- them by name, so a booster this script has never heard of still gets its own
-- toggle in the Booster Reset section instead of failing silently. Which of
-- them cause a reset is the RESET_BOOSTERS setting, so one booster running out
-- can be acted on without the others resetting the character.
return {
    Name = "AutoRefill",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICProfile = Context.AICProfile
        local SaveConfig = Context.SaveConfig
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// Saved under its original name so existing profiles and exported
        --// text keep their value.
        local FEATURE_NAME = "ResetOnBoostOut"
        local SETTING_KEY = "RESET_BOOSTERS"

        --// A booster is a ValueBase under PlayerStats whose name says boost.
        --// Matched as a substring, case-insensitively, so Boost, BoostDrops,
        --// BoostExp and MoneyBoost are all found: which names exist is the
        --// game's business, and every one that is found gets a toggle rather
        --// than staying invisible.
        local BOOST_PATTERN = "boost"

        local Setting = SaveConfig.GetSetting(SETTING_KEY)

        local Section = UIRef.BoosterSection

        --// Booster name -> its toggle, and name -> true once its watcher is
        --// connected, so a rescan never adds a control or a connection twice.
        local Toggles = {}
        local Watched = {}

        local Feature = { Name = "AutoRefill", IsFeature = true }

        local function GetSelected()
            if type(CONFIG[SETTING_KEY]) ~= "table" then
                CONFIG[SETTING_KEY] = SaveConfig.NormalizeSetting(Setting, nil)
            end

            return CONFIG[SETTING_KEY]
        end

        local function IsSelected(BoostName)
            return table.find(GetSelected(), BoostName) ~= nil
        end

        local function SetSelected(BoostName, Value)
            local Result = {}

            for _, Name in ipairs(GetSelected()) do
                if Name ~= BoostName then
                    table.insert(Result, Name)
                end
            end

            if Value == true then
                table.insert(Result, BoostName)
            end

            CONFIG[SETTING_KEY] = SaveConfig.NormalizeSetting(Setting, Result)
            AICProfile.QueueProfileSave()
        end

        --// Every booster name PlayerStats currently holds, and the folder
        --// itself, which is nil until the game has created it.
        local function FindBoosters()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Found = {}

            if PlayerStats then
                for _, Child in ipairs(PlayerStats:GetChildren()) do
                    if Child:IsA("ValueBase")
                        and string.find(string.lower(Child.Name), BOOST_PATTERN, 1, true)
                    then
                        table.insert(Found, Child.Name)
                    end
                end
            end

            table.sort(Found)

            return Found, PlayerStats
        end

        local function SetStatus()
            local Label = UIRef.BoosterStatusLabel

            if not Label then
                return
            end

            local Names = {}

            for Name in pairs(Toggles) do
                table.insert(Names, Name)
            end

            table.sort(Names)

            local Parts = {}

            for _, Name in ipairs(Names) do
                table.insert(Parts, Name .. (IsSelected(Name) and " ON" or " off"))
            end

            Label:Set(#Parts > 0
                and ("BOOSTERS  " .. table.concat(Parts, "   ·   "))
                or "BOOSTERS  none found yet")
        end

        local function BuildToggle(BoostName)
            local Toggle = Section:AddToggle{
                Name = BoostName,
                Default = IsSelected(BoostName),
                Callback = function(Value)
                    SetSelected(BoostName, Value)
                    SetStatus()
                end,
            }

            Toggles[BoostName] = Toggle
        end

        --// One connection per booster, but only the selected ones reset: the
        --// connection lives for the whole session, so the selection is read
        --// when the boost changes, not when it was made.
        function Feature.WatchBooster(Boost)
            if Watched[Boost.Name] then
                return
            end

            Watched[Boost.Name] = true

            table.insert(
                AICFeature.S.BoosterConnections,
                Boost:GetPropertyChangedSignal("Value"):Connect(function()
                    Feature.ResetOnBoostOut(Boost)
                end)
            )
        end

        function Feature.ResetOnBoostOut(Boost)
            --// The feature toggle is read here too, so turning Refill Booster
            --// off stops the resets without reconnecting anything.
            if not FeatureState[FEATURE_NAME].Enabled then
                return
            end

            if not IsSelected(Boost.Name) or Boost.Value ~= 0 then
                return
            end

            --// Resolved at fire time. The connection outlives respawns, so a
            --// Humanoid captured at setup would be the dead one.
            local _, Humanoid = Runtime:GetCharacter()

            if Humanoid then
                Humanoid.Health = 0
            end
        end

        --// Looks again for boosters, adds a toggle for any new one and starts
        --// watching it. Safe to call as often as wanted.
        function Feature.ScanBoosters(Notify)
            local Found, PlayerStats = FindBoosters()

            for _, Name in ipairs(Found) do
                if Section and not Toggles[Name] then
                    BuildToggle(Name)
                end

                local Boost = PlayerStats and PlayerStats:FindFirstChild(Name)

                if Boost then
                    Feature.WatchBooster(Boost)
                end
            end

            SetStatus()

            if Notify then
                NotifyAction(
                    "REFILL BOOSTER",
                    #Found > 0
                        and (tostring(#Found) .. " booster(s) found: " .. table.concat(Found, ", "))
                        or "No boosters in PlayerStats yet",
                    4
                )
            end
        end

        --// Called by the profile refresh in Components once a profile has been
        --// loaded, so the toggles follow the profile's selection.
        function Feature.RefreshBoosterToggles()
            for Name, Toggle in pairs(Toggles) do
                Toggle:Set(IsSelected(Name), false)
            end

            SetStatus()
        end

        function Feature.AutoRefillBooster()
            task.spawn(function()
                --// PlayerStats does not exist at load time on every join.
                Player:WaitForChild("PlayerStats", 30)
                Feature.ScanBoosters(false)
            end)
        end

        AICFeature.AutoRefillBooster = Feature.AutoRefillBooster
        AICFeature.RefreshBoosterToggles = Feature.RefreshBoosterToggles

        function Feature:Update()
            --// Event driven: the watchers are connected by ScanBoosters.
            --// Calling it from here would add connections on every Heartbeat.
        end

        AICUI.BindFeatureToggle(FEATURE_NAME, "Refill Booster", nil, Section)

        if Section then
            UIRef.BoosterStatusLabel = Section:AddLabel("BOOSTERS  none found yet")
            UIRef.BoosterRefreshButton = Section:AddButton{
                Name = "Refresh Boosters",
                Callback = function()
                    Feature.ScanBoosters(true)
                end,
            }
            Section:AddLabel("ON = that booster running out resets the character")
        end

        Feature.AutoRefillBooster()

        --// Also holds Safe Booster Reset's watcher; PlayerStats outlives this run.
        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(AICFeature.S.BoosterConnections)
        end)

        return Feature
    end,
}
