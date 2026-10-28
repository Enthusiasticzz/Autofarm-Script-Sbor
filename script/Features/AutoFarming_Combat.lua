-- AutoFarming_Combat - weapon draw and potion/heal helpers.
-- Split from Features/AutoFarming.lua as part of Step 4b.
return {
    Name = "AutoFarming_Combat",
    Dependencies = {"AutoFarming", "Logger"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local AICFeature = Context.AICFeature
        local Logger = Context.Logger
        local CONFIG = Context.CONFIG

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

        --// Drinks the last used potion when it is off cooldown. The weapon
        --// is sheathed first, which costs a frame: true means this frame was
        --// spent sheathing and the caller should yield it.
        local function TryConsumePotion(now, PlayerStats, InputBindableFunction, MainWeld)
            local UseConsumable = Replicated:FindFirstChild("UseConsumable", true)
            local LastConsumed = PlayerStats and PlayerStats:FindFirstChild("LastConsumed")

            if not UseConsumable
                or not LastConsumed
                or LastConsumed.Value == ""
                or now - AICFeature.S.LAST_CONSUME_TIME < CONFIG.CONSUME_INTERVAL
            then
                return false
            end

            if InputBindableFunction
                and (AICFeature.S.Equipped or (MainWeld.Part1 and MainWeld.Part1.Name ~= "UpperTorso"))
                and now - AICFeature.S.LAST_EQUIP_TIME >= CONFIG.EQUIP_TOGGLE_COOLDOWN
            then
                AICFeature.S.Equipped = false
                AICFeature.S.LAST_EQUIP_TIME = now

                InputBindableFunction:Invoke(
                    "EquipButton",
                    Enum.UserInputState.Begin
                )

                return true
            end

            if not AICFeature.S.Equipped then
                AICFeature.S.LAST_CONSUME_TIME = now
                UseConsumable:InvokeServer(LastConsumed.Value)
            end

            return false
        end

        AICFeature.TryConsumePotion = TryConsumePotion

        --// Drinks from anywhere, for code that never reaches the retreat.
        AICFeature.TryHeal = function(now)
            local Character = Runtime:GetCharacter()
            local Sword = Character and Character:FindFirstChild("Sword")
            local MainWeld = Sword and Sword:FindFirstChild("MainWeld", true)
            local InputBindableFunction = Runtime:GetInputBindableFunction()

            if not Character or not MainWeld or not InputBindableFunction then
                Logger.debug("TryHeal: no character, weld, or input handle")
                return false
            end

            return TryConsumePotion(
                now,
                Player:FindFirstChild("PlayerStats"),
                InputBindableFunction,
                MainWeld
            )
        end

        return { Name = "AutoFarming_Combat" }
    end,
}
