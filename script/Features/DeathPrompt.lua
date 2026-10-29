-- DeathPrompt presses "No" on the confirm notice the game puts up when the
-- character dies: PlayerGui.GameGui.Confirm2, with its buttons in the C row
-- and the one to press named No.
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

        --// How long after the death the notice may still turn up. The game
        --// builds it a frame or two after the character goes down, and it can
        --// arrive around the respawn rather than at the exact death, so the
        --// window outlives the dead state.
        local WATCH_SECONDS = 30
        --// Wait after each click method before checking the notice has closed.
        local VERIFY_SECONDS = 0.7
        --// A notice that survived every method is tried again after this.
        local RETRY_SECONDS = 2

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
        }

        Feature.S = S

        --// The No button of the death notice, or nil while there is none on
        --// screen. A reskin can nest the row deeper, so the no-descendant
        --// case falls back to the first GuiButton named No inside the notice
        --// itself and never to one elsewhere in the game.
        local function FindNoticeButton()
            local GameGui = PlayerGui:FindFirstChild(GUI_NAME)
            local Notice = GameGui and GameGui:FindFirstChild(NOTICE_NAME)

            if not Notice then
                return nil
            end

            local Row = Notice:FindFirstChild(ROW_NAME)
            local Button = Row and Row:FindFirstChild(BUTTON_NAME)

            --// A reskin can put the click target inside the No frame.
            if Button and not Button:IsA("GuiButton") then
                local Click = nil

                for _, Descendant in ipairs(Button:GetDescendants()) do
                    if Descendant:IsA("GuiButton") then
                        Click = Descendant
                        break
                    end
                end

                Button = Click
            end

            --// Same when the row itself is named differently: the button has to
            --// be called No and live inside this notice, never elsewhere.
            if not Button then
                for _, Descendant in ipairs(Notice:GetDescendants()) do
                    if Descendant:IsA("GuiButton") and Descendant.Name == BUTTON_NAME then
                        Button = Descendant
                        break
                    end
                end
            end

            if Button and GuiClick.IsOnScreen(Button) then
                return Button
            end

            return nil
        end

        --// True once the notice is gone, which is the only proof a press
        --// landed: the button has no state to read back.
        local function IsNoticeGone()
            return FindNoticeButton() == nil
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

            if Dead and not S.Dead then
                S.Dead = true
                S.ArmedUntil = Now + WATCH_SECONDS
                S.NextAttemptAt = 0
            elseif not Dead and S.Dead then
                S.Dead = false
            end

            if S.Clicking or Now >= S.ArmedUntil or Now < S.NextAttemptAt then
                return
            end

            local Button = FindNoticeButton()

            if not Button then
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
