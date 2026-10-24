-- ServerUI owns the Server tab, ported from Iambatman's Server page, status
-- card, server info panel and join log: this server's players, place, Job
-- ID, FPS and ping; Rejoin, Server Hop, Copy Job ID and Join Job ID; the
-- Leave On Danger Group and Join Alerts toggles; the Player Log; and the
-- Server Browser window listing public servers. ServerHop does the work.
return {
    Name = "ServerUI",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components", "ServerHop", "Floating"},

    Start = function(Context)
        local UI = Context.UI
        local UIRef = Context.UIRef
        local CONFIG = Context.CONFIG
        local AICUI = Context.AICUI
        local AICProfile = Context.AICProfile
        local Services = Context.Services
        local Players = Services.Players
        local Player = Context.Player
        local NotifyAction = Context.NotifyAction
        local ServerHop = Context.ServerHop
        local Floating = Context.Floating

        local New, Label, Button = Floating.New, Floating.Label, Floating.Button
        local ClearChildren = Floating.ClearChildren

        local INFO_INTERVAL = 1
        local LOG_SHOWN = 15
        local WINDOW_WIDTH = 600
        local WINDOW_HEIGHT = 420
        --// Share of the window the server list takes; the details get the rest.
        local LIST_WIDTH_SCALE = 0.5
        local ROW_HEIGHT = 40
        --// FPS and ping colour bands, as in Iambatman.
        local FPS_GOOD, FPS_OK = 50, 30
        local PING_GOOD, PING_OK = 100, 200

        local Module = {
            Name = "ServerUI",
            IsFeature = true,
            S = {
                LastInfo = 0,
                FrameCount = 0,
                FrameTime = 0,
                FPS = nil,
                PlaceName = "Place " .. tostring(game.PlaceId),
                LogLabels = {},
                LogVersion = -1,
                --// Server Browser
                Built = false,
                Servers = {},
                Cursor = nil,
                Loading = false,
                Selected = nil,
            },
        }

        local S = Module.S
        local Window, ListScroll, DetailScroll, StatusLabel, RefreshButton, MoreButton

        task.spawn(function()
            local Success, Info = pcall(function()
                return Services.MarketplaceService:GetProductInfo(game.PlaceId)
            end)

            if Success and type(Info) == "table" and Info.Name then
                S.PlaceName = Info.Name
            end
        end)

        local function ShortJobId(JobId)
            JobId = tostring(JobId or "")

            if #JobId > 18 then
                return JobId:sub(1, 8) .. "..." .. JobId:sub(-6)
            end

            return JobId ~= "" and JobId or "-"
        end

        local function GetPingMs()
            local Success, Seconds = pcall(function()
                return Player:GetNetworkPing()
            end)

            return Success and type(Seconds) == "number" and math.floor(Seconds * 1000 + 0.5) or nil
        end

        local function CopyJobId(JobId)
            if JobId == "" then
                NotifyAction("SERVER", "This server has no Job ID", 3)
            elseif Floating.CopyText(JobId) then
                NotifyAction("SERVER", "Job ID copied")
            else
                NotifyAction("SERVER", "Copy is not available here. Job ID: " .. JobId, 8)
            end
        end

        --// The current server as a server list entry.
        local function CurrentServerEntry()
            return {
                Id = tostring(game.JobId or ""),
                Playing = #Players:GetPlayers(),
                MaxPlayers = Players.MaxPlayers,
                Ping = GetPingMs(),
                FPS = S.FPS,
                IsCurrent = true,
            }
        end

        ------------------------------------------------------------------------
        --// Current Server
        ------------------------------------------------------------------------

        local Section = UIRef.ServerSection

        UIRef.ServerPlayersLabel = Section:AddLabel("PLAYERS  0")
        UIRef.ServerJobLabel = Section:AddLabel("JOB ID  -")
        UIRef.ServerFPSLabel = Section:AddLabel("FPS  --")
        UIRef.ServerPingLabel = Section:AddLabel("PING  -- MS")
        UIRef.ServerStatusLabel = Section:AddLabel("STATUS  IDLE")

        Section:AddButton("Rejoin", function()
            ServerHop:Rejoin()
        end)

        Section:AddButton("Server Hop", function()
            ServerHop:Hop()
        end)

        Section:AddButton("Copy Job ID", function()
            CopyJobId(tostring(game.JobId or ""))
        end)

        UIRef.JoinJobIdBox = Section:AddTextbox("Job ID", "", function() end)

        Section:AddButton("Join Job ID", function()
            ServerHop:Join(UIRef.JoinJobIdBox:Get())
        end)

        Section:AddButton("Open Server Browser", function()
            Module:ToggleBrowser()
        end)

        ------------------------------------------------------------------------
        --// Server Safety
        ------------------------------------------------------------------------

        local SafetySection = UIRef.ServerSafetySection

        AICUI.BindFeatureToggle("DangerGroupHop", "Leave On Danger Group", function()
            ServerHop.S.LastScan = 0
        end, SafetySection)

        SafetySection:AddLabel("Leaves if a Danger Group member is here (Danger Whitelist exempt; Block Whitelist too with Whitelist Skips Safety)")
        SafetySection:AddLabel("Toggle, groups and whitelist are shared by every profile")

        --// A list of IDs kept in CONFIG[Key] and the global file. Removing
        --// or reordering a row saves too; OnChanged runs after every save.
        --// Returns the list and its save function.
        local function AddGlobalIdList(Title, Key, OnChanged)
            local List = SafetySection:AddPriority(Title, CONFIG[Key] or {})
            CONFIG[Key] = List.Priority

            local function Save()
                CONFIG[Key] = List.Priority
                AICProfile.WriteGlobalStore()

                if OnChanged then
                    OnChanged()
                end
            end

            local OriginalRemove = List.Remove
            local OriginalMoveUp = List.MoveUp
            local OriginalMoveDown = List.MoveDown

            function List:Remove(Entry)
                local Changed = OriginalRemove(self, Entry)
                Save()
                return Changed
            end

            function List:MoveUp(Entry)
                OriginalMoveUp(self, Entry)
                Save()
            end

            function List:MoveDown(Entry)
                OriginalMoveDown(self, Entry)
                Save()
            end

            return List, Save
        end

        --// Groups whose members Leave On Danger Group leaves for.
        local DangerGroups, SaveDangerGroups = AddGlobalIdList("Danger Groups", "DANGER_GROUP_IDS", function()
            ServerHop:ResetGroupChecks()
        end)

        local DangerGroupBox = SafetySection:AddTextbox("Group ID", "", function() end)

        SafetySection:AddButton("Add Group ID", function()
            local Id = tostring(DangerGroupBox:Get() or ""):gsub("%s+", "")

            if not Id:match("^%d+$") then
                NotifyAction("Danger Groups", "Enter a numeric group ID")
                return
            end

            if table.find(CONFIG.DANGER_GROUP_IDS or {}, Id) then
                NotifyAction("Danger Groups", Id .. " is already on the list")
                return
            end

            DangerGroups:Add(Id)
            SaveDangerGroups()
            DangerGroupBox:Set("")
            NotifyAction("Danger Groups", "Added group " .. Id)
        end)

        --// Players Leave On Danger Group stays for, separate from the Auto
        --// Block whitelist.
        local DangerPlayerOptions = {}
        local DangerPlayerDropdown
        local RefreshDangerPlayerDropdown

        local DangerWhitelist, SaveDangerWhitelist = AddGlobalIdList("Danger Whitelist", "DANGER_WHITELIST", function()
            --// Someone taken off the list is acted on at the next frame.
            ServerHop.S.LastScan = 0
            task.defer(RefreshDangerPlayerDropdown)
        end)

        AICUI.ShowUserNames(DangerWhitelist)

        local function AddDangerWhitelist(UserId, Label)
            if ServerHop:IsDangerWhitelisted(UserId) then
                NotifyAction("Danger Whitelist", tostring(Label) .. " is already on the list")
                return false
            end

            DangerWhitelist:Add(UserId)
            SaveDangerWhitelist()
            NotifyAction("Danger Whitelist", "Added " .. tostring(Label))
            return true
        end

        --// DangerPlayerOptions maps each label to its UserId text.
        function RefreshDangerPlayerDropdown()
            table.clear(DangerPlayerOptions)

            local Options = {}

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if OtherPlayer ~= Player and not ServerHop:IsDangerWhitelisted(OtherPlayer.UserId) then
                    local Text = string.format("%s (@%s)  %d", OtherPlayer.DisplayName, OtherPlayer.Name, OtherPlayer.UserId)
                    DangerPlayerOptions[Text] = tostring(OtherPlayer.UserId)
                    table.insert(Options, Text)
                end
            end

            table.sort(Options, function(A, B)
                return string.lower(A) < string.lower(B)
            end)

            if #Options == 0 then
                Options = {"No other players"}
            end

            --// A new dropdown is appended to the section, so it takes the
            --// old one's slot to keep its place in the list.
            local Order = DangerPlayerDropdown and DangerPlayerDropdown.Frame and DangerPlayerDropdown.Frame.LayoutOrder

            if DangerPlayerDropdown then
                if DangerPlayerDropdown.Popup then
                    DangerPlayerDropdown.Popup:Destroy()
                end

                if DangerPlayerDropdown.Frame then
                    DangerPlayerDropdown.Frame:Destroy()
                end
            end

            DangerPlayerDropdown = SafetySection:AddDropdown("Add Player In Server", Options, function(Value)
                local Id = DangerPlayerOptions[Value]

                if Id then
                    AddDangerWhitelist(Id, Value)
                end
            end)

            if Order and DangerPlayerDropdown.Frame then
                DangerPlayerDropdown.Frame.LayoutOrder = Order
            end
        end

        RefreshDangerPlayerDropdown()

        local DangerWhitelistBox = SafetySection:AddTextbox("User ID", "", function() end)

        SafetySection:AddButton("Add User ID", function()
            local Id = tostring(DangerWhitelistBox:Get() or ""):gsub("%s+", "")

            if not Id:match("^%d+$") then
                NotifyAction("Danger Whitelist", "Enter a numeric UserId")
                return
            end

            if AddDangerWhitelist(Id, Id) then
                DangerWhitelistBox:Set("")
            end
        end)

        SafetySection:AddButton("Clear Danger Whitelist", function()
            DangerWhitelist:SetPriority({})
            SaveDangerWhitelist()
            NotifyAction("Danger Whitelist", "Cleared")
        end)

        Context.Connect(Players.PlayerAdded, function()
            RefreshDangerPlayerDropdown()
        end)

        Context.Connect(Players.PlayerRemoving, function()
            task.defer(RefreshDangerPlayerDropdown)
        end)

        AICUI.BindFeatureToggle("JoinAlerts", "Join Alerts", function(Enabled)
            if Enabled then
                ServerHop:ScanJoinAlerts()
            end
        end, SafetySection)

        SafetySection:AddLabel("Notifies about players off the Auto Block whitelist")

        ------------------------------------------------------------------------
        --// Player Log
        ------------------------------------------------------------------------

        local LogSection = UIRef.ServerLogSection

        LogSection:AddButton("Clear Log", function()
            ServerHop:ClearLog()
        end)

        local function DescribeLogEntry(Entry)
            local Tags = ""
            local OtherPlayer = Players:GetPlayerByUserId(tonumber(Entry.UserId) or 0)

            if Context.AICFeature.IsWhitelisted and Context.AICFeature.IsWhitelisted(Entry.UserId) then
                Tags ..= "  [WHITELIST]"
            end

            if ServerHop:IsDangerWhitelisted(Entry.UserId) then
                Tags ..= "  [DANGER WHITELIST]"
            end

            if OtherPlayer and ServerHop:IsDangerPlayer(OtherPlayer) then
                Tags ..= "  [DANGER]"
            end

            return string.format("%s  %s  @%s%s", Entry.Time, string.upper(Entry.Event), Entry.Name, Tags)
        end

        local function RefreshLog()
            if ServerHop.S.LogVersion == S.LogVersion then
                return
            end

            S.LogVersion = ServerHop.S.LogVersion

            local Lines = {}

            for Index, Entry in ipairs(ServerHop:GetLog()) do
                if Index > LOG_SHOWN then
                    break
                end

                Lines[Index] = DescribeLogEntry(Entry)
            end

            if #Lines == 0 then
                Lines[1] = "NO PLAYERS LOGGED YET"
            end

            for Index, Text in ipairs(Lines) do
                local LogLabel = S.LogLabels[Index]

                if not LogLabel then
                    LogLabel = LogSection:AddLabel(Text)
                    S.LogLabels[Index] = LogLabel
                end

                LogLabel.Text = Text
                LogLabel.Visible = true
            end

            for Index = #Lines + 1, #S.LogLabels do
                S.LogLabels[Index].Visible = false
            end
        end

        ------------------------------------------------------------------------
        --// Server Browser
        ------------------------------------------------------------------------

        local function PingText(Ping)
            return Ping and string.format("%d ms", math.floor(Ping + 0.5)) or "n/a"
        end

        local function FPSText(FPS)
            return FPS and tostring(math.floor(FPS + 0.5)) or "n/a"
        end

        local function BuildDetail()
            local Theme = UI.Theme
            local Server = S.Selected

            ClearChildren(DetailScroll)

            if not Server then
                Label(DetailScroll, "Pick a server from the list", 12, { TextColor3 = Theme.TextMuted, LayoutOrder = 1 })
                return
            end

            local IsCurrent = Server.Id == tostring(game.JobId or "")

            if IsCurrent then
                Server = CurrentServerEntry()
            end

            Label(DetailScroll, (IsCurrent and "◇  THIS SERVER" or "◇  PUBLIC SERVER"), 13, {
                TextColor3 = Theme.Cyan,
                Font = Floating.Fonts.Bold,
                LayoutOrder = 1,
            })
            Label(DetailScroll, string.format("PLAYERS  %d / %d", Server.Playing or 0, Server.MaxPlayers or 0), 10, {
                Font = Floating.Fonts.Bold,
                LayoutOrder = 2,
            })
            Label(DetailScroll, string.format("PING  %s  ·  FPS  %s", PingText(Server.Ping), FPSText(Server.FPS)):upper(), 10, {
                TextColor3 = Theme.TextSecondary,
                LayoutOrder = 3,
            })
            Label(DetailScroll, "JOB ID  " .. Server.Id, 9, {
                TextColor3 = Theme.TextMuted,
                TextWrapped = true,
                TextTruncate = Enum.TextTruncate.None,
                AutomaticSize = Enum.AutomaticSize.Y,
                LayoutOrder = 4,
            })

            local Copy = Button(DetailScroll, "COPY JOB ID", Theme.Text, { LayoutOrder = 5 })
            UI:_Connect(Copy.Activated, function()
                CopyJobId(Server.Id)
            end)

            if not IsCurrent then
                local Join = Button(DetailScroll, "JOIN", Theme.Cyan, { LayoutOrder = 6 })
                UI:_Connect(Join.Activated, function()
                    ServerHop:Join(Server.Id)
                end)

                Label(DetailScroll, "Roblox's server list gives player counts only, not names, for other servers", 9, {
                    TextColor3 = Theme.TextMuted,
                    TextWrapped = true,
                    TextTruncate = Enum.TextTruncate.None,
                    AutomaticSize = Enum.AutomaticSize.Y,
                    LayoutOrder = 7,
                })
                return
            end

            Label(DetailScroll, "PLAYERS IN THIS SERVER", 8, {
                TextColor3 = Theme.TextMuted,
                Font = Floating.Fonts.Bold,
                LayoutOrder = 6,
            })

            local Here = Players:GetPlayers()

            table.sort(Here, function(A, B)
                if A == Player or B == Player then
                    return A == Player and B ~= Player
                end

                return string.lower(A.Name) < string.lower(B.Name)
            end)

            for Index, OtherPlayer in ipairs(Here) do
                local Display = OtherPlayer.DisplayName ~= "" and OtherPlayer.DisplayName or OtherPlayer.Name
                local Text = string.format("%s%s  @%s", OtherPlayer == Player and "YOU  ·  " or "", Display, OtherPlayer.Name)

                if ServerHop:IsDangerPlayer(OtherPlayer) then
                    Text ..= "  [DANGER]"
                end

                Label(DetailScroll, Text, 10, {
                    TextColor3 = OtherPlayer == Player and Theme.Cyan
                        or (ServerHop:IsDangerPlayer(OtherPlayer) and Theme.Danger or Theme.Text),
                    LayoutOrder = 6 + Index,
                })
            end
        end

        local function SelectServer(Server)
            S.Selected = Server
            S.DetailSignature = nil
            BuildDetail()
        end

        local function AddServerRow(Server, Order)
            local Theme = UI.Theme
            local IsCurrent = Server.IsCurrent == true

            local Row = New("TextButton", {
                Parent = ListScroll,
                Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
                BackgroundColor3 = IsCurrent and Theme.PanelHover or Theme.Element,
                BackgroundTransparency = 0.1,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = Order,
            })

            Floating.Hover(Row)

            --// Accent bar on the left: cyan for the server we are in.
            New("Frame", {
                Parent = Row,
                BackgroundColor3 = IsCurrent and Theme.Cyan or Theme.BorderDim,
                BorderSizePixel = 0,
                Position = UDim2.fromOffset(0, 6),
                Size = UDim2.new(0, 2, 1, -12),
            })

            Label(Row, string.format("%s%d / %d PLAYERS", IsCurrent and "◆  YOU ARE HERE  ·  " or "◇  ", Server.Playing or 0, Server.MaxPlayers or 0), 10, {
                Position = UDim2.fromOffset(10, 5),
                Size = UDim2.new(1, -18, 0, 15),
                TextColor3 = IsCurrent and Theme.Cyan or Theme.Text,
                Font = Floating.Fonts.Bold,
            })
            Label(Row, string.format("PING %s  ·  FPS %s  ·  %s", PingText(Server.Ping), FPSText(Server.FPS), ShortJobId(Server.Id)):upper(), 8, {
                Position = UDim2.fromOffset(10, 22),
                Size = UDim2.new(1, -18, 0, 12),
                TextColor3 = Theme.TextMuted,
            })

            UI:_Connect(Row.Activated, function()
                SelectServer(Server)
            end)
        end

        local function RedrawList()
            ClearChildren(ListScroll)

            for Index, Server in ipairs(S.Servers) do
                AddServerRow(Server, Index)
            end
        end

        --// Reset starts over with this server on top; otherwise the next page.
        local function LoadServers(Reset)
            if S.Loading or (not Reset and not S.Cursor) then
                return
            end

            if Reset then
                S.Cursor = nil
                S.Servers = { CurrentServerEntry() }
                RedrawList()
            end

            S.Loading = true
            StatusLabel.Text = Reset and "Loading public servers..." or "Loading more servers..."

            task.spawn(function()
                local Servers, NextCursor, Error = ServerHop:ReadPublicServers(not Reset and S.Cursor or nil)
                S.Loading = false

                if not Servers then
                    S.Cursor = nil
                    MoreButton.Visible = false
                    StatusLabel.Text = "Could not load servers: " .. tostring(Error)
                    return
                end

                local Seen = {}

                for _, Server in ipairs(S.Servers) do
                    Seen[Server.Id] = true
                end

                for _, Server in ipairs(Servers) do
                    if not Seen[Server.Id] then
                        Seen[Server.Id] = true
                        table.insert(S.Servers, Server)
                        AddServerRow(Server, #S.Servers)
                    end
                end

                S.Cursor = NextCursor
                MoreButton.Visible = NextCursor ~= nil
                StatusLabel.Text = string.format("%d servers%s", #S.Servers, NextCursor and "  ·  more available" or "")
            end)
        end

        local function BuildBrowser()
            local Theme = UI.Theme

            Window = Floating.CreateWindow({
                Title = "SERVER BROWSER",
                Subtitle = "Public servers  //  pick one to see it and join",
                Width = WINDOW_WIDTH,
                Height = WINDOW_HEIGHT,
            })

            RefreshButton = Button(Window.Body, "◇  REFRESH", Theme.Cyan, { Size = UDim2.fromOffset(100, 26) })
            MoreButton = Button(Window.Body, "LOAD MORE", Theme.Text, {
                Position = UDim2.fromOffset(106, 0),
                Size = UDim2.fromOffset(90, 26),
                Visible = false,
            })
            StatusLabel = Label(Window.Body, "", 9, {
                Position = UDim2.fromOffset(206, 0),
                Size = UDim2.new(1, -206, 0, 26),
                TextColor3 = Theme.TextMuted,
            })

            local Lists = New("Frame", {
                Parent = Window.Body,
                BackgroundTransparency = 1,
                Position = UDim2.fromOffset(0, 34),
                Size = UDim2.new(1, 0, 1, -34),
            })

            ListScroll = Floating.Scroller(Lists, UDim2.new(), UDim2.new(LIST_WIDTH_SCALE, -4, 1, 0), 4, 4)
            DetailScroll = Floating.Scroller(Lists, UDim2.new(LIST_WIDTH_SCALE, 4, 0, 0), UDim2.new(1 - LIST_WIDTH_SCALE, -4, 1, 0), 8, 6)

            UI:_Connect(RefreshButton.Activated, function()
                LoadServers(true)
            end)

            UI:_Connect(MoreButton.Activated, function()
                LoadServers(false)
            end)

            S.Built = true
        end

        function Module:ToggleBrowser()
            if not Floating.Available() then
                return
            end

            if not S.Built then
                BuildBrowser()
            end

            if Window.IsOpen then
                Window:Close()
                return
            end

            Window:Open()
            SelectServer(CurrentServerEntry())
            LoadServers(true)
        end

        ------------------------------------------------------------------------

        local function ColorBand(Value, Good, Ok, LowerIsBetter)
            local Theme = UI.Theme

            if not Value then
                return Theme.TextMuted
            end

            local IsGood = LowerIsBetter and Value < Good or not LowerIsBetter and Value >= Good
            local IsOk = LowerIsBetter and Value < Ok or not LowerIsBetter and Value >= Ok
            return IsGood and Theme.Cyan or (IsOk and Theme.Warning or Theme.Danger)
        end

        local function RefreshInfo()
            local Ping = GetPingMs()

            UIRef.ServerPlayersLabel.Text = string.format("PLAYERS  %d / %d  //  %s", #Players:GetPlayers(), Players.MaxPlayers, S.PlaceName)
            UIRef.ServerJobLabel.Text = string.format("JOB ID  %s  //  PLACE  %d", ShortJobId(game.JobId), game.PlaceId)
            UIRef.ServerFPSLabel.Text = "FPS  " .. (S.FPS and tostring(S.FPS) or "--")
            UIRef.ServerFPSLabel.TextColor3 = ColorBand(S.FPS, FPS_GOOD, FPS_OK, false)
            UIRef.ServerPingLabel.Text = "PING  " .. (Ping and tostring(Ping) or "--") .. " MS"
            UIRef.ServerPingLabel.TextColor3 = ColorBand(Ping, PING_GOOD, PING_OK, true)
            UIRef.ServerStatusLabel.Text = "STATUS  " .. ServerHop:GetStatus()

            RefreshLog()

            --// The current server's details follow its players while shown,
            --// redrawn only when they change so the scroll stays put.
            if Window and Window.IsOpen and S.Selected and S.Selected.Id == tostring(game.JobId or "") then
                local Names = {}

                for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                    table.insert(Names, OtherPlayer.Name .. (ServerHop:IsDangerPlayer(OtherPlayer) and "!" or ""))
                end

                table.sort(Names)

                local Signature = table.concat(Names, ",")

                if Signature ~= S.DetailSignature then
                    S.DetailSignature = Signature
                    BuildDetail()
                end
            end
        end

        --// Heartbeat drives this every frame, so it also counts the FPS.
        function Module:Update(dt)
            S.FrameCount += 1
            S.FrameTime += dt or 0

            if S.FrameTime >= INFO_INTERVAL then
                S.FPS = math.floor(S.FrameCount / S.FrameTime + 0.5)
                S.FrameCount = 0
                S.FrameTime = 0
            end

            local now = os.clock()

            if now - S.LastInfo >= INFO_INTERVAL then
                S.LastInfo = now
                RefreshInfo()
            end
        end

        return Module
    end,
}
