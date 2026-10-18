-- TeleportNavigate owns the Teleport tab, ported from Iambatman's
-- TeleportSystem. Both ways ask the game's own TeleportEvent remote to move
-- us:
--   Door Teleport: the T1/T2 points of every Door in workspace.Interactions
--     (the remote takes the point's position);
--   Waypoint Teleport: the game's waypoints in workspace.Waypoints (the
--     remote takes the waypoint number), or any number typed in, which is
--     sent straight away without waiting for that waypoint to load in.
return {
    Name = "TeleportNavigate",
    Dependencies = {"Runtime", "Components"},

    Start = function(Context)
        local Services = Context.Services
        local Replicated = Services.Replicated
        local Runtime = Context.Runtime
        local UIRef = Context.UIRef
        local NotifyAction = Context.NotifyAction

        local REMOTE_NAME = "TeleportEvent"
        local DOORS_FOLDER = "Interactions"
        local WAYPOINTS_FOLDER = "Waypoints"
        local DOOR_NAME = "Door"
        local DOOR_POINTS = {"T1", "T2"}
        --// Folder changes arriving within this are one refresh.
        local REFRESH_DEBOUNCE = 0.5
        local NO_DOORS = "No doors found"
        local DEFAULT_WAYPOINT = "#0  Default"
        --// A teleport lands on a door's own prompt; the farm's Interact presses
        --// would fire it again on the way out. Ten seconds is long enough to
        --// walk clear, and every presser honours it (Runtime:MuteInteract).
        local INTERACT_MUTE = 10

        local Module = {
            Name = "TeleportNavigate",
            S = {
                --// Dropdown label -> the door point part.
                DoorPoints = {},
                --// Dropdown label -> waypoint number.
                WaypointNumbers = {},
                DoorDropdown = nil,
                WaypointDropdown = nil,
                FolderConnections = {},
                RefreshScheduled = false,
            },
        }

        local S = Module.S

        local function GetRemote()
            local Remote = Replicated:FindFirstChild(REMOTE_NAME, true)
            return Remote and Remote:IsA("RemoteEvent") and Remote or nil
        end

        --// Sends the request; Value is a door point position or a waypoint
        --// number. True when it went out.
        local function FireTeleport(Value, What)
            local Remote = GetRemote()

            if not Remote then
                NotifyAction("TELEPORT", REMOTE_NAME .. " was not found in this place", 5)
                return false
            end

            local Success, Error = pcall(function()
                Remote:FireServer(Value)
            end)

            if not Success then
                NotifyAction("TELEPORT", "Teleport request failed: " .. tostring(Error), 5)
                return false
            end

            NotifyAction("TELEPORT", "Teleporting to " .. What)

            if Runtime and Runtime.MuteInteract then
                Runtime:MuteInteract(INTERACT_MUTE)
            end

            return true
        end

        --// Puts a fresh dropdown where the old one was, keeping its choice
        --// when that is still an option. The library's dropdowns have a
        --// fixed option list, so a new list means a new dropdown.
        --// The same list keeps the old dropdown: the folders change all the
        --// time as parts stream in and out, and rebuilding on each change
        --// swapped the button out between press and release, so clicks on
        --// it were lost.
        local function RebuildDropdown(Section, Old, Name, Options)
            if Old and Old.Options and table.concat(Old.Options, "\n") == table.concat(Options, "\n") then
                return Old
            end

            local LayoutOrder = Old and Old.Frame and Old.Frame.LayoutOrder
            local Previous = Old and Old:Get()

            if Old then
                if Old.Popup then
                    Old.Popup:Destroy()
                end

                if Old.Frame then
                    Old.Frame:Destroy()
                end
            end

            local Dropdown = Section:AddDropdown(Name, Options, function() end)

            if LayoutOrder then
                Dropdown.Frame.LayoutOrder = LayoutOrder
            end

            if Previous and table.find(Options, Previous) then
                Dropdown:Set(Previous, false)
            end

            return Dropdown
        end

        ------------------------------------------------------------------------
        --// Door Teleport
        ------------------------------------------------------------------------

        local function GetDoorPlace(Door)
            local Place = Door:FindFirstChild("Place")
            return Place and Place:IsA("ValueBase") and tostring(Place.Value) or nil
        end

        --// "<place>  T1" per point of every door, sorted by place.
        local function ReadDoorOptions()
            table.clear(S.DoorPoints)

            local Folder = workspace:FindFirstChild(DOORS_FOLDER)
            local Options = {}

            for _, Door in ipairs(Folder and Folder:GetChildren() or {}) do
                local Place = Door:IsA("Model") and Door.Name == DOOR_NAME and GetDoorPlace(Door)

                if Place then
                    for _, PointName in ipairs(DOOR_POINTS) do
                        local Point = Door:FindFirstChild(PointName)

                        if Point and Point:IsA("BasePart") then
                            local Label = Place .. "  " .. PointName
                            local Suffix = 2

                            --// Two doors to the same place stay separate.
                            while S.DoorPoints[Label] do
                                Label = string.format("%s  %s (%d)", Place, PointName, Suffix)
                                Suffix += 1
                            end

                            S.DoorPoints[Label] = Point
                            table.insert(Options, Label)
                        end
                    end
                end
            end

            table.sort(Options, function(A, B)
                return string.lower(A) < string.lower(B)
            end)

            if #Options == 0 then
                Options = {NO_DOORS}
            end

            return Options
        end

        local function RefreshDoors()
            S.DoorDropdown = RebuildDropdown(UIRef.DoorTeleportSection, S.DoorDropdown, "Door", ReadDoorOptions())
        end

        local function TeleportToDoor()
            local Label = S.DoorDropdown and S.DoorDropdown:Get()
            local Point = Label and S.DoorPoints[Label]

            if not Point or not Point.Parent then
                NotifyAction("TELEPORT", "Pick a door first (press Refresh Doors if the list is old)", 4)
                return
            end

            FireTeleport(Point.Position, Label)
        end

        ------------------------------------------------------------------------
        --// Waypoint Teleport
        ------------------------------------------------------------------------

        --// "#0  Default", then every numbered waypoint in the folder.
        local function ReadWaypointOptions()
            table.clear(S.WaypointNumbers)

            local Folder = workspace:FindFirstChild(WAYPOINTS_FOLDER)
            local Numbers = {}

            for _, Waypoint in ipairs(Folder and Folder:GetChildren() or {}) do
                local Number = tonumber(Waypoint.Name)

                if Number and Number % 1 == 0 and Number ~= 0 and not table.find(Numbers, Number) then
                    table.insert(Numbers, Number)
                end
            end

            table.sort(Numbers)

            local Options = {DEFAULT_WAYPOINT}
            S.WaypointNumbers[DEFAULT_WAYPOINT] = 0

            for _, Number in ipairs(Numbers) do
                local Label = "#" .. tostring(Number)
                S.WaypointNumbers[Label] = Number
                table.insert(Options, Label)
            end

            return Options
        end

        local function RefreshWaypoints()
            S.WaypointDropdown = RebuildDropdown(UIRef.WaypointTeleportSection, S.WaypointDropdown, "Waypoint", ReadWaypointOptions())
        end

        local function TeleportToWaypoint(Number)
            FireTeleport(Number, "waypoint #" .. tostring(Number))
        end

        --// The typed number as a whole number of 0 or more, or nil.
        local function ParseWaypointNumber(Text)
            local Number = tonumber((tostring(Text or ""):gsub("[%s#]", "")))

            if not Number or Number % 1 ~= 0 or Number < 0 then
                return nil
            end

            return Number
        end

        ------------------------------------------------------------------------
        --// Folder watching
        ------------------------------------------------------------------------

        local function ScheduleRefresh()
            if S.RefreshScheduled then
                return
            end

            S.RefreshScheduled = true

            task.delay(REFRESH_DEBOUNCE, function()
                S.RefreshScheduled = false

                if not Context.Lifetime.Alive then
                    return
                end

                --// Never rebuild a list the user has open; try again later.
                if (S.DoorDropdown and S.DoorDropdown.IsOpen)
                    or (S.WaypointDropdown and S.WaypointDropdown.IsOpen)
                then
                    ScheduleRefresh()
                    return
                end

                RefreshDoors()
                RefreshWaypoints()
            end)
        end

        --// Watches the two folders that exist now; called again, with a
        --// refresh, whenever one of them appears or goes.
        local function BindFolders(Refresh)
            Context.Lifetime.Disconnect(S.FolderConnections)

            for _, FolderName in ipairs({DOORS_FOLDER, WAYPOINTS_FOLDER}) do
                local Folder = workspace:FindFirstChild(FolderName)

                if Folder then
                    table.insert(S.FolderConnections, Folder.ChildAdded:Connect(ScheduleRefresh))
                    table.insert(S.FolderConnections, Folder.ChildRemoved:Connect(ScheduleRefresh))
                end
            end

            if Refresh then
                ScheduleRefresh()
            end
        end

        local function OnWorkspaceChild(Child)
            if Child.Name == DOORS_FOLDER or Child.Name == WAYPOINTS_FOLDER then
                task.defer(BindFolders, true)
            end
        end

        ------------------------------------------------------------------------
        --// UI
        ------------------------------------------------------------------------

        local DoorSection = UIRef.DoorTeleportSection
        local WaypointSection = UIRef.WaypointTeleportSection

        S.DoorDropdown = DoorSection:AddDropdown("Door", ReadDoorOptions(), function() end)

        DoorSection:AddButton("Teleport To Door", TeleportToDoor)
        DoorSection:AddButton("Refresh Doors", RefreshDoors)

        S.WaypointDropdown = WaypointSection:AddDropdown("Waypoint", ReadWaypointOptions(), function() end)

        WaypointSection:AddButton("Teleport To Waypoint", function()
            local Label = S.WaypointDropdown and S.WaypointDropdown:Get()
            local Number = Label and S.WaypointNumbers[Label]

            if Number == nil then
                NotifyAction("TELEPORT", "Pick a waypoint first", 4)
                return
            end

            TeleportToWaypoint(Number)
        end)

        WaypointSection:AddButton("Refresh Waypoints", RefreshWaypoints)

        UIRef.WaypointNumberBox = WaypointSection:AddTextbox("Waypoint Number", "", function() end)

        WaypointSection:AddButton("Teleport To Number", function()
            local Number = ParseWaypointNumber(UIRef.WaypointNumberBox:Get())

            if not Number then
                NotifyAction("TELEPORT", "Enter a waypoint number (0 or more)", 4)
                return
            end

            TeleportToWaypoint(Number)
        end)

        Context.Connect(workspace.ChildAdded, OnWorkspaceChild)
        Context.Connect(workspace.ChildRemoved, OnWorkspaceChild)

        Context.Lifetime.OnEnd(function()
            Context.Lifetime.Disconnect(S.FolderConnections)
        end)

        BindFolders(false)

        return Module
    end,
}
