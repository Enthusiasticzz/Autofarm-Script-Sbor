-- AutoQuest owns the Quest tab's quest loop.
--
-- Quest givers are the nodes in workspace.Interactions whose name starts with
-- "QuestGiver" (they are all called the same, so the ID child is what tells
-- them apart). Each one's prompt lives at
--   Giver.ProxBase.ProximityAttach.ProximityPrompt
-- and is both fired directly (fireproximityprompt, else InputHoldBegin/End)
-- and pressed through the game's own Interact binding, the same press Auto
-- Farm uses for doors.
--
-- The quest itself is read from the live tracker, not typed in:
--   PlayerGui.QuestUI_Root.Tracker.Content.Objectives.ObjectiveRow.Task
--   PlayerGui.QuestUI_Root.Tracker.Content.Objectives.ObjectiveRow.Count
-- Several ObjectiveRow rows are normal; every row with a Task counts. The
-- task text ("Defeat Boars") is matched against the mobs in workspace.Mobs by
-- their model name and Config.Entity value, plural forms included, so the
-- loop fights whatever the quest asks for without a list of mob names.
--
-- The dialog the giver puts up is clicked through: the visible Accept button
-- under QuestUI_Root.Dialogue is pressed with GuiClick until the tracker has
-- rows. Nothing here sends a remote the game did not already expose; the
-- QuestEvent "AssignQuest" assigner stays on the Assign By ID section.
--
-- The loop is a phase machine driven from the heartbeat: start -> travel ->
-- prompt -> accept -> kill -> idle. Every movement call happens after Auto
-- Farm's (Auto Farm runs earlier and does nothing while off), and switching
-- Auto Quest on pauses Auto Farm and Boss Route so only one loop moves the
-- character.
return {
    Name = "AutoQuest",
    IsFeature = true,
    Dependencies = {"Runtime", "Components", "GuiClick", "SaveConfig"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local PlayerGui = Context.PlayerGui
        local UIRef = Context.UIRef
        local AICUI = Context.AICUI
        local AICProfile = Context.AICProfile
        local AICFeature = Context.AICFeature
        local AICCombat = Context.AICCombat
        local AICCombatUtils = Context.AICCombatUtils
        local FeatureState = Context.Feature
        local GuiClick = Context.GuiClick
        local NotifyAction = Context.NotifyAction
        local CONFIG = Context.CONFIG

        local GIVER_FOLDER = "Interactions"
        local GIVER_PREFIX = "questgiver"
        local QUEST_GUI_NAME = "QuestUI_Root"
        local QUEST_ITEMS_NAME = "QuestItems"
        local TRIGGER_REMOTE_NAME = "TriggerQuest"
        local MOB_FOLDER = "Mobs"
        local NONE_OPTION = "No quest givers found"
        local DUMP_FILE = Context.PROFILE_FOLDER .. "/QuestDump.txt"

        --// Where the character stops in front of the giver; the prompt's own
        --// activation distance is about ten studs.
        local TRAVEL_STOP_DISTANCE = 6
        --// How often MoveTo is re-issued while travelling or chasing.
        local MOVE_INTERVAL = 0.2
        --// Giver list, tracker readout and mob list refresh rates.
        local GIVER_REFRESH_INTERVAL = 3
        local TRACKER_REFRESH_INTERVAL = 0.35
        local MOB_REFRESH_INTERVAL = 0.5
        --// The input handle is cleared on every respawn; while it is missing a
        --// new one is looked for at this rate rather than every frame.
        local BINDABLE_RETRY_INTERVAL = 1
        --// Prompt presses and Accept clicks. A dialog is two or three pages,
        --// so Accept has to be pressed a few times.
        local PROMPT_INTERVAL = 0.6
        local PROMPT_TRIES = 10
        local ACCEPT_INTERVAL = 0.35
        local ACCEPT_TRIES = 20
        --// Travelling that gets no closer than this for STUCK_WINDOW seconds
        --// counts as stuck, and teleports when Teleport If Stuck is on.
        local STUCK_WINDOW = 8
        local STUCK_PROGRESS = 4
        --// The tracker is given this long to show rows after the dialog ends
        --// before the loop reports that nothing was accepted.
        local QUEST_READ_GRACE = 4
        local STATUS_COLOR = {
            Work = Color3.fromRGB(120, 220, 140),
            Wait = Color3.fromRGB(230, 200, 120),
            Stop = Color3.fromRGB(235, 130, 130),
            Idle = Color3.fromRGB(160, 160, 160),
        }

        local PHASE_IDLE = "idle"
        local PHASE_START = "start"
        local PHASE_TRAVEL = "travel"
        local PHASE_PROMPT = "prompt"
        local PHASE_ACCEPT = "accept"
        local PHASE_KILL = "kill"

        --// Verbed quests that are not a fight. Anything not listed and not a
        --// kill verb is decided by whether the wording names a live mob.
        local KILL_VERBS = {
            defeat = true,
            kill = true,
            slay = true,
            eliminate = true,
            hunt = true,
            vanquish = true,
            destroy = true,
            exterminate = true,
            beat = true,
            fight = true,
            subdue = true,
        }
        local OTHER_VERBS = {
            collect = true,
            gather = true,
            find = true,
            retrieve = true,
            deliver = true,
            ["return"] = true,
            talk = true,
            speak = true,
            visit = true,
            reach = true,
            escort = true,
            purchase = true,
            buy = true,
            craft = true,
            mine = true,
            fish = true,
            catch = true,
            cook = true,
            use = true,
            equip = true,
        }
        --// Buttons a quest dialog may answer with, best first.
        local ACCEPT_NAMES = {
            "accept",
            "continue",
            "next",
            "finish",
            "complete",
            "ok",
            "yes",
            "confirm",
        }
        --// Plurals the s/es rules below would get wrong.
        local IRREGULAR = {
            wolves = "wolf",
            elves = "elf",
            thieves = "thief",
            mice = "mouse",
            men = "man",
            women = "woman",
            children = "child",
            feet = "foot",
            teeth = "tooth",
            geese = "goose",
        }

        local Module = {
            Name = "AutoQuest",
            IsFeature = true,
            S = {
                Phase = PHASE_IDLE,
                --// Label -> giver entry, and the entry the loop is using.
                Givers = {},
                Options = {},
                SelectedKey = nil,
                SelectedInstance = nil,
                ShownOption = nil,
                LastReadout = nil,
                TeleportIfStuck = true,
                --// Off unless asked for: the arguments of the TriggerQuest
                --// remote are a guess, and the prompt is the documented way.
                UseTriggerRemote = false,
                --// Row cache filled by GetObjectives.
                Rows = {},
                RowsAt = -10,
                Mobs = {},
                MobsAt = -10,
                GiversAt = -10,
                ReadoutAt = -10,
                Root = nil,
                RootAt = -10,
                PromptTries = 0,
                AcceptTries = 0,
                NextPromptAt = 0,
                NextAcceptAt = 0,
                MoveAt = 0,
                KillSince = 0,
                StuckAt = 0,
                --// Distance when the current stuck window opened; the walk is
                --// only stuck when it is barely closer at the end of it.
                StuckFrom = nil,
                ClickMethod = nil,
                BindableAt = -10,
                Character = nil,
                WasEnabled = false,
                Dead = false,
                StatusLabel = nil,
                TrackLabel = nil,
                GiverDropdown = nil,
            },
        }

        local S = Module.S

        ------------------------------------------------------------------------
        --// Text helpers
        ------------------------------------------------------------------------

        local function Trim(Text)
            return (string.gsub(tostring(Text or ""), "^%s*(.-)%s*$", "%1"))
        end

        --// Lower case, single spaced words: "Defeat Boars!" -> "defeat boars".
        local function Normalize(Text)
            return Trim((string.gsub(string.lower(tostring(Text or "")), "[^%w]+", " ")))
        end

        local function Compact(Text)
            return (string.gsub(Normalize(Text), "%s+", ""))
        end

        --// Crude singular of the last word, enough for mob names ("Boars",
        --// "Wolves", "Foxes").
        local function Singular(Text)
            local Words = {}

            for Word in string.gmatch(Normalize(Text), "%S+") do
                table.insert(Words, Word)
            end

            local Last = table.remove(Words)

            if not Last then
                return ""
            end

            local Known = IRREGULAR[Last]

            if Known then
                Last = Known
            elseif string.sub(Last, -3) == "ies" and #Last > 4 then
                Last = string.sub(Last, 1, -4) .. "y"
            elseif string.sub(Last, -2) == "es" and #Last > 3 then
                local Stem = string.sub(Last, 1, -3)

                if string.find(Stem, "[sxz]$") or string.find(Stem, "ch$") or string.find(Stem, "sh$") then
                    Last = Stem
                else
                    Last = string.sub(Last, 1, -2)
                end
            elseif string.sub(Last, -1) == "s" and string.sub(Last, -2) ~= "ss" and #Last > 2 then
                Last = string.sub(Last, 1, -2)
            end

            table.insert(Words, Last)

            return table.concat(Words, " ")
        end

        --// "Defeat Boars" -> { Verb = "defeat", Normal = "boars", Compact = "boars" }.
        local function ObjectiveKeys(Task)
            local Rest = Normalize(Task)
            local Verb = nil

            for _ = 1, 2 do
                local Word, After = string.match(Rest, "^(%a+)%s+(.+)$")

                if Word and (KILL_VERBS[Word] or OTHER_VERBS[Word]) then
                    Verb = Verb or Word
                    Rest = After
                else
                    break
                end
            end

            Rest = Trim((string.gsub(Rest, "%d+", " ")))
            Rest = Trim((string.gsub(Rest, "^the%s+", "")))

            return { Verb = Verb, Normal = Rest, Compact = Compact(Rest) }
        end

        --// Whether a mob name is the one the wording names: equal, singular
        --// in either direction, or the mob's own words inside the wording
        --// ("Defeat Great Boars" finds "Great Boar").
        local function NameMatches(Keys, Name)
            local MobNormal = Normalize(Name)
            local MobCompact = Compact(Name)

            if Keys.Compact == "" or MobCompact == "" then
                return false
            end

            if Keys.Compact == MobCompact then
                return true
            end

            local ObjectiveSingular = Compact(Singular(Keys.Normal))
            local MobSingular = Compact(Singular(MobNormal))

            if ObjectiveSingular == MobCompact
                or Keys.Compact == MobSingular
                or (ObjectiveSingular ~= "" and ObjectiveSingular == MobSingular)
            then
                return true
            end

            local Wording = " " .. Keys.Normal .. " "

            if string.find(Wording, " " .. MobNormal .. " ", 1, true) then
                return true
            end

            return string.find(Wording, " " .. Singular(MobNormal) .. " ", 1, true) ~= nil
        end

        Module.ObjectiveKeys = ObjectiveKeys
        Module.NameMatches = NameMatches

        ------------------------------------------------------------------------
        --// PlayerGui lookups
        ------------------------------------------------------------------------

        local function GetGui()
            if PlayerGui and PlayerGui.Parent then
                return PlayerGui
            end

            PlayerGui = Player:FindFirstChildOfClass("PlayerGui")

            return PlayerGui
        end

        --// Breadth first, case insensitive, so a renamed or slightly moved
        --// node is still found instead of only the exact path.
        local function FindInTree(Root, Name, MaxDepth)
            if not Root then
                return nil
            end

            local Wanted = string.lower(Name)
            local Level = { Root }

            for _ = 1, MaxDepth or 3 do
                local Next = {}

                for _, Node in ipairs(Level) do
                    for _, Child in ipairs(Node:GetChildren()) do
                        if string.lower(Child.Name) == Wanted then
                            return Child
                        end

                        table.insert(Next, Child)
                    end
                end

                Level = Next
            end

            return nil
        end

        local function GetQuestRoot()
            local Now = os.clock()

            if S.Root and S.Root.Parent and Now - S.RootAt < 2 then
                return S.Root
            end

            S.RootAt = Now
            S.Root = nil

            local Gui = GetGui()

            if not Gui then
                return nil
            end

            S.Root = Gui:FindFirstChild(QUEST_GUI_NAME) or FindInTree(Gui, QUEST_GUI_NAME, 2)

            return S.Root
        end

        --// The text a node shows: its own Text, a ValueBase's value, or the
        --// first non-empty label under it. The tracker may use either.
        local function ReadText(Node)
            if not Node then
                return ""
            end

            if Node:IsA("TextLabel") or Node:IsA("TextButton") or Node:IsA("TextBox") then
                return Trim(Node.Text)
            end

            if Node:IsA("ValueBase") then
                local Ok, Value = pcall(function()
                    return Node.Value
                end)

                return Ok and Trim(tostring(Value)) or ""
            end

            local Attribute = Node:GetAttribute("Text")

            if type(Attribute) == "string" and Trim(Attribute) ~= "" then
                return Trim(Attribute)
            end

            for _, Descendant in ipairs(Node:GetDescendants()) do
                if Descendant:IsA("TextLabel")
                    or Descendant:IsA("TextButton")
                    or Descendant:IsA("TextBox")
                then
                    local Text = Trim(Descendant.Text)

                    if Text ~= "" then
                        return Text
                    end
                end
            end

            return ""
        end

        --// "3/10" (or "3 / 10") -> 3, 10. One number is read as the count so
        --// far, with no total.
        local function ParseCount(Text)
            local Current, Total = string.match(tostring(Text or ""), "(%d+)%s*/%s*(%d+)")

            if Current then
                return tonumber(Current), tonumber(Total)
            end

            local Single = string.match(tostring(Text or ""), "(%d+)")

            return Single and tonumber(Single) or nil, nil
        end

        ------------------------------------------------------------------------
        --// The live quest tracker
        ------------------------------------------------------------------------

        --// Drawn at all: every GuiObject ancestor visible and every
        --// LayerCollector above it enabled. The game hides the whole quest
        --// UI when nothing is tracked, and its rows stay behind.
        local function IsNodeShown(Node)
            local Cursor = Node

            while Cursor do
                if Cursor:IsA("LayerCollector") and not Cursor.Enabled then
                    return false
                end

                if Cursor:IsA("GuiObject") and not Cursor.Visible then
                    return false
                end

                Cursor = Cursor.Parent
            end

            return true
        end

        local function ReadObjectives()
            local Rows = {}
            local Root = GetQuestRoot()

            if not Root then
                return Rows
            end

            local Tracker = Root:FindFirstChild("Tracker") or FindInTree(Root, "Tracker", 2)

            if not Tracker then
                return Rows
            end

            local Content = Tracker:FindFirstChild("Content") or Tracker
            local Objectives = Content:FindFirstChild("Objectives")
                or FindInTree(Content, "Objectives", 2)

            if not Objectives or not IsNodeShown(Objectives) then
                return Rows
            end

            for _, Row in ipairs(Objectives:GetChildren()) do
                if string.find(string.lower(Row.Name), "objective", 1, true) and IsNodeShown(Row) then
                    local TaskNode = Row:FindFirstChild("Task") or FindInTree(Row, "Task", 2)
                    local CountNode = Row:FindFirstChild("Count") or FindInTree(Row, "Count", 2)
                    local Task = ReadText(TaskNode)
                    local CountText = ReadText(CountNode)
                    local Current, Total = ParseCount(CountText)

                    if Task ~= "" then
                        table.insert(Rows, {
                            Task = Task,
                            Current = Current,
                            Total = Total,
                            Text = CountText,
                            Instance = Row,
                            Done = Current ~= nil and Total ~= nil and Total > 0 and Current >= Total,
                        })
                    end
                end
            end

            return Rows
        end

        --// The rows, refreshed at most every TRACKER_REFRESH_INTERVAL unless
        --// Force is passed (the diagnostic dump always reads live).
        function Module.GetObjectives(Force)
            local Now = os.clock()

            if Force or Now - S.RowsAt >= TRACKER_REFRESH_INTERVAL then
                S.Rows = ReadObjectives()
                S.RowsAt = Now
            end

            return S.Rows
        end

        ------------------------------------------------------------------------
        --// Quest givers
        ------------------------------------------------------------------------

        local function ReadId(Giver)
            for _, Name in ipairs({ "ID", "Id", "QuestID", "QuestId" }) do
                local Node = Giver:FindFirstChild(Name)

                if Node then
                    if Node:IsA("ValueBase") then
                        return Trim(tostring(Node.Value))
                    end

                    return Trim(ReadText(Node))
                end
            end

            local Attribute = Giver:GetAttribute("ID") or Giver:GetAttribute("Id")

            if Attribute ~= nil then
                return Trim(tostring(Attribute))
            end

            return ""
        end

        local function ReadTitle(Giver)
            for _, Name in ipairs({ "Title", "QuestName", "DisplayName", "Label", "Name" }) do
                local Node = Giver:FindFirstChild(Name)

                if Node then
                    local Text = Trim(ReadText(Node))

                    if Text ~= "" then
                        return Text
                    end
                end
            end

            return ""
        end

        local function FindPrompt(Giver)
            --// The documented path first, then anything prompt shaped.
            local ProxBase = Giver:FindFirstChild("ProxBase")
            local Attach = ProxBase and ProxBase:FindFirstChild("ProximityAttach")

            if Attach and Attach:FindFirstChildOfClass("ProximityPrompt") then
                return Attach:FindFirstChildOfClass("ProximityPrompt")
            end

            local Prompt = Giver:FindFirstChild("ProximityPrompt", true)

            if Prompt and Prompt:IsA("ProximityPrompt") then
                return Prompt
            end

            return Giver:FindFirstChildOfClass("ProximityPrompt")
        end

        --// Where the prompt stands: the part it belongs to, through an
        --// Attachment or a Model, so the character is put in range of it.
        local function GetPromptPosition(Prompt)
            local Node = Prompt and Prompt.Parent

            for _ = 1, 6 do
                if not Node then
                    return nil
                end

                if Node:IsA("BasePart") then
                    return Node.Position
                end

                if Node:IsA("Attachment") then
                    return Node.WorldPosition
                end

                if Node:IsA("Model") then
                    local Primary = Node.PrimaryPart or Node:FindFirstChildWhichIsA("BasePart")

                    if Primary then
                        return Primary.Position
                    end
                end

                Node = Node.Parent
            end

            return nil
        end

        local function GetGiverPosition(Entry)
            if not Entry then
                return nil
            end

            if Entry.Position and Entry.Prompt and Entry.Prompt.Parent then
                return Entry.Position
            end

            Entry.Prompt = FindPrompt(Entry.Instance)
            Entry.Position = GetPromptPosition(Entry.Prompt)

            if not Entry.Position and Entry.Instance then
                local Part = Entry.Instance:FindFirstChildWhichIsA("BasePart", true)

                if Part then
                    Entry.Position = Part.Position
                end
            end

            return Entry.Position
        end

        function Module.GetSelectedGiver()
            if S.SelectedInstance and S.SelectedInstance.Parent then
                local Entry = S.Givers[S.SelectedKey]

                if Entry and Entry.Instance == S.SelectedInstance then
                    return Entry
                end

                --// Still there but renamed out of the list: build a stand-in
                --// so the loop keeps working between list refreshes.
                return {
                    Instance = S.SelectedInstance,
                    Key = S.SelectedKey,
                    Label = S.SelectedKey or S.SelectedInstance.Name,
                    Id = ReadId(S.SelectedInstance),
                }
            end

            return nil
        end

        local function SelectEntry(Entry, Silent)
            S.SelectedKey = Entry.Key
            S.SelectedInstance = Entry.Instance

            if S.GiverDropdown and Entry.Key then
                S.GiverDropdown:Set(Entry.Key, Silent ~= false)
            end
        end

        local function RefreshGivers(Now)
            if Now - S.GiversAt < GIVER_REFRESH_INTERVAL then
                return
            end

            S.GiversAt = Now

            local Interactions = workspace:FindFirstChild(GIVER_FOLDER)
                or workspace:FindFirstChild(GIVER_FOLDER, true)

            local Entries = {}

            for _, Node in ipairs(Interactions and Interactions:GetDescendants() or {}) do
                if string.find(string.lower(Node.Name), GIVER_PREFIX, 1, true) == 1 then
                    table.insert(Entries, {
                        Instance = Node,
                        Id = ReadId(Node),
                        IdNumber = tonumber(ReadId(Node)),
                        Path = Node:GetFullName(),
                    })
                end
            end

            table.sort(Entries, function(A, B)
                if A.IdNumber and B.IdNumber and A.IdNumber ~= B.IdNumber then
                    return A.IdNumber < B.IdNumber
                end

                return A.Path < B.Path
            end)

            local Givers, Labels = {}, {}

            for Index, Item in ipairs(Entries) do
                local Node = Item.Instance
                local Id = Item.Id
                local Title = ReadTitle(Node)
                local Base = Id ~= "" and ("Quest " .. Id) or Node.Name

                if Title ~= "" then
                    Base = Base .. "  ·  " .. Title
                end

                local Label = Base
                local Suffix = 2

                while Givers[Label] do
                    Label = Base .. " #" .. Suffix
                    Suffix += 1
                end

                Givers[Label] = {
                    Key = Label,
                    Id = Id,
                    Title = Title,
                    Label = Label,
                    Instance = Node,
                    Order = Index,
                }
                table.insert(Labels, Label)
            end

            S.Givers = Givers

            local Options = #Labels > 0 and Labels or { NONE_OPTION }

            if table.concat(Options, "\n") ~= table.concat(S.Options, "\n") then
                S.Options = Options

                if S.GiverDropdown then
                    S.GiverDropdown:SetOptions(Options)
                end
            end

            --// The selection survives a refresh when its giver is still here.
            local Selected = nil

            for Label, Entry in pairs(Givers) do
                if Entry.Instance == S.SelectedInstance then
                    Selected = Entry
                    S.SelectedKey = Label
                    break
                end
            end

            if S.SelectedInstance and not S.SelectedInstance.Parent then
                S.SelectedInstance, S.SelectedKey = nil, nil
            end

            if not Selected and not (S.SelectedInstance and S.SelectedInstance.Parent) then
                S.SelectedInstance, S.SelectedKey = nil, nil

                --// One is picked for the user on the first fill, so the tab
                --// does something without a choice having been made.
                if #Labels > 0 then
                    SelectEntry(Givers[Labels[1]], true)
                end
            end

            local Shown = (S.SelectedKey and Givers[S.SelectedKey]) and S.SelectedKey
                or (#Labels == 0 and NONE_OPTION or nil)

            if S.GiverDropdown and Shown and Shown ~= S.ShownOption then
                S.ShownOption = Shown
                S.GiverDropdown:Set(Shown, true)
            end
        end

        ------------------------------------------------------------------------
        --// Mobs
        ------------------------------------------------------------------------

        local function RefreshMobs(Now)
            if Now - S.MobsAt < MOB_REFRESH_INTERVAL then
                return S.Mobs
            end

            S.MobsAt = Now
            S.Mobs = {}

            local Folder = workspace:FindFirstChild(MOB_FOLDER)

            for _, Model in ipairs(Folder and Folder:GetChildren() or {}) do
                if Model:IsA("Model") then
                    local Humanoid = Model:FindFirstChildOfClass("Humanoid")
                    local Root = Model:FindFirstChild("HumanoidRootPart")

                    if Humanoid and Root and Humanoid.Health > 0 then
                        table.insert(S.Mobs, Model)
                    end
                end
            end

            return S.Mobs
        end

        --// The names a mob answers to: its model name and the entity its
        --// Config carries (workspace.Mobs models are named by entity).
        local function MobNames(Model)
            local Names = { Model.Name }
            local Config = Model:FindFirstChild("Config")

            if Config then
                local Entity = Config:FindFirstChild("Entity")

                if Entity and Entity:IsA("ValueBase") and Trim(tostring(Entity.Value)) ~= "" then
                    table.insert(Names, tostring(Entity.Value))
                end
            end

            for _, Attribute in ipairs({ "Name", "Entity" }) do
                local Value = Model:GetAttribute(Attribute)

                if type(Value) == "string" and Value ~= "" then
                    table.insert(Names, Value)
                end
            end

            return Names
        end

        local function MobMatches(Model, Keys)
            for _, Name in ipairs(MobNames(Model)) do
                if NameMatches(Keys, Name) then
                    return true
                end
            end

            return false
        end

        --// True when any live mob answers to the wording, which is what makes
        --// "Boars: 0/10" a kill objective even without a verb.
        local function MatchesAnyMob(Task)
            local Keys = ObjectiveKeys(Task)

            for _, Model in ipairs(RefreshMobs(os.clock())) do
                if MobMatches(Model, Keys) then
                    return true
                end
            end

            return false
        end

        function Module.GetMobs()
            return RefreshMobs(os.clock())
        end

        --// Whether a live mob answers to this wording (QuestHelper draws the
        --// ones the tracker asks for).
        function Module.MobMatches(Model, Task)
            return MobMatches(Model, ObjectiveKeys(Task))
        end

        --// A fight when the wording names a mob, an errand when it names
        --// something to fetch instead.
        function Module.IsKillTask(Task)
            local Keys = ObjectiveKeys(Task)

            if Keys.Verb then
                if KILL_VERBS[Keys.Verb] then
                    return true
                end

                if OTHER_VERBS[Keys.Verb] then
                    return false
                end
            end

            return MatchesAnyMob(Task)
        end

        --// Nearest live mob that answers to the wording, with its distance.
        local function FindMob(Task, Now)
            local Keys = ObjectiveKeys(Task)
            local _, _, RootPart = Runtime:GetCharacter()
            local Best, BestDistance = nil, nil
            local Origin = RootPart and RootPart.Position

            for _, Model in ipairs(RefreshMobs(Now)) do
                if MobMatches(Model, Keys) then
                    local Root = Model:FindFirstChild("HumanoidRootPart")

                    if Root then
                        local Distance = Origin and (Root.Position - Origin).Magnitude or 0

                        if not BestDistance or Distance < BestDistance then
                            Best, BestDistance = Model, Distance
                        end
                    end
                end
            end

            return Best, BestDistance
        end

        ------------------------------------------------------------------------
        --// The dialog
        ------------------------------------------------------------------------

        local function FindDialog()
            local Root = GetQuestRoot()

            if not Root then
                return nil
            end

            local Dialogue = Root:FindFirstChild("Dialogue") or FindInTree(Root, "Dialogue", 2)

            if not Dialogue or not IsNodeShown(Dialogue) then
                return nil
            end

            return Dialogue
        end

        --// The button the dialog advances with: the visible one whose name
        --// matches ACCEPT_NAMES best ("Accept" before "Continue").
        local function FindAcceptButton()
            local Dialogue = FindDialog()

            if not Dialogue then
                return nil
            end

            local Buttons = {}

            local function Collect(Node, Depth)
                if Depth > 4 then
                    return
                end

                for _, Child in ipairs(Node:GetChildren()) do
                    if Child:IsA("GuiButton") then
                        table.insert(Buttons, Child)
                    end
                    Collect(Child, Depth + 1)
                end
            end

            Collect(Dialogue, 0)

            local Best, BestScore = nil, nil

            for _, Button in ipairs(Buttons) do
                if GuiClick.IsOnScreen(Button) then
                    local Lower = string.lower(Button.Name)
                    local Score = nil

                    for Index, Name in ipairs(ACCEPT_NAMES) do
                        if string.find(Lower, Name, 1, true) then
                            Score = Index
                            break
                        end
                    end

                    if Score and (not BestScore or Score < BestScore) then
                        Best, BestScore = Button, Score
                    end
                end
            end

            return Best
        end

        local function ClickAccept()
            local Button = FindAcceptButton()

            if not Button then
                return false
            end

            local Method = GuiClick.Click(Button, S.ClickMethod)

            if Method then
                S.ClickMethod = Method
            end

            return Method ~= nil
        end

        ------------------------------------------------------------------------
        --// Prompt and movement
        ------------------------------------------------------------------------

        --// The game's input BindableFunction, the handle every combat press
        --// goes through (EquipButton, AttackButton, InteractButton). Bootstrap
        --// clears the runtime's copy on every respawn and only Auto Farm ever
        --// looks it up again, so with Auto Farm paused the character used to
        --// stand at a mob unable to swing: the handle was nil.
        local function GetInputBindable()
            local Existing = Runtime.GetInputBindableFunction and Runtime:GetInputBindableFunction()

            if Existing and Existing.Parent then
                return Existing
            end

            local Now = os.clock()

            if Now - S.BindableAt < BINDABLE_RETRY_INTERVAL then
                return nil
            end

            S.BindableAt = Now

            local Gui = GetGui()
            local Bindable = Gui and Gui:FindFirstChild("InputBindableFunction", true)

            if Bindable and Bindable:IsA("BindableFunction") then
                Runtime:SetInputBindableFunction(Bindable)
                return Bindable
            end

            return nil
        end

        --// The farm's own weapon draw, called exactly as it does: EquipButton
        --// through the input handle, and true means the frame was spent
        --// drawing and the caller should give it up. AttackButton does nothing
        --// while the sword is sheathed, which is what made the loop walk up to
        --// a mob and stand there.
        local function DrawWeapon(Now, Character)
            local Input = GetInputBindable()
            local Sword = Character and Character:FindFirstChild("Sword")
            local MainWeld = Sword and Sword:FindFirstChild("MainWeld", true)

            if not Input or not MainWeld or not AICFeature.EnsureWeaponDrawnRaw then
                return false
            end

            local Ok, Drew = pcall(AICFeature.EnsureWeaponDrawnRaw, Now, Input, MainWeld)

            return Ok and Drew == true
        end

        --// Fires the prompt the way an executor can (fireproximityprompt, else
        --// the local hold), and presses the game's own Interact binding as
        --// well: that is what Auto Farm uses for doors and levers, and it uses
        --// whatever prompt the character stands in.
        --// The remote the game keeps on its QuestItems folder. It is only a
        --// fallback for a giver whose prompt opens nothing, because what it
        --// takes is unknown; a RemoteFunction is never called (InvokeServer
        --// would block the heartbeat on the server's answer).
        local function GetTriggerRemote()
            local Items = workspace:FindFirstChild(QUEST_ITEMS_NAME)
                or workspace:FindFirstChild(QUEST_ITEMS_NAME, true)
            local Remote = Items and Items:FindFirstChild(TRIGGER_REMOTE_NAME, true)

            if Remote and Remote:IsA("RemoteEvent") then
                return Remote
            end

            return nil
        end

        local function FirePrompt(Prompt)
            if not Prompt or not Prompt.Parent then
                return false
            end

            local Fired = false

            if type(fireproximityprompt) == "function" then
                Fired = pcall(fireproximityprompt, Prompt)
            end

            if not Fired then
                pcall(function()
                    Prompt:InputHoldBegin()
                end)

                local Hold = math.max(tonumber(Prompt.HoldDuration) or 0, 0.05)

                task.delay(Hold, function()
                    pcall(function()
                        if Prompt.Parent then
                            Prompt:InputHoldEnd()
                        end
                    end)
                end)

                Fired = true
            end

            local Bindable = GetInputBindable()

            if Bindable then
                pcall(function()
                    Bindable:Invoke("InteractButton", Enum.UserInputState.Begin)
                end)
            end

            return Fired
        end

        local function MoveTo(Position, Now, Force)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart or Humanoid.Health <= 0 then
                return
            end

            if not Force and Now < S.MoveAt then
                return
            end

            S.MoveAt = Now + MOVE_INTERVAL

            if AICCombatUtils.DoJumpIfObstacle then
                pcall(AICCombatUtils.DoJumpIfObstacle, Position)
            end

            Humanoid:MoveTo(Position)
        end

        local function StandStill()
            local _, Humanoid = Runtime:GetCharacter()

            if Humanoid then
                Humanoid:Move(Vector3.zero)
            end
        end

        local function TeleportTo(Position)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Position or not Humanoid or not RootPart or Humanoid.Health <= 0 then
                return false
            end

            local Ok = pcall(function()
                RootPart.CFrame = CFrame.new(Position + Vector3.new(0, 3, 0))
            end)

            if Ok and Runtime.MuteInteract then
                Runtime:MuteInteract(2)
            end

            return Ok
        end

        --// The farm's fight, without its Enemy Priority gate: draw first, close
        --// in with its own combat jump, then swing. Enemy Priority decides what
        --// Auto Farm hunts, and quest mobs are not on that list, so the swing
        --// goes through AICCombat.AttackTarget — the same entry point a boss
        --// stop uses, which takes the mob it is given.
        local function FightMob(Mob, Now)
            local Character, Humanoid, RootPart = Runtime:GetCharacter()
            local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

            if not Humanoid or not RootPart or not MobRoot or Humanoid.Health <= 0 then
                return
            end

            if DrawWeapon(Now, Character) then
                return
            end

            local Distance = (MobRoot.Position - RootPart.Position).Magnitude
            local Reach = tonumber(CONFIG.PLAYER_ATTACK_DISTANCE) or 12

            if Distance > Reach and Now >= S.MoveAt then
                S.MoveAt = Now + MOVE_INTERVAL

                local Jump = AICCombatUtils.DoCombatJumpIfObstacle

                if Jump then
                    pcall(Jump, MobRoot.Position)
                end

                Humanoid:MoveTo(MobRoot.Position)
            end

            AICCombat.AttackTarget(Mob, Now)
        end

        ------------------------------------------------------------------------
        --// Phases
        ------------------------------------------------------------------------

        local function SetStatus(Text, Color)
            if S.StatusLabel then
                S.StatusLabel:Set("QUEST  //  " .. Text)
                S.StatusLabel:SetColor(Color or STATUS_COLOR.Work)
            end

            if AICFeature.SetFarmState then
                AICFeature.SetFarmState("AUTO QUEST " .. Text)
            end
        end

        local function PauseFarm()
            if FeatureState.AutoFarm and FeatureState.AutoFarm.Enabled then
                FeatureState.AutoFarm.Enabled = false
                AICFeature.S.Enabled = false

                if AICUI.SetFeatureComponent then
                    AICUI.SetFeatureComponent("AutoFarm", false)
                end

                NotifyAction("QUEST", "Auto Farm paused while the quest runs", 5)

                if AICProfile and AICProfile.QueueProfileSave then
                    AICProfile.QueueProfileSave()
                end
            end

            if FeatureState.BossRoute and FeatureState.BossRoute.Enabled then
                FeatureState.BossRoute.Enabled = false

                if AICUI.SetFeatureComponent then
                    AICUI.SetFeatureComponent("BossRoute", false)
                end

                if AICFeature.StopBossRoute then
                    AICFeature.StopBossRoute()
                end
            end
        end

        local function BeginQuest(Now)
            local Rows = Module.GetObjectives(true)

            if #Rows > 0 then
                S.Phase = PHASE_KILL
                S.KillSince = Now

                return
            end

            local Giver = Module.GetSelectedGiver()

            if not Giver then
                S.Phase = PHASE_IDLE
                SetStatus("PICK A QUEST GIVER", STATUS_COLOR.Wait)

                return
            end

            S.Phase = PHASE_TRAVEL
            S.StuckAt = Now
            S.StuckFrom = nil
            S.PromptTries = 0
            S.AcceptTries = 0

            SetStatus("GOING TO " .. Giver.Label, STATUS_COLOR.Work)
        end

        local function StepTravel(Now)
            local Giver = Module.GetSelectedGiver()

            if not Giver then
                S.Phase = PHASE_IDLE
                SetStatus("QUEST GIVER GONE — REFRESH", STATUS_COLOR.Stop)

                return
            end

            local Position = GetGiverPosition(Giver)

            if not Position then
                S.Phase = PHASE_IDLE
                SetStatus("NO PROMPT ON " .. Giver.Label, STATUS_COLOR.Stop)

                return
            end

            local _, _, RootPart = Runtime:GetCharacter()

            if not RootPart then
                return
            end

            local Distance = (Position - RootPart.Position).Magnitude

            if Distance <= TRAVEL_STOP_DISTANCE then
                S.Phase = PHASE_PROMPT
                S.PromptTries = 0
                S.NextPromptAt = 0

                return
            end

            --// Walked a whole window without getting meaningfully closer:
            --// the way there is blocked. Measured from the distance the
            --// window opened on, not from the closest ever seen, so a long
            --// approach that is still closing is not mistaken for a stuck one.
            if not S.StuckFrom then
                S.StuckFrom = Distance
            end

            if Now - S.StuckAt >= STUCK_WINDOW then
                if Distance > S.StuckFrom - STUCK_PROGRESS then
                    if S.TeleportIfStuck then
                        if TeleportTo(Position) then
                            NotifyAction("QUEST", "Walk was stuck; teleported to " .. Giver.Label, 4)
                            S.Phase = PHASE_PROMPT
                            S.PromptTries = 0
                            S.NextPromptAt = 0

                            return
                        end
                    else
                        S.Phase = PHASE_IDLE
                        SetStatus("STUCK — TURN ON TELEPORT IF STUCK", STATUS_COLOR.Stop)

                        return
                    end
                end

                S.StuckAt = Now
                S.StuckFrom = Distance
            end

            MoveTo(Position, Now)

            SetStatus(string.format("GOING TO %s  %d STUDS", Giver.Label, math.floor(Distance)), STATUS_COLOR.Work)
        end

        local function StepPrompt(Now)
            local Rows = Module.GetObjectives()

            if #Rows > 0 then
                S.Phase = PHASE_KILL
                S.KillSince = Now

                return
            end

            if FindAcceptButton() then
                S.Phase = PHASE_ACCEPT
                S.AcceptTries = 0
                S.NextAcceptAt = 0

                return
            end

            local Giver = Module.GetSelectedGiver()

            if not Giver then
                S.Phase = PHASE_IDLE
                SetStatus("QUEST GIVER GONE — REFRESH", STATUS_COLOR.Stop)

                return
            end

            if Now >= S.NextPromptAt then
                S.NextPromptAt = Now + PROMPT_INTERVAL
                S.PromptTries += 1
                FirePrompt(Giver.Prompt or FindPrompt(Giver.Instance))
                SetStatus("ASKING " .. Giver.Label, STATUS_COLOR.Work)

                --// Every third attempt, when the toggle is on: the game's
                --// own quest trigger, in case the prompt is the wrong way
                --// into this giver.
                if S.UseTriggerRemote and S.PromptTries % 3 == 0 and not FindAcceptButton() then
                    local Remote = GetTriggerRemote()

                    if Remote then
                        pcall(function()
                            Remote:FireServer(tonumber(Giver.Id) or Giver.Id)
                        end)
                    end
                end

                if S.PromptTries >= PROMPT_TRIES then
                    S.Phase = PHASE_IDLE
                    NotifyAction("QUEST", "No dialog came up from " .. Giver.Label, 5)
                    SetStatus("NO DIALOG — CHECK THE GIVER", STATUS_COLOR.Stop)

                    return
                end
            end

            --// Keep close, in case the character drifted out of the prompt's
            --// range while the dialog was being asked for.
            local Position = GetGiverPosition(Giver)

            if Position then
                local _, _, RootPart = Runtime:GetCharacter()

                if RootPart and (Position - RootPart.Position).Magnitude > TRAVEL_STOP_DISTANCE then
                    MoveTo(Position, Now)
                end
            end
        end

        local function StepAccept(Now)
            local Rows = Module.GetObjectives()

            if #Rows > 0 then
                S.Phase = PHASE_KILL
                S.KillSince = Now

                return
            end

            if not FindDialog() then
                --// The dialog closed without a quest: ask the giver again.
                if S.PromptTries >= PROMPT_TRIES then
                    S.Phase = PHASE_IDLE
                    SetStatus("NO QUEST ACCEPTED", STATUS_COLOR.Stop)
                else
                    S.Phase = PHASE_PROMPT
                    S.PromptTries += 1
                    S.NextPromptAt = Now + 1
                end

                return
            end

            if Now >= S.NextAcceptAt then
                S.NextAcceptAt = Now + ACCEPT_INTERVAL
                S.AcceptTries += 1

                if not ClickAccept() then
                    SetStatus("WAITING ON THE DIALOG", STATUS_COLOR.Wait)
                else
                    SetStatus("ACCEPTING THE QUEST", STATUS_COLOR.Work)
                end

                if S.AcceptTries >= ACCEPT_TRIES then
                    S.Phase = PHASE_IDLE
                    NotifyAction("QUEST", "The quest dialog would not finish", 5)
                    SetStatus("DIALOG WOULD NOT FINISH", STATUS_COLOR.Stop)
                end
            end
        end

        local function DescribeRows(Rows)
            local Parts = {}

            for _, Row in ipairs(Rows) do
                local Count = Row.Current and Row.Total and string.format(" %d/%d", Row.Current, Row.Total) or ""
                table.insert(Parts, Row.Task .. Count)
            end

            return table.concat(Parts, " · ")
        end

        --// The farm's own drink (AutoFarming_Combat's TryHeal), at the saved
        --// heal share. Nothing else drinks with Auto Farm paused, and a quest
        --// fight is as good a place to die as a farm one.
        local function HealIfHurt(Now)
            if not AICFeature.TryHeal or not AICCombat.GetCombatHealthPercent then
                return
            end

            local Share = tonumber(CONFIG.AUTO_HEAL_HEALTH_PERCENT) or 65

            if AICCombat.GetCombatHealthPercent() <= Share then
                pcall(AICFeature.TryHeal, Now)
            end
        end

        local function StepKill(Now)
            HealIfHurt(Now)

            local Rows = Module.GetObjectives()
            local Pending, AllDone = 0, #Rows > 0

            for _, Row in ipairs(Rows) do
                if not Row.Done then
                    Pending += 1
                    AllDone = false
                end
            end

            if #Rows == 0 then
                if Now - S.KillSince < QUEST_READ_GRACE then
                    SetStatus("READING THE QUEST", STATUS_COLOR.Wait)
                else
                    S.Phase = PHASE_IDLE
                    SetStatus("QUEST COMPLETE", STATUS_COLOR.Work)
                    StandStill()
                end

                return
            end

            if AllDone then
                S.Phase = PHASE_IDLE
                SetStatus("QUEST COMPLETE", STATUS_COLOR.Work)
                StandStill()

                return
            end

            local Target, TargetRow, TargetDistance, AnyKill = nil, nil, nil, false

            for _, Row in ipairs(Rows) do
                if not Row.Done and Module.IsKillTask(Row.Task) then
                    AnyKill = true
                    local Mob, Distance = FindMob(Row.Task, Now)

                    if Mob and (not TargetDistance or Distance < TargetDistance) then
                        Target, TargetRow, TargetDistance = Mob, Row, Distance
                    end
                end
            end

            if not AnyKill then
                SetStatus("ONLY ERRAND PARTS LEFT  ·  " .. DescribeRows(Rows), STATUS_COLOR.Wait)
                StandStill()

                return
            end

            if not Target then
                SetStatus("LOOKING FOR THE QUEST MOBS  ·  " .. DescribeRows(Rows), STATUS_COLOR.Wait)
                StandStill()

                return
            end

            local Count = TargetRow.Current and TargetRow.Total
                and string.format(" %d/%d", TargetRow.Current, TargetRow.Total)
                or ""

            SetStatus(string.format(
                "FIGHTING %s  ·  %s%s  %d STUDS",
                Target.Name,
                TargetRow.Task,
                Count,
                math.floor(TargetDistance)
            ), STATUS_COLOR.Work)

            FightMob(Target, Now)
        end

        ------------------------------------------------------------------------
        --// Diagnostic dump
        ------------------------------------------------------------------------

        local function AddValueLine(Lines, Prefix, Node)
            local Text = Prefix .. Node:GetFullName() .. "  [" .. Node.ClassName .. "]"

            if Node:IsA("ValueBase") then
                Text = Text .. " = " .. tostring(Node.Value)
            elseif Node:IsA("TextLabel") or Node:IsA("TextButton") or Node:IsA("TextBox") then
                Text = Text .. "  text: " .. Trim(Node.Text)
            end

            table.insert(Lines, Text)
        end

        local function CopyQuestInfo()
            local Lines = { "AIC quest dump  PlaceId " .. tostring(game.PlaceId) }

            local GiverCount = 0

            for _ in pairs(S.Givers) do
                GiverCount += 1
            end

            table.insert(Lines, "== Quest givers (workspace." .. GIVER_FOLDER .. ")")
            table.insert(Lines, "found " .. GiverCount .. ", selected " .. tostring(S.SelectedKey))

            for Label, Entry in pairs(S.Givers) do
                local Prompt = FindPrompt(Entry.Instance)
                local Position = GetPromptPosition(Prompt)

                table.insert(Lines, string.format(
                    "%s  ID=%s  prompt=%s  at=%s",
                    Label,
                    Entry.Id,
                    Prompt and Prompt:GetFullName() or "none",
                    Position and string.format("%.0f, %.0f, %.0f", Position.X, Position.Y, Position.Z) or "none"
                ))

                for _, Child in ipairs(Entry.Instance:GetChildren()) do
                    local Value = Child:IsA("ValueBase") and (" = " .. tostring(Child.Value)) or ""

                    table.insert(Lines, "    " .. Child.Name .. "  [" .. Child.ClassName .. "]" .. Value)
                end
            end

            local Root = GetQuestRoot()

            table.insert(Lines, "== Quest UI  " .. (Root and Root:GetFullName() or "(not found)"))

            if Root then
                for _, Node in ipairs(Root:GetDescendants()) do
                    local Name = string.lower(Node.Name)

                    if Node:IsA("GuiButton")
                        or Node:IsA("TextLabel")
                        or string.find(Name, "tracker", 1, true)
                        or string.find(Name, "objective", 1, true)
                        or string.find(Name, "dialogue", 1, true)
                    then
                        local Visible = not Node:IsA("GuiObject") or Node.Visible

                        if Visible then
                            AddValueLine(Lines, "  ", Node)
                        end
                    end
                end
            end

            table.insert(Lines, "== Tracker rows")

            local Rows = Module.GetObjectives(true)

            if #Rows == 0 then
                table.insert(Lines, "  (no rows read)")
            end

            for Index, Row in ipairs(Rows) do
                table.insert(Lines, string.format(
                    "  %d. task=%q count=%q read=%s/%s done=%s",
                    Index,
                    Row.Task,
                    Row.Text,
                    tostring(Row.Current),
                    tostring(Row.Total),
                    tostring(Row.Done)
                ))
            end

            table.insert(Lines, "== QuestItems")

            local Items = workspace:FindFirstChild(QUEST_ITEMS_NAME)
                or workspace:FindFirstChild(QUEST_ITEMS_NAME, true)

            if not Items then
                table.insert(Lines, "  (no QuestItems folder in workspace)")
            else
                table.insert(Lines, "  " .. Items:GetFullName() .. "  [" .. Items.ClassName .. "]")

                for _, Descendant in ipairs(Items:GetDescendants()) do
                    AddValueLine(Lines, "    ", Descendant)
                end

                local Trigger = Items:FindFirstChild("TriggerQuest", true)

                table.insert(Lines, "  TriggerQuest: " .. (Trigger and Trigger.ClassName or "not found"))
            end

            table.insert(Lines, "== Mobs matching the wording")

            for _, Row in ipairs(Rows) do
                local Mob, Distance = FindMob(Row.Task, os.clock())

                table.insert(Lines, string.format(
                    "  %s  kill=%s  nearest=%s%s",
                    Row.Task,
                    tostring(Module.IsKillTask(Row.Task)),
                    Mob and Mob:GetFullName() or "none",
                    Mob and string.format("  %.0f studs", Distance) or ""
                ))
            end

            local Text = table.concat(Lines, "\n")
            local Copied = type(setclipboard) == "function" and pcall(setclipboard, Text)
            local Saved = false

            if AICProfile and AICProfile.CanUseFileStorage and AICProfile.CanUseFileStorage() then
                AICProfile.EnsureProfileFolder()
                Saved = pcall(writefile, DUMP_FILE, Text)
            end

            --// The console copy is what gets pasted into a report; the file is
            --// the full one.
            local Printed = 0

            for _, Line in ipairs(Lines) do
                print("[QUEST] " .. Line)
                Printed += 1

                if Printed >= 200 then
                    print("[QUEST] ... cut at 200 lines")
                    break
                end
            end

            NotifyAction("QUEST", string.format(
                "%d lines%s%s",
                #Lines,
                Copied and " · copied" or "",
                Saved and (" · saved to " .. DUMP_FILE) or ""
            ), 6)
        end

        ------------------------------------------------------------------------
        --// Readout and UI
        ------------------------------------------------------------------------

        local function UpdateReadout(Now)
            if Now - S.ReadoutAt < TRACKER_REFRESH_INTERVAL then
                return
            end

            S.ReadoutAt = Now

            if not S.TrackLabel then
                return
            end

            local Rows = Module.GetObjectives()
            local Text, Color

            if #Rows == 0 then
                Text, Color = "No quest tracked", STATUS_COLOR.Idle
            else
                local Parts = {}

                for _, Row in ipairs(Rows) do
                    local Count = Row.Text ~= "" and (Row.Text .. "  ") or ""
                    table.insert(Parts, Count .. Row.Task)
                end

                Text, Color = table.concat(Parts, "   ·   "), STATUS_COLOR.Work
            end

            if Text ~= S.LastReadout then
                S.LastReadout = Text
                S.TrackLabel:Set(Text)
                S.TrackLabel:SetColor(Color)
            end
        end

        local Section = UIRef.QuestSection

        S.StatusLabel = Section:AddLabel("QUEST IDLE")

        S.GiverDropdown = Section:AddDropdown{
            Name = "Quest Giver",
            Options = { NONE_OPTION },
            Callback = function(Value)
                local Entry = S.Givers[Value]

                if Entry then
                    S.SelectedKey = Value
                    S.SelectedInstance = Entry.Instance

                    --// Picking another quest starts it without a re-toggle.
                    if S.Phase == PHASE_IDLE then
                        S.Phase = PHASE_START
                    end
                end
            end,
        }

        Section:AddButton{
            Name = "Refresh Quests",
            Callback = function()
                S.GiversAt = -10
                RefreshGivers(os.clock())

                local Count = 0

                for _ in pairs(S.Givers) do
                    Count += 1
                end

                NotifyAction("QUEST", Count .. " quest giver(s) found")
            end,
        }

        AICUI.BindFeatureToggle("AutoQuest", "Auto Quest", function(Value)
            if Value then
                PauseFarm()
                S.Phase = PHASE_START
                S.PromptTries = 0
                S.AcceptTries = 0
            else
                S.Phase = PHASE_IDLE
                StandStill()
                SetStatus("OFF", STATUS_COLOR.Idle)
            end
        end, Section)

        Section:AddToggle{
            Name = "Teleport If Stuck",
            Default = true,
            Callback = function(Value)
                S.TeleportIfStuck = Value
            end,
        }

        Section:AddToggle{
            Name = "Try TriggerQuest Remote",
            Default = false,
            Callback = function(Value)
                S.UseTriggerRemote = Value
            end,
        }

        Section:AddButton{
            Name = "Teleport To Quest",
            Callback = function()
                local Giver = Module.GetSelectedGiver()

                if not Giver then
                    NotifyAction("QUEST", "Pick a quest giver first", 4)
                    return
                end

                local Position = GetGiverPosition(Giver)

                if not Position then
                    NotifyAction("QUEST", "That giver has no prompt to land on", 4)
                    return
                end

                TeleportTo(Position)
                NotifyAction("QUEST", "Teleported to " .. Giver.Label, 4)
            end,
        }

        local TrackerSection = UIRef.QuestTrackerSection

        S.TrackLabel = TrackerSection:AddLabel("No quest tracked")

        TrackerSection:AddButton{
            Name = "Copy Quest Info",
            Callback = CopyQuestInfo,
        }

        TrackerSection:AddNote("Read from QuestUI_Root: the rows are Task and Count.")

        ------------------------------------------------------------------------
        --// The loop
        ------------------------------------------------------------------------

        function Module:Update()
            local Now = os.clock()

            RefreshGivers(Now)
            UpdateReadout(Now)

            local Enabled = FeatureState.AutoQuest and FeatureState.AutoQuest.Enabled == true

            if Enabled and not S.WasEnabled then
                --// Also runs for a profile load, which sets the flag without
                --// going through the toggle's callback.
                PauseFarm()
                S.Phase = PHASE_START
                S.PromptTries = 0
                S.AcceptTries = 0
            elseif not Enabled and S.WasEnabled then
                S.Phase = PHASE_IDLE
                SetStatus("OFF", STATUS_COLOR.Idle)
            end

            S.WasEnabled = Enabled

            if not Enabled then
                return
            end

            local Character, Humanoid = Runtime:GetCharacter()

            if not Humanoid then
                SetStatus("WAITING FOR A CHARACTER", STATUS_COLOR.Wait)
                return
            end

            --// A new life: the input handle Bootstrap cleared is looked for
            --// again on the next fighting frame instead of a second later.
            if Character ~= S.Character then
                S.Character = Character
                S.BindableAt = -10
            end

            if Humanoid.Health <= 0 then
                S.Dead = true
                SetStatus("DEAD — WAITING TO RESPAWN", STATUS_COLOR.Stop)
                return
            end

            if S.Dead then
                S.Dead = false
                S.Phase = PHASE_START
            end

            --// Whatever the phase, a dialog waiting on screen is clicked and
            --// the tracker is read first: the two things that say the quest
            --// is actually live.
            if S.Phase ~= PHASE_ACCEPT and S.Phase ~= PHASE_IDLE and FindAcceptButton() then
                S.Phase = PHASE_ACCEPT
                S.AcceptTries = 0
                S.NextAcceptAt = 0
            end

            local Phase = S.Phase

            if Phase == PHASE_START then
                BeginQuest(Now)
            elseif Phase == PHASE_TRAVEL then
                StepTravel(Now)
            elseif Phase == PHASE_PROMPT then
                StepPrompt(Now)
            elseif Phase == PHASE_ACCEPT then
                StepAccept(Now)
            elseif Phase == PHASE_KILL then
                StepKill(Now)
            else
                --// Idle still picks up a quest accepted by hand, and keeps
                --// the readout honest while it waits.
                local Rows = Module.GetObjectives()

                if #Rows > 0 then
                    S.Phase = PHASE_KILL
                    S.KillSince = Now
                elseif FindAcceptButton() then
                    S.Phase = PHASE_ACCEPT
                    S.AcceptTries = 0
                    S.NextAcceptAt = 0
                end
            end
        end

        Context.Lifetime.OnEnd(function()
            S.Phase = PHASE_IDLE
            S.Root = nil
            S.Mobs = {}
            S.Rows = {}
        end)

        return Module
    end,
}
