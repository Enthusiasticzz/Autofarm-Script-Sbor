-- Webhook posts a summary of the run to a Discord webhook: event currency or
-- EXP, the account (and duo), the floor, and how long the session has been
-- going. Everything it needs lives in one section on the Utility tab.
return {
    Name = "Webhook",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components"},

    Start = function(Context)
        local Services = Context.Services
        local HttpService = Services.HttpService
        local MarketplaceService = Services.MarketplaceService
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local AICFeature = Context.AICFeature
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        local FORMAT_CURRENCY = "Event Currency"
        local FORMAT_EXP = "EXP Grind"
        local FORMATS = { FORMAT_CURRENCY, FORMAT_EXP }

        local Feature = {
            Name = "Webhook",
            IsFeature = true,
            S = {
                --// When this report started, as os.clock() for the elapsed
                --// time and as Eastern text for the header.
                StartedAt = os.clock(),
                StartedClock = nil,
                --// Read once when the session starts, so Starting EC/Level
                --// is the value before the grind rather than the value now.
                StartCurrency = nil,
                StartLevel = nil,
                --// The progress inside the starting level's bar, so the
                --// starting line keeps its EXP after levelling up.
                StartExp = nil,
                --// os.clock() of the last departure report, so the hook and
                --// the teleport after it post once.
                LeaveSentAt = nil,
                LastLabelUpdate = 0,
            },
        }

        local S = Feature.S

        --// PlaceId -> its name, looked up once. The product lookup yields, so
        --// it runs in the background and the report falls back to the game's
        --// own name until it answers.
        local PlaceNames = {}

        local function Trim(Value)
            return tostring(Value or ""):gsub("^%s*(.-)%s*$", "%1")
        end

        local function GetPlayerStats()
            return Player:FindFirstChild("PlayerStats")
        end

        local function ReadLevel()
            local PlayerStats = GetPlayerStats()
            local Stat = PlayerStats and PlayerStats:FindFirstChild("Level")

            if not Stat then
                return nil
            end

            return tonumber(Stat.Value) or 0
        end

        --// The progress inside the current level's bar, and how big that
        --// bar is (the same curve the HUD prints).
        local function ReadExp()
            local PlayerStats = GetPlayerStats()
            local Stat = PlayerStats and PlayerStats:FindFirstChild("EXP")

            if not Stat then
                return nil
            end

            return tonumber(Stat.Value) or 0
        end

        local function NeededExp(Level)
            local Needed = AICUI.neededExp

            if type(Needed) ~= "function" or not Level or Level <= 0 then
                return nil
            end

            return math.max(0, math.floor(tonumber(Needed(Level)) or 0))
        end

        local function ReadCurrency()
            local PlayerStats = GetPlayerStats()
            local Inventory = PlayerStats and PlayerStats:FindFirstChild("Inventory")

            if not Inventory then
                return nil
            end

            local ItemName = Trim(CONFIG.DISCORD_EC_ITEM)

            if ItemName == "" then
                ItemName = AICUI.S.TargetCurrency
            end

            local _, Amount = AICUI.GetItem(tostring(Inventory.Value or ""), ItemName)
            return tonumber(Amount) or 0
        end

        --// "23 Minutes, 10 Seconds"; hours are added above that.
        local function FormatDuration(Seconds)
            local Total = math.max(0, math.floor(tonumber(Seconds) or 0))
            local Hours = math.floor(Total / 3600)
            local Minutes = math.floor((Total % 3600) / 60)
            local Rest = Total % 60
            local Parts = {}

            local function Add(Value, Singular, Plural)
                table.insert(Parts, string.format("%d %s", Value, Value == 1 and Singular or Plural))
            end

            if Hours > 0 then
                Add(Hours, "Hour", "Hours")
            end

            if Hours > 0 or Minutes > 0 then
                Add(Minutes, "Minute", "Minutes")
            end

            Add(Rest, "Second", "Seconds")

            return table.concat(Parts, ", ")
        end

        --// United States Eastern time for the header. os.date is the
        --// machine's own zone, so the UTC clock is shifted instead: UTC-4
        --// while daylight saving is on, UTC-5 otherwise. DST starts on the
        --// second Sunday in March and ends on the first Sunday in November.
        local function Weekday(Year, Month, Day)
            if Month < 3 then
                Year -= 1
                Month += 12
            end

            local K = Year % 100
            local J = math.floor(Year / 100)

            --// Zeller: 0 = Saturday, 1 = Sunday, ...
            return (Day + math.floor(13 * (Month + 1) / 5) + K
                + math.floor(K / 4) + math.floor(J / 4) + 5 * J) % 7
        end

        local function NthSunday(Year, Month, N)
            local First = 1 + (7 - Weekday(Year, Month, 1)) % 7
            return First + (N - 1) * 7
        end

        local function IsEasternDST(Year, Month, Day)
            if Month < 3 or Month > 11 then
                return false
            end

            if Month == 3 then
                return Day >= NthSunday(Year, 3, 2)
            end

            if Month == 11 then
                return Day < NthSunday(Year, 11, 1)
            end

            return true
        end

        --// "03:41 PM EST", or EDT in summer. The date is left out: the
        --// report is about this session, and "Started at" only needs the
        --// clock.
        local function EasternTime()
            local Now = os.time()
            local Utc = os.date("!*t", Now)
            local DST = IsEasternDST(Utc.year, Utc.month, Utc.day)
            local Offset = DST and 4 or 5
            local Stamp = os.date("!%I:%M %p", Now - Offset * 3600)

            return Stamp .. (DST and " EDT" or " EST")
        end

        --// A UserId, "everyone", or nothing at all. A hand-typed @name is
        --// passed through, so a mention copied from Discord also works.
        local function FormatPing(Value)
            local Text = Trim(Value)

            if Text == "" then
                return ""
            end

            local Lower = string.lower(Text)

            if Lower == "everyone" or Lower == "@everyone" then
                return "@everyone"
            end

            local Id = string.match(Text, "^<@!?(%d+)>$") or string.match(Text, "^@?(%d+)$")

            if Id then
                return "<@" .. Id .. ">"
            end

            return string.sub(Text, 1, 1) == "@" and Text or ("@" .. Text)
        end

        --// The floor's display name, or the server's own name until the
        --// product lookup has answered (or if it cannot).
        local function GetPlaceName(PlaceId)
            local Cached = PlaceNames[PlaceId]

            if Cached then
                return Cached
            end

            local Fallback = game.Name
            Fallback = (Fallback ~= nil and Fallback ~= "" and Fallback)
                or ("Place " .. tostring(PlaceId))

            PlaceNames[PlaceId] = Fallback

            task.spawn(function()
                local Ok, Info = pcall(function()
                    return MarketplaceService:GetProductInfo(PlaceId, Enum.InfoType.Asset)
                end)

                if Ok and type(Info) == "table" and type(Info.Name) == "string" and Info.Name ~= "" then
                    PlaceNames[PlaceId] = Info.Name
                end
            end)

            return Fallback
        end

        --// Starts a fresh report: the header time, the elapsed clock and
        --// the Starting EC/Level all come from this moment. Stat reads can
        --// be missing before PlayerStats loads, so they are tried again on
        --// the first update that has them.
        function Feature:ResetSession()
            self.S.StartedAt = os.clock()
            self.S.StartedClock = EasternTime()
            self.S.StartCurrency = ReadCurrency()
            self.S.StartLevel = ReadLevel()
            self.S.StartExp = ReadExp()
            self.S.LastLabelUpdate = 0
        end

        function Feature:GetElapsed()
            return math.max(0, os.clock() - (self.S.StartedAt or os.clock()))
        end

        function Feature:CaptureStart()
            if self.S.StartCurrency == nil then
                self.S.StartCurrency = ReadCurrency()
            end

            if self.S.StartLevel == nil then
                self.S.StartLevel = ReadLevel()
            end

            if self.S.StartExp == nil then
                self.S.StartExp = ReadExp()
            end
        end

        --// The message body, in the order Discord shows it.
        function Feature:BuildReport()
            --// A report built before the first update still gets the session's
            --// starting numbers rather than today's.
            self:CaptureStart()

            local Currency = ReadCurrency()
            local Level = ReadLevel()
            local Exp = ReadExp()
            local Duo = Trim(CONFIG.DISCORD_DUO)
            local Account = Player.Name

            if Duo ~= "" then
                Account = Account .. " and " .. Duo
            end

            local Lines = {
                "# Macro Started at " .. tostring(self.S.StartedClock or EasternTime()),
                "Account: " .. Account,
                string.format("Floor: %s (%s)", GetPlaceName(game.PlaceId), tostring(game.PlaceId)),
            }

            if CONFIG.DISCORD_FORMAT == FORMAT_EXP then
                --// One number per line: the level on its own, then the
                --// progress inside that level's bar as "exp/needed".
                table.insert(Lines, "Current Level: " .. tostring(Level or 0))
                table.insert(Lines, string.format(
                    "Current EXP: %s/%s",
                    tostring(Exp or 0),
                    tostring(NeededExp(Level) or 0)
                ))

                local StartLevel = self.S.StartLevel or Level or 0
                table.insert(Lines, "Starting Level: " .. tostring(StartLevel))
                table.insert(Lines, string.format(
                    "Starting EXP: %s/%s",
                    tostring(self.S.StartExp or Exp or 0),
                    tostring(NeededExp(StartLevel) or 0)
                ))
            else
                table.insert(Lines, "Current EC: " .. tostring(Currency or 0))
                table.insert(Lines, "Starting EC: " .. tostring(self.S.StartCurrency or Currency or 0))
            end

            table.insert(Lines, "Time: " .. FormatDuration(self:GetElapsed()))

            return table.concat(Lines, "\n")
        end

        --// Some executors blacklist HttpService:RequestAsync, so the report
        --// goes through the executor's own request function when one exists
        --// (syn.request, http.request, http_request, request), and only then
        --// through HttpService. Returns true, or false and the reason.
        local function PostJSON(Url, Body)
            local Headers = { ["Content-Type"] = "application/json" }

            --// Only the functions that exist are kept: a fixed-size table
            --// with a nil first slot would hide every name after it.
            local Executors = {}
            local function AddRequest(Request)
                if type(Request) == "function" then
                    table.insert(Executors, Request)
                end
            end

            AddRequest(syn and syn.request)
            AddRequest(http and http.request)
            AddRequest(http_request)
            AddRequest(request)

            local LastError

            for _, Request in ipairs(Executors) do
                local Ok, Response = pcall(Request, {
                    Url = Url,
                    Method = "POST",
                    Headers = Headers,
                    Body = Body,
                })

                if not Ok then
                    LastError = Response
                elseif type(Response) == "table" then
                    local Status = tonumber(Response.StatusCode)
                        or tonumber(Response.statusCode)
                        or tonumber(Response.Status)

                    if Status == nil then
                        --// No code to read: a body or anything short of an
                        --// explicit failure is as much as this executor
                        --// says about the call.
                        if Response.Body ~= nil or Response.Success ~= false then
                            return true
                        end

                        LastError = "empty response"
                    elseif Status >= 200 and Status < 300 then
                        return true
                    else
                        return false, "Discord rejected the report (HTTP " .. tostring(Status) .. ")"
                    end
                else
                    LastError = "empty response"
                end
            end

            local Ok, Response = pcall(function()
                return HttpService:RequestAsync({
                    Url = Url,
                    Method = "POST",
                    Headers = Headers,
                    Body = Body,
                })
            end)

            if Ok then
                if type(Response) == "table" and Response.Success then
                    return true
                end

                local Status = type(Response) == "table" and Response.StatusCode or "?"
                return false, "Discord rejected the report (HTTP " .. tostring(Status) .. ")"
            end

            return false, "Request failed: " .. tostring(LastError or Response)
        end

        --// Everything a report needs, or nil and why it cannot be made. The
        --// URL is checked first so an unconfigured hop stays silent.
        local function BuildPayload()
            local Url = Trim(CONFIG.DISCORD_WEBHOOK)

            if Url == "" then
                return nil, "Paste a Discord webhook URL first"
            end

            if not string.match(Url, "^https?://%S+$") then
                return nil, "That does not look like a webhook URL"
            end

            --// The duo is mentioned separately, so both accounts get the
            --// ping; the same id in both boxes is only mentioned once.
            local Mentions = {}
            local Ping = FormatPing(CONFIG.DISCORD_PING)
            local DuoPing = FormatPing(CONFIG.DISCORD_DUO_PING)

            if Ping ~= "" then
                table.insert(Mentions, Ping)
            end

            if DuoPing ~= "" and DuoPing ~= Ping then
                table.insert(Mentions, DuoPing)
            end

            local Prefix = table.concat(Mentions, " ")
            local Text = Feature:BuildReport()
            local Content = Prefix ~= "" and (Prefix .. "\n" .. Text) or Text

            local Ok, Body = pcall(function()
                return HttpService:JSONEncode({
                    content = Content,
                    --// Both, so a UserId ping and @everyone both mention.
                    allowed_mentions = { parse = { "users", "everyone" } },
                })
            end)

            if not Ok then
                return nil, "Could not build the report"
            end

            return { Url = Url, Body = Body }
        end

        --// Posts the report. The HTTP call runs in the background so the
        --// window does not stall on it, and the result is reported either way.
        function Feature:Send()
            local Payload, Reason = BuildPayload()

            if not Payload then
                NotifyAction("Webhook", tostring(Reason), 4)
                return false
            end

            task.spawn(function()
                local Delivered, Error = PostJSON(Payload.Url, Payload.Body)

                if not Delivered then
                    NotifyAction("Webhook", tostring(Error), 6)
                    return
                end

                NotifyAction("Webhook", "Report sent", 3)
            end)

            return true
        end

        --// The report posted on the way out: every leave the script starts
        --// calls this before the teleport or kick, so the client cannot
        --// vanish mid-request. The leave hook and the teleport it starts are
        --// one departure, so only the first of them posts.
        local LEAVE_REPORT_WINDOW = 8

        function Feature:SendOnLeave()
            --// Nothing configured: a hop must stay silent, not notify.
            if Trim(CONFIG.DISCORD_WEBHOOK) == "" then
                return false
            end

            local Now = os.clock()

            if self.S.LeaveSentAt and Now - self.S.LeaveSentAt < LEAVE_REPORT_WINDOW then
                return false
            end

            self.S.LeaveSentAt = Now
            self:CaptureStart()

            local Payload = BuildPayload()

            if not Payload then
                return false
            end

            local Delivered, Reason = PostJSON(Payload.Url, Payload.Body)

            if Delivered then
                NotifyAction("Webhook", "Report sent before leaving", 3)
            else
                NotifyAction("Webhook", tostring(Reason), 6)
            end

            return Delivered
        end

        --// Auto Block, Server Hop, Danger Group and Follower Guard call this
        --// before they leave, so the report is already on its way out.
        AICFeature.ReportBeforeLeave = function()
            return Feature:SendOnLeave()
        end

        local SessionLabel

        local function Save(Key, Value)
            CONFIG[Key] = Value
            AICProfile.WriteGlobalStore()
        end

        local function RefreshLabel()
            if not SessionLabel then
                return
            end

            SessionLabel.Text = string.format(
                "SESSION STARTED  %s   ·   %s",
                tostring(S.StartedClock or "--"),
                FormatDuration(Feature:GetElapsed())
            )
        end

        function Feature:CreateUI()
            local Section = UIRef.WebhookSection

            if not Section then
                return
            end

            Section:AddTextbox("Webhook URL", Trim(CONFIG.DISCORD_WEBHOOK), function(Value)
                Save("DISCORD_WEBHOOK", Trim(Value))
            end)

            Section:AddTextbox("Ping User ID", Trim(CONFIG.DISCORD_PING), function(Value)
                Save("DISCORD_PING", Trim(Value))
            end)

            Section:AddTextbox("Ping Duo User ID", Trim(CONFIG.DISCORD_DUO_PING), function(Value)
                Save("DISCORD_DUO_PING", Trim(Value))
            end)
            Section:AddLabel("UserId to ping, everyone, or blank for no ping")
            
            Section:AddTextbox("Duo Username", Trim(CONFIG.DISCORD_DUO), function(Value)
                Save("DISCORD_DUO", Trim(Value))
            end)
            Section:AddLabel("Blank when not duoing")

            local FormatPicker = Section:AddDropdown("Report Format", FORMATS, function(Value)
                Save("DISCORD_FORMAT", Value)
            end)

            if CONFIG.DISCORD_FORMAT ~= FORMAT_CURRENCY and CONFIG.DISCORD_FORMAT ~= FORMAT_EXP then
                CONFIG.DISCORD_FORMAT = FORMAT_CURRENCY
            end

            FormatPicker:Set(CONFIG.DISCORD_FORMAT, false)

            Section:AddTextbox("EC Item Name", Trim(CONFIG.DISCORD_EC_ITEM), function(Value)
                Save("DISCORD_EC_ITEM", Trim(Value))
            end)
            Section:AddLabel("Only used by Event Currency; blank uses the event currency the script tracks")

            Section:AddButton("Send Report", function()
                Feature:CaptureStart()
                Feature:Send()
            end)

            Section:AddButton("Reset Session", function()
                Feature:ResetSession()
                RefreshLabel()
                NotifyAction("Webhook", "Session restarted", 3)
            end)

            SessionLabel = Section:AddLabel("")
            RefreshLabel()

            Section:AddLabel("Sending does not restart the session; Reset Session does")
        end

        --// The elapsed time in the label, and the Starting EC/Level that
        --// PlayerStats was not ready for when the session began.
        function Feature:Update(DeltaTime)
            self:CaptureStart()

            local Now = os.clock()

            if Now - (self.S.LastLabelUpdate or 0) >= 1 then
                self.S.LastLabelUpdate = Now
                RefreshLabel()
            end
        end

        --// A teleport the script did not start (a door in the game, another
        --// script, the game's own party teleport) still reports first. The
        --// leave hook does not fire for it, so this is the only notice.
        if Player.OnTeleport then
            Context.Connect(Player.OnTeleport, function(State)
                if State == Enum.TeleportState.Started then
                    Feature:SendOnLeave()
                end
            end)
        end

        --// A manual leave is not signalled in time to post reliably, but the
        --// client does fire this in many executors before it closes, so the
        --// report goes then. A leave the script started already sent its own.
        local Players = Services.Players or game:GetService("Players")

        Context.Connect(Players.PlayerRemoving, function(Who)
            if Who == Player then
                Feature:SendOnLeave()
            end
        end)

        Feature:ResetSession()
        --// Warm the floor lookup now, so the first report already has the
        --// product name instead of the server's own.
        GetPlaceName(game.PlaceId)
        Feature:CreateUI()

        return Feature
    end,
}
