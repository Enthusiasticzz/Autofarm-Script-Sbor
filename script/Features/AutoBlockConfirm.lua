-- AutoBlockConfirm presses "Block" in Roblox's Block dialog after Auto Block
-- opens it. Ported from Iambatman's AutoBlockConfirm.
-- Executor only: the dialog lives in CoreGui, which Studio scripts cannot read.
return {
    Name = "AutoBlockConfirm",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "Components", "AutoBlock", "GuiClick"},

    Start = function(Context)
        local Services = Context.Services
        local RunService = Services.RunService
        local GuiClick = Context.GuiClick
        local FeatureState = Context.Feature
        local AICFeature = Context.AICFeature
        local NotifyAction = Context.NotifyAction

        --// How long to look for the dialog after a prompt.
        local ARM_SECONDS = 6
        local SCAN_INTERVAL = 0.15
        --// Wait after each click method before checking the block list.
        local VERIFY_SECONDS = 0.7
        local FINAL_VERIFY_SECONDS = 2
        --// A confirm still running after this is taken as stuck, so it
        --// never holds Auto Block's hop back for good.
        local CONFIRM_MAX_SECONDS = 20
        --// Exact match: "Block and report" must never be pressed.
        local CONFIRM_TEXT = "Block"
        --// The dialog title reads "Block <name>?".
        local TITLE_PREFIX = "Block "

        local CloneReference = type(cloneref) == "function" and cloneref or function(Instance)
            return Instance
        end

        local CoreGui = CloneReference(game:GetService("CoreGui"))

        local Available = not RunService:IsStudio()
            and (pcall(function()
                return CoreGui:GetChildren()
            end))

        local Feature = {
            Name = "AutoBlockConfirm",
            IsFeature = true,
            S = {
                ArmToken = 0,
                ArmedPlayer = nil,
                ArmedUntil = 0,
                ArmedAt = 0,
                --// The click method that worked last, tried first next time.
                LastMethod = nil,
            },
        }

        local S = Feature.S

        local function Trim(Text)
            local Trimmed = string.gsub(tostring(Text or ""), "^%s*(.-)%s*$", "%1")
            return Trimmed
        end

        --// Turn on with getgenv().AICBlockConfirmDebug = true before running.
        local function IsDebug()
            local Ok, Env = pcall(function()
                return type(getgenv) == "function" and getgenv()
            end)

            return Ok and type(Env) == "table" and Env.AICBlockConfirmDebug == true
        end

        local function Log(...)
            if IsDebug() then
                print("[AutoBlockConfirm]", ...)
            end
        end

        local function IsBlocked(OtherPlayer)
            return AICFeature.isBlocked ~= nil and AICFeature.isBlocked(OtherPlayer.UserId) == true
        end

        local function WaitForBlocked(OtherPlayer, Seconds)
            local Deadline = os.clock() + Seconds

            while os.clock() < Deadline do
                if IsBlocked(OtherPlayer) then
                    return true
                end

                task.wait(0.1)
            end

            return IsBlocked(OtherPlayer)
        end

        local function GetButtonText(Button)
            if Button:IsA("TextButton") and Trim(Button.Text) ~= "" then
                return Trim(Button.Text)
            end

            for _, Descendant in ipairs(Button:GetDescendants()) do
                if (Descendant:IsA("TextLabel") or Descendant:IsA("TextButton")) and Trim(Descendant.Text) ~= "" then
                    return Trim(Descendant.Text)
                end
            end

            return ""
        end


        local function TitleNamesPlayer(Text, Names)
            if string.sub(Text, 1, #TITLE_PREFIX) ~= TITLE_PREFIX then
                return false
            end

            for _, Name in ipairs(Names) do
                if Name ~= "" and string.find(Text, Name, 1, true) then
                    return true
                end
            end

            return false
        end

        --// Only confirm a dialog whose title names our target, so a dialog
        --// the user opened for someone else is never pressed.
        local function DialogNamesPlayer(Button, OtherPlayer)
            local Names = {OtherPlayer.Name, OtherPlayer.DisplayName}
            local Node = Button.Parent

            while Node and not Node:IsA("LayerCollector") do
                for _, Descendant in ipairs(Node:GetDescendants()) do
                    if Descendant:IsA("TextLabel") and TitleNamesPlayer(Trim(Descendant.Text), Names) then
                        return true
                    end
                end

                Node = Node.Parent
            end

            return false
        end


        local function FindConfirmButton(OtherPlayer)
            local Ok, Descendants = pcall(function()
                return CoreGui:GetDescendants()
            end)

            if not Ok then
                return nil
            end

            for _, Descendant in ipairs(Descendants) do
                if Descendant:IsA("GuiButton")
                    and GuiClick.IsOnScreen(Descendant)
                    and GetButtonText(Descendant) == CONFIRM_TEXT
                    and DialogNamesPlayer(Descendant, OtherPlayer)
                then
                    return Descendant
                end
            end

            return nil
        end

        local function DumpDialogTexts()
            local Ok, Descendants = pcall(function()
                return CoreGui:GetDescendants()
            end)

            if not Ok then
                return
            end

            for _, Descendant in ipairs(Descendants) do
                if (Descendant:IsA("TextLabel") or Descendant:IsA("TextButton"))
                    and string.find(Descendant.Text, "Block", 1, true)
                then
                    print(
                        "[AutoBlockConfirm] dump:",
                        Descendant:GetFullName(),
                        Descendant.ClassName,
                        string.format("%q", Descendant.Text),
                        "onScreen=" .. tostring(GuiClick.IsOnScreen(Descendant))
                    )
                end
            end
        end

        local function Finish(Token)
            if Token == S.ArmToken then
                S.ArmedPlayer = nil
            end
        end

        local function WaitForConfirmButton(Token, OtherPlayer)
            while Token == S.ArmToken and os.clock() < S.ArmedUntil do
                local Button = FindConfirmButton(OtherPlayer)

                if Button then
                    return Button
                end

                task.wait(SCAN_INTERVAL)
            end

            return nil
        end

        local function Run(Token, OtherPlayer)
            local Button = WaitForConfirmButton(Token, OtherPlayer)

            if Token ~= S.ArmToken then
                return
            end

            if not Button then
                Log("Block dialog not found for", OtherPlayer.Name)

                if IsDebug() then
                    DumpDialogTexts()
                end

                Finish(Token)
                return
            end

            for _, Method in ipairs(GuiClick.GetOrderedMethods(S.LastMethod)) do
                if Token ~= S.ArmToken or not GuiClick.IsOnScreen(Button) then
                    break
                end

                local Sent = Method.Click(Button)
                Log(Method.Name, Sent and "sent" or "unavailable")

                if Sent and WaitForBlocked(OtherPlayer, VERIFY_SECONDS) then
                    S.LastMethod = Method.Name
                    Log("Blocked", OtherPlayer.Name, "via", Method.Name)
                    Finish(Token)
                    return
                end
            end

            --// A click may have closed the dialog while the block request is
            --// still in flight.
            if Token == S.ArmToken and not WaitForBlocked(OtherPlayer, FINAL_VERIFY_SECONDS) then
                warn("[AutoBlockConfirm] Could not confirm Block for", OtherPlayer.Name)
                NotifyAction("Auto Confirm Block", "Could not press Block; confirm it yourself.", 5)
            end

            Finish(Token)
        end

        function Feature:IsAvailable()
            return Available
        end

        --// Starts watching for the dialog PromptBlockPlayer just opened for
        --// this player.
        function Feature:Arm(OtherPlayer)
            if not Available or not FeatureState.AutoBlockConfirm.Enabled then
                return
            end

            if not OtherPlayer or not OtherPlayer.Parent or IsBlocked(OtherPlayer) then
                return
            end

            if S.ArmedPlayer == OtherPlayer and os.clock() < S.ArmedUntil then
                return
            end

            S.ArmToken += 1
            S.ArmedPlayer = OtherPlayer
            S.ArmedAt = os.clock()
            S.ArmedUntil = S.ArmedAt + ARM_SECONDS
            task.spawn(Run, S.ArmToken, OtherPlayer)
        end

        function Feature:Disarm()
            S.ArmToken += 1
            S.ArmedPlayer = nil
        end

        --// Whether a confirm for this player is still looking for, pressing
        --// or verifying their dialog.
        function Feature:IsConfirming(OtherPlayer)
            return OtherPlayer ~= nil
                and S.ArmedPlayer == OtherPlayer
                and os.clock() - S.ArmedAt < CONFIRM_MAX_SECONDS
        end

        function Feature:Update()
        end

        --// AutoBlock calls this right after it opens the dialog.
        AICFeature.ConfirmBlockPrompt = function(OtherPlayer)
            return Feature:Arm(OtherPlayer)
        end

        --// AutoBlock waits on this before prompting again or hopping.
        AICFeature.IsConfirmingBlock = function(OtherPlayer)
            return Feature:IsConfirming(OtherPlayer)
        end

        --// AutoBlock makes the toggle itself, directly under Auto Block in its
        --// section: this module starts after it, so a toggle added here would
        --// land past the whitelist instead. It calls this when it changes.
        AICFeature.OnAutoBlockConfirmChanged = function(Enabled)
            if Enabled and not Available then
                NotifyAction("Auto Confirm Block", "Executor only: Roblox's Block dialog cannot be reached here.", 5)
            end

            if not Enabled then
                Feature:Disarm()
            end
        end

        return Feature
    end,
}
