-- Shared-environment test runner.
--
-- In Roblox (or any host that shares globals between modules) run this file
-- directly. Under the standalone Luau CLI, modules are sandboxed and cannot
-- see each other's globals, so use tests/run-cli.ps1 instead: it embeds the
-- sources into one chunk.

if type(game) == "nil" then
    print("Standalone Luau CLI detected.")
    print("Run the tests with: powershell -ExecutionPolicy Bypass -File tests/run-cli.ps1")
    return
end

local Suites = {
    require("./TestConfig"),
    require("./TestSerialization"),
    require("./TestStateMachines"),
}

local Passed, Failed = 0, 0

for _, Suite in ipairs(Suites) do
    print(string.format("-- %s --", Suite.Name or "suite"))

    for _, Test in ipairs(Suite.Tests or {}) do
        local Ok, Err = pcall(Test.fn)

        if Ok then
            Passed += 1
            print(string.format("  ✓ %s", Test.name))
        else
            Failed += 1
            print(string.format("  ✗ %s: %s", Test.name, tostring(Err)))
        end
    end
end

print(string.format("\n%d passed, %d failed", Passed, Failed))

if Failed > 0 then
    error(string.format("%d test(s) failed", Failed), 0)
end
