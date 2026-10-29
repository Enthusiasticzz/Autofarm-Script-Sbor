-- FpsBoost turns off what costs frames and that the farm does not need:
-- shadows, post effects, atmosphere, clouds, particles, lights, decals,
-- water waves and terrain grass, and lowers the render quality. Every
-- property it changes is remembered and put back when it is turned off or
-- the run ends. The Debug Visualizer's own objects are left alone.
return {
    Name = "FpsBoost",
    Dependencies = {"Runtime", "SaveConfig", "Components"},

    Start = function(Context)
        local FeatureState = Context.Feature
        local AICUI = Context.AICUI
        local AICCombatUtils = Context.AICCombatUtils
        local UIRef = Context.UIRef
        local Lighting = game:GetService("Lighting")

        --// Lighting is set again this often, for games that change it.
        local REAPPLY_INTERVAL = 5
        --// Descendants handled per frame on the first pass, so a big map
        --// does not freeze the client.
        local SCAN_BATCH = 2000
        local FOG_END = 1e6

        --// Property -> value for each class (by IsA), in workspace.
        local OBJECT_RULES = {
            { Class = "ParticleEmitter", Props = { Enabled = false } },
            { Class = "Trail", Props = { Enabled = false } },
            { Class = "Beam", Props = { Enabled = false } },
            { Class = "Smoke", Props = { Enabled = false } },
            { Class = "Fire", Props = { Enabled = false } },
            { Class = "Sparkles", Props = { Enabled = false } },
            { Class = "Light", Props = { Enabled = false } },
            { Class = "Explosion", Props = { Visible = false } },
            { Class = "Decal", Props = { Transparency = 1 } },
            { Class = "BasePart", Props = { CastShadow = false } },
            { Class = "Clouds", Props = { Enabled = false } },
            { Class = "PostEffect", Props = { Enabled = false } },
            { Class = "Atmosphere", Props = { Density = 0, Haze = 0, Glare = 0 } },
        }

        local LIGHTING_PROPS = {
            GlobalShadows = false,
            FogEnd = FOG_END,
            ShadowSoftness = 0,
            EnvironmentDiffuseScale = 0,
            EnvironmentSpecularScale = 0,
        }

        local TERRAIN_PROPS = {
            WaterWaveSize = 0,
            WaterWaveSpeed = 0,
            WaterReflectance = 0,
            Decoration = false,
        }

        local S = {
            --// Instance -> { Property = original value }.
            Saved = setmetatable({}, { __mode = "k" }),
            Connections = {},
            --// Bumped on every on/off, so an old pass or loop stops.
            Token = 0,
            QualitySaved = nil,
        }

        local Feature = { Name = "FpsBoost", S = S }

        --// Sets Property, remembering its value from before the first change.
        local function SetProp(Object, Property, Value)
            local Saved = S.Saved[Object]

            if not Saved then
                Saved = {}
                S.Saved[Object] = Saved
            end

            if Saved[Property] == nil then
                local Success, Current = pcall(function()
                    return Object[Property]
                end)

                if not Success or Current == nil then
                    return
                end

                Saved[Property] = Current
            end

            pcall(function()
                Object[Property] = Value
            end)
        end

        local function IsOurs(Object)
            local Folder = AICCombatUtils.S.DebugFolder
            return Folder ~= nil and (Object == Folder or Object:IsDescendantOf(Folder))
        end

        local function ApplyObject(Object)
            if typeof(Object) ~= "Instance" or not Object.Parent or IsOurs(Object) then
                return
            end

            for _, Rule in ipairs(OBJECT_RULES) do
                if Object:IsA(Rule.Class) then
                    for Property, Value in pairs(Rule.Props) do
                        SetProp(Object, Property, Value)
                    end

                    return
                end
            end
        end

        local function ApplyLighting()
            for Property, Value in pairs(LIGHTING_PROPS) do
                SetProp(Lighting, Property, Value)
            end

            local Terrain = workspace:FindFirstChildOfClass("Terrain")

            if Terrain then
                for Property, Value in pairs(TERRAIN_PROPS) do
                    SetProp(Terrain, Property, Value)
                end
            end
        end

        local function SetQuality(Level)
            pcall(function()
                local Rendering = settings().Rendering

                if S.QualitySaved == nil then
                    S.QualitySaved = Rendering.QualityLevel
                end

                Rendering.QualityLevel = Level
            end)
        end

        local function RestoreQuality()
            local Level = S.QualitySaved
            S.QualitySaved = nil

            if Level ~= nil then
                pcall(function()
                    settings().Rendering.QualityLevel = Level
                end)
            end
        end

        --// Every descendant of Roots, a batch per frame, while Token holds.
        local function ScanAll(Token, Roots)
            for _, Root in ipairs(Roots) do
                local List = Root:GetDescendants()

                for Index, Object in ipairs(List) do
                    if S.Token ~= Token or not Context.Lifetime.Alive then
                        return
                    end

                    ApplyObject(Object)

                    if Index % SCAN_BATCH == 0 then
                        task.wait()
                    end
                end
            end
        end

        --// Streaming a map in adds hundreds of instances a second. Handling
        --// each one in its own deferred closure queued a task per instance, and
        --// every one of those tasks is a frame the client had to get through;
        --// they are collected and handled in batches instead.
        local STREAM_BATCH = 500
        local PendingObjects = {}
        local PendingScheduled = false

        local function FlushPending(Token)
            PendingScheduled = false

            if S.Token ~= Token or not FeatureState.FpsBoost.Enabled then
                return
            end

            local Batch = PendingObjects
            PendingObjects = {}

            for Index, Object in ipairs(Batch) do
                --// A toggle in the middle of a batch wins over the rest.
                if S.Token ~= Token then
                    return
                end

                if Index > STREAM_BATCH then
                    for Rest = Index, #Batch do
                        table.insert(PendingObjects, Batch[Rest])
                    end

                    break
                end

                if Object.Parent then
                    ApplyObject(Object)
                end
            end

            if #PendingObjects > 0 and not PendingScheduled then
                PendingScheduled = true
                task.delay(0, FlushPending, Token)
            end
        end

        local function OnAdded(Object)
            if not FeatureState.FpsBoost.Enabled then
                return
            end

            table.insert(PendingObjects, Object)

            if not PendingScheduled then
                PendingScheduled = true
                task.delay(0, FlushPending, S.Token)
            end
        end

        function Feature.Enable()
            S.Token += 1
            local Token = S.Token

            Context.Lifetime.Disconnect(S.Connections)
            table.insert(S.Connections, workspace.DescendantAdded:Connect(OnAdded))
            table.insert(S.Connections, Lighting.DescendantAdded:Connect(OnAdded))

            ApplyLighting()
            SetQuality(Enum.QualityLevel.Level01)

            task.spawn(ScanAll, Token, { Lighting, workspace })
            task.spawn(function()
                while Context.Lifetime.Alive and S.Token == Token do
                    task.wait(REAPPLY_INTERVAL)

                    if Context.Lifetime.Alive and S.Token == Token then
                        ApplyLighting()
                    end
                end
            end)
        end

        --// Puts every changed property back.
        function Feature.Disable()
            S.Token += 1
            Context.Lifetime.Disconnect(S.Connections)

            for Object, Saved in pairs(S.Saved) do
                for Property, Value in pairs(Saved) do
                    pcall(function()
                        Object[Property] = Value
                    end)
                end
            end

            table.clear(S.Saved)
            table.clear(PendingObjects)
            RestoreQuality()
        end

        AICUI.BindFeatureToggle("FpsBoost", "FPS Boost", function(Enabled)
            if Enabled then
                Feature.Enable()
            else
                Feature.Disable()
            end
        end, UIRef.UtilitySection)

        --// It is a global toggle, already read before this module starts.
        if FeatureState.FpsBoost.Enabled then
            Feature.Enable()
        end

        Context.Lifetime.OnEnd(Feature.Disable)

        return Feature
    end,
}
