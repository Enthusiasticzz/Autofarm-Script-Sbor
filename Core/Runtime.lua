-- AutoFarmV3 Core Runtime
-- Shared runtime state, services, configuration, and composition context.
return {
    Name = "Runtime",
    Dependencies = {"SaveConfig"},
    Start = function(Context)
        local SaveConfig = Context.SaveConfig
        local Players            = game:GetService("Players")
        local Replicated         = game:GetService("ReplicatedStorage")
        local StarterGui         = game:GetService("StarterGui")
        local RunService         = game:GetService("RunService")
        local UserInputService   = game:GetService("UserInputService")
        local MarketplaceService = game:GetService("MarketplaceService")
        local PathfindingService = game:GetService("PathfindingService")
        local HttpService        = game:GetService("HttpService")
        
        local Player    = Players.LocalPlayer
        local PlayerGui = Player:WaitForChild("PlayerGui", 30)
        if not PlayerGui then
            error("[AIC] PlayerGui not found — cannot start AIC UI")
        end
        
        --==============================================================
        --// LAYERS
        --//
        --// Every function in this file lives on one of the tables below.
        --// A layer only ever calls downward in this list, never upward,
        --// so the dependency direction stays readable at a glance.
        --//
        --//
        --// The tables are declared up front and filled in further down, so
        --// call order between layers does not depend on definition order.
        --==============================================================
        local AICConfig = {}
        local AICProfile = {}
        local AICCombatUtils = {}
        local AICCombat = {}
        local AICFeature = {}
        local AICUI = {}
        local AICDebug = {}
        
        --// Every module keeps its mutable state on its own S table. Ownership is
        --// then obvious from the name alone, resetting a whole area is one
        --// table.clear, and none of it costs a local register, which is what put
        --// this file into the compiler limit before.
        AICProfile.S = {}
        AICCombat.S = {}
        AICCombatUtils.S = {}
        AICFeature.S = {}
        AICUI.S = {}
        AICDebug.S = {}
        
        --// Luau allows 200 local registers in a chunk and this file had reached
        --// exactly that, which the compiler rejects outright, so nothing loaded at
        --// all. Related state lives on a table instead of one register each: the UI
        --// handles and everything the patrol keeps between frames.
        local UIRef = {}
        local PatrolState = {}
        
        --// Init normally creates the window up front so its boot loader can
        --// show real progress. Without it, Studio can require the local Utils
        --// ModuleScript and executor/Git mode fetches the remote source.
        local UI = Context.UI

        if not UI then
            local UtilsModule = Replicated:FindFirstChild("Utils")
            local Utils
            if UtilsModule and UtilsModule:IsA("ModuleScript") then
                Utils = require(UtilsModule)
            else
                --// Same base as Init.lua's BASE, override included: this path
                --// only runs when Init did not create the window, and it has to
                --// fetch the same build rather than another repo's copy.
                local Base = "https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/"

                local Ok, Env = pcall(function()
                    return type(getgenv) == "function" and getgenv() or nil
                end)

                if Ok and type(Env) == "table" and type(Env.AICBaseURL) == "string" and Env.AICBaseURL ~= "" then
                    Base = Env.AICBaseURL

                    if not string.find(Base, "/$") then
                        Base = Base .. "/"
                    end
                end

                local UtilsChunk = assert(loadstring(game:HttpGet(Base .. "UI/Utils.lua"), "@Utils.lua"))
                Utils = UtilsChunk()
            end
            UI = Utils.new("AUTOMATED INDUSTRY COMPLEX")
        end

        --// Shared UI foundation. Feature modules own their controls; Runtime
        --// only creates the tabs/sections they attach those controls to.
        UIRef.StatusTab = UI:AddTab("Status")
        UIRef.FarmTab = UI:AddTab("Farming")
        --// Boss route: its own tab, list and timers, apart from the farming
        --// waypoints and the profile waypoints (BossNavigator).
        UIRef.BossTab = UI:AddTab("Bosses")
        UIRef.MineTab = UI:AddTab("Mining")
        UIRef.CraftTab = UI:AddTab("Crafting")
        UIRef.PartyTab = UI:AddTab("Party")
        UIRef.ServerTab = UI:AddTab("Server")
        UIRef.TeleportTab = UI:AddTab("Teleport")
        UIRef.QuestTab = UI:AddTab("Quest")
        UIRef.DebugTab = UI:AddTab("Debug")
        UIRef.UtilityTab = UI:AddTab("Utility")
        UIRef.UtilitySection = UIRef.UtilityTab:AddSection("Utilities")
        UIRef.FeatureSection = UIRef.FarmTab:AddSection("Core")
        UIRef.CoreSection = UIRef.FeatureSection
        UIRef.CombatSection = UIRef.FarmTab:AddSection("Combat")
        UIRef.TargetSection = UIRef.FarmTab:AddSection("Targeting")
        UIRef.BlockSection = UIRef.FarmTab:AddSection("Auto Block")
        UIRef.GatherSection = UIRef.FarmTab:AddSection("Mob Gather")
        --// Holds AutoRefill's booster list: which boosters reset the character
        --// when they run out.
        UIRef.BoosterSection = UIRef.FarmTab:AddSection("Booster Reset")
        UIRef.StatusSection = UIRef.StatusTab:AddSection("Live Status")
        UIRef.DebugSection = UIRef.DebugTab:AddSection("Debug Visualizer")
        UIRef.MineSection = UIRef.MineTab:AddSection("Auto Mining")
        UIRef.CraftSection = UIRef.CraftTab:AddSection("Auto Smithing")
        UIRef.PartySection = UIRef.PartyTab:AddSection("Party System")
        UIRef.ServerSection = UIRef.ServerTab:AddSection("Current Server")
        UIRef.ServerSafetySection = UIRef.ServerTab:AddSection("Server Safety")
        UIRef.ServerLogSection = UIRef.ServerTab:AddSection("Player Log")
        UIRef.DoorTeleportSection = UIRef.TeleportTab:AddSection("Door Teleport")
        UIRef.WaypointTeleportSection = UIRef.TeleportTab:AddSection("Waypoint Teleport")
        UIRef.QuestSection = UIRef.QuestTab:AddSection("Assign Quest")
        UIRef.QuestHelperSection = UIRef.QuestTab:AddSection("Quest Helper")
        
        local function NotifyAction(Action, Message, Duration)
            if UI and type(UI.Notify) == "function" then
                UI:Notify(Action, Message, Duration or 2.5)
            end
        end
        
        
        
        --======================================================================
        --// SECTION 1  ::  CONFIGURATION AND STATE
        --// Pure data and every top-level variable, declared before any layer runs.
        --======================================================================
        
        
        local CONFIG = {
            CURRENT_WAYPOINT_TARGET = 1,
            MAX_SERVER_AGE = 7 * 60 * 60,
        
            TARGET_ENTITY_PRIORITY = {
                [1] = "Goblin",
                [2] = "Leader Goblin",
            },
        
            --// Saved settings (EXECUTE_CHARGE_HP_PERCENT, TARGET_HP_MODE,
            --// PARTY_LEADER, PINNED_STATE, SAFE_ENEMY_RANGE,
            --// RETREAT_HEALTH_PERCENT, AUTO_HEAL_HEALTH_PERCENT) take their
            --// defaults from SaveConfig.Settings below, not from here; global
            --// ones (BLOCK_WHITELIST, DANGER_*, UI_*) from SaveConfig.GlobalSettings.

            --// Roblox disconnects an idle client after about twenty minutes. The
            --// script drives the character, not the mouse, so the idle timer keeps
            --// running. Nudged well inside that window.
            ANTI_AFK_INTERVAL = 480,

            --// Party System timing. The Leader itself is a saved setting.
            PARTY_CHECK_INTERVAL = 1,
            PARTY_TP_ATTEMPTS = 3,
            PARTY_TP_ATTEMPT_TIMEOUT = 15,
            PARTY_RESPAWN_TIMEOUT = 10,
            PARTY_FAILED_COOLDOWN = 60,

            GOBLIN_REACH_DISTANCE = 8,
            PLAYER_ATTACK_DISTANCE = 12,
            --// A walk passing closer than this to the target's root goes
            --// through its body, which climbs or jumps onto it.
            TARGET_BODY_CLEARANCE = 3.5,
            ENEMY_ATTACK_SAFE_DISTANCE = 2,
            ENEMY_BLADE_PADDING = 2,
            GROUP_DANGER_DISTANCE = 22,
            THREAT_DETECTION_DISTANCE = 12,
            THREAT_ANGLE = 65,
            THREAT_ESCAPE_DISTANCE = 20,
            RETREAT_NEARBY_MOB_DISTANCE = 30,
            --// While retreating from a player the character keeps moving until
            --// they are at least this far away. In a duel it never stops.
            RETREAT_PLAYER_SAFE_DISTANCE = 50,

            DEADZONE_ESCAPE_DISTANCE = 45,
            DEADZONE_ESCAPE_DIRECTIONS = 16,
            DEADZONE_ESCAPE_INTERVAL = 0.3,
        
            JUMP_HEIGHT = 2,
            STUCK_CHECK_INTERVAL = 0.5,
            BLOCK_COOLDOWN = 3,
        
            MOB_DETECTION_DISTANCE = 200,
            MOB_VALIDATION_INTERVAL = 0.15,
            --// GetLivingGoblins walks the whole mob folder, and the retreat solver
            --// calls it once per candidate, so one solve used to rescan the folder
            --// dozens of times. The list cannot meaningfully change inside this.
            LIVING_MOB_CACHE_INTERVAL = 0.1,
            DISTANCE_Y_CALCULATE = false,
            --// How long to keep trying to reach a mob before concluding there is no
            --// route to it, and how long to leave it alone afterwards. Without the
            --// second value the target is dropped and then immediately reselected,
            --// so the character runs at something it can never reach forever.
            TARGET_UNREACHABLE_TIMEOUT = 6,
            UNREACHABLE_COOLDOWN = 15,
            TARGET_REPOSITION_INTERVAL = 0.3,
            TARGET_PATH_RECALCULATE_INTERVAL = 0.5,
            TARGET_PATH_WAYPOINT_DISTANCE = 3,
            TARGET_REPOSITION_RADIUS = 12,
            TARGET_REPOSITION_DIRECTIONS = 16,
            SAFE_COMBAT_DIRECTIONS = 12,
            SAFE_COMBAT_MAX_PATH_TESTS = 4,
            --// Cost added to a combat position the mob cannot be seen from. Losing
            --// sight behind a pillar should cost a detour, not the whole candidate.
            BLIND_POSITION_PENALTY = 14,
        
            --// Jumping is only useful against something that can be jumped over, so
            --// movement probes ahead instead of hopping on every frame. A hit low
            --// down with clear space above it is a ledge or a rock; a hit at both
            --// heights is a wall, which a jump does not solve.
            JUMP_PROBE_DISTANCE = 4.5,
            JUMP_PROBE_LOW_OFFSET = 0.6,
            JUMP_PROBE_HIGH_OFFSET = 3.2,
            JUMP_STEP_HEIGHT = 1.2,
            --// How far outside the farm zone the return may still pathfind from.
            FARM_RETURN_PATH_DISTANCE = 220,
            OTHER_ATTACKER_SIDE_SWITCH_MIN = 0.1,
            OTHER_ATTACKER_SIDE_SWITCH_MAX = 0.3,
            OTHER_PLAYER_DETOUR_DISTANCE = 4,
        
            RETREAT_DISTANCE = 60,
            RETREAT_DIRECTIONS = 16,
            RETREAT_RECALCULATE_INTERVAL = 0.12,
            RETREAT_NO_POSITION_TIMEOUT = 1.5,
            SKILL_RETREAT_DISTANCE = 60,
            SKILL_RETREAT_PATH_TIMEOUT = 0.35,
        
            --// Enemy skill reaction. Detection covers every nearby mob, not just the
            --// current target, because a skill from a mob we are not fighting still
            --// connects. The hold keeps the dodge running for a moment after the
            --// signal clears, so a flickering sound or emitter cannot drop us back
            --// into the attack halfway through the escape.
            SKILL_DETECT_DISTANCE = 45,
            SKILL_DODGE_HOLD = 0.75,
            SKILL_DODGE_DISTANCE = 26,
            SKILL_DODGE_FALLBACK_DISTANCE = 14,
            SKILL_DODGE_DIRECTIONS = 9,
            SKILL_DODGE_SPREAD = 110,
            --// The pathfinding retreat solver is expensive enough to stall frames, so
            --// during a dodge it is a fallback that runs at most this often.
            SKILL_SOLVER_INTERVAL = 0.6,
        
            --// Sheathing and drawing the weapon both play an animation. Without a
            --// floor between toggles the script can flap once per frame.
            EQUIP_TOGGLE_COOLDOWN = 0.35,
        
            ATTACK_INTERVAL = 0.16,
            SKILL_INTERVAL = 3,
            COMBAT_ATTACK_RANGE = 14.5,
            COMBAT_SKILL_RANGE = 15,
            COMBAT_FACE_RANGE = 22,
            COMBAT_TARGET_GRACE = 0.45,
            COMBAT_LOW_HP_PERCENT = 35,
            COMBAT_SKILL_MIN_HP_PERCENT = 50,
            COMBAT_ACTION_JITTER = 0.025,
            COMBAT_TARGET_RECHECK = 0.08,
            COMBAT_STICKY_DISTANCE_BONUS = 6,
            COMBAT_FINISHER_HP_PERCENT = 18,
            COMBAT_FINISHER_RANGE_BONUS = 1.5,
            COMBAT_ENGAGE_MAX_DISTANCE = 50,
            COMBAT_POSITION_ARRIVAL = 2,
            APPROACH_ARRIVAL_DISTANCE = 3,
            SAFE_ENEMY_RANGE_ARRIVAL = 2,
            CONSUME_INTERVAL = 10,
            MINIMUM_WALKSPEED = 28,
            MAXIMUM_WALKSPEED = 38,
            HIGH_LEVEL_THRESHOLD = 300,
            STAT_RESET_THRESHOLD = 500,
            INTERACTION_INTERVAL = 0.5,
            TEXT_UPDATE_INTERVAL = 0.5,
            PROFILE_SAVE_DEBOUNCE = 0.5,
            --// Target pickers. Mob spawns and deaths are batched into one
            --// rebuild after this many seconds; roster changes show quickly.
            MOB_TARGET_REFRESH_DELAY = 3,
            PLAYER_TARGET_REFRESH_DELAY = 0.5,
        
            DEBUG_VISUALIZE_WAYPOINTS = true,
            DEBUG_WAYPOINT_MAX_DISTANCE = 500,
            DEBUG_WAYPOINT_SIZE = 0.75,
            DEBUG_ZONE_HEIGHT = 0.15,
        
            SAFECOMBAT_INTERVAL = 0.25,
            BLADE_PART_CACHE_INTERVAL = 0.2,
            COMBAT_GROUP_CACHE_INTERVAL = 0.15,
            DIRECT_PATH_CACHE_INTERVAL = 0.12,
        
            PATROL_DIRECTIONS = 12,
            PATROL_RECALCULATE_INTERVAL = 12,
            PATROL_MIN_DISTANCE = 24,
            PATROL_MAX_DISTANCE = 58,
            PATROL_ARRIVAL_DISTANCE = 4,
            PATROL_PAUSE_MIN = 0.8,
            PATROL_PAUSE_MAX = 2.8,
            PATROL_DIRECTION_MEMORY = 0.65,
            PATROL_ESCAPE_DISTANCE = 10,
            PATROL_ESCAPE_DIRECTIONS = 4,
        
            --// A person walking somewhere does not move in one unbroken line to a
            --// point and stop dead. They pause partway, change their mind about how
            --// far to go, and do not stop at exactly the same distance every time.
            PATROL_MIDWALK_PAUSE_CHANCE = 0.18,
            PATROL_MIDWALK_PAUSE_MIN = 0.4,
            PATROL_MIDWALK_PAUSE_MAX = 1.5,
            PATROL_MIDWALK_ROLL_INTERVAL = 1.1,
            PATROL_SHORT_LEG_CHANCE = 0.22,
            PATROL_SHORT_LEG_SCALE = 0.45,
            PATROL_ARRIVAL_JITTER = 2.5,
        
            --// A patrol runs several legs back to back before resting, the number
            --// picked per rest, rather than stopping at every single point.
            PATROL_LEGS_MIN = 1,
            PATROL_LEGS_MAX = 4,
        
            --// Direction changes are steered rather than switched. The heading turns
            --// at a limited rate toward the new bearing and the character walks at a
            --// point just ahead of itself, which traces an arc instead of pivoting on
            --// the spot. Lower turn rate means a wider curve.
            PATROL_TURN_RATE = 150,
            PATROL_LOOKAHEAD = 11,
            PATROL_CURVE_MIN_ANGLE = 12,
        
            --// Occasionally lean the heading off the direct bearing for a moment, so
            --// a leg wanders instead of running dead straight. Rolled on an interval
            --// and deliberately uncommon; a constant weave looks worse than a
            --// straight line.
            PATROL_RANDOM_CURVE_CHANCE = 0.22,
            PATROL_RANDOM_CURVE_ROLL_INTERVAL = 2.6,
            PATROL_RANDOM_CURVE_MIN_TIME = 1.2,
            PATROL_RANDOM_CURVE_MAX_TIME = 2.5,
        
            --// The wander is described by the radius of the arc it walks rather than
            --// by an angle. Radius is what is actually visible: a small one is a
            --// tight loop around something, a large one is a barely perceptible
            --// drift. Turn rate follows from it and the walk speed, so the arc holds
            --// its shape whatever the character is moving at.
            PATROL_CURVE_RADIUS_MIN = 12,
            PATROL_CURVE_RADIUS_MAX = 55,
            --// Cap on how far the bearing may sweep off course, so a long curve
            --// bends the route instead of turning it into a circle.
            PATROL_CURVE_MAX_SWEEP = 48,
            PATROL_SMOOTH_SNAP_DISTANCE = 7,
        
            --// Movement only jumps when it is genuinely stuck: barely moving while
            --// actively trying to. Checked over this window.
            STUCK_SAMPLE_INTERVAL = 0.35,
            STUCK_MIN_PROGRESS = 0.6,

            --// Chasing a target. A straight walk is used while it works; a
            --// wall just ahead or a stall switches to pathfinding for a while,
            --// and a stall on the path itself sidesteps out of the corner.
            CHASE_BLOCK_PROBE_DISTANCE = 6,
            CHASE_BLOCK_CHECK_INTERVAL = 0.12,
            CHASE_PATH_HOLD = 2.5,
            CHASE_UNSTICK_TIME = 0.6,
            CHASE_MAX_UNSTICKS = 4,
            UNSTICK_PROBE_DISTANCE = 9,
            UNSTICK_MIN_FREE = 3,

            --// Facing the target. The aim leads a moving target by this many
            --// seconds of its velocity, so a mob walking around us is faced
            --// where it is going rather than where it was. A heading error
            --// above the snap angle turns rigidly (instantly) instead of easing.
            FACE_RESPONSIVENESS = 200,
            FACE_LEAD_TIME = 0.12,
            FACE_SNAP_ANGLE = 35,
            --// Bounds on the lead: none closer than MIN_DISTANCE, velocity
            --// capped at MAX_SPEED, and never more than MAX_RATIO of the
            --// distance to the target.
            FACE_LEAD_MIN_DISTANCE = 6,
            FACE_LEAD_MAX_SPEED = 20,
            FACE_LEAD_MAX_RATIO = 0.35,
            --// Facing while retreating: no snap, a slower ease with the turn
            --// capped at MAX_TURN_SPEED rad/s, changes under DEADBAND degrees
            --// ignored. Switching between the threat and the run direction
            --// needs the threat HYSTERESIS studs past the face range to let go,
            --// and is then held HOLD seconds.
            RETREAT_FACE_RESPONSIVENESS = 30,
            RETREAT_FACE_MAX_TURN_SPEED = 6,
            RETREAT_FACE_DEADBAND = 15,
            RETREAT_FACE_HYSTERESIS = 6,
            RETREAT_FACE_HOLD = 0.8,
            --// Swimming tilts the facing up/down toward the target, at most
            --// this many degrees.
            SWIM_FACE_MAX_PITCH = 70,

            --// Fighting in water. Distances are measured in 3D there, since a
            --// diver straight below is close on the map but out of reach.
            SWIM_ARRIVAL_DISTANCE = 5,
            SWIM_SURFACE_MARGIN = 2,
        
            FARM_RETURN_CANDIDATES = 24,
            FARM_RETURN_RADIUS_MIN = 10,
            FARM_RETURN_RADIUS_MAX = 20,
            FARM_RETURN_RECALCULATE_INTERVAL = 0.75,
            FARM_RETURN_MIN_SPREAD = 4,
            FARM_RETURN_ARRIVAL_DISTANCE = 4,
            FARM_RETURN_CENTER_DISTANCE = 5,
        
            --// Zones are cylinders: the radius check ignores height so that sloped
            --// ground inside one zone still counts. On a multi-floor map that lets a
            --// mob one floor above or below match a zone it is not really in. Set a
            --// positive value to also require the point to be within this many studs
            --// of the zone centre vertically. 0 keeps the original flat behaviour.
            ZONE_MAX_HEIGHT_DIFFERENCE = 0,
        
            WATER_SAMPLE_DISTANCE = 4,
            DEADZONE_SAMPLE_DISTANCE = 2,
        
            UI_PANEL = Color3.fromRGB(22, 23, 29),
            UI_SURFACE = Color3.fromRGB(29, 31, 38),
            UI_HOVER = Color3.fromRGB(38, 40, 48),
            UI_BORDER = Color3.fromRGB(55, 58, 68),
            UI_TEXT = Color3.fromRGB(238, 239, 244),
            UI_MUTED = Color3.fromRGB(145, 149, 162),
            UI_ACCENT = Color3.fromRGB(112, 126, 255),
        }
        
        --// Saved settings start at their SaveConfig defaults. Place-scoped
        --// ones live on the place config instead.
        for _, Entry in ipairs(SaveConfig.Settings) do
            if Entry.Scope ~= "Place" then
                CONFIG[Entry.Key] = SaveConfig.GetSettingDefault(Entry)
            end
        end

        local PLACE_CONFIG = {
            [10299594856] = { --// Event Floor
                DEFAULT_TARGET_PRIORITY = {
                    [1] = "Karkinos the Visceral",
                    [2] = "Water Style Disciple",
                    [3] = "Drake the North Sea Commander",
                    [4] = "Marina the South Sea Commander",
                },
                WAYPOINTS = {
                    Vector3.new(1773, 61, 336),
                    Vector3.new(1778, 61, 536),
                    Vector3.new(1810, 61, 703),
                    Vector3.new(1652, 71, 809),
                    Vector3.new(1652, 99, 735),
                    Vector3.new(1600, 118, 737),
                    Vector3.new(1605, 125, 770),
                    Vector3.new(1533, 110, 778),
                    Vector3.new(1466, 102, 726),
                    Vector3.new(1427, 86, 664),
                    Vector3.new(1410, 83, 712),
                    Vector3.new(1455, 72, 720),
                    Vector3.new(1533, 57, 588),
                    Vector3.new(1474, 57, 553),
                    Vector3.new(1442, 61, 517),
                    Vector3.new(1438, 61, 504),
                },
                FARM_CENTER = Vector3.new(1442, 61, 517),
                FARM_RADIUS = 100,
                FARM_DEADZONE_CENTER = Vector3.zero,
                FARM_DEADZONE_RADIUS = 35,
        
                REACH_DISTANCE = 5,
                AUTOBLOCK = false,
            },
            [11987539001] = {
                DEFAULT_TARGET_PRIORITY = { --// F16
                    [1] = "Goblin",
                    [2] = "Leader Goblin",
                },
                WAYPOINTS = {
                    Vector3.new(-2326, 163, -1412),
                    Vector3.new(-2271, 148, -1298),
                    Vector3.new(-2171, 168, -914),
                    Vector3.new(-2044, 167, -429),
                    Vector3.new(-1971, 157, 59),
                    Vector3.new(-1831, 164, 168),
                    Vector3.new(-1681, 184, 879),
                    Vector3.new(-1520, 179, 1452),
                    Vector3.new(-1409, 179, 1846),
                    Vector3.new(-1365, 179, 1905),
                    Vector3.new(-1364, 172, 1962),
                    Vector3.new(-1363, 174, 2068),
                    Vector3.new(-1437, 176, 2494),
                    Vector3.new(-1654, 174, 2619),
                    Vector3.new(-1792, 175, 2769),
                },
                FARM_CENTER = Vector3.new(-1715, 173, 2798),
                FARM_RADIUS = 200,
                FARM_DEADZONE_CENTER = Vector3.new(-1681, 173, 2821),
                FARM_DEADZONE_RADIUS = 35,
        
                REACH_DISTANCE = 5,
                AUTOBLOCK = true,
            }
        }
        
        local PlaceConfig
        
        --//==============================================================
        --// Profile Store
        --// Profiles are stored per PlaceId. The last used profile for the
        --// current place is restored automatically on the next execution.
        --//==============================================================
        
        
        AICFeature.S.DeadzoneEscapePosition = nil
        PatrolState.PatrolPosition = nil
        PatrolState.LastPatrolCalculateTime = 0
        PatrolState.PatrolDirection = nil
        PatrolState.PatrolPauseUntil = 0
        PatrolState.PatrolLastPosition = nil
        PatrolState.PatrolLastDistance = 0
        PatrolState.PatrolMidwalkRollTime = 0
        PatrolState.PatrolArrivalDistance = 0
        PatrolState.PatrolLegsRemaining = 0
        PatrolState.PatrolHeading = nil
        PatrolState.PatrolSteerTime = 0
        PatrolState.PatrolCurveBias = 0
        PatrolState.PatrolCurveUntil = 0
        PatrolState.PatrolCurveRollTime = 0
        AICFeature.S.LastAntiAfkTime = 0
        AICCombatUtils.S.StuckSampleTime = 0
        AICCombatUtils.S.StuckSamplePosition = nil
        AICCombatUtils.S.StuckStrikes = 0
        AICFeature.S.FarmReturnPosition = nil
        AICFeature.S.LastFarmReturnCalculateTime = 0
        
        local BasePlaceConfig
        
        
        local Character
        local Humanoid
        local RootPart
        --// Character handles shared by several modules, in the same class as the
        --// three above: nothing owns the character, so nothing owns these.
        local FaceOrientation
        local InputBindableFunction
        
        --// One entry per saved toggle in SaveConfig.Features. Modules read and
        --// write Feature[Name].Enabled and park their toggle on .Button.
        local Feature = {}

        for _, Entry in ipairs(SaveConfig.Features) do
            Feature[Entry.Name] = {
                Enabled = Entry.Default,
                Button = nil,
                Status = nil,
            }
        end
        
        local MiningFeature = {
            AutoMining = {
                Enabled = false,
                Button = nil,
                Status = nil,
            },
        }
        
        AICCombat.S.ClosestTarget = nil
        AICFeature.S.DEATH_COUNT = 0
        AICCombat.S.LAST_MOB_VALIDATION_TIME = 0
        AICCombat.S.TargetUnreachableSince = nil
        AICCombat.S.TargetApproachPosition = nil
        AICCombat.S.TargetApproachMob = nil
        AICCombat.S.LastTargetRepositionTime = 0
        
        AICCombat.S.TargetPath = nil
        AICCombat.S.TargetPathMob = nil
        AICCombat.S.TargetPathDestination = nil
        AICCombat.S.TargetPathWaypoint = 1
        AICCombat.S.LastTargetPathTime = 0
        AICCombat.S.TargetPathBlockedSince = nil
        
        AICCombat.S.ValidMobs = {}
        AICCombat.S.UnreachableMobs = {}
        AICCombat.S.LivingGoblinCache = nil
        AICCombat.S.LivingGoblinCacheTime = 0
        
        AICCombat.S.RETREATING = false
        AICCombat.S.LastRetreatPosition = nil
        AICCombat.S.LastRetreatCalculateTime = 0
        AICCombat.S.RetreatNoPositionSince = nil
        AICCombat.S.SkillRetreatPosition = nil
        AICCombat.S.LastSkillRetreatTime = 0
        AICCombat.S.SkillThreatUntil = 0
        AICCombat.S.LastSkillSolverTime = 0
        AICFeature.S.LAST_EQUIP_TIME = 0
        
        AICCombat.S.LAST_ATTACK_TIME = 0
        AICCombat.S.LAST_SKILL_TIME = 0
        AICCombat.S.LAST_COMBAT_TARGET_CHECK = 0
        AICCombat.S.COMBAT_TARGET_LOST_SINCE = nil
        AICCombat.S.COMBAT_TARGET_SCORE = math.huge
        AICCombat.S.COMBAT_ATTACK_PHASE = 0
        AICCombat.S.COMBAT_NEXT_ATTACK_TIME = 0
        AICCombat.S.COMBAT_NEXT_SKILL_TIME = 0
        
        --// Potion Consume
        
        AICFeature.S.LAST_CONSUME_TIME = 0
        AICFeature.S.LAST_INTERACTION_TIME = 0
        AICUI.S.LAST_TEXT_UPDATE_TIME = 0
        AICCombatUtils.S.LAST_STUCK_TIME = 0
        AICCombatUtils.S.LAST_STUCK_POSITION = nil
        
        AICCombat.S.CACHED_SAFECOMBAT_POSITION = nil
        AICCombat.S.CACHED_SAFECOMBAT_TARGET = nil
        AICCombat.S.LAST_SAFECOMBAT_TIME = 0
        AICCombat.S.LastAttackerCombatMob = nil
        AICCombat.S.LastAttackerCombatSide = 1
        AICCombat.S.LastAttackerCombatSwitchTime = 0
        AICCombat.S.LastAttackerCombatPosition = nil
        
        AICCombatUtils.S.BladePartCache = {}
        AICCombat.S.CombatGroupCache = {}
        AICCombat.S.CombatBladeCache = {}
        
        AICCombat.S.LastDirectPathCheckTime = 0
        AICCombat.S.LastDirectPathTarget = nil
        AICCombat.S.LastDirectPathPosition = nil
        AICCombat.S.LastDirectPathBlocked = false
        
        AICFeature.S.LastDeadzoneEscapeTime = 0
        
        --// Debug Visualizer
        AICCombatUtils.S.DebugFolder = nil
        AICDebug.S.DebugWaypointData = {}
        AICDebug.S.DebugFarmZone = nil
        AICDebug.S.DebugDeadzone = nil
        AICDebug.S.DebugZoneSignature = nil
        AICDebug.S.DebugWaypointSignature = nil
        
        local DEBUG_COLORS = {
            WaypointPending = Color3.fromRGB(108, 119, 117),
            WaypointCurrent = Color3.fromRGB(220, 205, 0),
            WaypointVisited = Color3.fromRGB(165, 195, 170),
            WaypointLine    = Color3.fromRGB(220, 205, 0),
            FarmZone        = Color3.fromRGB(80, 125, 95),
            Deadzone        = Color3.fromRGB(150, 65, 65),
            MineZone        = Color3.fromRGB(70, 110, 160),
            OreReady        = Color3.fromRGB(120, 200, 140),
            OreMining       = Color3.fromRGB(220, 205, 0),
            OreBlocked      = Color3.fromRGB(205, 110, 90),
            OreIdle         = Color3.fromRGB(150, 158, 156),
            BillboardPanel  = Color3.fromRGB(27, 32, 33),
            BillboardBorder = Color3.fromRGB(79, 91, 91),
            BillboardText   = Color3.fromRGB(232, 237, 235),
            BillboardMuted  = Color3.fromRGB(171, 181, 179),
        }
        
        --// InputBindableFunction
        AICFeature.S.BlockValue = nil
        
        AICFeature.S.WaypointEnabled = true
        --// os.clock() time a waypoint wait ends, or nil when not waiting.
        AICFeature.S.WaypointWaitUntil = nil
        AICFeature.S.Enabled = true
        AICFeature.S.Equipped = false
        --// The inventory item the Status tab's event currency readout counts,
        --// under the name the game gives it. The event changes it.
        AICUI.S.TargetCurrency = "Fallen Camellia"
        AICUI.S.LastInventory = nil
        AICUI.S.EventCurrency = 0
        
        AICCombat.S.SafeCombatPositionEnabled = true
        
        
        
        AICFeature.S.StaminaConnection = nil
        AICFeature.S.BoosterConnections = {}
        
        
        
        --//==============================================================
        --// Utility UI
        --//==============================================================
        
        --UI:SetTheme({
        --    Background      = CONFIG.UI_PANEL,
        --    BackgroundLight = CONFIG.UI_SURFACE,
        --    Panel           = CONFIG.UI_SURFACE,
        --    PanelLight      = CONFIG.UI_HOVER,
        --    PanelHover      = Color3.fromRGB(48, 50, 60),
        --    Element         = CONFIG.UI_SURFACE,
        --    ElementHover    = CONFIG.UI_HOVER,
        --    Text            = CONFIG.UI_TEXT,
        --    TextSecondary   = Color3.fromRGB(190, 193, 204),
        --    TextMuted       = CONFIG.UI_MUTED,
        --    Cyan            = CONFIG.UI_ACCENT,
        --    CyanDark        = Color3.fromRGB(80, 90, 190),
        --    CyanDim         = Color3.fromRGB(150, 160, 255),
        --    White           = CONFIG.UI_TEXT,
        --    Border          = CONFIG.UI_BORDER,
        --    BorderDim       = Color3.fromRGB(45, 48, 58),
        --    Danger          = Color3.fromRGB(255, 65, 65),
        --    Warning         = Color3.fromRGB(255, 180, 0),
        --    Black           = Color3.fromRGB(10, 10, 14),
        --})
        
        
        
        
        
        --// Live status labels
        
        --// Detected Entity List
        AICCombat.S.DetectedEntities = {}
        
        --// Priority component
        
        UIRef.WhitelistPlayerOptions = {}
        
        --// Keep Utils priority actions synchronized with the farm state and target dropdown.
        
        --//==============================================================
        --// Profile Settings
        --//==============================================================
        
        
        
        
        
        --// Mob Watcher
        AICCombat.S.MobConnections = {}
        AICCombat.S.MobFolderConnections = {}
        
        
        --======================================================================
        --// SECTION 2  ::  LAYERS
        --// Function definitions only. No layer runs anything at load time.
        --======================================================================
        
        
        
        
        ------------------------------------------------------------------------
        --// AICConfig
        --//
        --// place presets and config normalisation
        --//
        --// 2 function(s). Definitions only; nothing here runs
        --// at load time.
        ------------------------------------------------------------------------
        
        ------------------------------------------------------------------------
        --// AICConfig  ::  place presets and CONFIG normalisation
        --// 2 function(s)
        ------------------------------------------------------------------------
        function AICConfig.IsValidPlace(id: number)
            if PLACE_CONFIG[id] then
                return PLACE_CONFIG[id]
            end
            return false
        end
        
        function AICConfig.NormalizePlaceConfig(Config)
            Config = Config or {}
        
            local Waypoints = AICConfig.CloneVectorList(Config.WAYPOINTS)
            local FarmZones = AICConfig.CloneZoneList(Config.FARM_ZONES)
            local Deadzones = AICConfig.CloneZoneList(Config.DEADZONES)
        
            --// Backwards compatibility with the existing place_config format.
            if #FarmZones == 0 and Config.FARM_CENTER then
                table.insert(FarmZones, {
                    Center = AICConfig.DecodeVector3(Config.FARM_CENTER),
                    Radius = math.max(0, tonumber(Config.FARM_RADIUS) or 0),
                })
            end
        
            if #Deadzones == 0 and Config.FARM_DEADZONE_CENTER then
                local Radius = tonumber(Config.FARM_DEADZONE_RADIUS) or 0
        
                if Radius > 0 then
                    table.insert(Deadzones, {
                        Center = AICConfig.DecodeVector3(Config.FARM_DEADZONE_CENTER),
                        Radius = Radius,
                    })
                end
            end
        
            local FirstFarm = FarmZones[1]
            local FirstDeadzone = Deadzones[1]
        
            Config.WAYPOINTS = Waypoints
            --// Seconds to stand at each waypoint before moving on, one entry per
            --// waypoint. Padded with 0 and trimmed so it always lines up.
            Config.WAYPOINT_WAITS = AICConfig.NormalizeWaitList(Config.WAYPOINT_WAITS, #Waypoints)
            --// Whether to jump on reaching each waypoint, one entry per
            --// waypoint, padded with false.
            Config.WAYPOINT_JUMPS = AICConfig.NormalizeJumpList(Config.WAYPOINT_JUMPS, #Waypoints)
            Config.FARM_ZONES = FarmZones
            --// Farm zone paired with each waypoint for the waypoint loop, one
            --// entry per waypoint. 0 means the waypoint has no zone.
            Config.WAYPOINT_ZONES = AICConfig.NormalizeZonePairs(Config.WAYPOINT_ZONES, #Waypoints, #FarmZones)
            Config.DEADZONES = Deadzones
            --// Auto Mining only mines ores inside one of these.
            Config.MINE_ZONES = AICConfig.CloneZoneList(Config.MINE_ZONES)
            --// Boss Route stops (BossNavigator): a spot to stand on per boss,
            --// with its own teleport, wait and reset timers. Kept apart from
            --// WAYPOINTS so neither route moves the other.
            Config.BOSS_ROUTE = AICConfig.NormalizeBossStops(Config.BOSS_ROUTE)
            --// Where the chosen smithing table stands, or nil for "nearest".
            --// A position, not the table's Id, which may differ per server.
            Config.SMITH_TABLE = Config.SMITH_TABLE ~= nil
                and AICConfig.DecodeVector3(Config.SMITH_TABLE)
                or nil

            --// Legacy aliases remain available to old code while the actual logic
            --// supports multiple zones.
            --// Do not manufacture Vector3.zero when a zone does not exist.
            --// Missing zones stay nil so farm logic never treats (0, 0, 0) as a real zone.
            Config.FARM_CENTER = FirstFarm and FirstFarm.Center or nil
            Config.FARM_RADIUS = FirstFarm and FirstFarm.Radius or nil
            Config.FARM_DEADZONE_CENTER = FirstDeadzone and FirstDeadzone.Center or nil
            Config.FARM_DEADZONE_RADIUS = FirstDeadzone and FirstDeadzone.Radius or nil
        
            Config.REACH_DISTANCE = tonumber(Config.REACH_DISTANCE) or 5
            Config.AUTOBLOCK = Config.AUTOBLOCK == true
        
            return Config
        end
        
        --// Longest a waypoint may hold the character, so a typo cannot park
        --// the bot for hours.
        AICConfig.MAX_WAYPOINT_WAIT = 600

        function AICConfig.NormalizeWaitList(List, Count)
            local Result = {}

            for Index = 1, Count do
                local Value = type(List) == "table" and tonumber(List[Index]) or 0
                Result[Index] = math.clamp(Value or 0, 0, AICConfig.MAX_WAYPOINT_WAIT)
            end

            return Result
        end

        function AICConfig.NormalizeJumpList(List, Count)
            local Result = {}

            for Index = 1, Count do
                Result[Index] = type(List) == "table" and List[Index] == true
            end

            return Result
        end

        --// A Jump waypoint is reached only this close (studs, flat), so the
        --// jump goes off at the edge it was placed on rather than Reach
        --// Distance short of it.
        AICConfig.JUMP_WAYPOINT_REACH = 1.5

        --// Whether the character should jump now that it is at waypoint
        --// Index: it is a Jump waypoint and close enough. Returns IsJump,
        --// Reached. A non-jump waypoint returns false, nil (use Reach).
        function AICConfig.CheckJumpWaypoint(Config, Index, HorizontalDistance)
            if not (Config.WAYPOINT_JUMPS and Config.WAYPOINT_JUMPS[Index]) then
                return false, nil
            end

            return true, HorizontalDistance <= AICConfig.JUMP_WAYPOINT_REACH
        end

        function AICConfig.NormalizeZonePairs(List, Count, ZoneCount)
            local Result = {}

            for Index = 1, Count do
                local Value = math.floor(type(List) == "table" and tonumber(List[Index]) or 0)
                Result[Index] = (Value >= 1 and Value <= ZoneCount) and Value or 0
            end

            return Result
        end

        --// Target names a farm zone fights; empty means the Enemy Priority list.
        function AICConfig.CloneTargetList(List)
            local Result = {}

            for _, Name in ipairs(type(List) == "table" and List or {}) do
                if type(Name) == "string" and Name ~= "" and not table.find(Result, Name) then
                    table.insert(Result, Name)
                end
            end

            return Result
        end

        --// Boss Route limits. The defaults are what a new stop starts with:
        --// fight until the boss is down, then reset and move on. Wait After
        --// Reset gives the new character time to load, and the engage radius
        --// reaches across a boss room from the standing spot. A stop's Path is
        --// the travel points walked before it; there is no fight timer, so a
        --// stop only ever resets after the kill.
        AICConfig.DEFAULT_BOSS_RADIUS = 120
        --// Held at the corpse before a reset that would actually lose EXP.
        --// A reset that would not is not held at all, whatever this says.
        AICConfig.DEFAULT_BOSS_RESET_WAIT = 10
        AICConfig.MAX_BOSS_PATH = 64
        AICConfig.MAX_BOSS_RESET = 600
        AICConfig.MAX_BOSS_RADIUS = 500
        AICConfig.MAX_BOSS_WAYPOINT = 999
        --// How far from the boss the skill dodge settles. Small enough to be a
        --// step out of a skill rather than a run across the room; a stop can
        --// set its own in "Dodge Distance".
        AICConfig.DEFAULT_BOSS_DODGE_DISTANCE = 16
        AICConfig.MIN_BOSS_DODGE_DISTANCE = 6
        AICConfig.MAX_BOSS_DODGE_DISTANCE = 80

        --// Saved travel points for one boss stop, in the order walked.
        function AICConfig.NormalizeBossPath(List)
            local Result = {}

            for _, Point in ipairs(type(List) == "table" and List or {}) do
                if #Result >= AICConfig.MAX_BOSS_PATH then
                    break
                end

                if typeof(Point) == "Vector3" then
                    table.insert(Result, AICConfig.RoundVector3(Point))
                elseif type(Point) == "table" then
                    table.insert(Result, AICConfig.DecodeVector3(Point))
                end
            end

            return Result
        end

        --// One stop of the Boss Route (BossNavigator). Position is the spot
        --// the character stands on; a stop without one is dropped, so a
        --// half-written save cannot leave an unwalkable row.
        --//   Label       shown in the list
        --//   Targets     boss entity names; empty fights anything at the spot
        --//   Path        points walked in order on the way to Position
        --//   Waypoint    game waypoint number teleported to first, 0 walks
        --//   ResetAfterKill  reset once the boss is down, then the next stop
        --//   ResetWait   seconds held at the corpse before that reset
        --//   WaitExp     hold the next stop until EXP actually dropped
        --//   Radius      how far from Position a boss is picked up
        --//   Dodge       sprint out of the boss's skill while it is casting
        --//   DodgeDistance  how far from the boss that dodge settles
        --//   Prompt      travel by teleporting to PromptPosition first
        --//   PromptPosition  where that interaction prompt stands
        --//   PromptName  its name, for the editor and the status line
        function AICConfig.NormalizeBossStops(List)
            local Result = {}

            for _, Stop in ipairs(type(List) == "table" and List or {}) do
                local Position = type(Stop) == "table" and Stop.Position or nil

                if typeof(Position) == "Vector3" then
                    Position = AICConfig.RoundVector3(Position)
                elseif type(Position) == "table" then
                    Position = AICConfig.DecodeVector3(Position)
                else
                    Position = nil
                end

                if Position then
                    local Label = type(Stop.Label) == "string" and Stop.Label:gsub("^%s*(.-)%s*$", "%1") or ""
                    --// Where the interaction prompt of this stop stands, saved
                    --// from the button in Edit Boss Stop. Rounded like any
                    --// other point, so a save cannot drift it.
                    local PromptPosition = Stop.PromptPosition

                    if typeof(PromptPosition) == "Vector3" then
                        PromptPosition = AICConfig.RoundVector3(PromptPosition)
                    elseif type(PromptPosition) == "table" then
                        PromptPosition = AICConfig.DecodeVector3(PromptPosition)
                    else
                        PromptPosition = nil
                    end

                    local PromptName = type(Stop.PromptName) == "string"
                        and string.sub(Stop.PromptName:gsub("^%s*(.-)%s*$", "%1"), 1, 64)
                        or ""
                    --// Stops saved before Reset After Kill existed: they were
                    --// written with the old 10 s timeout and never reset after
                    --// a kill. Treat them as the new default, fight until the
                    --// boss is down and then reset.
                    local Legacy = Stop.ResetAfterKill == nil

                    table.insert(Result, {
                        Label = Label ~= "" and Label or ("Boss " .. tostring(#Result + 1)),
                        Position = Position,
                        Path = AICConfig.NormalizeBossPath(Stop.Path),
                        Targets = AICConfig.CloneTargetList(Stop.Targets),
                        Waypoint = math.clamp(
                            math.floor(tonumber(Stop.Waypoint) or 0), 0, AICConfig.MAX_BOSS_WAYPOINT
                        ),
                        ResetAfterKill = Legacy or Stop.ResetAfterKill == true,
                        --// Saves made before v3.36 kept the fight timeout in
                        --// ResetAfter; that number is the pause at the corpse
                        --// now, so a wait the user had set keeps working.
                        ResetWait = math.clamp(
                            tonumber(Stop.ResetWait) or tonumber(Stop.ResetAfter)
                                or AICConfig.DEFAULT_BOSS_RESET_WAIT,
                            0,
                            AICConfig.MAX_BOSS_RESET
                        ),
                        WaitExp = Stop.WaitExp == true,
                        --// Default on: a boss skill is worth stepping out of
                        --// until the stop says otherwise.
                        Dodge = Stop.Dodge ~= false,
                        DodgeDistance = math.clamp(
                            tonumber(Stop.DodgeDistance) or AICConfig.DEFAULT_BOSS_DODGE_DISTANCE,
                            AICConfig.MIN_BOSS_DODGE_DISTANCE,
                            AICConfig.MAX_BOSS_DODGE_DISTANCE
                        ),
                        --// On with nothing saved is allowed: the nearest prompt
                        --// to the stop is found at run time.
                        Prompt = Stop.Prompt == true,
                        PromptPosition = PromptPosition,
                        PromptName = PromptName,
                        Radius = math.clamp(
                            tonumber(Stop.Radius) or AICConfig.DEFAULT_BOSS_RADIUS,
                            1,
                            AICConfig.MAX_BOSS_RADIUS
                        ),
                    })
                end
            end

            return Result
        end

        --// Rewrites waypoint->zone pairs after farm zones are removed or
        --// reordered. Map(oldIndex) returns the new index, or 0 if gone.
        function AICConfig.RemapWaypointZones(Config, Map)
            local Pairs = Config.WAYPOINT_ZONES or {}

            for Index, ZoneIndex in ipairs(Pairs) do
                if ZoneIndex > 0 then
                    Pairs[Index] = Map(ZoneIndex) or 0
                end
            end

            Config.WAYPOINT_ZONES = Pairs
        end

        --// Every stored position keeps two decimal places. Raw floats like
        --// 1773.4182739257812 bloat the save and the export text for no
        --// precision anyone can walk to.
        AICConfig.VECTOR_DECIMALS = 2

        function AICConfig.RoundNumber(Value)
            local Scale = 10 ^ AICConfig.VECTOR_DECIMALS
            return math.round((tonumber(Value) or 0) * Scale) / Scale
        end

        function AICConfig.RoundVector3(Value)
            return Vector3.new(
                AICConfig.RoundNumber(Value.X),
                AICConfig.RoundNumber(Value.Y),
                AICConfig.RoundNumber(Value.Z)
            )
        end

        function AICConfig.EncodeVector3(Value)
            if typeof(Value) ~= "Vector3" then
                return { X = 0, Y = 0, Z = 0 }
            end

            return {
                X = AICConfig.RoundNumber(Value.X),
                Y = AICConfig.RoundNumber(Value.Y),
                Z = AICConfig.RoundNumber(Value.Z),
            }
        end

        function AICConfig.DecodeVector3(Value)
            if typeof(Value) == "Vector3" then
                return AICConfig.RoundVector3(Value)
            end

            if type(Value) ~= "table" then
                return Vector3.zero
            end

            return AICConfig.RoundVector3(Vector3.new(
                tonumber(Value.X) or 0,
                tonumber(Value.Y) or 0,
                tonumber(Value.Z) or 0
            ))
        end
        
        function AICConfig.CloneVectorList(List)
            local Result = {}
        
            for _, Value in ipairs(List or {}) do
                table.insert(Result, AICConfig.DecodeVector3(Value))
            end
        
            return Result
        end
        
        function AICConfig.CloneZoneList(List)
            local Result = {}
        
            for _, Zone in ipairs(List or {}) do
                if type(Zone) == "table" and Zone.Center then
                    table.insert(Result, {
                        Center = AICConfig.DecodeVector3(Zone.Center),
                        Radius = math.max(0, tonumber(Zone.Radius) or 0),
                        Targets = AICConfig.CloneTargetList(Zone.Targets),
                    })
                end
            end
        
            return Result
        end
        
        function AICConfig.SerializeVectorList(List)
            local Result = {}
        
            for _, Value in ipairs(List or {}) do
                table.insert(Result, AICConfig.EncodeVector3(Value))
            end
        
            return Result
        end
        
        function AICConfig.SerializeZoneList(List)
            local Result = {}
        
            for _, Zone in ipairs(List or {}) do
                if Zone and Zone.Center then
                    table.insert(Result, {
                        Center = AICConfig.EncodeVector3(Zone.Center),
                        Radius = tonumber(Zone.Radius) or 0,
                        Targets = AICConfig.CloneTargetList(Zone.Targets),
                    })
                end
            end
        
            return Result
        end
        
        
        
        
        ------------------------------------------------------------------------
        ------------------------------------------------------------------------
        --// AICCombatUtils
        --//
        --// geometry, world queries, blade maths, movement primitives
        --//
        --// Definitions only; nothing here runs at load time.
        ------------------------------------------------------------------------

        --// Real stuck detection: barely moving while actively trying to move.
        --// Two consecutive samples prevent a single frame against a corner
        --// from counting as stuck.
        local Runtime = {}

        function Runtime:GetCharacter()
            -- Refresh from Player if character was destroyed or never set
            if not Character or not Character.Parent then
                Character = Player.Character
                Humanoid = Character and Character:FindFirstChildOfClass("Humanoid") or nil
                RootPart = Character and Character:FindFirstChild("HumanoidRootPart") or nil
            elseif not Humanoid or not Humanoid.Parent then
                Humanoid = Character:FindFirstChildOfClass("Humanoid")
            end
            if Character and Character.Parent and (not RootPart or not RootPart.Parent) then
                RootPart = Character:FindFirstChild("HumanoidRootPart")
            end
            return Character, Humanoid, RootPart
        end

        function Runtime:SetCharacter(NewCharacter, NewHumanoid, NewRootPart)
            Character = NewCharacter
            Humanoid = NewHumanoid
            RootPart = NewRootPart
        end

        function Runtime:SetInputBindableFunction(Value)
            InputBindableFunction = Value
        end

        function Runtime:GetInputBindableFunction()
            return InputBindableFunction
        end

        --// The game's Interact input is left alone for a moment after a script
        --// teleport. A prompt teleport lands the character on the prompt
        --// itself, so pressing on the way out fires the same door again -- and
        --// a door that teleports the character keeps re-firing for as long as
        --// the presses go out. Every presser (Auto Farm, Boss Route) asks
        --// this, so a teleport from any tab mutes them all.
        local InteractMutedUntil = 0

        function Runtime:MuteInteract(Seconds)
            local UntilTime = os.clock() + math.max(tonumber(Seconds) or 0, 0)

            if UntilTime > InteractMutedUntil then
                InteractMutedUntil = UntilTime
            end
        end

        function Runtime:IsInteractMuted()
            return os.clock() < InteractMutedUntil
        end

        function Runtime:GetFaceOrientation()
            return FaceOrientation
        end

        function Runtime:SetFaceOrientation(Value)
            FaceOrientation = Value
        end

        function Runtime:GetPlaceConfig()
            return PlaceConfig
        end

        function Runtime:SetPlaceConfig(Value)
            PlaceConfig = Value
        end

        function Runtime:GetBasePlaceConfig()
            return BasePlaceConfig
        end

        function Runtime:SetBasePlaceConfig(Value)
            BasePlaceConfig = Value
        end

        Context.Services = {
            Players = Players,
            Replicated = Replicated,
            StarterGui = StarterGui,
            RunService = RunService,
            UserInputService = UserInputService,
            MarketplaceService = MarketplaceService,
            PathfindingService = PathfindingService,
            HttpService = HttpService,
        }
        Context.Player = Player
        Context.PlayerGui = PlayerGui
        Context.CONFIG = CONFIG
        Context.AICConfig = AICConfig
        Context.AICProfile = AICProfile
        Context.AICCombatUtils = AICCombatUtils
        Context.AICCombat = AICCombat
        Context.AICFeature = AICFeature
        Context.AICUI = AICUI
        Context.AICDebug = AICDebug
        Context.Feature = Feature
        Context.MiningFeature = MiningFeature
        Context.UI = UI
        Context.UIRef = UIRef
        Context.NotifyAction = NotifyAction
        Context.PatrolState = PatrolState
        -- Seed character handles so GetCharacter works before first updateCharacter()
        Character = Player.Character
        if Character then
            Humanoid = Character:FindFirstChildOfClass("Humanoid")
            RootPart = Character:FindFirstChild("HumanoidRootPart")
        end

        --// Resolve the place config here, before any other module starts.
        --// ProfileManager, Farmzone, Waypoints and AutoBlock read it while
        --// they build, so it cannot wait for Bootstrap.
        PlaceConfig = AICConfig.NormalizePlaceConfig(AICConfig.IsValidPlace(game.PlaceId) or {})
        BasePlaceConfig = AICConfig.NormalizePlaceConfig(AICConfig.IsValidPlace(game.PlaceId) or {})
        CONFIG.TARGET_ENTITY_PRIORITY = PlaceConfig.DEFAULT_TARGET_PRIORITY or {}
        Context.PLACE_CONFIG = PlaceConfig

        Context.Runtime = Runtime
        Context.DEBUG_COLORS = DEBUG_COLORS

        --// Init stores whatever Start returns as Context.Runtime, so this has
        --// to be the Runtime object. Returning Context replaced Runtime with
        --// Context and every Runtime:GetX() call failed.
        return Runtime
    end,
}
