-- ModuleConfig - the single source of truth for module loading order,
-- feature classification, and lifecycle hooks.
--
-- Init.lua loads this file instead of the inline MODULES array.
-- Every module listed here must return { Name, Dependencies?, IsFeature?, Start(Context) }.
--
-- Adding a feature:
--   1. Create the module file.
--   2. Add its path to START_ORDER (position determines UI control order).
--   3. If it is a feature, add to FEATURE_MODULES.
--   4. If it needs BuildLateUI, add to LATE_UI_MODULES.
--   5. If it needs Finalize, add to FINALIZE_MODULES.
--   6. Add its toggle to SaveConfig.Features (if applicable).
--
-- Module names must match their file basenames (e.g. "AutoFarming" for "Features/AutoFarming.lua").
--
-- This file is loaded both remotely (via loadstring) and locally (via require).
-- When running locally in Studio, the paths are relative to this file'"'"'s directory.
return {
    --// Every module, in start order. Dependencies start first regardless.
    --// The order also determines where each module'"'"'s UI controls appear.
    START_ORDER = {
        --// Core bootstrap and config
        "Core/SaveConfig.lua",
        "Core/GuiClick.lua",
        "Core/Runtime.lua",
        "Core/Logger.lua",

        --// UI library and components
        "UI/Descriptions.lua",
        "Core/ProfileManager_Storage.lua",
        "Core/ProfileManager_Global.lua",
        "Core/ProfileManager_Serialization.lua",
        "Core/ProfileManager_Creation.lua",
        "Core/ProfileManager.lua",
        "UI/Components.lua",
        "UI/Floating.lua",
        "UI/DetailKit.lua",
        "UI/BrowserShell.lua",

        --// Combat modules
        "Combat/CombatUtils.lua",
        "Features/EnemyPriority.lua",
        "Combat/Targeting.lua",
        "Combat/Navigation.lua",
        "Combat/Combat.lua",

        --// Feature modules (game logic)
        "Features/AutoFarming.lua",
        --// AutoFarming helpers. They attach to AICFeature, so they must start
        --// after the entry module above.
        "Features/AutoFarming_Combat.lua",
        "Features/AutoFarming_Navigation.lua",
        "Features/AutoFarming_State.lua",
        "Features/AutoFarming_UI.lua",
        "Features/AutoFarming_Smithing.lua",
        "Features/AutoFarming_Mining.lua",
        "Features/AutoBlock.lua",
        "Features/AutoBlockConfirm.lua",
        "Features/SafeCombat.lua",
        "Features/JumpWhileFighting.lua",
        "Features/AutoSkill.lua",
        "Features/MobGather.lua",
        "Features/AutoFind.lua",
        "Features/IgnoreFarmZone.lua",
        "Features/AutoPatrol.lua",
        "Features/ReturnToFarmZone.lua",
        "Features/AutoRefill.lua",
        "Features/SafeBoosterReset.lua",
        "Features/ResetStats.lua",
        "Features/DebugVisualizer.lua",
        "Features/AutoHeal.lua",
        "Features/AntiAFK.lua",
        "Features/FpsBoost.lua",
        "Features/AutoStartGame.lua",
        "Features/Minezone.lua",
        "Features/WalkController.lua",
        "Features/AutoMining.lua",
        "Features/SmithingRecipes.lua",
        "Features/SmithingMinigame.lua",
        "Features/AutoSmithing.lua",
        "Features/SmithingDetail.lua",
        "Features/SmithingBrowser.lua",
        "Features/MobDictionary.lua",
        "Features/MobDetail.lua",
        "Features/MobBrowser.lua",
        "Features/AssetDictionary.lua",
        "Features/AssetDetail.lua",
        "Features/AssetBrowser.lua",
        "Features/DatabaseDump.lua",
        "Features/PartySystem.lua",
        "Features/ServerHop.lua",
        "Features/ServerUI.lua",
        "Features/FollowerGuard.lua",
        "Features/Webhook.lua",
        "Features/TeleportNavigate.lua",
        "Features/QuestAssign.lua",
        "Features/QuestHelper.lua",
        "Features/ProfileSettings.lua",
        "Features/Waypoints.lua",
        "Features/Farmzone.lua",
        "Features/Deadzone.lua",
        "Features/RespawnTimers.lua",
        "Features/WaypointLoop.lua",
        "Features/BossNavigator.lua",

        --// Lifecycle modules (started last)
        "Core/Bootstrap.lua",
        "Core/Heartbeat.lua",
    },

    --// Modules that are features - their returned object goes into Context.Features
    --// and receives :Update(dt) calls every Heartbeat.
    FEATURE_MODULES = {
        ["Combat/Combat.lua"] = true,
        ["Combat/Targeting.lua"] = true,
        ["Combat/Navigation.lua"] = true,
        ["Features/AutoFarming.lua"] = true,
        ["Features/AutoBlock.lua"] = true,
        ["Features/AutoBlockConfirm.lua"] = true,
        ["Features/SafeCombat.lua"] = true,
        ["Features/JumpWhileFighting.lua"] = true,
        ["Features/AutoSkill.lua"] = true,
        ["Features/MobGather.lua"] = true,
        ["Features/AutoFind.lua"] = true,
        ["Features/IgnoreFarmZone.lua"] = true,
        ["Features/AutoPatrol.lua"] = true,
        ["Features/ReturnToFarmZone.lua"] = true,
        ["Features/AutoRefill.lua"] = true,
        ["Features/SafeBoosterReset.lua"] = true,
        ["Features/ResetStats.lua"] = true,
        ["Features/DebugVisualizer.lua"] = true,
        ["Features/AutoHeal.lua"] = true,
        ["Features/AntiAFK.lua"] = true,
        ["Features/FpsBoost.lua"] = true,
        ["Features/AutoStartGame.lua"] = true,
        ["Features/Minezone.lua"] = true,
        ["Features/WalkController.lua"] = true,
        ["Features/AutoMining.lua"] = true,
        ["Features/AutoSmithing.lua"] = true,
        ["Features/SmithingMinigame.lua"] = true,
        ["Features/PartySystem.lua"] = true,
        ["Features/ServerUI.lua"] = true,
        ["Features/FollowerGuard.lua"] = true,
        ["Features/Webhook.lua"] = true,
        ["Features/QuestHelper.lua"] = true,
        ["Features/ProfileSettings.lua"] = true,
        ["Features/Waypoints.lua"] = true,
        ["Features/Farmzone.lua"] = true,
        ["Features/Deadzone.lua"] = true,
        ["Features/RespawnTimers.lua"] = true,
        ["Features/WaypointLoop.lua"] = true,
        ["Features/BossNavigator.lua"] = true,
        ["Features/EnemyPriority.lua"] = true,
    },

    --// Modules that receive :BuildLateUI() after all modules have started.
    LATE_UI_MODULES = {
        ["Features/ProfileSettings.lua"] = true,
        ["Features/Waypoints.lua"] = true,
        ["Features/Farmzone.lua"] = true,
        ["Features/Deadzone.lua"] = true,
        ["Features/ServerUI.lua"] = true,
        ["Features/BossNavigator.lua"] = true,
    },

    --// Modules that receive :Finalize() after BuildLateUI.
    FINALIZE_MODULES = {
        ["Core/ProfileManager.lua"] = true,
        ["Features/ProfileSettings.lua"] = true,
    },

    --// Modules that are not specs (e.g. utility libraries loaded separately).
    NON_SPEC_MODULES = {
        ["UI/Utils.lua"] = true,
    },

    --// Module name extraction: "Features/AutoFarming.lua" -> "AutoFarming"
    NameFromPath = function(self, Path)
        return string.match(Path, "([^/]+)%.lua$")
    end,

    --// Get the list of feature module names.
    GetFeatureNames = function(self)
        local Names = {}
        for Path in pairs(self.FEATURE_MODULES) do
            table.insert(Names, self:NameFromPath(Path))
        end
        table.sort(Names)
        return Names
    end,

    --// Check if a module path is a feature.
    IsFeature = function(self, Path)
        return self.FEATURE_MODULES[Path] == true
    end,

    --// Check if a module needs BuildLateUI.
    NeedsLateUI = function(self, Path)
        return self.LATE_UI_MODULES[Path] == true
    end,

    --// Check if a module needs Finalize.
    NeedsFinalize = function(self, Path)
        return self.FINALIZE_MODULES[Path] == true
    end,

    --// Check if a module is a non-spec module.
    IsNonSpec = function(self, Path)
        return self.NON_SPEC_MODULES[Path] == true
    end,
}
