-- QuestHelper tags what a "find an item / reach a place" quest asks for.
-- The names typed in Quest Targets (comma separated) are looked for in the
-- QuestItems folder of workspace: a Model or BasePart with that name, or a
-- part whose ProximityPrompt shows it (ObjectText / ActionText). Names are
-- compared by NormalizeName (letters and digits only, lower case) on both
-- sides, so "old key" finds "Old_Key" or "OldKey". Show All Quest Items
-- tags every Model / BasePart in QuestItems instead (an item's own parts
-- are skipped once the item is tagged). Each one found gets a
-- Highlight (the nearest MAX_HIGHLIGHTS of them; Roblox draws about 31 at
-- once) and a label with its name and distance, seen through walls.
--
-- New items are tagged as they stream in (workspace.DescendantAdded) and
-- tags whose part went away are dropped on the next update. Copy Quest Info
-- puts what the client can see of the active quest on the clipboard (and in
-- QUEST_DUMP_FILE), so the quest format can be read for automatic targets.
return {
    Name = "QuestHelper",
    Dependencies = {"Runtime", "Components", "ProfileManager", "QuestAssign"},

    Start = function(Context)
        local Services = Context.Services
        local Players = Services.Players
        local Replicated = Services.Replicated
        local UIRef = Context.UIRef
        local UI = Context.UI
        local AICProfile = Context.AICProfile
        local NotifyAction = Context.NotifyAction

        --// Highlights at once; Roblox renders ~31 in total and the debug
        --// visualizer uses some.
        local MAX_HIGHLIGHTS = 20
        --// Labels at once; matches past this are skipped until a Rescan.
        --// Raised so Show All Quest Items can label a whole QuestItems folder.
        local MAX_TAGS = 200
        --// Seconds between distance / nearest updates.
        local UPDATE_INTERVAL = 0.25
        --// Labels further than this (studs) are hidden.
        local LABEL_MAX_DISTANCE = 5000
        local ESP_COLOR = Color3.fromRGB(255, 196, 0)
        local NEAREST_COLOR = Color3.fromRGB(0, 255, 140)
        local ESP_FOLDER_NAME = "AICQuestESP"
        --// The game's folder of quest items to find; only it is searched.
        local QUEST_ITEMS_FOLDER = "QuestItems"
        local QUEST_DUMP_FILE = Context.PROFILE_FOLDER .. "/QuestDump.txt"
        --// Most lines a dump section lists, so a huge folder cannot flood it.
        local DUMP_SECTION_LIMIT = 150

        local Module = {
            Name = "QuestHelper",
            IsFeature = true,
            S = {
                Enabled = false,
                --// Lower-case target name -> true.
                Targets = {},
                --// Tagged instance -> { Part, Name, Highlight, Billboard, Label }.
                Tags = {},
                TagCount = 0,
                Folder = nil,
                Elapsed = 0,
                StatusLabel = nil,
                --// workspace's QuestItems folder (GetQuestItemsFolder).
                QuestItems = nil,
                --// Tag every item in QuestItems, typed targets or not.
                ShowAll = false,
            },
        }

        local S = Module.S

        local function GetFolder()
            if not S.Folder or not S.Folder.Parent then
                S.Folder = Instance.new("Folder")
                S.Folder.Name = ESP_FOLDER_NAME
                S.Folder.Parent = workspace

                if UI and UI.AddFontRoot then
                    UI:AddFontRoot(S.Folder)
                end
            end

            return S.Folder
        end

        --// Letters and digits only, lower case: "Old Key #2" -> "oldkey2".
        --// Typed targets and item names both go through this, so spacing,
        --// case and symbols never stop a match.
        local function NormalizeName(Text)
            local Stripped = string.gsub(tostring(Text or ""), "[^%w]", "")
            return string.lower(Stripped)
        end

        local function ParseTargets(Text)
            local Targets = {}

            for Name in string.gmatch(tostring(Text or ""), "[^,]+") do
                local Key = NormalizeName(Name)

                if Key ~= "" then
                    Targets[Key] = true
                end
            end

            return Targets
        end

        --// workspace.QuestItems (or one deeper in workspace), cached while
        --// it stays in the game; nil when it has not loaded in.
        local function GetQuestItemsFolder()
            if S.QuestItems and S.QuestItems:IsDescendantOf(workspace) then
                return S.QuestItems
            end

            S.QuestItems = workspace:FindFirstChild(QUEST_ITEMS_FOLDER)
                or workspace:FindFirstChild(QUEST_ITEMS_FOLDER, true)

            return S.QuestItems
        end

        --// A part to hang the label on, or nil.
        local function GetAnchorPart(Instance_)
            if Instance_:IsA("BasePart") then
                return Instance_
            elseif Instance_:IsA("Model") then
                return Instance_.PrimaryPart or Instance_:FindFirstChildWhichIsA("BasePart", true)
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

        local function IsTaggedOrInsideTag(Instance_)
            local Current = Instance_

            while Current and Current ~= workspace do
                if S.Tags[Current] then
                    return true
                end

                Current = Current.Parent
            end

            return false
        end

        --// Something to look for: typed targets, or Show All.
        local function HasTargets()
            return S.ShowAll or next(S.Targets) ~= nil
        end

        --// The instance to tag for this one, and the name to show, or nil.
        local function MatchTarget(Instance_)
            if Instance_:IsA("Model") or Instance_:IsA("BasePart") then
                if S.ShowAll or S.Targets[NormalizeName(Instance_.Name)] then
                    return Instance_, Instance_.Name
                end
            elseif Instance_:IsA("ProximityPrompt") then
                for _, Text in ipairs({ Instance_.ObjectText, Instance_.ActionText }) do
                    if Text ~= "" and S.Targets[NormalizeName(Text)] then
                        local Holder = Instance_.Parent

                        if Holder and Holder:IsA("Attachment") then
                            Holder = Holder.Parent
                        end

                        if Holder then
                            return Holder, Text
                        end
                    end
                end
            end

            return nil
        end

        local function RemoveTag(Instance_)
            local Tag = S.Tags[Instance_]

            if not Tag then
                return
            end

            if Tag.Highlight then
                Tag.Highlight:Destroy()
            end

            Tag.Billboard:Destroy()
            S.Tags[Instance_] = nil
            S.TagCount -= 1
        end

        local function ClearTags()
            for Instance_ in pairs(S.Tags) do
                RemoveTag(Instance_)
            end
        end

        local function CreateBillboard(Part, Name)
            local Billboard = Instance.new("BillboardGui")
            Billboard.Name = "QuestTarget"
            Billboard.Adornee = Part
            Billboard.AlwaysOnTop = true
            Billboard.LightInfluence = 0
            Billboard.MaxDistance = LABEL_MAX_DISTANCE
            Billboard.Size = UDim2.fromOffset(160, 34)
            Billboard.StudsOffset = Vector3.new(0, 2.5, 0)
            Billboard.Parent = GetFolder()

            local Label = Instance.new("TextLabel")
            Label.BackgroundTransparency = 1
            Label.Size = UDim2.fromScale(1, 1)
            Label.Font = UI.Fonts.Bold
            Label.Text = Name
            Label.TextColor3 = ESP_COLOR
            Label.TextStrokeTransparency = 0.3
            Label.TextSize = 13
            Label.Parent = Billboard

            return Billboard, Label
        end

        local function AddTag(Instance_, Name)
            if S.Tags[Instance_] or S.TagCount >= MAX_TAGS then
                return
            end

            if IsTaggedOrInsideTag(Instance_) or IsInsideCharacter(Instance_) then
                return
            end

            local Part = GetAnchorPart(Instance_)

            if not Part then
                return
            end

            local Billboard, Label = CreateBillboard(Part, Name)

            S.Tags[Instance_] = { Target = Instance_, Part = Part, Name = Name, Billboard = Billboard, Label = Label }
            S.TagCount += 1
        end

        local function TryTag(Instance_)
            if not S.Enabled or (S.Folder and Instance_:IsDescendantOf(S.Folder)) then
                return
            end

            local Target, Name = MatchTarget(Instance_)

            if Target then
                AddTag(Target, Name)
            end
        end

        local function FullScan()
            ClearTags()

            if not S.Enabled or not HasTargets() then
                return
            end

            local Folder = GetQuestItemsFolder()

            for _, Descendant in ipairs(Folder and Folder:GetDescendants() or {}) do
                TryTag(Descendant)
            end
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

        local function SetStatus(Text)
            if S.StatusLabel then
                S.StatusLabel.Text = Text
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
                local Color = Index == 1 and NEAREST_COLOR or ESP_COLOR
                Tag.Label.Text = string.format("%s  [%d]", Tag.Name, math.floor(Tag.Distance + 0.5))
                Tag.Label.TextColor3 = Color
                SetHighlight(Tag, Index <= MAX_HIGHLIGHTS, Color)
            end

            if not S.Enabled then
                SetStatus("QUEST ESP OFF")
            elseif not HasTargets() then
                SetStatus("TYPE A QUEST TARGET NAME OR TURN ON SHOW ALL")
            elseif Sorted[1] then
                SetStatus(string.format("FOUND %d  ·  NEAREST %s  %d STUDS", #Sorted, Sorted[1].Name, math.floor(Sorted[1].Distance + 0.5)))
            else
                SetStatus((S.QuestItems and S.QuestItems.Parent)
                    and "NOTHING FOUND IN QUESTITEMS (MAY NOT HAVE LOADED IN)"
                    or "NO QUESTITEMS FOLDER LOADED")
            end
        end

        function Module:Update(DeltaTime)
            if not S.Enabled then
                return
            end

            S.Elapsed += DeltaTime

            if S.Elapsed < UPDATE_INTERVAL then
                return
            end

            S.Elapsed = 0
            UpdateTags()
        end

        ------------------------------------------------------------------------
        --// Quest info dump
        ------------------------------------------------------------------------

        local function DescribeValue(Instance_)
            local Parts = { Instance_:GetFullName(), "(" .. Instance_.ClassName .. ")" }

            if Instance_:IsA("ValueBase") then
                table.insert(Parts, "= " .. tostring(Instance_.Value))
            elseif Instance_:IsA("TextLabel") or Instance_:IsA("TextButton") then
                table.insert(Parts, "text: " .. Instance_.Text)
            end

            for Name, Value in pairs(Instance_:GetAttributes()) do
                table.insert(Parts, "@" .. Name .. "=" .. tostring(Value))
            end

            return table.concat(Parts, " ")
        end

        --// Root and every descendant whose own name or an ancestor's (below
        --// Root) holds "quest", up to DUMP_SECTION_LIMIT lines.
        local function DumpQuestish(Lines, Title, Root, All)
            table.insert(Lines, "== " .. Title)

            if not Root then
                table.insert(Lines, "(missing)")
                return
            end

            local Count = 0

            for _, Descendant in ipairs(Root:GetDescendants()) do
                local Path = string.lower(Descendant:GetFullName())

                if All or string.find(Path, "quest", 1, true) then
                    local Visible = not Descendant:IsA("GuiObject") or Descendant.Visible

                    if Visible then
                        table.insert(Lines, DescribeValue(Descendant))
                        Count += 1

                        if Count >= DUMP_SECTION_LIMIT then
                            table.insert(Lines, "... cut at " .. DUMP_SECTION_LIMIT)
                            return
                        end
                    end
                end
            end
        end

        local function CopyQuestInfo()
            local Player = Context.Player
            local Lines = { "AIC quest dump  PlaceId " .. tostring(game.PlaceId) }

            DumpQuestish(Lines, "Character values", Player.Character, false)

            local Character = Player.Character

            for _, Name in ipairs({ "QG", "IgnoreNPCs" }) do
                local Value = Character and Character:FindFirstChild(Name)
                table.insert(Lines, Name .. " = " .. (Value and Value:IsA("ValueBase") and tostring(Value.Value) or "(none)"))
            end

            DumpQuestish(Lines, "Player", Player, false)
            DumpQuestish(Lines, "PlayerGui", Player:FindFirstChildOfClass("PlayerGui"), false)
            DumpQuestish(Lines, "ReplicatedStorage", Replicated, false)
            DumpQuestish(Lines, "Workspace", workspace, false)

            local Text = table.concat(Lines, "\n")
            local Copied = type(setclipboard) == "function" and pcall(setclipboard, Text)
            local Saved = false

            if AICProfile.CanUseFileStorage() then
                AICProfile.EnsureProfileFolder()
                Saved = pcall(writefile, QUEST_DUMP_FILE, Text)
            end

            NotifyAction("QUEST", string.format(
                "%d lines%s%s", #Lines,
                Copied and " · copied" or "",
                Saved and (" · saved to " .. QUEST_DUMP_FILE) or ""
            ), 5)
        end

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        local Section = UIRef.QuestHelperSection

        S.StatusLabel = Section:AddLabel("QUEST ESP OFF")

        Section:AddToggle("Quest ESP", false, function(Value)
            S.Enabled = Value

            if Value then
                FullScan()
                UpdateTags()
            else
                ClearTags()
                SetStatus("QUEST ESP OFF")
            end
        end)

        Section:AddToggle("Show All Quest Items", false, function(Value)
            S.ShowAll = Value
            FullScan()
            UpdateTags()
        end)

        UIRef.QuestTargetsBox = Section:AddTextbox("Quest Targets", "", function(Value)
            S.Targets = ParseTargets(Value)
            FullScan()
            UpdateTags()
        end)

        Section:AddButton("Rescan Quest Targets", function()
            FullScan()
            UpdateTags()
            NotifyAction("QUEST", S.TagCount .. " target(s) tagged")
        end)

        Section:AddButton("Copy Quest Info", CopyQuestInfo)

        Context.Connect(workspace.DescendantAdded, function(Descendant)
            if not S.Enabled or not HasTargets() then
                return
            end

            --// The folder itself streamed in: tag what it holds.
            if Descendant.Name == QUEST_ITEMS_FOLDER and not (S.QuestItems and S.QuestItems.Parent) then
                S.QuestItems = Descendant

                for _, Item in ipairs(Descendant:GetDescendants()) do
                    TryTag(Item)
                end

                return
            end

            if S.QuestItems and Descendant:IsDescendantOf(S.QuestItems) then
                TryTag(Descendant)
            end
        end)

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
