return {
    Name = "Bootstrap",
    Dependencies = {"Runtime", "ProfileManager", "Components", "ProfileSettings", "Waypoints", "Farmzone", "Deadzone", "DebugVisualizer", "CombatUtils", "Targeting", "Navigation", "Combat", "AutoFarming", "AutoBlock", "AutoPatrol", "ReturnToFarmZone", "AntiAFK"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Replicated = Services.Replicated
        local StarterGui = Services.StarterGui
        local RunService = Services.RunService
        local UserInputService = Services.UserInputService
        local MarketplaceService = Services.MarketplaceService
        local PathfindingService = Services.PathfindingService
        local HttpService = Services.HttpService
        local Player = Context.Player
        local PlayerGui = Context.PlayerGui
        local CONFIG = Context.CONFIG
        local AICConfig = Context.AICConfig
        local AICProfile = Context.AICProfile
        local AICCombatUtils = Context.AICCombatUtils
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local Feature = Context.Feature
        local MiningFeature = Context.MiningFeature
        local UI = Context.UI
        local UIRef = Context.UIRef
        local PatrolState = Context.PatrolState
        local NotifyAction = Context.NotifyAction
        local AICPlaceConfig = Runtime:GetPlaceConfig()
        local DEBUG_COLORS = Context.DEBUG_COLORS
        local BasePlaceConfig = Runtime:GetBasePlaceConfig()
        local InputBindableFunction = Runtime:GetInputBindableFunction()
        local FaceOrientation = Runtime:GetFaceOrientation()

        --// Bootstrap / composition root
        --//
        --// Composition root. Creates the window, every control and the debug
        --// visualiser, then restores the last used profile. Nothing here runs
        --// per frame.
        ------------------------------------------------------------------------
        
        --======================================================================
        --// SECTION 3  ::  BOOTSTRAP AND RUNTIME
        --// Everything that actually executes, in its original order.
        --======================================================================
        
        
        --// PlaceConfig, BasePlaceConfig and the default target priority are
        --// resolved in Runtime. Rebuilding them here would hand out new tables
        --// after ProfileManager and the zone modules already hold the old ones.

        AICFeature.updateCharacter()
        
        AICFeature.CreateToggleContainer()
        AICFeature.RegenStamina()
        
        Context.Connect(Player.CharacterAdded, function()
            task.wait()
        
            AICFeature.S.DEATH_COUNT += 1
            CONFIG.CURRENT_WAYPOINT_TARGET = 1
            AICFeature.S.WaypointWaitUntil = nil
            if AICFeature.ResetWaypointLoop then AICFeature.ResetWaypointLoop() end
            AICDebug.ResetDebugWaypoints()
            AICDebug.UpdateDebugWaypointColors()
            AICCombat.S.ClosestTarget = nil
            Runtime:SetInputBindableFunction(nil)
            AICFeature.S.BlockValue = nil
            AICFeature.S.Equipped = false
            AICCombat.S.RETREATING = false
            AICCombat.S.SkillRetreatPosition = nil
            AICCombat.S.LastSkillRetreatTime = 0
            AICCombat.S.SkillThreatUntil = 0
            AICCombat.S.LastSkillSolverTime = 0
            AICFeature.S.LAST_EQUIP_TIME = 0
            PatrolState.PatrolLegsRemaining = 0
            PatrolState.PatrolHeading = nil
            AICCombatUtils.S.StuckSamplePosition = nil
            AICCombatUtils.S.StuckStrikes = 0
            AICCombat.S.LAST_ATTACK_TIME = 0
            AICCombat.S.LAST_SKILL_TIME = 0
            AICCombat.S.LAST_COMBAT_TARGET_CHECK = 0
            AICCombat.S.COMBAT_TARGET_LOST_SINCE = nil
            AICCombat.S.COMBAT_TARGET_SCORE = math.huge
            AICCombat.S.COMBAT_ATTACK_PHASE = 0
            AICCombat.S.COMBAT_NEXT_ATTACK_TIME = 0
            AICCombat.S.COMBAT_NEXT_SKILL_TIME = 0
            AICFeature.S.LAST_CONSUME_TIME = 0
            AICFeature.S.LAST_INTERACTION_TIME = 0
            AICCombatUtils.S.LAST_STUCK_POSITION = nil
            AICFeature.S.FaceAttachment = nil
            Runtime:SetFaceOrientation(nil)
        
            if AICCombatUtils.S.DebugFolder then
                --// Keep the debug instances, but reset their state/colors for the new life.
                for Index, Data in AICDebug.S.DebugWaypointData do
                    if Data.Label then
                        Data.Label.TextColor3 = DEBUG_COLORS.WaypointPending
                    end
                    if Data.Marker then
                        Data.Marker.BackgroundColor3 = DEBUG_COLORS.WaypointPending
                    end
                end
            end
        
            if AICFeature.S.StaminaConnection then
                AICFeature.S.StaminaConnection:Disconnect()
                AICFeature.S.StaminaConnection = nil
            end
        
            table.clear(AICCombat.S.ValidMobs)
            table.clear(AICCombat.S.CombatGroupCache)
            table.clear(AICCombat.S.CombatBladeCache)
            table.clear(AICCombatUtils.S.BladePartCache)
            AICCombat.ClearUnreachableMobs()
        
            task.delay(0.5, function()
                AICFeature.S.Equipped = false
            end)
        
            AICFeature.updateCharacter()
            AICCombat.ResetTargetReposition()
            AICFeature.CreateToggleContainer()
            AICFeature.RegenStamina()
        end)
        
        
        
        --//==============================================================
        --// Utility UI
        --//==============================================================
        
        --UI:SetTheme({
        --    Background      = CONFIG.UI_PANEL,
        --    BackgroundLight = CONFIG.UI_SURFACE,
        --    Panel           = CONFIG.UI_SURFACE,
        --    PanelLight      = CONFIG.UI_HOVER,
        --    PanelHover      = Color3.fromRGB(48, 50, 60),
        --    Element         = CONFIG.UI_SURFACE,
        --    ElementHover    = CONFIG.UI_HOVER,
        --    Text            = CONFIG.UI_TEXT,
        --    TextSecondary   = Color3.fromRGB(190, 193, 204),
        --    TextMuted       = CONFIG.UI_MUTED,
        --    Cyan            = CONFIG.UI_ACCENT,
        --    CyanDark        = Color3.fromRGB(80, 90, 190),
        --    CyanDim         = Color3.fromRGB(150, 160, 255),
        --    White           = CONFIG.UI_TEXT,
        --    Border          = CONFIG.UI_BORDER,
        --    BorderDim       = Color3.fromRGB(45, 48, 58),
        --    Danger          = Color3.fromRGB(255, 65, 65),
        --    Warning         = Color3.fromRGB(255, 180, 0),
        --    Black           = Color3.fromRGB(10, 10, 14),
        --})
        
        --// Feature toggles
        Feature.ResetStats.Enabled = true
        
        --// Priority component
        UIRef.PriorityComponent = UIRef.TargetSection:AddPriority(
            "Enemy Priority",
            CONFIG.TARGET_ENTITY_PRIORITY
        )
        
        -- Keep CONFIG and the Utils priority component on the same table.
        CONFIG.TARGET_ENTITY_PRIORITY = UIRef.PriorityComponent.Priority
        
        --// Capture the stock methods before the overrides below replace them.
        AICUI.S.OriginalPriorityAdd      = UIRef.PriorityComponent.Add
        AICUI.S.OriginalPriorityRemove   = UIRef.PriorityComponent.Remove
        AICUI.S.OriginalPriorityMoveUp   = UIRef.PriorityComponent.MoveUp
        AICUI.S.OriginalPriorityMoveDown = UIRef.PriorityComponent.MoveDown
        
        function UIRef.PriorityComponent:Add(EntityName)
            if not AICProfile.S.ActiveProfileName then
                return false
            end
        
            local Changed = AICUI.S.OriginalPriorityAdd(self, EntityName)
        
            if Changed then
                AICUI.SyncPriorityState(true)
            end
        
            return Changed
        end
        
        function UIRef.PriorityComponent:Remove(EntityName)
            if not AICProfile.S.ActiveProfileName then
                return false
            end
        
            local Changed = AICUI.S.OriginalPriorityRemove(self, EntityName)
        
            if Changed then
                AICUI.SyncPriorityState(true)
            end
        
            return Changed
        end
        
        function UIRef.PriorityComponent:MoveUp(EntityName)
            if not AICProfile.S.ActiveProfileName then
                return
            end
        
            AICUI.S.OriginalPriorityMoveUp(self, EntityName)
            AICUI.SyncPriorityState(true)
        end
        
        function UIRef.PriorityComponent:MoveDown(EntityName)
            if not AICProfile.S.ActiveProfileName then
                return
            end
        
            AICUI.S.OriginalPriorityMoveDown(self, EntityName)
            AICUI.SyncPriorityState(true)
        end
        
        AICUI.S.AddPriorityTarget = function(EntityName)
            if not EntityName or EntityName == "" or AICUI.S.TargetPickerPlaceholders[EntityName] then
                return
            end
        
            if AICCombat.IsEntityInPriority(EntityName) then
                return
            end

            --// A player entry is accepted only while that player is still in
            --// the server, and never the local player.
            if AICCombat.IsPlayerTargetName(EntityName) then
                local OtherPlayer = Players:FindFirstChild(string.sub(EntityName, 2))

                if not OtherPlayer
                    or not OtherPlayer:IsA("Player")
                    or not AICCombat.IsTargetablePlayer(OtherPlayer)
                then
                    NotifyAction("Target Priority", "Player is not in this server")
                    AICUI.RefreshTargetDropdown()
                    return
                end
            end

            UIRef.PriorityComponent:Add(EntityName)
        end
        
        UIRef.TargetRefreshButton = UIRef.TargetSection:AddButton(
            "Refresh Detected Targets",
            function()
                AICUI.RefreshTargetDropdown()
            end
        )

        --// UI font, picked in Configuration and kept in the global file.
        if UI.SetFont then
            if CONFIG.UI_FONT ~= "" and not UI:SetFont(CONFIG.UI_FONT) then
                CONFIG.UI_FONT = ""
            end

            UI.OnFontChanged = function(Name)
                CONFIG.UI_FONT = Name
                AICProfile.WriteGlobalStore()
            end
        end

        --// Theme colours, also kept in the global file: only the keys that
        --// differ from the built-in theme are saved.
        if UI.SetTheme and UI._DefaultTheme then
            local Saved = {}

            for Key, Hex in pairs(CONFIG.UI_THEME) do
                local Ok, Color = pcall(Color3.fromHex, Hex)

                if Ok and UI.Theme[Key] ~= nil then
                    Saved[Key] = Color
                end
            end

            if next(Saved) then
                UI:SetTheme(Saved)
            end

            UI.OnThemeChanged = function(Theme)
                local Changed = {}

                for Key, Color in pairs(Theme) do
                    local Default = UI._DefaultTheme[Key]

                    if typeof(Color) == "Color3" and (typeof(Default) ~= "Color3" or Color:ToHex() ~= Default:ToHex()) then
                        Changed[Key] = Color:ToHex()
                    end
                end

                CONFIG.UI_THEME = Changed
                AICProfile.WriteGlobalStore()
            end
        end

        --// UI text scale, also kept in the global file.
        if UI.SetTextScale then
            if CONFIG.UI_TEXT_SCALE ~= 1 then
                CONFIG.UI_TEXT_SCALE = UI:SetTextScale(CONFIG.UI_TEXT_SCALE)
            end

            UI.OnTextScaleChanged = function(Scale)
                if CONFIG.UI_TEXT_SCALE == Scale then
                    return
                end

                CONFIG.UI_TEXT_SCALE = Scale
                AICProfile.WriteGlobalStore()
            end
        end

        --// Pinned items
        --// Lives outside the tabs so the panel can be dragged or popped out.
        UIRef.PinPanel = UI:AddPin("Pinned Items")

        --// Pins are global: restore them from their own file before any
        --// profile loads, and write every change back there.
        local StoredPinned = AICProfile.ReadPinnedState()

        if StoredPinned then
            AICProfile.S.HasGlobalPinnedState = true
            CONFIG.PINNED_STATE = StoredPinned
            UIRef.PinPanel:SetState(StoredPinned)
        end

        UIRef.PinnedSection = UIRef.StatusTab:AddSection("Pinned Items")

        --// The only way to show the panel again once its × closed it.
        UIRef.PinnedVisibleToggle = UIRef.PinnedSection:AddToggle("Show Pinned Items", UIRef.PinPanel.Visible, function(Value)
            UIRef.PinPanel:SetVisible(Value)
            CONFIG.PINNED_STATE = UIRef.PinPanel:GetState()
            AICProfile.QueuePinnedSave()
        end)

        UIRef.PinPanel.OnChanged = function()
            CONFIG.PINNED_STATE = UIRef.PinPanel:GetState()
            UIRef.PinnedVisibleToggle:Set(UIRef.PinPanel.Visible, false)
            AICProfile.QueuePinnedSave()
            AICProfile.QueueProfileSave()
        end

        UIRef.PinnedSection:AddButton("Reset Pinned Items Position", function()
            UIRef.PinPanel:ResetPosition()
            NotifyAction("Pinned Items", "Position reset")
        end)

        task.spawn(function()
            local PlayerStats = Player:WaitForChild("PlayerStats", 30)
            local Inventory = PlayerStats and PlayerStats:WaitForChild("Inventory", 30)

            if Inventory then
                UI:BindPinToValue(UIRef.PinPanel, Inventory)
            end
        end)

        --// Breaks ties between mobs of equal priority. Disabled keeps nearest first.
        UIRef.TargetTypeDropdown = UIRef.TargetSection:AddDropdown(
            "Target Type",
            { "Disabled", "Highest HP", "Lowest HP" },
            function(Value)
                CONFIG.TARGET_HP_MODE = tostring(Value or "Disabled")
                AICCombat.ResetTargetState()
                AICProfile.SaveActiveProfile()
            end
        )
        
        UIRef.TargetTypeDropdown:Set(tostring(CONFIG.TARGET_HP_MODE or "Disabled"), false)
        
        
        AICUI.RefreshTargetDropdown()
        
        AICUI.updateFeatureButtons()
        
        return {Name = "Bootstrap"}
    end,
}
