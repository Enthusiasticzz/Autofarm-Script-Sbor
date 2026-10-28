-- Tests for Runtime's pure config normalizers.
--
-- Runs the real Core/Runtime.lua Start() against stubbed Roblox services, then
-- exercises the normalizers it exposes on Context.AICConfig.

require("./StubRoblox")

local Runtime = require("../script/Core/Runtime")

local function BuildContext()
    local SaveConfig = {
        Settings = {},
        Features = {
            { Name = "AutoFarm", Default = true, Key = "AF" },
            { Name = "AutoBlock", Default = true, Key = "AB" },
        },
        GetSettingDefault = function(_, entry)
            return entry.Default
        end,
    }

    return {
        SaveConfig = SaveConfig,
        UI = require("./StubRoblox").UI,
    }
end

local Context = BuildContext()
Runtime.Start(Context)

local Config = Context.AICConfig

local Tests = {}

local function Check(name, fn)
    table.insert(Tests, { name = name, fn = fn })
end

local function Equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

Check("NormalizeWaitList clamps and pads", function()
    local result = Config.NormalizeWaitList({ 100, -5, 999 }, 4)
    Equal(result[1], 100, "valid value preserved")
    Equal(result[2], 0, "negative clamped to 0")
    Equal(result[3], 600, "over-max clamped to MAX_WAYPOINT_WAIT")
    Equal(result[4], 0, "missing value becomes 0")
end)

Check("NormalizeWaitList handles nil input", function()
    local result = Config.NormalizeWaitList(nil, 2)
    Equal(result[1], 0, "nil list index 1")
    Equal(result[2], 0, "nil list index 2")
end)

Check("NormalizeJumpList coerces to booleans", function()
    local result = Config.NormalizeJumpList({ true, false, nil }, 3)
    Equal(result[1], true, "true preserved")
    Equal(result[2], false, "false preserved")
    Equal(result[3], false, "missing becomes false")
end)

Check("NormalizeZonePairs drops out-of-range zones", function()
    local result = Config.NormalizeZonePairs({ 1, 5, 0 }, 3, 3)
    Equal(result[1], 1, "in-range preserved")
    Equal(result[2], 0, "above zone count becomes 0")
    Equal(result[3], 0, "zero stays 0")
end)

Check("CloneTargetList dedupes and filters", function()
    local result = Config.CloneTargetList({ "A", "A", "", "B", 3 })
    Equal(#result, 2, "two unique strings kept")
    Equal(result[1], "A", "first kept")
    Equal(result[2], "B", "second kept")
end)

Check("CheckJumpWaypoint reports reach", function()
    local ok, reached = Config.CheckJumpWaypoint({ WAYPOINT_JUMPS = { [1] = true } }, 1, 1)
    Equal(ok, true, "jump flagged")
    Equal(reached, true, "within reach")
end)

return {
    Name = "TestConfig",
    Tests = Tests,
}
