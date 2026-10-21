-- ServerHop owns moving between servers and watching who is in this one,
-- ported from Iambatman:
--   Rejoin, Server Hop (a random public server with a free slot) and joining
--   a server by Job ID; reading the public server list for the browser;
--   Leave On Danger Group: when a member of any group in DANGER_GROUP_IDS
--   who is not on the Danger Whitelist (nor, with Whitelist Skips Safety on,
--   the Auto Block whitelist) is in the server, it blocks them and then
--   joins another public server (toggle, groups and whitelist are global,
--   not per profile); Join Alerts for players off the Auto Block whitelist;
--   and the Player Log of who joined and left.
-- ServerUI draws all of it on the Server tab.
return {
    Name = "ServerHop",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "AutoBlock"},

    Start = function(Context)
        local Services = Context.Services
        local Players = Services.Players
        local HttpService = Services.HttpService
        local TeleportService = game:GetService("TeleportService")
        local Player = Context.Player
        local Feature = Context.Feature
        local CONFIG = Context.CONFIG
        local AICFeature = Context.AICFeature
        local NotifyAction = Context.NotifyAction

        local DANGER_HOP_MAX_ATTEMPTS = 3
        local DANGER_HOP_RETRY_DELAY = 3
        --// How long a danger hop waits for the block to take before leaving
        --// anyway (time to press Block by hand when Auto Confirm Block is
        --// off), and how often it looks.
        local DANGER_BLOCK_WAIT = 10
        local DANGER_BLOCK_POLL = 0.25
        local GROUP_CHECK_MAX_ATTEMPTS = 3
        local GROUP_CHECK_RETRY_DELAY = 5
        --// Players are checked again this often, so a player taken off the
        --// whitelist, or a toggle switched on, is acted on.
        local SCAN_INTERVAL = 2
        --// Pages of the public server list a hop reads before giving up.
        local HOP_MAX_PAGES = 4
        local LOG_LIMIT = 100
        --// The same notice is not shown again within this.
        local NOTICE_COOLDOWN = 8
        --// One "could not check" notice at most this often, however many
        --// players' group checks fail (the details go to the console).
        local GROUP_CHECK_NOTICE_COOLDOWN = 60
        --// Join alerts arriving within this are shown as one notice.
        local JOIN_ALERT_BATCH_SECONDS = 1.5
        --// Names listed in one notice; the rest are counted.
        local JOIN_ALERT_MAX_NAMES = 4
        --// A player who leaves and comes back within this is not announced
        --// again.
        local JOIN_ALERT_REPEAT_SECONDS = 120
        local SERVER_LIST_URL = "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100"

        local ServerHop = {
            Name = "ServerHop",
            IsFeature = true,
            S = {
                Teleporting = false,
                --// A hop is reading the server list.
                Finding = false,
                Status = "IDLE",
                --// Notice key -> os.clock() it was last shown.
                NoticeAt = {},
                --// Join alerts waiting to be shown together.
                AlertQueue = {},
                AlertFlushScheduled = false,
                --// UserId -> the danger group ID they were found in.
                DangerUsers = {},
                --// Bumped when the group list changes, so a check that was
                --// asking about the old list is dropped.
                GroupListVersion = 0,
                CheckedUsers = {},
                CheckInFlight = {},
                CheckFailures = {},
                DangerHopStarted = false,
                DangerHopAttempts = 0,
                --// UserId -> os.clock() of their last join alert.
                AlertSeen = {},
                Log = {},
                --// Bumped on every log change, so the UI redraws only then.
                LogVersion = 0,
                Online = {},
                LastScan = 0,
                --// Set by the first Update, once the profile is loaded.
                Ready = false,
            },
        }

        local S = ServerHop.S

        --// The Auto Block whitelist, which Join Alerts goes by.
        local function IsWhitelisted(OtherPlayer)
            return AICFeature.IsWhitelisted ~= nil and AICFeature.IsWhitelisted(OtherPlayer.UserId) == true
        end

        --// Leave On Danger Group's own whitelist (CONFIG.DANGER_WHITELIST),
        --// global and separate from the Auto Block one.
        function ServerHop:IsDangerWhitelisted(UserId)
            local Id = tostring(UserId or ""):gsub("%s+", "")
            return table.find(CONFIG.DANGER_WHITELIST or {}, Id) ~= nil
        end

        local function SetStatus(Text)
            S.Status = Text
        end

        --// Every notice goes through here, so a repeat within Cooldown
        --// (NOTICE_COOLDOWN by default) is dropped. Key defaults to the
        --// title and message.
        local function Notify(Title, Message, Duration, Key, Cooldown)
            Key = Key or (Title .. "|" .. Message)

            local now = os.clock()

            if now - (S.NoticeAt[Key] or -math.huge) < (Cooldown or NOTICE_COOLDOWN) then
                return
            end

            S.NoticeAt[Key] = now
            NotifyAction(Title, Message, Duration)
        end

        function ServerHop:GetStatus()
            return S.Status
        end

        function ServerHop:IsDangerPlayer(OtherPlayer)
            return S.DangerUsers[tostring(OtherPlayer.UserId)] ~= nil
        end

        --// CONFIG.DANGER_GROUP_IDS as numbers.
        local function GetDangerGroupIds()
            local Ids = {}

            for _, Text in ipairs(CONFIG.DANGER_GROUP_IDS or {}) do
                local Id = tonumber(Text)

                if Id then
                    table.insert(Ids, Id)
                end
            end

            return Ids
        end

        --// The group list changed: everyone is asked again about the new one.
        function ServerHop:ResetGroupChecks()
            S.GroupListVersion += 1
            table.clear(S.DangerUsers)
            table.clear(S.CheckedUsers)
            table.clear(S.CheckInFlight)
            table.clear(S.CheckFailures)
            S.LastScan = 0
            S.LogVersion += 1
        end

        ------------------------------------------------------------------------
        --// Player Log
        ------------------------------------------------------------------------

        local function RecordLog(OtherPlayer, Event)
            if not OtherPlayer or OtherPlayer == Player then
                return
            end

            table.insert(S.Log, {
                Time = os.date("%H:%M:%S"),
                Event = Event,
                Name = OtherPlayer.Name,
                UserId = tostring(OtherPlayer.UserId),
            })

            while #S.Log > LOG_LIMIT do
                table.remove(S.Log, 1)
            end

            S.LogVersion += 1
        end

        --// Newest first.
        function ServerHop:GetLog()
            local Result = {}

            for Index = #S.Log, 1, -1 do
                table.insert(Result, S.Log[Index])
            end

            return Result
        end

        function ServerHop:ClearLog()
            table.clear(S.Log)
            S.LogVersion += 1
        end

        ------------------------------------------------------------------------
        --// Teleports
        ------------------------------------------------------------------------

        local function TeleportToInstance(JobId, Status, OnFailed)
            if S.Teleporting then
                return false
            end

            S.Teleporting = true
            SetStatus(Status)

            task.spawn(function()
                --// The Webhook report goes while the client is still here.
                if AICFeature.ReportBeforeLeave then
                    AICFeature.ReportBeforeLeave()
                end

                local Success, Error = pcall(function()
                    TeleportService:TeleportToPlaceInstance(game.PlaceId, JobId, Player)
                end)

                if not Success then
                    S.Teleporting = false
                    SetStatus("TELEPORT FAILED")
                    Notify("SERVER", tostring(Error), 6)

                    if OnFailed then
                        OnFailed(tostring(Error))
                    end
                end
            end)

            return true
        end

        function ServerHop:Rejoin()
            local JobId = tostring(game.JobId or "")

            if JobId == "" then
                Notify("SERVER", "This server has no Job ID, so Rejoin is unavailable", 4)
                return false
            end

            Notify("SERVER", "Rejoining this server...")
            return TeleportToInstance(JobId, "REJOINING")
        end

        function ServerHop:Join(JobId)
            JobId = tostring(JobId or ""):gsub("%s+", "")

            if JobId == "" or JobId == game.JobId then
                Notify("SERVER", "That Job ID is empty or is this server", 4)
                return false
            end

            return TeleportToInstance(JobId, "JOINING SERVER")
        end

        --// One page of public servers with a free slot, other than this one.
        --// Returns the servers and the next page's cursor, or nil and an error.
        function ServerHop:ReadPublicServers(Cursor)
            local Url = string.format(SERVER_LIST_URL, game.PlaceId)

            if type(Cursor) == "string" and Cursor ~= "" then
                Url ..= "&cursor=" .. HttpService:UrlEncode(Cursor)
            end

            local Success, Body = pcall(function()
                return game:HttpGet(Url)
            end)

            if not Success then
                return nil, nil, Body
            end

            local Decoded, Payload = pcall(function()
                return HttpService:JSONDecode(Body)
            end)

            if not Decoded or type(Payload) ~= "table" or type(Payload.data) ~= "table" then
                return nil, nil, "The public server list response was invalid"
            end

            local Servers = {}

            for _, Server in ipairs(Payload.data) do
                local Playing = tonumber(Server.playing)
                local MaxPlayers = tonumber(Server.maxPlayers)

                if type(Server.id) == "string" and Server.id ~= game.JobId
                    and Playing and MaxPlayers and Playing < MaxPlayers
                then
                    table.insert(Servers, {
                        Id = Server.id,
                        Playing = Playing,
                        MaxPlayers = MaxPlayers,
                        Ping = tonumber(Server.ping),
                        FPS = tonumber(Server.fps),
                    })
                end
            end

            local NextCursor = type(Payload.nextPageCursor) == "string" and Payload.nextPageCursor or nil
            return Servers, NextCursor
        end

        --// The Job ID of a random public server with a free slot other than
        --// this one, or nil and why (nil error: there is none). Yields.
        local function FindOtherServer()
            local Cursor

            for _ = 1, HOP_MAX_PAGES do
                local Servers, NextCursor, ReadError = ServerHop:ReadPublicServers(Cursor)

                if not Servers then
                    return nil, ReadError
                end

                if #Servers > 0 then
                    return Servers[math.random(1, #Servers)].Id
                end

                Cursor = NextCursor

                if not Cursor then
                    break
                end
            end

            return nil, nil
        end

        --// Finds another public server and joins it. OnFailed is called when
        --// a hop was started but could not be carried out -- the server list
        --// could not be read, no other server had a free slot, or the
        --// teleport was refused -- so a caller that has to get out of this
        --// server can fall back to stopping the farm.
        --// Returns false when another hop is already on its way: that is
        --// still leaving, for somebody else's reason.
        function ServerHop:Hop(OnFailed)
            --// A second press while one is finding or teleporting does nothing.
            if S.Teleporting or S.Finding then
                return false
            end

            S.Finding = true
            SetStatus("FINDING SERVER")

            task.spawn(function()
                local Target, Error = FindOtherServer()

                S.Finding = false

                if Target then
                    Notify("SERVER HOP", "Joining another public server...")
                    TeleportToInstance(Target, "HOPPING", OnFailed)
                elseif Error then
                    SetStatus("HOP FAILED")
                    Notify("SERVER HOP", "Could not read the server list: " .. tostring(Error), 6)

                    if OnFailed then
                        OnFailed(tostring(Error))
                    end
                else
                    SetStatus("NO OTHER SERVER")
                    Notify("SERVER HOP", "No other public server with a free slot was found", 6)

                    if OnFailed then
                        OnFailed("no other server with a free slot")
                    end
                end
            end)

            return true
        end

        ------------------------------------------------------------------------
        --// Leave On Danger Group
        ------------------------------------------------------------------------

        --// Whitelist Skips Safety also exempts the Auto Block whitelist.
        local function IsSafetyExempt(OtherPlayer)
            return AICFeature.IsSafetyExempt ~= nil and AICFeature.IsSafetyExempt(OtherPlayer.UserId) == true
        end

        local function ShouldLeaveFor(OtherPlayer)
            return Feature.DangerGroupHop.Enabled
                and OtherPlayer.Parent == Players
                and ServerHop:IsDangerPlayer(OtherPlayer)
                and not ServerHop:IsDangerWhitelisted(OtherPlayer.UserId)
                and not IsSafetyExempt(OtherPlayer)
        end

        local function IsBlocked(OtherPlayer)
            return AICFeature.isBlocked ~= nil and AICFeature.isBlocked(OtherPlayer.UserId) == true
        end

        --// Auto Block's check that the block has gone through, not just
        --// shown up on the list.
        local function IsBlockSettled(OtherPlayer)
            if AICFeature.IsBlockSettled then
                return AICFeature.IsBlockSettled(OtherPlayer) == true
            end

            return IsBlocked(OtherPlayer)
        end

        --// Blocks the player through Auto Block's prompt (Auto Confirm Block
        --// presses it when on) and waits, at most DANGER_BLOCK_WAIT, for the
        --// block to go through. Roblox does not put us in a server with
        --// someone we blocked, so without this a hop can land straight back
        --// here. True when they are blocked. Yields.
        local function BlockBeforeLeaving(OtherPlayer)
            if not IsBlocked(OtherPlayer) then
                if not AICFeature.promptBlockPlayer then
                    return false
                end

                SetStatus("BLOCKING @" .. OtherPlayer.Name .. " (DANGER GROUP)")
                AICFeature.promptBlockPlayer(OtherPlayer)
            end

            local Deadline = os.clock() + DANGER_BLOCK_WAIT

            while os.clock() < Deadline and OtherPlayer.Parent == Players do
                if IsBlockSettled(OtherPlayer) then
                    return true
                end

                --// Taken off the list again (the block failed): ask again.
                if not IsBlocked(OtherPlayer) and AICFeature.promptBlockPlayer then
                    AICFeature.promptBlockPlayer(OtherPlayer)
                end

                task.wait(DANGER_BLOCK_POLL)
            end

            return IsBlockSettled(OtherPlayer)
        end

        --// Blocks the danger player first, then joins another public server
        --// from the list, so it cannot be this one. Without a readable list
        --// it lets Roblox pick a server instead.
        local function LeaveFor(OtherPlayer)
            if S.DangerHopStarted
                or S.DangerHopAttempts >= DANGER_HOP_MAX_ATTEMPTS
                or not ShouldLeaveFor(OtherPlayer)
            then
                return
            end

            S.DangerHopStarted = true
            S.DangerHopAttempts += 1
            S.Teleporting = true

            if S.DangerHopAttempts == 1 then
                local GroupId = S.DangerUsers[tostring(OtherPlayer.UserId)]
                Notify("DANGER", string.format("@%s is in group %s. Blocking, then leaving this server.", OtherPlayer.Name, tostring(GroupId)), 7)
            end

            task.spawn(function()
                --// Nothing leaves the instant a Danger Group member is
                --// spotted: the same random 2-4 s pause every other leave
                --// takes runs first (Random Leave Delay), and what was
                --// decided before it is looked at again after it.
                local Wait = AICFeature.LeaveDelay and AICFeature.LeaveDelay() or 0

                if Wait > 0 then
                    task.wait(Wait)

                    if OtherPlayer.Parent ~= Players or not ShouldLeaveFor(OtherPlayer) then
                        S.DangerHopAttempts = math.max(S.DangerHopAttempts - 1, 0)
                        S.DangerHopStarted = false
                        S.Teleporting = false
                        SetStatus("IDLE")
                        return
                    end
                end

                local Blocked = BlockBeforeLeaving(OtherPlayer)

                --// They left while we waited: nothing to leave for any more.
                --// Not a failed hop, so it does not use up an attempt.
                if OtherPlayer.Parent ~= Players then
                    S.DangerHopAttempts = math.max(S.DangerHopAttempts - 1, 0)
                    S.DangerHopStarted = false
                    S.Teleporting = false
                    SetStatus("IDLE")
                    return
                end

                if not Blocked then
                    Notify("DANGER", "@" .. OtherPlayer.Name .. " is not blocked yet; leaving anyway", 6)
                end

                SetStatus("LEAVING (DANGER GROUP)")

                --// Report before the hop, like every other leave, naming the
                --// player whose group made us leave.
                if AICFeature.ReportBeforeLeave then
                    AICFeature.ReportBeforeLeave(OtherPlayer)
                end

                local Target = FindOtherServer()

                local Success, Error = pcall(function()
                    if Target then
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, Target, Player)
                    else
                        TeleportService:Teleport(game.PlaceId, Player)
                    end
                end)

                if Success then
                    return
                end

                warn("[ServerHop] Danger group hop failed:", Error)
                S.DangerHopStarted = false
                S.Teleporting = false

                if S.DangerHopAttempts < DANGER_HOP_MAX_ATTEMPTS then
                    task.delay(DANGER_HOP_RETRY_DELAY, LeaveFor, OtherPlayer)
                else
                    SetStatus("TELEPORT FAILED")
                    Notify("DANGER", "Teleport failed after " .. DANGER_HOP_MAX_ATTEMPTS .. " attempts", 7)
                end
            end)
        end

        --// IsInGroupAsync where the client has it, IsInGroup otherwise. Errors
        --// from the second reach the caller's pcall.
        local function IsInGroup(OtherPlayer, GroupId)
            local Success, IsMember = pcall(function()
                return OtherPlayer:IsInGroupAsync(GroupId)
            end)

            if Success then
                return IsMember
            end

            return OtherPlayer:IsInGroup(GroupId)
        end

        --// The first of GroupIds the player is in, or nil.
        local function FindDangerGroup(OtherPlayer, GroupIds)
            for _, GroupId in ipairs(GroupIds) do
                if IsInGroup(OtherPlayer, GroupId) then
                    return GroupId
                end
            end

            return nil
        end

        --// Group membership is asked once per player; the answer is kept for
        --// as long as they are in the server.
        local function CheckDangerGroup(OtherPlayer)
            if OtherPlayer == Player or OtherPlayer.Parent ~= Players then
                return
            end

            local UserId = tostring(OtherPlayer.UserId)

            if S.DangerUsers[UserId] then
                LeaveFor(OtherPlayer)
                return
            end

            if S.CheckedUsers[UserId] or S.CheckInFlight[UserId] then
                return
            end

            local GroupIds = GetDangerGroupIds()

            if #GroupIds == 0 then
                return
            end

            S.CheckInFlight[UserId] = true

            local Version = S.GroupListVersion

            task.spawn(function()
                local Success, GroupId = pcall(FindDangerGroup, OtherPlayer, GroupIds)

                --// The group list changed while asking: the scan asks again.
                if Version ~= S.GroupListVersion then
                    return
                end

                if not Success then
                    S.CheckFailures[UserId] = (S.CheckFailures[UserId] or 0) + 1
                    warn("[ServerHop] Group check failed for @" .. OtherPlayer.Name .. ":", GroupId)

                    --// Not marked checked: a scan after the retry delay asks
                    --// again, until the last attempt has failed.
                    if S.CheckFailures[UserId] >= GROUP_CHECK_MAX_ATTEMPTS then
                        S.CheckedUsers[UserId] = true
                        Notify("GROUP CHECK", "Could not check @" .. OtherPlayer.Name .. " after " .. GROUP_CHECK_MAX_ATTEMPTS .. " tries", 7,
                            "GROUP CHECK", GROUP_CHECK_NOTICE_COOLDOWN)
                    else
                        task.wait(GROUP_CHECK_RETRY_DELAY)
                    end

                    S.CheckInFlight[UserId] = nil
                    return
                end

                S.CheckInFlight[UserId] = nil
                S.CheckFailures[UserId] = nil
                S.CheckedUsers[UserId] = true

                if GroupId and OtherPlayer.Parent == Players then
                    S.DangerUsers[UserId] = GroupId
                    S.LogVersion += 1
                    LeaveFor(OtherPlayer)
                end
            end)
        end

        ------------------------------------------------------------------------
        --// Join Alerts
        ------------------------------------------------------------------------

        --// "@a, @b, @c, @d and 2 more"
        local function ListNames(Names)
            local Shown = {}

            for Index = 1, math.min(#Names, JOIN_ALERT_MAX_NAMES) do
                Shown[Index] = Names[Index]
            end

            local Text = table.concat(Shown, ", ")

            if #Names > JOIN_ALERT_MAX_NAMES then
                Text ..= string.format(" and %d more", #Names - JOIN_ALERT_MAX_NAMES)
            end

            return Text
        end

        --// Shows the queued alerts as at most two notices: who joined, and
        --// who was already here. Anyone who left or was whitelisted while
        --// queued, or Join Alerts switched off meanwhile, is dropped.
        local function FlushJoinAlerts()
            S.AlertFlushScheduled = false

            local Queue = S.AlertQueue
            S.AlertQueue = {}

            if not Feature.JoinAlerts.Enabled then
                return
            end

            local Joined, Here = {}, {}

            for _, Entry in ipairs(Queue) do
                if Entry.Player.Parent == Players and not IsWhitelisted(Entry.Player) then
                    table.insert(Entry.WasAlreadyHere and Here or Joined, "@" .. Entry.Player.Name)
                end
            end

            if #Joined == 1 then
                NotifyAction("PLAYER JOINED", Joined[1] .. " joined the server", 6)
            elseif #Joined > 1 then
                NotifyAction("PLAYERS JOINED", string.format("%d players joined: %s", #Joined, ListNames(Joined)), 6)
            end

            if #Here == 1 then
                NotifyAction("PLAYER ALREADY HERE", Here[1] .. " is already in this server", 6)
            elseif #Here > 1 then
                NotifyAction("PLAYERS ALREADY HERE", string.format("%d players off the whitelist are here: %s", #Here, ListNames(Here)), 6)
            end
        end

        --// Force skips the repeat window, for a fresh look at who is here.
        local function AlertIfStranger(OtherPlayer, WasAlreadyHere, Force)
            if OtherPlayer == Player or not Feature.JoinAlerts.Enabled or IsWhitelisted(OtherPlayer) then
                return
            end

            local UserId = tostring(OtherPlayer.UserId)
            local now = os.clock()

            if not Force and now - (S.AlertSeen[UserId] or -math.huge) < JOIN_ALERT_REPEAT_SECONDS then
                return
            end

            S.AlertSeen[UserId] = now
            table.insert(S.AlertQueue, { Player = OtherPlayer, WasAlreadyHere = WasAlreadyHere })

            if not S.AlertFlushScheduled then
                S.AlertFlushScheduled = true
                task.delay(JOIN_ALERT_BATCH_SECONDS, FlushJoinAlerts)
            end
        end

        --// Join Alerts switched on, or loaded on: everyone already here, in
        --// one notice.
        function ServerHop:ScanJoinAlerts()
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                AlertIfStranger(OtherPlayer, true, true)
            end
        end

        ------------------------------------------------------------------------

        local function OnPlayerAdded(OtherPlayer, WasAlreadyHere)
            if OtherPlayer == Player then
                return
            end

            local UserId = tostring(OtherPlayer.UserId)

            if not S.Online[UserId] then
                S.Online[UserId] = true
                RecordLog(OtherPlayer, WasAlreadyHere and "present" or "joined")
            end

            task.defer(AlertIfStranger, OtherPlayer, WasAlreadyHere)

            --// Before the first Update the profile, and with it the
            --// whitelist, is not loaded yet; that scan covers everyone.
            if S.Ready then
                CheckDangerGroup(OtherPlayer)
            end
        end

        Context.Connect(Players.PlayerAdded, function(OtherPlayer)
            OnPlayerAdded(OtherPlayer, false)
        end)

        Context.Connect(Players.PlayerRemoving, function(OtherPlayer)
            local UserId = tostring(OtherPlayer.UserId)

            if S.Online[UserId] then
                RecordLog(OtherPlayer, "left")
            end

            --// AlertSeen is kept, so leaving and coming straight back is not
            --// announced twice.
            S.Online[UserId] = nil
            S.CheckedUsers[UserId] = nil
            S.CheckFailures[UserId] = nil
        end)

        for _, OtherPlayer in ipairs(Players:GetPlayers()) do
            OnPlayerAdded(OtherPlayer, true)
        end

        Context.Connect(TeleportService.TeleportInitFailed, function(Who, _, ErrorMessage)
            --// Auto Block and Party System teleport too, and report their own
            --// failures; only a teleport of ours is reported here.
            if Who ~= Player or not (S.Teleporting or S.DangerHopStarted) then
                return
            end

            S.Teleporting = false
            SetStatus("TELEPORT FAILED")
            Notify("SERVER", tostring(ErrorMessage or "Teleport failed"), 6)

            --// A failed danger hop tries again on the next scan.
            S.DangerHopStarted = false
        end)

        function ServerHop:Update()
            local now = os.clock()

            if now - S.LastScan < SCAN_INTERVAL then
                return
            end

            S.LastScan = now

            --// A profile that loaded with Join Alerts on: everyone already here.
            if not S.Ready and Feature.JoinAlerts.Enabled then
                ServerHop:ScanJoinAlerts()
            end

            S.Ready = true

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                CheckDangerGroup(OtherPlayer)
            end
        end

        return ServerHop
    end,
}
