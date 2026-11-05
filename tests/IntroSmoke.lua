-- Run the real cinematic with instant tweens and controlled cancellation.
UDim2.__sub = function(a, b)
    return UDim2.new(a.X.Scale - b.X.Scale, a.X.Offset - b.X.Offset, a.Y.Scale - b.Y.Scale, a.Y.Offset - b.Y.Offset)
end
Random = { new = function()
    return {
        NextNumber = function(_, low, high) return low and (low + high) / 2 or 0.5 end,
        NextInteger = function(_, low) return low end,
    }
end }
local lighting = Instance.new("Folder")
Services.Lighting = lighting
local topbar = false
Services.StarterGui = {
    GetCore = function() return topbar end,
    SetCore = function(_, _, value) topbar = value end,
}
Services.TextService = { GetTextSize = function() return Vector2.new(500, 100) end }
-- Background particle loops are scheduled rather than run synchronously.
task.spawn = function() end
local waits, cancelAt, cleanup, lifetime, startup
task.wait = function()
    waits += 1
    if startup and not startup.Ready and waits >= 12 then
        -- Simulate module startup continuing while the intro is holding.
        startup.HeartbeatStarted = true
        startup.Ready = true
    end
    RunService.Heartbeat:Fire(1/60)
    if waits == cancelAt then
        lifetime.Alive = false
        cleanup()
    end
end
local playerGui = Players.LocalPlayer.PlayerGui
playerGui.Name = "PlayerGui"
playerGui.Parent = Players.LocalPlayer
local function run(cancel, boot)
    waits, cancelAt = 0, cancel
    startup = boot
    if boot then
        boot.AttachIntro = function(gui)
            boot.IntroGui = gui
            gui.Parent = Services.CoreGui
        end
    end
    lifetime = { Alive = true, OnEnd = function(fn) cleanup = fn end }
    Intro.Start({ Lifetime = lifetime, Startup = startup })
    assert(not playerGui:FindFirstChild("GildedArchiveIntro"), "intro still covers the menu after Start returns")
    assert(not Services.CoreGui:FindFirstChild("GildedArchiveIntro"), "intro in the menu container survived cleanup")
    assert(not lighting:FindFirstChild("GildedArchiveBlur"), "intro blur leaked")
    assert(topbar == false, "intro changed the original topbar state")
    cleanup() -- A later script replay must not restore stale UI state.
end
run(nil)
assert(waits > 5, "intro returned before completing its animation sequence")
local boot = { Ready = false, IntroDone = false, AutomationReady = false }
local Updates = 0
local Hb = HeartbeatModule.Start({Startup=boot, Services={RunService=RunService}})
Hb:Start({{Name="AutoFarm",Update=function() Updates += 1 end}})
local revealedAt
boot.RevealMenu = function()
    assert(boot.Ready and boot.HeartbeatStarted, "menu revealed before boot readiness")
    assert(not boot.AutomationReady and Updates==0, "gameplay started while menu was being prepared under intro")
    assert(boot.IntroGui and boot.IntroGui.Parent == Services.CoreGui, "intro and menu are in different UI containers")
    assert(boot.IntroGui.DisplayOrder > 999999, "menu/ESP can cover the intro")
    revealedAt = waits
end
run(nil, boot)
assert(boot.HeartbeatStarted and waits > 12, "intro did not wait for heartbeat readiness before exiting")
assert(revealedAt == 12 and waits > revealedAt, "menu was not revealed before the intro exit animation")
assert(Updates==0,"gameplay updated during intro")
boot.IntroDone=true -- Init sets this only after Intro.Start returns/cleans up.
RunService.Heartbeat:Fire(1/60)
assert(Updates==0,"intro cleanup alone started gameplay before the menu rendered")
local renderWait=RunService.RenderStepped.Wait
local rendered=false
RunService.RenderStepped.Wait=function()
    assert(not boot.AutomationReady and not Services.CoreGui:FindFirstChild("GildedArchiveIntro"),"automation released before intro removal")
    RunService.Heartbeat:Fire(1/60)
    assert(Updates==0,"automation ran in the handoff frame")
    rendered=true
end
boot.RevealMenu=function() end -- Already laid out beneath the fading intro.
ReleaseStartup({Startup=boot,Lifetime=lifetime,UI={},Services={RunService=RunService}})
RunService.RenderStepped.Wait=renderWait
assert(rendered and boot.AutomationReady,"startup didn't wait for a rendered frame")
RunService.Heartbeat:Fire(1/60)
assert(Updates==1,"automation didn't begin after intro and first menu frame")
Hb:Destroy()
run(1)
assert(waits == 1, "a cancelled intro kept playing")
local create = TweenService.Create
TweenService.Create = function() error("unsupported tween") end
local ok = pcall(run, nil)
TweenService.Create = create
assert(not ok, "intro test failed to inject the visual error")
assert(not playerGui:FindFirstChild("GildedArchiveIntro"), "failed intro leaked its GUI")
assert(not lighting:FindFirstChild("GildedArchiveBlur"), "failed intro leaked its blur")
assert(topbar == false, "failed intro changed the topbar state")
print("INTRO SMOKE PASSED: menu prelayout, no gameplay during intro, rendered-frame handoff, cancellation/error cleanup")
