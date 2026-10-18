-- AutoFarm bootstrap.
-- Every module returns {Name, Dependencies, Start(Context)}.

local TITLE = "AUTOMATED INDUSTRY COMPLEX v3.49"
local UTILS_PATH = "UI/Utils.lua"

--// A failed download is retried this many times before giving up.
local FETCH_RETRIES = 2

local BRANCH = "main"

--// Where every module is downloaded from. The default is this repository, so
--// what runs in the executor is what was pushed here - pointing at another
--// repo made a pushed fix invisible to it. Set getgenv().AICBaseURL before
--// loading to run from somewhere else: a fork, or
--// "https://raw.githubusercontent.com/<user>/<repo>/<sha>/" to pin one build.
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
        .. "/"
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
    "UI/Descriptions.lua",
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
    "Features/PartySystem.lua",
    "Features/ServerHop.lua",
    "Features/ServerUI.lua",
    "Features/FollowerGuard.lua",
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

--// Module name from its path: "Features/AutoFarming.lua" -> "AutoFarming".
--// Every module's Name matches its file name.
local START_ORDER = {}

for _, Path in ipairs(MODULES) do
    table.insert(START_ORDER, string.match(Path, "([^/]+)%.lua$"))
end

--// Modules that are not specs. UI/Utils is the UI library that Runtime
--// loads itself.
local NON_SPEC_MODULES = {
    ["UI/Utils.lua"] = true,
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
    --// Only the first line fits on the loader; the full text is raised.
    if UI then
        UI:SetLoadingProgress(nil, "LOAD FAILED  //  " .. string.match(Message, "^[^\n]*"), true)
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
    local Ok, Body = pcall(function()
        return game:HttpGet(BASE .. Path, true)
    end)

    if Ok and type(Body) == "string" and Body ~= "" and not string.find(Body, "^404: Not Found") then
        return Body
    end

    return nil
end

--// Starts every download at once. HttpGet yields, so fetching in parallel
--// costs about one round trip instead of one per file.
local function fetchParallel(Paths)
    local Bodies = {}
    local Pending = #Paths

    for _, Path in ipairs(Paths) do
        task.spawn(function()
            for _ = 0, FETCH_RETRIES do
                Bodies[Path] = fetchOnce(Path)

                if Bodies[Path] then
                    break
                end
            end

            Pending -= 1
        end)
    end

    return Bodies, function()
        return Pending
    end
end

local function createWindow(Utils)
    UI = Utils.new(TITLE, { ManualLoading = true })
    Context.UI = UI

    local Window = UI
    Lifetime.OnEnd(function()
        Window:Destroy()
    end)
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

local function loadRemote()
    local Paths = table.clone(MODULES)
    table.insert(Paths, 1, UTILS_PATH)

    local Bodies, GetPending = fetchParallel(Paths)
    local Total = #Paths

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

    local UtilsChunk = loadstring(UtilsBody, "@" .. UTILS_PATH)

    if not UtilsChunk then
        fail("Failed to compile " .. UTILS_PATH)
    end

    createWindow(UtilsChunk())

    while GetPending() > 0 do
        local Done = Total - GetPending()
        report(Done / Total * FETCH_SHARE, string.format("FETCHING MODULES  //  %d / %d", Done, Total))
        task.wait()
    end

    report(FETCH_SHARE, "COMPILING MODULES")

    local Specs = {}

    for _, Path in ipairs(MODULES) do
        local Body = Bodies[Path]

        if not Body then
            fail("Failed to fetch " .. Path)
        end

        local Chunk, CompileError = loadstring(Body, "@" .. Path)

        if not Chunk then
            fail("Failed to compile " .. Path .. ": " .. tostring(CompileError))
        end

        local Spec = checkSpec(Chunk(), Path)
        Specs[Spec.Name] = Spec
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

    local Spec = assert(
        Specs[Name],
        "Missing dependency: " .. tostring(Name)
    )

    for _, Dependency in ipairs(Spec.Dependencies or {}) do
        start(Dependency)
    end

    report(
        FETCH_SHARE + StartedCount / math.max(1, SpecCount) * (1 - FETCH_SHARE),
        "STARTING  //  " .. Name
    )

    local Ok, Module = xpcall(Spec.Start, debug.traceback, Context)

    if not Ok then
        fail(Name .. " failed to start\n" .. tostring(Module))
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
    if Specs[Name] then
        start(Name)
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
    start(Name)
end

--// Controls that AFV2 places after every feature toggle (the health sliders
--// and the Debug Visualizer toggle). Built here so they land below the
--// toggles instead of wherever their module happened to start.
for _, Name in ipairs(START_ORDER) do
    local Module = Context.Modules[Name]

    if type(Module) == "table" and type(Module.BuildLateUI) == "function" then
        Module:BuildLateUI()
    end
end

--// Runs once every control exists. ProfileSettings restores the last used
--// profile here, which touches controls owned by several other modules.
for _, Name in ipairs(START_ORDER) do
    local Module = Context.Modules[Name]

    if type(Module) == "table" and type(Module.Finalize) == "function" then
        Module:Finalize()
    end
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

--// A newer run stopped this one while it was still loading: undo what was
--// built since.
if not Lifetime.Alive then
    Lifetime.RunCleanups()
    print("[AIC] A newer run started while this one was loading; stopped.")
    return nil
end

if Context.UI then
    Context.UI:FinishLoading()
end

return Context
