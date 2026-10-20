# AI-WALKTHROUGH.md

This file provides guidance to LLM's or AI when working with code in this repository.

## What this is

A Roblox auto-farm script ("Automated Industry Complex", aka AutoFarmV3) written in Luau. It has no build, lint or test tooling. Nothing can be run locally: the code only runs inside a Roblox client, so every change is "done but not tested in-game" until the user checks it (`TODO.md` uses `[x]` with that same meaning).

It runs in two ways (`Init.lua`):
- **Remote (executor):** `Init.lua` downloads every file in parallel from `raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/` (or from `getgenv().AICBaseURL` when it is set) and `loadstring`s it. **Pushing to `main` ships the change to users.** Runtime reads the same override for the `UI/Utils.lua` it falls back to.
- **Local (Studio):** when `Init` is a ModuleScript, it `require`s sibling ModuleScripts in folders that mirror the repo layout.

## Module system

Every file except `UI/Utils.lua` returns a spec: `{ Name, Dependencies = {...}, IsFeature?, Start = function(Context) ... end }`. `Name` must match the file name.

- `MODULES` in `Init.lua` is the one list of files: it controls both the download and the start order. Dependencies start first. Start order also sets where each module's UI controls appear in the window.
- Whatever `Start` returns is stored as both `Context.Modules[Name]` and `Context[Name]`. A module returned with `IsFeature` goes into `Context.Features`, and `Core/Heartbeat.lua` calls its `:Update(dt)` every RunService.Heartbeat.
- After all modules have started, Init calls the optional `:BuildLateUI()` on every module (controls that must go below all the toggles), then `:Finalize()` (ProfileSettings restores the last profile here, once every control exists), then starts Heartbeat.
- `Core/Bootstrap.lua` is the composition root. It wires character respawn resets and other cross-module glue.
- `Features/AutoFarming.lua` `Feature:Update` is the main per-frame decision loop (retreat, Auto Block, waypoint route, then combat/patrol). Once the route is walked it first offers the frame to `AICFeature.SmithingStep` (AutoSmithing, also run with Auto Farm off) and then `AICFeature.MiningStep` (AutoMining); a true return means that job moved and fought this frame, and the farm's own combat is skipped.
- `AICFeature.BossStep` (BossNavigator) is offered the frame *before* the waypoint route, and again in the Auto Farm off branch, so the Boss Route runs with Auto Farm on or off and the farm keeps its safety checks (party hold, retreat, Auto Block, server age) ahead of it. While the character is dead Auto Farm returns early, so `AICFeature.BossRecoverStep` is called there to keep a boss reset waiting for its respawn.

## Shared runtime layers

`Core/Runtime.lua` creates the shared state and puts it on Context: `Services`, `Player`, `CONFIG`, `PLACE_CONFIG`, `Feature` (toggle state built from SaveConfig), `UI`/`UIRef`, and seven layer tables. Each layer is declared in Runtime and filled in by other modules:

| Layer | Filled in by |
|---|---|
| `AICConfig` | Runtime |
| `AICProfile` | ProfileManager |
| `AICCombatUtils` | Combat/CombatUtils |
| `AICCombat` | Combat/Targeting, Navigation, Combat (+ Components) |
| `AICFeature` | the Features/* modules |
| `AICUI` | UI/Components (+ some features) |
| `AICDebug` | Features/DebugVisualizer |

Rules from the code comments:
- A layer only calls *downward* in that list (Config → Profile → CombatUtils → Combat → Feature → UI → Debug).
- Mutable state goes on each layer's `.S` table (e.g. `AICCombat.S.ClosestTarget`), not in locals. Runtime.lua previously hit Luau's limit of 200 local registers per chunk and failed to compile. Keep new state on tables in large files.
- Do not rebuild PlaceConfig or the target-priority tables in other modules. ProfileManager and the zone modules already hold references to the tables Runtime made.

Much of the old monolith is still in Runtime.lua ("compatibility layer") and is being moved out feature by feature. Several small Features/* files (AutoHeal, AutoSkill, SafeCombat…) are stubs whose behavior lives in AutoFarming/Combat.

## Saved values: `Core/SaveConfig.lua`

This is the single schema for everything a profile saves. `Features` lists the toggles (`Name`, `Default`, `Key`) and `Settings` lists the settings (default, range/options, normalizers). Runtime, ProfileManager (save/load/export/reset) and Components (refresh) all read from it.

- An export `Key` must never change or be reused, or old exported profiles will load into the wrong toggle.
- A `Global = true` feature (e.g. `DangerGroupHop`) and every entry in `SaveConfig.GlobalSettings` (`DANGER_GROUP_IDS`, `DANGER_WHITELIST`) are kept in `AutoFarmProfiles/Global.json` by ProfileManager (`ReadGlobalStore`/`ApplyGlobalStore`/`WriteGlobalStore`), shared by every profile and PlaceId; profiles never save, load or export them. `PINNED_STATE` is global through its own older mechanism (`PinnedItems.json`).

Adding a feature with a saved toggle (from README):
1. Create `Features/MyFeature.lua` returning the spec.
2. Add its path to `MODULES` in `Init.lua`.
3. Add `{ Name = "MyFeature", Default = false, Key = "<unused letter>" }` to `SaveConfig.Features`.
4. In `Start`, call `Context.AICUI.BindFeatureToggle("MyFeature", "My Feature", OnChanged)` and read `Context.Feature.MyFeature.Enabled`.

Waypoints, Farmzone and Deadzone are spatial modules and are not part of Profile Settings.

## UI

`UI/Utils.lua` (~5.9k lines) is the self-contained window/widget library (`Utils.new(title, opts)`, `AddTab`, `AddPriority`, loader progress…). It is loaded before any spec so the boot loader can show progress. `UI/Components.lua` binds feature toggles and shared controls to it.

The tabs and their sections are all declared in one place at the top of `Core/Runtime.lua` (`UIRef.StatusTab`, `UIRef.FarmTab`, … and `UIRef.FeatureSection`, `UIRef.CombatSection`, …). A feature's controls are **placed** by passing that section to `AICUI.BindFeatureToggle(Name, Label, OnChanged, Section)` (or by calling `Section:AddToggle(...)` directly). `BindFeatureToggle`'s 4th arg defaults to `UIRef.CoreSection` (the `FeatureSection` alias), so a toggle with no explicit section lands in **Core** — always pass the section that matches the feature. The Farming tab is deliberately split into **Core** (Auto Farm, Auto Find, Auto Patrol, Return To Farm Zone, Ignore Farm Zone + the combat HP% sliders), **Combat** (Safe Combat, Jump While Fighting, Auto Skill), **Targeting**, **Auto Block** (Leave Instead Of Block above a `Section:AddDivider()`, then Auto Block and Auto Confirm Block with their settings, not in Core), **Mob Gather** (Gather Mobs) and **Booster Reset** (Refill Booster, Safe Booster Reset); **Auto Start Game** and **FPS Boost** live on the **Utility** tab with the **Webhook** section (`UIRef.WebhookSection`, the Discord report), and the **Debug Visualizer** master toggle on the **Debug** tab. Keep each feature's master toggle with its own settings rather than dumping it in the default section. A control that has to sit inside another module's section is made there with `BindFeatureToggle` (and, when the owning module starts later, reached through an `AICFeature` hook) rather than added by its owner, which would append it to the end of the section — Auto Confirm Block is the example.

Outgoing HTTP goes through `Features/Webhook.lua`'s `PostJSON`, not straight to `HttpService`: executors commonly blacklist `HttpService:RequestAsync`, so it tries the executor's own request function first (`syn.request`, `http.request`, `http_request`, `request`) and only falls back to `HttpService` when none is present. Anything else that has to reach the internet should reuse that helper rather than call `RequestAsync` itself — and note the candidates are appended only when they exist, because `ipairs` over a table whose first slot is `nil` stops immediately and hides every name after it.

Leaving a server has one funnel: call `AICFeature.ReportBeforeLeave(OtherPlayer)` (installed by Webhook) before any `TeleportService:Teleport*`, `TeleportToPlace` or `Player:Kick`, so the Discord report is posted while the client is still running. Pass the player the leave was caused by — the intruder, the Danger Group player, Follower Guard's follower — and the report adds `Left because of: @name (UserId)`; pass nothing when nobody caused it, and the line is left out. `AutoBlock:TeleportToPlace`, `AutoBlock:LeaveGame` (Leave Instead Of Block, which kicks the client out to the Roblox app), `ServerHop:TeleportToInstance`, the Danger Group leave and Follower Guard's kick do this; a new leave path must too. Webhook also listens to `Player.OnTeleport` (`Started` only) for teleports the script did not start, and to `Players.PlayerRemoving` for the local player as the best-effort manual-leave signal. The two can both arrive for one departure, which is why `SendOnLeave` ignores a second call inside eight seconds.

The UI font is chosen in Configuration (`UI:SetFont`, saved as the global `UI_FONT`); text under the ScreenGui and any root passed to `UI:AddFontRoot` follows it, keeping its weight. Code that sets `Font` keeps working: new text is retargeted right after it is created.

Every control in the main window shows a one-line description under its name, looked up by its label in `UI/Descriptions.lua` (`UI:SetDescriptions`; a widget can also take a `description` argument). Add a line there when adding a control. Hovering a button, toggle, dropdown or textbox lights its border in the accent colour. `UI/Floating.lua` builds the floating windows (Server Browser, Recipe Browser) in the same look; `Floating.Section` lets the Utils widgets live inside them.

## Re-execution guard

Running the script again stops the previous run before the new one loads (`Init.lua`, the run is kept in `getgenv().AICSession`). A run ends through `Context.Lifetime`: `Alive` goes false, the `Context.Lifetime.OnEnd` callbacks run newest first (Init's last one stops Heartbeat and the character, then the modules' own, then ProfileManager writes pending saves and closes storage, then the window goes), and every connection made with `Context.Connect` is disconnected. A run of a version from before the guard cannot be stopped; the new run then refuses to start and asks for a rejoin.

When adding code:
- Connect to long-lived signals (Players, Player, workspace, RunService, UserInputService, remotes) with `Context.Connect(Signal, Callback)`, not `Signal:Connect`. Connections on our own UI die with the window.
- Connections a module keeps and rebinds itself (per-mob or per-folder watchers on `S`) stay plain `:Connect`; add a `Context.Lifetime.OnEnd` that calls `Context.Lifetime.Disconnect(...)` on them.
- Loops that never end on their own check `Context.Lifetime.Alive`. Anything created outside the window (in workspace) gets an `OnEnd` that destroys it.

## Committing and pushing

**Always commit and push every change to this repository.** When a task is done,
stage the changes, commit them with a conventional-commit subject (`feat:` /
`fix:` / `docs:` / `chore:`), and push to `origin` on `main`. The download base in
`Init.lua` and `Core/Runtime.lua` points at this repository, so an unpushed change
never reaches the game: committing is part of finishing the task, not a separate
step to wait to be asked for. Commit and push without being prompted.

## Release conventions

Every shipped change bumps the version:
- `TITLE` in `Init.lua` (`"AUTOMATED INDUSTRY COMPLEX vX.YY"`)
- the commit subject ends with `(vX.YY)`. Use conventional-commit prefixes (`feat:`/`fix:`) and a body that explains the behavior and names any new tuning constants.
- `TODO.md` (written in English) gets the request/bug under `## To Do` or `## To Fix` as `### [x] Area: title`, followed by a `> **Done (vX.YY):** ...` / `> **Fixed (vX.YY):** ...` note. Write these notes in English to match.

Tuning values are named UPPER_SNAKE constants near the top of the file that uses them (e.g. `RETREAT_FACE_HOLD`, `SWIM_FACE_MAX_PITCH`).

Note: there is no `Legacy/` folder in the repo.
