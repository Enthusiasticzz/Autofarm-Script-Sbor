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

        --// One departure per session. A teleport or kick can fail without
        --// saying so, and the farm used to ask again on the very next frame:
        --// each ask posted another departure report and, after a kick, the
        --// farm kept running behind the disconnect screen. Departing is set
        --// on the first ask and cleared only by the script reloading in the
        --// next server, or by the watchdog of a hop that never happened;
        --// LeaveStarted records that the report went out, so a retry cannot
        --// post it twice; LeaveAttempts counts teleport tries, so a refused
        --// hop gets one retry and then gives up with a notice.
        AICFeature.S.Departing = false
        AICFeature.S.LeaveStarted = false
        AICFeature.S.LeaveAttempts = 0
        --// A leave asked for before the Block Delay ran out is waiting on
        --// its timer; only one such timer is ever scheduled.
        AICFeature.S.LeaveWaiting = false

        --// Seconds before a refused teleport is tried once more.
        local LEAVE_RETRY_DELAY = 10

        --// A leave the script starts on its own pauses a random 2-4 s first,
        --// so the client never drops the server the same instant a stranger
        --// appeared: short enough not to be noticed, long enough not to look
        --// like a machine answering a join. Random Leave Delay turns it off.
        local RANDOM_LEAVE_MIN = 2
        local RANDOM_LEAVE_MAX = 4

        --// A teleport that never happens leaves the client where it was. If
        --// this timer still runs, the hop did not take, so the latch is freed
        --// and the farm may try again - with no second report, because
        --// LeaveStarted stays set. A kick runs no such timer: it is decisive,
        --// and repeating it is what put the client through five kicks' worth
        --// of reports.
        local HOP_WATCHDOG = 20

        function AutoBlock:IsLeaving()
            return AICFeature.S.Departing == true
        end

        --// The departure report, posted once. False when one was already sent,
        --// so a retry or a second caller cannot report the same leave again.
        function AutoBlock:BeginLeave(OtherPlayer)
            if AICFeature.S.LeaveStarted then
                return false
            end

            AICFeature.S.LeaveStarted = true

            if AICFeature.ReportBeforeLeave then
                AICFeature.ReportBeforeLeave(OtherPlayer)
            end

            return true
        end

        --// The teleport itself, carrying out a departure that has already been
        --// reported. A refusal is retried once, later, and then dropped with a
        --// notice rather than being asked for again every frame.
        function AutoBlock:SendHop(Target)
            AICFeature.S.LeaveAttempts += 1

            local Success, Error = pcall(function()
                game:GetService("TeleportService"):Teleport(Target, Player)
            end)

            if Success then
                task.delay(HOP_WATCHDOG, function()
                    --// Still running means the hop never took, so this attempt
                    --// is over and the next one is a new departure: it may
                    --// report again, because the first end described a leave
                    --// that did not happen.
                    AICFeature.S.Departing = false
                    AICFeature.S.LeaveStarted = false
                end)

                return true
            end

            warn("[AutoBlock] Teleport failed:", Error)

            if AICFeature.S.LeaveAttempts >= 2 then
                NotifyAction("Auto Block", "Could not leave the server", 6)
                return false
            end

            task.delay(LEAVE_RETRY_DELAY, function()
                AutoBlock:SendHop(Target)
            end)

            return false
        end

        --// Every hop in the farm (block, server age) goes through here, so the
        --// Webhook report is posted before the client is moved and cannot be
        --// cut off by the teleport. A hop caused by a player names them in the
        --// report, so the log says who it was. Only the first hop of a session
        --// is made and reported; a later call is ignored.
        function AutoBlock:TeleportToPlace(PlaceId, OtherPlayer)
            if self:IsLeaving() then
                return false
            end

            AICFeature.S.Departing = true
            self:BeginLeave(OtherPlayer)

            return self:SendHop(PlaceId or game.PlaceId)
        end

        --// Someone on the Block Whitelist is never the reason the game is
        --// closed. Their presence is what the list is for, so Leave Instead
        --// Of Block leaves them alone even if they sit on Roblox's block
        --// list as well: it is the escape from a stranger, not from a name
        --// you chose to keep.
        function AutoBlock:IsLeaveExempt(OtherPlayer)
            return OtherPlayer ~= nil
                and OtherPlayer.UserId ~= nil
                and self:IsWhitelisted(OtherPlayer.UserId) == true
        end

        --// How long a leave the script starts should wait before it happens:
        --// the random 2-4 s pause while Random Leave Delay is on, nothing at
        --// all while it is off. Every leave path reads it, so nothing leaves
        --// the instant a stranger is noticed.
        function AutoBlock:LeaveDelay()
            if not Feature.RandomLeaveDelay or Feature.RandomLeaveDelay.Enabled ~= true then
                return 0
            end

            return RANDOM_LEAVE_MIN + math.random() * (RANDOM_LEAVE_MAX - RANDOM_LEAVE_MIN)
        end

        --// The rest of a wait nobody has to spend in a frame loop. When it
        --// runs out the leave is asked for again, so the game still closes
        --// even if the caller was the only one who wanted it, and it is the
        --// only ask that skips the wait (`Ready`): one pause per leave, not
        --// one per re-ask. A player who left, or is exempt by then, is left
        --// alone: there is nobody to leave for.
        function AutoBlock:WaitThenLeave(Reason, OtherPlayer, Wait)
            if AICFeature.S.LeaveWaiting then
                return false
            end

            AICFeature.S.LeaveWaiting = true

            task.delay(Wait, function()
                AICFeature.S.LeaveWaiting = false

                if OtherPlayer ~= nil
                    and (OtherPlayer.Parent ~= Players or self:IsLeaveExempt(OtherPlayer))
                then
                    return
                end

                self:LeaveGame(Reason, OtherPlayer, true)
            end)

            return true
        end

        --// Leave Instead Of Block's way out: not another server, the game
        --// itself. A kick is the only thing a client script can use to get
        --// back out to the Roblox app, and it reports first, naming whoever
        --// made us leave.
        function AutoBlock:LeaveGame(Reason, OtherPlayer, Ready)
            --// Refused silently: a caller that asks every frame must not be
            --// answered with a notification every frame.
            if self:IsLeaveExempt(OtherPlayer) then
                return false
            end

            if self:IsLeaving() then
                return false
            end

            --// Nothing leaves instantly. The wait is whichever is longer: the
            --// Block Delay still owed to the stranger, so the setting is
            --// honoured wherever the ask came from, or the random pause that
            --// keeps a leave from landing on the very frame they joined. An
            --// ask inside it waits on one timer and looks again when it runs
            --// out; `Ready` is that second look, and waits on nothing more.
            if Ready ~= true then
                local Wait = self:LeaveDelay()

                if OtherPlayer ~= nil then
                    Wait = math.max(Wait, self:BlockDelayRemaining(OtherPlayer))
                end

                if Wait > 0 then
                    self:WaitThenLeave(Reason, OtherPlayer, Wait)
                    return false
                end
            end

            AICFeature.S.Departing = true
            self:BeginLeave(OtherPlayer)

            local Text = Reason or "Auto Block: leaving the game"

            if OtherPlayer and OtherPlayer.Name then
                Text = Text .. " (@" .. tostring(OtherPlayer.Name) .. ")"
            end

            local Success = pcall(function()
                Player:Kick(Text)
            end)

            if Success then
                return true
            end

            --// The kick was refused: hop instead, with no second report, so
            --// the setting still gets the client out of the server.
            return self:SendHop(game.PlaceId)
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

        --// When Auto Block first saw this player: stamped the moment they
        --// arrived (Players.PlayerAdded in CreateUI), and on the first look
        --// at them for someone already here when the script loaded. One
        --// stamp per player per server, cleared when they leave.
        local function SeenAt(UserId)
            local Seen = AICFeature.S.IntruderSeenAt[UserId]

            if not Seen then
                Seen = os.clock()
                AICFeature.S.IntruderSeenAt[UserId] = Seen
            end

            return Seen
        end

        function AutoBlock:BlockDelay()
            return math.max(tonumber(CONFIG.AUTO_BLOCK_DELAY) or 0, 0)
        end

        --// Seconds of Block Delay still owed to this player. Zero or less
        --// means it has run out and they may be blocked or left for.
        function AutoBlock:BlockDelayRemaining(OtherPlayer)
            local Since = SeenAt(OtherPlayer.UserId)

            return self:BlockDelay() - (os.clock() - Since)
        end

        --// Block Delay: an intruder is acted on only once they have been
        --// here for AUTO_BLOCK_DELAY seconds. The clock starts on arrival,
        --// not on the decision, so a stranger is not rushed because the
        --// block or the leave was only asked about later.
        function AutoBlock:IsBlockDelayOver(OtherPlayer)
            return self:BlockDelayRemaining(OtherPlayer) <= 0
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
            --// apart by a divider: the same Block Delay, then the game is
            --// closed to the Roblox app without a block at all.
            AICUI.BindFeatureToggle("AutoBlockLeaveOnly", "Leave Instead Of Block", nil, BlockSection)
            BlockSection:AddLabel("On: the game is closed to the Roblox app once Block Delay (s) runs out")

            BlockSection:AddDivider()

            self.Button = BlockSection:AddToggle{
                Name = "Auto Block",
                Default = self.Enabled,
                Callback = function(Value)
                    self:SetEnabled(Value)
                end,
            }

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

            --// The pause every leave takes first, right under the delay it
            --// is added to. On by default: nothing the script does on its own
            --// should drop the server the moment a stranger appears.
            AICUI.BindFeatureToggle("RandomLeaveDelay", "Random Leave Delay", nil, BlockSection)
            BlockSection:AddLabel("On: every leave waits a random 2-4 s first, Follower Guard included")

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

            self.WhitelistBox = BlockSection:AddTextBox{
                Name = "User ID",
                Default = "",
                Callback = function() end,
            }
            UIRef.BlockWhitelistBox = self.WhitelistBox

            BlockSection:AddButton{
                Name = "Add User ID",
                Callback = function()
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
                end,
            }

            BlockSection:AddButton{
                Name = "Refresh Player List",
                Callback = function()
                    self:RefreshWhitelistPlayerDropdown()
                end,
            }

            BlockSection:AddButton{
                Name = "Add Everyone Here",
                Callback = function()
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
                end,
            }

            BlockSection:AddButton{
                Name = "Clear Whitelist",
                Callback = function()
                    self.WhitelistComponent:SetPriority({})
                    CONFIG.BLOCK_WHITELIST = self.WhitelistComponent.Priority
                    AICProfile.WriteGlobalStore()
                    NotifyAction("Whitelist", "Cleared")
                    self:RefreshWhitelistPlayerDropdown()
                end,
            }

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

            Context.Connect(Players.PlayerAdded, function(OtherPlayer)
                --// The Block Delay is counted from the moment they walk in,
                --// not from the next look at them, so a stranger is never
                --// acted on before the delay because the scan was late.
                if OtherPlayer ~= nil and OtherPlayer.UserId ~= nil then
                    SeenAt(OtherPlayer.UserId)
                end

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
            AICFeature.TeleportToPlace = function(PlaceId, OtherPlayer)
                return AutoBlock:TeleportToPlace(PlaceId, OtherPlayer)
            end
            AICFeature.LeaveGame = function(Reason, OtherPlayer)
                return AutoBlock:LeaveGame(Reason, OtherPlayer)
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
            AICFeature.BlockDelayRemaining = function(OtherPlayer)
                return AutoBlock:BlockDelayRemaining(OtherPlayer)
            end
            --// The random pause a leave takes first, for the other features
            --// that leave on their own (FollowerGuard, the Danger Group hop).
            AICFeature.LeaveDelay = function()
                return AutoBlock:LeaveDelay()
            end

            AICUI.RefreshWhitelistPlayerDropdown = function()
                return AutoBlock:RefreshWhitelistPlayerDropdown()
            end
        end

        function AutoBlock:Update()
            --// The player check runs inside the AutoFarming loop, after the
            --// Auto Farm and retreat gates, as it did in AFV2. Running it here
            --// too prompted twice and teleported with Auto Farm switched off.
            --//
            --// What is done here is dropping the stamps of players who are no
            --// longer in the server: a departure the script missed would
            --// otherwise be inherited by the same player coming back, and
            --// the Block Delay would count from the old visit - the leave
            --// then fires the moment they rejoin.
            if next(AICFeature.S.IntruderSeenAt) == nil then
                return
            end

            for UserId in pairs(AICFeature.S.IntruderSeenAt) do
                if Players:GetPlayerByUserId(UserId) == nil then
                    AICFeature.S.IntruderSeenAt[UserId] = nil
                    AICFeature.S.BlockedSince[UserId] = nil
                end
            end
        end

        AutoBlock:CreateUI()
        return AutoBlock
    end,
}
