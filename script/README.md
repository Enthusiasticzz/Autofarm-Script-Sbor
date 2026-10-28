# Automated Industry Complex

A Roblox auto-farm script written in Luau. It plays the game for you — fights
mobs on your target list, walks your route, mines ore, smiths recipes, and
handles the small stuff like re-filling boosters and staying un-AFK.

You only load one file; everything else is pulled from this repo automatically.

## Run it

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/script/Init.lua"))()
```

`Init.lua` is the only file you load by hand. It lives in this `script/` folder
and downloads every module next to it from the same folder in this repository,
so **a change only reaches the game once it is pushed to `main` here** — and
pointing an executor at a single feature file does nothing.

Behind the scenes it fetches `UI/Utils.lua` plus the 65 modules in `MODULES`
(66 requests), compiles them, and starts them in dependency order. It needs an
executor (`loadstring`, `game:HttpGet`, `LocalPlayer`/`PlayerGui`).


### Options

- **Run from a fork or a pinned build.** The download base is `BASE` at the top
  of `Init.lua`, and it points at this `script/` folder. Set
  `getgenv().AICBaseURL` before loading to point it somewhere else (include the
  folder, e.g. `.../<sha>/script/`); `Core/Runtime.lua` reads the same override
  when it fetches `UI/Utils.lua` on its own. Pin a version by swapping `main`
  for a commit SHA.
- **Running it twice** stops the previous run (kept in `getgenv().AICSession`).
- **If a module fails to load**, you'll see `LOAD FAILED  //  ...` on the loading
  window.

## Making it actually fight

The script attacks a guest list, and that list starts empty — so with no setup
it moves and does nothing, silently. See **[QUICKSTART.md](QUICKSTART.md)** for
the four steps that turn it on, and **[USAGE.md](USAGE.md)** for what every
feature does, what it needs before it acts, and what its status line means.

## What's included

The feature modules, roughly grouped:

- **Combat & farming** — AutoFarming, AutoBlock, SafeCombat, JumpWhileFighting,
  AutoSkill, AutoFind, AutoPatrol, EnemyPriority, MobGather.
- **Zones & movement** — Waypoints (+ WaypointLoop), Farmzone, Deadzone,
  Minezone, WalkController, ReturnToFarmZone, IgnoreFarmZone, TeleportNavigate.
- **Boss route** — BossNavigator: its own tab, its own saved stop list, a
  recorded **Path to Boss** per stop (walked point to point) and a reset after
  each kill, separate from the farming and profile waypoints.
- **Jobs** — AutoMining, AutoSmithing (with SmithingRecipes, SmithingMinigame,
  SmithingBrowser, SmithingDetail).
- **Support** — AutoHeal, AutoRefill (Refill Booster), SafeBoosterReset,
  ResetStats, AntiAFK, FpsBoost, AutoStartGame, DebugVisualizer.
- **Servers & players** — PartySystem, ServerHop, ServerUI, FollowerGuard,
  QuestHelper/QuestAssign.
- **Browsers & UI data** — MobBrowser, AssetBrowser, MobDictionary, AssetDictionary.
  The Asset Explorer's **Dump Database** button writes every item, recipe and
  mob it can read to `AutoFarmProfiles/DatabaseDump.json` (DatabaseDump).

Waypoints, Farmzone and Deadzone are spatial modules and are not part of Profile
Settings.

## Saved values

`Core/SaveConfig.lua` is the single schema for everything a profile saves:
`Features` lists every toggle (default and export key) and `Settings` lists every
setting. Runtime, ProfileManager, and the UI all read from it, so adding an entry
there is enough to save, load, export, and refresh a value — no other file needs
touching.

## Adding a feature

1. Create `Features/MyFeature.lua` returning
   `{ Name = "MyFeature", Dependencies = {...}, Start = function(Context) ... end }`.
2. Add `"Features/MyFeature.lua"` to `START_ORDER` in `ModuleConfig.lua`, and mirror
   it in the fallback `MODULES` array in `Init.lua`.
3. Add `{ Name = "MyFeature", Default = false, Key = "<unused letter>" }` to
   `SaveConfig.Features`.
4. In `Start`, call `Context.AICUI.BindFeatureToggle("MyFeature", "My Feature", OnChanged)`
   and read `Context.Feature.MyFeature.Enabled`.

`Core/Runtime.lua` is still a compatibility layer holding much of the original
implementation; it is being split out feature-by-feature.

