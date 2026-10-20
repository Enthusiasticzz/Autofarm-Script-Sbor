-- AutoBlock owns its state, blocking logic, whitelist, and UI.
return {
    Name = "AutoBlock",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local StarterGui = Services.StarterGui
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local Feature = Context.Feature
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICProfile = Context.AICProfile
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// Roblox adds a player to the block list as soon as Block is
        --// pressed, before its block request has gone through, and takes
        --// them off again if it fails. A hop waits until they have stayed
        --// blocked this long, so leaving cannot cut the request short.
        local BLOCK_SETTLE_SECONDS = 1.5

        local AutoBlock = {
            Name = "AutoBlock",
            IsFeature = true,
            Enabled = false,
            Button = nil,
            WhitelistComponent = nil,
            WhitelistBox = nil,
            WhitelistDropdown = nil,
        }

        AICFeature.S.BlockCache = AICFeature.S.BlockCache or {}
        --// UserId -> os.clock() when Auto Block first saw that intruder.
        AICFeature.S.IntruderSeenAt = {}
        --// UserId -> os.clock() when that player was first seen blocked.
        AICFeature.S.BlockedSince = {}
        AICFeature.S.BlockEnabled = Runtime:GetPlaceConfig().AUTOBLOCK == true
        AutoBlock.Enabled = AICFeature.S.BlockEnabled
        Feature.AutoBlock.Enabled = AutoBlock.Enabled

        function AutoBlock:SetEnabled(Value, Save)
            self.Enabled = Value == true
            AICFeature.S.BlockEnabled = self.Enabled
            Feature.AutoBlock.Enabled = self.Enabled

            if self.Button then
                self.Button:Set(self.Enabled, false)
            end

            if Save ~= false and AICProfile.SaveActiveProfile then
                AICProfile.SaveActiveProfile()
            end
        end

        --// Every hop in the farm (block, leave instead of block, server age)
        --// goes through here, so the Webhook report is posted before the
        --// client is moved and cannot be cut off by the teleport.
        function AutoBlock:TeleportToPlace(PlaceId)
            if AICFeature.ReportBeforeLeave then
                AICFeature.ReportBeforeLeave()
            end

            game:GetService("TeleportService"):Teleport(PlaceId or game.PlaceId, Player)
        end

        function AutoBlock:NormalizeUserId(Value)
            local Text = tostring(Value or ""):gsub("%s+", "")

            if Text == "" or not Text:match("^%d+$") then
                return nil
            end

            return Text
        end

        function AutoBlock:IsWhitelisted(UserId)
            local Id = self:NormalizeUserId(UserId)

            if not Id then
                return false
            end

            for _, Entry in ipairs(CONFIG.BLOCK_WHITELIST or {}) do
                if self:NormalizeUserId(Entry) == Id then
                    return true
                end
            end

            return false
        end

        --// Whether the checks that leave the server (Auto Block's hop from a
        --// blocked player, Leave On Danger Group) leave this player alone.
        --// Prompting a block always skips whitelisted players; only leaving
        --// follows Whitelist Skips Safety.
        function AutoBlock:IsSafetyExempt(UserId)
            return Feature.WhitelistSkipsSafety.Enabled == true and self:IsWhitelisted(UserId)
        end

        function AutoBlock:IsBlocked(UserId)
            local Success, BlockedUserIds = pcall(function()
                return StarterGui:GetCore("GetBlockedUserIds")
            end)

            if not Success or not BlockedUserIds then
                return false
            end

            for _, BlockedUserId in BlockedUserIds do
                if BlockedUserId == UserId then
                    return true
                end
            end

            return false
        end

        --// Whether the block on this player is done: on the block list,
        --// unbroken, for BLOCK_SETTLE_SECONDS, with Auto Confirm Block no
        --// longer working on their dialog. Ask every frame or poll; the
        --// clock starts the first time they are seen blocked.
        function AutoBlock:IsBlockSettled(OtherPlayer)
            local UserId = OtherPlayer.UserId

            if not self:IsBlocked(UserId) then
                AICFeature.S.BlockedSince[UserId] = nil
                return false
            end

            local now = os.clock()
            local Since = AICFeature.S.BlockedSince[UserId]

            if not Since then
                Since = now
                AICFeature.S.BlockedSince[UserId] = now
            end

            if AICFeature.IsConfirmingBlock and AICFeature.IsConfirmingBlock(OtherPlayer) then
                return false
            end

            return now - Since >= BLOCK_SETTLE_SECONDS
        end

        --// Block Delay: an intruder is acted on only once they have been
        --// seen for AUTO_BLOCK_DELAY seconds. The clock starts the first
        --// time this is asked about them and stops when they leave.
        function AutoBlock:IsBlockDelayOver(OtherPlayer)
            local Delay = math.max(tonumber(CONFIG.AUTO_BLOCK_DELAY) or 0, 0)
            local now = os.clock()
            local SeenAt = AICFeature.S.IntruderSeenAt[OtherPlayer.UserId]

            if not SeenAt then
                SeenAt = now
                AICFeature.S.IntruderSeenAt[OtherPlayer.UserId] = now
            end

            return now - SeenAt >= Delay
        end

        function AutoBlock:PromptBlockPlayer(OtherPlayer)
            local UserId = OtherPlayer.UserId

            if AICFeature.S.BlockCache[UserId] or self:IsBlocked(UserId) then
                return
            end

            --// Auto Confirm Block is still pressing the dialog already open
            --// for them; opening it again would pull it out from under it.
            if AICFeature.IsConfirmingBlock and AICFeature.IsConfirmingBlock(OtherPlayer) then
                return
            end

            AICFeature.S.BlockCache[UserId] = true

            local Success, ErrorMessage = pcall(function()
                StarterGui:SetCore("PromptBlockPlayer", OtherPlayer)
            end)

            if not Success then
                warn("PromptBlockPlayer failed:", ErrorMessage)
                AICFeature.S.BlockCache[UserId] = nil
                return
            end

            --// Auto Confirm Block presses Block in the dialog when it is on.
            if AICFeature.ConfirmBlockPrompt then
                AICFeature.ConfirmBlockPrompt(OtherPlayer)
            end

            task.delay(CONFIG.BLOCK_COOLDOWN, function()
                AICFeature.S.BlockCache[UserId] = nil
            end)
        end

        function AutoBlock:RefreshWhitelistPlayerDropdown()
            local Section = UIRef.BlockSection

            if not Section then
                return
            end

            table.clear(UIRef.WhitelistPlayerOptions)

            local Options = {}

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer ~= Player and not self:IsWhitelisted(OtherPlayer.UserId) then
                    local Label = string.format(
                        "%s (@%s)  %d",
                        OtherPlayer.DisplayName,
                        OtherPlayer.Name,
                        OtherPlayer.UserId
                    )

                    UIRef.WhitelistPlayerOptions[Label] = tostring(OtherPlayer.UserId)
                    table.insert(Options, Label)
                end
            end

            table.sort(Options, function(A, B)
                return string.lower(A) < string.lower(B)
            end)

            if #Options == 0 then
                Options = {"No other players"}
            end

            self.WhitelistDropdown = AICUI.ReplaceDropdown(
                UIRef.WhitelistPlayerDropdown,
                Section,
                "Add Player In Server",
                Options,
                function(Value)
                    local Id = UIRef.WhitelistPlayerOptions[Value]

                    if not Id or self:IsWhitelisted(Id) then
                        return
                    end

                    self.WhitelistComponent:Add(Id)
                    CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority
                    AICProfile.WriteGlobalStore()
                    NotifyAction("Whitelist", "Added " .. tostring(Value))
                    self:RefreshWhitelistPlayerDropdown()
                end
            )

            UIRef.WhitelistPlayerDropdown = self.WhitelistDropdown
        end

        function AutoBlock:RefreshUI()
            if self.WhitelistComponent then
                self.WhitelistComponent:SetPriority(table.clone(CONFIG.BLOCK_WHITELIST or {}))
            end

            self:SetEnabled(AICFeature.S.BlockEnabled == true, false)
            self:RefreshWhitelistPlayerDropdown()
        end

        function AutoBlock:CreateUI()
            local BlockSection = UIRef.BlockSection

            if not BlockSection then
                return
            end

            --// The alternative to blocking, kept above Auto Block and set
            --// apart by a divider: the same Block Delay, then the server is
            --// left without a block at all.
            AICUI.BindFeatureToggle("AutoBlockLeaveOnly", "Leave Instead Of Block", nil, BlockSection)

            BlockSection:AddDivider()

            self.Button = BlockSection:AddToggle(
                "Auto Block",
                self.Enabled,
                function(Value)
                    self:SetEnabled(Value)
                end
            )

            Feature.AutoBlock.Button = self.Button

            --// Auto Confirm Block belongs directly under Auto Block. Its own
            --// module starts after this one and would otherwise append its
            --// toggle to the end of the section, past the whitelist; the
            --// toggle is made here and that module supplies the behaviour.
            self.ConfirmButton = AICUI.BindFeatureToggle(
                "AutoBlockConfirm",
                "Auto Confirm Block",
                function(Value)
                    if AICFeature.OnAutoBlockConfirmChanged then
                        AICFeature.OnAutoBlockConfirmChanged(Value)
                    end
                end,
                BlockSection
            )

            UIRef.BlockDelaySlider = AICUI.AddSettingSlider(
                BlockSection, "Block Delay (s)", "AUTO_BLOCK_DELAY", true
            )

            AICUI.BindFeatureToggle("WhitelistSkipsSafety", "Whitelist Skips Safety", nil, BlockSection)
            BlockSection:AddLabel("On: whitelisted players never make Auto Block or Leave On Danger Group leave, even if blocked")
            BlockSection:AddLabel("Whitelist and Whitelist Skips Safety are shared by every profile")

            self.WhitelistComponent = BlockSection:AddPriority(
                "Block Whitelist",
                CONFIG.BLOCK_WHITELIST or {}
            )
            UIRef.BlockWhitelistComponent = self.WhitelistComponent
            AICUI.ShowUserNames(self.WhitelistComponent)
            CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority

            self.WhitelistBox = BlockSection:AddTextbox("User ID", "", function() end)
            UIRef.BlockWhitelistBox = self.WhitelistBox

            BlockSection:AddButton("Add User ID", function()
                local Id = self:NormalizeUserId(self.WhitelistBox:Get())

                if not Id then
                    NotifyAction("Whitelist", "Enter a numeric UserId")
                    return
                end

                if self:IsWhitelisted(Id) then
                    NotifyAction("Whitelist", Id .. " is already on the list")
                    return
                end

                self.WhitelistComponent:Add(Id)
                CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority
                self.WhitelistBox:Set("")
                AICProfile.WriteGlobalStore()
                NotifyAction("Whitelist", "Added " .. Id)
                self:RefreshWhitelistPlayerDropdown()
            end)

            BlockSection:AddButton("Refresh Player List", function()
                self:RefreshWhitelistPlayerDropdown()
            end)

            BlockSection:AddButton("Add Everyone Here", function()
                local Added = 0

                for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                    if OtherPlayer ~= Player and not self:IsWhitelisted(OtherPlayer.UserId) then
                        self.WhitelistComponent:Add(tostring(OtherPlayer.UserId))
                        Added += 1
                    end
                end

                CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority
                AICProfile.WriteGlobalStore()
                NotifyAction("Whitelist", "Added " .. tostring(Added) .. " player(s)")
                self:RefreshWhitelistPlayerDropdown()
            end)

            BlockSection:AddButton("Clear Whitelist", function()
                self.WhitelistComponent:SetPriority({})
                CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority
                AICProfile.WriteGlobalStore()
                NotifyAction("Whitelist", "Cleared")
                self:RefreshWhitelistPlayerDropdown()
            end)

            local OriginalRemove = self.WhitelistComponent.Remove
            local OriginalMoveUp = self.WhitelistComponent.MoveUp
            local OriginalMoveDown = self.WhitelistComponent.MoveDown

            local WhitelistComponent = self.WhitelistComponent

            function WhitelistComponent:Remove(Entry)
                local Changed = OriginalRemove(self, Entry)
                CONFIG.BLOCK_WHITELIST = self.Priority
                AICProfile.WriteGlobalStore()
                AutoBlock:RefreshWhitelistPlayerDropdown()
                return Changed
            end

            function WhitelistComponent:MoveUp(Entry)
                OriginalMoveUp(self, Entry)
                CONFIG.BLOCK_WHITELIST = self.Priority
                AICProfile.WriteGlobalStore()
            end

            function WhitelistComponent:MoveDown(Entry)
                OriginalMoveDown(self, Entry)
                CONFIG.BLOCK_WHITELIST = self.Priority
                AICProfile.WriteGlobalStore()
            end

            self:RefreshWhitelistPlayerDropdown()

            Context.Connect(Players.PlayerAdded, function()
                self:RefreshWhitelistPlayerDropdown()
            end)

            Context.Connect(Players.PlayerRemoving, function(OtherPlayer)
                --// Leaving and coming back starts the delay over.
                AICFeature.S.IntruderSeenAt[OtherPlayer.UserId] = nil
                AICFeature.S.BlockedSince[OtherPlayer.UserId] = nil

                task.defer(function()
                    self:RefreshWhitelistPlayerDropdown()
                end)
            end)

            -- Compatibility hooks for older combat/profile code.
            AICFeature.TeleportToPlace = function(PlaceId)
                return AutoBlock:TeleportToPlace(PlaceId)
            end
            AICFeature.NormalizeUserId = function(Value)
                return AutoBlock:NormalizeUserId(Value)
            end
            AICFeature.IsWhitelisted = function(UserId)
                return AutoBlock:IsWhitelisted(UserId)
            end
            AICFeature.IsSafetyExempt = function(UserId)
                return AutoBlock:IsSafetyExempt(UserId)
            end
            AICFeature.isBlocked = function(UserId)
                return AutoBlock:IsBlocked(UserId)
            end
            AICFeature.IsBlockSettled = function(OtherPlayer)
                return AutoBlock:IsBlockSettled(OtherPlayer)
            end
            AICFeature.promptBlockPlayer = function(OtherPlayer)
                return AutoBlock:PromptBlockPlayer(OtherPlayer)
            end
            AICFeature.IsBlockDelayOver = function(OtherPlayer)
                return AutoBlock:IsBlockDelayOver(OtherPlayer)
            end

            AICUI.RefreshWhitelistPlayerDropdown = function()
                return AutoBlock:RefreshWhitelistPlayerDropdown()
            end
        end

        function AutoBlock:Update()
            --// The player check runs inside the AutoFarming loop, after the
            --// Auto Farm and retreat gates, as it did in AFV2. Running it here
            --// too prompted twice and teleported with Auto Farm switched off.
        end

        AutoBlock:CreateUI()
        return AutoBlock
    end,
}
