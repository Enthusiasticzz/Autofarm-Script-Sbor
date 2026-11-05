-- Deterministic yielding scheduler: suspended remote calls and task.wait really
-- remain pending, unlike the synchronous UI fixtures.
local now, queue = 100, {}
local task = {}
local os = { clock = function() return now end }
local warn = function(...) print(...) end
local function schedule(thread, at)
    queue[thread] = at
    return thread
end
local function resume(thread)
    local ok, delay = coroutine.resume(thread)
    assert(ok, tostring(delay))
    if coroutine.status(thread) ~= "dead" and type(delay) == "number" then schedule(thread, now + delay) end
end
function task.spawn(fn)
    local thread = type(fn) == "thread" and fn or coroutine.create(fn)
    resume(thread)
    return thread
end
function task.delay(delay, fn) return schedule(coroutine.create(fn), now + delay) end
function task.wait(delay) return coroutine.yield(delay or .01) end
function task.cancel(thread)
    queue[thread] = nil
    assert(coroutine.close(thread))
end
local function advance(seconds)
    local finish = now + seconds
    while true do
        local nextThread, at = nil, math.huge
        for thread, time in pairs(queue) do
            if time < at then nextThread, at = thread, time end
        end
        if at > finish then break end
        now = at; queue[nextThread] = nil; resume(nextThread)
    end
    now = finish
end
local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        local c = { Connected = true }
        function c:Disconnect() self.Connected = false; s.handlers[self] = nil end
        self.handlers[c] = fn
        return c
    end
    function s:Fire()
        for c, fn in pairs(self.handlers) do if c.Connected then fn() end end
    end
    return s
end
local workspace = { FindFirstChild = function() return nil end }
-- MODULES
local function context()
    local callbacks = {}
    local c = { Lifetime = { Alive = true } }
    c.Lifetime.OnEnd = function(fn) table.insert(callbacks, fn) end
    c.Lifetime.Disconnect = function(object)
        if not object then return end
        if object.Disconnect then object:Disconnect()
        else for _, connection in ipairs(object) do connection:Disconnect() end end
    end
    c.Connect = function(event, fn)
        local connection = event:Connect(fn)
        c.Lifetime.OnEnd(function() connection:Disconnect() end)
        return connection
    end
    c.stop = function()
        c.Lifetime.Alive = false
        for i = #callbacks, 1, -1 do callbacks[i]() end
    end
    c.Async = AsyncModule.Start(c)
    return c
end

do
    local c = context()
    local worker = c.Async:Worker()
    local thread, expired, completed
    assert(worker:Start(function() thread = coroutine.running(); coroutine.yield() end, 2,
        function() completed = true end, function() expired = true end))
    assert(not worker:Start(function() error("duplicate worker started") end))
    advance(2)
    assert(expired and not completed and not worker:IsRunning(), "timeout retained pending work")
    assert(coroutine.status(thread) == "dead", "timed-out remote coroutine wasn't cancelled")
    worker:Start(function() return "ok", nil, 3 end, 2, function(ok, a, b, d)
        assert(ok and a == "ok" and b == nil and d == 3); completed = true
    end)
    assert(completed and not worker:IsRunning(), "successful remote completion lost return values")
    completed = false
    worker:Start(function() thread = coroutine.running(); task.wait(5) end, 8, function() completed = true end)
    c.stop(); advance(10)
    assert(not completed and coroutine.status(thread) == "dead", "shutdown left a worker alive")
    assert(not worker:Start(function() error("started after shutdown") end))
    assert(next(queue) == nil, "worker timers leaked")
    print("OK worker timeout, single flight, successful return, shutdown")
end

local function staminaContext()
    local c = context()
    local changed = signal()
    local stamina = { Value = 5, GetPropertyChangedSignal = function() return changed end }
    local maximum = { Value = 10 }
    local loaded = false
    c.Player = { FindFirstChild = function() return loaded and { FindFirstChild = function() return maximum end } or nil end }
    c.PlayerGui = { FindFirstChild = function() return loaded and { FindFirstChild = function() return stamina end } or nil end }
    c.AICFeature, c.CONFIG = { S = {} }, {}
    StaminaModule.Start(c)
    return c, stamina, changed, function() loaded = true end
end
do
    local c, stamina, changed, load = staminaContext()
    c.AICFeature.RegenStamina(); c.stop(); load(); advance(1)
    assert(next(changed.handlers) == nil, "stamina setup attached after shutdown")
    local c2, s2, event, load2 = staminaContext()
    load2(); c2.AICFeature.RegenStamina()
    local old = c2.AICFeature.S.StaminaConnection
    c2.AICFeature.RegenStamina()
    assert(not old.Connected, "repeated stamina setup retained the old callback")
    event:Fire(); assert(s2.Value == 10, "active stamina callback stopped working")
    c2.stop(); s2.Value = 2; event:Fire()
    assert(s2.Value == 2 and next(event.handlers) == nil, "stamina callback survived shutdown")
    print("OK stamina loading, rebind and shutdown")
end
do
    local c = context()
    local calls, thread = 0, nil
    c.Services = { Replicated = { FindFirstChild = function() return { InvokeServer = function(_, item)
        assert(item == "Potion"); calls += 1; thread = coroutine.running(); coroutine.yield()
    end } end } }
    c.AICFeature = { S = { LAST_CONSUME_TIME = 0 } }
    c.CONFIG = { CONSUME_INTERVAL = 1 }
    PotionModule.Start(c)
    local stats = { FindFirstChild = function() return { Value = "Potion" } end }
    assert(c.AICFeature.TryConsumePotion(now, stats), "heartbeat did not return from pending potion request")
    advance(2)
    assert(not c.AICFeature.TryConsumePotion(now, stats) and calls == 1, "pending potion request duplicated")
    advance(8)
    assert(coroutine.status(thread) == "dead", "potion timeout retained remote waiter")
    assert(c.AICFeature.TryConsumePotion(now, stats) and calls == 2, "potion didn't recover after timeout")
    c.stop(); assert(coroutine.status(thread) == "dead")
    print("OK potion heartbeat stays responsive with one pending request")
end
do
    local c = context()
    local waiting
    c.Player = { WaitForChild = function() waiting = coroutine.running(); coroutine.yield() end }
    c.Services, c.Feature = {}, { SafeBoosterReset = { Enabled = true } }
    c.AICFeature, c.AICUI, c.UIRef = { S = {} }, { BindFeatureToggle = function() end }, {}
    local feature = BoosterModule.Start(c)
    local first = waiting
    feature.SafeBoosterReset()
    assert(coroutine.status(first) == "dead", "booster rebind retained setup wait")
    advance(30)
    assert(coroutine.status(waiting) == "dead", "booster setup wait had no timeout")
    feature.SafeBoosterReset(); c.stop()
    assert(coroutine.status(waiting) == "dead", "booster setup survived shutdown")
    print("OK booster setup rebind, timeout and shutdown")
end

local function partyContext(aliveCharacter)
    local c = context()
    local joined = signal()
    local humanoid = { Health = aliveCharacter and 100 or 0 }
    local teleports, chats = 0, 0
    c.Runtime = { GetCharacter = function() return nil, humanoid end }
    c.Player = { CharacterAdded = joined }
    c.Services = { Players = { GetPlayers = function() return {} end }, Replicated = {
        FindFirstChild = function(_, name)
            return { FireServer = function()
                if name == "TeleportEvent" then teleports += 1 else chats += 1 end
            end }
        end } }
    c.CONFIG = { PARTY_LEADER = { Name = "Leader", UserId = 1 }, PARTY_TP_ATTEMPTS = 1,
        PARTY_CHECK_INTERVAL = 0, PARTY_TP_ATTEMPT_TIMEOUT = 2 }
    c.Feature = { PartySystem = { Enabled = true } }
    c.AICFeature, c.AICUI, c.UIRef = { S = {} }, {}, {}
    c.NotifyAction = function() end
    local feature = PartyModule.Start(c)
    return c, feature, joined, function() return teleports, chats end
end
do
    local c, feature, joined, counts = partyContext(true)
    feature:Update()
    assert(c.AICFeature.S.Party.Busy and next(joined.handlers), "follow did not wait for respawn")
    c.stop(); advance(20)
    assert(next(joined.handlers) == nil and not c.AICFeature.S.Party.Holding, "follow leaked respawn handler/hold")
    assert(counts() == 0, "follow teleported after shutdown")
    local c2, f2, _, counts2 = partyContext(false)
    f2:Update(); assert(counts2() == 1)
    c2.CONFIG.PARTY_LEADER = { Name = "Different", UserId = 2 }
    c2.AICUI.RefreshPartyUI(); advance(1)
    local _, chats = counts2(); assert(chats == 0, "old leader's delayed chat survived a change")
    c2.stop()
    local c3, f3, _, counts3 = partyContext(false)
    f3:Update(); advance(.5)
    local tp3, chat3 = counts3(); assert(tp3 == 1 and chat3 == 1, "active follow lost its teleport")
    c3.stop(); advance(10)
    assert(next(queue) == nil, "follow left background tasks alive")
    print("OK party respawn shutdown, leader change and active teleport")
end
do
    local position = setmetatable({}, { __sub = function() return { Magnitude = 0 } end })
    local function object(kind, name, children)
        return { Parent = true, Name = name, Value = 1, Position = position, Transparency = 0,
            IsA = function(_, class) return class == kind end,
            FindFirstChild = function(_, key) return children and children[key] end }
    end
    for _, mining in ipairs({true, false}) do
        local c = context()
        local thread, calls = nil, 0
        local remote = object("RemoteFunction", "Remote")
        remote.InvokeServer = function() calls += 1; thread = coroutine.running(); coroutine.yield() end
        c.Services = { Replicated = { FindFirstChild = function(_, name)
            if name == (mining and "ClaimMaterial" or "CraftingStart") then return remote end
        end } }
        c.Player = { Name = "Player", CharacterAdded = signal() }
        local humanoid = { Parent = true, WalkSpeed = 16 }
        c.Runtime = { GetCharacter = function() return nil, humanoid, { Position = position } end }
        c.CONFIG, c.UIRef, c.AICUI, c.AICFeature = {}, {}, {}, { S = {} }
        c.SaveConfig = { ITEM_MAX_STACK = 999 }
        c.Feature = { AutoMining = { Enabled = true }, AutoSmithing = { Enabled = true }, IgnoreFarmZone = { Enabled = true } }
        c.AICCombat = { GetNearestThreat = function() return nil end, GetFightBackThreat = function() return nil end }
        c.AICCombatUtils = { IsInsideMineZone = function() return true end }
        c.WalkController = { Reset = function() end, Hold = function() end }
        c.SmithingRecipes = { GetInventoryText = function() return "" end }
        c.SmithingMinigame = { Start = function() end, Stop = function() end }
        local feature = (mining and MiningModule or SmithingModule).Start(c)
        local function begin()
            local s = feature.S
            if mining then
                s.Ore = object("Model", "Ore", {
                    Core = object("BasePart", "Core"),
                    Owner = object("StringValue", "Owner"),
                    Id = object("NumberValue", "Id"),
                })
                s.Core, s.Owner, s.Id = s.Ore:FindFirstChild("Core"), s.Ore:FindFirstChild("Owner"), s.Ore:FindFirstChild("Id")
                s.Owner.Value = ""
                s.State, s.LastScan, s.ApproachStart = "Approach", now, now
            else
                s.Table = object("Model", "Smithing", { ProxBase = object("BasePart", "ProxBase"), Id = { Value = 1 } })
                s.State, s.LastSelect, s.WalkStart, s.Recipe = "Walking", now, now, "Sword"
            end
            feature.Step(now)
            assert(coroutine.status(thread) == "suspended", "remote wasn't pending")
        end
        begin(); advance(10)
        assert(coroutine.status(thread) == "dead" and feature.S.State == "Idle", "job timeout leaked its remote wait")
        begin(); feature:Reset()
        assert(coroutine.status(thread) == "dead" and feature.S.State == "Idle", "reset retained its remote wait")
        begin(); c.stop()
        assert(coroutine.status(thread) == "dead" and calls == 3, "shutdown retained its remote wait")
        print("OK " .. (mining and "mining" or "crafting") .. " timeout, reset and shutdown")
    end
    assert(next(queue) == nil, "job timers leaked")
end
print("LIFECYCLE SMOKE PASSED")
