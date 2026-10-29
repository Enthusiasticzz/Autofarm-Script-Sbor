-- DeathPrompt presses "No" on the confirm notice the game puts up when the
-- character dies: PlayerGui.GameGui.Confirm2, with its buttons in the C row
-- and the one to press named No.
--
-- The notice is looked for at that path first and then as any Confirm2 under a
-- ScreenGui, and the No side is clicked whether it is a GuiButton or the Frame
-- the label sits in - the game's dialogs are not all built the same way. When
-- nothing matches, what is on screen is printed once, so a notice in a shape
-- this does not know can be fixed from the real paths rather than guessed at.
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
        local NOTICE_NAME = "Confirm2"
        local ROW_NAME = "C"
        local BUTTON_NAME = "No"

        local BUTTON_LOWER = string.lower(BUTTON_NAME)

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

        --// The notice itself, while it is up. GameGui.Confirm2 first, then any
        --// Confirm2 under a ScreenGui: a reskin that moves it to another screen
        --// gui used to mean the notice was never seen at all.
        local function FindNotice()
            local GameGui = PlayerGui:FindFirstChild(GUI_NAME)
            local Notice = GameGui and GameGui:FindFirstChild(NOTICE_NAME)

            if Notice then
                return Notice
            end

            local Now = os.clock()

            if Now - S.NoticeAt < NOTICE_CACHE_TIME then
                return S.NoticeCache
            end

            S.NoticeAt = Now
            S.NoticeCache = nil

            for _, Root in ipairs(PlayerGui:GetChildren()) do
                if Root:IsA("LayerCollector") then
                    local Found = Root:FindFirstChild(NOTICE_NAME, true)

                    if Found then
                        S.NoticeCache = Found
                        return Found
                    end
                end
            end

            return nil
        end

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

        --// The No answer of the death notice, or nil while there is none on
        --// screen. Confirm2.C.No first; failing that, the first node called No
        --// inside this notice, in any case and at any depth - never one from
        --// elsewhere in the game.
        local function FindNoticeButton()
            local Notice = FindNotice()

            if not Notice then
                return nil
            end

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

            return GetClickTarget(Node)
        end

        --// True once the notice is gone, which is the only proof a press
        --// landed: the button has no state to read back.
        local function IsNoticeGone()
            return FindNoticeButton() == nil
        end

        --// What is on screen when nothing matched. Printed once per death
        --// window: the paths it names are what the next fix is written from.
        local function DumpVisible()
            local Notice = FindNotice()
            local Root = Notice or PlayerGui:FindFirstChild(GUI_NAME)

            if not Root then
                print("[DeathPrompt] No Confirm2 and no GameGui in PlayerGui: nothing to click and nothing to list")
                return
            end

            print("[DeathPrompt] No No button found under " .. Root:GetFullName() .. ". On screen:")

            local Count = 0

            for _, Descendant in ipairs(Root:GetDescendants()) do
                if GuiClick.IsOnScreen(Descendant)
                    and (Descendant:IsA("GuiButton") or string.lower(Descendant.Name) == BUTTON_LOWER)
                then
                    Count += 1
                    print(string.format("  [%s] %s", Descendant.ClassName, Descendant:GetFullName()))

                    if Count >= DUMP_LIMIT then
                        break
                    end
                end
            end

            if Count == 0 then
                print("  (nothing named No and no buttons)")
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
