-- Stubbed Roblox services for local testing.
--
-- This file installs just enough of the Roblox environment for the pure
-- Runtime/ProfileManager logic to run under the Luau CLI. It is NOT a full
-- emulator; only the pieces the modules touch are provided.

local Stub = {}

local function NewInstance(className)
    local inst = { ClassName = className, Parent = nil, Name = className }
    function inst:IsA(name)
        return self.ClassName == name
    end
    function inst:FindFirstChild()
        return nil
    end
    function inst:FindFirstChildOfClass()
        return nil
    end
    function inst:GetChildren()
        return {}
    end
    function inst:WaitForChild()
        return nil
    end
    function inst:Destroy() end
    return inst
end

local function NewSection()
    return {
        AddToggle = function() return { Set = function() end } end,
        AddSlider = function() return { Set = function() end } end,
        AddDropdown = function() return { Set = function() end } end,
        AddButton = function() return {} end,
        AddLabel = function() return {} end,
        AddTextbox = function() return {} end,
    }
end

local function NewTab()
    return {
        AddSection = function() return NewSection() end,
    }
end

local UI = {
    AddTab = function() return NewTab() end,
    Notify = function() end,
    SetTheme = function() end,
}

local PlayerGui = NewInstance("PlayerGui")
local LocalPlayer = NewInstance("Player")
LocalPlayer.WaitForChild = function(_, name)
    if name == "PlayerGui" then
        return PlayerGui
    end
    return nil
end

local Services = {}
Services.Players = { LocalPlayer = LocalPlayer }
Services.ReplicatedStorage = NewInstance("ReplicatedStorage")
Services.StarterGui = NewInstance("StarterGui")
Services.RunService = NewInstance("RunService")
Services.UserInputService = NewInstance("UserInputService")
Services.MarketplaceService = NewInstance("MarketplaceService")
Services.PathfindingService = NewInstance("PathfindingService")
Services.HttpService = NewInstance("HttpService")

game = {
    PlaceId = 0,
    GetService = function(_, name)
        return Services[name] or NewInstance(name)
    end,
    HttpGet = function()
        return ""
    end,
}

function typeof(value)
    if type(value) == "table" and value.ClassName then
        return "Instance"
    end
    return type(value)
end

Color3 = {
    fromRGB = function(r, g, b)
        return { R = r / 255, G = g / 255, B = b / 255 }
    end,
    new = function(r, g, b)
        return { R = r, G = g, B = b }
    end,
}

local function NewVector3(x, y, z)
    return { X = x or 0, Y = y or 0, Z = z or 0 }
end

Vector3 = {
    new = NewVector3,
    zero = NewVector3(0, 0, 0),
}

task = {
    wait = function() end,
    spawn = function(fn) fn() end,
    defer = function(fn) fn() end,
    delay = function(_, fn) fn() end,
}

--// Roblox has warn() as a global; the Luau CLI does not.
warn = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    print("[warn]", table.concat(parts, " "))
end

Stub.game = game
Stub.UI = UI
Stub.LocalPlayer = LocalPlayer
Stub.PlayerGui = PlayerGui
Stub.NewInstance = NewInstance
Stub.Services = Services

return Stub
