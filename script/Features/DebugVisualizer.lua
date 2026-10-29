return {
    Name = "DebugVisualizer",
    IsFeature = true,
    Dependencies = {"Runtime", "Components"},
    Start = function(Context)
        local Runtime = Context.Runtime
        local Services = Context.Services
        local Players = Services.Players
        local Replicated = Services.Replicated
        local StarterGui = Services.StarterGui
        local RunService = Services.RunService
        local PathfindingService = Services.PathfindingService
        local HttpService = Services.HttpService
        local CONFIG = Context.CONFIG
        local AICProfile = Context.AICProfile
        local AICCombatUtils = Context.AICCombatUtils
        local AICDebug = Context.AICDebug
        local UIRef = Context.UIRef
        local UI = Context.UI
        local FeatureState = Context.Feature
        local DEBUG_COLORS = Context.DEBUG_COLORS
        local Module = Context.AICDebug
        function AICDebug.GetDebugAdorneeParent()
            if not AICCombatUtils.S.DebugFolder then
                AICCombatUtils.S.DebugFolder = Instance.new("Folder")
                AICCombatUtils.S.DebugFolder.Name = "AutoFarmDebug"
                AICCombatUtils.S.DebugFolder.Parent = workspace

                --// Billboard text follows the font picked in Configuration.
                if UI and UI.AddFontRoot then
                    UI:AddFontRoot(AICCombatUtils.S.DebugFolder)
                end
            end
        
            return AICCombatUtils.S.DebugFolder
        end
        function AICDebug.SetDebugVisualizerVisible(Visible)
            if not AICCombatUtils.S.DebugFolder then
                return
            end
        
            AICCombatUtils.S.DebugFolder.Parent = Visible and workspace or nil
        end
        function AICDebug.CreateDebugZone(Name, Center, Radius, Color, ZoneType, Index)
            if not Center or not Radius or Radius <= 0 then
                return nil
            end
        
            local ZoneFolder = Instance.new("Folder")
            ZoneFolder.Name = Name
            ZoneFolder.Parent = AICDebug.GetDebugAdorneeParent()
        
            --// Radius ring.
            local Ring = Instance.new("Part")
            Ring.Name = "Radius"
            Ring.Anchored = true
            Ring.CanCollide = false
            Ring.CanTouch = false
            Ring.CanQuery = false
            Ring.CastShadow = false
            Ring.Transparency = 0.35
            Ring.Material = Enum.Material.Neon
            Ring.Color = Color
            Ring.Shape = Enum.PartType.Cylinder
            Ring.Size = Vector3.new(CONFIG.DEBUG_ZONE_HEIGHT, Radius * 2, Radius * 2)
            Ring.CFrame = CFrame.new(Center + Vector3.new(0, -2, 0)) * CFrame.Angles(0, 0, math.rad(90))
            Ring.Parent = ZoneFolder
        
            local Surface = Instance.new("Part")
            Surface.Name = "Surface"
            Surface.Anchored = true
            Surface.CanCollide = false
            Surface.CanTouch = false
            Surface.CanQuery = false
            Surface.CastShadow = false
            Surface.Transparency = 0.94
            Surface.Material = Enum.Material.SmoothPlastic
            Surface.Color = Color
            Surface.Shape = Enum.PartType.Cylinder
            Surface.Size = Vector3.new(0.04, Radius * 2, Radius * 2)
            Surface.CFrame = CFrame.new(Center + Vector3.new(0, -2, 0)) * CFrame.Angles(0, 0, math.rad(90))
            Surface.Parent = ZoneFolder
        
            local Highlight = Instance.new("Highlight")
            Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            Highlight.FillColor = Color
            Highlight.FillTransparency = 0.5
            Highlight.OutlineTransparency = 1
            Highlight.Adornee = Ring
            Highlight.Parent = Ring
        
            --// Center marker + billboard so each radius can be identified in-world.
            local Marker = Instance.new("Part")
            Marker.Name = "Center"
            Marker.Anchored = true
            Marker.CanCollide = false
            Marker.CanTouch = false
            Marker.CanQuery = false
            Marker.CastShadow = false
            Marker.Transparency = 1
            Marker.Size = Vector3.new(0.5, 0.5, 0.5)
            Marker.Position = Center + Vector3.new(0, 0.15, 0)
            Marker.Parent = ZoneFolder
        
            local Billboard = Instance.new("BillboardGui")
            Billboard.Name = "RadiusBillboard"
            Billboard.Adornee = Marker
            Billboard.AlwaysOnTop = true
            Billboard.LightInfluence = 0
            Billboard.MaxDistance = 180
            Billboard.Size = UDim2.fromScale(4.2, 1.25)
            Billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.0, 0)
            Billboard.Enabled = FeatureState.DebugRadiusLabels.Enabled
            Billboard.Parent = Marker
        
            local Container = Instance.new("Frame")
            Container.BackgroundColor3 = DEBUG_COLORS.BillboardPanel
            Container.BackgroundTransparency = 0.05
            Container.BorderSizePixel = 0
            Container.Size = UDim2.fromScale(1, 1)
            Container.Parent = Billboard
        
            local Corner = Instance.new("UICorner")
            Corner.CornerRadius = UDim.new(0, 3)
            Corner.Parent = Container
        
            local Stroke = Instance.new("UIStroke")
            Stroke.Color = Color
            Stroke.Thickness = 1
            Stroke.Transparency = 0.1
            Stroke.Parent = Container
        
            local Label = Instance.new("TextLabel")
            Label.BackgroundTransparency = 1
            Label.Size = UDim2.fromScale(1, 0.52)
            Label.Position = UDim2.fromScale(0, 0.03)
            Label.Font = UI.Fonts.Regular
            Label.Text = string.format("%s #%02d", ZoneType or "ZONE", Index or 0)
            Label.TextColor3 = DEBUG_COLORS.BillboardText
            Label.TextScaled = true
            Label.Parent = Container
        
            local RadiusLabel = Instance.new("TextLabel")
            RadiusLabel.BackgroundTransparency = 1
            RadiusLabel.Size = UDim2.fromScale(1, 0.4)
            RadiusLabel.Position = UDim2.fromScale(0, 0.55)
            RadiusLabel.Font = UI.Fonts.Regular
            RadiusLabel.Text = string.format("RADIUS  %.0f", Radius)
            RadiusLabel.TextColor3 = DEBUG_COLORS.BillboardMuted
            RadiusLabel.TextScaled = true
            RadiusLabel.Parent = Container
        
            return ZoneFolder
        end
        function AICDebug.CreateDebugWaypoint(Index, Position)
            local MarkerPart = Instance.new("Part")
            MarkerPart.Name = "Waypoint_" .. Index
            MarkerPart.Anchored = true
            MarkerPart.CanCollide = false
            MarkerPart.CanTouch = false
            MarkerPart.CanQuery = false
            MarkerPart.CastShadow = false
            MarkerPart.Transparency = 1
            MarkerPart.Size = Vector3.new(1, 1, 1)
            MarkerPart.Position = Position + Vector3.new(0, 0.1, 0)
            MarkerPart.Parent = AICDebug.GetDebugAdorneeParent()
        
            local Billboard = Instance.new("BillboardGui")
            Billboard.Name = "WaypointBillboard"
            Billboard.Adornee = MarkerPart
            Billboard.AlwaysOnTop = false
            Billboard.LightInfluence = 1
            Billboard.MaxDistance = 140
            Billboard.Size = UDim2.fromScale(2.8, 0.72)
            Billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.25, 0)
            Billboard.Parent = MarkerPart
        
            --// Match the Utils UI: compact dark panel, thin border, bright primary text,
            --// and a small accent instead of the old oversized pill.
            local Container = Instance.new("Frame")
            Container.Name = "Container"
            Container.AnchorPoint = Vector2.new(0.5, 0.5)
            Container.Position = UDim2.fromScale(0.5, 0.5)
            Container.Size = UDim2.fromScale(1, 1)
            Container.BackgroundColor3 = DEBUG_COLORS.BillboardPanel
            Container.BackgroundTransparency = 0.04
            Container.BorderSizePixel = 0
            Container.Parent = Billboard
        
            local Corner = Instance.new("UICorner")
            Corner.CornerRadius = UDim.new(0, 3)
            Corner.Parent = Container
        
            local Stroke = Instance.new("UIStroke")
            Stroke.Color = DEBUG_COLORS.BillboardBorder
            Stroke.Thickness = 1
            Stroke.Transparency = 0.05
            Stroke.Parent = Container
        
            local Accent = Instance.new("Frame")
            Accent.Name = "Accent"
            Accent.Position = UDim2.fromScale(0, 0.16)
            Accent.Size = UDim2.fromScale(0.035, 0.68)
            Accent.BackgroundColor3 = DEBUG_COLORS.WaypointPending
            Accent.BorderSizePixel = 0
            Accent.Parent = Container
        
            local AccentCorner = Instance.new("UICorner")
            AccentCorner.CornerRadius = UDim.new(0, 2)
            AccentCorner.Parent = Accent
        
            local Label = Instance.new("TextLabel")
            Label.Name = "Label"
            Label.BackgroundTransparency = 1
            Label.Position = UDim2.fromScale(0.10, 0)
            Label.Size = UDim2.fromScale(0.56, 1)
            Label.Font = UI.Fonts.Regular
            Label.Text = string.format("WP %02d", Index)
            Label.TextColor3 = DEBUG_COLORS.BillboardText
            Label.TextScaled = true
            Label.TextXAlignment = Enum.TextXAlignment.Left
            Label.TextYAlignment = Enum.TextYAlignment.Center
            Label.Parent = Container
        
            local State = Instance.new("TextLabel")
            State.Name = "State"
            State.BackgroundTransparency = 1
            State.Position = UDim2.fromScale(0.68, 0)
            State.Size = UDim2.fromScale(0.25, 1)
            State.Font = UI.Fonts.Regular
            State.Text = "NEXT"
            State.TextColor3 = DEBUG_COLORS.BillboardMuted
            State.TextScaled = true
            State.TextXAlignment = Enum.TextXAlignment.Right
            State.TextYAlignment = Enum.TextYAlignment.Center
            State.Parent = Container
        
            AICDebug.S.DebugWaypointData[Index] = {
                MarkerPart = MarkerPart,
                Billboard = Billboard,
                Accent = Accent,
                Label = Label,
                State = State,
                Visited = false,
                NextBeam = nil,
                Arrow = nil,
            }
        
            return AICDebug.S.DebugWaypointData[Index]
        end
        function AICDebug.CreateDebugWaypointLink(Index, FromData, ToData)
            if not FromData or not ToData then
                return
            end
        
            local FromPart = FromData.MarkerPart
            local ToPart = ToData.MarkerPart
        
            if not FromPart or not ToPart then
                return
            end
        
            local FromAttachment = FromPart:FindFirstChild("NextAttachment")
            if not FromAttachment then
                FromAttachment = Instance.new("Attachment")
                FromAttachment.Name = "NextAttachment"
                FromAttachment.Position = Vector3.new(0, -0.1, 0)
                FromAttachment.Parent = FromPart
            end
        
            local ToAttachment = ToPart:FindFirstChild("PreviousAttachment")
            if not ToAttachment then
                ToAttachment = Instance.new("Attachment")
                ToAttachment.Name = "PreviousAttachment"
                ToAttachment.Position = Vector3.new(0, -0.1, 0)
                ToAttachment.Parent = ToPart
            end
        
            --// The beam and the arrow are reused. This is called from the
            --// heartbeat, and destroying and rebuilding two instances for
            --// every pair of waypoints on every frame is what froze the game
            --// once the heartbeat started.
            local Beam = FromData.NextBeam

            if Beam and Beam.Parent then
                Beam.Attachment0 = FromAttachment
                Beam.Attachment1 = ToAttachment
            else
                Beam = Instance.new("Beam")
                Beam.Name = "WaypointPath"
                Beam.Attachment0 = FromAttachment
                Beam.Attachment1 = ToAttachment
                Beam.FaceCamera = true
                Beam.LightEmission = 0.65
                Beam.LightInfluence = 0
                Beam.Segments = 1
                Beam.Width0 = 0.045
                Beam.Width1 = 0.045
                Beam.Transparency = NumberSequence.new(0.15)
                Beam.Color = ColorSequence.new(DEBUG_COLORS.WaypointLine)
                Beam.Parent = FromPart

                FromData.NextBeam = Beam
            end
        
            --// Small directional cone at the destination so the route visibly points
            --// from this waypoint to the next one.
            local DirectionVector = ToPart.Position - FromPart.Position
            local Distance = DirectionVector.Magnitude
            local Arrow = FromData.Arrow
        
            if Distance > 0.1 then
                local Direction = DirectionVector.Unit
                local Placement = CFrame.lookAt(ToPart.Position - Direction * 0.32, ToPart.Position) * CFrame.Angles(math.rad(90), 0, 0)

                if Arrow and Arrow.Parent then
                    Arrow.CFrame = Placement
                else
                    Arrow = Instance.new("Part")
                    Arrow.Name = "WaypointArrow"
                    Arrow.Anchored = true
                    Arrow.CanCollide = false
                    Arrow.CanTouch = false
                    Arrow.CanQuery = false
                    Arrow.CastShadow = false
                    Arrow.Material = Enum.Material.Neon
                    Arrow.Color = DEBUG_COLORS.WaypointLine
                    Arrow.Shape = Enum.PartType.Wedge
                    Arrow.Size = Vector3.new(0.16, 0.42, 0.16)
                    Arrow.CFrame = Placement
                    Arrow.Parent = AICDebug.GetDebugAdorneeParent()

                    FromData.Arrow = Arrow
                end
            elseif Arrow then
                Arrow:Destroy()
                FromData.Arrow = nil
            end
        end
        function AICDebug.ResetDebugWaypoints()
            for _, Data in AICDebug.S.DebugWaypointData do
                Data.Visited = false
        
                if Data.Label then
                    Data.Label.TextColor3 = DEBUG_COLORS.BillboardText
                end
        
                if Data.State then
                    Data.State.Text = "NEXT"
                    Data.State.TextColor3 = DEBUG_COLORS.BillboardMuted
                end
        
                if Data.Accent then
                    Data.Accent.BackgroundColor3 = DEBUG_COLORS.WaypointPending
                end
        
                if Data.NextBeam then
                    Data.NextBeam.Color = ColorSequence.new(DEBUG_COLORS.WaypointLine)
                end
            end
        end
        --// How often the route is repainted, in seconds. This runs from the
        --// heartbeat, and the colours only change when the walk moves on to
        --// another waypoint, so sixty times a second was pure waste.
        local WAYPOINT_PAINT_INTERVAL = 0.1

        function AICDebug.UpdateDebugWaypointColors(Force)
            local Now = os.clock()

            if not Force and Now - (AICDebug.S.LastWaypointPaint or 0) < WAYPOINT_PAINT_INTERVAL then
                return
            end

            AICDebug.S.LastWaypointPaint = Now

            local PlaceConfig = Runtime:GetPlaceConfig()

            for Index, Data in ipairs(AICDebug.S.DebugWaypointData) do
                local AccentColor = DEBUG_COLORS.WaypointPending
                local TextColor = DEBUG_COLORS.BillboardText
                local StateText = "NEXT"
                local StateColor = DEBUG_COLORS.BillboardMuted
        
                if PlaceConfig and Index < CONFIG.CURRENT_WAYPOINT_TARGET then
                    AccentColor = DEBUG_COLORS.WaypointVisited
                    TextColor = DEBUG_COLORS.WaypointVisited
                    StateText = "DONE"
                    StateColor = DEBUG_COLORS.WaypointVisited
                    Data.Visited = true
                elseif PlaceConfig and Index == CONFIG.CURRENT_WAYPOINT_TARGET then
                    AccentColor = DEBUG_COLORS.WaypointCurrent
                    TextColor = DEBUG_COLORS.BillboardText
                    StateText = "CURRENT"
                    StateColor = DEBUG_COLORS.WaypointCurrent
                    Data.Visited = false
                else
                    Data.Visited = false
                end
        
                --// Only what actually changed is written: assigning the same
                --// colour again still costs the client a render pass.
                if Data.Label and Data.Label.TextColor3 ~= TextColor then
                    Data.Label.TextColor3 = TextColor
                end
        
                if Data.State then
                    if Data.State.Text ~= StateText then
                        Data.State.Text = StateText
                    end

                    if Data.State.TextColor3 ~= StateColor then
                        Data.State.TextColor3 = StateColor
                    end
                end
        
                if Data.Accent and Data.Accent.BackgroundColor3 ~= AccentColor then
                    Data.Accent.BackgroundColor3 = AccentColor
                end
            end

            --// Route direction is always WP 1 -> WP 2 -> WP 3 -> ...
            --// The links reuse their beam and arrow, so this is only a property
            --// refresh rather than instance churn.
            for Index = 1, #AICDebug.S.DebugWaypointData - 1 do
                AICDebug.CreateDebugWaypointLink(Index, AICDebug.S.DebugWaypointData[Index], AICDebug.S.DebugWaypointData[Index + 1])
            end
        
            if AICDebug.S.DebugWaypointData[#AICDebug.S.DebugWaypointData] then
                local LastData = AICDebug.S.DebugWaypointData[#AICDebug.S.DebugWaypointData]
                if LastData.NextBeam then
                    LastData.NextBeam:Destroy()
                    LastData.NextBeam = nil
                end
                if LastData.Arrow then
                    LastData.Arrow:Destroy()
                    LastData.Arrow = nil
                end
            end
        end
        function AICDebug.DestroyDebugZones()
            AICDebug.S.DebugZoneSignature = nil
        
            if AICDebug.S.DebugFarmZone then
                AICDebug.S.DebugFarmZone:Destroy()
                AICDebug.S.DebugFarmZone = nil
            end
        
            if AICDebug.S.DebugDeadzone then
                AICDebug.S.DebugDeadzone:Destroy()
                AICDebug.S.DebugDeadzone = nil
            end

            if AICDebug.S.DebugMineZone then
                AICDebug.S.DebugMineZone:Destroy()
                AICDebug.S.DebugMineZone = nil
            end
        end
        function AICDebug.RebuildDebugZones()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if not PlaceConfig then
                AICDebug.DestroyDebugZones()
                return
            end
        
            --// Rebuild all farm/dead zones. Profiles can contain multiple zones.
            if AICDebug.S.DebugFarmZone then
                AICDebug.S.DebugFarmZone:Destroy()
                AICDebug.S.DebugFarmZone = nil
            end
        
            if AICDebug.S.DebugDeadzone then
                AICDebug.S.DebugDeadzone:Destroy()
                AICDebug.S.DebugDeadzone = nil
            end

            if AICDebug.S.DebugMineZone then
                AICDebug.S.DebugMineZone:Destroy()
                AICDebug.S.DebugMineZone = nil
            end

            AICDebug.S.DebugZoneSignature = nil
        
            local ZoneContainer = AICDebug.GetDebugAdorneeParent()
        
            local FarmZonesFolder = Instance.new("Folder")
            FarmZonesFolder.Name = "FarmZones"
            FarmZonesFolder.Parent = ZoneContainer
        
            if FeatureState.DebugFarmZones.Enabled then
                for Index, Zone in ipairs(PlaceConfig.FARM_ZONES or {}) do
                    local ZoneFolder = AICDebug.CreateDebugZone(
                        "FarmZone_" .. Index,
                        Zone.Center,
                        Zone.Radius,
                        DEBUG_COLORS.FarmZone,
                        "FARM",
                        Index
                    )
        
                    if ZoneFolder then
                        ZoneFolder.Parent = FarmZonesFolder
                    end
                end
            end
        
            local DeadzonesFolder = Instance.new("Folder")
            DeadzonesFolder.Name = "Deadzones"
            DeadzonesFolder.Parent = ZoneContainer
        
            if FeatureState.DebugDeadzones.Enabled then
                for Index, Zone in ipairs(PlaceConfig.DEADZONES or {}) do
                    local ZoneFolder = AICDebug.CreateDebugZone(
                        "Deadzone_" .. Index,
                        Zone.Center,
                        Zone.Radius,
                        DEBUG_COLORS.Deadzone,
                        "DEAD",
                        Index
                    )
        
                    if ZoneFolder then
                        ZoneFolder.Parent = DeadzonesFolder
                    end
                end
            end
        
            local MineZonesFolder = Instance.new("Folder")
            MineZonesFolder.Name = "MineZones"
            MineZonesFolder.Parent = ZoneContainer

            if FeatureState.DebugMineZones.Enabled then
                for Index, Zone in ipairs(PlaceConfig.MINE_ZONES or {}) do
                    local ZoneFolder = AICDebug.CreateDebugZone(
                        "MineZone_" .. Index,
                        Zone.Center,
                        Zone.Radius,
                        DEBUG_COLORS.MineZone,
                        "MINE",
                        Index
                    )

                    if ZoneFolder then
                        ZoneFolder.Parent = MineZonesFolder
                    end
                end
            end

            AICDebug.S.DebugFarmZone = FarmZonesFolder
            AICDebug.S.DebugDeadzone = DeadzonesFolder
            AICDebug.S.DebugMineZone = MineZonesFolder
            AICDebug.S.DebugZoneSignature = "MULTI|" .. tostring(#(PlaceConfig.FARM_ZONES or {})) .. "|" .. tostring(#(PlaceConfig.DEADZONES or {}))
        end
        function AICDebug.UpdateDebugVisualizer()
        local PlaceConfig = Runtime:GetPlaceConfig()
            if not PlaceConfig or not FeatureState.DebugVisualizer.Enabled then
                AICDebug.SetDebugVisualizerVisible(false)
                return
            end
        
            AICDebug.GetDebugAdorneeParent()
        
            --// Rebuild waypoints if the place configuration changed.
            local WaypointCount = FeatureState.DebugWaypoints.Enabled and #PlaceConfig.WAYPOINTS or 0
            local WaypointParts = {}
        
            for Index, Position in ipairs(PlaceConfig.WAYPOINTS) do
                WaypointParts[Index] = string.format(
                    "%.3f:%.3f:%.3f",
                    Position.X,
                    Position.Y,
                    Position.Z
                )
            end
        
            local CurrentWaypointSignature = table.concat(WaypointParts, "|")
        
            if AICDebug.S.DebugWaypointSignature ~= CurrentWaypointSignature
                or #AICDebug.S.DebugWaypointData ~= WaypointCount
            then
                for _, Data in AICDebug.S.DebugWaypointData do
                    if Data.NextBeam then
                        Data.NextBeam:Destroy()
                    end
                    if Data.Arrow then
                        Data.Arrow:Destroy()
                    end
                    if Data.MarkerPart then
                        Data.MarkerPart:Destroy()
                    end
                end
        
                table.clear(AICDebug.S.DebugWaypointData)
                AICDebug.S.DebugWaypointSignature = nil
        
                if FeatureState.DebugWaypoints.Enabled then
                    for Index, Position in ipairs(PlaceConfig.WAYPOINTS) do
                        AICDebug.CreateDebugWaypoint(Index, Position)
                    end
                end
        
                AICDebug.S.DebugWaypointSignature = CurrentWaypointSignature
            end
        
            AICDebug.RebuildDebugZones()
            --// Forced: the route was just rebuilt, so its colours are due now
            --// rather than on the next heartbeat paint.
            AICDebug.UpdateDebugWaypointColors(true)
            AICDebug.SetDebugVisualizerVisible(true)
        end

        --// Status billboards over world objects (ores, smithing tables). The
        --// feature decides what each shows; this keeps one billboard per
        --// object in step with that, per Group so groups never clear each
        --// other. They live in the debug folder, so hiding the visualizer
        --// hides them too.
        local STATUS_BILLBOARD_MAX_DISTANCE = 150

        --// Group -> { [Object] = billboard parts }
        AICDebug.S.StatusBillboards = {}

        local function CreateStatusBillboard(Core)
            local Billboard = Instance.new("BillboardGui")
            Billboard.Name = "Status"
            Billboard.Adornee = Core
            Billboard.AlwaysOnTop = true
            Billboard.LightInfluence = 0
            Billboard.MaxDistance = STATUS_BILLBOARD_MAX_DISTANCE
            Billboard.Size = UDim2.fromScale(5, 1.3)
            Billboard.StudsOffsetWorldSpace = Vector3.new(0, Core.Size.Y * 0.5 + 2, 0)

            local Container = Instance.new("Frame")
            Container.BackgroundColor3 = DEBUG_COLORS.BillboardPanel
            Container.BackgroundTransparency = 0.05
            Container.BorderSizePixel = 0
            Container.Size = UDim2.fromScale(1, 1)
            Container.Parent = Billboard

            local Corner = Instance.new("UICorner")
            Corner.CornerRadius = UDim.new(0, 3)
            Corner.Parent = Container

            local Stroke = Instance.new("UIStroke")
            Stroke.Thickness = 1
            Stroke.Transparency = 0.1
            Stroke.Parent = Container

            local Title = Instance.new("TextLabel")
            Title.BackgroundTransparency = 1
            Title.Size = UDim2.fromScale(1, 0.52)
            Title.Position = UDim2.fromScale(0, 0.03)
            Title.Font = UI.Fonts.Regular
            Title.TextColor3 = DEBUG_COLORS.BillboardText
            Title.TextScaled = true
            Title.Parent = Container

            local Status = Instance.new("TextLabel")
            Status.BackgroundTransparency = 1
            Status.Size = UDim2.fromScale(1, 0.4)
            Status.Position = UDim2.fromScale(0, 0.55)
            Status.Font = UI.Fonts.Regular
            Status.TextScaled = true
            Status.Parent = Container

            local Folder = AICDebug.GetDebugAdorneeParent():FindFirstChild("StatusBillboards")

            if not Folder then
                Folder = Instance.new("Folder")
                Folder.Name = "StatusBillboards"
                Folder.Parent = AICDebug.GetDebugAdorneeParent()
            end

            Billboard.Parent = Folder

            return { Gui = Billboard, Title = Title, Status = Status, Stroke = Stroke }
        end

        --// Entries maps an object to { Core, Title, Status, Color }. Objects
        --// missing from it lose their billboard; nil clears the whole Group.
        --// The caller checks its own debug toggle and passes nil when off.
        function AICDebug.UpdateStatusBillboards(Group, Entries)
            local Billboards = AICDebug.S.StatusBillboards[Group] or {}
            AICDebug.S.StatusBillboards[Group] = Billboards

            local Visible = Entries ~= nil and FeatureState.DebugVisualizer.Enabled

            for Object, Data in pairs(Billboards) do
                if not Visible or not Entries[Object] or not Object.Parent then
                    Data.Gui:Destroy()
                    Billboards[Object] = nil
                end
            end

            if not Visible then
                return
            end

            for Object, Entry in pairs(Entries) do
                local Data = Billboards[Object]

                if not Data then
                    Data = CreateStatusBillboard(Entry.Core)
                    Billboards[Object] = Data
                end

                --// Only touch what changed; these run several times a second.
                if Data.Title.Text ~= Entry.Title then
                    Data.Title.Text = Entry.Title
                end

                if Data.Status.Text ~= Entry.Status then
                    Data.Status.Text = Entry.Status
                end

                if Data.Status.TextColor3 ~= Entry.Color then
                    Data.Status.TextColor3 = Entry.Color
                    Data.Stroke.Color = Entry.Color
                end
            end
        end
        
        
        ------------------------------------------------------------------------
        --// Runtime exposes shared state only. Feature/UI composition is handled by Bootstrap.

        local Runtime = {}
        --// Called by Init after AutoFarming's sliders, matching AFV2's order.
        function Module:BuildLateUI()
            if UIRef.DebugSection then
                FeatureState.DebugVisualizer.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Visualizer",
                    Default = FeatureState.DebugVisualizer.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugVisualizer.Enabled = Value
                        task.defer(function()
                            if Value then
                                AICDebug.UpdateDebugVisualizer()
                            else
                                AICDebug.SetDebugVisualizerVisible(false)
                            end
                        end)
                        AICProfile.SaveActiveProfile()
                    end,
                }
            end
        end

        function Module:CreateUI()
            if UIRef.DebugSection then
                FeatureState.DebugWaypoints.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Waypoints",
                    Default = FeatureState.DebugWaypoints.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugWaypoints.Enabled = Value
                        AICDebug.UpdateDebugVisualizer()
                        AICProfile.SaveActiveProfile()
                    end,
                }

                FeatureState.DebugFarmZones.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Farm Zones",
                    Default = FeatureState.DebugFarmZones.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugFarmZones.Enabled = Value
                        AICDebug.UpdateDebugVisualizer()
                        AICProfile.SaveActiveProfile()
                    end,
                }

                FeatureState.DebugDeadzones.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Deadzones",
                    Default = FeatureState.DebugDeadzones.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugDeadzones.Enabled = Value
                        AICDebug.UpdateDebugVisualizer()
                        AICProfile.SaveActiveProfile()
                    end,
                }

                FeatureState.DebugMineZones.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Mine Zones",
                    Default = FeatureState.DebugMineZones.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugMineZones.Enabled = Value
                        AICDebug.UpdateDebugVisualizer()
                        AICProfile.SaveActiveProfile()
                    end,
                }

                --// Auto Mining feeds the billboards; turning this off drops
                --// them on its next update.
                FeatureState.DebugOres.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Ore Status",
                    Default = FeatureState.DebugOres.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugOres.Enabled = Value
                        AICProfile.SaveActiveProfile()
                    end,
                }

                --// Auto Smithing's billboards over smithing tables, same
                --// arrangement as the ores.
                FeatureState.DebugSmithing.Button = UIRef.DebugSection:AddToggle{
                    Name = "Debug Smithing Tables",
                    Default = FeatureState.DebugSmithing.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugSmithing.Enabled = Value
                        AICProfile.SaveActiveProfile()
                    end,
                }

                FeatureState.DebugRadiusLabels.Button = UIRef.DebugSection:AddToggle{
                    Name = "Radius Billboard Labels",
                    Default = FeatureState.DebugRadiusLabels.Enabled,
                    Callback = function(Value)
                        FeatureState.DebugRadiusLabels.Enabled = Value
                        AICDebug.UpdateDebugVisualizer()
                        AICProfile.SaveActiveProfile()
                    end,
                }
            end
        end

        Module:CreateUI()

        --// The debug folder sits in workspace, outside the window.
        Context.Lifetime.OnEnd(function()
            if AICCombatUtils.S.DebugFolder then
                AICCombatUtils.S.DebugFolder:Destroy()
                AICCombatUtils.S.DebugFolder = nil
            end
        end)

        return Module
    end,
}
