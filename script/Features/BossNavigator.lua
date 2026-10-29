-- BossNavigator walks a saved route of boss stops, fighting at each one.
--
-- It has its own tab and its own list (Boss Route on the place config), so it
-- is separate from the waypoint route Auto Farm walks and from the waypoints
-- in Profile Settings: editing one never moves the other. A stop is a spot to
-- stand on. Coming to a stop the character walks there, or teleports to one of
-- the game's waypoints first when the stop names one, then fights whatever
-- matches its Boss Names inside its radius. Wait At Spot (0 for a new stop)
-- can hold the fight at the spot for a boss that spawns a moment late.
--
-- A fight ends when the target dies and nothing else is in the radius, or
-- when nothing is there to fight at all. With Reset After Kill on (the default
-- for a new stop) the character then resets, so the next stop is travelled to
-- from spawn. Whether that reset is worth holding for is decided from the EXP
-- in the level's bar: a reset keeps the first 10% of the bar for each whole
-- hundred levels - 20% at 216, 30% from 300, 90% from 900 and never more above
-- that. The bar's own size is the level's, from the game's EXP curve, so the
-- kept part is always that share of the bar in front of it: nine tenths in at
-- 900 and above, and only the top tenth is at risk.
-- A reset that would drop the character past that protection is held for the
-- stop's Reset (s), ten by default; one that would keep everything happens at
-- once.
-- There is no timer reset: the character never resets while the boss is still
-- standing.
-- Once the character is back from a reset the route moves on at once: the
-- pause that matters is the one before the reset. Dying, rather than being
-- reset by the route, is never taken as the stop being done: once the character
-- is back
-- the same stop is run again, teleporting to its waypoint and walking its Path
-- from the first point. The sword is asked for before the fight, not at it.
--
-- A stop travels either by the game's own waypoint number, or by teleporting
-- straight to the interaction prompt it saved (the door or portal in front of
-- the boss) and walking the rest of the Path. A prompt visit is quiet: no
-- Interact press goes out for it, because the teleport is the travel and a
-- press at the prompt would re-fire the same door or menu.
-- A stop can turn the skill dodge off, for a boss whose particles never stop.
--
-- The route loops unless Loop Route is off; then it plays once and switches
-- itself off. Travel is the stop's own saved Path points, walked in order and
-- then the stop itself; nothing is solved or steered, so the way round a
-- building is the one recorded in the Path to Boss section. While walking it
-- presses the game's Interact input like the Farming waypoint route, so doors,
-- levers and other proximity prompts on the path are used. The fight uses the
-- same combat inputs as Auto Farm, and a big health drop in a moment (a boss
-- skill) makes the character sprint out of range and stay out until the
-- skill's own effects - its particles and skill sound - have gone. Auto Farm
-- hands this module the frame while it is on, with Auto Farm on or off.
return {
    Name = "BossNavigator",
    IsFeature = true,
    Dependencies = {
        "Runtime",
        "SaveConfig",
        "ProfileManager",
        "Components",
        "CombatUtils",
        "Combat",
    },

    Start = function(Context)
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local AICCombatUtils = Context.AICCombatUtils
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICFeature = Context.AICFeature
        local AICProfile = Context.AICProfile
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local AICConfig = Context.AICConfig
        local AICCombat = Context.AICCombat
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        --// How close to the stop counts as standing on it, when the place has
        --// no reach distance of its own.
        local REACH_DISTANCE = 5
        --// Interact presses while walking, when the place config has no
        --// interaction interval of its own.
        local INTERACT_INTERVAL = 0.5
        --// Waited after a waypoint teleport, so the character lands before
        --// the walk to the spot starts.
        local TELEPORT_WAIT = 2
        --// After a respawn the first waypoint teleport waits this long: the
        --// game drops a TeleportEvent fired on the respawn frame, before the
        --// new character has loaded, and the stop was then walked from spawn.
        local RESPAWN_SETTLE = 1.5
        --// A teleport that did not move the character was dropped by the game.
        --// It is asked again this many times, this far apart, before the
        --// route gives up and walks.
        local TELEPORT_RETRIES = 2
        local TELEPORT_RETRY_DELAY = 0.75
        --// Moved less than this from where the teleport fired means it never
        --// landed.
        local TELEPORT_LAND_DISTANCE = 4
        --// A stop this far away is worth re-asking the teleport for; a nearer
        --// one is simply walked.
        local TELEPORT_RETRY_DISTANCE = 60
        --// Mob scan interval. The folder is read whole, so not every frame.
        local SCAN_INTERVAL = 0.2
        --// Nothing matching at the spot for this long: move on.
        local NO_TARGET_TIMEOUT = 5
        --// The target just died; this long with nothing else there counts as
        --// the boss being down.
        local KILL_GRACE = 2
        --// A target the scan has lost is still fought for this long: a model
        --// swap, a boss stepping out of the engage radius or a root that is
        --// gone for a moment is not a kill. Past it the mob is not one the
        --// game is listing at the stop any more - the scan reads the Mobs
        --// folder every 0.2 s, and a boss still standing there is in it. The
        --// kept reference was otherwise held forever: another player kills
        --// the boss, the game takes the body out of the folder without ever
        --// zeroing its health, and the route sat in FIGHT at a corpse until
        --// the model was finally destroyed - which only happened after a
        --// while, so the stop looked like it was waiting for the character
        --// to heal before it would reset.
        local TARGET_KEEP_TIME = 4
        --// A reset whose character never comes back gives up after this.
        local RESPAWN_TIMEOUT = 20
        --// EXP kept after a reset: ten percent of the level's own EXP bar for
        --// every hundred levels, straight from the level (see GetKeepPercent).
        --// Only the EXP above that protected part is lost, and what a reset
        --// would take is read before the reset, because the hold at the corpse
        --// is only worth having when there is something to lose.
        --// The hold a stop that has no Reset (s) of its own gets.
        local DEFAULT_RESET_HOLD = 10
        --// How much later than the stop asks for the reset fires. The wait is
        --// there to sit out the EXP a reset would cost, so it runs a little
        --// past the row's Reset (s) rather than exactly on it.
        local RESET_HOLD_EXTRA = 2
        --// A reset that costs nothing is not waited for: one scan tick after
        --// the kill is enough to know nothing else of the stop is standing.
        local FREE_RESET_GRACE = 0.2
        --// Still alive this long after the reset fired means the game dropped
        --// it; ask again rather than standing at the corpse.
        local RESET_RETRY_TIME = 3
        local RESET_RETRIES = 2
        --// A character this close to where the reset fired has not respawned.
        local RESET_STAY_DISTANCE = 30
        --// A living mob this close while the reset hold runs is run from: the
        --// character does not stand at the corpse waiting for the timer to end.
        local HOLD_FLEE_DISTANCE = 40
        --// How far from that mob the hold runs to.
        local HOLD_FLEE_RING = 45
        --// Waited after a prompt teleport, for the landing and the prompt's
        --// own range check, before Interact is pressed.
        local PROMPT_WAIT = 0.6
        --// How far from a stop its interaction prompt may be found when the
        --// stop has not saved one.
        local PROMPT_SCAN_RADIUS = 80
        --// How far from the character "Save Prompt Here" looks.
        local PROMPT_SAVE_RADIUS = 40
        --// After a prompt teleport the Interact input is left alone for this
        --// long. The teleport lands on the prompt itself, and pressing it
        --// again while walking away fires it a second time - a door closing
        --// behind the character, or a menu over the fight.
        local PROMPT_INTERACT_MUTE = 10
        --// Walking to a stop this long means it cannot be reached.
        local WALK_TIMEOUT = 120
        --// No progress toward the next point for this long (a wrong point, a
        --// wall in the way): skip the stop instead of standing there for
        --// WALK_TIMEOUT.
        local NO_PROGRESS_TIMEOUT = 20
        --// How close a saved path point has to be to count as reached. The stop
        --// itself uses the place's Waypoint Reach Distance.
        local PATH_REACH = 4
        --// The walk samples the position this often and hops when less than
        --// this many studs were covered in that window (a step, a fence).
        local STUCK_SAMPLE = 0.5
        local STUCK_DISTANCE = 0.75
        --// How far from the boss the character stops to swing. The combat range
        --// says when the attack input may be pressed, not where a swing lands.
        local FIGHT_STANDOFF = 6
        --// Distance from the stop at which the sword is asked for, so it is
        --// already out when the fight starts instead of being fumbled for
        --// while the boss is hitting the character.
        local WEAPON_READY_DISTANCE = 60
        --// A boss skill lands as a big chunk of health in a moment. The drop is
        --// measured as a fraction of max health inside this window, so it works
        --// at any level and a slow grind of small hits is not a skill.
        local BURST_WINDOW = 0.6
        local BURST_DROP_PERCENT = 0.2
        --// The dodge is not a fixed timer. It stays out while the boss's own
        --// skill is still showing - the game plays a Skill sound and switches
        --// on the blade's Sparkles/particles - and only comes back a moment
        --// after those go out. These are the floor and the ceiling around it,
        --// so a signal that is missed cannot end it early, and a signal that
        --// never clears cannot keep the character running forever.
        local DODGE_MIN_TIME = 1.5
        local DODGE_MAX_TIME = 8
        local DODGE_EFFECT_GRACE = 0.5
        --// The distance the dodge settles at, measured from the boss: far
        --// enough to be out of a skill, close enough that it is a step out and
        --// not a run across the room. It is held, not added to, so a skill
        --// that stays up does not walk the character further every second.
        --// A stop can set its own ("Dodge Distance"); this is the default.
        local DODGE_DISTANCE = 16
        local DODGE_HOLD_SLACK = 2
        local DODGE_SPEED_BONUS = 12
        --// The boss's emitters and sounds are listed again this often. Once a
        --// second is enough: the boss tool is equipped a frame or two after
        --// the model spawns, and the list only changes with the tool.
        local SKILL_SCAN_INTERVAL = 1
        --// How far from the character a mob name is offered in the picker.
        local NAME_SCAN_RADIUS = 300
        --// The status line is rewritten at most this often.
        local STATUS_INTERVAL = 0.5
        --// Longest a stop name may be, for the list.
        local MAX_LABEL_LENGTH = 32

        local Feature = {
            Name = "BossNavigator",
            IsFeature = true,
            S = {
                --// "Idle", "Approach", "Fight", "Recover" or "Done".
                Phase = "Idle",
                Index = 1,
                --// Next point of the stop's saved Path to walk (1 = first).
                PathIndex = 1,
                --// The points this visit walks, copied off the stop when the
                --// stop begins. Read from here rather than off the live stop
                --// every frame: a place config that arrives mid visit (a
                --// profile apply, another feature's NormalizePlaceConfig)
                --// replaces the stop table, and a walk that re-read it there
                --// could come back with no points and head straight at the
                --// stop across whatever lay in between.
                Path = nil,
                WalkFrom = nil,
                WalkSampleAt = nil,
                PhaseStart = 0,
                FightStart = nil,
                WaitUntil = nil,
                --// End of Wait At Spot, when the stop set one. nil = no wait.
                SpotWaitUntil = nil,
                --// This visit walks back to a stop the character died at, so
                --// Wait At Spot is not held: the boss is already standing
                --// there - it killed the character a moment ago - and holding
                --// the fight for a spawn that already happened only wastes the
                --// run back.
                SkipSpotWait = false,
                --// Set by the recovery that restarts the stop, taken by the
                --// BeginStop it leads to. Kept apart so the skip belongs to
                --// that visit and not to every later one.
                SkipSpotWaitNext = false,
                --// The player's death counter (AICFeature.S.DEATH_COUNT, bumped
                --// by CharacterAdded) as the route last read it. A game that
                --// respawns in the same instant it kills leaves no dead frame
                --// to read, so Health alone missed the death and the walk back
                --// was taken for a fresh arrival - complete with Wait At Spot.
                DeathMark = nil,
                --// Deaths this route's own resets are expected to cause.
                --// CharacterAdded bumps DEATH_COUNT a frame after the new body,
                --// so that bump can land after Advance has already moved on -
                --// it used to restart the next stop mid-approach.
                OwnDeaths = 0,
                OwnDeathAt = nil,
                WalkStart = nil,
                Teleported = false,
                --// A target was fought at this stop, so its absence now means
                --// the boss is down rather than not spawned yet.
                SeenTarget = false,
                --// Something matching the stop was engaged on this visit, which
                --// is what a reset after the kill is owed for.
                FoughtThisVisit = false,
                --// The character died at this stop, which had a boss when it
                --// did: the walk back watches the spot, and a boss that is
                --// gone is counted as this stop's kill (the duo finished it).
                ReturnKill = false,
                --// First frame the return walk found no boss at the spot, so a
                --// single missed scan is not taken for a kill.
                ReturnMissAt = nil,
                --// The mob this stop was last fighting. A scan can lose a live
                --// boss (out of the engage radius, a model swap, a root that
                --// is gone for a moment) and that is not a kill, so this one
                --// is fought on while the scan keeps finding it.
                LastTarget = nil,
                --// When the scan last saw that mob. Only a target it has found
                --// within TARGET_KEEP_TIME is still the stop's boss.
                TargetSeenAt = nil,
                KillAt = nil,
                --// The walk speed the hold borrowed to run from a mob, so it can
                --// be put back when the hold ends.
                FleeFromSpeed = nil,
                RecoveredAt = nil,
                --// When the game's Interact input was last pressed on the way.
                InteractAt = nil,
                --// Where the character stood when the waypoint teleport was
                --// fired, and how many times it has been retried for this stop.
                TeleportFrom = nil,
                Teleports = 0,
                --// No waypoint teleport before this: set after a respawn so the
                --// game has a loaded character to move, and between retries.
                TeleportHold = nil,
                --// The body the reset fired on, so a respawned character is never
                --// killed again by the retry, and how many retries it has had.
                ResetHumanoid = nil,
                ResetFiredAt = nil,
                ResetRetries = 0,
                --// Where the reset fired, and the level and EXP it was decided
                --// from. A character back at spawn is a respawn, one still
                --// standing where it was reset is a reset the game dropped.
                ResetPosition = nil,
                --// Whether the stop's interaction prompt was already taken this
                --// visit.
                PromptUsed = false,
                --// No Interact press before this: quiet for
                --// PROMPT_INTERACT_MUTE after a prompt teleport.
                --// The prompt teleport's landing press is the visit's only
                --// Interact press: the door or menu the teleport used sits
                --// where the character lands, and pressing it again on the
                --// way out re-fires it for as long as the walk lasts.
                InteractSuppressed = false,
                --// Where the stop's prompt was found this visit (false = none).
                PromptFallback = nil,
                --// Health watching for a skill: the baseline percent and when
                --// the current window started.
                HpAt = nil,
                HpBase = nil,
                --// While a dodge runs: when it ends, where it runs to, and the
                --// normal speed to put back afterwards.
                DodgeMinUntil = 0,
                DodgeMaxUntil = 0,
                DodgeTarget = nil,
                DodgeFromSpeed = nil,
                --// Whether the boss's skill effects were showing this frame,
                --// and when they were last seen. The dodge holds until they
                --// have been off again for DODGE_EFFECT_GRACE.
                SkillActive = false,
                SkillSeenAt = nil,
                --// The effect state on the previous frame: the dodge starts on
                --// the cast beginning, not on the damage arriving.
                SkillWas = false,
                --// This recovery is a death, not a planned reset: walk the same
                --// stop's path again instead of moving on to the next stop.
                RestartStop = false,
                --// Closest the character has been to the stop this visit, and
                --// when it was last closer than before. A stop the character
                --// stops approaching is the only unreachable stop.
                BestDistance = nil,
                LastProgressAt = nil,
                --// Per visit, for the status line.
                Resets = 0,
            },
        }

        local S = Feature.S

        AICProfile.S.SelectedBossStopIndex = AICProfile.S.SelectedBossStopIndex or 1

        local LastStatus = ""
        local LastStatusTime = 0

        --// The status line, rewritten only when it changes or after
        --// STATUS_INTERVAL, so countdowns can be shown without churn.
        local function SetStatus(Text)
            local Now = os.clock()

            if Text == LastStatus and Now - LastStatusTime < STATUS_INTERVAL then
                return
            end

            LastStatus = Text
            LastStatusTime = Now

            if UIRef.BossStatusLabel then
                UIRef.BossStatusLabel:Set("STATUS:  " .. tostring(Text))
            end
        end

        --// The saved toggle is the one state: the profile load, the tab's
        --// toggle and the end-of-route switch-off all write it, so no copy of
        --// it here can drift out of step (the feature is BossRoute while the
        --// module is BossNavigator, so the module table is not sync'd for us).
        local function IsEnabled()
            return FeatureState.BossRoute ~= nil and FeatureState.BossRoute.Enabled == true
        end

        local function GetStops()
            local PlaceConfig = Runtime:GetPlaceConfig()
            return PlaceConfig and PlaceConfig.BOSS_ROUTE or {}
        end

        --// How many bodies the player has had: Core/Bootstrap bumps this from
        --// CharacterAdded, so it counts a respawn even when the dead frame was
        --// never drawn, and it counts one per reset too.
        local function GetDeathCount()
            local Stats = AICFeature.S
            return Stats and tonumber(Stats.DEATH_COUNT) or 0
        end

        --// Takes the counter as read without calling anything a death. Used
        --// where the route legitimately stops watching (switched off, a
        --// profile load) so the deaths of that time are not replayed later.
        local function SyncDeathMark()
            S.DeathMark = GetDeathCount()
        end

        local function CurrentStop()
            return GetStops()[S.Index]
        end

        local function SelectedStop()
            return GetStops()[AICProfile.S.SelectedBossStopIndex]
        end

        --// Boss stops are place config, so they need a profile to be written
        --// to, the same rule as waypoints and zones.
        local function CanEdit(Message)
            if AICProfile.S.ActiveProfileName then
                return true
            end

            SetStatus("CREATE / LOAD PROFILE FIRST")
            AICUI.SetProfileStatus(Message or "CREATE / LOAD PROFILE FIRST")
            return false
        end

        local function Say(Action, Message, Duration)
            if NotifyAction then
                NotifyAction(Action or "Boss Route", Message, Duration or 3)
            end
        end

        local function GetExp()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Exp = PlayerStats and PlayerStats:FindFirstChild("EXP")
            return Exp and tonumber(Exp.Value) or nil
        end

        local function GetLevel()
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Level = PlayerStats and PlayerStats:FindFirstChild("Level")
            return Level and tonumber(Level.Value) or nil
        end

        --// Share of the EXP bar a reset leaves behind, from the level alone.
        --// The game steps it in whole hundreds: ten percent for each hundred
        --// levels *completed*, so 100-199 keeps 10%, 200-299 keeps 20%, 250
        --// and 299 are the same 20%, and 300 is the step up to 30%. From 900
        --// on it stays at 90% - 1,000, 1,500 and 2,000 all keep 90% - so the
        --// top tenth of the bar is always at risk. Only reached with a level
        --// in hand: GetResetCost returns "unknown" without one, and that
        --// holds. A share, never an EXP amount: what it protects is worked out
        --// from the bar the level actually has.
        local function GetKeepPercent(Level)
            if not Level or Level <= 0 then
                return 0
            end

            return math.min(90, math.floor(Level / 100) * 10)
        end

        --// The size of a level's EXP bar is the level's max EXP: the number the
        --// HUD prints after the slash, AICUI.neededExp(Level), and the EXP
        --// stat is counted against that same number. The share a reset keeps
        --// is taken from it directly. It used to be the gap between this level
        --// and the one before (about 1,300), a much smaller number than the
        --// real max, which made every EXP value look like it sat above the
        --// protected part and so every reset look like it would lose EXP.
        --// Cached per level, since this is read every frame of a hold.
        local LevelBars = {}

        --// Reach: the max EXP of this level. Floor: always 0, the stat starts
        --// each level from nothing. Bar: Reach, what the level itself asks for.
        local function GetLevelBar(Level)
            if not Level or Level <= 0 then
                return nil, 0, 0
            end

            local Cached = LevelBars[Level]

            if Cached then
                return Cached.Reach, Cached.Bar, Cached.Floor
            end

            local Needed = type(AICUI.neededExp) == "function" and AICUI.neededExp

            if not Needed then
                return nil, 0, 0
            end

            local Reach = tonumber(Needed(Level))

            if not Reach or Reach <= 0 then
                return nil, 0, 0
            end

            LevelBars[Level] = { Reach = Reach, Bar = Reach, Floor = 0 }

            return Reach, Reach, 0
        end

        --// How far into its bar the character's EXP is, 0..bar. A value that
        --// already fits the level's own bar is that bar's progress (the EXP
        --// stat restarting each level); a running total sits between this
        --// level's floor and its reach, and is read from the floor. Past the
        --// reach means the character has levelled up (the stat has not caught
        --// up yet), so it is at the end of the old bar. nil when it fits
        --// neither, and then the caller holds rather than guessing.
        local function GetBarProgress(Exp, Level)
            local Reach, Bar, Floor = GetLevelBar(Level)

            if not Bar or Bar <= 0 then
                return nil, Bar
            end

            if Exp >= 0 and Exp <= Bar then
                return Exp, Bar
            end

            if Exp > Floor and Exp <= Reach then
                return Exp - Floor, Bar
            end

            if Reach and Exp > Reach then
                return Bar, Bar
            end

            return nil, Bar
        end

        --// What a reset would cost where the character is standing. The level
        --// gives the share a reset keeps (70% at 700 to 799, 90% from 900 up),
        --// the bar is the level's max EXP, and the protected amount is that
        --// share of the max. Loss is the character's EXP minus that amount:
        --// zero or more means the EXP is at or past the line, so the route
        --// holds for it; below zero means everything is inside the protected
        --// part and the reset is free. Returned are the loss, the bar, the loss
        --// as a share of the bar and the level.
        --//
        --// nil means the cost cannot be read (no stats yet, a number that fits
        --// no bar) and is waited out, never taken for free.
        local function GetResetCost()
            local Level = GetLevel()
            local Exp = GetExp()

            if not Level or not Exp then
                return nil
            end

            --// An empty bar has nothing to take, whatever share is kept, so
            --// it is below the line and free.
            if Exp <= 0 then
                return -1, 0, -1, Level
            end

            local Progress, Bar = GetBarProgress(Exp, Level)

            if not Progress or not Bar or Bar <= 0 then
                return nil
            end

            local Keep = GetKeepPercent(Level) / 100
            local Loss = Progress - Bar * Keep

            return Loss, Bar, Loss / Bar, Level
        end

        --// Seconds held at the corpse before the reset: the row's Reset (s),
        --// ten when it has none, plus RESET_HOLD_EXTRA. Always Wait Before Reset
        --// takes that pause every time, so nothing resets on the spot even when
        --// the EXP check would have called it free. Otherwise nothing is held
        --// when the character's EXP sits inside the part of the bar a reset
        --// keeps. A reset that costs EXP always pauses - a 0 in the box is not a
        --// licence to throw the EXP away - and a cost that cannot be read is a
        --// loss.
        local function GetResetHold(Stop)
            local Wait = tonumber(Stop and Stop.ResetWait)

            if not Wait or Wait <= 0 then
                Wait = DEFAULT_RESET_HOLD
            end

            if CONFIG.BOSS_RESET_ALWAYS_WAIT == true then
                return Wait + RESET_HOLD_EXTRA
            end

            local Loss = GetResetCost()

            if Loss == nil then
                return Wait + RESET_HOLD_EXTRA
            end

            --// Below the protected line the reset is free. At the line or
            --// past it, the wait is held.
            if Loss < 0 then
                return 0
            end

            return Wait + RESET_HOLD_EXTRA
        end

        ------------------------------------------------------------------------
        --// Travel: the saved Path points, walked in order
        ------------------------------------------------------------------------

        --// Forgets the walk samples, so the next point starts a fresh stuck
        --// check.
        local function ResetWalk()
            S.WalkFrom = nil
            S.WalkSampleAt = nil
        end

        --// Walks at Point until it is within Reach of it. Straight MoveTo with
        --// a hop over anything low: the way there is the stop's saved Path, so
        --// nothing has to guess a route round a building.
        local function WalkTo(Point, Reach, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return false
            end

            if AICCombatUtils.GetHorizontalDistance(Point, RootPart.Position) <= Reach then
                Humanoid:Move(Vector3.zero)
                return true
            end

            --// Stuck (a step, a fence, a corner): hop. Sampled, never compared
            --// frame by frame: a walking character covers under a stud a
            --// frame, which a per-frame check reads as standing still.
            if not S.WalkSampleAt or Now - S.WalkSampleAt >= STUCK_SAMPLE then
                if S.WalkFrom and (RootPart.Position - S.WalkFrom).Magnitude < STUCK_DISTANCE then
                    AICCombatUtils.DoJump()
                end

                S.WalkFrom = RootPart.Position
                S.WalkSampleAt = Now
            end

            AICCombatUtils.DoJumpIfObstacle(Point)
            Humanoid:MoveTo(Point)

            return false
        end

        --// The Boss Route list labels. A stop keeps its number and position in
        --// the label so a drag can find it again, even with two identically
        --// named stops.
        local function BuildLabels()
            local Labels = {}

            for Index, Stop in ipairs(GetStops()) do
                local Extra = ""

                if (Stop.Waypoint or 0) > 0 then
                    Extra = string.format("  > WP%d", Stop.Waypoint)
                end

                if #(Stop.Path or {}) > 0 then
                    Extra = Extra .. string.format("  P%d", #Stop.Path)
                end

                if #Stop.Targets > 0 then
                    Extra = Extra .. "  " .. Stop.Targets[1]
                end

                Labels[Index] = string.format(
                    "#%d  %s%s  (%s)",
                    Index,
                    Stop.Label,
                    Extra,
                    string.format("%.0f, %.0f, %.0f", Stop.Position.X, Stop.Position.Y, Stop.Position.Z)
                )
            end

            return Labels
        end

        --// Saved Path points of the stop picked in "Edit Boss Stop".
        local function BuildPathLabels()
            local Stop = SelectedStop()
            local Labels = {}

            for Index, Point in ipairs(Stop and Stop.Path or {}) do
                Labels[Index] = string.format(
                    "#%d  (%.0f, %.0f, %.0f)",
                    Index,
                    Point.X,
                    Point.Y,
                    Point.Z
                )
            end

            return Labels
        end

        function AICUI.RefreshBossPathList()
            if not UIRef.BossPathComponent then
                return
            end

            UIRef.BossPathComponent:SetPriority(BuildPathLabels())

            if UIRef.BossPathLabel then
                local Stop = SelectedStop()

                if Stop then
                    UIRef.BossPathLabel:Set(string.format(
                        "PATH TO %s  (#%d)  %d POINTS",
                        string.upper(Stop.Label),
                        AICProfile.S.SelectedBossStopIndex,
                        #(Stop.Path or {})
                    ))
                else
                    UIRef.BossPathLabel:Set("PATH TO BOSS  NO STOP SELECTED")
                end
            end
        end

        local function GetResetWaits()
            local Waits = {}

            for Index, Stop in ipairs(GetStops()) do
                Waits[Index] = tonumber(Stop.ResetWait) or 0
            end

            return Waits
        end

        function AICUI.RefreshBossRouteList()
            if not UIRef.BossListComponent then
                return
            end

            UIRef.BossListComponent:SetPriority(BuildLabels(), GetResetWaits())
        end

        --// Names of the boss picked in "Edit Boss Stop": a list plus a
        --// dropdown of the mobs around the player, the same pattern as Zone
        --// Targets. Nothing is typed by hand.
        function AICUI.RefreshBossNames()
            local Component = UIRef.BossNamesComponent
            local Section = UIRef.BossNamesSection

            if not Component or not Section then
                return
            end

            local Stop = SelectedStop()
            local Names = Stop and Stop.Targets or {}

            Component:SetPriority(table.clone(Names))

            local _, _, RootPart = Runtime:GetCharacter()
            local Options = {}
            local Offered = {}

            local function Offer(Name)
                if type(Name) ~= "string" or Name == "" or Offered[Name] then
                    return
                end

                if table.find(Names, Name) then
                    return
                end

                Offered[Name] = true
                table.insert(Options, Name)
            end

            --// Nearest first: the mobs actually around the character, so the
            --// usual pick is the first entry.
            local Nearby, NearbyDistance = {}, {}
            local MobFolder = workspace:FindFirstChild("Mobs")

            if RootPart and MobFolder then
                for _, Mob in ipairs(MobFolder:GetChildren()) do
                    if Mob:IsA("Model") then
                        local MobRoot = Mob:FindFirstChild("HumanoidRootPart")
                        local Name = AICCombat.GetTargetEntityName(Mob)

                        if Name and MobRoot then
                            local Distance = (MobRoot.Position - RootPart.Position).Magnitude

                            if Distance <= NAME_SCAN_RADIUS
                                and Distance < (NearbyDistance[Name] or math.huge)
                            then
                                Nearby[Name] = true
                                NearbyDistance[Name] = Distance
                            end
                        end
                    end
                end
            end

            local NearbyNames = {}

            for Name in pairs(Nearby) do
                table.insert(NearbyNames, Name)
            end

            table.sort(NearbyNames, function(A, B)
                if NearbyDistance[A] == NearbyDistance[B] then
                    return A < B
                end

                return NearbyDistance[A] < NearbyDistance[B]
            end)

            for _, Name in ipairs(NearbyNames) do
                Offer(Name)
            end

            --// Then every other mob the game has loaded, so a boss name can
            --// be picked before walking next to it.
            local Detected = type(AICCombat.GetDetectedMobTargets) == "function"
                and AICCombat.GetDetectedMobTargets()
                or {}

            for _, Name in ipairs(Detected) do
                Offer(Name)
            end

            if #Options == 0 then
                Options = { "No mobs nearby" }
            end

            UIRef.BossNameDropdown = AICUI.ReplaceDropdown(
                UIRef.BossNameDropdown,
                Section,
                "Add Boss Name",
                Options,
                function(Value)
                    local Current = SelectedStop()

                    if not Current or Value == "No mobs nearby" then
                        return
                    end

                    if not AICProfile.S.ActiveProfileName then
                        SetStatus("CREATE / LOAD PROFILE FIRST")
                        return
                    end

                    Current.Targets = Current.Targets or {}

                    if not table.find(Current.Targets, Value) then
                        table.insert(Current.Targets, Value)
                        AICProfile.SaveActiveProfile()
                        Say("Boss Route", "Boss name added: " .. Value)
                    end

                    AICUI.RefreshBossNames()
                end,
                true
            )
        end

        --// Puts the selected stop's values back into the edit boxes, after a
        --// selection change or an edit was applied.
        local function RefreshEditor()
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if UIRef.BossNameBox then UIRef.BossNameBox:Set(Stop.Label, true) end
            if UIRef.BossWaypointBox then UIRef.BossWaypointBox:Set(tostring(Stop.Waypoint or 0), true) end
            if UIRef.BossRadiusBox then UIRef.BossRadiusBox:Set(tostring(Stop.Radius or 0), true) end
            if UIRef.BossWaitBox then UIRef.BossWaitBox:Set(tostring(Stop.Wait or 0), true) end
            if UIRef.BossResetAfterKillToggle then
                UIRef.BossResetAfterKillToggle:Set(Stop.ResetAfterKill == true, true)
            end
            if UIRef.BossDodgeToggle then
                UIRef.BossDodgeToggle:Set(Stop.Dodge ~= false, true)
            end
            if UIRef.BossDodgeDistanceBox then
                UIRef.BossDodgeDistanceBox:Set(
                    tostring(Stop.DodgeDistance or AICConfig.DEFAULT_BOSS_DODGE_DISTANCE),
                    true
                )
            end
            if UIRef.BossPromptToggle then
                UIRef.BossPromptToggle:Set(Stop.Prompt == true, true)
            end
            if UIRef.BossPromptLabel then
                UIRef.BossPromptLabel:Set(Stop.PromptPosition
                    and string.format(
                        "PROMPT:  %s  (%.0f, %.0f, %.0f)",
                        Stop.PromptName ~= "" and Stop.PromptName or "?",
                        Stop.PromptPosition.X,
                        Stop.PromptPosition.Y,
                        Stop.PromptPosition.Z
                    )
                    or "PROMPT:  NONE SAVED  (NEAREST TO THE STOP IS USED)"
                )
            end
            if UIRef.BossLoopToggle then UIRef.BossLoopToggle:Set(CONFIG.BOSS_ROUTE_LOOP ~= false, true) end
            if UIRef.BossAlwaysWaitToggle then
                UIRef.BossAlwaysWaitToggle:Set(CONFIG.BOSS_RESET_ALWAYS_WAIT == true, true)
            end
            AICUI.RefreshBossPathList()
        end

        --// Rebuilds the "Edit Boss Stop" picker, keeping its slot in the
        --// section, and follows the selected stop.
        function AICUI.RefreshBossRoutePickers()
            if not UIRef.BossEditorSection then
                return
            end

            local Stops = GetStops()
            local Options = {}

            for Index, Stop in ipairs(Stops) do
                Options[Index] = string.format("#%d  %s", Index, Stop.Label)
            end

            if #Options == 0 then
                Options = { "No boss stops" }
            end

            AICProfile.S.SelectedBossStopIndex = math.clamp(
                AICProfile.S.SelectedBossStopIndex, 1, math.max(1, #Stops)
            )

            local Selected = Options[AICProfile.S.SelectedBossStopIndex] or Options[1]

            UIRef.BossPicker = AICUI.ReplaceDropdown(
                UIRef.BossPicker,
                UIRef.BossEditorSection,
                "Edit Boss Stop",
                Options,
                function(Value)
                    local Index = table.find(Options, Value)

                    if Index and GetStops()[Index] then
                        AICProfile.S.SelectedBossStopIndex = Index
                        RefreshEditor()
                        AICUI.RefreshBossNames()
                    end
                end,
                true
            )

            if Selected then
                UIRef.BossPicker:Set(Selected, true)
            end

            RefreshEditor()
        end

        local function Commit(StatusText)
            Runtime:SetPlaceConfig(AICConfig.NormalizePlaceConfig(Runtime:GetPlaceConfig()))
            AICUI.RefreshBossRouteList()
            AICUI.RefreshBossRoutePickers()
            AICUI.RefreshBossPathList()
            AICProfile.SaveActiveProfile()
            SetStatus(StatusText)
            if AICUI.RefreshBossVisuals then AICUI.RefreshBossVisuals() end
            AICDebug.UpdateDebugVisualizer()
        end

        --// Turned off from inside the run (route finished with Loop Route off).
        local function SwitchOff()
            FeatureState.BossRoute.Enabled = false

            if AICUI.SetFeatureComponent then
                AICUI.SetFeatureComponent("BossRoute", false)
            end

            if AICProfile.S.ActiveProfileName then
                AICProfile.SaveActiveProfile()
            end
        end

        ------------------------------------------------------------------------
        --// The run
        ------------------------------------------------------------------------

        --// Puts the speed the dodge borrowed back and forgets the dodge. Safe
        --// without a character (dead, loading): the next body has its own
        --// speed and only the state needs clearing.
        local function EndDodge(Humanoid)
            if not Humanoid then
                local _, Current = Runtime:GetCharacter()
                Humanoid = Current
            end

            if S.DodgeFromSpeed and Humanoid and (tonumber(Humanoid.Health) or 0) > 0 then
                Humanoid.WalkSpeed = S.DodgeFromSpeed
            end

            S.DodgeFromSpeed = nil
            S.DodgeMinUntil = 0
            S.DodgeMaxUntil = 0
            S.DodgeTarget = nil
            S.SkillActive = false
            S.SkillSeenAt = nil
            --// SkillWas is deliberately left alone: the dodge ending is not
            --// the cast ending, and clearing it here made a boss whose effect
            --// stays on start a fresh dodge every frame at the ceiling.
        end

        --// Puts the walk speed back after a hold that ran from a mob. Safe
        --// without a character (dead, loading).
        local function StopFlee(Humanoid)
            if not Humanoid then
                local _, Current = Runtime:GetCharacter()
                Humanoid = Current
            end

            if S.FleeFromSpeed and Humanoid and (tonumber(Humanoid.Health) or 0) > 0 then
                Humanoid.WalkSpeed = S.FleeFromSpeed
            end

            S.FleeFromSpeed = nil
        end

        local function StopRoute(StatusText)
            S.Phase = "Idle"
            S.ReturnKill = false
            S.ReturnMissAt = nil
            S.SeenTarget = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            S.KillAt = nil
            S.WaitUntil = nil
            S.SpotWaitUntil = nil
            S.WalkStart = nil
            --// Nothing carries a death's skip into a later run, and a death
            --// from while the route was off is not the next run's.
            S.SkipSpotWait = false
            S.SkipSpotWaitNext = false
            S.TeleportHold = nil
            S.OwnDeaths = 0
            S.OwnDeathAt = nil
            SyncDeathMark()
            EndDodge()
            StopFlee()
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
            SetStatus(StatusText or "IDLE")
        end

        local function BeginStop(Now)
            local Stops = GetStops()
            local Stop = Stops[S.Index]

            if not Stop then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return
            end

            S.Phase = "Approach"
            S.PhaseStart = Now
            S.WalkStart = Now
            S.WaitUntil = nil
            S.FightStart = nil
            S.SeenTarget = false
            S.FoughtThisVisit = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            S.KillAt = nil
            S.Teleported = false
            S.PathIndex = 1
            S.Path = Stop.Path and table.clone(Stop.Path) or {}
            S.InteractAt = nil
            S.TeleportFrom = nil
            S.Teleports = 0
            S.TeleportHold = nil
            S.PromptUsed = false
            S.SpotWaitUntil = nil
            S.SkipSpotWait = S.SkipSpotWaitNext == true
            S.SkipSpotWaitNext = false
            S.InteractSuppressed = false
            S.PromptFallback = nil
            S.ResetHumanoid = nil
            S.ResetFiredAt = nil
            S.ResetRetries = 0
            S.RestartStop = false
            --// A new visit has not been fought yet. The return check is armed
            --// again by FinishRecovery, after this reset.
            S.ReturnKill = false
            S.ReturnMissAt = nil
            S.RecoveredAt = nil
            StopFlee()
            S.HpAt = nil
            S.HpBase = nil
            S.SkillWas = false
            EndDodge()
            S.BestDistance = nil
            S.LastProgressAt = Now
            S.Resets = 0
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
            SetStatus(string.format("STOP %d/%d  %s", S.Index, #Stops, Stop.Label))
        end

        local function Advance(Now)
            local Stops = GetStops()
            S.SeenTarget = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            S.KillAt = nil
            S.FightStart = nil
            S.WalkStart = nil
            S.WaitUntil = nil
            S.BestDistance = nil
            S.LastProgressAt = nil

            if #Stops == 0 then
                S.Phase = "Idle"
                SetStatus("ADD A BOSS STOP")
                return
            end

            if S.Index >= #Stops then
                if CONFIG.BOSS_ROUTE_LOOP == false then
                    S.Phase = "Done"
                    SetStatus("ROUTE FINISHED")
                    SwitchOff()
                    return
                end

                S.Index = 1
            else
                S.Index += 1
            end

            BeginStop(Now)
        end

        --// Restart: the character died rather than being reset here, so the
        --// same stop is walked again from its first path point once it is back.
        local function BeginRecover(Now, Reason, Restart)
            EndDodge()
            StopFlee()
            S.Phase = "Recover"
            S.PhaseStart = Now
            S.RecoveredAt = nil
            S.RestartStop = Restart == true
            AICCombat.S.ClosestTarget = nil
            ResetWalk()
            SetStatus(string.format("STOP %d/%d  %s", S.Index, #GetStops(), Reason))
        end

        local function BeginReset(Now, Reason)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            S.Resets += 1

            if Humanoid and Humanoid.Health > 0 then
                Humanoid:Move(Vector3.zero)
                --// The same reset Party System uses; the game respawns the
                --// character and, on a death, takes the EXP it takes.
                Humanoid.Health = 0
                --// The respawn this causes bumps DEATH_COUNT a frame after the
                --// new body, which can be after the route has advanced. It is
                --// this reset, not a death the route has to walk back from.
                S.OwnDeaths = (S.OwnDeaths or 0) + 1
                S.OwnDeathAt = Now
            end

            --// The body this fired on. A retry re-kills only that one: a
            --// character that already respawned is a new Humanoid, and
            --// killing it again is not a retry, it is a second reset.
            S.ResetHumanoid = Humanoid
            S.ResetFiredAt = Now
            S.ResetRetries = 0
            S.ResetPosition = RootPart and RootPart.Position or nil

            BeginRecover(Now, "RESET " .. Reason)
            Say("Boss Route", string.format("Reset %s at stop #%d", Reason, S.Index), 3)
        end

        --// The recovery is done. A planned reset moves the route on; a death
        --// walks the same stop's path again, from its first point, instead of
        --// pretending the boss was dealt with.
        local function FinishRecovery(Now)
            if S.RestartStop then
                S.RestartStop = false
                --// The stop is walked again after a death. The walk back is
                --// followed by the fight straight away, whatever the stop's
                --// Wait At Spot says: nothing is being waited for.
                S.SkipSpotWaitNext = true
                --// A boss this stop had before the death is carried into the
                --// walk back: if it is gone when the character returns, the
                --// duo finished it and the stop still owes its reset.
                local HadBoss = S.SeenTarget == true
                    or S.FoughtThisVisit == true
                    or S.ReturnKill == true
                BeginStop(Now)
                S.ReturnKill = HadBoss
            else
                Advance(Now)
            end

            --// The stop is about to travel and the body is a fresh respawn. The
            --// game drops a TeleportEvent fired this early, so hold the body
            --// for a moment before the first attempt: firing on the respawn
            --// frame left the stop being walked from spawn instead.
            if S.Phase == "Approach" then
                S.TeleportHold = Now + RESPAWN_SETTLE
            end
        end

        --// A death the dead-frame check never got to see. A game that
        --// respawns in the same instant it kills destroys the body and hands
        --// back a live one before the next step, and Runtime:GetCharacter()
        --// follows it: Health never reads 0, so the route never entered
        --// Recover and the walk back from the spawn was taken for a fresh
        --// arrival - which held Wait At Spot at a boss that had just killed
        --// the character. The player's death counter does not have that gap:
        --// CharacterAdded bumps it however fast the respawn is.
        --//
        --// A bump while Recover runs is the route's own reset (or a death it
        --// already has), so it is only marked as read.
        local function WatchDeath(Now)
            local Count = GetDeathCount()

            if S.DeathMark == nil then
                S.DeathMark = Count
                return false
            end

            if Count <= S.DeathMark then
                S.DeathMark = Count
                return false
            end

            S.DeathMark = Count

            --// A bump this route's own reset caused can arrive after the new
            --// body has been seen and the next stop is already under way. It
            --// is that reset, not a death: consuming it here keeps the stop
            --// from restarting mid-approach and losing its teleport.
            if (S.OwnDeaths or 0) > 0
                and S.OwnDeathAt
                and Now - S.OwnDeathAt <= RESPAWN_TIMEOUT + RESPAWN_SETTLE + 5
            then
                S.OwnDeaths -= 1

                if S.OwnDeaths <= 0 then
                    S.OwnDeaths = 0
                    S.OwnDeathAt = nil
                end

                return false
            end

            --// Already recovering from it, or nothing left to walk again.
            if S.Phase == "Recover" or S.Phase == "Done" or not CurrentStop() then
                return false
            end

            --// Died and is back already: the stop is walked again from where
            --// the character is, and its Wait At Spot is not held on the
            --// arrival - the boss that killed it is standing there.
            BeginRecover(Now, "DIED", true)
            return true
        end

        --// Waits for the character after a reset or a death, then for Wait
        --// After Reset (and the EXP drop, when the stop asks for it). The wait
        --// is measured from the frame the character is back, so the death
        --// animation is never mistaken for part of it.
        local function RecoverStep(Now)
            if S.Phase ~= "Recover" then
                return false
            end

            local _, Humanoid = Runtime:GetCharacter()

            if not Humanoid or Humanoid.Health <= 0 then
                S.RecoveredAt = nil

                if Now - S.PhaseStart >= RESPAWN_TIMEOUT then
                    Say(
                        "Boss Route",
                        S.RestartStop
                            and "No respawn; retrying the stop"
                            or "No respawn, moving to the next stop",
                        4
                    )
                    FinishRecovery(Now)
                end

                return true
            end

            --// Still standing in the same body after a reset means the game
            --// dropped it (a load, a guard, a script that restores health):
            --// ask again instead of calling the character recovered and
            --// walking off. A respawn is a new Humanoid, so it is never this
            --// branch.
            local _, _, RootPart = Runtime:GetCharacter()
            local StayedPut = not S.ResetPosition
                or (RootPart ~= nil
                    and (RootPart.Position - S.ResetPosition).Magnitude <= RESET_STAY_DISTANCE)
            --// Same body, still where it was reset. A mere "the same Humanoid"
            --// is not enough: a game that revives the body rather than
            --// replacing it leaves the character at spawn instead.
            local ResetPending = S.ResetHumanoid == Humanoid
                and S.ResetFiredAt ~= nil
                and StayedPut
                and not S.RestartStop

            if ResetPending then
                if (S.ResetRetries or 0) < RESET_RETRIES
                    and Now - S.ResetFiredAt >= RESET_RETRY_TIME
                then
                    S.ResetRetries = (S.ResetRetries or 0) + 1
                    S.ResetFiredAt = Now
                    S.RecoveredAt = nil
                    Humanoid:Move(Vector3.zero)
                    Humanoid.Health = 0
                    SetStatus(string.format(
                        "STOP %d/%d  RESET RETRY %d",
                        S.Index,
                        #GetStops(),
                        S.ResetRetries
                    ))
                    Say("Boss Route", string.format(
                        "Reset retried at stop #%d (the game ignored it)",
                        S.Index
                    ), 4)
                    return true
                end

                --// Not recovered yet: the character is still the body the
                --// reset fired on. Only the no-respawn timeout can end this.
                if Now - S.PhaseStart < RESPAWN_TIMEOUT then
                    SetStatus(string.format("STOP %d/%d  RESET PENDING", S.Index, #GetStops()))
                    return true
                end
            end

            if not S.RecoveredAt then
                S.RecoveredAt = Now
                --// The body is back, so there is nothing left to retry.
                S.ResetHumanoid = nil
                S.ResetFiredAt = nil
            end

            --// Back on the character and straight on. The pause that matters
            --// is the one before the reset (Reset After); waiting after the
            --// respawn only delayed the next stop, which is why there is no
            --// second pause here.
            FinishRecovery(Now)
            return true
        end

        --// Nearest living mob at the stop that matches its Boss Names (or any
        --// mob when none are set). The scan is shared by every frame that asks
        --// within SCAN_INTERVAL.
        local ScanAt = 0
        local ScanKey = nil
        local ScanResult = nil
        --// Kept apart from ScanResult, which is nil when the scan found
        --// nothing: without it an empty spot would rescan every frame.
        local ScanDone = false

        --// Auto Farm's own IsCombatTargetValid also demands the name be on the
        --// Enemy Priority list and that the mob be within its farm engage
        --// range. A boss stop knows nothing about that list, so a boss the stop
        --// names was found and then thrown away: the character stood at the
        --// stop without drawing its weapon. A boss stop validates its own
        --// target instead.
        local function IsStopTargetAlive(Mob)
            if not Mob or not Mob:IsA("Model") or not Mob:IsDescendantOf(workspace) then
                return false
            end

            local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
            local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

            return MobHumanoid ~= nil and MobRoot ~= nil and MobHumanoid.Health > 0
        end

        --// Whether the game still says this mob is alive. Deliberately looser
        --// than IsStopTargetAlive: a root that is gone for a moment (a model
        --// swap, a spawn animation) does not make a living boss a corpse.
        local function IsMobAlive(Mob)
            if not Mob then
                return false
            end

            local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")

            return MobHumanoid ~= nil and (tonumber(MobHumanoid.Health) or 0) > 0
        end

        --// The stop still wants this mob: its name is on the list, or the stop
        --// takes anything. Checked on the fallback target so removing a boss
        --// name mid-fight is not treated as a kill.
        local function IsWantedTarget(Mob, Stop)
            if not Mob then
                return false
            end

            if #Stop.Targets == 0 then
                return true
            end

            local Name = AICCombat.GetTargetEntityName(Mob)

            --// A name that cannot be read right now (a model swapped for a
            --// phase) is not proof the boss was taken off the list: the mob
            --// that was already being fought is kept in that case.
            return Name == nil or table.find(Stop.Targets, Name) ~= nil
        end

        local function FindTarget(Stop, Now)
            local Key = string.format(
                "%d|%s|%s",
                S.Index,
                tostring(Stop.Radius),
                table.concat(Stop.Targets, ",")
            )

            if not ScanDone or Now - ScanAt >= SCAN_INTERVAL or ScanKey ~= Key then
                ScanAt = Now
                ScanKey = Key
                ScanDone = true

                local Best, BestDistance = nil, math.huge
                local MobFolder = workspace:FindFirstChild("Mobs")

                for _, Mob in ipairs(MobFolder and MobFolder:GetChildren() or {}) do
                    if Mob:IsA("Model") then
                        local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                        local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                        if MobHumanoid and MobRoot and MobHumanoid.Health > 0 then
                            local Distance = (MobRoot.Position - Stop.Position).Magnitude

                            if Distance <= Stop.Radius and Distance < BestDistance then
                                local Name = AICCombat.GetTargetEntityName(Mob)
                                local Match = Name ~= nil
                                    and (#Stop.Targets == 0 or table.find(Stop.Targets, Name) ~= nil)

                                if Match then
                                    Best, BestDistance = Mob, Distance
                                end
                            end
                        end
                    end
                end

                ScanResult = Best
            end

            if IsStopTargetAlive(ScanResult) then
                return ScanResult
            end

            return nil
        end

        --// A matching boss lying dead in the stop's radius. The scan above only
        --// ever returns a living humanoid, so a boss that died between two
        --// scans left nothing behind to say the stop was done - and the route
        --// walked off to the next waypoint without resetting. A corpse is that
        --// evidence.
        local function FindDeadStopTarget(Stop)
            local MobFolder = workspace:FindFirstChild("Mobs")
            local Radius = tonumber(Stop.Radius) or 0

            for _, Mob in ipairs(MobFolder and MobFolder:GetChildren() or {}) do
                if Mob:IsA("Model") then
                    local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                    local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                    if MobHumanoid and MobRoot and MobHumanoid.Health <= 0
                        and AICCombatUtils.GetHorizontalDistance(Stop.Position, MobRoot.Position) <= Radius
                    then
                        local Name = AICCombat.GetTargetEntityName(Mob)

                        if Name and (#Stop.Targets == 0 or table.find(Stop.Targets, Name)) then
                            return Mob
                        end
                    end
                end
            end

            return nil
        end

        --// Asks for the sword. The cached Equipped flag is not trusted: it
        --// survives a reset or a respawn that sheathed the sword, so checking
        --// it meant this helper was never called and the boss was fought
        --// unarmed until an attack happened to equip the sword. The helper
        --// itself reads the weld and rate-limits with the game's equip
        --// cooldown, so asking every frame cannot toggle the sword.
        --// True when the equip input was just sent: the game needs a frame to
        --// swap the weld, and closing in with the sword still on the back is
        --// how the character got hit before it could swing.
        local function RequireWeapon(Now)
            if not AICFeature.EnsureWeaponDrawn then
                return false
            end

            return AICFeature.EnsureWeaponDrawn(Now) == true
        end

        --// The boss's own skill effects, listed once per target and refreshed
        --// slowly: sounds and particles on its weapon, plus anything named for
        --// a skill. Ambient particles on the body are left out on purpose -
        --// they never go out, and the dodge is waiting for exactly that.
        local SkillEffects = { Target = nil, At = 0, List = {} }

        local function GetSkillEffects(Target, Now)
            if SkillEffects.Target == Target
                and Now - SkillEffects.At < SKILL_SCAN_INTERVAL
            then
                return SkillEffects.List
            end

            local List = {}
            local Scan = Target.GetDescendants

            if Scan then
                for _, Descendant in ipairs(Scan(Target)) do
                    local Name = string.lower(tostring(Descendant.Name or ""))

                    if Descendant:IsA("Sound") then
                        if string.find(Name, "skill", 1, true) then
                            table.insert(List, Descendant)
                        end
                    elseif Descendant:IsA("ParticleEmitter")
                        or Descendant:IsA("Sparkles")
                    then
                        local Parent = Descendant.Parent

                        if string.find(Name, "skill", 1, true)
                            or (Parent and Parent.Name == "BladePart")
                        then
                            table.insert(List, Descendant)
                        end
                    end
                end
            end

            SkillEffects.Target = Target
            SkillEffects.At = Now
            SkillEffects.List = List

            return List
        end

        --// True while the boss's skill is still showing. The shared check reads
        --// the game's Skill sound and the blade's Sparkles, the same signal Auto
        --// Farm reacts to; the list above covers a boss whose effects sit
        --// somewhere else on the model.
        local function IsSkillShowing(Target, Now)
            if not Target then
                return false
            end

            if AICCombat.IsEnemyUsingSkill and AICCombat.IsEnemyUsingSkill(Target) then
                return true
            end

            for _, Effect in ipairs(GetSkillEffects(Target, Now)) do
                if Effect.Parent then
                    if Effect:IsA("Sound") then
                        if Effect.IsPlaying then
                            return true
                        end
                    elseif Effect.Enabled then
                        return true
                    end
                end
            end

            return false
        end

        --// A point DODGE_DISTANCE from the boss: straight away first, then to
        --// either side, then behind, skipping directions with a hole or a wall.
        --// Measured from the boss rather than from the character, so every
        --// pick lands on the same ring instead of one ring further out.
        local function PickDodgePoint(RootPart, TargetRoot, Distance)
            Distance = tonumber(Distance) or DODGE_DISTANCE

            local Away = Vector3.new(
                RootPart.Position.X - TargetRoot.Position.X,
                0,
                RootPart.Position.Z - TargetRoot.Position.Z
            )

            if Away.Magnitude < 0.01 then
                Away = Vector3.xAxis
            else
                Away = Away.Unit
            end

            local Height = RootPart.Position.Y

            local function OnRing(Direction)
                return Vector3.new(
                    TargetRoot.Position.X + Direction.X * Distance,
                    Height,
                    TargetRoot.Position.Z + Direction.Z * Distance
                )
            end

            local Fallback = nil

            for _, Degrees in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
                local Angle = math.rad(Degrees)
                local Cos, Sin = math.cos(Angle), math.sin(Angle)
                local Direction = Vector3.new(
                    Away.X * Cos - Away.Z * Sin,
                    0,
                    Away.X * Sin + Away.Z * Cos
                )
                local Candidate = OnRing(Direction)
                local Hole = AICCombatUtils.IsHoleAhead(Candidate)

                if not Hole and AICCombatUtils.IsPathClear(Candidate) then
                    return Candidate
                end

                if not Hole and not Fallback then
                    Fallback = Candidate
                end
            end

            return Fallback or OnRing(Away)
        end

        --// Nearest living mob within Distance of Position, and the part to
        --// run away from. The mob folder is read directly: this only runs
        --// while the reset hold is counting down.
        local function GetNearestMob(Position, Distance)
            local MobFolder = workspace:FindFirstChild("Mobs")
            local BestRoot, BestDistance = nil, Distance

            for _, Mob in ipairs(MobFolder and MobFolder:GetChildren() or {}) do
                if Mob:IsA("Model") then
                    local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                    local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                    if MobHumanoid and MobRoot and MobHumanoid.Health > 0 then
                        local Flat = AICCombatUtils.GetHorizontalDistance(Position, MobRoot.Position)

                        if Flat <= BestDistance then
                            BestRoot, BestDistance = MobRoot, Flat
                        end
                    end
                end
            end

            return BestRoot
        end

        --// While the reset hold runs, a living mob near the corpse is run
        --// from at the dodge's sprint, to the far side of a ring around it.
        --// Standing still for ten seconds next to a mob is what got the
        --// character killed again before the reset it was waiting for.
        local function FleeStep(Humanoid, RootPart, Stop)
            local MobRoot = GetNearestMob(RootPart.Position, HOLD_FLEE_DISTANCE)

            if not MobRoot then
                StopFlee(Humanoid)
                return false
            end

            --// The speed to put back is the first one seen, never the sprint.
            S.FleeFromSpeed = S.FleeFromSpeed or tonumber(Humanoid.WalkSpeed) or 0

            local Speed = tonumber(Humanoid.WalkSpeed) or 0
            local RunSpeed = (tonumber(CONFIG.MAXIMUM_WALKSPEED) or Speed) + DODGE_SPEED_BONUS

            if Speed < RunSpeed then
                Humanoid.WalkSpeed = RunSpeed
            end

            local Distance = HOLD_FLEE_RING

            if Stop and tonumber(Stop.DodgeDistance) then
                Distance = math.max(Distance, tonumber(Stop.DodgeDistance))
            end

            local Point = PickDodgePoint(RootPart, MobRoot, Distance)
            AICCombatUtils.DoJumpIfObstacle(Point)
            Humanoid:MoveTo(Point)

            return true
        end

        --// Runs away from the boss at sprint speed. True while the dodge is
        --// still running; false on the frame it ends (and whenever there is no
        --// dodge), so the fight can carry on.
        --//
        --// The health burst starts it, but the skill's own effects end it: it
        --// runs for at least DODGE_MIN_TIME and after that only comes back once
        --// those effects have been off for DODGE_EFFECT_GRACE. A skill that
        --// keeps its particles up for two seconds is dodged for two seconds;
        --// one that flashes past still gets the full minimum. DODGE_MAX_TIME
        --// is the ceiling, for an effect that never switches off.
        local function DodgeStep(Target, Humanoid, RootPart, Now, Stop)
            --// Ended (or never armed). The state is cleared even when no speed
            --// was borrowed - a dodge that started already out on the ring
            --// never takes one - or the stale max keeps looking like a dodge.
            if (S.DodgeMaxUntil or 0) <= 0 or S.DodgeMaxUntil <= Now then
                if (S.DodgeMaxUntil or 0) > 0 then
                    EndDodge(Humanoid)
                end

                return false
            end

            local TargetRoot = Target and Target:FindFirstChild("HumanoidRootPart")

            if not TargetRoot then
                EndDodge(Humanoid)
                return false
            end

            S.SkillActive = IsSkillShowing(Target, Now)

            if S.SkillActive then
                S.SkillSeenAt = Now
            end

            local EffectsGoneAt = (S.SkillSeenAt or 0) + DODGE_EFFECT_GRACE

            if Now >= math.max(S.DodgeMinUntil or 0, EffectsGoneAt) then
                EndDodge(Humanoid)
                return false
            end

            --// Kept on one ring around the boss. Out there already, it stands
            --// its ground: the old code picked a point further away every time
            --// it arrived, so a long skill walked it across the map.
            local Distance = tonumber(Stop and Stop.DodgeDistance) or DODGE_DISTANCE
            local FromBoss = AICCombatUtils.GetHorizontalDistance(TargetRoot.Position, RootPart.Position)

            if FromBoss < Distance - DODGE_HOLD_SLACK then
                local Stale = not S.DodgeTarget
                    or AICCombatUtils.GetHorizontalDistance(S.DodgeTarget, TargetRoot.Position) > 6

                if Stale then
                    --// The speed to put back is the first one seen, never the
                    --// sprint a later frame is already running at.
                    S.DodgeFromSpeed = S.DodgeFromSpeed or tonumber(Humanoid.WalkSpeed) or 0
                    S.DodgeTarget = PickDodgePoint(RootPart, TargetRoot, Distance)
                end

                --// Run, not walk: the normal run speed plus a sprint.
                local Speed = tonumber(Humanoid.WalkSpeed) or 0
                local RunSpeed = (tonumber(CONFIG.MAXIMUM_WALKSPEED) or Speed) + DODGE_SPEED_BONUS

                if Speed < RunSpeed then
                    Humanoid.WalkSpeed = RunSpeed
                end

                AICCombatUtils.DoJumpIfObstacle(S.DodgeTarget)
                Humanoid:MoveTo(S.DodgeTarget)
            else
                --// On the ring (or the boss came no closer): hold here, facing
                --// it, until the skill's effects go out. The sprint is only
                --// for getting out, so standing still is done at the normal
                --// speed; EndDodge puts it back again anyway.
                S.DodgeTarget = nil

                if S.DodgeFromSpeed then
                    Humanoid.WalkSpeed = S.DodgeFromSpeed
                end

                Humanoid:Move(Vector3.zero)
                AICCombat.FaceCombatTarget(Target)
            end

            SetStatus(string.format("STOP %d/%d  DODGE", S.Index, #GetStops()))

            return true
        end

        --// True when health fell by a burst inside the window: a boss skill.
        local function IsHealthBurst(Humanoid, Now)
            local MaxHealth = tonumber(Humanoid.MaxHealth) or 0

            if MaxHealth <= 0 then
                return false
            end

            local Percent = math.clamp((tonumber(Humanoid.Health) or 0) / MaxHealth, 0, 1)

            if not S.HpAt or Now - S.HpAt > BURST_WINDOW then
                S.HpAt = Now
                S.HpBase = Percent
                return false
            end

            if Percent > (S.HpBase or 0) then
                S.HpBase = Percent
            end

            if (S.HpBase or 0) - Percent >= BURST_DROP_PERCENT then
                S.HpAt = Now
                S.HpBase = Percent
                return true
            end

            return false
        end

        --// Walks into swinging distance and fights. The attack goes through
        --// AttackTarget, not PerformCombatActions: that one also demands the
        --// mob be on Auto Farm's Enemy Priority list, so the boss stop's own
        --// target was found, drawn for, and then never swung at.
        local function Fight(Target, Now, Stop)
            local _, Humanoid, RootPart = Runtime:GetCharacter()
            local TargetRoot = Target:FindFirstChild("HumanoidRootPart")

            if not Humanoid or not RootPart or not TargetRoot then
                return
            end

            --// Per stop: a boss whose effects never go out can be fought with
            --// the dodge off instead of being run away from forever.
            local Dodge = not Stop or Stop.Dodge ~= false
            local Casting = Dodge and IsSkillShowing(Target, Now) == true
            --// The rising edge is the cast starting. Starting here steps out
            --// before the damage lands; the burst below stays as the backup
            --// for a skill whose effects were missed.
            local Opened = Casting and not S.SkillWas
            S.SkillWas = Casting

            if RequireWeapon(Now) then
                Humanoid:Move(Vector3.zero)
                return
            end

            if Opened then
                --// Already running (a burst dodge, or a second cast right
                --// after the first): keep its point, because a fresh one
                --// would be measured from a character already sprinting.
                local Running = (S.DodgeMaxUntil or 0) > Now

                S.DodgeMinUntil = Now + DODGE_MIN_TIME
                S.DodgeMaxUntil = Now + DODGE_MAX_TIME
                S.SkillSeenAt = Now
                S.SkillActive = true

                if not Running then
                    S.DodgeTarget = nil
                end
            end

            --// A dodge running owns the frame, and it holds until the boss's
            --// effects have gone out again (see DodgeStep).
            if DodgeStep(Target, Humanoid, RootPart, Now, Stop) then
                if Opened then
                    Say("Boss Route", "Dodging a skill at stop #" .. tostring(S.Index), 2)
                end
                return
            end

            if Dodge and IsHealthBurst(Humanoid, Now) then
                local Running = (S.DodgeMaxUntil or 0) > Now

                S.DodgeMinUntil = Now + DODGE_MIN_TIME
                S.DodgeMaxUntil = Now + DODGE_MAX_TIME

                if not Running then
                    S.SkillSeenAt = nil
                    S.SkillActive = false
                    S.DodgeTarget = nil
                end

                if DodgeStep(Target, Humanoid, RootPart, Now, Stop) then
                    Say("Boss Route", "Dodging a skill at stop #" .. tostring(S.Index), 2)
                    return
                end
            end

            --// A stop is fought before Auto Farm's own health decision runs,
            --// so this was the one place a potion was never drunk: the dodge
            --// and the walk take the frame, and the boss fights ran to the
            --// death with the health the stop started with.
            local HealPercent = math.clamp(tonumber(CONFIG.AUTO_HEAL_HEALTH_PERCENT) or 65, 30, 80)
            local MaxHealth = tonumber(Humanoid.MaxHealth) or 0

            if MaxHealth > 0
                and (tonumber(Humanoid.Health) or 0) <= MaxHealth * (HealPercent / 100)
                and AICFeature.TryHeal
                and AICFeature.TryHeal(Now)
            then
                Humanoid:Move(Vector3.zero)
                return
            end

            local Offset = TargetRoot.Position - RootPart.Position
            local Distance = AICCombat.GetCombatDistance(Target, Offset)

            if Distance > FIGHT_STANDOFF then
                local Flat = Vector3.new(Offset.X, 0, Offset.Z)
                local Direction = Flat.Magnitude > 0.01 and Flat.Unit or Vector3.xAxis
                --// Stop just short of the body, not inside it.
                local Destination = TargetRoot.Position - Direction * math.max(FIGHT_STANDOFF - 1, 2)

                AICCombatUtils.DoJumpIfObstacle(Destination)
                Humanoid:MoveTo(Destination)
            else
                Humanoid:Move(Vector3.zero)
                AICCombat.FaceCombatTarget(Target)
            end

            --// The same swing and skill inputs Auto Farm presses, with the
            --// same attack clock. Called while closing in too: it only swings
            --// once the target is in the combat range.
            AICCombat.AttackTarget(Target, Now)
        end

        --// The Farming waypoint route presses the game's Interact input while
        --// it walks (Auto Farm does it every INTERACTION_INTERVAL), which is
        --// how doors, levers and other proximity prompts get used on the way.
        --// Boss Route owns the frame, so nothing else would press it and the
        --// character would walk straight past every prompt on the path.
        local function PressInteract(Now)
            local GetInput = Runtime.GetInputBindableFunction

            if not GetInput then
                return
            end

            local Interval = tonumber(CONFIG.INTERACTION_INTERVAL) or INTERACT_INTERVAL

            --// Off for the rest of a visit that travelled by prompt: the
            --// teleport itself is the travel, and a press at the prompt it
            --// landed on fires the same door or menu again (some doors
            --// teleport the character, which made that an endless loop of x
            --// presses). A ten-second runtime mute is set with it, so a
            --// hand-off to Auto Farm stays quiet too.
            if S.InteractSuppressed or Runtime.IsInteractMuted and Runtime:IsInteractMuted() then
                return
            end

            if S.InteractAt and Now - S.InteractAt < Interval then
                return
            end

            S.InteractAt = Now

            local InputBindableFunction = GetInput(Runtime)

            if not InputBindableFunction then
                return
            end

            --// A game without the binding must not break the walk.
            pcall(function()
                InputBindableFunction:Invoke(
                    "InteractButton",
                    Enum.UserInputState.Begin
                )
            end)
        end

        --// Where an interaction prompt stands: the part it belongs to. A
        --// prompt may hang off a part directly, off an Attachment, or off a
        --// Model/Folder inside the room, so the ancestors are walked rather
        --// than only the immediate parent. That spot is what the character has
        --// to be near for the prompt to show, so it is the teleport target.
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

        --// A prompt, or a click detector: either way its part is where the
        --// game expects the character to stand, which is all a teleport target
        --// needs. A prompt the game has switched off is skipped.
        local function IsPromptLike(Object)
            if Object:IsA("ProximityPrompt") then
                return Object.Enabled ~= false
            end

            return Object:IsA("ClickDetector")
        end

        --// Nearest interaction object to a point: the best inside Radius, plus
        --// how far the nearest one anywhere was, so a miss can say why.
        local function FindNearestPrompt(Position, Radius)
            local Best, BestDistance = nil, Radius
            local Nearest = math.huge

            for _, Descendant in ipairs(workspace:GetDescendants()) do
                if IsPromptLike(Descendant) then
                    local PromptPosition = GetPromptPosition(Descendant)

                    if PromptPosition then
                        local Distance = (PromptPosition - Position).Magnitude

                        if Distance < Nearest then
                            Nearest = Distance
                        end

                        if Distance <= BestDistance then
                            Best, BestDistance = Descendant, Distance
                        end
                    end
                end
            end

            return Best, Nearest == math.huge and nil or Nearest
        end

        --// Puts the character at a point, no walk. Only ever used for a prompt
        --// the stop asked for, and never on a dead or missing body.
        local function TeleportToPoint(Position)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Position or not Humanoid or not RootPart or Humanoid.Health <= 0 then
                return false
            end

            local Ok = pcall(function()
                RootPart.CFrame = CFrame.new(Position + Vector3.new(0, 3, 0))
            end)

            return Ok
        end

        --// Where the stop goes by prompt: the one it saved, or the nearest to
        --// the stop when it saved none. Resolved once per visit and kept, so
        --// the workspace is not walked for prompts every frame.
        local function GetStopPromptPosition(Stop)
            if not Stop.Prompt then
                return nil
            end

            if Stop.PromptPosition then
                return Stop.PromptPosition
            end

            if S.PromptFallback == nil then
                local Prompt = FindNearestPrompt(Stop.Position, PROMPT_SCAN_RADIUS)
                S.PromptFallback = GetPromptPosition(Prompt) or false
            end

            return S.PromptFallback or nil
        end

        local function TeleportToWaypoint(Number)
            local TeleportEvent = Replicated:FindFirstChild("TeleportEvent", true)

            if not TeleportEvent then
                Say("Boss Route", "No TeleportEvent in this game; walking instead", 4)
                return false
            end

            local Ok, Error = pcall(function()
                TeleportEvent:FireServer(Number)
            end)

            if not Ok then
                Say("Boss Route", "Teleport failed: " .. tostring(Error), 4)
                return false
            end

            return true
        end

        --// How long a spot with no boss has to stay empty before the walk back
        --// calls it a kill: one scan miss can be a model swap, two cannot.
        local RETURN_KILL_MISS_SECONDS = 1

        --// Back at a stop the character died at. The boss may have been killed
        --// by the duo (or anyone else) while the character was dead, and that
        --// kill used to be invisible: the walk back found nothing at the spot,
        --// the stop timed out and the route moved on with no reset. The spot is
        --// watched instead - a living boss is walked to as usual, and a spot
        --// that stays empty is this stop's kill. The reset that follows is the
        --// ordinary one, so its Reset After pause and its EXP hold are exactly
        --// the ones a kill the character landed itself gets.
        local function CheckReturnKill(Stop, Now)
            if FindTarget(Stop, Now) then
                S.ReturnMissAt = nil
                return false
            end

            if not S.ReturnMissAt then
                S.ReturnMissAt = Now
                return false
            end

            if Now - S.ReturnMissAt < RETURN_KILL_MISS_SECONDS then
                return false
            end

            S.ReturnMissAt = nil
            S.ReturnKill = false
            S.Phase = "Fight"
            S.FightStart = Now
            S.SeenTarget = true
            S.FoughtThisVisit = true
            S.LastTarget = nil
            S.TargetSeenAt = nil
            S.KillAt = Now
            SetStatus(string.format(
                "STOP %d/%d  BOSS DOWN WHILE AWAY",
                S.Index,
                #GetStops()
            ))
            Say("Boss Route", string.format(
                "Boss at stop #%d died while away; counted as this stop's kill",
                S.Index
            ), 4)
            return true
        end

        local function ApproachStep(Stop, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return
            end

            --// A fresh respawn needs a moment before the game will move it: a
            --// TeleportEvent fired on the respawn frame is dropped and the stop
            --// then gets walked from spawn. This also spaces out the retries.
            if S.TeleportHold then
                if Now < S.TeleportHold
                    and (Stop.Prompt or (Stop.Waypoint or 0) > 0)
                then
                    Humanoid:Move(Vector3.zero)
                    return
                end

                S.TeleportHold = nil
            end

            --// The stop saved an interaction prompt (a door or portal in front
            --// of the boss): land on it once, then walk the rest. A stop that
            --// has both uses the prompt first, because it is the point of
            --// having saved one. Nothing is pressed on it: the teleport is the
            --// travel, and a press re-fires the prompt it landed on.
            if not S.PromptUsed then
                local PromptPosition = GetStopPromptPosition(Stop)

                if PromptPosition then
                    S.PromptUsed = true
                    --// The prompt is this visit's travel, so a waypoint the
                    --// stop also names is not taken on top of it.
                    S.Teleported = true
                    S.TeleportFrom = RootPart.Position
                    --// Off before the teleport, not on landing: waiting to
                    --// mute afterwards left a frame or two where a press
                    --// could still go out. It stays off for the visit, and
                    --// nothing is pressed on the prompt either: the teleport
                    --// is the travel, and a press would re-fire the door or
                    --// menu standing where the character lands.
                    S.InteractSuppressed = true

                    if Runtime.MuteInteract then
                        Runtime:MuteInteract(PROMPT_INTERACT_MUTE)
                    end

                    if TeleportToPoint(PromptPosition) then
                        S.WaitUntil = Now + PROMPT_WAIT
                        SetStatus(string.format(
                            "STOP %d/%d  TELEPORT %s",
                            S.Index,
                            #GetStops(),
                            Stop.PromptName ~= "" and Stop.PromptName or "PROMPT"
                        ))
                        return
                    end
                end
            end

            --// The stop names one of the game's waypoints: take it once, then
            --// give the character a moment to land.
            if not S.Teleported and (Stop.Waypoint or 0) > 0 then
                S.Teleported = true
                S.TeleportFrom = RootPart.Position
                --// A waypoint can land on a prompt, and the walk after it can
                --// pass the same one again. Off for the visit, set before the
                --// request goes out so no press can beat the mute.
                S.InteractSuppressed = true

                if Runtime.MuteInteract then
                    Runtime:MuteInteract(PROMPT_INTERACT_MUTE)
                end

                if TeleportToWaypoint(Stop.Waypoint) then
                    S.WaitUntil = Now + TELEPORT_WAIT
                    SetStatus(string.format("STOP %d/%d  TELEPORT WP%d", S.Index, #GetStops(), Stop.Waypoint))
                    return
                end
            end

            if S.WaitUntil and Now < S.WaitUntil then
                Humanoid:Move(Vector3.zero)
                return
            end

            --// Walking back from a death: a boss that is still there is walked
            --// to, and one that is gone is the kill the character did not get
            --// to see. Checked on the way, not only at the spot, so a kill the
            --// duo lands during the run back does not cost the whole walk.
            if S.ReturnKill and CheckReturnKill(Stop, Now) then
                return
            end

            --// A teleport fired before a just-respawned character had loaded
            --// can be dropped by the game. If nothing moved and the stop is
            --// still far away, hold the body and ask again rather than walking
            --// the whole way from spawn. Bounded, so a game that never accepts
            --// the request still reaches the stop.
            if S.TeleportFrom then
                local Moved = (RootPart.Position - S.TeleportFrom).Magnitude
                local ToStop = AICCombatUtils.GetHorizontalDistance(Stop.Position, RootPart.Position)
                S.TeleportFrom = nil

                if Moved < TELEPORT_LAND_DISTANCE
                    and ToStop > TELEPORT_RETRY_DISTANCE
                    and not S.PromptUsed
                    and (S.Teleports or 0) < TELEPORT_RETRIES
                then
                    S.Teleports = (S.Teleports or 0) + 1
                    S.Teleported = false
                    S.TeleportHold = Now + TELEPORT_RETRY_DELAY
                    Say("Boss Route", string.format(
                        "Teleport did not land at stop #%d; retrying (%d/%d)",
                        S.Index,
                        S.Teleports,
                        TELEPORT_RETRIES
                    ), 4)
                    return
                end
            end

            --// The visit's own points. A stop that began without any takes
            --// whatever the live config holds: points saved (or a config that
            --// loaded) after the walk started are still walked, which is the
            --// window a profile apply lands in.
            if not S.Path or #S.Path == 0 then
                S.Path = Stop.Path and table.clone(Stop.Path) or {}
            end

            local Path = S.Path
            local Point = Path[S.PathIndex]
            local Destination = Point or Stop.Position
            local Reach = Point
                and PATH_REACH
                or (tonumber(Runtime:GetPlaceConfig().REACH_DISTANCE) or REACH_DISTANCE)
            local Flat = AICCombatUtils.GetHorizontalDistance(Destination, RootPart.Position)

            --// Close to the stop now: get the sword out before the fight, so
            --// the first swing is not spent equipping it under the boss.
            if AICCombatUtils.GetHorizontalDistance(Stop.Position, RootPart.Position) <= WEAPON_READY_DISTANCE then
                RequireWeapon(Now)
            end

            --// On the way: use whatever prompt the character passes, the same
            --// way the Farming waypoint route does. Not on the frame the stop
            --// is reached, where the fight begins instead.
            if Flat > Reach then
                PressInteract(Now)
            end

            --// Progress, not the walker's opinion: a wrong point or a wall in
            --// the way shows up as no approach at all.
            if not S.BestDistance or Flat < S.BestDistance - 0.5 then
                S.BestDistance = Flat
                S.LastProgressAt = Now
            end

            if Now - (S.LastProgressAt or Now) >= NO_PROGRESS_TIMEOUT
                or Now - (S.WalkStart or Now) > WALK_TIMEOUT
            then
                Say("Boss Route", "Could not reach stop #" .. tostring(S.Index) .. "; skipping", 4)
                Advance(Now)
                return
            end

            if WalkTo(Destination, Reach, Now) then
                if Point then
                    S.PathIndex += 1
                    S.BestDistance = nil
                    S.LastProgressAt = Now
                    --// The 120 s cap is per leg, so a long recorded route is
                    --// not cut short just for having many points.
                    S.WalkStart = Now
                    ResetWalk()

                    SetStatus(string.format(
                        "STOP %d/%d  PATH %d/%d",
                        S.Index,
                        #GetStops(),
                        math.min(S.PathIndex - 1, #Path),
                        #Path
                    ))
                else
                    --// Wait At Spot (s), 0 for a new stop: hold the fight long
                    --// enough for a boss that spawns a moment after the walk
                    --// arrives. At 0 the fight starts on this frame, which is
                    --// what most stops want. Never held on a visit that
                    --// continues a stop the character died at: whatever is
                    --// there already killed the character, so there is no
                    --// spawn to wait for.
                    local Wait = S.SkipSpotWait and 0 or (tonumber(Stop.Wait) or 0)

                    if Wait > 0 and not S.SpotWaitUntil then
                        S.SpotWaitUntil = Now + Wait
                    end

                    if S.SpotWaitUntil and Now < S.SpotWaitUntil then
                        Humanoid:Move(Vector3.zero)
                        SetStatus(string.format(
                            "STOP %d/%d  WAIT %ds  %s",
                            S.Index,
                            #GetStops(),
                            math.ceil(S.SpotWaitUntil - Now),
                            Stop.Label
                        ))
                        return
                    end

                    S.SpotWaitUntil = nil

                    --// On the spot: fight straight away. The scan is forced,
                    --// so a boss that dies within the first eighth of a second
                    --// is still seen and counted as this stop's kill instead
                    --// of being walked past.
                    S.Phase = "Fight"
                    S.FightStart = Now
                    S.SeenTarget = false
                    S.LastTarget = nil
                    S.TargetSeenAt = nil
                    S.KillAt = nil
                    ScanAt = 0
                    ScanDone = false
                    Humanoid:Move(Vector3.zero)
                    SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                end

                return
            end

            if Point then
                SetStatus(string.format(
                    "STOP %d/%d  PATH %d/%d",
                    S.Index,
                    #GetStops(),
                    S.PathIndex,
                    #Path
                ))
            elseif #Path == 0 then
                --// Nothing to follow: the walk goes straight at the stop,
                --// across whatever lies between. Said on the status, which is
                --// the line that is always visible.
                SetStatus(string.format(
                    "STOP %d/%d  WALKING  NO PATH POINTS",
                    S.Index,
                    #GetStops()
                ))
            else
                SetStatus(string.format("STOP %d/%d  WALKING", S.Index, #GetStops()))
            end
        end

        local function FightStep(Stop, Now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not Humanoid or not RootPart then
                return
            end

            local Target = FindTarget(Stop, Now)
            local Scanned = Target ~= nil

            --// The scan is a snapshot of the room, not the game's health: a
            --// boss that steps out of the engage radius, has its model swapped
            --// for a phase, or loses its root for a frame disappears from it
            --// while still alive. Treating that as a kill reset the character
            --// in the middle of the fight (the free path fires a fifth of a
            --// second after one missed scan). The mob already being fought is
            --// kept instead - but only while the scan keeps finding it every
            --// so often. A reference the scan never sees again is a body the
            --// game has taken away (another player's kill, a corpse moved out
            --// of the Mobs folder), not a boss still standing: holding it cost
            --// nothing while it was alive and frozen the stop in FIGHT when it
            --// was not, so the keep lapses after TARGET_KEEP_TIME.
            if not Target
                and IsMobAlive(S.LastTarget)
                and IsWantedTarget(S.LastTarget, Stop)
                and Now - (S.TargetSeenAt or 0) <= TARGET_KEEP_TIME
            then
                Target = S.LastTarget
            end

            if Target then
                S.SeenTarget = true
                S.FoughtThisVisit = true
                S.LastTarget = Target
                S.KillAt = nil

                --// The scan watching it is the clock the keep above runs on.
                if Scanned then
                    S.TargetSeenAt = Now
                end
                AICCombat.S.ClosestTarget = Target

                SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                Fight(Target, Now, Stop)
                return
            end

            AICCombat.S.ClosestTarget = nil
            Humanoid:Move(Vector3.zero)
            EndDodge(Humanoid)
            --// Nothing to watch for a cast: the next target starts a fresh
            --// rising edge instead of inheriting this one.
            S.SkillWas = false

            --// The boss went down: a grace period covers a second mob of the
            --// same stop still standing up, then the stop's own Reset After
            --// pause is held before the character is reset.
            if S.SeenTarget then
                --// A boss that is still alive is never a kill, even when no
                --// scan finds it - as long as the scan still finds it now and
                --// then. Past TARGET_KEEP_TIME its health no longer holds the
                --// stop: it is not standing at the spot any more. The name was
                --// taken off this stop's list: the route simply moves on, with
                --// no reset and no EXP lost.
                if IsMobAlive(S.LastTarget)
                    and Now - (S.TargetSeenAt or 0) <= TARGET_KEEP_TIME
                then
                    if not IsWantedTarget(S.LastTarget, Stop) then
                        Advance(Now)
                    else
                        SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                    end

                    return
                end

                S.KillAt = S.KillAt or Now

                --// The pause belongs to the reset; with Reset After Kill off
                --// there is nothing to wait for and the route moves on after
                --// the grace. A reset that costs no EXP is not held at all, so
                --// the ten seconds only ever show up when there is something
                --// to lose - unless Always Wait Before Reset is on, which holds
                --// every reset for its pause whatever the EXP would cost.
                local Hold = Stop.ResetAfterKill and GetResetHold(Stop) or 0
                --// A reset with nothing to lose is not held at all: one scan
                --// tick after the kill, not the two-second grace the held
                --// path uses to see whether a second mob of the stop is still
                --// standing up.
                local Grace = Hold > 0 and KILL_GRACE or FREE_RESET_GRACE
                local Left = math.max(Grace, Hold) - (Now - S.KillAt)

                if Left > 0.05 then
                    if Hold > 0 then
                        local Loss = GetResetCost()
                        local Fleeing = FleeStep(Humanoid, RootPart, Stop)

                        --// With nothing at risk the hold is the Always Wait
                        --// toggle holding a reset the EXP check called free,
                        --// so say that rather than "LOSE 0 EXP".
                        local Risk = Loss == nil and "COST UNKNOWN"
                            or (Loss > 0 and string.format("LOSE %d EXP", math.floor(Loss + 0.5))
                                or (Loss == 0 and "AT THE LIMIT" or "NO EXP AT RISK"))

                        SetStatus(string.format(
                            "STOP %d/%d  CLEARING  %ds  %s%s",
                            S.Index,
                            #GetStops(),
                            math.ceil(Left),
                            Risk,
                            Fleeing and "  RUNNING" or ""
                        ))
                    else
                        SetStatus(string.format("STOP %d/%d  RESET NOW", S.Index, #GetStops()))
                    end

                    return
                end

                --// The fight is done. The only reset is this one: after the
                --// kill, never while the boss is still standing.
                StopFlee(Humanoid)

                if Stop.ResetAfterKill then
                    BeginReset(Now, "BOSS DOWN")
                else
                    Advance(Now)
                end

                return
            end

            --// A matching boss lying dead in the radius is a kill, even when
            --// the scan never caught it standing: without this the stop was
            --// walked off (and the next waypoint taken) with no reset.
            local Dead = FindDeadStopTarget(Stop)

            if Dead and not S.SeenTarget then
                S.SeenTarget = true
                S.FoughtThisVisit = true
                S.KillAt = Now
                SetStatus(string.format("STOP %d/%d  BOSS DOWN", S.Index, #GetStops()))
                return
            end

            --// Nothing here at all: the boss is dead already, on its respawn
            --// timer, or the spot is wrong.
            SetStatus(string.format("STOP %d/%d  NOTHING TO FIGHT", S.Index, #GetStops()))

            if S.FightStart and Now - S.FightStart >= NO_TARGET_TIMEOUT then
                --// A reset this stop still owes is never skipped by the
                --// timeout: that is what sent the route to the next waypoint
                --// leaving the character alive and the EXP untouched.
                if Stop.ResetAfterKill and S.Resets == 0 and S.FoughtThisVisit then
                    BeginReset(Now, "BOSS DOWN")
                    return
                end

                Advance(Now)
            end
        end

        local function Step(Now)
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
            EndDodge()
            S.HpAt = nil
            S.HpBase = nil
            S.Index = 1
            S.Phase = "Idle"
            S.SeenTarget = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            S.KillAt = nil
            S.WaitUntil = nil
            S.SpotWaitUntil = nil
            S.WalkStart = nil
            S.SkipSpotWait = false
            S.SkipSpotWaitNext = false
            SyncDeathMark()
            ResetWalk()
        end

        ------------------------------------------------------------------------
        --// Boss route floor visualization (separate from the mob debugger).
        ------------------------------------------------------------------------

        local VisualFolder
        local ColorSaveQueued = false
        local function QueueColorSave()
            if ColorSaveQueued then return end
            ColorSaveQueued = true
            task.delay(0.5, function()
                ColorSaveQueued = false
                if Context.Lifetime.Alive then AICProfile.WriteGlobalStore() end
            end)
        end

        local function ClearBossVisuals()
            if VisualFolder then
                VisualFolder:Destroy()
                VisualFolder = nil
            end
        end

        local function RefreshBossVisuals()
            ClearBossVisuals()
            if not CONFIG.BOSS_PATH_VISIBLE then return end

            local Stops = GetStops()
            if #Stops == 0 then return end

            local Color = Color3.fromHex(CONFIG.BOSS_PATH_COLOR or "4F7CF5")
            VisualFolder = Instance.new("Folder")
            VisualFolder.Name = "AICBossRouteVisuals"
            VisualFolder.Parent = workspace

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            local Excluded = { VisualFolder }
            if Player.Character then table.insert(Excluded, Player.Character) end
            if AICCombatUtils.S.DebugFolder then table.insert(Excluded, AICCombatUtils.S.DebugFolder) end
            Params.FilterDescendantsInstances = Excluded
            Params.IgnoreWater = true

            local function Ground(Position)
                local Hit = workspace:Raycast(Position + Vector3.new(0, 2, 0), Vector3.new(0, -24, 0), Params)
                return Hit and (Hit.Position + Vector3.new(0, 0.08, 0)) or (Position - Vector3.new(0, 2.9, 0))
            end

            local function Part(Name, Size, Placement)
                local Item = Instance.new("Part")
                Item.Name = Name
                Item.Anchored = true
                Item.CanCollide = false
                Item.CanTouch = false
                Item.CanQuery = false
                Item.CastShadow = false
                Item.Material = Enum.Material.Neon
                Item.Color = Color
                Item.Transparency = 0.2
                Item.Size = Size
                Item.CFrame = Placement
                Item.Parent = VisualFolder
                return Item
            end

            local function Point(Position, Name)
                local Marker = Part(Name, Vector3.new(0.08, 1.1, 1.1), CFrame.new(Position) * CFrame.Angles(0, 0, math.rad(90)))
                Marker.Shape = Enum.PartType.Cylinder
            end

            local function Line(From, To, Name, Width)
                local Direction = To - From
                local Length = Direction.Magnitude
                if Length < 0.01 then return end
                local Up = math.abs(Direction.Unit.Y) > 0.98 and Vector3.new(0, 0, 1) or Vector3.new(0, 1, 0)
                Part(Name, Vector3.new(Width, 0.08, Length), CFrame.lookAt((From + To) * 0.5, To, Up))
            end

            for Index, Stop in ipairs(Stops) do
                local Destination = Ground(Stop.Position)
                local Previous
                for PointIndex, Position in ipairs(Stop.Path or {}) do
                    local Current = Ground(Position)
                    Point(Current, string.format("Stop%d_Point%d", Index, PointIndex))
                    if Previous then Line(Previous, Current, "PathLine", 0.18) end
                    Previous = Current
                end
                if Previous then Line(Previous, Destination, "PathToStop", 0.18) end

                Point(Destination, "Stop" .. Index)
                -- A small outlined ring identifies the stop without filling the
                -- entire engage radius or adding floating labels.
                local Radius, Segments = 2.4, 24
                for Segment = 1, Segments do
                    local A = (Segment - 1) * math.pi * 2 / Segments
                    local B = Segment * math.pi * 2 / Segments
                    local From = Destination + Vector3.new(math.cos(A) * Radius, 0, math.sin(A) * Radius)
                    local To = Destination + Vector3.new(math.cos(B) * Radius, 0, math.sin(B) * Radius)
                    Line(From, To, "StopRing", 0.16)
                end
            end
        end

        AICUI.RefreshBossVisuals = RefreshBossVisuals
        Context.Lifetime.OnEnd(ClearBossVisuals)

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        UIRef.BossSection = UIRef.BossTab:AddSection{ Title = "Route Controls", Side = "Left" }
        UIRef.BossStopsSection = UIRef.BossTab:AddSection{ Title = "Boss Stops", Side = "Left" }
        UIRef.BossEditorSection = UIRef.BossTab:AddSection{ Title = "Selected Stop", Side = "Right" }
        UIRef.BossNamesSection = UIRef.BossTab:AddSection{ Title = "Boss Targets", Side = "Right" }
        UIRef.BossTravelSection = UIRef.BossTab:AddSection{ Title = "Teleport and Prompt", Side = "Right" }

        UIRef.BossToggle = AICUI.BindFeatureToggle("BossRoute", "Boss Route", function(Enabled)
            if Enabled then
                S.Index = 1
                S.Phase = "Idle"
                --// Deaths from while the route was off are not this run's.
                SyncDeathMark()
                BeginStop(os.clock())
            else
                StopRoute("OFF")
            end
        end, UIRef.BossSection)

        UIRef.BossStatusLabel = UIRef.BossSection:AddLabel("STATUS:  IDLE")

        UIRef.BossSection:AddToggle{
            Name = "Show Boss Path",
            Default = CONFIG.BOSS_PATH_VISIBLE == true,
            Callback = function(Value)
                CONFIG.BOSS_PATH_VISIBLE = Value == true
                RefreshBossVisuals()
                AICProfile.WriteGlobalStore()
            end,
        }

        UIRef.BossSection:AddColorPicker{
            Name = "Boss Path Color",
            Default = Color3.fromHex(CONFIG.BOSS_PATH_COLOR or "4F7CF5"),
            Callback = function(Color)
                local Hex = Color:ToHex():upper()
                if CONFIG.BOSS_PATH_COLOR == Hex then return end
                CONFIG.BOSS_PATH_COLOR = Hex
                -- Recolor existing geometry without rebuilding it during drag.
                if VisualFolder then
                    for _, Item in ipairs(VisualFolder:GetChildren()) do
                        if Item:IsA("BasePart") then Item.Color = Color end
                    end
                end
                QueueColorSave()
            end,
        }

        --// Turns instant resets off: with it on, every stop takes its Reset (s)
        --// before resetting, even when the character's EXP is inside the part of
        --// the bar a reset keeps and the wait would cost nothing.
        UIRef.BossAlwaysWaitToggle = UIRef.BossSection:AddToggle{
            Name = "Always Wait Before Reset",
            Default = CONFIG.BOSS_RESET_ALWAYS_WAIT == true,
            Callback = function(Value)
                CONFIG.BOSS_RESET_ALWAYS_WAIT = Value == true

                if AICProfile.S.ActiveProfileName then
                    AICProfile.SaveActiveProfile()
                end

                SetStatus(CONFIG.BOSS_RESET_ALWAYS_WAIT
                    and "ALWAYS WAIT BEFORE RESET"
                    or "INSTANT RESET WHEN NOTHING IS AT RISK")
            end,
        }

        UIRef.BossStopsSection:AddButton{
            Name = "Add Boss Stop Here",
            Callback = function()
            local _, _, RootPart = Runtime:GetCharacter()

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit() then
                return
            end

            local Stops = GetStops()

            table.insert(Stops, {
                Label = "Boss " .. tostring(#Stops + 1),
                Position = AICConfig.RoundVector3(RootPart.Position),
                Path = {},
                Targets = {},
                Waypoint = 0,
                ResetAfterKill = true,
                ResetWait = AICConfig.DEFAULT_BOSS_RESET_WAIT,
                Dodge = true,
                DodgeDistance = AICConfig.DEFAULT_BOSS_DODGE_DISTANCE,
                Prompt = false,
                PromptPosition = nil,
                PromptName = "",
                Radius = AICConfig.DEFAULT_BOSS_RADIUS,
                Wait = 0,
            })

            AICProfile.S.SelectedBossStopIndex = #GetStops()
            Commit("BOSS STOP ADDED #" .. tostring(#GetStops()))
            Say("Boss Route", "Added boss stop #" .. tostring(#GetStops()))
            end,
        }

        UIRef.BossStopsSection:AddButton{
            Name = "Clear Boss Route",
            Callback = function()
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.clear(GetStops())
            AICProfile.S.SelectedBossStopIndex = 1
            S.Index = 1
            S.Phase = "Idle"
            Commit("BOSS ROUTE CLEARED")
            Say("Boss Route", "Cleared every boss stop")
            end,
        }

        UIRef.BossListComponent = UIRef.BossStopsSection:AddPriority("Boss Route", BuildLabels(), {
            --// Seconds held at the corpse before a reset that costs EXP. The
            --// reset is not held at all when it would cost nothing, unless
            --// Always Wait Before Reset is on.
            Values = true,
            ValueLabel = "Reset (s)",
            Default = AICConfig.DEFAULT_BOSS_RESET_WAIT,
            Min = 0,
            Max = AICConfig.MAX_BOSS_RESET,
        })

        UIRef.BossListComponent.OnValueChanged = function(Index, Value)
            local Stop = GetStops()[Index]

            if not Stop then
                return
            end

            if not AICProfile.S.ActiveProfileName then
                SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                AICUI.RefreshBossRouteList()
                return
            end

            Stop.ResetWait = Value
            AICProfile.QueueProfileSave()
            SetStatus(string.format("STOP #%d RESETS %ss AFTER THE KILL", Index, tostring(Value)))
        end


        --// Stops move in place, so their timers, teleport and names travel with
        --// them. The labels are rebuilt afterwards: they carry the number.
        local OriginalMoveUp = UIRef.BossListComponent.MoveUp
        local OriginalMoveDown = UIRef.BossListComponent.MoveDown
        local OriginalRemove = UIRef.BossListComponent.Remove

        local function MoveStop(Component, Label, Delta, Original, StatusText)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Stops = GetStops()
            local Index = table.find(BuildLabels(), Label)
            local Other = Index and Index + Delta

            if not Other or Other < 1 or Other > #Stops then
                return
            end

            Stops[Index], Stops[Other] = Stops[Other], Stops[Index]
            Original(Component, Label)
            AICProfile.S.SelectedBossStopIndex = Other
            Commit(StatusText)
        end

        function UIRef.BossListComponent:MoveUp(Label)
            MoveStop(self, Label, -1, OriginalMoveUp, "BOSS STOP MOVED UP")
        end

        function UIRef.BossListComponent:MoveDown(Label)
            MoveStop(self, Label, 1, OriginalMoveDown, "BOSS STOP MOVED DOWN")
        end

        function UIRef.BossListComponent:Remove(Label)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = table.find(BuildLabels(), Label)

            if not Index then
                return
            end

            table.remove(GetStops(), Index)
            OriginalRemove(self, Label)
            AICProfile.S.SelectedBossStopIndex = math.clamp(Index, 1, math.max(1, #GetStops()))

            if S.Index > #GetStops() then
                S.Index = math.max(1, #GetStops())
            end

            Commit("BOSS STOP REMOVED #" .. tostring(Index))
        end

        AICUI.RefreshBossRoutePickers()

        --// Per stop edits. Each box writes the selected stop and commits it,
        --// so what the list shows and what the run reads can never differ.
        local function AddStopBox(Label, Write)
            return UIRef.BossEditorSection:AddTextBox{
                Name = Label,
                Default = "",
                Inline = true,
                Callback = function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                if not Write(Stop, Value) then
                    SetStatus("INVALID VALUE")
                    RefreshEditor()
                    return
                end

                Commit(string.format("STOP #%d UPDATED", AICProfile.S.SelectedBossStopIndex))
                end,
            }
        end

        UIRef.BossNameBox = AddStopBox("Boss Stop Name", function(Stop, Value)
            local Text = tostring(Value or ""):gsub("^%s*(.-)%s*$", "%1")

            if Text == "" then
                return false
            end

            Stop.Label = string.sub(Text, 1, MAX_LABEL_LENGTH)
            return true
        end)

        UIRef.BossWaypointBox = AddStopBox("Teleport Waypoint #", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.Waypoint = math.clamp(math.floor(Number), 0, AICConfig.MAX_BOSS_WAYPOINT)
            return true
        end)

        UIRef.BossDodgeDistanceBox = AddStopBox("Dodge Distance", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number <= 0 then
                return false
            end

            Stop.DodgeDistance = math.clamp(
                math.floor(Number),
                AICConfig.MIN_BOSS_DODGE_DISTANCE,
                AICConfig.MAX_BOSS_DODGE_DISTANCE
            )
            return true
        end)

        --// Pause at the spot before the fight. 0 (the default) starts it as
        --// soon as the walk arrives; a few seconds lets a boss that spawns
        --// just after the character lands appear before the first scan.
        UIRef.BossWaitBox = AddStopBox("Wait At Spot (s)", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number < 0 then
                return false
            end

            Stop.Wait = math.clamp(Number, 0, AICConfig.MAX_WAYPOINT_WAIT)
            return true
        end)

        UIRef.BossRadiusBox = AddStopBox("Engage Radius", function(Stop, Value)
            local Number = tonumber(Value)

            if not Number or Number <= 0 then
                return false
            end

            Stop.Radius = math.clamp(Number, 1, AICConfig.MAX_BOSS_RADIUS)
            return true
        end)

        --// Reset once the boss is down, i.e. the character respawns at the
        --// usual spawn point before the next stop is travelled to. Off, the
        --// next stop starts from wherever the fight ended.
        UIRef.BossResetAfterKillToggle = UIRef.BossEditorSection:AddToggle{
            Name = "Reset After Kill",
            Default = true,
            Callback = function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                Stop.ResetAfterKill = Value == true
                AICProfile.SaveActiveProfile()
                SetStatus(
                    Stop.ResetAfterKill
                        and "STOP RESETS AFTER THE KILL"
                        or "STOP STAYS WHERE THE BOSS DIED"
                )
            end,
        }

        --// The dodge is per stop: a boss whose effects never switch off can be
        --// fought with it off, instead of being run away from every time.
        UIRef.BossDodgeToggle = UIRef.BossEditorSection:AddToggle{
            Name = "Dodge Skills",
            Default = true,
            Callback = function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                Stop.Dodge = Value == true
                AICProfile.SaveActiveProfile()
                SetStatus(
                    Stop.Dodge
                        and "STOP DODGES BOSS SKILLS"
                        or "STOP IGNORES BOSS SKILLS"
                )
            end,
        }

        --// Travel by the interaction prompt in front of the boss rather than a
        --// numbered waypoint. Off, the stop is walked or waypointed as before.
        UIRef.BossPromptToggle = UIRef.BossTravelSection:AddToggle{
            Name = "Teleport To Prompt",
            Default = false,
            Callback = function(Value)
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    RefreshEditor()
                    return
                end

                Stop.Prompt = Value == true
                AICProfile.SaveActiveProfile()
                SetStatus(
                    Stop.Prompt
                        and "STOP TELEPORTS TO ITS PROMPT"
                        or "STOP TRAVELS BY PATH / WAYPOINT"
                )
            end,
        }

        UIRef.BossPromptLabel = UIRef.BossTravelSection:AddLabel(
            "PROMPT:  NONE SAVED  (NEAREST TO THE STOP IS USED)"
        )

        --// Every branch says something on screen (a toast as well as the
        --// status line, which sits at the top of the tab and is easy to miss),
        --// and a miss still saves the spot the player is standing on: that is
        --// where the game's prompt is, whether or not the game implements it
        --// as a ProximityPrompt.
        UIRef.BossPromptButton = UIRef.BossTravelSection:AddButton{
            Name = "Save Prompt Here",
            Callback = function()
            local Stop = SelectedStop()
            local _, _, RootPart = Runtime:GetCharacter()

            if not Stop then
                SetStatus("ADD A BOSS STOP FIRST")
                Say("Boss Route", "Add a boss stop first", 4)
                return
            end

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                Say("Boss Route", "Character not ready", 4)
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = AICProfile.S.SelectedBossStopIndex
            local Prompt, Nearest = FindNearestPrompt(RootPart.Position, PROMPT_SAVE_RADIUS)
            local Position = GetPromptPosition(Prompt)

            if not Position then
                Stop.PromptPosition = AICConfig.RoundVector3(RootPart.Position)
                Stop.PromptName = "HERE"
                Stop.Prompt = true
                Commit(string.format("PROMPT: STOOD HERE, SAVED FOR STOP #%d", Index))
                RefreshEditor()
                Say("Boss Route", string.format(
                    "No prompt within %d studs%s; saved where you stand",
                    PROMPT_SAVE_RADIUS,
                    Nearest and string.format(" (nearest %.0f)", Nearest) or ""
                ), 5)
                return
            end

            Stop.PromptPosition = AICConfig.RoundVector3(Position)
            Stop.PromptName = string.sub(tostring(Prompt.Name or ""), 1, 64)
            Stop.Prompt = true
            Commit(string.format("PROMPT %s SAVED FOR STOP #%d", Stop.PromptName, Index))
            RefreshEditor()
            Say("Boss Route", "Prompt saved: " .. Stop.PromptName, 4)
            end,
        }

        --// Boss names come from a list of the mobs around the player, the same
        --// way Zone Targets does it, so nothing has to be typed.
        UIRef.BossNamesComponent = UIRef.BossNamesSection:AddPriority("Boss Names", {})

        --// Built here, before the refresh button, so the button sits directly
        --// under the picker: both take the next two slots of the section.
        AICUI.RefreshBossNames()

        UIRef.BossRefreshButton = UIRef.BossNamesSection:AddButton{
            Name = "Refresh Nearby Bosses",
            Callback = function()
            AICUI.RefreshBossNames()
            SetStatus("NEARBY BOSSES REFRESHED")
            end,
        }

        local OriginalNameRemove = UIRef.BossNamesComponent.Remove
        local OriginalNameMoveUp = UIRef.BossNamesComponent.MoveUp
        local OriginalNameMoveDown = UIRef.BossNamesComponent.MoveDown

        local function CommitNames(Component)
            local Stop = SelectedStop()

            if Stop then
                Stop.Targets = table.clone(Component.Priority)
                AICProfile.SaveActiveProfile()
            end

            AICUI.RefreshBossNames()
        end

        local function NamesGuard()
            if AICProfile.S.ActiveProfileName and SelectedStop() then
                return true
            end

            SetStatus("ADD A BOSS STOP FIRST")
            return false
        end

        function UIRef.BossNamesComponent:Remove(Value)
            if not NamesGuard() then
                return false
            end

            local Changed = OriginalNameRemove(self, Value)
            CommitNames(self)
            return Changed
        end

        function UIRef.BossNamesComponent:MoveUp(Value)
            if not NamesGuard() then
                return
            end

            OriginalNameMoveUp(self, Value)
            CommitNames(self)
        end

        function UIRef.BossNamesComponent:MoveDown(Value)
            if not NamesGuard() then
                return
            end

            OriginalNameMoveDown(self, Value)
            CommitNames(self)
        end

        UIRef.BossEditorSection:AddButton{
            Name = "Move Stop Here",
            Callback = function()
            local Stop = SelectedStop()
            local _, _, RootPart = Runtime:GetCharacter()

            if not Stop then
                SetStatus("ADD A BOSS STOP FIRST")
                return
            end

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            Stop.Position = AICConfig.RoundVector3(RootPart.Position)
            Commit(string.format("STOP #%d MOVED HERE", AICProfile.S.SelectedBossStopIndex))
            end,
        }

        UIRef.BossEditorSection:AddButton{
            Name = "Remove Stop",
            Callback = function()
            local Index = AICProfile.S.SelectedBossStopIndex
            local Stops = GetStops()

            if not Stops[Index] then
                SetStatus("ADD A BOSS STOP FIRST")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.remove(Stops, Index)
            AICProfile.S.SelectedBossStopIndex = math.clamp(Index, 1, math.max(1, #GetStops()))

            if S.Index > #GetStops() then
                S.Index = math.max(1, #GetStops())
            end

            Commit("BOSS STOP REMOVED #" .. tostring(Index))
            end,
        }

        UIRef.BossLoopToggle = UIRef.BossSection:AddToggle{
            Name = "Loop Route",
            Default = CONFIG.BOSS_ROUTE_LOOP ~= false,
            Callback = function(Value)
                CONFIG.BOSS_ROUTE_LOOP = Value == true

                if AICProfile.S.ActiveProfileName then
                    AICProfile.SaveActiveProfile()
                end

                SetStatus(CONFIG.BOSS_ROUTE_LOOP and "ROUTE LOOPS" or "ROUTE RUNS ONCE")
            end,
        }

        ------------------------------------------------------------------------
        --// Path to Boss: the points walked to reach each stop
        ------------------------------------------------------------------------

        UIRef.BossPathSection = UIRef.BossTab:AddSection{ Title = "Path to Boss", Side = "Left" }
        UIRef.BossPathLabel = UIRef.BossPathSection:AddLabel("PATH TO BOSS  NO STOP SELECTED")

        UIRef.BossPathSection:AddButton{
            Name = "Add Path Point Here",
            Callback = function()
            local Stop = SelectedStop()
            local _, _, RootPart = Runtime:GetCharacter()

            if not Stop then
                SetStatus("PICK A BOSS STOP FIRST")
                return
            end

            if not RootPart then
                SetStatus("CHARACTER NOT READY")
                return
            end

            if not CanEdit() then
                return
            end

            Stop.Path = Stop.Path or {}
            table.insert(Stop.Path, AICConfig.RoundVector3(RootPart.Position))
            Commit(string.format("PATH POINT #%d ADDED", #Stop.Path))
            Say("Boss Route", string.format("Path point #%d saved", #Stop.Path))
            end,
        }

        UIRef.BossPathSection:AddButton{
            Name = "Clear Path",
            Callback = function()
            local Stop = SelectedStop()

            if not Stop then
                SetStatus("PICK A BOSS STOP FIRST")
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            table.clear(Stop.Path or {})
            Commit("PATH CLEARED")
            end,
        }

        UIRef.BossPathComponent = UIRef.BossPathSection:AddPriority("Path Points", {})

        local PathMoveUp = UIRef.BossPathComponent.MoveUp
        local PathMoveDown = UIRef.BossPathComponent.MoveDown
        local PathRemove = UIRef.BossPathComponent.Remove

        local function MovePath(Component, Label, Delta, Original, StatusText)
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Path = Stop.Path or {}
            local Index = table.find(BuildPathLabels(), Label)
            local Other = Index and Index + Delta

            if not Other or Other < 1 or Other > #Path then
                return
            end

            Path[Index], Path[Other] = Path[Other], Path[Index]
            Original(Component, Label)
            Commit(StatusText)
        end

        function UIRef.BossPathComponent:MoveUp(Label)
            MovePath(self, Label, -1, PathMoveUp, "PATH POINT MOVED UP")
        end

        function UIRef.BossPathComponent:MoveDown(Label)
            MovePath(self, Label, 1, PathMoveDown, "PATH POINT MOVED DOWN")
        end

        function UIRef.BossPathComponent:Remove(Label)
            local Stop = SelectedStop()

            if not Stop then
                return
            end

            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return
            end

            local Index = table.find(BuildPathLabels(), Label)

            if not Index then
                return
            end

            table.remove(Stop.Path, Index)
            PathRemove(self, Label)
            Commit("PATH POINT REMOVED #" .. tostring(Index))
        end

        --// Every control exists now, so fill the edit boxes from the selected
        --// stop instead of leaving them empty until the first edit.
        AICUI.RefreshBossRoutePickers()
        AICUI.RefreshBossPathList()
        RefreshBossVisuals()
        SetStatus("IDLE")

        return Feature
    end,
}