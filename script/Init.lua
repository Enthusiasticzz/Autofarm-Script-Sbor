-- AutoFarm bootstrap.
-- Every module returns {Name, Dependencies, Start(Context)}.

local TITLE = "AUTOMATED INDUSTRY COMPLEX v3.78"
local UTILS_PATH = "UI/Utils.lua"

--// A failed download is retried this many times before giving up.
local FETCH_RETRIES = 2
--// Files in flight at once, how long one may take, and how long the whole
--// download phase may take before the missing files are reported by name.
local FETCH_WORKERS = 6
local FETCH_TIMEOUT = 8
local FETCH_DEADLINE = 90

local BRANCH = "main"

--// Where every module is downloaded from. The default is this repository, so
--// what runs in the executor is what was pushed here - pointing at another
--// repo made a pushed fix invisible to it. Set getgenv().AICBaseURL before
--// loading to run from somewhere else: a fork, or a pinned build at
--// "https://raw.githubusercontent.com/<user>/<repo>/<sha>/script/" (the value
--// points at the script folder, since every module path is relative to it).
--// The trailing slash is added when it is missing.
local BaseOverride = nil

do
    local Ok, Env = pcall(function()
        return type(getgenv) == "function" and getgenv() or nil
    end)

    if Ok
        and type(Env) == "table"
        and type(Env.AICBaseURL) == "string"
        and Env.AICBaseURL ~= ""
    then
        BaseOverride = Env.AICBaseURL
    end
end

if BaseOverride and not string.find(BaseOverride, "/$") then
    BaseOverride = BaseOverride .. "/"
end

local BASE = BaseOverride
    or (
        "https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/"
        .. BRANCH
        .. "/script/"
    )

local ROOT =
    (typeof(script) == "Instance" and script:IsA("ModuleScript"))
    and script
    or nil

--// Every module, in start order. This is the only list to touch when a
--// module is added: it is both what gets downloaded and the order modules
--// start in (dependencies still start first), so the controls each module
--// adds always appear in the same place in the window. A saved toggle also
--// needs its line in Core/SaveConfig.lua.
local MODULES = {
    "Core/SaveConfig.lua",
    "Core/GuiClick.lua",
    "Core/Runtime.lua",
    "Core/Logger.lua",
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

    "Combat/CombatUtils.lua",
    "Features/EnemyPriority.lua",
    "Combat/Targeting.lua",
    "Combat/Navigation.lua",
    "Combat/Combat.lua",

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

    "Core/Bootstrap.lua",
    "Core/Heartbeat.lua",
}

--// ModuleConfig is the single source of truth for the module list. It is
--// fetched (remote) or required (local Studio) before the start order is
--// derived, so adding a module there is enough. If it cannot be loaded, the
--// inline MODULES table above is used as a fallback.
do
    local Config
    local Ok = pcall(function()
        if ROOT then
            local ConfigModule = ROOT:FindFirstChild("ModuleConfig")
            if ConfigModule and ConfigModule:IsA("ModuleScript") then
                Config = require(ConfigModule)
            end
        else
            local Body = game:HttpGet(BASE .. "ModuleConfig.lua", true)
            if type(Body) == "string"
                and Body ~= ""
                and not string.find(Body, "^404: Not Found")
            then
                local Chunk = loadstring(Body, "@ModuleConfig.lua")
                if Chunk then
                    Config = Chunk()
                end
            end
        end
    end)

    if Ok
        and type(Config) == "table"
        and type(Config.START_ORDER) == "table"
        and #Config.START_ORDER > 0
    then
        MODULES = Config.START_ORDER
    end
end

--// Module name from its path: "Features/AutoFarming.lua" -> "AutoFarming".
--// Every module's Name matches its file name.
local START_ORDER = {}

for _, Path in ipairs(MODULES) do
    table.insert(START_ORDER, string.match(Path, "([^/]+)%.lua$"))
end

--// Modules that are not specs. UI/Utils is the UI library that Runtime
--// loads itself; ModuleConfig is the config table loaded above.
local NON_SPEC_MODULES = {
    ["UI/Utils.lua"] = true,
    ["ModuleConfig.lua"] = true,
}

local function collect(Container, Prefix, Output)
    for _, Child in ipairs(Container:GetChildren()) do
        if Child:IsA("Folder") then
            collect(Child, Prefix .. Child.Name .. "/", Output)
        elseif Child:IsA("ModuleScript")
            and Child ~= script
            and not NON_SPEC_MODULES[Prefix .. Child.Name .. ".lua"]
        then
            Output[Prefix .. Child.Name .. ".lua"] = Child
        end
    end
end

local Context = {
    Modules = {},
    Features = {},
}

--// Re-execution guard: one run at a time. Running the script again stops the
--// previous run (kept in getgenv().AICSession) before this one loads. A run
--// stops by ending Context.Lifetime: Alive goes false, the OnEnd callbacks run
--// newest first, then every connection made through Context.Connect is
--// disconnected. Modules wrap connections to long-lived signals in
--// Context.Connect and loops check Context.Lifetime.Alive.
local Lifetime = { Alive = true, Connections = {}, Cleanups = {}, Env = nil }

--// Signal:Connect that the end of this run disconnects. A connection made
--// after the run was stopped (it was still loading) is cut at once.
function Lifetime.Connect(Signal, Callback)
    local Connection = Signal:Connect(Callback)

    if Lifetime.Alive then
        table.insert(Lifetime.Connections, Connection)
    else
        Connection:Disconnect()
    end

    return Connection
end

--// Runs when this run ends, newest first.
function Lifetime.OnEnd(Callback)
    table.insert(Lifetime.Cleanups, Callback)
end

--// Disconnects a connection, or every connection in a list (then clears it).
--// For connections a module keeps and rebinds itself (mob watchers, folder
--// watchers), which Context.Connect would pile up.
function Lifetime.Disconnect(Value)
    if typeof(Value) == "RBXScriptConnection" then
        Value:Disconnect()
    elseif type(Value) == "table" then
        for _, Connection in pairs(Value) do
            if typeof(Connection) == "RBXScriptConnection" then
                Connection:Disconnect()
            end
        end

        table.clear(Value)
    end
end

function Lifetime.RunCleanups()
    for Index = #Lifetime.Cleanups, 1, -1 do
        local Ok, Error = pcall(Lifetime.Cleanups[Index])

        if not Ok then
            warn("[AIC] Cleanup failed:", Error)
        end
    end

    table.clear(Lifetime.Cleanups)
end

function Lifetime.Destroy()
    if not Lifetime.Alive then
        return
    end

    Lifetime.Alive = false
    Lifetime.RunCleanups()

    for _, Connection in ipairs(Lifetime.Connections) do
        pcall(function()
            Connection:Disconnect()
        end)
    end

    table.clear(Lifetime.Connections)

    if Lifetime.Env and Lifetime.Env.AICSession == Lifetime then
        Lifetime.Env.AICSession = nil
    end
end

Context.Lifetime = Lifetime
Context.Connect = Lifetime.Connect

do
    local Ok, Env = pcall(function()
        return type(getgenv) == "function" and getgenv() or nil
    end)

    Lifetime.Env = Ok and type(Env) == "table" and Env or nil
end

if Lifetime.Env then
    local Previous = Lifetime.Env.AICSession
    local Player = game:GetService("Players").LocalPlayer
    local PlayerGui = Player and Player:FindFirstChildOfClass("PlayerGui")

    if type(Previous) == "table" and type(Previous.Destroy) == "function" then
        print("[AIC] Stopping the previous run")
        local Ok, Error = pcall(Previous.Destroy)

        if not Ok then
            warn("[AIC] Could not stop the previous run:", Error)
        end
    elseif PlayerGui and PlayerGui:FindFirstChild("ENDFIELD_INDUSTRIES_UI") then
        --// A version from before this guard is running. It cannot be stopped
        --// from here, and two runs would fight over the character.
        warn("[AIC] An older version is already running. Rejoin to load " .. TITLE .. ".")
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "AIC",
                Text = "An older version is already running. Rejoin to load the new one.",
                Duration = 10,
            })
        end)
        return nil
    end

    Lifetime.Env.AICSession = Lifetime
end

--// The window is built first so its boot loader can report real progress:
--// fetching takes the first half of the bar, starting modules the rest.
local UI = nil
local FETCH_SHARE = 0.5

local function report(Fraction, Text)
    if UI then
        UI:SetLoadingProgress(Fraction, Text)
    end
end

local function fail(Message)
    --// The first line names the module, the last line of a traceback is the
    --// error itself. The loader only has room for a line, so it shows both
    --// and the whole traceback goes to the console.
    local Text = tostring(Message)
    local Headline = string.match(Text, "^[^\n]*") or Text
    --// The line after the module name is the error itself; the rest is the
    --// stack, which goes on the error screen instead of the status line.
    local Detail = string.match(Text, "\n([^\n]+)")

    if Detail then
        Headline = Headline .. "  //  " .. Detail
    end

    warn("[AIC] " .. Text)

    if UI then
        UI:SetLoadingProgress(nil, "LOAD FAILED  //  " .. Headline, true)
        pcall(function()
            UI:ShowError(Text)
        end)
    end

    --// The session stays registered with the failed window up, so running the
    --// script again removes it along with whatever already started.
    error(Message, 0)
end

local function checkSpec(Spec, Path)
    if type(Spec) ~= "table" or type(Spec.Start) ~= "function" then
        fail("Invalid module: " .. Path)
    end

    return Spec
end

local function fetchOnce(Path)
    local Body, Done = nil, false

    --// The download runs in its own coroutine so it can be abandoned: some
    --// executors stop answering a request instead of erroring it, and a
    --// single one of those used to leave the loader waiting forever.
    task.spawn(function()
        local Ok, Result = pcall(function()
            return game:HttpGet(BASE .. Path, true)
        end)

        if Ok then
            Body = Result
        end

        Done = true
    end)

    local Waited = 0

    while not Done and Waited < FETCH_TIMEOUT do
        task.wait(0.1)
        Waited += 0.1
    end

    if not Done then
        return nil
    end

    if type(Body) == "string" and Body ~= "" and not string.find(Body, "^404: Not Found") then
        return Body
    end

    return nil
end

--// Downloads a few files at a time. Asking an executor for all of them at
--// once is what left one of them stalled behind the rest; a worker pool keeps
--// the queue moving, and every file now finishes or times out, so the counter
--// the loader waits on always reaches zero.
local function fetchParallel(Paths)
    local Bodies = {}
    local Pending = #Paths
    local Next = 1

    local function Worker()
        while true do
            local Index = Next
            Next += 1

            local Path = Paths[Index]

            if not Path then
                return
            end

            for _ = 0, FETCH_RETRIES do
                Bodies[Path] = fetchOnce(Path)

                if Bodies[Path] then
                    break
                end
            end

            Pending -= 1
        end
    end

    for _ = 1, math.min(FETCH_WORKERS, #Paths) do
        task.spawn(Worker)
    end

    return Bodies, function()
        return Pending
    end
end

local function createWindow(Utils)
    local Window = Utils.new{ Title = TITLE, ManualLoading = true }

    --// A run that was stopped while still loading must not leave its window
    --// behind: an orphan window keeps drawing, keeps taking the mouse and no
    --// later run can close it.
    if not Lifetime.Alive then
        Window:Destroy()
        return nil
    end

    UI = Window
    Context.UI = Window

    Lifetime.OnEnd(function()
        Window:Destroy()
    end)

    return Window
end

local function loadLocal()
    local Sources = {}
    local Specs = {}

    local UIFolder = ROOT:FindFirstChild("UI")
    local UtilsModule = UIFolder and UIFolder:FindFirstChild("Utils")

    if UtilsModule and UtilsModule:IsA("ModuleScript") then
        createWindow(require(UtilsModule))
    end

    collect(ROOT, "", Sources)

    for Path, ModuleScript in pairs(Sources) do
        local Spec = checkSpec(require(ModuleScript), Path)
        Specs[Spec.Name] = Spec
    end

    return Specs
end

--// The modules come down in a few parts rather than one file per module (the
--// executor's queue stalled on ~77 requests) or one huge file (which blocked
--// the client while it arrived). Each part is fetched on its own and the run
--// yields between them, so the game keeps drawing frames.
local BUNDLE_PARTS = 40
--// Parts in flight together. One after another cost the sum of their round
--// trips, which is most of what made the boot feel slow.
local BUNDLE_WORKERS = 4

--// The bundle's part count, written next to the parts by
--// tools/build-bundle.ps1. Without it (an older build) the loader falls back
--// to walking the parts until one is missing.
local function fetchBundleParts()
    local Body = fetchOnce("Bundle/Manifest.lua")

    if not Body then
        return nil
    end

    local Chunk = loadstring(Body, "@Bundle/Manifest.lua")
    local Ok, Value = false, nil

    if Chunk then
        Ok, Value = pcall(Chunk)
    end

    if Ok and type(Value) == "table" and type(Value.Parts) == "number" and Value.Parts > 0 then
        return math.min(Value.Parts, BUNDLE_PARTS)
    end

    return nil
end

--// Part 1 holds the window library (tools/build-bundle.ps1 writes it first),
--// so the loader can be on screen while the rest is still coming down.
local function fetchSeed()
    for _ = 0, FETCH_RETRIES do
        local Body = fetchOnce("Bundle/Part1.lua")

        if Body then
            local Chunk = loadstring(Body, "@Bundle/Part1.lua")
            local Ok, Part = false, nil

            if Chunk then
                Ok, Part = pcall(Chunk)
            end

            if Ok and type(Part) == "table" then
                return Part
            end
        end
    end

    return nil
end

--// Parts 2 and up, merged into Map. A part that does not arrive costs its
--// modules one download each later, so a partial bundle still boots.
local function fetchBundleRest(Map, Parts)
    local Limit = Parts or BUNDLE_PARTS
    local Count = Limit - 1

    if Count < 1 then
        return Map
    end

    local Bodies = {}
    local Next, Done = 2, 0

    local function Worker()
        while true do
            local Index = Next
            Next += 1

            if Index > Limit then
                return
            end

            for _ = 0, FETCH_RETRIES do
                Bodies[Index] = fetchOnce(string.format("Bundle/Part%d.lua", Index))

                if Bodies[Index] then
                    break
                end
            end

            Done += 1
        end
    end

    for _ = 1, math.min(BUNDLE_WORKERS, Count) do
        task.spawn(Worker)
    end

    local Deadline = os.clock() + FETCH_DEADLINE

    while Done < Count and os.clock() < Deadline do
        report(FETCH_SHARE * 0.3 * (Done / Count), string.format("FETCHING MODULES  //  %d / %d", Done + 1, Limit))
        task.wait(0.05)
    end

    --// Without a manifest the count is unknown, so the run stops at the first
    --// part that is not there.
    if not Parts then
        while Limit > 2 and not Bodies[Limit] do
            Limit -= 1
        end
    end

    for Index = 2, Limit do
        if Bodies[Index] then
            local Chunk = loadstring(Bodies[Index], string.format("@Bundle/Part%d.lua", Index))
            local Ok, Part = false, nil

            if Chunk then
                Ok, Part = pcall(Chunk)
            end

            if Ok and type(Part) == "table" then
                for Path, Source in pairs(Part) do
                    Map[Path] = Source
                end
            end
        end

        report(FETCH_SHARE * 0.45 * (Index / Limit), string.format("READING MODULES  //  %d / %d", Index, Limit))

        --// A frame every few parts keeps the client drawing while the bundle
        --// is turned into module sources.
        if Index % 4 == 0 then
            task.wait()
        end
    end

    return Map
end

local function loadRemote()
    local Paths = table.clone(MODULES)
    table.insert(Paths, 1, UTILS_PATH)

    local Total = #Paths
    local Parts = fetchBundleParts()
    local Bundle = fetchSeed()
    local Bodies, GetPending

    --// The window goes up the moment its library is here, so the download
    --// runs behind the loader instead of in front of a frozen screen.
    if Bundle and type(Bundle[UTILS_PATH]) == "string" then
        local Chunk = loadstring(Bundle[UTILS_PATH], "@" .. UTILS_PATH)
        local Ok, Utils = false, nil

        if Chunk then
            Ok, Utils = pcall(Chunk)
        end

        if Ok and Utils then
            createWindow(Utils)
        else
            Bundle = nil
        end
    else
        Bundle = nil
    end

    if Bundle then
        fetchBundleRest(Bundle, Parts)

        --// The bundle is only a shortcut: a module missing from it (a part
        --// that did not arrive, or a module added after the last build) is
        --// simply downloaded on its own.
        Bodies = {}

        for _, Path in ipairs(Paths) do
            Bodies[Path] = Bundle[Path]
        end

        GetPending = function()
            return 0
        end
    else
        Bodies, GetPending = fetchParallel(Paths)
    end

    --// Show the window as soon as Utils arrives; the modules keep
    --// downloading behind the loader.
    local UtilsBody = Bodies[UTILS_PATH]

    while not UtilsBody and GetPending() > 0 do
        task.wait()
        UtilsBody = Bodies[UTILS_PATH]
    end

    if not UtilsBody then
        fail("Failed to fetch " .. UTILS_PATH)
    end

    --// The seed part usually put the window up already.
    if not UI then
        local UtilsChunk = loadstring(UtilsBody, "@" .. UTILS_PATH)

        if not UtilsChunk then
            fail("Failed to compile " .. UTILS_PATH)
        end

        createWindow(UtilsChunk())
    end

    --// A file that never answers can no longer hold the boot: the workers
    --// time out, and this gives the whole phase a hard limit as well, after
    --// which the files still missing are named one by one.
    local FetchDeadline = os.clock() + FETCH_DEADLINE

    while GetPending() > 0 and os.clock() < FetchDeadline do
        local Done = Total - GetPending()
        report(Done / Total * FETCH_SHARE, string.format("FETCHING MODULES  //  %d / %d", Done, Total))
        task.wait()
    end

    if GetPending() > 0 then
        report(FETCH_SHARE, string.format("FETCH TIMED OUT  //  %d / %d", Total - GetPending(), Total))
    end

    report(FETCH_SHARE, "COMPILING MODULES")

    local Specs = {}
    local Compiled = 0

    for _, Path in ipairs(MODULES) do
        local Body = Bodies[Path]

        --// Not in the bundle: a module added after the last build. One
        --// download is still better than failing the boot.
        if not Body and Bundle then
            Body = fetchOnce(Path)
            Bodies[Path] = Body
        end

        if not Body then
            fail("Failed to fetch " .. Path)
        end

        local Chunk, CompileError = loadstring(Body, "@" .. Path)

        if not Chunk then
            fail("Failed to compile " .. Path .. ": " .. tostring(CompileError))
        end

        local Spec = checkSpec(Chunk(), Path)
        Specs[Spec.Name] = Spec

        --// A few frames between batches: compiling and running every module in
        --// one stretch is what froze the client until the boot finished.
        Compiled += 1

        if Compiled % 4 == 0 then
            task.wait()
        end
    end

    return Specs
end

local Specs = ROOT and loadLocal() or loadRemote()
local SpecCount = 0

for _ in pairs(Specs) do
    SpecCount += 1
end

local Started = {}
local StartedCount = 0

local function start(Name)
    if Started[Name] then
        return Context.Modules[Name]
    end

    --// A newer run stopped this one while it was still starting. Building more
    --// modules now would only create controls in a window that is already
    --// gone, and their loops would throw every frame from then on.
    if not Lifetime.Alive then
        return nil
    end

    local Spec = assert(
        Specs[Name],
        "Missing dependency: " .. tostring(Name)
    )

    for _, Dependency in ipairs(Spec.Dependencies or {}) do
        if not Lifetime.Alive then
            return nil
        end

        start(Dependency)
    end

    report(
        FETCH_SHARE + StartedCount / math.max(1, SpecCount) * (1 - FETCH_SHARE),
        "STARTING  //  " .. Name
    )

    local Ok, Module = xpcall(Spec.Start, debug.traceback, Context)

    if not Ok then
        --// The error's own type is worth reporting: a module that raises a
        --// table has no message to show otherwise.
        fail(Name .. " failed to start\n" .. tostring(Module) .. "\n(error value: " .. type(Module) .. ")")
    end

    Context.Modules[Name] = Module
    Context[Name] = Module
    Started[Name] = true
    StartedCount += 1

    if Spec.IsFeature or (type(Module) == "table" and Module.IsFeature) then
        table.insert(Context.Features, Module)
    end

    return Module
end

for _, Name in ipairs(START_ORDER) do
    if not Lifetime.Alive then
        break
    end

    if Specs[Name] then
        start(Name)

        --// Each module builds its controls on start, so the game gets a frame
        --// back between them instead of waiting for all 76 to finish.
        task.wait()
    end
end

--// Anything not listed above, in a stable order.
local Remaining = {}
for Name in pairs(Specs) do
    if not Started[Name] then
        table.insert(Remaining, Name)
    end
end
table.sort(Remaining)
for _, Name in ipairs(Remaining) do
    if not Lifetime.Alive then
        break
    end

    start(Name)
    task.wait()
end

--// Controls that AFV2 places after every feature toggle (the health sliders
--// and the Debug Visualizer toggle). Built here so they land below the
--// toggles instead of wherever their module happened to start.
for _, Name in ipairs(START_ORDER) do
    if not Lifetime.Alive then
        break
    end

    local Module = Context.Modules[Name]

    if type(Module) == "table" and type(Module.BuildLateUI) == "function" then
        Module:BuildLateUI()
        task.wait()
    end
end

--// Runs once every control exists. ProfileSettings restores the last used
--// profile here, which touches controls owned by several other modules.
for _, Name in ipairs(START_ORDER) do
    if not Lifetime.Alive then
        break
    end

    local Module = Context.Modules[Name]

    if type(Module) == "table" and type(Module.Finalize) == "function" then
        Module:Finalize()
        task.wait()
    end
end

--// A newer run stopped this one while it was still loading: undo what was
--// built since, before anything starts looping on the heartbeat. Nothing has
--// started acting yet at this point, so there is nothing to stop beyond the
--// cleanups.
if not Lifetime.Alive then
    Lifetime.RunCleanups()
    print("[AIC] A newer run started while this one was loading; stopped.")
    return nil
end

Context.Heartbeat:Start(Context.Features)

--// Added last, so it runs first when the run ends: stop acting before the
--// modules tear down their own parts and the window goes.
Lifetime.OnEnd(function()
    Context.Heartbeat:Destroy()

    local Character = Context.Player and Context.Player.Character
    local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
    local Root = Character and Character:FindFirstChild("HumanoidRootPart")

    if Humanoid and Root then
        Humanoid:MoveTo(Root.Position)
    end
end)

if Context.UI then
    Context.UI:FinishLoading()
end

return Context
