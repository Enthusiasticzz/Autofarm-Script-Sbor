-- Webhook posts a summary of the run to a Discord webhook: event currency or
-- EXP, the account (and duo), the floor, and how long the session has been
-- going. Everything it needs lives in one section on the Utility tab.
return {
    Name = "Webhook",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components", "TimeZones"},

    Start = function(Context)
        local Services = Context.Services
        local HttpService = Services.HttpService
        local MarketplaceService = Services.MarketplaceService
        local Player = Context.Player
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
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
                --// The same position as one total across levels, so a
                --// level-up reports the EXP gained, not a negative bar.
                StartTotalExp = nil,
                --// os.clock() of the last report, so a departure and the
                --// teleport that follows it (or a toggle and a hop) post once.
                LastReportAt = nil,
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

        --// The character's EXP as one total across levels: every bar passed
        --// in full, plus the progress inside this one. neededExp(Level) is
        --// the bar the HUD prints, so a level-up makes the total bigger
        --// instead of resetting it. Cached per level; the curve is static.
        local CumulativeExp = {}

        local function TotalExpAt(Level, Exp)
            if type(Level) ~= "number" or Level < 1 or type(Exp) ~= "number" then
                return nil
            end

            local Base = CumulativeExp[Level]

            if Base == nil then
                Base = 0

                for Passed = 1, Level - 1 do
                    local Needed = NeededExp(Passed)

                    if not Needed then
                        return nil
                    end

                    Base = Base + Needed
                end

                CumulativeExp[Level] = Base
            end

            return Base + Exp
        end

        --// "12,345": rates are read at a glance, and six digits without a
        --// separator are not. Groups are peeled off the right; regrouping
        --// only the left side dropped the last group of every 7-digit value.
        local function FormatCount(Value)
            local Text = tostring(math.max(0, math.floor(tonumber(Value) or 0)))
            local Groups = {}

            while #Text > 3 do
                table.insert(Groups, 1, string.sub(Text, -3))
                Text = string.sub(Text, 1, -4)
            end

            table.insert(Groups, 1, Text)
            return table.concat(Groups, ",")
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

        --// The clock in the report header, in the zone picked in the section.
        --// Core/TimeZones owns the offsets and the daylight-saving calendar,
        --// so the report follows the calendar by itself: US Eastern prints
        --// EDT in summer and EST after the clocks go back. The date is left
        --// out: the report is about this session, and "Started at" only needs
        --// the clock.
        local TimeZones = Context.TimeZones

        --// The stamp for a moment already past. The session keeps its start
        --// as an epoch rather than a finished string, so changing the Time
        --// Zone picker while a report is running restamps the header and the
        --// session label in the zone picked now; a saved string kept
        --// printing the zone the session began in until the script restarted.
        local function ClockAt(Epoch)
            if TimeZones and TimeZones.Stamp then
                return TimeZones.Stamp(CONFIG.DISCORD_TIMEZONE, Epoch)
            end

            --// The module did not start (an older bundle): UTC is better than
            --// a report with no time on it.
            return os.date("!%I:%M %p", Epoch or os.time()) .. " UTC"
        end

        local function ZoneClock()
            return ClockAt(os.time())
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
            self.S.StartedEpoch = os.time()
            self.S.StartedClock = ZoneClock()
            self.S.StartCurrency = ReadCurrency()
            self.S.StartLevel = ReadLevel()
            self.S.StartExp = ReadExp()
            self.S.StartTotalExp = TotalExpAt(self.S.StartLevel, self.S.StartExp)
            self.S.LastLabelUpdate = 0
        end

        function Feature:GetElapsed()
            return math.max(0, os.clock() - (self.S.StartedAt or os.clock()))
        end

        --// EXP gained since the session began, and that gain spread over the
        --// time it took. The rate is a session average, not an instant rate.
        --// nil until both ends of the bar can be read.
        function Feature:GetExpProgress()
            local GainedNow = TotalExpAt(ReadLevel(), ReadExp())

            if GainedNow == nil or self.S.StartTotalExp == nil then
                return nil
            end

            local Gained = math.max(0, GainedNow - self.S.StartTotalExp)
            local Minutes = self:GetElapsed() / 60
            local PerHour = Minutes > 0 and Gained / Minutes * 60 or 0

            return Gained, PerHour
        end

        --// The Status tab reads the same session and baseline as the report,
        --// so its EXP rate lines cannot disagree with the live label.
        AICFeature.GetExpProgress = function()
            return Feature:GetExpProgress()
        end

        --// When this session started, in whichever zone is picked now.
        function Feature:GetStartedClock()
            if self.S.StartedEpoch then
                return ClockAt(self.S.StartedEpoch)
            end

            return tostring(self.S.StartedClock or ZoneClock())
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

            if self.S.StartTotalExp == nil then
                self.S.StartTotalExp = TotalExpAt(self.S.StartLevel, self.S.StartExp)
            end
        end

        --// "@name (UserId)" for each player, or "".
        local function NameList(Names)
            local Parts = {}

            for _, Who in ipairs(Names or {}) do
                local OtherName = tostring(Who.Name or "?")
                local OtherId = tonumber(Who.UserId)

                table.insert(Parts, "@" .. OtherName
                    .. (OtherId and string.format(" (%d)", OtherId) or ""))
            end

            return table.concat(Parts, ", ")
        end

        --// The header keeps to one line: "@a", or "@a and 2 more".
        local function ShortNames(Names)
            if #Names == 0 then
                return ""
            end

            if #Names == 1 then
                return "@" .. tostring(Names[1].Name or "?")
            end

            return string.format("@%s and %d more", tostring(Names[1].Name or "?"), #Names - 1)
        end

        --// A report takes a list of players. A single Player still works, and
        --// a caller with nobody to name passes nothing.
        local function AsList(Value)
            local List = {}

            if Value == nil then
                return List
            end

            if type(Value) == "table" then
                for _, Who in ipairs(Value) do
                    if Who ~= nil then
                        table.insert(List, Who)
                    end
                end

                return List
            end

            table.insert(List, Value)
            return List
        end

        --// The message body, in the order Discord shows it. Kind is "Start",
        --// "End" (a leave, or Auto Farm switched off), "Waiting" (a stranger
        --// is on the server and the hold is hiding from them) or "Left" (the
        --// strangers went before the hold ran out). Names lists the players
        --// the report is about; a report with nobody to name leaves that line
        --// out. Waited is how long a "Left" report waited on them.
        function Feature:BuildReport(Kind, Names, Waited)
            --// A report built before the first update still gets the session's
            --// starting numbers rather than today's.
            self:CaptureStart()

            local Ending = Kind == "End"
            local Waiting = Kind == "Waiting"
            local Left = Kind == "Left"
            local Currency = ReadCurrency()
            local Level = ReadLevel()
            local Exp = ReadExp()
            local Duo = Trim(CONFIG.DISCORD_DUO)
            local Account = Player.Name

            if Duo ~= "" then
                Account = Account .. " and " .. Duo
            end

            Names = Names or {}

            --// A leaving or hiding report says when it is; a running one says
            --// when this session started.
            local Head

            if Waiting then
                local Who = ShortNames(Names)

                Head = "# Waiting For " .. (Who ~= "" and Who or "A Player")
                    .. " at " .. ZoneClock()
            elseif Left then
                local Who = ShortNames(Names)

                Head = "# " .. (Who ~= "" and Who or "A Player")
                    .. " Left at " .. ZoneClock()
            elseif Ending then
                Head = "# Macro Turned off at " .. ZoneClock()
            else
                Head = "# Macro Started at " .. self:GetStartedClock()
            end

            local Lines = {
                Head,
                "Account: " .. Account,
                string.format("Floor: %s (%s)", GetPlaceName(game.PlaceId), tostring(game.PlaceId)),
            }

            --// A leave or a hold caused by a player names them, so the log
            --// says who was there. A report with nobody to name (server age,
            --// a manual leave) has no such line at all.
            if Waiting and #Names > 0 then
                table.insert(Lines, "Waiting on: " .. NameList(Names))
            elseif Left and #Names > 0 then
                table.insert(Lines, "Hid from: " .. NameList(Names))
            elseif Ending and #Names > 0 then
                table.insert(Lines, "Left because of: " .. NameList(Names))
            end

            --// How long the hold was parked before they went, and how much of
            --// their window was left, so a short wait reads as one.
            if Left then
                table.insert(Lines, "They stayed: " .. FormatDuration(Waited))
            end

            --// A running report carries only where the run is now; the
            --// starting numbers are what an end report adds, so both ends of
            --// the pair can be compared. A leave (or Send Report) reads both.
            if CONFIG.DISCORD_FORMAT == FORMAT_EXP then
                --// One number per line: the level on its own, then the
                --// progress inside that level's bar as "exp/needed".
                table.insert(Lines, "**Current Level:** " .. tostring(Level or 0))
                table.insert(Lines, string.format(
                    "Current EXP: %s/%s",
                    FormatCount(Exp or 0),
                    FormatCount(NeededExp(Level) or 0)
                ))

                local Gained, PerHour = self:GetExpProgress()

                if Gained then
                    table.insert(Lines, "**Session EXP Gained:** " .. FormatCount(Gained))
                    table.insert(Lines, "**Average EXP / Hour:** " .. FormatCount(PerHour))
                end

                if Ending then
                    local StartLevel = self.S.StartLevel or Level or 0
                    table.insert(Lines, "**Starting Level:** " .. tostring(StartLevel))
                    table.insert(Lines, string.format(
                        "Starting EXP: %s/%s",
                        FormatCount(self.S.StartExp or Exp or 0),
                        FormatCount(NeededExp(StartLevel) or 0)
                    ))
                end
            else
                table.insert(Lines, "Current EC: " .. tostring(Currency or 0))

                if Ending then
                    table.insert(
                        Lines,
                        "Starting EC: " .. tostring(self.S.StartCurrency or Currency or 0)
                    )
                end
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

            --// One report is one post. A request that runs and comes back
            --// without throwing has already been sent, whatever shape the
            --// answer is: several executors answer with the body as a string
            --// or with nothing at all, and the old fall-through called the
            --// next request function for each of those, so one hold report
            --// arrived several times - the same text, five or six copies.
            --// Only a call that threw moves on to the next function.
            for _, Request in ipairs(Executors) do
                local Ok, Response = pcall(Request, {
                    Url = Url,
                    Method = "POST",
                    Headers = Headers,
                    Body = Body,
                })

                if not Ok then
                    LastError = Response
                    continue
                end

                if type(Response) ~= "table" then
                    return true
                end

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
                    continue
                end

                if Status >= 200 and Status < 300 then
                    return true
                end

                return false, "Discord rejected the report (HTTP " .. tostring(Status) .. ")"
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
        local function BuildPayload(Kind, Names, Waited)
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
            local Text = Feature:BuildReport(Kind, Names, Waited)
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

        --// Posts the report from the button. The HTTP call runs in the
        --// background so the window does not stall on it.
        function Feature:Send()
            if CONFIG.DISCORD_ENABLED == false then
                NotifyAction("Webhook", "Discord logging is off", 4)
                return false
            end

            local Payload, Reason = BuildPayload("Start")

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

        --// One report for a start or an end, posted synchronously so it is
        --// out before a teleport, a kick or the client going away. A repeat
        --// inside REPORT_DEDUPE is the same event seen twice - the Auto Farm
        --// toggle and the hop it leads to, or the leave hook and the teleport
        --// after it - so only the first one posts.
        local REPORT_DEDUPE = 8

        --// getgenv outlives a run of the script, so the last hold report is
        --// kept there: a copy of the script the re-execution guard could not
        --// stop posts through its own Webhook module, and only something
        --// shared by both runs can stop it repeating what the other said.
        local function SharedEnv()
            local Ok, Env = pcall(function()
                return type(getgenv) == "function" and getgenv() or nil
            end)

            if Ok and type(Env) == "table" then
                return Env
            end

            return nil
        end

        --// What one hold report says, without the time it was built at: the
        --// two copies of a flood differ by frames, not by what they name.
        --// The wait is whole seconds so a copy a frame later still matches.
        local function HoldKey(Kind, Names, Waited)
            local Parts = {}

            for _, Who in ipairs(Names or {}) do
                table.insert(Parts, tostring(Who.Name or "?") .. "#" .. tostring(Who.UserId or 0))
            end

            return table.concat({
                Kind,
                tostring(game.PlaceId),
                table.concat(Parts, ","),
                tostring(math.floor(tonumber(Waited) or 0)),
            }, "|")
        end

        --// A left report says a hold is over, so a copy of it is another run
        --// or another frame saying what has already been said. A waiting
        --// report can honestly happen twice (the same player rejoining), so
        --// its window is a few seconds rather than half a minute.
        local HOLD_REPORT_WINDOW = 30
        local WAITING_REPORT_WINDOW = 8

        function Feature:PostReport(Kind, Force, Names, Waited)
            if CONFIG.DISCORD_ENABLED == false then
                return false
            end

            --// Nothing configured: a hop must stay silent, not notify.
            if Trim(CONFIG.DISCORD_WEBHOOK) == "" then
                return false
            end

            local Now = os.clock()
            local List = AsList(Names)
            local Hold = Kind == "Left" or Kind == "Waiting"
            local Key = Hold and HoldKey(Kind, List, Waited) or nil

            --// A hold report with nobody to name lost the list it was built
            --// from, and it can only come out as "A Player Left" - the
            --// header that used to arrive several times beside the real
            --// report. The hold names who was there, so an empty list here is
            --// a caller that could not, not a leave by nobody.
            if Hold and #List == 0 then
                return false
            end

            if Key then
                local Window = Kind == "Waiting" and WAITING_REPORT_WINDOW or HOLD_REPORT_WINDOW
                local Env = SharedEnv()
                local Shared = Env and Env.AICHoldReport or nil

                if type(Shared) == "table"
                    and Shared.Key == Key
                    and Now - (tonumber(Shared.At) or 0) < Window
                then
                    return false
                end

                if self.S.LastHoldKey == Key
                    and self.S.LastHoldAt
                    and Now - self.S.LastHoldAt < Window
                then
                    return false
                end
            end

            if not Force
                and self.S.LastReportAt
                and Now - self.S.LastReportAt < REPORT_DEDUPE
            then
                return false
            end

            self:CaptureStart()

            --// The list, not what the caller passed: a single Player handed in
            --// by an older hook is counted as one entry here.
            local Payload = BuildPayload(Kind, List, Waited)

            if not Payload then
                return false
            end

            local Delivered, Reason = PostJSON(Payload.Url, Payload.Body)

            if not Delivered then
                NotifyAction("Webhook", tostring(Reason), 6)
                return false
            end

            self.S.LastReportAt = Now

            if Key then
                self.S.LastHoldKey = Key
                self.S.LastHoldAt = Now

                local Env = SharedEnv()

                if Env then
                    Env.AICHoldReport = { Key = Key, At = Now }
                end
            end

            NotifyAction(
                "Webhook",
                Kind == "Start" and "Macro started report sent"
                    or (Kind == "Waiting" and "Waiting report sent")
                    or (Kind == "Left" and "Left report sent")
                    or "Macro ended report sent",
                3
            )
            return true
        end

        --// The run is over: a leave, or Auto Farm switched off.
        function Feature:AnnounceEnd(Strangers)
            return self:PostReport("End", false, AsList(Strangers))
        end

        --// A new run: the session clock and its starting numbers restart with
        --// it, so the reports that follow measure this run.
        function Feature:AnnounceStart()
            self:ResetSession()
            return self:PostReport("Start", true)
        end

        --// Auto Block, Server Hop, Danger Group and Follower Guard call this
        --// before they leave, so the report is already on its way out. A
        --// departure posts even inside the window: the client is about to go,
        --// a missed end cannot be retried, and the leave that causes it happens
        --// once anyway (AutoBlock's LeaveStarted latch).
        AICFeature.ReportBeforeLeave = function(Strangers)
            return Feature:PostReport("End", true, AsList(Strangers))
        end

        --// The hold started hiding from strangers (Pause For Strangers). This
        --// one is a setting: with Log When Hiding off nothing is posted when
        --// someone joins, while the leave that follows, if they stay, still
        --// posts.
        AICFeature.ReportHold = function(Strangers)
            if CONFIG.DISCORD_HOLD_LOG == false then
                return false
            end

            return Feature:PostReport("Waiting", true, AsList(Strangers))
        end

        --// The strangers went before their window ran out, so the hold ends
        --// and the route starts again at stop #1. Seconds is how long the hold
        --// sat there waiting on them (from the reset to the moment they were
        --// gone), which is the answer to "how long did they take to leave".
        --// Gated by Log When Hiding with the waiting report: both describe a
        --// hold that ended quietly, while the leave below is not a setting.
        AICFeature.ReportHoldCleared = function(Strangers, Seconds)
            if CONFIG.DISCORD_HOLD_LOG == false then
                return false
            end

            return Feature:PostReport("Left", true, AsList(Strangers), tonumber(Seconds) or 0)
        end

        --// The hold ran out and the game is being closed because the
        --// strangers would not leave. This report is not a setting: it names
        --// everyone who stayed, whether or not Log When Hiding is on. It also
        --// marks the departure as reported, so the kick that follows does not
        --// post the same leave again with a single name.
        AICFeature.ReportHoldLeave = function(Strangers)
            local Posted = Feature:PostReport("End", true, AsList(Strangers))

            if AICFeature.S ~= nil then
                AICFeature.S.LeaveStarted = true
            end

            return Posted
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

            local Text = string.format(
                "SESSION STARTED  %s   ·   %s",
                S.StartedEpoch and ClockAt(S.StartedEpoch) or tostring(S.StartedClock or "--"),
                FormatDuration(Feature:GetElapsed())
            )

            --// The same numbers the report carries, on the label the section
            --// shows. Update refreshes it once a second, so the rates are
            --// live rather than the value at the last report.
            local Gained, PerHour = Feature:GetExpProgress()

            if Gained then
                Text = Text .. string.format(
                    "   ·   EXP +%s   ·   AVG %s/h",
                    FormatCount(Gained),
                    FormatCount(PerHour)
                )
            end

            SessionLabel:Set(Text)
        end

        function Feature:CreateUI()
            local Section = UIRef.WebhookSection

            if not Section then
                return
            end

            --// The master switch, first in the section: off means no report
            --// goes out at all - not on a start, an end or the button.
            Section:AddToggle{
                Name = "Discord Logging",
                Default = CONFIG.DISCORD_ENABLED ~= false,
                Callback = function(Value)
                    Save("DISCORD_ENABLED", Value == true)
                end,
            }

            Section:AddTextBox{
                Name = "Webhook URL",
                Default = Trim(CONFIG.DISCORD_WEBHOOK),
                Callback = function(Value)
                    Save("DISCORD_WEBHOOK", Trim(Value))
                end,
            }

            Section:AddTextBox{
                Name = "Ping User ID",
                Default = Trim(CONFIG.DISCORD_PING),
                Callback = function(Value)
                    Save("DISCORD_PING", Trim(Value))
                end,
            }

            Section:AddTextBox{
                Name = "Ping Duo User ID",
                Default = Trim(CONFIG.DISCORD_DUO_PING),
                Callback = function(Value)
                    Save("DISCORD_DUO_PING", Trim(Value))
                end,
            }
            Section:AddNote("UserId to ping, everyone, or blank for no ping")
            
            Section:AddTextBox{
                Name = "Duo Username",
                Default = Trim(CONFIG.DISCORD_DUO),
                Callback = function(Value)
                    Save("DISCORD_DUO", Trim(Value))
                end,
            }
            Section:AddNote("Blank when not duoing")

            local FormatPicker = Section:AddDropdown{
                Name = "Report Format",
                Options = FORMATS,
                Callback = function(Value)
                    Save("DISCORD_FORMAT", Value)
                end,
            }

            if CONFIG.DISCORD_FORMAT ~= FORMAT_CURRENCY and CONFIG.DISCORD_FORMAT ~= FORMAT_EXP then
                CONFIG.DISCORD_FORMAT = FORMAT_CURRENCY
            end

            FormatPicker:Set(CONFIG.DISCORD_FORMAT, true)

            Section:AddTextBox{
                Name = "EC Item Name",
                Default = Trim(CONFIG.DISCORD_EC_ITEM),
                Callback = function(Value)
                    Save("DISCORD_EC_ITEM", Trim(Value))
                end,
            }
            Section:AddNote("Only used by Event Currency; blank uses the event currency the script tracks")

            --// The clock every report is stamped with. A zone that keeps
            --// daylight saving follows the calendar on its own, so EDT turns
            --// into EST when the clocks go back.
            local ZoneNames = TimeZones and TimeZones.Names or { "US Eastern", "UTC" }

            local ZonePicker = Section:AddDropdown{
                Name = "Time Zone",
                Options = ZoneNames,
                Callback = function(Value)
                    Save("DISCORD_TIMEZONE", TimeZones and TimeZones.Get(Value).Name or Value)
                    --// Restamp the label now: the zone applies to the session
                    --// already running, not only to the next report.
                    RefreshLabel()
                end,
            }

            local ZoneName = TimeZones and TimeZones.Get(CONFIG.DISCORD_TIMEZONE).Name or "US Eastern"
            CONFIG.DISCORD_TIMEZONE = ZoneName
            ZonePicker:Set(ZoneName, true)

            Section:AddNote("Daylight saving follows the calendar: US Eastern reads EDT in summer and EST once the clocks go back")

            Section:AddToggle{
                Name = "Log When Hiding",
                Default = CONFIG.DISCORD_HOLD_LOG ~= false,
                Callback = function(Value)
                    Save("DISCORD_HOLD_LOG", Value == true)
                end,
            }

            Section:AddNote("Posts a report when someone joins and Pause For Strangers is hiding, naming them. Off sends nothing then; a leave because they stayed always reports, with every name")

            Section:AddButton{
                Name = "Send Report",
                Callback = function()
                    Feature:CaptureStart()
                    Feature:Send()
                end,
            }

            Section:AddButton{
                Name = "Reset Session",
                Callback = function()
                    Feature:ResetSession()
                    RefreshLabel()
                    NotifyAction("Webhook", "Session restarted", 3)
                end,
            }

            SessionLabel = Section:AddLabel("")
            RefreshLabel()

            Section:AddNote("Sending does not restart the session; Reset Session does")
        end

        --// The Auto Farm flag the last frame saw. The start and end reports
        --// follow the farm itself, so a toggle, a profile load or Follower
        --// Guard's hold all produce the same pair of messages.
        local FarmingWas = false

        --// One report per change of the farm flag, whoever reports it: the
        --// toggle calls this as it flips, and the heartbeat calls it with the
        --// flag it just read, so the edge is seen even when the frame after
        --// the click never runs. The state is updated here, so the second
        --// signal for the same edge posts nothing.
        function Feature:SetFarming(Farming)
            Farming = Farming == true

            if Farming == FarmingWas then
                return false
            end

            FarmingWas = Farming

            --// Both edges post for certain: this is the event itself, not a
            --// second sighting of one. The leave paths keep their window, so
            --// the hop that a toggle-off leads to does not post again.
            if Farming then
                return self:AnnounceStart()
            end

            return self:PostReport("End", true)
        end

        --// The Auto Farm toggle, which knows the moment it was flipped. It
        --// posts even if the farm loop stops before the next heartbeat.
        AICFeature.NotifyAutoFarmChanged = function(Value)
            return Feature:SetFarming(Value)
        end

        --// The elapsed time in the label, and the Starting EC/Level that
        --// PlayerStats was not ready for when the session began.
        function Feature:Update(DeltaTime)
            self:CaptureStart()

            self:SetFarming(
                FeatureState ~= nil
                    and FeatureState.AutoFarm ~= nil
                    and FeatureState.AutoFarm.Enabled == true
            )

            local Now = os.clock()

            if Now - (self.S.LastLabelUpdate or 0) >= 1 then
                self.S.LastLabelUpdate = Now
                RefreshLabel()
            end
        end

        --// A leave the script started has already posted its own end report
        --// (`ReportBeforeLeave` set AutoBlock's LeaveStarted). The signals
        --// below are for departures the script did not start, so they stay
        --// silent once one has: a kick leaves the client sitting on the
        --// disconnect screen with the script still running, and the end
        --// report used to go out again and again from here.
        local function ScriptLeaveReported()
            return AICFeature.S ~= nil and AICFeature.S.LeaveStarted == true
        end

        --// A teleport the script did not start (a door in the game, another
        --// script, the game's own party teleport) still reports first. The
        --// leave hook does not fire for it, so this is the only notice.
        if Player.OnTeleport then
            Context.Connect(Player.OnTeleport, function(State)
                if State == Enum.TeleportState.Started and not ScriptLeaveReported() then
                    Feature:AnnounceEnd()
                end
            end)
        end

        --// A manual leave is not signalled in time to post reliably, but the
        --// client does fire this in many executors before it closes, so the
        --// report goes then. A leave the script started already sent its own.
        local Players = Services.Players or game:GetService("Players")

        Context.Connect(Players.PlayerRemoving, function(Who)
            if Who == Player and not ScriptLeaveReported() then
                Feature:AnnounceEnd()
            end
        end)

        --// The local player taken out of the game is the closest a manual
        --// leave comes to a signal before the client goes. The parent is nil
        --// when the player is destroyed, not on a respawn.
        if Player.AncestryChanged then
            Context.Connect(Player.AncestryChanged, function(_, Parent)
                if Parent == nil and not ScriptLeaveReported() then
                    Feature:AnnounceEnd()
                end
            end)
        end

        --// Roblox refuses BindToClose on the client, but some executors allow
        --// it to fire on leave. Wrapped, so a refusal changes nothing.
        pcall(function()
            game:BindToClose(function()
                if not ScriptLeaveReported() then
                    Feature:AnnounceEnd()
                end
            end)
        end)

        Feature:ResetSession()
        --// Warm the floor lookup now, so the first report already has the
        --// product name instead of the server's own.
        GetPlaceName(game.PlaceId)
        Feature:CreateUI()

        return Feature
    end,
}
