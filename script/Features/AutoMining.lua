-- AutoMining mines ores inside the mine zones once the waypoint route has
-- been walked. AutoFarming hands it the frame through AICFeature.MiningStep
-- before its own Return To Farm Zone and combat, and falls back to farming
-- whenever there is nothing to mine.
--
--   * Ores are mined in the Ore Priority order. Each one is mined until the
--     inventory holds its Target (at most ITEM_MAX_STACK); what is
--     already carried counts, so 250 held of a 500 target leaves 250 to go.
--   * The highest priority ore with an available node in a mine zone wins;
--     when none of its nodes are up (taken, regenerating, unreachable) the
--     next ore in the list is mined instead.
--   * Ores outside every mine zone, or inside a deadzone, are never targets.
--   * Walking is WalkController's job. Within CLAIM_DISTANCE the ore is
--     claimed and the character holds still until the mining cooldown ends.
--   * Anything within DEFEND_RANGE while a job is on is fought: the weapon is
--     drawn and it is hit once in range. While claiming or mining, WalkSpeed
--     is held at 0, so the character never steps off the spot.
--   * Each ore shows its state on a billboard through the Debug Visualizer
--     ("Debug Ore Status").
--
-- The Auto Mining section of the Mining tab is built here too (end of the
-- file); the walking is WalkController's.
return {
    Name = "AutoMining",
    IsFeature = true,
    Dependencies = {"Runtime", "SaveConfig", "ProfileManager", "Components", "CombatUtils", "Navigation", "Combat", "DebugVisualizer", "WalkController", "Minezone"},

    Start = function(Context)
        local SaveConfig = Context.SaveConfig
        local Runtime = Context.Runtime
        local Player = Context.Player
        local Replicated = Context.Services.Replicated
        local CONFIG = Context.CONFIG
        local FeatureState = Context.Feature
        local AICCombatUtils = Context.AICCombatUtils
        local AICCombat = Context.AICCombat
        local AICFeature = Context.AICFeature
        local AICUI = Context.AICUI
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction
        local DEBUG_COLORS = Context.DEBUG_COLORS
        local Movement = Context.WalkController

        local MAX_STACK = SaveConfig.ITEM_MAX_STACK

        --// Re-pick the target this often while walking, so a higher
        --// priority node that regenerates is taken over a lower one.
        local SCAN_INTERVAL = 0.5
        --// The claim is accepted from this far away.
        local CLAIM_DISTANCE = 15
        --// Only an enemy this close is fought.
        local DEFEND_RANGE = 10
        --// WalkSpeed is held at 0 while claiming or mining, so nothing walks
        --// the character away from the node (the game cancels mining, and
        --// can kick, when it is too far). Step not running for this long
        --// (Auto Farm switched off mid-mining) gives the speed back.
        local STEP_STALE_SECONDS = 0.5
        --// Give up on a node not reached in this long.
        local APPROACH_TIMEOUT = 15
        --// A node given up on is skipped for this long.
        local UNREACHABLE_SECONDS = 30
        --// A claim that has not answered by then is dropped.
        local CLAIM_TIMEOUT = 10
        --// Someone else's name on the node after this long means we lost it.
        local CLAIM_CONFIRM_SECONDS = 1
        --// Added to the game's mining cooldown so the node is never left early.
        local COOLDOWN_PADDING = 0.15
        local FALLBACK_COOLDOWN = 20
        --// Stand this far in front of the ore, measured from its surface.
        local APPROACH_STANDOFF = 3
        local STATUS_INTERVAL = 0.25
        local BILLBOARD_INTERVAL = 0.3
        local BILLBOARD_RANGE = 150
        local ORE_PICKER_REFRESH_DELAY = 1
        local NO_ORES_OPTION = "No ores found"

        local Feature = {
            Name = "AutoMining",
            IsFeature = true,
            S = {
                --// "Idle", "Approach", "Claiming" or "Mining".
                State = "Idle",
                --// Bumped whenever the job ends, so a claim answering late
                --// cannot revive it.
                Token = 0,
                Ore = nil,
                Core = nil,
                Owner = nil,
                Id = nil,
                Priority = nil,
                ApproachPoint = nil,
                ApproachStart = 0,
                ClaimStart = 0,
                MineUntil = 0,
                Defending = nil,
                LastScan = 0,
                Unreachable = {},
                Nodes = {},
                MaterialsFolder = nil,
                MaterialConnections = {},
                Commons = nil,
                CommonsLoaded = false,
                LastStatus = 0,
                LastBillboards = 0,
                BillboardsShown = false,
                WarnedNoRemote = false,
                LastStep = 0,
                --// The humanoid held at WalkSpeed 0, and its speed before.
                LockedHumanoid = nil,
                SavedWalkSpeed = nil,
            },
        }

        local S = Feature.S

        ------------------------------------------------------------------------
        --// Ore nodes
        ------------------------------------------------------------------------

        --// Core, Owner, Id of a mineable node, or nil when the model is not one.
        local function GetNodeParts(Model)
            if not Model.Parent then
                return nil
            end

            local Core = Model:FindFirstChild("Core")
            local Owner = Model:FindFirstChild("Owner")
            local Id = Model:FindFirstChild("Id")

            if not Core or not Core:IsA("BasePart")
                or not Owner or not Owner:IsA("StringValue")
                or not Id or not Id:IsA("NumberValue")
            then
                return nil
            end

            return Core, Owner, Id
        end

        local function IsDepleted(Core)
            return Core.Transparency >= 1
        end

        local function IsTakenByOther(Owner)
            return Owner.Value ~= "" and Owner.Value ~= Player.Name
        end

        --// Nodes are tracked by ChildAdded/ChildRemoved instead of listing
        --// the folder on every scan. The folder can be replaced, so it is
        --// re-resolved and re-watched when that happens.
        local function WatchMaterials()
            local Folder = workspace:FindFirstChild("Materials")

            if Folder == S.MaterialsFolder then
                return
            end

            for _, Connection in ipairs(S.MaterialConnections) do
                Connection:Disconnect()
            end

            table.clear(S.MaterialConnections)
            table.clear(S.Nodes)
            S.MaterialsFolder = Folder

            if not Folder then
                return
            end

            for _, Child in ipairs(Folder:GetChildren()) do
                if Child:IsA("Model") then
                    S.Nodes[Child] = true
                end
            end

            table.insert(S.MaterialConnections, Folder.ChildAdded:Connect(function(Child)
                if Child:IsA("Model") then
                    S.Nodes[Child] = true

                    --// A burst of streamed-in nodes makes one rebuild.
                    if not S.OrePickerQueued and AICUI.RefreshOrePicker then
                        S.OrePickerQueued = true

                        task.delay(ORE_PICKER_REFRESH_DELAY, function()
                            S.OrePickerQueued = false
                            AICUI.RefreshOrePicker()
                        end)
                    end
                end
            end))

            table.insert(S.MaterialConnections, Folder.ChildRemoved:Connect(function(Child)
                S.Nodes[Child] = nil
                S.Unreachable[Child] = nil
            end))
        end

        --// Unique ore names currently loaded, sorted.
        local function GetLoadedOreNames()
            local Seen = {}
            local Names = {}

            for Model in pairs(S.Nodes) do
                if not Seen[Model.Name] and GetNodeParts(Model) then
                    Seen[Model.Name] = true
                    table.insert(Names, Model.Name)
                end
            end

            table.sort(Names)
            return Names
        end

        ------------------------------------------------------------------------
        --// Targets and inventory
        ------------------------------------------------------------------------

        local function GetInventoryCount(Name)
            local PlayerStats = Player:FindFirstChild("PlayerStats")
            local Inventory = PlayerStats and PlayerStats:FindFirstChild("Inventory")

            if not Inventory then
                return 0
            end

            local _, Amount = AICUI.GetItem(Inventory.Value, Name)
            return Amount
        end

        --// Ore name -> { Priority, Target, Have, Remaining }, recomputed per
        --// call so it always follows the inventory.
        local function GetOrePlan()
            local Plan = {}

            for Priority, Entry in ipairs(CONFIG.MINE_ORES or {}) do
                local Target = math.clamp(tonumber(Entry.Target) or MAX_STACK, 0, MAX_STACK)
                local Have = GetInventoryCount(Entry.Name)

                Plan[Entry.Name] = {
                    Priority = Priority,
                    Target = Target,
                    Have = Have,
                    Remaining = math.max(0, Target - Have),
                }
            end

            return Plan
        end

        local function CanMineAt(Position)
            return AICCombatUtils.IsInsideMineZone(Position)
                and (FeatureState.IgnoreFarmZone.Enabled or not AICCombatUtils.IsInsideFarmDeadzone(Position))
        end

        local function IsAvailable(Model, Core, Owner, now)
            return not IsDepleted(Core)
                and not IsTakenByOther(Owner)
                and (S.Unreachable[Model] or 0) <= now
                and CanMineAt(Core.Position)
        end

        --// Highest priority ore with work left and a free node; the nearest
        --// node of that ore. Returns the model and its priority.
        local function FindTargetOre(now, RootPart)
            local Plan = GetOrePlan()
            local Best, BestPriority, BestDistance = nil, math.huge, math.huge

            for Model in pairs(S.Nodes) do
                local Entry = Plan[Model.Name]

                if Entry and Entry.Remaining > 0 and Entry.Priority <= BestPriority then
                    local Core, Owner = GetNodeParts(Model)

                    if Core and IsAvailable(Model, Core, Owner, now) then
                        local Distance = (Core.Position - RootPart.Position).Magnitude

                        if Entry.Priority < BestPriority or Distance < BestDistance then
                            Best, BestPriority, BestDistance = Model, Entry.Priority, Distance
                        end
                    end
                end
            end

            return Best, Best and BestPriority or nil
        end

        ------------------------------------------------------------------------
        --// Game hooks
        ------------------------------------------------------------------------

        local function GetCommons()
            if not S.CommonsLoaded then
                S.CommonsLoaded = true

                local Module = Replicated:FindFirstChild("CoreCommons", true)
                local Ok, Commons = pcall(function()
                    return Module and require(Module)
                end)

                S.Commons = Ok and type(Commons) == "table" and Commons or nil
            end

            return S.Commons
        end

        --// The game's own cooldown for this kind of node, padded.
        local function GetCooldown(Ore)
            local Commons = GetCommons()

            if not Commons then
                return FALLBACK_COOLDOWN
            end

            local Cooldown = (Ore:FindFirstChild("Ore") and Commons.MINE_ORE_COOLDOWN)
                or (Ore:FindFirstChild("Tree") and Commons.MINE_TREE_COOLDOWN)
                or (Ore:FindFirstChild("Plant") and Commons.MINE_PLANT_COOLDOWN)

            return tonumber(Cooldown) and Cooldown + COOLDOWN_PADDING or FALLBACK_COOLDOWN
        end

        local function GetClaimRemote()
            local Remote = Replicated:FindFirstChild("ClaimMaterial", true)
            return Remote and Remote:IsA("RemoteFunction") and Remote or nil
        end

        ------------------------------------------------------------------------
        --// Job state
        ------------------------------------------------------------------------

        local function EndJob()
            S.Token += 1
            S.State = "Idle"
            S.Ore = nil
            S.Core = nil
            S.Owner = nil
            S.Id = nil
            S.Priority = nil
            S.ApproachPoint = nil
            Movement:Reset()
        end

        local function MarkUnreachable(Ore, now)
            if Ore then
                S.Unreachable[Ore] = now + UNREACHABLE_SECONDS
            end

            EndJob()
            --// Next node on the next frame, not after a scan interval.
            S.LastScan = 0
        end

        local function StartJob(Ore, Priority, now)
            local Core, Owner, Id = GetNodeParts(Ore)

            EndJob()
            S.State = "Approach"
            S.Ore = Ore
            S.Core = Core
            S.Owner = Owner
            S.Id = Id
            S.Priority = Priority
            S.ApproachStart = now
            S.ApproachPoint = Movement:GetApproachPoint(Core, APPROACH_STANDOFF, Ore)
        end

        --// Picks or re-picks the node while not committed to one.
        local function UpdateTarget(now, RootPart)
            local CurrentValid = S.Ore ~= nil
                and GetNodeParts(S.Ore) ~= nil
                and IsAvailable(S.Ore, S.Core, S.Owner, now)

            --// A node gone bad is replaced at once. With no job at all the
            --// scan still waits its turn: rescanning every node every frame
            --// with nothing to mine is wasted work.
            if (CurrentValid or S.Ore == nil) and now - S.LastScan < SCAN_INTERVAL then
                return CurrentValid
            end

            S.LastScan = now

            local Best, Priority = FindTargetOre(now, RootPart)

            if not Best then
                --// Idle already: leave the shared walker alone, Auto
                --// Smithing may be using it.
                if S.State ~= "Idle" then
                    EndJob()
                end

                return false
            end

            if Best ~= S.Ore then
                StartJob(Best, Priority, now)
            end

            return true
        end

        local function Claim(now)
            local Remote = GetClaimRemote()

            if not Remote then
                if not S.WarnedNoRemote then
                    S.WarnedNoRemote = true
                    NotifyAction("AUTO MINING", "ClaimMaterial was not found; cannot mine.", 5)
                end

                MarkUnreachable(S.Ore, now)
                return
            end

            S.State = "Claiming"
            S.ClaimStart = now

            local Token = S.Token
            local Ore = S.Ore
            local Id = S.Id.Value

            --// InvokeServer yields, which a heartbeat must never do.
            task.spawn(function()
                local Ok, Error = pcall(function()
                    return Remote:InvokeServer(Id)
                end)

                if Token ~= S.Token then
                    return
                end

                if not Ok then
                    warn("[AutoMining] ClaimMaterial failed:", Error)
                    MarkUnreachable(Ore, os.clock())
                    return
                end

                S.State = "Mining"
                S.MineUntil = os.clock() + GetCooldown(Ore)
            end)
        end

        --// The mining job is over: the cooldown has run, the node is gone,
        --// or someone else ended up owning it. A node that turns transparent
        --// is not treated as done early: the game may hide it as soon as
        --// mining starts, and leaving then could cancel the mining.
        local function IsMiningDone(now)
            return now >= S.MineUntil
                or not GetNodeParts(S.Ore)
                or (now - S.ClaimStart >= CLAIM_CONFIRM_SECONDS and IsTakenByOther(S.Owner))
        end

        ------------------------------------------------------------------------
        --// WalkSpeed lock
        ------------------------------------------------------------------------

        local function ReleaseWalkSpeed()
            local Humanoid = S.LockedHumanoid

            if not Humanoid then
                return
            end

            S.LockedHumanoid = nil

            if Humanoid.Parent and Humanoid.WalkSpeed == 0 then
                Humanoid.WalkSpeed = S.SavedWalkSpeed or 0
            end
        end

        local function LockWalkSpeed(Humanoid)
            if S.LockedHumanoid ~= Humanoid then
                ReleaseWalkSpeed()
                S.LockedHumanoid = Humanoid
                S.SavedWalkSpeed = Humanoid.WalkSpeed
            end

            if Humanoid.WalkSpeed ~= 0 then
                Humanoid.WalkSpeed = 0
            end
        end

        --// Every frame: locked while a job claims or mines a node and Step is
        --// still being run, released otherwise.
        local function UpdateWalkSpeedLock(now)
            local Committed = S.State == "Claiming" or S.State == "Mining"
            local _, Humanoid = Runtime:GetCharacter()

            if Committed and Humanoid and now - S.LastStep <= STEP_STALE_SECONDS then
                LockWalkSpeed(Humanoid)
            else
                ReleaseWalkSpeed()
            end
        end

        AICFeature.IsWalkSpeedLocked = function()
            return S.LockedHumanoid ~= nil
        end

        ------------------------------------------------------------------------
        --// Defence
        ------------------------------------------------------------------------

        local function StopDefending()
            if not S.Defending then
                return
            end

            S.Defending = nil

            local _, Humanoid = Runtime:GetCharacter()
            local FaceOrientation = Runtime:GetFaceOrientation()

            if FaceOrientation then
                FaceOrientation.Enabled = false
            end

            if Humanoid then
                Humanoid.AutoRotate = true
            end
        end

        --// True when an enemy is close and was dealt with this frame.
        local function Defend(now)
            local Threat, Distance = AICCombat.GetNearestThreat()

            if not Threat or Distance > DEFEND_RANGE then
                StopDefending()
                return false
            end

            local ThreatRoot = Threat:FindFirstChild("HumanoidRootPart")
            local InRange = Distance <= AICCombat.GetCombatAttackRange(Threat)
            local Committed = S.State == "Claiming" or S.State == "Mining"
            local CanCloseIn = not Committed and ThreatRoot ~= nil and CanMineAt(ThreatRoot.Position)

            --// Out of reach and off mining ground: it is not in the way, and
            --// waiting on it (a mob idling nearby) would stall mining forever.
            if not InRange and not Committed and not CanCloseIn then
                StopDefending()
                return false
            end

            S.Defending = Threat

            --// Time spent fighting is not time failing to reach the node.
            if S.State == "Approach" then
                S.ApproachStart = now
            end

            --// Drawing the weapon takes the frame.
            if AICFeature.EnsureWeaponDrawn and AICFeature.EnsureWeaponDrawn(now) then
                Movement:Hold()
                return true
            end

            --// Between nodes it closes in, over mining ground only. While
            --// mining it stays on the spot and lets the enemy come.
            if not InRange and CanCloseIn then
                Movement:MoveTo(ThreatRoot.Position, { Ignore = Threat, KeepInsideMine = true })
            else
                Movement:Hold()
            end

            AICCombat.FaceGoblin(Threat)

            if InRange then
                AICCombat.RetreatAttack(Threat, now)
            end

            return true
        end

        ------------------------------------------------------------------------
        --// Step (called by AutoFarming)
        ------------------------------------------------------------------------

        local function Approach(now, RootPart)
            if now - S.ApproachStart > APPROACH_TIMEOUT then
                MarkUnreachable(S.Ore, now)
                return
            end

            if (S.Core.Position - RootPart.Position).Magnitude <= CLAIM_DISTANCE then
                Movement:Hold()
                Claim(now)
                return
            end

            --// Already inside the mine: stay inside on the way to the node.
            local Result = Movement:MoveTo(S.ApproachPoint, {
                Ignore = S.Ore,
                KeepInsideMine = AICCombatUtils.IsInsideMineZone(RootPart.Position),
            })

            if Result == "failed" then
                MarkUnreachable(S.Ore, now)
            end
        end

        local function RunStep(now)
            local _, Humanoid, RootPart = Runtime:GetCharacter()

            if not FeatureState.AutoMining.Enabled or not Humanoid or not RootPart then
                if S.State ~= "Idle" then
                    EndJob()
                end

                StopDefending()
                return false
            end

            WatchMaterials()

            local Committed = S.State == "Claiming" or S.State == "Mining"

            if not Committed and not UpdateTarget(now, RootPart) then
                StopDefending()
                return false
            end

            if Defend(now) then
                return true
            end

            if S.State == "Claiming" then
                Movement:Hold()

                if now - S.ClaimStart > CLAIM_TIMEOUT then
                    MarkUnreachable(S.Ore, now)
                end
            elseif S.State == "Mining" then
                Movement:Hold()

                if IsMiningDone(now) then
                    EndJob()
                    S.LastScan = 0
                end
            else
                Approach(now, RootPart)
            end

            return true
        end

        --// True while mining owns the frame. False hands it back to farming:
        --// mining is off or there is nothing in the zones to mine.
        function Feature.Step(now)
            S.LastStep = now

            local Taken = RunStep(now)
            UpdateWalkSpeedLock(now)
            return Taken
        end

        AICFeature.MiningStep = Feature.Step

        --// Claiming or mining a node: nothing else may walk the character
        --// off it until that is done.
        AICFeature.IsMiningCommitted = function()
            return S.State == "Claiming" or S.State == "Mining"
        end

        ------------------------------------------------------------------------
        --// Status label and ore billboards
        ------------------------------------------------------------------------

        local function GetStatusText(now)
            if not FeatureState.AutoMining.Enabled then
                return "OFF"
            end

            local Name = S.Ore and S.Ore.Name or ""
            local PlaceConfig = Runtime:GetPlaceConfig()
            local Waypoints = PlaceConfig and PlaceConfig.WAYPOINTS or {}

            if not AICFeature.S.Enabled then
                return "WAITING FOR AUTO FARM"
            elseif not FeatureState.AutoFind.Enabled
                and (tonumber(CONFIG.CURRENT_WAYPOINT_TARGET) or 1) <= #Waypoints
            then
                return "WAITING FOR WAYPOINT ROUTE"
            elseif S.Defending then
                return "DEFENDING"
            elseif S.State == "Mining" then
                return string.format("MINING  %s  %.1fs", Name, math.max(0, S.MineUntil - now))
            elseif S.State == "Claiming" then
                return "CLAIMING  " .. Name
            elseif S.State == "Approach" then
                return "WALKING TO  " .. Name
            elseif #(Runtime:GetPlaceConfig().MINE_ZONES or {}) == 0 then
                return "IDLE  //  NO MINE ZONE"
            elseif #(CONFIG.MINE_ORES or {}) == 0 then
                return "IDLE  //  NO ORES IN PRIORITY"
            end

            return "IDLE  //  NOTHING TO MINE"
        end

        --// What one node's billboard says and in which colour.
        local function DescribeNode(Model, Core, Owner, Entry, now)
            if Model == S.Ore then
                if S.State == "Mining" then
                    return string.format("MINING  %.1fs", math.max(0, S.MineUntil - now)), DEBUG_COLORS.OreMining
                end

                return S.State == "Claiming" and "CLAIMING" or "TARGET", DEBUG_COLORS.OreMining
            elseif IsDepleted(Core) then
                return "REGENERATING", DEBUG_COLORS.OreIdle
            elseif IsTakenByOther(Owner) then
                return "TAKEN  " .. Owner.Value, DEBUG_COLORS.OreBlocked
            elseif not AICCombatUtils.IsInsideMineZone(Core.Position) then
                return "OUTSIDE MINE ZONE", DEBUG_COLORS.OreIdle
            elseif not FeatureState.IgnoreFarmZone.Enabled and AICCombatUtils.IsInsideFarmDeadzone(Core.Position) then
                return "IN DEADZONE", DEBUG_COLORS.OreBlocked
            elseif not Entry then
                return "NOT IN PRIORITY", DEBUG_COLORS.OreIdle
            elseif (S.Unreachable[Model] or 0) > now then
                return "UNREACHABLE", DEBUG_COLORS.OreBlocked
            end

            local Count = string.format("%d / %d", Entry.Have, Entry.Target)

            if Entry.Remaining <= 0 then
                return "DONE  " .. Count, DEBUG_COLORS.OreIdle
            end

            return "READY  " .. Count, DEBUG_COLORS.OreReady
        end

        local function UpdateBillboards(now)
            local Wanted = FeatureState.DebugVisualizer.Enabled and FeatureState.DebugOres.Enabled

            if not Wanted then
                if S.BillboardsShown then
                    S.BillboardsShown = false
                    AICDebug.UpdateStatusBillboards("Ores", nil)
                end

                return
            end

            local _, _, RootPart = Runtime:GetCharacter()

            if not RootPart then
                return
            end

            WatchMaterials()

            local Plan = GetOrePlan()
            local Entries = {}

            for Model in pairs(S.Nodes) do
                local Core, Owner = GetNodeParts(Model)

                if Core and (Core.Position - RootPart.Position).Magnitude <= BILLBOARD_RANGE then
                    local Entry = Plan[Model.Name]
                    local Status, Color = DescribeNode(Model, Core, Owner, Entry, now)

                    Entries[Model] = {
                        Core = Core,
                        Title = Entry and string.format("%s  #%d", Model.Name, Entry.Priority) or Model.Name,
                        Status = Status,
                        Color = Color,
                    }
                end
            end

            S.BillboardsShown = true
            AICDebug.UpdateStatusBillboards("Ores", Entries)
        end

        function Feature:Update()
            local now = os.clock()

            UpdateWalkSpeedLock(now)

            if now - S.LastStatus >= STATUS_INTERVAL then
                S.LastStatus = now

                if UIRef.MineStatusLabel then
                    UIRef.MineStatusLabel.Text = "STATUS  " .. GetStatusText(now)
                end
            end

            if now - S.LastBillboards >= BILLBOARD_INTERVAL then
                S.LastBillboards = now
                UpdateBillboards(now)
            end
        end

        Context.Connect(Context.Player.CharacterAdded, function()
            EndJob()
            S.Defending = nil
        end)

        ------------------------------------------------------------------------
        --// Control
        ------------------------------------------------------------------------

        --// Drops the current job. ClearUnreachable also forgets every node
        --// given up on, which a different profile should not inherit.
        function Feature:Reset(ClearUnreachable)
            EndJob()
            StopDefending()

            if ClearUnreachable then
                table.clear(S.Unreachable)
            end
        end

        --// The ore list changed: choose again on the next frame.
        function Feature:Rescan()
            S.LastScan = 0
        end

        function Feature:GetLoadedOreNames()
            WatchMaterials()
            return GetLoadedOreNames()
        end

        --// The ore folder outlives this run, and so does the character:
        --// give its WalkSpeed back if it was held at 0 for mining.
        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(S.MaterialConnections)
            ReleaseWalkSpeed()
        end)

        ------------------------------------------------------------------------
        --// Mining tab
        ------------------------------------------------------------------------

        --// The Auto Mining section: the toggle, the status line, the Ore
        --// Priority list with a Target per ore (saved as MINE_ORES), and the
        --// ways to add an ore.
        local function BuildMineSection(Section)
            local OrePicker = {}

            AICUI.BindFeatureToggle("AutoMining", "Auto Mining", function(Enabled)
                if not Enabled then
                    Feature:Reset()
                elseif #(Runtime:GetPlaceConfig().MINE_ZONES or {}) == 0 then
                    NotifyAction("AUTO MINING", "Add a mine zone first; ores outside one are never mined.", 5)
                end
            end, Section)

            --// Update writes the text.
            UIRef.MineStatusLabel = Section:AddLabel("STATUS  OFF")

            UIRef.OrePriorityComponent = Section:AddPriority("Ore Priority", {}, {
                Values = true,
                ValueLabel = "Target",
                Default = MAX_STACK,
                Min = 0,
                Max = MAX_STACK,
            })

            local OreList = UIRef.OrePriorityComponent

            --// The list is the source of truth while editing; CONFIG follows it.
            local LoadOreList = AICUI.BindCountList(OreList, "MINE_ORES", "Target", function()
                Feature:Rescan()
                AICUI.RefreshOrePicker(true)
            end)

            LoadOreList()

            local function AddOre(Name)
                Name = tostring(Name or ""):gsub("^%s+", ""):gsub("%s+$", "")

                if Name == "" or Name == NO_ORES_OPTION then
                    return
                end

                if not OreList:Add(Name, MAX_STACK) then
                    NotifyAction("AUTO MINING", Name .. " is already in the list")
                    return
                end

                NotifyAction("AUTO MINING", "Added " .. Name)
            end

            --// Loaded ores not yet in the list. Rebuilt only when that set
            --// changes, never while open (unless forced by the user), and in
            --// its old slot, like the target pickers.
            function AICUI.RefreshOrePicker(Force)
                local Options = {}

                for _, Name in ipairs(Feature:GetLoadedOreNames()) do
                    if not table.find(OreList.Priority, Name) then
                        table.insert(Options, Name)
                    end
                end

                if #Options == 0 then
                    Options = { NO_ORES_OPTION }
                end

                AICUI.RefreshDropdown(OrePicker, Section, "Add Ore", Options, AddOre, Force)
            end

            AICUI.RefreshOrePicker(true)

            Section:AddButton("Refresh Ore List", function()
                AICUI.RefreshOrePicker(true)
            end)

            --// For ores not loaded right now (streamed out with distance).
            UIRef.OreNameBox = Section:AddTextbox("Ore Name", "", function() end)

            Section:AddButton("Add Ore By Name", function()
                AddOre(UIRef.OreNameBox:Get())
                UIRef.OreNameBox:Set("")
            end)

            --// Called from updateFeatureButtons on every profile load.
            function AICUI.RefreshMiningUI()
                LoadOreList()
                AICUI.RefreshOrePicker(true)
                AICUI.RefreshMineZoneList()
                AICUI.RefreshMineZonePicker()
                Feature:Reset(true)
            end
        end

        if UIRef.MineSection then
            BuildMineSection(UIRef.MineSection)
        end

        return Feature
    end,
}
