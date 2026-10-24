-- QuestAssign owns the Quest tab: a quest ID typed in is sent to the game's
-- own QuestEvent remote as ("AssignQuest", ID), the same call the quest
-- givers make, so any quest can be taken from anywhere.
return {
    Name = "QuestAssign",
    Dependencies = {"Runtime", "Components"},

    Start = function(Context)
        local Replicated = Context.Services.Replicated
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        local REMOTE_NAME = "QuestEvent"
        local ASSIGN_ACTION = "AssignQuest"

        local Module = { Name = "QuestAssign" }

        local function GetRemote()
            local Remote = Replicated:FindFirstChild(REMOTE_NAME, true)
            return Remote and Remote:IsA("RemoteEvent") and Remote or nil
        end

        --// The typed quest ID without surrounding spaces, or nil when empty.
        local function ReadQuestId(Text)
            local Id = string.match(tostring(Text or ""), "^%s*(.-)%s*$")
            return Id ~= "" and Id or nil
        end

        --// True when the request went out.
        local function AssignQuest(QuestId)
            local Remote = GetRemote()

            if not Remote then
                NotifyAction("QUEST", REMOTE_NAME .. " was not found in this place", 5)
                return false
            end

            local Success, Error = pcall(function()
                Remote:FireServer(ASSIGN_ACTION, QuestId)
            end)

            if not Success then
                NotifyAction("QUEST", "Assign quest failed: " .. tostring(Error), 5)
                return false
            end

            NotifyAction("QUEST", "Asked for quest " .. QuestId)
            return true
        end

        local Section = UIRef.QuestSection

        UIRef.QuestIdBox = Section:AddTextbox("Quest ID", "", function() end)

        Section:AddButton("Assign Quest", function()
            local QuestId = ReadQuestId(UIRef.QuestIdBox:Get())

            if not QuestId then
                NotifyAction("QUEST", "Enter a quest ID first", 4)
                return
            end

            AssignQuest(QuestId)
        end)

        return Module
    end,
}
