-- RespawnTimers: reads the game's workspace.RespawnTimers folder.
--
-- Each dead enemy has a Configuration there with the attributes
--   RespawnName     the enemy's name
--   DiedAt          when it died
--   RespawnSeconds  how long it stays dead
-- The Configuration is removed once the enemy has respawned. An enemy counts
-- as dead until then; the timer running out only makes it "due". Both the
-- timer running out and the removal are reported through
-- AICFeature.OnEnemyRespawned(Name).
return {
    Name = "RespawnTimers",
    Dependencies = {"Runtime"},

    Start = function(Context)
        local AICFeature = Context.AICFeature

        local FOLDER_NAME = "RespawnTimers"

        --// [Configuration] = { Name = lowercased RespawnName, FirstSeen, Due }
        local Timers = {}
        local FolderConnections = {}

        local Module = {
            Name = "RespawnTimers",
        }

        local function NotifyRespawned(Name)
            if Name and AICFeature.OnEnemyRespawned then
                AICFeature.OnEnemyRespawned(Name)
            end
        end

        local function TimerName(Config)
            local Name = Config:GetAttribute("RespawnName")
            return type(Name) == "string" and Name ~= "" and string.lower(Name) or nil
        end

        --// DiedAt is written by the server, so which clock it uses is not
        --// known here. Every candidate clock is tried and the one giving a
        --// plausible age is used: at least as old as the timer is known to
        --// be locally, and not far past its respawn time. Failing that the
        --// local age since the timer appeared is used.
        local function GetElapsed(Timer, Config, RespawnSeconds)
            local LocalElapsed = os.clock() - Timer.FirstSeen
            local DiedAt = tonumber(Config:GetAttribute("DiedAt")) or 0

            if DiedAt <= 0 then
                return LocalElapsed
            end

            local Best = nil
            local Clocks = {
                os.clock(),
                workspace:GetServerTimeNow(),
                os.time(),
                workspace.DistributedGameTime,
            }

            for _, Now in ipairs(Clocks) do
                local Elapsed = Now - DiedAt

                if Elapsed >= LocalElapsed - 1
                    and Elapsed <= RespawnSeconds + 5
                    and (not Best or Elapsed < Best)
                then
                    Best = Elapsed
                end
            end

            return Best or LocalElapsed
        end

        --// Seconds until this timer's enemy respawns; 0 once it is due.
        local function GetRemaining(Config, Timer)
            local RespawnSeconds = tonumber(Config:GetAttribute("RespawnSeconds")) or 0
            local Remaining = math.max(0, RespawnSeconds - GetElapsed(Timer, Config, RespawnSeconds))

            if Remaining <= 0 and not Timer.Due then
                Timer.Due = true
                NotifyRespawned(TimerName(Config))
            end

            return Remaining
        end

        local function Track(Config)
            if Config:IsA("Configuration") and not Timers[Config] then
                Timers[Config] = { FirstSeen = os.clock(), Due = false }
            end
        end

        local function Untrack(Config)
            local Timer = Timers[Config]

            if not Timer then
                return
            end

            Timers[Config] = nil

            --// Removal is the real respawn, so it is always reported, even
            --// when the timer already ran out.
            NotifyRespawned(TimerName(Config))
        end

        local function WatchFolder(Folder)
            for _, Connection in ipairs(FolderConnections) do
                Connection:Disconnect()
            end

            table.clear(FolderConnections)
            table.clear(Timers)

            for _, Child in ipairs(Folder:GetChildren()) do
                Track(Child)
            end

            table.insert(FolderConnections, Folder.ChildAdded:Connect(Track))
            table.insert(FolderConnections, Folder.ChildRemoved:Connect(Untrack))
        end

        --// Respawn state of an enemy by name (any case):
        --//   Pending    how many of them have a timer, i.e. are not back yet
        --//   Remaining  seconds until the first of those respawns (0 once its
        --//              timer has run out but it has not appeared), or nil
        function AICFeature.GetRespawnState(EnemyName)
            local Wanted = string.lower(tostring(EnemyName))
            local Pending, Soonest = 0, nil

            for Config, Timer in pairs(Timers) do
                if Config.Parent and TimerName(Config) == Wanted then
                    Pending += 1
                    Soonest = math.min(Soonest or math.huge, GetRemaining(Config, Timer))
                end
            end

            return Pending, Soonest
        end

        local Existing = workspace:FindFirstChild(FOLDER_NAME)

        if Existing then
            WatchFolder(Existing)
        end

        Context.Connect(workspace.ChildAdded, function(Child)
            if Child.Name == FOLDER_NAME then
                WatchFolder(Child)
            end
        end)

        --// The enemy folders outlive this run.
        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(FolderConnections)
        end)

        return Module
    end,
}
