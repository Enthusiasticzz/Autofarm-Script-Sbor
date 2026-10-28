-- Tests for ProfileManager serialization.
--
-- These require a shared global environment (Roblox/executor). For the local
-- Luau CLI, use tests/run-cli.ps1, which embeds the sources into one chunk
-- because the CLI sandboxes each module's globals.

require("./StubRoblox")

local RuntimeModule = require("../script/Core/Runtime")
local ProfileManager = require("../script/Core/ProfileManager")
local Stub = require("./StubRoblox")

local function BuildContext()
    local SaveConfig = {
        Settings = {},
        GlobalSettings = {},
        Features = {
            { Name = "AutoFarm", Default = true, Key = "AF" },
            { Name = "AutoBlock", Default = true, Key = "AB" },
        },
        GetSettingDefault = function(_, entry)
            return entry.Default
        end,
        NormalizeSetting = function(_, entry, value)
            if value == nil then
                return entry.Default
            end
            return value
        end,
        GetSetting = function(_, key)
            return { Key = key }
        end,
    }

    local Context = {
        SaveConfig = SaveConfig,
        UI = Stub.UI,
        Lifetime = { OnEnd = function() end },
        Modules = {},
    }

    local Runtime = RuntimeModule.Start(Context)
    Context.Runtime = Runtime
    Context.Services.HttpService = {
        JSONEncode = function(_, value)
            return tostring(value)
        end,
        JSONDecode = function()
            return {}
        end,
    }

    ProfileManager.Start(Context)

    return Context
end

local Context = BuildContext()
local AICProfile = Context.AICProfile

local Tests = {}

local function Check(name, fn)
    table.insert(Tests, { name = name, fn = fn })
end

local function Equal(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

Check("Serialize/Deserialize round-trips a table", function()
    local source = { A = 1, B = "two", C = { D = true } }
    local encoded = AICProfile.SerializeConfigValue(source)
    local decoded = AICProfile.DeserializeConfigValue(encoded)
    Equal(decoded.A, 1, "A")
    Equal(decoded.B, "two", "B")
    Equal(decoded.C.D, true, "C.D")
end)

Check("MergeConfig overrides nested keys", function()
    local merged = AICProfile.MergeConfig(
        { A = 1, Nested = { X = 1, Y = 2 } },
        { Nested = { Y = 9 } }
    )
    Equal(merged.A, 1, "base kept")
    Equal(merged.Nested.X, 1, "nested base kept")
    Equal(merged.Nested.Y, 9, "nested override")
end)

Check("IsArrayTable detects arrays", function()
    Equal(AICProfile.IsArrayTable({ 1, 2, 3 }), true, "array")
    Equal(AICProfile.IsArrayTable({ A = 1 }), false, "map")
end)

return {
    Name = "TestSerialization",
    Tests = Tests,
}
