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
        local Players = Context.Services.Players
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
        --// A waypoint teleport is watched this long for the body to move. The
        --// watch ends the frame the character moves; only a request that moves
        --// it nowhere at all for the whole window is a dropped one. A fixed
        --// distance check a couple of seconds after the send was too short for
        --// a slow landing: the body was still where the request had fired, the
        --// teleport was read as failed, and the same waypoint was sent again -
        --// a second trip, and a third when a restart in between cleared the
        --// retry count.
        local TELEPORT_LAND_WINDOW = 6
        --// After a respawn the first waypoint teleport waits this long: the
        --// game drops a TeleportEvent fired on the respawn frame, before the
        --// new character has loaded, and the stop was then walked from spawn.
        local RESPAWN_SETTLE = 1.5
        --// A teleport that did not move the character was dropped by the game.
        --// It is asked again this many times, this far apart, before the
        --// route gives up and walks. One: the case the retry covers (a
        --// request fired at a body the game was not ready for) is settled by
        --// the second try, and a game that keeps dropping them costs the walk
        --// either way.
        local TELEPORT_RETRIES = 1
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
        --// The game's mark that the player damaged a mob, in
        --// ReplicatedStorage.PlayerDamageTags, is named <PlayerName> + this.
        local DAMAGE_TAG_SUFFIX = "MobDamaged"
        --// A tag that never clears must not freeze the route: past this many
        --// seconds the hold starts anyway.
        local TAG_WAIT_MAX = 10
        --// A reset that waits for nothing (Reset (s) set to 0, or a reset the
        --// EXP check called free) waits this long for that tag at most. The
        --// game clears the tag a couple of seconds after the last hit, and
        --// that wait sat in front of every zero-delay reset: the stop was set
        --// to reset on the spot and still stood at the corpse for two seconds
        --// with nothing on the status to say why. Long enough for the last hit
        --// to be awarded, short enough to be a zero delay. Death Farm skips it
        --// altogether.
        local TAG_WAIT_FREE = 0.6
        --// A reset whose character never comes back gives up after this.
        local RESPAWN_TIMEOUT = 20
        --// EXP kept after a reset: ten percent of the level's own EXP bar for
        --// every hundred levels, straight from the level (see GetKeepPercent).
        --// Only the EXP above that protected part is lost, and what a reset
        --// would take is read before the reset, because the hold at the corpse
        --// is only worth having when there is something to lose.
        --// The hold a stop that has no Reset (s) of its own gets. A stop that
        --// does have one is waited exactly that long, with nothing added.
        local DEFAULT_RESET_HOLD = 10
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
        --// How far from that mob the hold runs to. Only a floor: a mob that
        --// detects from further away is run from to its own range.
        local HOLD_FLEE_RING = 45
        --// Run this far past the mob's own detection range, so it drops the
        --// chase instead of following the character to the ring.
        local FLEE_RANGE_MARGIN = 8
        --// The longest run a hold will make. A boss that detects from 300
        --// studs must not send the character across the map: 120 is the
        --// route's own boss radius.
        local FLEE_RING_MAX = 120
        --// Waited after a prompt teleport, for the landing and the prompt's
        --// own range check, before Interact is pressed.
        local PROMPT_WAIT = 0.6
        --// A prompt teleport that leaves the character further than this from
        --// the prompt did not take: the body was snapped back, and walking is
        --// the only way left.
        local PROMPT_ARRIVAL = 12
        --// A landing this far below the prompt fell through the floor it was
        --// sent to, whatever the floor probe under the body reads.
        local PROMPT_FALL_DEPTH = 12
        --// Looked at again this long after a landing was put back on the floor,
        --// so the short drop has settled before the walk starts.
        local PROMPT_RECHECK = 0.4
        --// The floor under the body: probed this far above the root and this
        --// far below the feet, so a body inside the ground or through it is
        --// measured rather than guessed.
        local FLOOR_PROBE_UP = 6
        local FLOOR_PROBE_DOWN = 40
        --// Feet this far under the surface are inside the ground, not on it. A
        --// slope or a stair contact reads about zero, so only real burial
        --// passes this.
        local FLOOR_BURIED = 1.5
        --// Lifted this far above the surface, then let fall back onto it.
        local FLOOR_LIFT_CLEARANCE = 3
        --// Lifts per visit. A spot that buries the character again after this
        --// many is not walked out of; the no-progress timeout moves on.
        local FLOOR_LIFTS = 3
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
        --// The fight box a stop can save: four corners, kept as one
        --// axis-aligned rectangle. nil until all four exist, so a half-typed
        --// box changes nothing and the dodge keeps its old behaviour.
        local BOUNDS_INSET = 2
        local BOUNDS_MIN_SIZE = 6

        local function GetBoundsRect(Stop)
            local Points = Stop and Stop.Bounds

            if type(Points) ~= "table" or #Points < AICConfig.MAX_BOSS_BOUNDS then
                return nil
            end

            local MinX, MaxX = math.huge, -math.huge
            local MinZ, MaxZ = math.huge, -math.huge
            local SumY = 0

            for Index = 1, AICConfig.MAX_BOSS_BOUNDS do
                local Point = Points[Index]

                if typeof(Point) ~= "Vector3" then
                    return nil
                end

                MinX = math.min(MinX, Point.X)
                MaxX = math.max(MaxX, Point.X)
                MinZ = math.min(MinZ, Point.Z)
                MaxZ = math.max(MaxZ, Point.Z)
                SumY = SumY + Point.Y
            end

            if MaxX - MinX < BOUNDS_MIN_SIZE or MaxZ - MinZ < BOUNDS_MIN_SIZE then
                return nil
            end

            return { MinX = MinX, MaxX = MaxX, MinZ = MinZ, MaxZ = MaxZ, Y = SumY / 4 }
        end

        local function InsideBounds(Stop, Point, Inset)
            local Rect = GetBoundsRect(Stop)

            if not Rect or not Point then
                return true
            end

            Inset = Inset or 0

            return Point.X >= Rect.MinX + Inset and Point.X <= Rect.MaxX - Inset
                and Point.Z >= Rect.MinZ + Inset and Point.Z <= Rect.MaxZ - Inset
        end

        local function ClampToBounds(Stop, Point, Inset)
            local Rect = GetBoundsRect(Stop)

            if not Rect or not Point then
                return Point
            end

            Inset = Inset or BOUNDS_INSET
            local MinX, MaxX = Rect.MinX + Inset, Rect.MaxX - Inset
            local MinZ, MaxZ = Rect.MinZ + Inset, Rect.MaxZ - Inset

            if MinX > MaxX then
                MinX = (Rect.MinX + Rect.MaxX) / 2
                MaxX = MinX
            end

            if MinZ > MaxZ then
                MinZ = (Rect.MinZ + Rect.MaxZ) / 2
                MaxZ = MinZ
            end

            return Vector3.new(
                math.clamp(Point.X, MinX, MaxX),
                Point.Y,
                math.clamp(Point.Z, MinZ, MaxZ)
            )
        end

        --// Four thin panels mark the fight box in the world. They are display
        --// only: CanCollide/CanTouch/CanQuery are off, so neither the game nor
        --// the route's own raycasts can hit them.
        local BoundsVisualFolder

        local function ClearBoundsVisual()
            if BoundsVisualFolder then
                BoundsVisualFolder:Destroy()
                BoundsVisualFolder = nil
            end
        end

        local function RefreshBoundsVisual(Stop)
            ClearBoundsVisual()

            if CONFIG.BOSS_BOUNDS_VISIBLE == false then
                return
            end

            local Rect = GetBoundsRect(Stop)

            if not Rect then
                return
            end

            local Height = 12
            local Thick = 0.4
            local MidX = (Rect.MinX + Rect.MaxX) / 2
            local MidZ = (Rect.MinZ + Rect.MaxZ) / 2
            local Width = Rect.MaxX - Rect.MinX
            local Depth = Rect.MaxZ - Rect.MinZ
            local Y = (Rect.Y or 0) + Height / 2

            BoundsVisualFolder = Instance.new("Folder")
            BoundsVisualFolder.Name = "AICBossBoundsVisuals"
            BoundsVisualFolder.Parent = workspace

            local function Wall(Name, Size, Position)
                local Panel = Instance.new("Part")

                Panel.Name = Name
                Panel.Anchored = true
                Panel.CanCollide = false
                Panel.CanTouch = false
                Panel.CanQuery = false
                Panel.CastShadow = false
                Panel.Material = Enum.Material.Neon
                Panel.Color = Color3.fromRGB(255, 120, 40)
                Panel.Transparency = 0.8
                Panel.Size = Size
                Panel.CFrame = CFrame.new(Position)
                Panel.Parent = BoundsVisualFolder
            end

            Wall("BoundsNorth", Vector3.new(Width, Height, Thick), Vector3.new(MidX, Y, Rect.MaxZ))
            Wall("BoundsSouth", Vector3.new(Width, Height, Thick), Vector3.new(MidX, Y, Rect.MinZ))
            Wall("BoundsEast", Vector3.new(Thick, Height, Depth), Vector3.new(Rect.MaxX, Y, MidZ))
            Wall("BoundsWest", Vector3.new(Thick, Height, Depth), Vector3.new(Rect.MinX, Y, MidZ))
        end
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
        --// Pause For Strangers: how long a stranger is given to leave, in
        --// seconds. Picked at random inside the window once per hold, so a run
        --// that pauses on every join never leaves on a rhythm; the whole window
        --// is theirs to go before the game is closed.
        local EVADE_WAIT_MIN = 120
        local EVADE_WAIT_MAX = 180
        --// A reset the game ignores at the start of a hold is asked for again
        --// this long after the last ask, the same number of times the route's
        --// own resets get (RESET_RETRIES).
        local EVADE_KICK_RETRY = 5
        local EVADE_DEAD_SETTLE = 20
        local EVADE_RESET_RETRY_DELAY = 3
        --// A reset that has not landed in this long is not waited for any
        --// further: the hold runs where the body is, which is still standing
        --// still, out of the fight.
        local EVADE_RESET_GIVE_UP = 12

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
                --// When the hold on this stop's kill may start counting. Set
                --// when the game has taken its MobDamaged tag down, which is
                --// the moment the kill is settled; nil while that tag is up.
                HoldFrom = nil,
                --// First frame the tag was found still up, so a tag that never
                --// clears gives up after TAG_WAIT_MAX instead of freezing.
                TagWaitAt = nil,
                --// The walk speed the hold borrowed to run from a mob, so it can
                --// be put back when the hold ends.
                FleeFromSpeed = nil,
                RecoveredAt = nil,
                --// When the game's Interact input was last pressed on the way.
                InteractAt = nil,
                --// Where the character stood when the waypoint teleport was
                --// fired, when it fired, and how many times it has been retried
                --// for this stop.
                TeleportFrom = nil,
                TeleportAt = nil,
                Teleports = 0,
                --// A teleport moved the body on this visit. Once one has, no
                --// later "nothing moved" is read as a dropped request.
                TeleportLanded = false,
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
                --// The visit's prompt teleport: when its landing is checked, and
                --// where it was meant to land.
                PromptCheckAt = nil,
                PromptTargetPosition = nil,
                --// Floor lifts used this visit (see LiftFromFloor).
                FloorLifts = 0,
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
                --// Pause For Strangers (Evasion section). Evading is the whole
                --// hold: the route is parked while it runs and every frame
                --// belongs to EvadeStep, wherever the farm called it from.
                Evading = false,
                --// Who the hold is for, for the status line and the leave.
                EvadeName = "",
                --// "Reset", "Travel" or "Hold".
                EvadeStage = nil,
                EvadeSince = nil,
                --// When the hold ends, and the window it was given (shown at the
                --// start so the wait is never a mystery).
                EvadeWaitUntil = nil,
                EvadeWaitTotal = 0,
                --// The body the hold's reset fired on, when, and where it stood,
                --// so a reset the game dropped is asked for again and a
                --// respawned body is never killed a second time.
                EvadeResetHumanoid = nil,
                EvadeResetAt = nil,
                EvadeResetRetries = 0,
                EvadeResetPosition = nil,
                --// The travel to the evade spot: what has been sent, the body it
                --// was sent from and when (a waypoint landing is watched by
                --// movement), and the prompt landing's check.
                EvadeSent = false,
                EvadeTeleportFrom = nil,
                EvadeTeleportAt = nil,
                EvadePromptCheckAt = nil,
                EvadePromptTarget = nil,
                --// When the body was first standing after the hold's reset. The
                --// travel waits RESPAWN_SETTLE from here: the game drops a
                --// TeleportEvent fired on the respawn frame, and a waypoint
                --// teleport that never went out would leave the character at
                --// spawn instead of the saved spot.
                EvadeLiveAt = nil,
                --// The key of the hiding spot the last hold picked. Kept
                --// across holds on purpose: the next pick steps off it rather
                --// than hiding in the same place twice.
                EvadePick = nil,
                --// The leave was asked for once the window ran out.
                EvadeKicked = false,
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
        --// HUD prints after the slash, AICUI.neededExp(Level). The EXP stat is
        --// a running total counted against that same number, so the share a
        --// reset keeps is taken from it directly. Cached per level, since
        --// this is read every frame of a hold.
        local LevelBars = {}

        --// The bar of a level: its max EXP. nil when it cannot be read.
        local function GetLevelBar(Level)
            if not Level or Level <= 0 then
                return nil
            end

            local Cached = LevelBars[Level]

            if Cached then
                return Cached
            end

            local Needed = type(AICUI.neededExp) == "function" and AICUI.neededExp

            if not Needed then
                return nil
            end

            local Bar = tonumber(Needed(Level))

            if not Bar or Bar <= 0 then
                return nil
            end

            LevelBars[Level] = Bar

            return Bar
        end

        --// How far into its bar the character's EXP is, 0..bar. Past the bar
        --// means the character has levelled up (the stat has not caught up
        --// yet), so it is at the end of the old bar. nil when it is negative
        --// or the bar is unreadable, and then the caller holds rather than
        --// guessing.
        local function GetBarProgress(Exp, Level)
            local Bar = GetLevelBar(Level)

            if not Bar then
                return nil, 0
            end

            if Exp < 0 then
                return nil, Bar
            end

            return math.min(Exp, Bar), Bar
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

        --// The game's own record of the kill, under ReplicatedStorage: while a
        --// mob the player damaged is still being settled, PlayerDamageTags
        --// holds a child named <PlayerName>MobDamaged. The game adds one per
        --// hit and they all keep that same name, so the folder routinely holds
        --// several children called exactly "HuffMobDamaged" at once. This
        --// returns the first it finds; the caller keeps waiting while ANY of
        --// them is still up and starts the hold only when none is left. That
        --// is a better clock than the scan, which can stop finding the body a
        --// moment before the last hit is awarded.
        local function GetDamageTag()
            if not Player or not Player.Name then
                return nil
            end

            local Folder = Replicated and Replicated:FindFirstChild("PlayerDamageTags")

            if not Folder then
                return nil
            end

            local Prefix = Player.Name .. DAMAGE_TAG_SUFFIX
            local Length = #Prefix

            for _, Child in ipairs(Folder:GetChildren()) do
                if string.sub(Child.Name, 1, Length) == Prefix then
                    --// Every one of them is `HuffMobDamaged`; a numbered name
                    --// is only tolerated in case a build ever starts
                    --// numbering them. Nothing else counts as ours.
                    local Rest = string.sub(Child.Name, Length + 1)

                    if Rest == "" or string.match(Rest, "^%d+$") then
                        return Child
                    end
                end
            end

            return nil
        end

        --// The two halves of the kill clock: KillAt is when the boss was seen
        --// down, HoldFrom when this stop's pause may start counting. Both are
        --// dropped together when a fight or a stop begins.
        local function ClearKillClock()
            S.KillAt = nil
            S.HoldFrom = nil
            S.TagWaitAt = nil
        end

        --// Seconds held at the corpse before the reset: the stop's own
        --// Reset (s), ten when it has never been set. That number is the whole
        --// pause - nothing is added to it - so the row and the CLEARING
        --// countdown always read the same. Always Wait After Kill takes it every
        --// time, so nothing resets on the spot even when the EXP check would
        --// have called the reset free. Otherwise nothing is held when the
        --// character's EXP sits inside the part of the bar a reset keeps, and a
        --// cost that cannot be read is a loss and is waited out.
        local function GetResetHold(Stop)
            local Wait = tonumber(Stop and Stop.ResetWait)

            --// A stop saved before Reset (s) existed keeps the default. A 0 that
            --// was actually set is taken at its word and resets on the spot.
            if Wait == nil then
                Wait = DEFAULT_RESET_HOLD
            end

            Wait = math.max(0, Wait)

            --// Death Farm is the strict rule and is taken first: a reset that
            --// costs no EXP happens the moment the kill is in, whatever the
            --// stop's Reset (s) or Always Wait After Kill says, and a reset
            --// that would take EXP waits the stop's own number. A cost that
            --// cannot be read is a loss and is waited out, as everywhere else.
            if CONFIG.BOSS_DEATH_FARM == true then
                local FarmLoss = GetResetCost()

                if FarmLoss == nil then
                    return Wait
                end

                return FarmLoss < 0 and 0 or Wait
            end

            if CONFIG.BOSS_RESET_ALWAYS_WAIT == true then
                return Wait
            end

            local Loss = GetResetCost()

            if Loss == nil then
                return Wait
            end

            --// Below the protected line the reset is free. At the line or
            --// past it, the wait is held.
            if Loss < 0 then
                return 0
            end

            return Wait
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

        --// How far the feet are under the floor the body stands on, in studs.
        --// nil when there is no floor under it at all (a drop, a ledge), so
        --// only a body that is actually inside the ground is measured.
        --//
        --// A prompt teleport sets the body's CFrame, and a landing point that
        --// sits inside a floor leaves the character standing in the ground:
        --// it cannot walk out, nothing on the way notices, and the stop is
        --// skipped as unreachable after twenty seconds of not moving.
        local function GetFloorOverlap(RootPart)
            local Character = RootPart and RootPart.Parent

            if not Character then
                return nil
            end

            local Params = RaycastParams.new()
            Params.FilterType = Enum.RaycastFilterType.Exclude
            Params.FilterDescendantsInstances = { Character }
            --// A swimmer's surface is above the body; water is not a floor.
            Params.IgnoreWater = true

            local FeetY = RootPart.Position.Y - RootPart.Size.Y * 0.5
            local Hit = workspace:Raycast(
                Vector3.new(RootPart.Position.X, RootPart.Position.Y + FLOOR_PROBE_UP, RootPart.Position.Z),
                Vector3.new(0, -(FLOOR_PROBE_UP + FLOOR_PROBE_DOWN), 0),
                Params
            )

            if not Hit then
                return nil
            end

            --// Positive: the floor is above the feet, so the body is in it.
            return Hit.Position.Y - FeetY
        end

        --// Puts the body back above the floor it is standing in and lets the
        --// fall settle it onto the surface. False when it cannot (a dead body,
        --// or the lifts for this visit are used up).
        local function LiftFromFloor(Humanoid, RootPart, Depth)
            if not RootPart or (tonumber(Humanoid and Humanoid.Health) or 0) <= 0 then
                return false
            end

            if (S.FloorLifts or 0) >= FLOOR_LIFTS then
                return false
            end

            local Ok = pcall(function()
                RootPart.CFrame = RootPart.CFrame + Vector3.new(0, Depth + FLOOR_LIFT_CLEARANCE, 0)
            end)

            if not Ok then
                return false
            end

            S.FloorLifts = (S.FloorLifts or 0) + 1
            Humanoid:Move(Vector3.zero)
            ResetWalk()
            return true
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
                    --// Not moving *and* under the floor is not a step to hop:
                    --// the body is inside the ground and has to be lifted out.
                    --// Read only from a body that is already not moving, so a
                    --// stair edge or a slope (which never stops it) is never
                    --// taken for burial.
                    local Depth = GetFloorOverlap(RootPart)

                    if not (Depth and Depth >= FLOOR_BURIED and LiftFromFloor(Humanoid, RootPart, Depth)) then
                        AICCombatUtils.DoJump()
                    end
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

            --// A loaded profile or a commit changes the hiding spots with it.
            if AICUI.RefreshBossEvadeList then
                AICUI.RefreshBossEvadeList()
            end
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
            if UIRef.BossBoundsLabel then
                local Points = Stop.Bounds or {}

                if #Points >= AICConfig.MAX_BOSS_BOUNDS then
                    local Rect = GetBoundsRect(Stop)

                    UIRef.BossBoundsLabel:Set(string.format(
                        "FIGHT BOUNDS:  SET  %.0f x %.0f STUDS",
                        Rect and (Rect.MaxX - Rect.MinX) or 0,
                        Rect and (Rect.MaxZ - Rect.MinZ) or 0
                    ))
                elseif #Points > 0 then
                    UIRef.BossBoundsLabel:Set(string.format(
                        "FIGHT BOUNDS:  CORNER %d/%d  (CLICK THE NEXT CORNER)",
                        #Points,
                        AICConfig.MAX_BOSS_BOUNDS
                    ))
                else
                    UIRef.BossBoundsLabel:Set("FIGHT BOUNDS:  NONE  (DODGE RUNS FREELY)")
                end
            end

            RefreshBoundsVisual(Stop)
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
            if UIRef.BossDeathFarmToggle then
                UIRef.BossDeathFarmToggle:Set(CONFIG.BOSS_DEATH_FARM == true, true)
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
            --// The hiding-spot list rides on BOSS_EVADE.Spots. The normalizer
            --// below only keeps the fields it knows, so the list is held
            --// aside and put back if it was dropped.
            local Before = Runtime:GetPlaceConfig()
            local KeptSpots = type(Before) == "table"
                and type(Before.BOSS_EVADE) == "table"
                and Before.BOSS_EVADE.Spots
                or nil
            local Normalized = AICConfig.NormalizePlaceConfig(Before)

            if KeptSpots and type(Normalized) == "table" then
                if type(Normalized.BOSS_EVADE) ~= "table" then
                    Normalized.BOSS_EVADE = AICConfig.NormalizeBossEvade(nil)
                end

                if Normalized.BOSS_EVADE.Spots == nil then
                    Normalized.BOSS_EVADE.Spots = KeptSpots
                end
            end

            Runtime:SetPlaceConfig(Normalized)
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

        --// The game's block button, held rather than pressed: Begin on the way
        --// into a wait, End on the way out, so the sword is up for as long as
        --// the stop is waited at and back down when the fight (or the next
        --// step) starts. The name follows the game's own bindings
        --// (AttackButton, EquipButton, InteractButton). A game without the
        --// binding answers with an error through pcall and the wait carries on
        --// without a guard, the same way a missing prompt binding is survived.
        local function SetBlocking(On)
            On = On == true

            if S.Blocking == On then
                return
            end

            local GetInput = Runtime.GetInputBindableFunction
            local InputBindableFunction = GetInput and GetInput(Runtime)

            if not InputBindableFunction then
                return
            end

            S.Blocking = On

            pcall(function()
                InputBindableFunction:Invoke(
                    "BlockButton",
                    On and Enum.UserInputState.Begin or Enum.UserInputState.End
                )
            end)
        end

        --// Defined with the rest of the hold, further down: a stop of the route
        --// has to be able to end one that is running.
        local EndEvade

        local function StopRoute(StatusText)
            if S.Evading and EndEvade then
                --// Never restarts: the caller is switching the route off.
                EndEvade(os.clock(), false)
            end

            S.Phase = "Idle"
            S.ReturnKill = false
            S.ReturnMissAt = nil
            S.SeenTarget = false
            S.LastTarget = nil
            S.TargetSeenAt = nil
            ClearKillClock()
            S.WaitUntil = nil
            S.SpotWaitUntil = nil
            SetBlocking(false)
            S.WalkStart = nil
            --// Nothing carries a death's skip into a later run, and a death
            --// from while the route was off is not the next run's.
            S.SkipSpotWait = false
            S.SkipSpotWaitNext = false
            S.TeleportHold = nil
            S.TeleportAt = nil
            S.TeleportFrom = nil
            S.TeleportLanded = false
            S.PromptCheckAt = nil
            S.PromptTargetPosition = nil
            S.FloorLifts = 0
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
            ClearKillClock()
            S.Teleported = false
            S.PathIndex = 1
            S.Path = Stop.Path and table.clone(Stop.Path) or {}
            S.InteractAt = nil
            S.TeleportFrom = nil
            S.TeleportAt = nil
            S.Teleports = 0
            S.TeleportLanded = false
            S.TeleportHold = nil
            S.PromptUsed = false
            S.PromptCheckAt = nil
            S.PromptTargetPosition = nil
            S.FloorLifts = 0
            S.SpotWaitUntil = nil
            SetBlocking(false)
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
            ClearKillClock()
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

            --// Already recovering from it, or nothing left to walk again. A
            --// hold of Pause For Strangers is parked on purpose and its reset
            --// has already been counted on its own: it is not a death to walk
            --// back from.
            if S.Phase == "Recover" or S.Phase == "Done" or S.Phase == "Evade"
                or not CurrentStop()
            then
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

        --// The name a stop's list is matched against. Config.Entity is what the
        --// picker saved, but a mob whose config has not replicated yet - or a
        --// variant without one - still has a model name. Reading nil there
        --// dropped a living boss out of the scan, and four seconds later the
        --// route called it dead.
        local function MobName(Mob)
            return AICCombat.GetTargetEntityName(Mob) or (Mob and Mob.Name) or nil
        end

        --// Every mob the game lists, one folder deep. The Mobs folder is flat
        --// today, but a nested "Bosses" folder was invisible to the old scan,
        --// which read exactly like a dead boss.
        local function EachMob(Fn)
            local MobFolder = workspace:FindFirstChild("Mobs")

            if not MobFolder then
                return
            end

            for _, Node in ipairs(MobFolder:GetChildren()) do
                if Node:IsA("Model") then
                    Fn(Node)
                elseif Node:IsA("Folder") then
                    for _, Nested in ipairs(Node:GetChildren()) do
                        if Nested:IsA("Model") then
                            Fn(Nested)
                        end
                    end
                end
            end
        end

        --// A living mob matching the stop, anywhere in the Mobs folder. The
        --// scan's radius is about what is worth engaging, not about whether the
        --// boss still exists, and the kill tests below need the second answer: a
        --// boss that stepped out of the circle, or was dragged out of it, used
        --// to count as dead while it was standing right there.
        local function FindLivingTarget(Stop)
            local Found = nil

            EachMob(function(Mob)
                if Found then
                    return
                end

                local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")

                if MobHumanoid and (tonumber(MobHumanoid.Health) or 0) > 0 then
                    local Name = MobName(Mob)

                    if Name and (#Stop.Targets == 0 or table.find(Stop.Targets, Name)) then
                        Found = Mob
                    end
                end
            end)

            return Found
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

                EachMob(function(Mob)
                    local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                    local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                    if MobHumanoid and MobRoot and MobHumanoid.Health > 0 then
                        local Distance = (MobRoot.Position - Stop.Position).Magnitude

                        if Distance <= Stop.Radius and Distance < BestDistance then
                            local Name = MobName(Mob)
                            local Match = Name ~= nil
                                and (#Stop.Targets == 0 or table.find(Stop.Targets, Name) ~= nil)

                            if Match then
                                Best, BestDistance = Mob, Distance
                            end
                        end
                    end
                end)

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
            local Radius = tonumber(Stop.Radius) or 0
            local Found = nil

            EachMob(function(Mob)
                if Found then
                    return
                end

                local MobHumanoid = Mob:FindFirstChildOfClass("Humanoid")
                local MobRoot = Mob:FindFirstChild("HumanoidRootPart")

                if MobHumanoid and MobRoot and MobHumanoid.Health <= 0
                    and AICCombatUtils.GetHorizontalDistance(Stop.Position, MobRoot.Position) <= Radius
                then
                    local Name = MobName(Mob)

                    if Name and (#Stop.Targets == 0 or table.find(Stop.Targets, Name)) then
                        Found = Mob
                    end
                end
            end)

            return Found
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
        local function PickDodgePoint(RootPart, TargetRoot, Distance, Stop)
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
                --// A point outside the stop's fight box is a wall the dodge
                --// must not run through, however clear the path looks.
                local Outside = not InsideBounds(Stop, Candidate, BOUNDS_INSET)

                if not Hole and not Outside and AICCombatUtils.IsPathClear(Candidate) then
                    return Candidate
                end

                if not Hole and not Outside and not Fallback then
                    Fallback = Candidate
                end
            end

            --// Every heading left the box: keep the step on the wall line
            --// instead of running out of the room.
            return ClampToBounds(Stop, Fallback or OnRing(Away), BOUNDS_INSET)
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
        --// The range a mob starts chasing from, straight off its own config:
        --// Mobs["Mob..."].Config.DetectionRange. Every mob carries it, and the
        --// number differs per boss, so a fixed ring was either short (the mob
        --// followed the character to it) or long (the hold ran for nothing).
        --// A value object is what the game uses; an attribute is accepted too,
        --// so a variant that stores it that way still gets its own number.
        local function MobDetectionRange(Mob)
            local Config = Mob and Mob:FindFirstChild("Config")

            if not Config then
                return nil
            end

            local Value = Config:FindFirstChild("DetectionRange")
            local Range = (Value and tonumber(Value.Value)) or tonumber(Config:GetAttribute("DetectionRange"))

            if Range and Range > 0 then
                return Range
            end

            return nil
        end

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

            --// Flee the mob that is actually chasing, not a guessed ring: its
            --// DetectionRange is where it gives up. The cap keeps a
            --// long-sighted boss from turning the hold into a lap of the map.
            local Detected = MobDetectionRange(MobRoot.Parent)

            if Detected then
                Distance = math.min(math.max(Distance, Detected + FLEE_RANGE_MARGIN), FLEE_RING_MAX)
            end

            if Stop and tonumber(Stop.DodgeDistance) then
                Distance = math.max(Distance, tonumber(Stop.DodgeDistance))
            end

            local Point = PickDodgePoint(RootPart, MobRoot, Distance, Stop)
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

            --// The box is the wall: knocked outside it, walk back in before
            --// picking a ring point, or the next step can be through the wall.
            if not InsideBounds(Stop, RootPart.Position, 0) then
                local Back = ClampToBounds(Stop, RootPart.Position, BOUNDS_INSET)

                if (Back - RootPart.Position).Magnitude > 0.5 then
                    Humanoid:MoveTo(Back)
                    SetStatus(string.format("STOP %d/%d  DODGE", S.Index, #GetStops()))
                    return true
                end
            end

            --// A target saved before the box existed can sit outside it.
            if S.DodgeTarget then
                S.DodgeTarget = ClampToBounds(Stop, S.DodgeTarget, BOUNDS_INSET)
            end

            if FromBoss < Distance - DODGE_HOLD_SLACK then
                local Stale = not S.DodgeTarget
                    or AICCombatUtils.GetHorizontalDistance(S.DodgeTarget, TargetRoot.Position) > 6

                if Stale then
                    --// The speed to put back is the first one seen, never the
                    --// sprint a later frame is already running at.
                    S.DodgeFromSpeed = S.DodgeFromSpeed or tonumber(Humanoid.WalkSpeed) or 0
                    S.DodgeTarget = PickDodgePoint(RootPart, TargetRoot, Distance, Stop)
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
                --// The drink is a remote, so the sword is never put away: the
                --// fight loses this frame to the drink and the next one to a
                --// swing, not two frames to a sheathe and a draw.
                return
            end

            --// Standing on the boss (a jump onto it, or its body walking under
            --// the character): every swing from up there is at air over its
            --// head. Step off the body first; the walk back in puts the
            --// character alongside it at the standoff again.
            if AICCombatUtils.IsStandingOnTarget(TargetRoot) then
                local StepOff = AICCombatUtils.GetStepOffPosition(TargetRoot, FIGHT_STANDOFF + 2)

                if StepOff then
                    Humanoid.AutoRotate = false
                    Humanoid:MoveTo(StepOff)
                    AICCombat.FaceCombatTarget(Target)
                    return
                end
            end

            local Offset = TargetRoot.Position - RootPart.Position
            local Distance = AICCombat.GetCombatDistance(Target, Offset)

            if Distance > FIGHT_STANDOFF then
                local Flat = Vector3.new(Offset.X, 0, Offset.Z)
                local Direction = Flat.Magnitude > 0.01 and Flat.Unit or Vector3.xAxis
                --// Stop just short of the body, not inside it.
                local Destination = TargetRoot.Position - Direction * math.max(FIGHT_STANDOFF - 1, 2)

                --// Not right against the body: a hop there lands on the boss,
                --// and the fight carries on from its head.
                if not AICCombatUtils.IsPressedAgainstBody(TargetRoot) then
                    AICCombatUtils.DoJumpIfObstacle(Destination)
                end

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

        --// A landing that put the body inside a floor. Lifted out and looked at
        --// again on the next frame: a landing point half a stud under the ground
        --// leaves the character standing in the floor, unable to walk out, and
        --// nothing on the way notices until the stop is given up on.
        local function FixLandedFloor(Humanoid, RootPart)
            local Depth = GetFloorOverlap(RootPart)

            if Depth and Depth >= FLOOR_BURIED then
                return LiftFromFloor(Humanoid, RootPart, Depth)
            end

            return false
        end

        --// The waypoint teleport in flight. True means the frame is spoken for:
        --// the landing is still coming, or it has just been read and the walk
        --// (or the one retry) is set up. The same waypoint is never sent to
        --// twice over a slow landing - only a request that moved the body
        --// nowhere at all for TELEPORT_LAND_WINDOW is a dropped one.
        local function WatchTeleportLanding(Stop, Humanoid, RootPart, Now)
            local From = S.TeleportFrom
            local At = S.TeleportAt or Now

            if (RootPart.Position - From).Magnitude >= TELEPORT_LAND_DISTANCE then
                S.TeleportFrom = nil
                S.TeleportAt = nil
                S.TeleportLanded = true
                S.WaitUntil = nil
                ResetWalk()
                S.BestDistance = nil
                S.LastProgressAt = Now
                S.WalkStart = Now

                --// The landing point can sit inside the ground (a waypoint
                --// saved under a floor plane): lifted out before the walk, so
                --// the body is not left standing in it.
                if FixLandedFloor(Humanoid, RootPart) then
                    SetStatus(string.format(
                        "STOP %d/%d  LIFTED OUT OF FLOOR",
                        S.Index,
                        #GetStops()
                    ))
                    return true
                end

                SetStatus(string.format(
                    "STOP %d/%d  TELEPORT LANDED",
                    S.Index,
                    #GetStops()
                ))
                return true
            end

            if Now - At < TELEPORT_LAND_WINDOW then
                Humanoid:Move(Vector3.zero)
                SetStatus(string.format(
                    "STOP %d/%d  TELEPORT WP%d",
                    S.Index,
                    #GetStops(),
                    Stop.Waypoint or 0
                ))
                return true
            end

            --// Not a stud of movement in the whole window: the game dropped the
            --// request. Asked one more time, then walked.
            S.TeleportFrom = nil
            S.TeleportAt = nil

            local ToStop = AICCombatUtils.GetHorizontalDistance(Stop.Position, RootPart.Position)

            --// A landing already happened on this visit, so a send that moved
            --// nothing is the game's answer, not a dropped request: only a
            --// visit where no send has ever moved the body re-asks.
            if ToStop > TELEPORT_RETRY_DISTANCE
                and not S.PromptUsed
                and not S.TeleportLanded
                and (S.Teleports or 0) < TELEPORT_RETRIES
            then
                S.Teleports = (S.Teleports or 0) + 1
                S.Teleported = false
                S.TeleportHold = Now + TELEPORT_RETRY_DELAY
                --// The distance is in the message on purpose: "did not land"
                --// with no number is what made a landing that had worked look
                --// like a failure, with no way to tell afterwards what the
                --// route had measured.
                Say("Boss Route", string.format(
                    "Waypoint teleport to stop #%d moved %.1f studs; asking once more (%d/%d)",
                    S.Index,
                    (RootPart.Position - From).Magnitude,
                    S.Teleports,
                    TELEPORT_RETRIES
                ), 4)
                return true
            end

            Say("Boss Route", string.format(
                "Waypoint teleport to stop #%d moved %.1f studs; walking the rest",
                S.Index,
                (RootPart.Position - From).Magnitude
            ), 4)
            S.BestDistance = nil
            S.LastProgressAt = Now
            S.WalkStart = Now
            SetStatus(string.format("STOP %d/%d  WALKING", S.Index, #GetStops()))
            return true
        end

        --// What the prompt teleport actually did. The request goes out and the
        --// game puts the character where it likes: a landing point inside a floor
        --// left the body standing in the ground, and a send the game dropped left
        --// it far from the prompt with nothing checking - the walk carried on, or
        --// the no-progress timeout skipped the stop as unreachable. Checked once,
        --// PROMPT_WAIT after the send; the body is put back on the prompt and the
        --// check repeated when the landing was inside the floor or through it.
        local function CheckPromptLanding(Humanoid, RootPart, Now)
            local Target = S.PromptTargetPosition

            S.PromptCheckAt = nil

            if not Target then
                return false
            end

            local Flat = AICCombatUtils.GetHorizontalDistance(Target, RootPart.Position)
            local Depth = GetFloorOverlap(RootPart)
            local Buried = Depth and Depth >= FLOOR_BURIED
            local Fell = RootPart.Position.Y < Target.Y - PROMPT_FALL_DEPTH

            if Flat <= PROMPT_ARRIVAL and not Buried and not Fell then
                return false
            end

            --// Inside the ground, or through it: put the body back where the
            --// prompt meant to land, then look again once the drop settles.
            if Buried or Fell then
                if (S.FloorLifts or 0) < FLOOR_LIFTS then
                    local Ok = pcall(function()
                        RootPart.CFrame = CFrame.new(Target + Vector3.new(0, FLOOR_LIFT_CLEARANCE, 0))
                    end)

                    if Ok then
                        S.FloorLifts = (S.FloorLifts or 0) + 1
                        S.PromptCheckAt = Now + PROMPT_RECHECK
                        S.WaitUntil = nil
                        Humanoid:Move(Vector3.zero)
                        ResetWalk()
                        SetStatus(string.format(
                            "STOP %d/%d  PROMPT LANDING IN FLOOR",
                            S.Index,
                            #GetStops()
                        ))
                        return true
                    end
                end
            end

            --// Not on the prompt: the send did not take this visit. Nothing is
            --// pressed on it again, and the stop is walked from here.
            S.Teleported = true
            S.BestDistance = nil
            S.LastProgressAt = Now
            S.WalkStart = Now
            Say("Boss Route", string.format(
                "Prompt teleport to stop #%d landed %.0f studs away; walking the rest",
                S.Index,
                Flat
            ), 4)
            SetStatus(string.format(
                "STOP %d/%d  PROMPT MISSED  WALKING",
                S.Index,
                #GetStops()
            ))
            return true
        end

        --// How long a spot with no boss has to stay empty before the walk back
        --// calls it a kill: one scan miss can be a model swap, two cannot.
        --// A walk back with nothing in the scan radius counts as "it died while
        --// away" after this. One second was the old value, and it is shorter
        --// than the scan's own cache and shorter than a boss takes to walk back
        --// into range: a live boss was being credited as a kill on the walk
        --// back, reset over, and the route moved on. A living match anywhere in
        --// the Mobs folder now vetoes the kill outright, so this only has to
        --// cover the scan settling.
        local RETURN_KILL_MISS_SECONDS = 3

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

            --// Nothing in the radius is not the same as nothing alive: a boss
            --// that followed the character away from the stop, or simply walked
            --// out of the circle, is still the boss.
            if FindLivingTarget(Stop) then
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
            --// This kill gets its own clock: the tag wait and the pause run
            --// from here, not from the kill that ended in the death.
            ClearKillClock()
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

            --// A waypoint teleport in flight is watched first, so no other
            --// send can go out while it is still landing.
            if S.TeleportFrom then
                if WatchTeleportLanding(Stop, Humanoid, RootPart, Now) then
                    return
                end
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
                        --// Read back once the landing has had PROMPT_WAIT,
                        --// instead of trusting the send: the prompt can drop
                        --// the body inside a floor or put it back where it
                        --// stood, and neither used to be noticed.
                        S.PromptCheckAt = Now + PROMPT_WAIT
                        S.PromptTargetPosition = PromptPosition
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
            --// watch the body for the landing (see WatchTeleportLanding, which
            --// ends the watch the frame the character moves).
            if not S.Teleported and (Stop.Waypoint or 0) > 0 then
                S.Teleported = true
                S.TeleportFrom = RootPart.Position
                S.TeleportAt = Now
                --// A waypoint can land on a prompt, and the walk after it can
                --// pass the same one again. Off for the visit, set before the
                --// request goes out so no press can beat the mute.
                S.InteractSuppressed = true

                if Runtime.MuteInteract then
                    Runtime:MuteInteract(PROMPT_INTERACT_MUTE)
                end

                if TeleportToWaypoint(Stop.Waypoint) then
                    SetStatus(string.format("STOP %d/%d  TELEPORT WP%d", S.Index, #GetStops(), Stop.Waypoint))
                    return
                end

                --// Nothing was sent, so there is no landing to watch.
                S.TeleportFrom = nil
                S.TeleportAt = nil
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

            --// What the prompt teleport did, read after its landing window.
            --// The waypoint teleport is watched at the top of this step.
            if S.PromptCheckAt then
                --// Held, not walked: a landing lifted out of a floor is looked
                --// at again once it has dropped back onto the surface, and the
                --// walk starting under it would move a body still falling.
                if Now < S.PromptCheckAt then
                    Humanoid:Move(Vector3.zero)
                    return
                end

                if CheckPromptLanding(Humanoid, RootPart, Now) then
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
                        --// The wait is for the spawn, not for the character to
                        --// stand still and be killed in: the boss's dodge, the
                        --// heal and the guard all still run, only the fight
                        --// itself is held back until the wait is over.
                        --//
                        --// No evade code of its own: a boss that spawns early
                        --// and opens with a skill is dodged with the fight's
                        --// own DodgeStep, armed by the same IsSkillShowing /
                        --// IsHealthBurst checks and the same constants, so the
                        --// ring, the sprint and the release are the ones the
                        --// fight has already been tuned to.
                        local WaitTarget = FindTarget(Stop, Now)

                        if WaitTarget then
                            local WaitDodge = Stop.Dodge ~= false
                                and WaitTarget:FindFirstChild("HumanoidRootPart") ~= nil
                            local WaitCasting = WaitDodge and IsSkillShowing(WaitTarget, Now) == true

                            --// Only a cast the boss is actually showing arms the
                            --// dodge while waiting. A health burst used to arm it
                            --// as well, and during a wait that burst is just a mob
                            --// landing on the guard: eight seconds of stepping out
                            --// of nothing, which is the wait fighting itself
                            --// instead of blocking. The burst stays the fight's
                            --// own backup, where it belongs.
                            --// The rising edge is the cast starting, the same
                            --// edge the fight uses. Arming on every frame the
                            --// effect stayed up cleared S.DodgeTarget each
                            --// time, so DodgeStep's staleness test was true
                            --// every frame and PickDodgePoint picked a fresh
                            --// candidate each frame: as IsPathClear flipped
                            --// between neighbouring candidates the character
                            --// was sent back and forth between them.
                            local WaitOpened = WaitCasting and not S.SkillWas
                            S.SkillWas = WaitCasting

                            if WaitOpened then
                                local WaitRunning = (S.DodgeMaxUntil or 0) > Now

                                S.DodgeMinUntil = Now + DODGE_MIN_TIME
                                S.DodgeMaxUntil = Now + DODGE_MAX_TIME
                                S.SkillSeenAt = Now
                                S.SkillActive = true

                                --// A dodge already running keeps its point: a
                                --// fresh one would be measured from a
                                --// character already sprinting.
                                if not WaitRunning then
                                    S.DodgeTarget = nil
                                end
                            end

                            if DodgeStep(WaitTarget, Humanoid, RootPart, Now, Stop) then
                                --// DodgeStep writes its own STOP x/y DODGE line. The
                                --// guard stays up through it: evading and blocking
                                --// are one stance here, not a choice between them.
                                SetBlocking(true)
                                --// Own the frame. A bare return made BossStep
                                --// return nil, so Auto Farm's own Update kept
                                --// moving the character on these same frames -
                                --// the dodge went one way and Auto Farm pulled it
                                --// back, which is the back-and-forth.
                                return true
                            end
                        else
                            --// No boss to read a cast from. Forget the last one,
                            --// or a respawn's opening skill looks like a cast
                            --// that was already handled and is not dodged.
                            S.SkillWas = false
                        end

                        local WaitHealPercent = math.clamp(
                            tonumber(CONFIG.AUTO_HEAL_HEALTH_PERCENT) or 65,
                            30,
                            80
                        )
                        local WaitMaxHealth = tonumber(Humanoid.MaxHealth) or 0
                        local WaitHeal = WaitMaxHealth > 0
                            and (tonumber(Humanoid.Health) or 0) <= WaitMaxHealth * (WaitHealPercent / 100)
                            and AICFeature.TryHeal
                            and AICFeature.TryHeal(Now)

                        --// Standing at the stop either way: the sword stays
                        --// out and the guard goes up, and a remote drink on a
                        --// low bar is the only thing that happens besides it.
                        Humanoid:Move(Vector3.zero)
                        RequireWeapon(Now)
                        SetBlocking(true)

                        --// Only says BLOCK when the binding actually took it: a
                        --// game that names its block differently shows HEAL
                        --// alone rather than a guard that is not up.
                        local WaitMarker = S.Blocking and "  BLOCK" or ""

                        if WaitHeal then
                            WaitMarker = S.Blocking and "  HEAL  BLOCK" or "  HEAL"
                        end

                        SetStatus(string.format(
                            "STOP %d/%d  WAIT %ds  %s%s",
                            S.Index,
                            #GetStops(),
                            math.ceil(S.SpotWaitUntil - Now),
                            Stop.Label,
                            WaitMarker
                        ))
                        --// Same reason as the dodge frame: the wait is what
                        --// stands the character here, so Auto Farm must not
                        --// walk it somewhere else on the same frame.
                        return true
                    end

                    S.SpotWaitUntil = nil
                    --// The wait is over (or was skipped): the guard comes down
                    --// for the fight, and a dodge the wait armed ends with it.
                    --// DODGE_MAX_TIME is eight seconds and TARGET_KEEP_TIME is
                    --// four, so a dodge left running walked the character (and
                    --// the boss chasing it) out of the stop's scan radius for
                    --// long enough that the fight lost the scan and called a
                    --// live boss dead. The fight arms its own dodge on the
                    --// frame a skill actually shows.
                    SetBlocking(false)
                    EndDodge(Humanoid)
                    S.SkillSeenAt = nil
                    S.SkillActive = false
                    --// The fight reads casts on a rising edge too. Left true, a
                    --// skill still showing when the wait ends would look like
                    --// a cast already handled, and the fight would walk in.
                    S.SkillWas = false
                    S.DodgeTarget = nil
                    S.HpAt = nil
                    S.HpBase = nil

                    --// On the spot: fight straight away. The scan is forced,
                    --// so a boss that dies within the first eighth of a second
                    --// is still seen and counted as this stop's kill instead
                    --// of being walked past.
                    S.Phase = "Fight"
                    S.FightStart = Now
                    S.SeenTarget = false
                    S.LastTarget = nil
                    S.TargetSeenAt = nil
                    ClearKillClock()
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
                ClearKillClock()

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
                local LastAlive = IsMobAlive(S.LastTarget)
                --// A body the game took away stops existing for us; a boss that
                --// is merely outside the scan radius is still in the workspace.
                local StillHere = LastAlive
                    and S.LastTarget ~= nil
                    and S.LastTarget:IsDescendantOf(workspace)

                --// Only a stop whose list has names can be held open this way.
                --// A stop with no names takes anything in its radius, and mobs
                --// die on the way through a fight all the time: an ordinary mob
                --// still standing there must never send the route walking back
                --// for it. For an unnamed stop the old lapse stands unchanged.
                local NamedTarget = #Stop.Targets > 0 and IsWantedTarget(S.LastTarget, Stop)

                if LastAlive and Now - (S.TargetSeenAt or 0) <= TARGET_KEEP_TIME then
                    if not IsWantedTarget(S.LastTarget, Stop) then
                        Advance(Now)
                    else
                        SetStatus(string.format("STOP %d/%d  FIGHT  %s", S.Index, #GetStops(), Stop.Label))
                    end

                    return
                end

                --// Alive, in the workspace, just not where the scan looks any
                --// more (it chased something, or a dodge pulled the character
                --// away and the boss followed). That is not a kill: resetting
                --// over it took the EXP the reset was there to protect. Walk
                --// the stop again, and let the walk's own timeouts move the
                --// route on if it cannot be reached.
                if StillHere and NamedTarget then
                    Say("Boss Route", string.format(
                        "Boss still alive at stop #%d; walking back",
                        S.Index
                    ), 4)
                    S.SkipSpotWaitNext = true
                    BeginStop(Now)
                    return
                end

                S.KillAt = S.KillAt or Now

                --// The pause belongs to the reset; with Reset After Kill off
                --// there is nothing to wait for and the route moves on after
                --// the grace. A reset that costs no EXP is not held at all, so
                --// the row's Reset (s) only shows up when there is something to
                --// lose - unless Always Wait After Kill is on, which holds every
                --// reset for that number whatever the EXP would cost.
                local Hold = Stop.ResetAfterKill and GetResetHold(Stop) or 0
                --// A reset with nothing to lose is not held at all: one scan
                --// tick after the kill, not the two-second grace the held
                --// path uses to see whether a second mob of the stop is still
                --// standing up. Death Farm takes even that tick off it.
                local Grace = Hold > 0 and KILL_GRACE
                    or (CONFIG.BOSS_DEATH_FARM == true and 0 or FREE_RESET_GRACE)

                --// The pause starts when the game has finished with the kill,
                --// not when the scan stopped finding the boss: the tag the game
                --// keeps in PlayerDamageTags comes down once the kill is settled,
                --// so counting from the scan could reset before the last hit was
                --// awarded. A stop that only walks on is not spending the kill,
                --// so it is not held for the tag.
                if not S.HoldFrom then
                    if Stop.ResetAfterKill and GetDamageTag() then
                        --// A reset that waits for nothing waits for the tag
                        --// only TAG_WAIT_FREE, and not at all under Death
                        --// Farm: the tag is the game's "still settling" mark,
                        --// and on a zero-delay stop it was the whole delay.
                        local TagMax = TAG_WAIT_MAX

                        if Hold <= 0 then
                            TagMax = CONFIG.BOSS_DEATH_FARM == true and 0 or TAG_WAIT_FREE
                        end

                        S.TagWaitAt = S.TagWaitAt or Now

                        if Now - S.TagWaitAt < TagMax then
                            --// The tag is the game still settling the kill, and
                            --// the character stands in the open for it: the same
                            --// health decision and the same run from a mob the
                            --// reset hold uses, so a slow tag is not a free hit
                            --// for whatever is left at the stop. Losing EXP to
                            --// that is worse than the reset being waited for.
                            local TagHealPercent = math.clamp(
                                tonumber(CONFIG.AUTO_HEAL_HEALTH_PERCENT) or 65,
                                30,
                                80
                            )
                            local TagMaxHealth = tonumber(Humanoid.MaxHealth) or 0
                            local TagMarker = ""

                            if TagMaxHealth > 0
                                and (tonumber(Humanoid.Health) or 0) <= TagMaxHealth * (TagHealPercent / 100)
                                and AICFeature.TryHeal
                                and AICFeature.TryHeal(Now)
                            then
                                --// A remote drink, so the sword stays out.
                                Humanoid:Move(Vector3.zero)
                                TagMarker = "  HEAL"
                            elseif FleeStep(Humanoid, RootPart, Stop) then
                                TagMarker = "  RUNNING"
                            else
                                Humanoid:Move(Vector3.zero)
                            end

                            SetStatus(string.format(
                                "STOP %d/%d  WAITING  DAMAGE TAG%s",
                                S.Index,
                                #GetStops(),
                                TagMarker
                            ))
                            return
                        end
                    end

                    --// The tag is down: put back the speed a run borrowed before
                    --// the hold or the reset below takes over.
                    StopFlee(Humanoid)
                    S.HoldFrom = Now
                    S.TagWaitAt = nil
                end

                local Left = math.max(Grace, Hold) - (Now - S.HoldFrom)

                if Left > 0.05 then
                    if Hold > 0 then
                        local Loss = GetResetCost()
                        local Fleeing = FleeStep(Humanoid, RootPart, Stop)

                        --// With nothing at risk the hold is Always Wait After
                        --// Kill holding a reset the EXP check called free, so
                        --// say that rather than "LOSE 0 EXP".
                        local Risk = Loss == nil and "COST UNKNOWN"
                            or (Loss > 0 and string.format("LOSE %d EXP", math.floor(Loss + 0.5))
                                or (CONFIG.BOSS_RESET_ALWAYS_WAIT == true and "ALWAYS WAIT"
                                    or "NO EXP AT RISK"))

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

            --// A corpse only counts when nothing matching the stop is standing:
            --// a body left from an earlier spawn must never skip a boss that has
            --// already respawned at the spot.
            if Dead and not S.SeenTarget and not FindLivingTarget(Stop) then
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

        ------------------------------------------------------------------------
        --// Pause For Strangers (Evasion section)
        --//
        --// A stranger on the server stops the run instead of being blocked or
        --// hopped from: the character resets at once, goes to the spot saved in
        --// the section (a prompt or one of the game's waypoints), and stands
        --// there while they are given a random 2-3 minutes to leave. If they go
        --// the route starts again at stop #1; if they stay the game is closed
        --// through Auto Block's leave, so the client is out either way.
        ------------------------------------------------------------------------

        --// Where the hold stands, saved on the place config (BOSS_EVADE) beside
        --// the route. Made up when a save has none, so the section always has
        --// something to write to.
        local function GetEvadeConfig()
            local PlaceConfig = Runtime:GetPlaceConfig()

            if not PlaceConfig then
                return { Waypoint = 0, Prompt = false, Random = false, PromptName = "", Spots = {} }
            end

            if type(PlaceConfig.BOSS_EVADE) ~= "table" then
                PlaceConfig.BOSS_EVADE = AICConfig.NormalizeBossEvade(nil)
            end

            return PlaceConfig.BOSS_EVADE
        end

        --// The hiding spots: the places the hold may go to, picked from at
        --// random by the hold. Saved as BOSS_EVADE.Spots, plain tables with
        --// plain numbers so any saver can write them:
        --//   { Kind = "Waypoint", Waypoint = 7 }
        --//   { Kind = "Prompt", Name = "Door", X = 1, Y = 2, Z = 3 }
        local MAX_EVADE_SPOTS = 20

        --// Whatever was saved, made into a list the hold can trust. Spots
        --// that are not a waypoint in range or a real position are dropped.
        local function CleanSpots(Raw)
            local Clean = {}

            local function IsFiniteNumber(Value)
                return type(Value) == "number" and Value == Value and math.abs(Value) < math.huge
            end

            if type(Raw) ~= "table" then
                return Clean
            end

            for _, Spot in ipairs(Raw) do
                if #Clean >= MAX_EVADE_SPOTS then
                    break
                end

                if type(Spot) == "table" then
                    if Spot.Kind == "Waypoint" then
                        local Number = math.floor(tonumber(Spot.Waypoint) or 0)

                        if Number >= 1 and Number <= AICConfig.MAX_BOSS_WAYPOINT then
                            table.insert(Clean, { Kind = "Waypoint", Waypoint = Number })
                        end
                    elseif Spot.Kind == "Prompt" then
                        local X, Y, Z = tonumber(Spot.X), tonumber(Spot.Y), tonumber(Spot.Z)

                        if IsFiniteNumber(X) and IsFiniteNumber(Y) and IsFiniteNumber(Z) then
                            table.insert(Clean, {
                                Kind = "Prompt",
                                Name = string.sub(tostring(Spot.Name or ""), 1, 64),
                                X = X,
                                Y = Y,
                                Z = Z,
                            })
                        end
                    end
                end
            end

            return Clean
        end

        --// The list on the config. A save from before the list existed has
        --// none: its single waypoint or prompt becomes the first spot, once.
        local function GetEvadeSpots()
            local Evade = GetEvadeConfig()

            if type(Evade.Spots) ~= "table" then
                Evade.Spots = {}

                if Evade.Prompt and Evade.PromptPosition then
                    table.insert(Evade.Spots, {
                        Kind = "Prompt",
                        Name = tostring(Evade.PromptName or ""),
                        X = Evade.PromptPosition.X,
                        Y = Evade.PromptPosition.Y,
                        Z = Evade.PromptPosition.Z,
                    })
                elseif (tonumber(Evade.Waypoint) or 0) > 0 then
                    table.insert(Evade.Spots, { Kind = "Waypoint", Waypoint = Evade.Waypoint })
                end
            end

            --// Cleaned in place. Every read used to build a new list, so a
            --// caller that held the one it got back (Remove, MoveUp,
            --// MoveDown) was editing a table the next read had already
            --// replaced: the X took the row off the screen and left the spot
            --// on the list, and a move never reached the config at all.
            local Clean = CleanSpots(Evade.Spots)
            local Kept = Evade.Spots

            table.clear(Kept)

            for _, Spot in ipairs(Clean) do
                table.insert(Kept, Spot)
            end

            return Kept
        end

        --// A spot's identity, so a hold can avoid the one the hold before it
        --// used even after the list was edited in between.
        local function SpotKey(Spot)
            if Spot.Kind == "Prompt" then
                return string.format("P%.0f,%.0f,%.0f", Spot.X, Spot.Y, Spot.Z)
            end

            return "W" .. tostring(Spot.Waypoint)
        end

        --// Whether a player is a stranger to the hold: yourself and anyone on
        --// the Block Whitelist are not. One list decides who is safe for Auto
        --// Block and for here, so the two can never disagree about it.

        ------------------------------------------------------------------------
        --// Pause For Strangers (the hold itself)
        --//
        --// The hold lives in Features/BossNavigator_Evade.lua. The saved
        --// hiding-spot shape above stays in this file because the route editor
        --// reads and saves it as well; these forwarders are how the route and
        --// its UI reach the hold now.
        ------------------------------------------------------------------------

        --// EndEvade is declared beside StopRoute; this assigns it, so the
        --// route's own stop and a profile load both end a hold through the
        --// module.
        EndEvade = function(Now, Restart)
            if AICFeature.BossEvadeReady == true and type(AICFeature.BossEvadeEnd) == "function" then
                AICFeature.BossEvadeEnd(Now, Restart)
            end
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
        Context.Lifetime.OnEnd(ClearBoundsVisual)

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        UIRef.BossSection = UIRef.BossTab:AddSection{ Title = "Route Controls", Side = "Left" }
        UIRef.BossStopsSection = UIRef.BossTab:AddSection{ Title = "Boss Stops", Side = "Left" }
        UIRef.BossEditorSection = UIRef.BossTab:AddSection{ Title = "Selected Stop", Side = "Left" }
        UIRef.BossNamesSection = UIRef.BossTab:AddSection{ Title = "Boss Targets", Side = "Right" }
        UIRef.BossTravelSection = UIRef.BossTab:AddSection{ Title = "Teleport and Prompt", Side = "Right" }
        --// Pause For Strangers has sections of its own, each with its title on
        --// top: the switch, the list of hiding spots, and where spots are added.
        UIRef.EvadeSection = UIRef.BossTab:AddSection{ Title = "Pause For Strangers", Side = "Right" }
        UIRef.EvadeListSection = UIRef.BossTab:AddSection{ Title = "Hiding Spots", Side = "Right" }
        UIRef.EvadeAddSection = UIRef.BossTab:AddSection{ Title = "Add A Hiding Spot", Side = "Right" }

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

        --// Turns the EXP check off: with it on, every stop waits its Reset (s)
        --// after the kill before resetting, even when the character's EXP is
        --// inside the part of the bar a reset keeps and nothing would be lost.
        UIRef.BossAlwaysWaitToggle = UIRef.BossSection:AddToggle{
            Name = "Always Wait After Kill",
            Default = CONFIG.BOSS_RESET_ALWAYS_WAIT == true,
            Callback = function(Value)
                CONFIG.BOSS_RESET_ALWAYS_WAIT = Value == true

                if AICProfile.S.ActiveProfileName then
                    AICProfile.SaveActiveProfile()
                end

                SetStatus(CONFIG.BOSS_RESET_ALWAYS_WAIT
                    and "ALWAYS WAIT AFTER KILL"
                    or "INSTANT RESET WHEN NOTHING IS AT RISK")
            end,
        }

        --// One press, and the route resets the instant a kill is in: no Reset
        --// (s), no grace, no waiting for the game's damage tag. The one thing
        --// still waited for is EXP - a reset that would take some holds the
        --// stop's own Reset (s), which is what makes a farm that dies on the
        --// spot safe.
        UIRef.BossDeathFarmToggle = UIRef.BossSection:AddToggle{
            Name = "Death Farm",
            Default = CONFIG.BOSS_DEATH_FARM == true,
            Callback = function(Value)
                CONFIG.BOSS_DEATH_FARM = Value == true

                if AICProfile.S.ActiveProfileName then
                    AICProfile.SaveActiveProfile()
                end

                SetStatus(CONFIG.BOSS_DEATH_FARM
                    and "DEATH FARM  INSTANT RESET UNLESS EXP IS AT RISK"
                    or (CONFIG.BOSS_RESET_ALWAYS_WAIT
                        and "ALWAYS WAIT AFTER KILL"
                        or "INSTANT RESET WHEN NOTHING IS AT RISK"))
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
            --// Seconds held at the corpse before a reset that costs EXP - the
            --// whole pause, waited exactly. The reset is not held at all when it
            --// would cost nothing, unless Always Wait After Kill is on.
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

        --// The fight box: four corners, clicked where the character stands.
        --// The dodge and the reset-hold run stay inside it, so a boss next to
        --// a wall can no longer be dodged through that wall.
        UIRef.BossBoundsLabel = UIRef.BossEditorSection:AddLabel(
            "FIGHT BOUNDS:  NONE  (DODGE RUNS FREELY)"
        )

        UIRef.BossBoundsButton = UIRef.BossEditorSection:AddButton{
            Name = "Add Fight Corner",
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

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    return
                end

                Stop.Bounds = Stop.Bounds or {}

                if #Stop.Bounds >= AICConfig.MAX_BOSS_BOUNDS then
                    SetStatus("FOUR CORNERS SAVED  ·  CLEAR TO REDO")
                    return
                end

                table.insert(Stop.Bounds, AICConfig.RoundVector3(RootPart.Position))
                Commit(string.format(
                    "FIGHT CORNER %d/%d SAVED",
                    #Stop.Bounds,
                    AICConfig.MAX_BOSS_BOUNDS
                ))
            end,
        }

        UIRef.BossBoundsClearButton = UIRef.BossEditorSection:AddButton{
            Name = "Clear Fight Bounds",
            Callback = function()
                local Stop = SelectedStop()

                if not Stop then
                    SetStatus("ADD A BOSS STOP FIRST")
                    return
                end

                if not AICProfile.S.ActiveProfileName then
                    SetStatus("DEFAULT PLACE_CONFIG IS READ-ONLY")
                    return
                end

                Stop.Bounds = nil
                Commit("FIGHT BOUNDS CLEARED")
            end,
        }

        UIRef.BossBoundsVisualToggle = UIRef.BossEditorSection:AddToggle{
            Name = "Show Fight Bounds",
            Default = CONFIG.BOSS_BOUNDS_VISIBLE ~= false,
            Callback = function(Value)
                CONFIG.BOSS_BOUNDS_VISIBLE = Value == true
                AICProfile.WriteGlobalStore()
                RefreshBoundsVisual(SelectedStop())
                SetStatus(
                    CONFIG.BOSS_BOUNDS_VISIBLE
                        and "FIGHT BOUNDS SHOWN"
                        or "FIGHT BOUNDS HIDDEN"
                )
            end,
        }

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

        ------------------------------------------------------------------------
        --// Evasion: the pause-for-strangers hold
        ------------------------------------------------------------------------

        --// The hiding spots as list rows. The number keeps every label unique:
        --// the list finds a spot by its label.
        local function BuildEvadeLabels()
            local Labels = {}

            for Index, Spot in ipairs(GetEvadeSpots()) do
                if Spot.Kind == "Prompt" then
                    Labels[Index] = string.format(
                        "#%d  PROMPT  %s  (%.0f, %.0f, %.0f)",
                        Index,
                        Spot.Name ~= "" and Spot.Name or "HERE",
                        Spot.X,
                        Spot.Y,
                        Spot.Z
                    )
                else
                    Labels[Index] = string.format("#%d  WAYPOINT  %d", Index, Spot.Waypoint)
                end
            end

            return Labels
        end

        --// The list and the line above it, from what is saved.
        local function RefreshEvadeUI()
            local Count = #GetEvadeSpots()

            if UIRef.EvadeSpotLabel then
                UIRef.EvadeSpotLabel:Set(Count == 0
                    and "HIDING SPOTS:  NONE  (THE RESET IS THE WHOLE EVADE)"
                    or (Count == 1
                        and "HIDING SPOTS:  1  (ALWAYS THIS ONE)"
                        or string.format("HIDING SPOTS:  %d  (ONE PICKED AT RANDOM)", Count)))
            end

            if UIRef.EvadeListComponent then
                UIRef.EvadeListComponent:SetPriority(BuildEvadeLabels())
            end
        end

        AICUI.RefreshBossEvadeList = RefreshEvadeUI

        --// Adds a spot unless the list already has it. Where it was added
        --// from decides the message; the list is saved either way.
        local function AddEvadeSpot(Spot, Message)
            if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                return false
            end

            local Spots = GetEvadeSpots()

            if #Spots >= MAX_EVADE_SPOTS then
                SetStatus(string.format("HIDING SPOTS FULL (%d)", MAX_EVADE_SPOTS))
                return false
            end

            local Key = SpotKey(Spot)

            for _, Other in ipairs(Spots) do
                if SpotKey(Other) == Key then
                    SetStatus("ALREADY A HIDING SPOT")
                    return false
                end
            end

            table.insert(Spots, Spot)
            RefreshEvadeUI()
            Commit(Message)
            return true
        end

        do
            local EvadeSection = UIRef.EvadeSection
            local ListSection = UIRef.EvadeListSection
            local AddSection = UIRef.EvadeAddSection

            ----------------------------------------------------------------
            --// Pause For Strangers: the switch and what it does
            ----------------------------------------------------------------

            UIRef.EvadePauseToggle = AICUI.BindFeatureToggle(
                "PauseForStrangers",
                "Pause For Strangers",
                function(Enabled)
                    if not Enabled and S.Evading then
                        --// Switched off in the middle of a hold: the run is
                        --// let go where it stands, never restarted from here.
                        EndEvade(os.clock(), false)
                        SetStatus("PAUSE FOR STRANGERS OFF")
                        return
                    end

                    SetStatus(Enabled
                        and "PAUSE FOR STRANGERS ON"
                        or "PAUSE FOR STRANGERS OFF")
                end,
                EvadeSection
            )

            UIRef.EvadeSpotLabel = EvadeSection:AddLabel("HIDING SPOTS:  NONE")

            EvadeSection:AddNote("When someone who is not on your Block Whitelist shows up, the route stops. Your character resets, hides at one of your Hiding Spots, and waits 2-3 minutes for them to leave")
            EvadeSection:AddNote("They leave: the route starts again at stop #1")
            EvadeSection:AddNote("They stay: the game is closed, like Leave Instead Of Block")

            ----------------------------------------------------------------
            --// Hiding Spots: the list the hold picks from
            ----------------------------------------------------------------

            ListSection:AddNote("Every hold picks one spot from this list at random, never the same one twice in a row. Keep one spot to always hide in the same place")

            UIRef.EvadeListComponent = ListSection:AddPriority("Hiding Spots", {})

            local ListMoveUp = UIRef.EvadeListComponent.MoveUp
            local ListMoveDown = UIRef.EvadeListComponent.MoveDown
            local ListRemove = UIRef.EvadeListComponent.Remove

            local function MoveEvadeSpot(Component, Label, Delta, Original, StatusText)
                if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                    return
                end

                local Spots = GetEvadeSpots()
                local Index = table.find(BuildEvadeLabels(), Label)
                local Other = Index and Index + Delta

                if not Other or Other < 1 or Other > #Spots then
                    return
                end

                Spots[Index], Spots[Other] = Spots[Other], Spots[Index]
                Original(Component, Label)
                RefreshEvadeUI()
                Commit(StatusText)
            end

            function UIRef.EvadeListComponent:MoveUp(Label)
                MoveEvadeSpot(self, Label, -1, ListMoveUp, "HIDING SPOT MOVED UP")
            end

            function UIRef.EvadeListComponent:MoveDown(Label)
                MoveEvadeSpot(self, Label, 1, ListMoveDown, "HIDING SPOT MOVED DOWN")
            end

            function UIRef.EvadeListComponent:Remove(Label)
                if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                    return
                end

                local Spots = GetEvadeSpots()
                local Index = table.find(BuildEvadeLabels(), Label)

                if not Index then
                    return
                end

                table.remove(Spots, Index)
                ListRemove(self, Label)
                RefreshEvadeUI()
                Commit("HIDING SPOT REMOVED #" .. tostring(Index))
            end

            ListSection:AddButton{
                Name = "Clear Hiding Spots",
                Callback = function()
                    if not CanEdit("DEFAULT PLACE_CONFIG IS READ-ONLY") then
                        return
                    end

                    table.clear(GetEvadeSpots())
                    RefreshEvadeUI()
                    Commit("HIDING SPOTS CLEARED")
                end,
            }

            ----------------------------------------------------------------
            --// Add A Hiding Spot: a waypoint by number, or a prompt by standing
            ----------------------------------------------------------------

            AddSection:AddNote("Waypoint: type its number and press enter. Prompt: stand at a door or portal and press the button. Away from any prompt, it saves the spot you are standing on")

            UIRef.EvadeWaypointBox = AddSection:AddTextBox{
                Name = "Add Waypoint #",
                Default = "",
                Inline = true,
                Callback = function(Value)
                    if tostring(Value or "") == "" then
                        return
                    end

                    local Number = tonumber(Value)

                    if not Number or Number < 1 then
                        SetStatus("INVALID VALUE")
                        UIRef.EvadeWaypointBox:Set("", true)
                        return
                    end

                    Number = math.clamp(math.floor(Number), 1, AICConfig.MAX_BOSS_WAYPOINT)

                    AddEvadeSpot(
                        { Kind = "Waypoint", Waypoint = Number },
                        string.format("HIDING SPOT ADDED:  WAYPOINT %d", Number)
                    )

                    UIRef.EvadeWaypointBox:Set("", true)
                end,
            }

            UIRef.EvadePromptButton = AddSection:AddButton{
                Name = "Add Prompt Here",
                Callback = function()
                    local _, _, RootPart = Runtime:GetCharacter()

                    if not RootPart then
                        SetStatus("CHARACTER NOT READY")
                        Say("Evasion", "Character not ready", 4)
                        return
                    end

                    local Prompt, Nearest = FindNearestPrompt(RootPart.Position, PROMPT_SAVE_RADIUS)
                    local Position = GetPromptPosition(Prompt)

                    --// No prompt near: where the player is standing is the
                    --// spot. The hold only needs somewhere to stand still.
                    if not Position then
                        local Here = AICConfig.RoundVector3(RootPart.Position)

                        if AddEvadeSpot(
                            { Kind = "Prompt", Name = "HERE", X = Here.X, Y = Here.Y, Z = Here.Z },
                            "HIDING SPOT ADDED:  STOOD HERE"
                        ) then
                            Say("Evasion", string.format(
                                "No prompt within %d studs%s; saved where you stand",
                                PROMPT_SAVE_RADIUS,
                                Nearest and string.format(" (nearest %.0f)", Nearest) or ""
                            ), 5)
                        end

                        return
                    end

                    local Rounded = AICConfig.RoundVector3(Position)
                    local Name = string.sub(tostring(Prompt.Name or ""), 1, 64)

                    if AddEvadeSpot(
                        { Kind = "Prompt", Name = Name, X = Rounded.X, Y = Rounded.Y, Z = Rounded.Z },
                        "HIDING SPOT ADDED:  PROMPT"
                    ) then
                        Say("Evasion", "Hiding spot added: " .. Name, 4)
                    end
                end,
            }
        end

        RefreshEvadeUI()

        --// Every control exists now, so fill the edit boxes from the selected
        --// stop instead of leaving them empty until the first edit.
        AICUI.RefreshBossRoutePickers()
        AICUI.RefreshBossPathList()
        --// What Features/BossNavigator_Evade.lua reads. Published before this
        --// Start returns, so the split module (which starts right after this
        --// one) always sees a complete table.
        AICFeature.BossNav = {
            S = S,
            FeatureState = FeatureState,
            SetStatus = SetStatus,
            Say = Say,
            IsEnabled = IsEnabled,
            CurrentStop = CurrentStop,
            GetStops = GetStops,
            BeginStop = BeginStop,
            ResetWalk = ResetWalk,
            EndDodge = EndDodge,
            StopFlee = StopFlee,
            ClearKillClock = ClearKillClock,
            SyncDeathMark = SyncDeathMark,
            GetFloorOverlap = GetFloorOverlap,
            LiftFromFloor = LiftFromFloor,
            FixLandedFloor = FixLandedFloor,
            TeleportToPoint = TeleportToPoint,
            TeleportToWaypoint = TeleportToWaypoint,
            FightStep = FightStep,
            ApproachStep = ApproachStep,
            RecoverStep = RecoverStep,
            BeginRecover = BeginRecover,
            IsMobAlive = IsMobAlive,
            SetBlocking = SetBlocking,
            StopRoute = StopRoute,
            WatchDeath = WatchDeath,
            GetEvadeConfig = GetEvadeConfig,
            CleanSpots = CleanSpots,
            GetEvadeSpots = GetEvadeSpots,
            SpotKey = SpotKey,
            MAX_EVADE_SPOTS = MAX_EVADE_SPOTS,
            EVADE_WAIT_MIN = EVADE_WAIT_MIN,
            EVADE_WAIT_MAX = EVADE_WAIT_MAX,
            EVADE_KICK_RETRY = EVADE_KICK_RETRY,
            EVADE_DEAD_SETTLE = EVADE_DEAD_SETTLE,
            EVADE_RESET_RETRY_DELAY = EVADE_RESET_RETRY_DELAY,
            EVADE_RESET_GIVE_UP = EVADE_RESET_GIVE_UP,
            RESET_RETRIES = RESET_RETRIES,
            RESET_STAY_DISTANCE = RESET_STAY_DISTANCE,
            PROMPT_WAIT = PROMPT_WAIT,
            PROMPT_ARRIVAL = PROMPT_ARRIVAL,
            PROMPT_RECHECK = PROMPT_RECHECK,
            PROMPT_INTERACT_MUTE = PROMPT_INTERACT_MUTE,
            TELEPORT_LAND_WINDOW = TELEPORT_LAND_WINDOW,
            TELEPORT_LAND_DISTANCE = TELEPORT_LAND_DISTANCE,
            RESPAWN_SETTLE = RESPAWN_SETTLE,
            FLOOR_BURIED = FLOOR_BURIED,
        }

        RefreshBossVisuals()
        SetStatus("IDLE")

        return Feature
    end,
}