-- BossNavigator_Evade - Pause For Strangers: the hold that parks the boss
-- route while someone else is on the server.
--
-- Split out of Features/BossNavigator.lua so that file is about the route. The
-- saved hiding-spot shape (GetEvadeConfig / CleanSpots / GetEvadeSpots /
-- SpotKey) deliberately stayed behind: the route editor reads and writes that
-- list, and keeping one copy is what stops the editor and the hold from
-- disagreeing about where the spots are saved.
--
-- The route publishes what the hold needs as AICFeature.BossNav; this module
-- asserts every name at boot, so a renamed seam fails the boot probe instead of
-- failing the first time a stranger walks in.
--
-- Published by this module:
--   AICFeature.BossEvadeStep(Now)   one frame of the hold; true = owned
--   AICFeature.BossEvadeEnd(Now, Restart)
--   AICFeature.BossEvadeReady       true once the above are assigned
return {
    Name = "BossNavigator_Evade",
    Dependencies = {"BossNavigator", "AutoBlock", "Webhook", "Logger"},

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Players = Context.Services.Players
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local AICCombatUtils = Context.AICCombatUtils
        local AICFeature = Context.AICFeature
        --// The route reads the same table as Context.Feature; FeatureState is
        --// the older name, kept for a context that still passes it alone.
        local FeatureState = Context.FeatureState or Context.Feature

        local Boss = AICFeature.BossNav
        assert(type(Boss) == "table", "BossNavigator_Evade: BossNavigator did not publish BossNav")

        local REQUIRED = {
            "S", "SetStatus", "Say", "IsEnabled", "CurrentStop", "GetStops",
            "BeginStop", "ResetWalk", "EndDodge", "StopFlee", "ClearKillClock",
            "SyncDeathMark", "GetFloorOverlap", "LiftFromFloor", "FixLandedFloor",
            "TeleportToPoint", "TeleportToWaypoint", "FightStep", "ApproachStep",
            "RecoverStep", "BeginRecover", "IsMobAlive", "SetBlocking", "StopRoute",
            "WatchDeath", "GetEvadeConfig", "CleanSpots", "GetEvadeSpots", "SpotKey",
            "MAX_EVADE_SPOTS",
            "EVADE_WAIT_MIN", "EVADE_WAIT_MAX", "EVADE_KICK_RETRY",
            "EVADE_DEAD_SETTLE", "EVADE_RESET_RETRY_DELAY", "EVADE_RESET_GIVE_UP",
            "RESET_RETRIES", "RESET_STAY_DISTANCE", "PROMPT_WAIT", "PROMPT_ARRIVAL",
            "PROMPT_RECHECK", "PROMPT_INTERACT_MUTE", "TELEPORT_LAND_WINDOW",
            "TELEPORT_LAND_DISTANCE", "RESPAWN_SETTLE", "FLOOR_BURIED",
        }

        for _, Key in ipairs(REQUIRED) do
            assert(Boss[Key] ~= nil, "BossNavigator_Evade: BossNav." .. Key .. " is missing")
        end

        local S = Boss.S
        local SetStatus = Boss.SetStatus
        local Say = Boss.Say
        local IsEnabled = Boss.IsEnabled
        local CurrentStop = Boss.CurrentStop
        local GetStops = Boss.GetStops
        local BeginStop = Boss.BeginStop
        local ResetWalk = Boss.ResetWalk
        local EndDodge = Boss.EndDodge
        local StopFlee = Boss.StopFlee
        local ClearKillClock = Boss.ClearKillClock
        local SyncDeathMark = Boss.SyncDeathMark
        local GetFloorOverlap = Boss.GetFloorOverlap
        local LiftFromFloor = Boss.LiftFromFloor
        local FixLandedFloor = Boss.FixLandedFloor
        local TeleportToPoint = Boss.TeleportToPoint
        local TeleportToWaypoint = Boss.TeleportToWaypoint
        local FightStep = Boss.FightStep
        local ApproachStep = Boss.ApproachStep
        local RecoverStep = Boss.RecoverStep
        local BeginRecover = Boss.BeginRecover
        local IsMobAlive = Boss.IsMobAlive
        local SetBlocking = Boss.SetBlocking
        local StopRoute = Boss.StopRoute
        local WatchDeath = Boss.WatchDeath
        local GetEvadeConfig = Boss.GetEvadeConfig
        local CleanSpots = Boss.CleanSpots
        local GetEvadeSpots = Boss.GetEvadeSpots
        local SpotKey = Boss.SpotKey
        local MAX_EVADE_SPOTS = Boss.MAX_EVADE_SPOTS

        local EVADE_WAIT_MIN = Boss.EVADE_WAIT_MIN
        local EVADE_WAIT_MAX = Boss.EVADE_WAIT_MAX
        local EVADE_KICK_RETRY = Boss.EVADE_KICK_RETRY
        local EVADE_DEAD_SETTLE = Boss.EVADE_DEAD_SETTLE
        local EVADE_RESET_RETRY_DELAY = Boss.EVADE_RESET_RETRY_DELAY
        local EVADE_RESET_GIVE_UP = Boss.EVADE_RESET_GIVE_UP
        local RESET_RETRIES = Boss.RESET_RETRIES
        local RESET_STAY_DISTANCE = Boss.RESET_STAY_DISTANCE
        local PROMPT_WAIT = Boss.PROMPT_WAIT
        local PROMPT_ARRIVAL = Boss.PROMPT_ARRIVAL
        local PROMPT_RECHECK = Boss.PROMPT_RECHECK
        local PROMPT_INTERACT_MUTE = Boss.PROMPT_INTERACT_MUTE
        local TELEPORT_LAND_WINDOW = Boss.TELEPORT_LAND_WINDOW
        local TELEPORT_LAND_DISTANCE = Boss.TELEPORT_LAND_DISTANCE
        local RESPAWN_SETTLE = Boss.RESPAWN_SETTLE
        local FLOOR_BURIED = Boss.FLOOR_BURIED

        --// Assigned by the hold below; the route ends a hold through
        --// AICFeature.BossEvadeEnd.
        local EndEvade

        local function IsStranger(OtherPlayer)
            if not OtherPlayer or OtherPlayer == Player then
                return false
            end

            if AICFeature.IsWhitelisted and AICFeature.IsWhitelisted(OtherPlayer.UserId) then
                return false
            end

            return true
        end

        --// The first stranger on the server. Someone already there when the
        --// toggle was switched on counts the same as one who just walked in:
        --// the point is not to be seen, and whether the character was standing
        --// next to them when they arrived changes nothing about that.
        local function FindStranger()
            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if IsStranger(OtherPlayer) then
                    return OtherPlayer
                end
            end

            return nil
        end

        --// Everyone the hold is hiding from. FindStranger answers the one that
        --// stops the run; the reports name all of them, so a leave that the
        --// hold causes says exactly who was still on the server.
        local function FindStrangers()
            local List = {}

            for _, OtherPlayer in ipairs(Players:GetPlayers()) do
                if IsStranger(OtherPlayer) then
                    table.insert(List, OtherPlayer)
                end
            end

            return List
        end

        --// The strangers the hold is hiding from, as plain { Name, UserId }
        --// copies. The report that says they left has to name them after their
        --// Player objects are gone, so the hold keeps its own copy.
        local function SnapshotStrangers(List)
            local Copy = {}

            for _, OtherPlayer in ipairs(List or {}) do
                table.insert(Copy, {
                    Name = tostring(OtherPlayer.Name or "?"),
                    UserId = tonumber(OtherPlayer.UserId),
                })
            end

            return Copy
        end

        --// The hold starts: the route is parked, the fight dropped, and the
        --// reset fired. Nothing is walked or fought until it ends.
        local function BeginEvade(Now, OtherPlayer)
            S.Evading = true
            S.EvadeName = tostring(OtherPlayer.Name)
            --// Kept beside the name so a report always has someone to name,
            --// even if the snapshot below is ever empty.
            S.EvadeId = tonumber(OtherPlayer.UserId)
            S.EvadeStage = "Reset"
            S.EvadeSince = Now
            S.EvadeWaitUntil = nil
            S.EvadeWaitTotal = 0
            S.EvadeResetHumanoid = nil
            S.EvadeResetAt = nil
            S.EvadeResetRetries = 0
            S.EvadeResetPosition = nil
            S.EvadeSent = false
            S.EvadeTeleportFrom = nil
            S.EvadeTeleportAt = nil
            S.EvadePromptCheckAt = nil
            S.EvadePromptTarget = nil
            S.EvadeLiveAt = nil
            S.EvadeKicked = false
            S.EvadeKickAt = nil
            S.EvadeStrangers = SnapshotStrangers(FindStrangers())
            S.EvadeStrangersAt = Now
            S.EvadeClearSent = false
            S.FloorLifts = 0
            S.Phase = "Evade"
            EndDodge()
            StopFlee()
            AICCombat.S.ClosestTarget = nil
            S.LastTarget = nil
            S.TargetSeenAt = nil
            ClearKillClock()
            ResetWalk()
            SetStatus("EVADING  @" .. S.EvadeName .. "  RESETTING")
            Say("Evasion", "Pause For Strangers: @" .. S.EvadeName .. " is here; resetting", 5)

            --// Log When Hiding is on: the report says who joined and stopped
            --// the run. It names everyone on the server, not only the one the
            --// hold latched onto.
            if AICFeature.ReportHold then
                AICFeature.ReportHold(S.EvadeStrangers)
            end
        end

        --// The hold is over: the stranger went (Restart true), or the section
        --// was switched off. A restart starts the route again at stop #1, from
        --// wherever the character is standing - the first stop's own teleport
        --// takes it from there.
        EndEvade = function(Now, Restart)
            if not S.Evading then
                return
            end

            local Was = S.EvadeName

            S.Evading = false
            S.EvadeName = ""
            S.EvadeId = nil
            S.EvadeStage = nil
            S.EvadeSince = nil
            S.EvadeWaitUntil = nil
            S.EvadeWaitTotal = 0
            S.EvadeResetHumanoid = nil
            S.EvadeResetAt = nil
            S.EvadeResetRetries = 0
            S.EvadeResetPosition = nil
            S.EvadeSent = false
            S.EvadeTeleportFrom = nil
            S.EvadeTeleportAt = nil
            S.EvadePromptCheckAt = nil
            S.EvadePromptTarget = nil
            S.EvadeLiveAt = nil
            S.EvadeKicked = false
            S.EvadeKickAt = nil
            S.EvadeStrangers = nil
            S.EvadeStrangersAt = nil
            S.Phase = "Idle"
            --// The hold's own reset bumped the player's death counter. Taking
            --// it as read here is what keeps the restart from being treated as
            --// a death the route has to walk back from.
            SyncDeathMark()

            if not (Restart and IsEnabled() and CurrentStop()) then
                SetStatus("EVASION OVER")
                return
            end

            S.Index = 1
            BeginStop(Now)

            if Was ~= "" then
                Say("Evasion", "@" .. Was .. " left; starting again at stop #1", 5)
            end
        end

        --// The strangers went before their window ran out: the hold ends by
        --// itself and the route starts again at stop #1. The wait they cost is
        --// reported, with how long it was - that is the one report that says a
        --// hold ended quietly instead of with a kick. Log When Hiding decides
        --// whether it goes out; the leave for a hold that ran out never is a
        --// setting.
        local function StrangersLeft(Now)
            if S.EvadeClearSent then
                --// Already ended: one hold is one report, however many frames
                --// end up seeing the strangers gone.
                EndEvade(Now, true)
                return
            end

            S.EvadeClearSent = true

            local Waited = math.max(0, Now - (S.EvadeSince or Now))
            local Who = S.EvadeStrangers or {}

            --// Nobody left in the snapshot: name the one the hold latched
            --// onto rather than posting a report that says "A Player Left".
            if #Who == 0 and S.EvadeName ~= "" then
                Who = { { Name = S.EvadeName, UserId = S.EvadeId } }
            end

            S.EvadeStrangers = {}

            if AICFeature.ReportHoldCleared then
                AICFeature.ReportHoldCleared(Who, Waited)
            end

            EndEvade(Now, true)
        end

        --// The hold's reset, asked for once and then again only while the same
        --// body is still alive and still standing where it was reset: a body
        --// that came back is the reset landing, never a reason to kill it again.
        --// True while the reset is still owed or still in flight.
        local function EvadeResetStep(Now, Humanoid, RootPart)
            --// A different body: the reset landed and the character is back.
            if S.EvadeResetHumanoid and Humanoid ~= S.EvadeResetHumanoid then
                S.EvadeResetHumanoid = nil
                return false
            end

            if (tonumber(Humanoid.Health) or 0) <= 0 then
                return true
            end

            Humanoid:Move(Vector3.zero)

            --// The game revived the body somewhere else rather than replacing
            --// it (a scripted respawn): the reset landed too, and the travel
            --// starts from where it now stands.
            local StayedPut = not S.EvadeResetPosition
                or (RootPart.Position - S.EvadeResetPosition).Magnitude <= RESET_STAY_DISTANCE

            if S.EvadeResetHumanoid and not StayedPut then
                S.EvadeResetHumanoid = nil
                return false
            end

            --// Not asked yet: this is the reset the hold starts with.
            if not S.EvadeResetHumanoid then
                S.EvadeResetHumanoid = Humanoid
                S.EvadeResetAt = Now
                S.EvadeResetPosition = RootPart.Position
                --// This reset is the script's own: its death counter bump must
                --// not restart the stop the route was on.
                S.OwnDeaths = (S.OwnDeaths or 0) + 1
                S.OwnDeathAt = Now
                Humanoid.Health = 0
                return true
            end

            --// The same body, still standing there: the game dropped it. Asked
            --// again a couple of times, then the hold runs where it is rather
            --// than standing at the corpse of a reset that never happened.
            if Now - (S.EvadeResetAt or Now) >= EVADE_RESET_RETRY_DELAY
                and (S.EvadeResetRetries or 0) < RESET_RETRIES
            then
                S.EvadeResetRetries = (S.EvadeResetRetries or 0) + 1
                S.EvadeResetAt = Now
                Humanoid.Health = 0
                return true
            end

            if Now - (S.EvadeSince or Now) >= EVADE_RESET_GIVE_UP then
                S.EvadeResetHumanoid = nil
                return false
            end

            return true
        end

        --// The travel to the evade spot: the saved prompt first (the door or
        --// portal the spot is actually behind), then the game's waypoint, and
        --// neither saved is a hold where the reset left the character. The
        --// landing is read back the same way a stop's is - a waypoint watched
        --// for movement, a prompt checked against where it meant to land - so a
        --// send the game dropped is not taken for one that worked. False means
        --// the travel is over.
        local function EvadeTravelStep(Now, Humanoid, RootPart)
            if S.EvadeSent then
                --// A prompt landing, read once the drop has settled.
                if S.EvadePromptCheckAt then
                    if Now < S.EvadePromptCheckAt then
                        Humanoid:Move(Vector3.zero)
                        return true
                    end

                    S.EvadePromptCheckAt = nil

                    local Target = S.EvadePromptTarget
                    S.EvadePromptTarget = nil
                    local Depth = GetFloorOverlap(RootPart)

                    --// Landed inside the floor: lifted out and looked at again
                    --// once it has dropped back onto the surface.
                    if Depth and Depth >= FLOOR_BURIED
                        and LiftFromFloor(Humanoid, RootPart, Depth)
                    then
                        S.EvadePromptCheckAt = Now + PROMPT_RECHECK
                        S.EvadePromptTarget = Target
                        Humanoid:Move(Vector3.zero)
                        return true
                    end

                    local Flat = Target
                        and AICCombatUtils.GetHorizontalDistance(Target, RootPart.Position)
                        or 0

                    if Flat > PROMPT_ARRIVAL then
                        Say("Evasion", string.format(
                            "Evade prompt landed %.0f studs away; holding here", Flat
                        ), 4)
                    end

                    return false
                end

                --// A waypoint landing, watched for the whole window: the frame
                --// the body moves the travel is over.
                if S.EvadeTeleportFrom then
                    local Window = TELEPORT_LAND_WINDOW

                    if (RootPart.Position - S.EvadeTeleportFrom).Magnitude < TELEPORT_LAND_DISTANCE
                        and Now - (S.EvadeTeleportAt or Now) < Window
                    then
                        Humanoid:Move(Vector3.zero)
                        return true
                    end

                    S.EvadeTeleportFrom = nil
                    S.EvadeTeleportAt = nil

                    --// The landing point can sit under a floor plane: lifted
                    --// out before the hold, so the character is not standing in
                    --// the ground for the whole wait.
                    if FixLandedFloor(Humanoid, RootPart) then
                        Humanoid:Move(Vector3.zero)
                        return true
                    end

                    return false
                end

                return false
            end

            --// A body that has just come back needs a moment before the game
            --// will move it; a teleport fired on the respawn frame is dropped.
            if not S.EvadeLiveAt then
                S.EvadeLiveAt = Now
            end

            if Now - S.EvadeLiveAt < RESPAWN_SETTLE then
                Humanoid:Move(Vector3.zero)
                return true
            end

            S.EvadeSent = true

            --// The teleport is the travel, so nothing is pressed on the prompt
            --// it lands on - the same mute a prompt travel to a stop sets.
            if Runtime.MuteInteract then
                Runtime:MuteInteract(PROMPT_INTERACT_MUTE)
            end

            --// One spot is picked at random from the hiding-spot list, and
            --// never the same one as the hold before it - the point of hiding
            --// somewhere else is not to land where a stranger last saw the
            --// character. Picked once per hold: this block runs on the frame
            --// the send goes out, which is the only frame it runs on
            --// (EvadeSent is set above).
            local Spots = GetEvadeSpots()
            local Spot = nil

            if #Spots > 0 then
                local Pick = math.random(1, #Spots)

                if #Spots > 1 and SpotKey(Spots[Pick]) == S.EvadePick then
                    Pick = (Pick % #Spots) + 1
                end

                Spot = Spots[Pick]
                S.EvadePick = SpotKey(Spot)
            end

            if Spot and Spot.Kind == "Prompt" then
                local PromptPosition = Vector3.new(Spot.X, Spot.Y, Spot.Z)

                if TeleportToPoint(PromptPosition) then
                    S.EvadePromptTarget = PromptPosition
                    S.EvadePromptCheckAt = Now + PROMPT_WAIT
                    SetStatus("EVADING  @" .. S.EvadeName .. "  PROMPT")
                    return true
                end

                return false
            end

            local Waypoint = Spot and Spot.Waypoint or 0

            if Waypoint > 0 then
                S.EvadeTeleportFrom = RootPart.Position
                S.EvadeTeleportAt = Now

                if TeleportToWaypoint(Waypoint) then
                    SetStatus(string.format("EVADING  @%s  WP%d", S.EvadeName, Waypoint))
                    return true
                end

                --// Nothing was sent, so there is no landing to watch.
                S.EvadeTeleportFrom = nil
                S.EvadeTeleportAt = nil
            end

            --// Nowhere saved: the reset was the whole evade.
            return false
        end

        --// The stranger stayed the whole window: Auto Block's leave reports and
        --// then closes the game, with the same random pause every other leave
        --// takes. The ask is repeated on a slow timer - a leave the game
        --// refuses, or one that never lands, must not end with the character
        --// parked here while the stranger is still on the server.
        local function AskToLeave(Now, Stranger)
            local FirstAsk = not S.EvadeKicked

            S.EvadeKicked = true
            S.EvadeKickAt = Now
            SetStatus("EVADING  @" .. S.EvadeName .. "  STAYED  LEAVING")

            --// The leave is logged whether or not Log When Hiding is on: the
            --// run ends because people would not leave, so the report names
            --// all of them. Reporting it here is also what names more than
            --// one; the departure latch it sets keeps the kick's own report
            --// from repeating the same leave with a single name.
            if FirstAsk and AICFeature.ReportHoldLeave then
                AICFeature.ReportHoldLeave(FindStrangers())
            end

            if AICFeature.LeaveGame then
                AICFeature.LeaveGame("Boss Evasion: a stranger stayed for the whole hold", Stranger)
            end
        end

        --// The wait itself. Standing still, out of the fight, counting down;
        --// the stranger leaving ends it and a stranger still there when the
        --// window runs out closes the game.
        local function EvadeHoldStep(Now, Humanoid, RootPart)
            if Humanoid and RootPart and (tonumber(Humanoid.Health) or 0) > 0 then
                Humanoid:Move(Vector3.zero)
                Humanoid.AutoRotate = true
            end

            local Stranger = FindStranger()

            if not Stranger then
                --// A leave asked for on the last frame is already under way.
                --// Someone walking out now does not undo it, and a report that
                --// says they left would describe a hold that ended with a kick
                --// instead of quietly.
                if S.EvadeKicked then
                    return true
                end

                StrangersLeft(Now)
                return true
            end

            if S.EvadeKicked then
                if Now - (S.EvadeKickAt or Now) >= EVADE_KICK_RETRY then
                    AskToLeave(Now, Stranger)
                end

                return true
            end

            if not S.EvadeWaitUntil then
                S.EvadeWaitTotal = math.random(EVADE_WAIT_MIN, EVADE_WAIT_MAX)
                S.EvadeWaitUntil = Now + S.EvadeWaitTotal
                Say("Evasion", string.format(
                    "Holding for @%s: giving them %ds to leave",
                    S.EvadeName,
                    S.EvadeWaitTotal
                ), 5)
            end

            if Now < S.EvadeWaitUntil then
                SetStatus(string.format(
                    "EVADING  @%s  %ds LEFT",
                    S.EvadeName,
                    math.ceil(S.EvadeWaitUntil - Now)
                ))
                return true
            end

            --// The whole window went by and they are still here.
            Say("Evasion", "@" .. S.EvadeName .. " stayed for the whole hold; closing the game", 6)
            AskToLeave(Now, Stranger)

            return true
        end

        --// One frame of the hold. True means the frame is the hold's: nothing
        --// else on the farm may walk, fight or reset while it runs. Gated by
        --// the section's own toggle and by the route, which is what there is to
        --// pause - with the route off nothing is paused and nothing restarts.
        local function EvadeStep(Now)
            if not IsEnabled() then
                return false
            end

            if not (FeatureState.PauseForStrangers
                and FeatureState.PauseForStrangers.Enabled == true)
            then
                --// Switched off from outside the toggle (a profile load sets
                --// the flag without its callback): the hold is let go rather
                --// than left parked with the route in its phase.
                if S.Evading then
                    EndEvade(Now, true)
                    return true
                end

                return false
            end

            local Stranger = FindStranger()

            if not S.Evading then
                if not Stranger then
                    return false
                end

                --// A route with no stops is not a run: resetting for it would
                --// cost a death and pause nothing.
                if not CurrentStop() then
                    return false
                end

                BeginEvade(Now, Stranger)
            end

            local _, Humanoid, RootPart = Runtime:GetCharacter()

            --// Who is still on the server, kept so the report that says they
            --// left can name them once their Player objects are gone. Read on a
            --// slow tick rather than every frame, and only refreshed while
            --// there is someone to name: writing the empty list the tick also
            --// sees would erase them a frame before the report that needs
            --// them, which is how a leave came out as "A Player Left at"
            --// instead of naming who had been there.
            if not S.EvadeStrangersAt or Now - S.EvadeStrangersAt >= 0.5 then
                local Live = SnapshotStrangers(FindStrangers())

                if #Live > 0 then
                    S.EvadeStrangers = Live
                end

                S.EvadeStrangersAt = Now
            end

            if S.EvadeStage == "Reset" then
                local Pending = Humanoid ~= nil
                    and RootPart ~= nil
                    and (tonumber(Humanoid.Health) or 0) > 0
                    and EvadeResetStep(Now, Humanoid, RootPart)

                if Pending then
                    SetStatus("EVADING  @" .. S.EvadeName .. "  RESETTING")
                    return true
                end

                S.EvadeStage = "Travel"
                S.EvadeResetHumanoid = nil
            end

            --// The reset has landed. A stranger who left while it did is not
            --// waited for: the run starts again now instead of taking a trip to
            --// a spot nobody needs it to stand on.
            if not Stranger then
                StrangersLeft(Now)
                return true
            end

            if not Humanoid or not RootPart or (tonumber(Humanoid.Health) or 0) <= 0 then
                if S.EvadeStage == "Travel" then
                    --// A body that never comes back must not park the hold for
                    --// good: past a normal respawn the countdown starts where
                    --// it lies, so a stranger who stays still gets the leave
                    --// the section promises.
                    if Now - (S.EvadeSince or Now) < EVADE_DEAD_SETTLE then
                        SetStatus("EVADING  @" .. S.EvadeName .. "  RESPAWNING")
                        return true
                    end

                    S.EvadeStage = "Hold"
                    S.EvadeSent = false
                end

                return EvadeHoldStep(Now, Humanoid, RootPart)
            end

            if S.EvadeStage == "Travel" then
                if EvadeTravelStep(Now, Humanoid, RootPart) then
                    return true
                end

                S.EvadeStage = "Hold"
                S.EvadeSent = false
            end

            return EvadeHoldStep(Now, Humanoid, RootPart)
        end

        local function Step(Now)
            --// The hold is checked before everything else: while it runs the
            --// route does nothing at all, and a stranger who is already there
            --// stops the run on the frame the toggle is read.
            if EvadeStep(Now) then
                return true
            end

            if not IsEnabled() then
                return false
            end

            if WatchDeath(Now) then
                return true
            end

            if S.Phase == "Recover" then
                return RecoverStep(Now)
            end

            local Stops = GetStops()

            if #Stops == 0 then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return true
            end

            if S.Index > #Stops then
                S.Index = 1
            end

            if S.Phase == "Idle" then
                BeginStop(Now)
            end

            local _, Humanoid, RootPart = Runtime:GetCharacter()

            --// Died on the way or in the fight without being reset by us: the
            --// loss is already taken, so wait for the respawn only, then walk
            --// this same stop's path again rather than skipping it.
            if not Humanoid or not RootPart or Humanoid.Health <= 0 then
                if S.Phase ~= "Recover" then
                    BeginRecover(Now, "DIED", true)
                end

                return true
            end

            local Stop = CurrentStop()

            if not Stop then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return true
            end

            if S.Phase == "Approach" then
                ApproachStep(Stop, Now)
                return true
            end

            if S.Phase == "Fight" then
                FightStep(Stop, Now)
                return true
            end

            --// "Done" with the loop off, or something else parked the run.
            if S.Phase == "Done" then
                return true
            end

            BeginStop(Now)
            return true
        end

        --// Auto Farm calls this every frame, with Auto Farm on or off. True
        --// means the route owns this frame's movement and combat.
        AICFeature.BossStep = function(Now)
            return Step(Now)
        end

        --// The hold on its own. Auto Farm calls this high in its frame, above
        --// the retreat and the Auto Block player check, so a stranger pauses
        --// the run instead of being blocked or hopped from.
        AICFeature.BossEvadeStep = function(Now)
            --// Auto Farm calls this with the route switched off too, so the hold
            --// only acts for a running route. Context.Feature is the live switch
            --// the UI and a profile load flip; FeatureState is the fallback for a
            --// context built without it.
            local Features = Context.Feature or FeatureState
            local Route = Features and Features.BossRoute
            local Pause = Features and Features.PauseForStrangers

            if not Route or Route.Enabled ~= true then
                return false
            end

            --// The hold is this switch's own; with it off there is no frame to
            --// own, including the one that would end a hold left over.
            if not Pause or Pause.Enabled ~= true then
                return false
            end

            return EvadeStep(Now)
        end

        --// The stop's boss is down but the route has not acted on it yet: the
        --// kill was stamped, or the target being fought is no longer alive.
        --// Auto Farm's health retreat hands the frame back every frame while
        --// it runs, so a kill landed at low health was invisible to the route:
        --// it stayed in RETREAT (healing, and waiting to be healed) until the
        --// health came back, and only then ran again and reset. The retreat
        --// yields the frame instead, and the reset it is owed happens now.
        AICFeature.BossKillPending = function()
            if not IsEnabled() or S.Phase ~= "Fight" then
                return false
            end

            if S.KillAt then
                return true
            end

            return S.SeenTarget == true
                and S.LastTarget ~= nil
                and not IsMobAlive(S.LastTarget)
        end

        --// Called while the character is dead or gone, where Auto Farm
        --// returns before BossStep: keeps a reset waiting for its respawn, and
        --// registers a death the route did not cause. Without the second part
        --// a death was invisible to the route (Auto Farm returns before
        --// BossStep while dead), so it resumed the half-walked path from the
        --// spawn on respawn and never teleported back to the stop's waypoint.
        AICFeature.BossRecoverStep = function(Now)
            if not IsEnabled() then
                return false
            end

            --// The hold runs while the character is down too, and this is the
            --// only frame it gets while dead or loading.
            if EvadeStep(Now) then
                return true
            end

            if WatchDeath(Now) then
                return true
            end

            if S.Phase ~= "Recover" then
                BeginRecover(Now, "DIED", true)
            end

            return RecoverStep(Now)
        end

        --// Turned off from outside the module - Auto Farm off takes the route
        --// with it - so the run stops here rather than at the next frame.
        AICFeature.StopBossRoute = function()
            StopRoute("OFF")
        end

        --// A profile load brings another place's stops with it.
        AICFeature.ResetBossRoute = function()
            if S.Evading and EndEvade then
                EndEvade(os.clock(), false)
            end

            EndDodge()
            S.HpAt = nil
            S.HpBase = nil
            S.Index = 1
            S.Phase = "Idle"
            S.SeenTarget = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            ClearKillClock()
            S.WaitUntil = nil
            S.SpotWaitUntil = nil
            SetBlocking(false)
            S.WalkStart = nil
            S.SkipSpotWait = false
            S.SkipSpotWaitNext = false
            SyncDeathMark()
            ResetWalk()
        end

        AICFeature.BossEvadeReady = true

        return { Name = "BossNavigator_Evade" }
    end,
}
