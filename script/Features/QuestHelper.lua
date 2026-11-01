-- QuestHelper is the Quest tab's marker layer: it draws what the live quest
-- asks for, instead of waiting for names to be typed in.
--
-- The quest comes from AutoQuest, which reads the game's own tracker
-- (QuestUI_Root.Tracker.Content.Objectives), so there is nothing to enter:
--   Quest ESP          marks the quest giver that is picked, every live mob
--                      the tracker's kill objectives name (matched by model
--                      name and Config.Entity, plurals included), and any
--                      object in workspace whose name the other objectives
--                      name (what a "Collect 3 Boar Hides" quest wants).
--   Show All Quest Items  marks everything inside the workspace's QuestItems
--                      folder as well. It draws on its own, without Quest ESP
--                      having to be switched on first.
--   Extra Quest Targets  names typed in (comma separated) are marked too, for
--                      anything the tracker's wording does not say plainly.
--
-- Each mark is a Highlight (the nearest MAX_HIGHLIGHTS) plus a label with the
-- name and distance, seen through walls. A tagged part that goes away is
-- dropped on the next update, and marks are rebuilt from the live tracker
-- every UPDATE_INTERVAL, so a quest that advances stops marking what is done.
return {
    Name = "QuestHelper",
    IsFeature = true,
    Dependencies = {"Runtime", "Components", "ProfileManager", "AutoQuest"},

    Start = function(Context)
        local Players = Context.Services.Players
        local UIRef = Context.UIRef
        local UI = Context.UI
        local AICQuest = Context.AutoQuest

        --// Highlights at once; Roblox renders about 31 in total and the
        --// debug visualizer uses some.
        local MAX_HIGHLIGHTS = 20
        --// Labels at once; matches past this are skipped until a Rescan.
        local MAX_TAGS = 200
        --// Seconds between rebuilds, and between distance / nearest updates.
        local UPDATE_INTERVAL = 0.25
        --// Seconds between full workspace name scans (item objectives).
        local WORLD_SCAN_INTERVAL = 2.5
        local LABEL_MAX_DISTANCE = 5000
        local ESP_COLOR = Color3.fromRGB(255, 196, 0)
        local GIVER_COLOR = Color3.fromRGB(120, 200, 255)
        local NEAREST_COLOR = Color3.fromRGB(0, 255, 140)
        local ESP_FOLDER_NAME = "AICQuestESP"
        local QUEST_ITEMS_FOLDER = "QuestItems"
        local OFF_TEXT = "QUEST ESP OFF"
        local EMPTY_TEXT = "NO QUEST TRACKED AND NO TARGETS TYPED"

        local Module = {
            Name = "QuestHelper",
            IsFeature = true,
            S = {
                Enabled = false,
                --// Tag everything in the workspace's QuestItems folder.
                ShowAll = false,
                --// Normalized name -> the name as typed.
                Manual = {},
                --// Tagged instance -> { Part, Name, Highlight, Billboard, Label }.
                Tags = {},
                TagCount = 0,
                Folder = nil,
                Elapsed = 0,
                WorldAt = -10,
                --// { { Instance, Name, Part }, ... } from the last name scan.
                WorldMatches = {},
                StatusLabel = nil,
            },
        }

        local S = Module.S

        local function GetFolder()
            if not S.Folder or not S.Folder.Parent then
                S.Folder = Instance.new("Folder")
                S.Folder.Name = ESP_FOLDER_NAME
                S.Folder.Parent = workspace
            end

            return S.Folder
        end

        --// Letters and digits only, lower case: "Old Key #2" -> "oldkey2".
        local function Normalize(Text)
            return string.lower((string.gsub(tostring(Text or ""), "[^%w]", "")))
        end

        local function ParseNames(Text)
            local Names = {}

            for Name in string.gmatch(tostring(Text or ""), "[^,]+") do
                local Key = Normalize(Name)

                if Key ~= "" then
                    Names[Key] = Name
                end
            end

            return Names
        end

        local function IsOn()
            return S.Enabled or S.ShowAll
        end

        --// The part a label hangs on, or nil.
        local function GetAnchorPart(Instance_)
            if Instance_:IsA("BasePart") then
                return Instance_
            end

            if Instance_:IsA("Model") then
                return Instance_.PrimaryPart
                    or Instance_:FindFirstChild("HumanoidRootPart")
                    or Instance_:FindFirstChildWhichIsA("BasePart", true)
            end

            if Instance_:IsA("Attachment") then
                return Instance_.Parent and Instance_.Parent:IsA("BasePart") and Instance_.Parent or nil
            end

            return nil
        end

        local function IsInsideCharacter(Instance_)
            for _, Player in ipairs(Players:GetPlayers()) do
                if Player.Character and Instance_:IsDescendantOf(Player.Character) then
                    return true
                end
            end

            return false
        end

        ------------------------------------------------------------------------
        --// Drawing
        ------------------------------------------------------------------------

        local function CreateBillboard(Part, Name, Color)
            local Billboard = Instance.new("BillboardGui")
            Billboard.Name = "QuestTarget"
            Billboard.Adornee = Part
            Billboard.AlwaysOnTop = true
            Billboard.LightInfluence = 0
            Billboard.MaxDistance = LABEL_MAX_DISTANCE
            Billboard.Size = UDim2.fromOffset(180, 34)
            Billboard.StudsOffset = Vector3.new(0, 2.5, 0)
            Billboard.Parent = GetFolder()

            local Label = Instance.new("TextLabel")
            Label.BackgroundTransparency = 1
            Label.Size = UDim2.fromScale(1, 1)
            Label.Font = UI.Fonts and UI.Fonts.Bold or Enum.Font.GothamBold
            Label.Text = Name
            Label.TextColor3 = Color or ESP_COLOR
            Label.TextStrokeTransparency = 0.3
            Label.TextSize = 13
            Label.Parent = Billboard

            return Billboard, Label
        end

        local function RemoveTag(Instance_)
            local Tag = S.Tags[Instance_]

            if not Tag then
                return
            end

            if Tag.Highlight then
                Tag.Highlight:Destroy()
            end

            if Tag.Billboard then
                Tag.Billboard:Destroy()
            end

            S.Tags[Instance_] = nil
            S.TagCount -= 1
        end

        local function ClearTags()
            for Instance_ in pairs(S.Tags) do
                RemoveTag(Instance_)
            end
        end

        local function AddTag(Instance_, Name, Part, Color)
            if S.Tags[Instance_] or S.TagCount >= MAX_TAGS then
                return
            end

            if not Part or not Part.Parent or IsInsideCharacter(Instance_) then
                return
            end

            local Billboard, Label = CreateBillboard(Part, Name, Color)

            S.Tags[Instance_] = {
                Target = Instance_,
                Part = Part,
                Name = Name,
                Color = Color or ESP_COLOR,
                Billboard = Billboard,
                Label = Label,
            }
            S.TagCount += 1
        end

        local function SetHighlight(Tag, Wanted, Color)
            if Wanted and not Tag.Highlight then
                local Highlight = Instance.new("Highlight")
                Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                Highlight.FillTransparency = 0.6
                Highlight.OutlineTransparency = 0
                Highlight.Adornee = Tag.Target
                Highlight.Parent = GetFolder()
                Tag.Highlight = Highlight
            elseif not Wanted and Tag.Highlight then
                Tag.Highlight:Destroy()
                Tag.Highlight = nil
            end

            if Tag.Highlight then
                Tag.Highlight.FillColor = Color
                Tag.Highlight.OutlineColor = Color
            end
        end

        local function SetStatus(Text, Color)
            if S.StatusLabel then
                S.StatusLabel:Set(Text)
                S.StatusLabel:SetColor(Color or ESP_COLOR)
            end
        end

        ------------------------------------------------------------------------
        --// What the quest asks for
        ------------------------------------------------------------------------

        --// Every object in workspace (outside a character) whose name one of
        --// these wordings names. Rebuilt at WORLD_SCAN_INTERVAL, since a walk
        --// of the whole workspace is the expensive part of the marker layer.
        local function GetWorldMatches(Now)
            if Now - S.WorldAt < WORLD_SCAN_INTERVAL then
                return S.WorldMatches
            end

            S.WorldAt = Now
            S.WorldMatches = {}

            local Wanted = {}

            for _, Row in ipairs(AICQuest.GetObjectives()) do
                if not Row.Done and not AICQuest.IsKillTask(Row.Task) then
                    table.insert(Wanted, { Task = Row.Task, Keys = AICQuest.ObjectiveKeys(Row.Task) })
                end
            end

            for _, Text in pairs(S.Manual) do
                table.insert(Wanted, { Task = Text, Keys = AICQuest.ObjectiveKeys(Text) })
            end

            if #Wanted == 0 then
                return S.WorldMatches
            end

            local Folder = S.Folder

            for _, Descendant in ipairs(workspace:GetDescendants()) do
                local OwnMark = Folder ~= nil and Descendant:IsDescendantOf(Folder)

                if not OwnMark and (Descendant:IsA("Model") or Descendant:IsA("BasePart")) then
                    for _, Entry in ipairs(Wanted) do
                        if AICQuest.NameMatches(Entry.Keys, Descendant.Name) then
                            local Part = GetAnchorPart(Descendant)

                            if Part then
                                table.insert(S.WorldMatches, {
                                    Instance = Descendant,
                                    Name = Entry.Task,
                                    Part = Part,
                                })
                            end

                            break
                        end
                    end
                end
            end

            return S.WorldMatches
        end

        --// Everything inside the workspace's QuestItems folder, for Show All.
        local function GetQuestItemInstances()
            local Items = workspace:FindFirstChild(QUEST_ITEMS_FOLDER)
                or workspace:FindFirstChild(QUEST_ITEMS_FOLDER, true)

            if not Items then
                return {}
            end

            local Found = {}

            for _, Descendant in ipairs(Items:GetDescendants()) do
                if Descendant:IsA("Model") or Descendant:IsA("BasePart") then
                    table.insert(Found, Descendant)
                end
            end

            return Found
        end

        ------------------------------------------------------------------------
        --// The tag set
        ------------------------------------------------------------------------

        --// Every entry is keyed by the part the mark hangs on, so a Highlight
        --// is only ever put on a Model or a BasePart (a giver can be a folder).
        local function Rebuild()
            local Wanted = {}

            --// The quest giver the loop is using, so it can be walked to.
            local Giver = AICQuest.GetSelectedGiver()

            if S.Enabled and Giver and Giver.Instance and Giver.Instance.Parent then
                local Prompt = Giver.Instance:FindFirstChild("ProximityPrompt", true)
                local Part = Prompt and GetAnchorPart(Prompt.Parent)
                    or Giver.Instance:FindFirstChildWhichIsA("BasePart", true)

                if Part then
                    Wanted[Part] = {
                        Part = Part,
                        Name = "QUEST " .. (Giver.Id ~= "" and Giver.Id or Giver.Label or ""),
                        Color = GIVER_COLOR,
                    }
                end
            end

            --// Mobs the tracker's kill objectives name.
            if S.Enabled then
                local KillRows = {}

                for _, Row in ipairs(AICQuest.GetObjectives()) do
                    if not Row.Done and AICQuest.IsKillTask(Row.Task) then
                        table.insert(KillRows, Row)
                    end
                end

                if #KillRows > 0 then
                    for _, Mob in ipairs(AICQuest.GetMobs()) do
                        for _, Row in ipairs(KillRows) do
                            if AICQuest.MobMatches(Mob, Row.Task) then
                                local Part = GetAnchorPart(Mob)
                                local Count = Row.Current and Row.Total
                                    and string.format("  %d/%d", Row.Current, Row.Total)
                                    or ""

                                if Part then
                                    Wanted[Part] = {
                                        Part = Part,
                                        Name = Mob.Name .. Count,
                                        Color = ESP_COLOR,
                                    }
                                end

                                break
                            end
                        end
                    end
                end

                for _, Match in ipairs(GetWorldMatches(os.clock())) do
                    Wanted[Match.Part] = { Part = Match.Part, Name = Match.Name, Color = ESP_COLOR }
                end
            end

            --// Show All draws on its own: it is the answer to "where are the
            --// quest items", not something that needed Quest ESP first.
            if S.ShowAll then
                for _, Item in ipairs(GetQuestItemInstances()) do
                    local Part = GetAnchorPart(Item)

                    if Part then
                        Wanted[Part] = { Part = Part, Name = Item.Name, Color = ESP_COLOR }
                    end
                end
            end

            --// Grown or gone.
            for Instance_, Tag in pairs(S.Tags) do
                if not Wanted[Instance_] or not Instance_.Parent or not Tag.Part.Parent then
                    RemoveTag(Instance_)
                end
            end

            for Instance_, Entry in pairs(Wanted) do
                local Tag = S.Tags[Instance_]

                if Tag then
                    Tag.Name, Tag.Color, Tag.Part = Entry.Name, Entry.Color, Entry.Part
                    Tag.Label.TextColor3 = Entry.Color
                elseif S.TagCount < MAX_TAGS then
                    AddTag(Instance_, Entry.Name, Entry.Part, Entry.Color)
                end
            end
        end

        --// Distances, the nearest MAX_HIGHLIGHTS highlighted, gone ones dropped.
        local function UpdateTags()
            local _, _, RootPart = Context.Runtime:GetCharacter()
            local Origin = RootPart and RootPart.Position
            local Sorted = {}

            for Instance_, Tag in pairs(S.Tags) do
                if not Instance_.Parent or not Tag.Part.Parent then
                    RemoveTag(Instance_)
                else
                    Tag.Distance = Origin and (Tag.Part.Position - Origin).Magnitude or 0
                    table.insert(Sorted, Tag)
                end
            end

            table.sort(Sorted, function(A, B)
                return A.Distance < B.Distance
            end)

            for Index, Tag in ipairs(Sorted) do
                local Color = Index == 1 and NEAREST_COLOR or Tag.Color
                Tag.Label.Text = string.format("%s  [%d]", Tag.Name, math.floor(Tag.Distance + 0.5))
                Tag.Label.TextColor3 = Color
                SetHighlight(Tag, Index <= MAX_HIGHLIGHTS, Color)
            end

            if not IsOn() then
                SetStatus(OFF_TEXT, Color3.fromRGB(160, 160, 160))
            elseif Sorted[1] then
                SetStatus(string.format(
                    "FOUND %d%s  ·  NEAREST %s  %d STUDS",
                    #Sorted,
                    S.ShowAll and " (SHOW ALL)" or "",
                    Sorted[1].Name,
                    math.floor(Sorted[1].Distance + 0.5)
                ))
            else
                SetStatus(S.Enabled and EMPTY_TEXT or "NOTHING IN QUESTITEMS YET", Color3.fromRGB(230, 200, 120))
            end
        end

        function Module:Update(DeltaTime)
            if not IsOn() then
                if S.TagCount > 0 then
                    ClearTags()
                end

                if S.StatusLabel then
                    SetStatus(OFF_TEXT, Color3.fromRGB(160, 160, 160))
                end

                return
            end

            S.Elapsed += DeltaTime

            if S.Elapsed < UPDATE_INTERVAL then
                return
            end

            S.Elapsed = 0
            Rebuild()
            UpdateTags()
        end

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        local Section = UIRef.QuestHelperSection

        S.StatusLabel = Section:AddLabel(OFF_TEXT)

        Section:AddToggle{
            Name = "Quest ESP",
            Default = false,
            Callback = function(Value)
                S.Enabled = Value
                S.WorldAt = -10

                if not IsOn() then
                    ClearTags()
                else
                    Rebuild()
                    UpdateTags()
                end
            end,
        }

        Section:AddToggle{
            Name = "Show All Quest Items",
            Default = false,
            Callback = function(Value)
                S.ShowAll = Value

                if not IsOn() then
                    ClearTags()
                else
                    Rebuild()
                    UpdateTags()
                end
            end,
        }

        UIRef.QuestTargetsBox = Section:AddTextBox{
            Name = "Extra Quest Targets",
            Default = "",
            Callback = function(Value)
                S.Manual = ParseNames(Value)
                S.WorldAt = -10

                if IsOn() then
                    Rebuild()
                    UpdateTags()
                end
            end,
        }

        Section:AddButton{
            Name = "Rescan Quest Targets",
            Callback = function()
                S.WorldAt = -10

                if IsOn() then
                    Rebuild()
                    UpdateTags()
                end

                SetStatus(string.format("RESCAN  ·  %d MARKED", S.TagCount))
            end,
        }

        Context.Lifetime.OnEnd(function()
            ClearTags()

            if S.Folder then
                S.Folder:Destroy()
                S.Folder = nil
            end
        end)

        return Module
    end,
}
