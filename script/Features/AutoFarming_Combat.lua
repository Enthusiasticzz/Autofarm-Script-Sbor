-- AutoFarming_Combat - weapon draw and potion/heal helpers.
-- Split from Features/AutoFarming.lua as part of Step 4b.
return {
    Name = "AutoFarming_Combat",
    Dependencies = {"AutoFarming", "Logger", "Async"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local AICFeature = Context.AICFeature
        local Logger = Context.Logger
        local CONFIG = Context.CONFIG
        local PotionWorker = Context.Async:Worker()

        --// Draws the weapon when it is sheathed. True when the draw was just
        --// issued, so the caller should give it this frame.
        local function EnsureWeaponDrawn(now, InputBindableFunction, MainWeld)
            local Sheathed = not AICFeature.S.Equipped
                or (MainWeld.Part1 and MainWeld.Part1.Name == "UpperTorso")

            if not Sheathed or now - AICFeature.S.LAST_EQUIP_TIME < CONFIG.EQUIP_TOGGLE_COOLDOWN then
                return false
            end

            AICFeature.S.Equipped = true
            AICFeature.S.LAST_EQUIP_TIME = now

            InputBindableFunction:Invoke(
                "EquipButton",
                Enum.UserInputState.Begin
            )

            return true
        end

        AICFeature.EnsureWeaponDrawnRaw = EnsureWeaponDrawn

        --// For code outside the farm loop (Auto Mining's defence), which has
        --// no weld or input handle of its own.
        AICFeature.EnsureWeaponDrawn = function(now)
            local Character = Runtime:GetCharacter()
            local Sword = Character and Character:FindFirstChild("Sword")
            local MainWeld = Sword and Sword:FindFirstChild("MainWeld", true)
            local InputBindableFunction = Runtime:GetInputBindableFunction()

            if not MainWeld or not InputBindableFunction then
                Logger.debug(
                    "EnsureWeaponDrawn: missing %s%s",
                    MainWeld and "" or "MainWeld ",
                    InputBindableFunction and "" or "InputBindableFunction"
                )
                return false
            end

            return EnsureWeaponDrawn(now, InputBindableFunction, MainWeld)
        end

        --// Drinks the last used potion when it is off cooldown. The drink is
        --// the game's own UseConsumable remote, so the weapon makes no
        --// difference to it: nothing is sheathed first. The old sheathe cost
        --// two frames (a sheathe and the draw back) and left the character
        --// bare-handed between them, which is what a remote drink never needs.
        --// True means this frame drank, so the caller may yield it.
        local function TryConsumePotion(now, PlayerStats)
            local UseConsumable = Replicated:FindFirstChild("UseConsumable", true)
            local LastConsumed = PlayerStats and PlayerStats:FindFirstChild("LastConsumed")

            if not UseConsumable
                or PotionWorker:IsRunning()
                or not LastConsumed
                or LastConsumed.Value == ""
                or now - AICFeature.S.LAST_CONSUME_TIME < CONFIG.CONSUME_INTERVAL
            then
                return false
            end

            AICFeature.S.LAST_CONSUME_TIME = now
            local Item = LastConsumed.Value
            return PotionWorker:Start(function()
                return UseConsumable:InvokeServer(Item)
            end, 10, function(Ok, Error)
                if not Ok then Logger.warn("Potion request failed: %s", tostring(Error)) end
            end)
        end

        AICFeature.TryConsumePotion = TryConsumePotion

        --// Drinks from anywhere, for code that never reaches the retreat. No
        --// weld or input handle is needed any more: the drink is a remote, and
        --// the weapon is left exactly as it is.
        AICFeature.TryHeal = function(now)
            local Character = Runtime:GetCharacter()
            local PlayerStats = Player:FindFirstChild("PlayerStats")

            if not Character or not PlayerStats then
                Logger.debug("TryHeal: no character or PlayerStats")
                return false
            end

            return TryConsumePotion(now, PlayerStats)
        end

        return { Name = "AutoFarming_Combat" }
    end,
}
