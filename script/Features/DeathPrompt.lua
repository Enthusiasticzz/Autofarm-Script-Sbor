-- DeathPrompt presses "No" on the confirm notice the game puts up when the
-- character dies: PlayerGui.GameGui.Confirm2, with its buttons in the C row
-- and the one to press named No.
--
-- The notice is looked for at that path first, then as a Confirm or Confirm2
-- anywhere under a ScreenGui - the death dialog is one of those two names, and
-- not always in GameGui. A nested one only counts when it holds a visible No
-- to press: the trade window has its own Confirm buried deep inside it, and
-- taking that for the notice left the real one unseen and the dump below
-- describing the wrong window.
--
-- The No side is clicked whether it is a GuiButton or the Frame the label sits
-- in: the game's dialogs are not all built the same way. When nothing matches,
-- every answer on screen - a node or a label reading No, Yes, Cancel or
-- Confirm, anywhere in the PlayerGui - is printed once with its path, so a
-- notice in a shape this does not know can be fixed from the real paths rather
-- than guessed at.
--
-- It is armed by a death and looks for the notice only inside that window, so
-- a confirm the user opens themselves at any other time is never pressed.
-- The press itself goes through Core/GuiClick, the same clicker Auto Confirm
-- Block and Auto Start Game use, so it needs an executor that can fire a
-- button's signals or send a synthetic mouse click.
return {
    Name = "DeathPrompt",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "GuiClick"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local PlayerGui = Context.PlayerGui
        local GuiClick = Context.GuiClick
        local FeatureState = Context.Feature
        local AICUI = Context.AICUI
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// PlayerGui.GameGui.Confirm2.C.No
        local GUI_NAME = "GameGui"
        --// The death dialog answers to either name, and Confirm2 wins when both
        --// are on screen: the plain Confirm is also used for other dialogs, so
        --// it is only looked at as a whole node named Confirm, never as a
        --// prefix of something else.
        local NOTICE_NAMES = { "Confirm2", "Confirm" }
        local ROW_NAME = "C"
        local BUTTON_NAME = "No"

        local BUTTON_LOWER = string.lower(BUTTON_NAME)

        --// The words an answer wears, as a node name or as a label's text.
        --// Only these are printed by the dump: the rest of the gui is noise.
        local ANSWERS = {
            ["no"] = true,
            ["yes"] = true,
            ["cancel"] = true,
            ["confirm"] = true,
            ["ok"] = true,
            ["respawn"] = true,
            ["revive"] = true,
            ["retry"] = true,
            ["dismiss"] = true,
        }

        --// How long after the death the notice may still turn up. The game
        --// builds it a frame or two after the character goes down, and it can
        --// arrive around the respawn rather than at the exact death, so the
        --// window outlives the dead state.
        local WATCH_SECONDS = 30
        --// Wait after each click method before checking the notice has closed.
        local VERIFY_SECONDS = 0.7
        --// A notice that survived every method is tried again after this.
        local RETRY_SECONDS = 2
        --// This long into the window with nothing clicked, what is on screen is
        --// printed once, so a notice in a shape this does not expect can be
        --// reported with the real paths instead of "it does not work".
        local DUMP_AFTER = 4
        local DUMP_LIMIT = 30
        --// A label's text in the dump is clipped to this, so one long label
        --// that happens to be named Confirm cannot flood the console.
        local TEXT_LIMIT = 60

        local Feature = {
            Name = "DeathPrompt",
            IsFeature = true,
        }

        local S = {
            --// The dead state the last frame saw, so only the frame health
            --// reaches 0 arms the window.
            Dead = false,
            ArmedUntil = 0,
            --// A press sequence is running: the notice it is on is its own.
            Clicking = false,
            NextAttemptAt = 0,
            --// The click method that worked last, tried first next time.
            LastMethod = nil,
            --// One warning per run: an executor without any click method would
            --// otherwise warn on every notice.
            Warned = false,
            --// When the current window was armed, and whether it has already
            --// printed what it could see.
            ArmedAt = 0,
            Dumped = false,
            --// The death counter the last frame saw, so a respawn arms the
            --// window as well.
            Deaths = nil,
            --// Where the fallback search last found the notice, so the whole
            --// PlayerGui is not walked on every frame of a window.
            NoticeAt = 0,
            NoticeCache = nil,
        }

        Feature.S = S

        --// How long the fallback search's answer is reused. Only the fallback
        --// is cached: the GameGui path is two lookups and stays live.
        local NOTICE_CACHE_TIME = 0.25

        --// What to click for the answer. The game's buttons are not always
        --// GuiButtons: the name often sits on a Frame with the label inside it,
        --// so the node called No is clicked when nothing better exists. The
        --// signal methods have nothing to fire on a Frame and step aside, and
        --// the synthetic-click methods land on any GuiObject.
        local function GetClickTarget(Node)
            if not Node then
                return nil
            end

            if Node:IsA("GuiButton") and GuiClick.IsOnScreen(Node) then
                return Node
            end

            --// A button inside the No frame.
            for _, Descendant in ipairs(Node:GetDescendants()) do
                if Descendant:IsA("GuiButton") and GuiClick.IsOnScreen(Descendant) then
                    return Descendant
                end
            end

            --// A Frame named No wrapped in the button that is actually clicked.
            local Parent = Node.Parent

            while Parent and Parent:IsA("GuiObject") do
                if Parent:IsA("GuiButton") and GuiClick.IsOnScreen(Parent) then
                    return Parent
                end

                Parent = Parent.Parent
            end

            if Node:IsA("GuiObject") and GuiClick.IsOnScreen(Node) then
                return Node
            end

            return nil
        end

        --// The node called No inside a notice: the C row first, then the first
        --// one anywhere in it, in any case - never one from elsewhere in the
        --// game.
        local function FindNoticeNo(Notice)
            local Row = Notice:FindFirstChild(ROW_NAME)
            local Node = Row and Row:FindFirstChild(BUTTON_NAME)

            if not Node then
                for _, Descendant in ipairs(Notice:GetDescendants()) do
                    if string.lower(Descendant.Name) == BUTTON_LOWER then
                        Node = Descendant
                        break
                    end
                end
            end

            return Node
        end

        --// A notice is only worth taking for the death one when the answer it
        --// holds can actually be pressed. The trade window's Confirm passes a
        --// name test and nothing else: it is closed, and it is not a notice.
        local function IsAnswerable(Notice)
            return GetClickTarget(FindNoticeNo(Notice)) ~= nil
        end

        --// The notice itself, while it is up. GameGui's Confirm2, then its
        --// Confirm, then either of them anywhere under a ScreenGui, but only
        --// with an answer showing: a reskin that moves it to another screen
        --// gui used to mean the notice was never seen at all.
        local function FindNotice()
            local GameGui = PlayerGui:FindFirstChild(GUI_NAME)

            if GameGui then
                for _, Name in ipairs(NOTICE_NAMES) do
                    local Found = GameGui:FindFirstChild(Name)

                    if Found then
                        return Found
                    end
                end
            end

            local Now = os.clock()

            if Now - S.NoticeAt < NOTICE_CACHE_TIME then
                return S.NoticeCache
            end

            S.NoticeAt = Now
            S.NoticeCache = nil

            for _, Root in ipairs(PlayerGui:GetChildren()) do
                if Root:IsA("LayerCollector") then
                    for _, Name in ipairs(NOTICE_NAMES) do
                        for _, Found in ipairs(Root:GetDescendants()) do
                            if Found.Name == Name and IsAnswerable(Found) then
                                S.NoticeCache = Found
                                return Found
                            end
                        end
                    end
                end
            end

            return nil
        end

        --// The No answer of the death notice, or nil while there is none on
        --// screen.
        local function FindNoticeButton()
            local Notice = FindNotice()

            if not Notice then
                return nil
            end

            return GetClickTarget(FindNoticeNo(Notice))
        end

        --// True once the notice is gone, which is the only proof a press
        --// landed: the button has no state to read back.
        local function IsNoticeGone()
            return FindNoticeButton() == nil
        end

        --// What is on screen when nothing matched, printed once per death
        --// window: the paths it names are what the next fix is written from.
        --// It walks the whole PlayerGui rather than the node the finder
        --// settled on, because a finder that picked the wrong node is one of
        --// the ways to end up here.
        local function DumpVisible()
            print("[DeathPrompt] No No button found " .. DUMP_AFTER .. "s after the death. Answers on screen:")

            local Count = 0
            local Truncated = false

            for _, Root in ipairs(PlayerGui:GetChildren()) do
                if Root:IsA("LayerCollector") and Count < DUMP_LIMIT then
                    for _, Descendant in ipairs(Root:GetDescendants()) do
                        if Count >= DUMP_LIMIT then
                            Truncated = true
                            break
                        end

                        local Text = nil

                        if Descendant:IsA("TextLabel")
                            or Descendant:IsA("TextButton")
                            or Descendant:IsA("TextBox")
                        then
                            Text = Descendant.Text
                        end

                        local Named = ANSWERS[string.lower(Descendant.Name)] == true
                        local Labelled = type(Text) == "string"
                            and ANSWERS[string.lower(string.match(Text, "^%s*(.-)%s*$"))] == true

                        if (Named or Labelled) and GuiClick.IsOnScreen(Descendant) then
                            Count += 1

                            if type(Text) == "string" and Text ~= "" then
                                print(string.format(
                                    "  [%s] %s  text=\"%s\"",
                                    Descendant.ClassName,
                                    Descendant:GetFullName(),
                                    string.sub(Text, 1, TEXT_LIMIT)
                                ))
                            else
                                print(string.format(
                                    "  [%s] %s",
                                    Descendant.ClassName,
                                    Descendant:GetFullName()
                                ))
                            end
                        end
                    end
                end
            end

            if Count == 0 then
                print("  (nothing on screen is named or labelled No, Yes, Cancel or Confirm)")
            elseif Truncated then
                print(string.format("  (stopped at %d lines)", DUMP_LIMIT))
            end

            local Guis = {}

            for _, Root in ipairs(PlayerGui:GetChildren()) do
                if Root:IsA("LayerCollector") and Root.Enabled then
                    table.insert(Guis, Root.Name)
                end
            end

            if #Guis > 0 then
                print("  visible guis: " .. table.concat(Guis, ", "))
            else
                print("  visible guis: (none)")
            end
        end

        local function WaitClosed(Seconds)
            local Deadline = os.clock() + Seconds

            while os.clock() < Deadline do
                if IsNoticeGone() then
                    return true
                end

                task.wait(0.05)
            end

            return IsNoticeGone()
        end

        --// One method at a time, in the order that worked last time, and the
        --// notice is checked after each: a click that fires but is ignored
        --// leaves the notice up for the next method to try.
        local function Press(Button)
            for _, Method in ipairs(GuiClick.GetOrderedMethods(S.LastMethod)) do
                if not Button.Parent or not GuiClick.IsOnScreen(Button) then
                    return true
                end

                if Method.Click(Button) then
                    S.LastMethod = Method.Name

                    if WaitClosed(VERIFY_SECONDS) then
                        return true
                    end
                end
            end

            return IsNoticeGone()
        end

        local function Run(Button)
            --// A click method that throws must not leave the gate shut: this
            --// runs off the Heartbeat, so nothing else would reset it.
            local Ok, Pressed = pcall(Press, Button)

            S.Clicking = false

            if Ok and Pressed then
                print("[DeathPrompt] Pressed No on the death notice")
                return
            end

            S.NextAttemptAt = os.clock() + RETRY_SECONDS

            if not S.Warned then
                S.Warned = true
                warn("[DeathPrompt] Could not press No on the death notice; press it yourself")
                NotifyAction("Dismiss Death Prompt", "Could not press No on the death notice.", 5)
            end
        end

        --// A loaded profile can turn the toggle on without the callback, so
        --// the enabled check lives here rather than only in the toggle.
        function Feature:Update()
            if not FeatureState.DeathPrompt.Enabled then
                return
            end

            local Character, Humanoid = Runtime:GetCharacter()
            local Dead = Character == nil or Humanoid == nil or Humanoid.Health <= 0
            local Now = os.clock()

            --// A respawn arms the window too: the game can hand the body back
            --// before health is ever read as 0, and DEATH_COUNT is what
            --// Bootstrap bumps on CharacterAdded for the whole script.
            local Stats = AICFeature and AICFeature.S
            local Deaths = Stats and tonumber(Stats.DEATH_COUNT) or 0
            local Respawned = S.Deaths ~= nil and Deaths ~= S.Deaths
            S.Deaths = Deaths

            if (Dead and not S.Dead) or Respawned then
                S.ArmedUntil = Now + WATCH_SECONDS
                S.ArmedAt = Now
                S.Dumped = false
                S.NextAttemptAt = 0
            end

            S.Dead = Dead

            if S.Clicking or Now >= S.ArmedUntil or Now < S.NextAttemptAt then
                return
            end

            local Button = FindNoticeButton()

            if not Button then
                if not S.Dumped and Now - S.ArmedAt >= DUMP_AFTER then
                    S.Dumped = true
                    DumpVisible()
                end

                return
            end

            S.Clicking = true
            task.spawn(Run, Button)
        end

        AICUI.BindFeatureToggle("DeathPrompt", "Dismiss Death Prompt", function(Enabled)
            if not Enabled then
                S.ArmedUntil = 0
            end
        end, UIRef.UtilitySection)

        return Feature
    end,
}
