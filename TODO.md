# TODO

Status: `[ ]` not started · `[x]` done or fixed (written, not yet verified in-game)

All 102 items are complete — nothing here is pending. This file is the record of
what was asked for and what shipped, oldest work first: `## To Do` lists requested
features, `## To Fix` lists reported bugs. Every item names the version it shipped
in, and the note under it explains what actually changed and which tuning constants
were added.

## To Do

### [x] Party System

- The Leader is set from a player in the server.
- Condition: it has to check whether someone who is not in the whitelist has joined the server, or whether the Party Leader is not in the server.
- If the condition is met, reset the character and stand still, then chat `Tp friend (leaderPartName)`.
- If it still has not teleported to the Leader, it tries 3 attempts until it is sure.

> **Done (Party tab):** enable **Party System** and pick the Leader from the **Set Leader** dropdown (saved in the profile).
> - Someone outside the whitelist joined but the Leader is still there → reset and stand still, wait for the Leader to hop servers first, then follow.
> - The Leader is not in the server → reset, stand still, then chat `Tp friend <username>`, trying 3 times at 15 seconds each.
>   It succeeds when the Leader is in the same server; if it fails it waits 60 seconds before trying again.
> - If a Leader is set, Party handles strangers instead of Auto Block (Auto Block only works during the break after a failed Tp).

### [x] Target Priority

- Players can be added to Target Priority, except yourself.
- It checks that they are a player and are still in the server.

> **Done:** players in the server (except yourself) appear in the **Add Target** dropdown as `@name`; only someone still in the server can be added.
> If they leave the server the target lock is released immediately, using the same rules as mobs (must be inside a Farmzone, not inside a Deadzone).

### [x] Waypoints Looped & Paired Farmzone/Waypoint/Targets

- Once it reaches the last Waypoint, if the Farmzone paired with that Waypoint has no Paired Targets it walks back.
  - Example: there are 10 Waypoints in total; on reaching 10 with no Paired Targets it walks back 10 > 9 > 8 > 7 ... all the way to 1.
- Along the way it looks for Paired Targets in the Paired Farmzone paired with that Waypoint, e.g. Paired Waypoint#1 paired with Farmzone#1.
- If it finds no Paired Targets in any of the Paired Farmzones, it stands and waits until a Target spawns.
- If a Target is added to Paired Farmzone#2 but the character is in another Paired Farmzone, it walks back to that Paired Farmzone along the Waypoints as set up, dynamically.

> **Done:** **Waypoint Loop** is enabled in the Waypoints section (Profile Settings).
> - Pairs a Waypoint with a Farmzone through the **Pair Waypoint** + **Paired Farm Zone** dropdowns (the list shows `> Z#`).
> - Targets for each Farmzone: pick the zone in **Edit Farm Zone**, then add from **Add Zone Target** (empty = use Enemy Priority).
> - Once the route is finished, if the zone paired with that Waypoint has targets it fights in that zone only; if it has none it walks back N > N-1 > ... > 1
>   to find a zone that has targets. If it finds none at all it stands and waits, and as soon as a target spawns in a zone it walks the Waypoints to that zone.
> - While fighting inside the paired zone, Return To Farm Zone / Patrol / target selection apply to that zone only.
> - Limitation: it can only see mobs the game has streamed to us; a zone that is very far away may need walking closer before they become visible.

### [x] Waypoints Priority Wait

- On running up to a Waypoint, a wait of x seconds can be set in the Priority list before going to the next Waypoint.
- The default is 0.
- It is editable from the UI (the Utils UI had to be changed to support it).

> **Done:** the All Waypoints list has a "Wait (s)" number field on every row (0–600 seconds), stored in `PLACE_CONFIG.WAYPOINT_WAITS`.
> In the profile, moving or removing a waypoint carries the wait value with it; while waiting it stands still and does not fight (the same as while walking the route).
> Dying or switching profiles cancels the wait. Utils: `AddPriority(name, values, { Values = true, ... })`

### [x] UI Priority Draggable

- Priorities can be dragged up and down without pressing up/down.

> **Done:** every Priority list can be dragged by its row name (Enemy, Waypoints, Farm Zones, Deadzones, Whitelist) with a line showing where it will land.
> The ▲▼ buttons still work as before.

### [x] Auto Confirm Block

- Uses AutoBlockConfirm from Iambatman: automatically presses Block in Roblox's confirmation window.

> **Done (v2.69):** enable **Auto Confirm Block** (under Auto Block, saved in the profile, default off).
> - After Auto Block opens the Block window it looks for the `Block` button in CoreGui within 6 seconds (`ARM_SECONDS`).
>   It only presses a window whose title is that player's name, and never presses "Block and report".
> - It tries one click method at a time — getconnections > firesignal > VirtualInputManager > real mouse — then checks that the block actually succeeded.
>   A method that worked is tried first next time; if it cannot press the button it asks you to press it yourself.
> - Once the block has succeeded, Auto Block hops servers as before.
> - Only works on executors that can read CoreGui (not Studio). Debug: `getgenv().AICBlockConfirmDebug = true`

### [x] Auto Mining

- Mines ore inside the MineZone after the Waypoint route is finished; if an enemy comes within 15 studs it draws the sword and attacks; it stands still while mining.
- MineZone: it only mines ore inside the zone; ore outside the zone is not a target to walk to; there is a slider to adjust the radius.
- Ore Priority + the target amount per ore (max 500), minus what is already in the inventory.
- A billboard showing the ore's status, tied to DebugVisualizer.
- `IsHoleAhead`: if it finds a hole it can jump across it jumps, otherwise it uses Pathfinding; MoveTo, jump and Pathfinding are adjusted to respect the deadzone and the MineZone.

> **Done (v2.70):** the **Mining** tab.
> - **Auto Mining** (saved in the profile, default off) runs inside the Auto Farm loop after the Waypoint route is finished (Auto Farm has to be on).
>   With no ore to mine it goes back to farming as usual; the STATUS line says what it is doing or waiting for.
> - **Ore Priority**: drag to reorder, with a Target field per ore (0–500); the default is Iron Ore and Copper Ore at 500 each.
>   It mines the highest-ranked ore that has not reached its target; if that ore has no free chunk in the zone (claimed / regenerating / unreachable) it skips to the next rank.
>   Remaining target = Target − the amount in the inventory, read from `PlayerStats.Inventory` every time a chunk is chosen.
> - Add ore from the **Add Ore** dropdown (ore that is loaded), or type a name into **Ore Name** for ore too far away to be loaded.
> - **Mine Zone**: Add Mine Zone Here / Mine Zone Radius (5–300) / Edit Mine Zone / Clear, stored in `PLACE_CONFIG.MINE_ZONES`.
>   No Mine Zone = no mining; ore inside a deadzone is not mined either.
> - It walks to within ≤ 15 studs of the chunk and fires `ClaimMaterial`, standing still until the game's cooldown (`CoreCommons`) runs out +0.5 s.
>   If it cannot reach it within 15 s, or cannot find a way, it skips that chunk for 30 s.
> - Enemies within 15 studs: draw the sword, turn towards them, and attack once in range; while mining it does not move; while walking over to attack it only does so inside the zone.
>   An enemy outside the zone that cannot be hit is ignored (this prevents waiting forever on a mob that is just standing there). Retreat at low HP still works as before.
> - Movement (`MiningMovement`): it walks straight when that is safe and uses Pathfinding when it meets a wall it cannot jump, a hole too wide to jump,
>   a ledge too high to jump, a deadzone in the way, or a step that would leave the MineZone (if it is already inside); stuck for more than 1.5 s also switches to Pathfinding.
>   A path that crosses a deadzone or leaves the zone is rejected. Path calculation happens outside Heartbeat, so it does not stall frames.
> - `AICCombatUtils.IsHoleAhead`: checks the ground ahead every 1 stud up to 6 studs; a drop deeper than 6 studs, water, or no ground = a hole.
>   The jump distance is computed from WalkSpeed + JumpPower/JumpHeight (with 80% allowance); if there is ground on the other side within range it jumps 2.5 studs before the edge.
> - Debug: **Debug Mine Zones** (blue circles) and **Debug Ore Status**, a label on ore within 150 studs
>   (TARGET / MINING x.xs / READY has/target / DONE / TAKEN / REGENERATING / OUTSIDE MINE ZONE / NOT IN PRIORITY ...).
> - Assumptions that need checking in game: inventory item names match the ore model names (e.g. "Iron Ore"), and the 15 studs claim distance from the demo.

### [x] Auto Block: configurable delay

- Add a feature to set a delay for Auto Block.

> **Done (v2.71):** the **Block Delay (s)** slider in the Auto Block section (0–120 seconds, default 0 = acts immediately as before, saved in the profile).
> - When it sees a player who is not in the whitelist it keeps farming as usual until the delay is up, then blocks and hops servers.
> - The timer is counted per person, starting from the first time that person is seen; leaving the server and coming back restarts the count.
> - If a Leader is set in Party System, Party handles strangers instead and this delay has no effect.

### [x] Auto Smithing

- Implements the auto smithing system from the PoC: pick a recipe by priority, walk to the table, `CraftingStart`, play the minigame and press strike itself.
- It accounts for the materials used and the SmithingSkill each recipe requires.
- Separate from mining / uses the nearest or the chosen table / an amount can be entered / has a material Reserve.

> **Done (v2.72):** the **Crafting** tab.
> - **Auto Smithing** (saved in the profile, default off) is separate from Auto Mining.
>   With Auto Farm on: it crafts after the Waypoint route is finished, before mining, but is not pulled away while it is mining an ore chunk.
>   With Auto Farm off: it works on its own (walks to the table and only crafts).
> - **Recipe Priority**: drag to reorder, with a Target field per recipe (0–500); the default is Iron Ingot and Copper Ingot at 500 each.
>   It skips recipes whose SmithingSkill is below `CraftingSkill`, that lack materials, or whose inventory count already meets the target.
>   Added from the **Add Recipe** dropdown (shows the skill required and the materials, ordered easiest to hardest).
> - **Recipe Status**: one line per recipe — READY xN / LOCKED SKILL required/have / NEED materials have/required / DONE / PAUSED.
> - **Material Reserve**: sets how much of a material to keep and not craft with (e.g. Keep Iron Ore 40).
> - **Set Smithing Table** (stand within ≤ 20 studs of the table) saves the position to the profile / **Use Nearest Table** goes back to using the nearest table.
>   It stores a position, not an Id (the Id can change per server); when used it finds a table within 10 studs of that point.
> - It walks to the table with `WalkController` (renamed from MiningMovement); within ≤ 8 studs of the table it calls `CraftingStart`.
>   If it cannot reach it within 30 s, or cannot find a way, it skips that table for 30 s. A mob entering attack range on the way is fought first, then it keeps walking.
> - Minigame (`SmithingMinigame`): checks every frame (RenderStepped) and presses `Action` when `Mover` overlaps `ClickArea`.
>   It presses through firesignal/getconnections (the `MouseButton1Click` signal from the PoC); if that is unavailable it uses VirtualInputManager/real mouse,
>   and the latter computes the next frame's Mover position from its speed.
> - It finishes when Success/Failed appears and the GUI closes, then waits for the inventory to update before choosing the next recipe. Every step has a timeout, so nothing hangs.
>   Three failures in a row pauses that recipe for 60 s.
> - Debug: **Debug Smithing Tables**, a label on tables (TARGET / CRAFTING / READY / UNREACHABLE / NOT THE SET TABLE).
> - The button-pressing code was split out into `Core/GuiClick.lua`, shared with Auto Confirm Block, and `AutoCraft.lua` (stub) was removed.
> - AutoMining fix: with no ore to mine it no longer scans every frame (every 0.5 s instead).
> - Assumptions that need checking in game: the crafted item's name matches the recipe name, the 8 studs table range, and the Action button accepting `MouseButton1Click`.

### [x] Smithing: Recipe Browser as a separate window

- Pressing it opens a separate UI with a search field and a ScrollingFrame list instead of a dropdown.
- Selecting a recipe shows its details and says which materials are missing.
- Selecting a missing material opens a floating box saying what it is crafted from (if it is craftable).

> **Done (v2.74):** the **Open Recipe Browser** button in the Crafting tab (replacing the Add Recipe dropdown) opens a separate, draggable window that closes with ×.
> - Left: a list of every recipe, ordered from least to most skill, searchable by recipe name and by material name (typing an ore name finds every recipe that uses it).
>   Each row shows skill + status READY xN (yellow) / NEED materials have/required (orange) / LOCKED (grey), with ✓ if it is already in Recipe Priority.
> - Right: for the selected recipe — the skill required compared with ours, the type, the amount held, and the materials per single craft.
>   Each one shows have/required and how many are MISSING (counted after subtracting Material Reserve), plus an Add/Remove Recipe Priority button.
> - Selecting a material: a floating box next to the row gives the amount held; if it is craftable it shows its own materials with have/required and an **OPEN RECIPE** button.
>   If it is not craftable it says there is no Smithing recipe that makes this item / click elsewhere or × to close.
> - It refreshes the inventory and skill every 1 s while the window is open (`SmithingBrowser.lua`).

### [x] Server: move all server-related features over from Iambatman

> **Done (v2.75):** new **Server** tab (`ServerHop.lua` does the work, `ServerUI.lua` draws the UI)
> - **Current Server**: player count / max + map name, Job ID + PlaceId, FPS and Ping (yellow/orange/red at the 50/30 FPS and 100/200 ms thresholds), server-hop status
>   Buttons **Rejoin** (rejoin the same server), **Server Hop** (pick a random public server that is not full, reads up to 4 pages of the list), **Copy Job ID**,
>   field **Job ID** + **Join Job ID** (join the server of that Job ID), **Open Server Browser**
> - **Server Browser**: separate window, the public server list on the left (the server you are in is listed first, marked "YOU ARE HERE") showing players/Ping/FPS/short Job ID, Refresh / Load More
>   Click a server and the right side shows the details + Copy Job ID + Join; for the server you are in it also lists the players in it (for other servers Roblox gives only the count)
> - **Leave On Danger Group** (default on, like Iambatman which kept it on at all times): checks everyone in the server for membership of group 5928691
>   If yes and they are not in the Auto Block whitelist → hop servers at once, up to 3 attempts (a failed group check retries 3 times, 5 s apart)
>   Checks start after the profile has loaded (the whitelist has to load first) and re-check every 2 s, in case someone is removed from the whitelist
> - **Join Alerts** (default off): notifies when someone outside the whitelist joins, or is already in the server when you turn it on
> - **Player Log**: the latest 15 entries, time + JOINED / LEFT / PRESENT @name, with [WL] [DANGER] labels, keeps up to 100, Clear Log button
> - "Add everyone in the server to the whitelist" already exists in Auto Block (**Add Everyone Here**), it was not duplicated
> - The floating-window code was split out into `UI/Floating.lua`, shared with the Recipe Browser
> - The server list needs `game:HttpGet` (executor); in Studio it shows as failed to load

### [x] Auto Mining: use Pathfinding first when something blocks the way to an ore, and fall back to a smart MoveTo when it cannot compute

> **Done (v2.76):** `WalkController` (used by both Auto Mining and Auto Smithing)
> - Obstacles are checked with a box the size of the character (2.4 wide, from 1 stud above the feet up to the head) 8 studs ahead, instead of a single waist-height ray
>   Slopes you can walk up are not counted (surface facing up > 0.6), nor are the target ore, mobs and players
> - Something blocks the way (including low objects you can jump over) → use Pathfinding first (previously it walked straight and jumped over)
> - Pathfinding cannot compute → walk around it: find the most open direction heading towards the target (30°–150°, alternating left/right) with at least 4 studs of clearance
>   Not a hole/deadzone/outside the mining zone; walk to that point (≤ 2.5 s) then retry the straight line and Pathfinding from there
> - After 4 detours without getting closer (≥ 2 studs), if the obstacle is low enough it jumps over it instead, otherwise the target counts as unreachable (previously it gave up as soon as the path failed)
> - Stuck following a path for more than 1.5 s → recompute the path from where it is

### [x] Combat: pull mobs together first, then use the skill

> **Done (v2.79, Phase 1):** Farming tab → **Mob Gather** section (`MobGather.lua`), toggle **Gather Mobs** (saved in the profile, default off)
> - **Min Mobs** (2–8, default 3) / **Max Mobs** (2–10, 5) / **Gather Radius** (15–80, 40) + a status line
> - IDLE: look for a group of attackable mobs (in Enemy Priority, inside the farmzone, not being attacked by another player) of at least Min Mobs within the Gather Radius
>   If there are not enough it farms normally; below 50% HP (`COMBAT_SKILL_MIN_HP_PERCENT`) it does not start gathering
> - TAG: run in and hit each mob once so it follows (mobs whose `LastAttacker` is already us are skipped), nearest mob first, at most 6 s per mob
> - KITE: back off 12 studs from the group (inside the farmzone, not a deadzone/water, clear path) and wait for the mobs to come within skill range (15), at most 4 s
> - BURST: face the group and fire the skill as soon as it is ready (waits at most 4 s), then normal combat keeps hitting
> - FIGHT: the round ends when the gathered mobs die or are all lost (further than 35 studs for 3 s = lost) or after 25 s, then it rests 4 s before the next round
> - Retreat on low HP / dodging mob skills / Auto Block / walking waypoints always take priority; entering a duel cancels the round
> - Still to check in game: how far mobs follow (leash), whether the mobs are faster than us, how large the skill's AoE radius is (the current values are cautious)

### [x] Smithing: Recipe Browser can be resized and minimised

> **Done (v2.80):** done in `UI/Floating.lua`, so both the Recipe Browser and the Server Browser get it
> - **—** button next to the close button: collapses to just the title bar, press **+** to expand again (minimising the Recipe Browser also closes the floating material tooltip)
> - Drag the bottom-right corner (**◢**) to resize; the top-left corner stays put, minimum 360×240, maximum not beyond the screen edge
> - Size and minimised state are remembered for the rest of the script session; closing and reopening looks the same (the first open is centred)

### [x] Auto Start Game: clicks through the title screen by itself

> **Done (v2.86):** toggle **Auto Start Game** (saved in the profile), ported from Iambatman's AutoStartGame
> - Clicks "CLICK ANYWHERE TO CONTINUE" and then "// START GAME"; it stops by itself once in game and does not watch the screen while playing
> - The menu is on a SurfaceGui (StarterGui.GameMenu); the option buttons listen for `MouseButton1Down`, so it fires the full signal set just like a real click. Works at any window size
> - If a positional click is needed, coordinates are converted from the SurfaceGui to screen coordinates; the real mouse is used only while the cursor is already over the button
> - While the window is minimised: no real mouse is used; if the click does not go through it waits until the window is restored · no title screen for 180 s = stop · 3 failed click rounds = notify and stop
> - It never clicks Customize / Credits / Reset Data · debug: `getgenv().AICStartGameDebug = true`

### [x] Server: Leave On Danger Group is saved globally and has its own whitelist

> **Done (v2.87):** the **Leave On Danger Group** toggle and **Danger Whitelist** are kept in `AutoFarmProfiles/Global.json`, shared by every profile and every PlaceId
> - Loading, creating or importing a profile does not change them, and exporting a profile does not include them (key `r` stays reserved, never reuse it)
> - Danger Whitelist is separate from Block Whitelist: someone in a danger group who is in the Danger Whitelist no longer forces a server hop, while Block Whitelist no longer affects this feature at all
> - Add people from the in-server dropdown or type a User ID · removing someone who is in the server hops immediately · the Player Log shows a `[DANGER WL]` tag
> - On the first run after the update the toggle starts off (the old value in the profile is not migrated), so it has to be turned on once

### [x] Server: Danger Group accepts several group IDs

> **Done (v2.88):** the **Danger Groups** list in the Server tab: type a Group ID and press Add Group ID (remove / drag to reorder); being in any of the groups hops the server
> - Saved globally in `Global.json` like the toggle and Danger Whitelist (`DANGER_GROUP_IDS`); the default contains the original 5928691
> - The **Leave On Danger Group** toggle still defaults to off · Danger Whitelist is still separate from Block Whitelist
> - Editing the group list re-checks everyone in the server immediately · the notification tells you which group the person was found in

### [x] Smithing: craft from the Recipe Browser in a single window + filter by category

> **Done (v2.88):** the Recipe Browser was rewritten so one window is enough; no need to keep the main window open next to it
> - Left: search field (recipe or material name) + item-category buttons (ALL / Weapon / ... with counts) + **READY ONLY** (only what can be crafted right now)
> - The category is read from `Commons.getAssets(true)` (`Assets[name].Value`); each recipe row shows the category, LV (if it has `LVL`) or Skill (if it has `Skill`), and BOUND if it has `Bound` (not tradeable)
> - **RECIPE** tab: details + DMG / DEF / DEX (if any) + TRADEABLE/BOUND + materials (click one to see what it is made from)
> - **CRAFT NOW**: slider + number field + MAX button + CRAFT button; the maximum is how many the materials in the inventory allow (after subtracting Material Reserve, at most 500 items in the inventory)
>   CRAFT orders N of that recipe immediately, runs before Recipe Priority and works even with Auto Smithing off; it ends by itself when done / materials run out / 3 failures / CANCEL
> - **PRIORITY** tab: the same Recipe Priority as the Crafting tab (editing either one updates both); the ADD/REMOVE buttons in the RECIPE tab still work
> - New file `Features/SmithingDetail.lua` (the RECIPE tab), split out of `SmithingBrowser.lua`

### [x] Pinned Items: open it from the Status tab instead of a floating button

> **Done (v2.88):** closing Pinned Items (×) no longer leaves a "◇ OPEN" button floating on screen; reopen it with the **Show Pinned Items** toggle in the Status tab
> - Whether it is open or closed is remembered (stored in `PinnedItems.json` together with its contents)

### [x] Auto Block: Whitelist Skips Safety button

- Someone who is in the whitelist but is blocked by us must not cause a warp away (the same addition as in Iamrich)

> **Done (v2.89):** toggle **Whitelist Skips Safety** in the Auto Block section (saved in the profile, default on)
> - On: someone in the Block Whitelist does not make Auto Block warp away even if they are blocked, and does not make Leave On Danger Group leave either (except through Danger Whitelist)
> - Off: someone in the Block Whitelist who is already blocked makes it warp away (after Block Delay), while Leave On Danger Group uses Danger Whitelist only, as before
> - Auto Block never opens the block window for someone in the whitelist, whether this toggle is on or off

### [x] UI: Server Browser / Recipe Browser in the AIC theme + a description under every control name + a highlight border on hover

> **Done (v2.90):**
> - The floating windows (Server Browser, Recipe Browser) were rebuilt to match the main window: yellow-cornered frame, title with ◇ + uppercase name + a description line below, bordered square buttons, text the same size as the main window
> - Every button / toggle / slider / dropdown / text field in the main window has a small description line under its name saying what it does (priority lists show it on the second line); edit the wording in the single file `UI/Descriptions.lua`
> - Hovering a button / toggle / dropdown / text field / row in a floating window turns its border to the accent colour

### [x] UI: one font across the whole system

> **Done (v2.91):** the whole UI uses a single Gotham (normal text GothamMedium, headings/button names GothamBold from the same font), set in one place: `FONT_REGULAR` / `FONT_BOLD` at the top of `UI/Utils.lua`
> - Colour/setting fields in Settings that used to be the Code font now use the same font
> - Text that never had a font set (it previously took Roblox's default) now gets the normal font automatically, across the main window, Server Browser, Recipe Browser and the Debug Visualizer floating labels

### [x] Whitelist: show the name next to the User ID

> **Done (v2.92):** Block Whitelist and Danger Whitelist show `UserId  ·  @name` (the saved value is still the UserId, as before)
> - Someone in the server gets a name immediately; for everyone else the name is fetched from Roblox in the background (`GetNameFromUserIdAsync`) and the list redraws itself once it arrives, remembered for the rest of the script session
> - If the name lookup fails only the UserId is shown

### [x] UI: font selector in Configuration

> **Done (v2.93):** the Configuration page (button at the bottom left of the menu) has a **FONT** dropdown listing every Roblox font (`Enum.Font`)
> - Picking one changes the whole UI at once: main window, Configuration page, Server Browser, Recipe Browser, Pinned Items, notifications and the Debug Visualizer floating labels; bold stays bold (if that font has a bold variant)
> - Text created later also uses the selected font · saved globally in `Global.json` (`UI_FONT`), shared by every profile, so a fresh start keeps the same font
> - **RESET DEFAULT** goes back to Gotham

### [x] Re-execution guard

- Running it again must not leave two copies working at once (done in Iamrich first)

> **Done (v2.94):** running it again stops the previous run before the new one loads (the current run is kept in `getgenv().AICSession`)
> - Stopping the old run: Heartbeat (farming/mining/smithing, all of it), tells the character to stop moving, the Anti AFK loop, the Auto Start Game loop, disconnects every connection, destroys the `AutoFarmDebug` folder and the window
> - Pending profile saves are written immediately, and the old run cannot save after that (it never overwrites the new run)
> - If an AIC older than v2.94 is running (it cannot be stopped from here) the new run does not start and asks for a rejoin
> - There is still no Unload button

### [x] Combat: adjustable fighting distance when Safe Combat is off

> **Done (v2.97):** slider **Close Combat Range** in the Target section (below Safe Enemy Range), saved in the profile (`CLOSE_COMBAT_RANGE`), default 6 studs, adjustable 4–12
> - Applies when Safe Combat is off: it stands and fights in place (CLOSE HOLD) while inside this range, and the standing spots it tries are range-2 / range-1 / range (never closer than 4 studs, `CLOSE_COMBAT_MIN`, so it does not overlap the mob)
> - A value of 6 behaves exactly as before (4 / 5 / 6) · never more than 12 = our attack range (`PLAYER_ATTACK_DISTANCE`) · the combat logic itself is unchanged

### [x] Combat: with Character.NoDamage, do not attack yet — circle the target first

> **Done (v2.97):** when we have `NoDamage` (attacks do not register) it no longer runs in to attack, and circles the target instead (`AICCombat.OrbitTarget`) until `NoDamage` clears, then fights normally
> - It circles outside the target's blade range like Safe Combat (never closer than the 12-stud attack range) + 2 studs (`ORBIT_PADDING`) and faces the target the whole time
> - If the way ahead leaves the farmzone / drops into a deadzone / is water / hits a wall → it reverses the circle (allowed to flip every 1.5 s, `ORBIT_FLIP_COOLDOWN`) · it walks around obstacles with the same target-chasing logic
> - It does not attack during this · FARM STATE shows `NO DAMAGE, CIRCLING` · retreating at low HP / dodging mob skills still take priority as before
> - Applies to Auto Farm's main combat (not Gather Mobs / self-defence while mining)

### [x] Combat: duel opponents are fought like a mob we are attacking (walk around and hit them from behind)

> **Done (v2.97):** a duel partner is treated like a mob whose `LastAttacker.Value` is us
> - Against players it used to skip the standing spots past their body (afraid of circling forever because the player turns to follow us), so it only fought from the front; now a duel partner uses the behind spot first, then the side spots, like a mob, walking around them with the same target-chasing logic
> - Safe Enemy Range also prefers the behind spot for a duel partner (it used to prefer backing out of blade range, because players have no `LastAttacker`)
> - Blade dodging (Blade Push / blade range) and the circling when the target turns to face us work as they do for mobs · players who are not duelling us are still fought the old way

### [x] Combat: Retreat At HP% can be set as low as 0

> **Done (v2.97):** the **Retreat At HP%** slider now goes 0–80 (was 30–80) · setting 0 means it never retreats for low HP (dodging mob skills still works as before)

### [x] Auto Start Game: retry pressing 10 rounds instead of 3

> **Done (v2.99):** `MAX_FAILED_ROUNDS` 3 → 10
> - While the window is minimised it now retries up to 10 rounds before stopping to wait for the window to come back · it logs every round until round 10, then every 10 rounds (normally it still keeps retrying until the screen is passed, as before)

### [x] Mob Dictionary: inspect each mob's data

> **Done (v3.00):** the **Open Mob Dictionary** button at the end of the Targeting section (Farming tab) opens a separate window in the Recipe Browser style
> - The data comes from the game's dictionary (`ReplicatedStorage.BuildAssets:InvokeServer("MobDict")`); it is loaded the first time the window opens and **RELOAD** loads it again
> - Left: the list of mobs + bosses sorted from least to most HP, searchable by name · chips ALL / MOBS / BOSSES / LIVE (only those currently in the server) · the thin bar under each name = threat level
> - Right: name + MOB/BOSS label + how many are in the server (updated every 1 s) + status effects · a 5-step THREAT gauge (LOW → EXTREME, from the HP/damage rank against every mob)
> - Big numbers: HP, WALK SPEED, first attack value, each with its rank · every numeric value is a bar compared against the highest of the same type (mobs against mobs, bosses against bosses), grouped as BODY / COMBAT / REWARDS / OTHER · values that are not numbers show as TRAITS labels
> - Buttons **ADD TO ENEMY PRIORITY** (a profile is required) and **COPY NAME**

### [x] Mob Dictionary: drop rates and Luck calculation

> **Done (v3.01):** the **DROPS PER KILL** card on the Mob Dictionary page calculates the way the server does (`AwardPlayer`)
> - Drops are read from `Config.MaxDrops` of the mob spawned in the server (MobDict does not send it), so that mob must have spawned in the server at least once; it is remembered for the whole run
> - Per item: it rolls `Value` times with a `100/Rarity`% chance per roll, and if the item still has not dropped, roll N is multiplied by N · plus Luck `min(Luck, 500)/100`% (capped by `CoreCommons.PHYSICAL_STAT_MAX`) · rolls 1–100, rounded down
> - It shows the % chance of at least 1 drop per kill, how many kills on average to get one, the average count per kill, a bright bar = Luck included / grey = no Luck, and a RARE label (1 in 10 or rarer)
> - The LUCK line shows our Luck value and the % it adds to every roll, and updates itself when Luck changes · items from events are excluded
> - The detail view was split out into `Features/MobDetail.lua` · the left list shows LV and the number of drops already known

### [x] Refactor: merge the Mining / Smithing UI files into their features

> **Done (v3.03):** `AutoMiningUI.lua` was merged into `AutoMining.lua` and `AutoSmithingUI.lua` into `AutoSmithing.lua` (mining and smithing still live in separate files)
> - The layout and button positions in the Mining / Crafting tabs are exactly as before
> - The Crafting tab is built in AutoSmithing's `BuildLateUI`, because the Recipe Browser (SmithingBrowser → SmithingDetail) depends on AutoSmithing first; building it in Start would create a circular dependency

### [x] Asset Explorer: inspect every item's data

> **Done (v3.06):** the **Open Asset Explorer** button in the Crafting tab (below Refresh Recipes) opens a window like Mob Dictionary
> - The data comes from the game's assets (`CoreCommons.getAssets`, the same one the Recipe Browser uses); no remote call · press **RELOAD** to read it again
> - Left: all items sorted by type, then by level · search by name / type / text values · chips ALL / OWNED / one per type · the bar under each name = best DMG/DEF/DEX compared with the same type
> - Right: type, LV, BOUND/TRADEABLE, UNOBTAINABLE, requires a pass/badge/group, bought with event currency, the amount owned · big DMG/DEF/DEX numbers with their ranks
> - **VALUE**: buy price (`Worth`) and sell price at 35% (45% with the Agility pass) as in the server code · items that require a pass/badge/group/event currency cannot be sold
> - **HOW TO GET**: the recipes you can make (materials compared against your inventory) + the mobs that drop it, with the % per kill (mobs seen in the server this run, from Mob Dictionary) · **USED IN**: the recipes that use this item
> - Every numeric value is a bar compared against the best of its type, other values show as labels, plus status effects · buttons **COPY NAME** / **OPEN RECIPE** (opens the Recipe Browser at that recipe)
> - The parts shared with Mob Dictionary were split into `UI/DetailKit.lua` (cards, labels, bars, numbers) and `UI/BrowserShell.lua` (window, search, chips, list) · Mob Dictionary now uses those two files and looks the same as before

### [x] Teleport Navigate: warp through doors and to the game's waypoints

> **Done (v3.11):** a new **Teleport** tab (after Server), file `Features/TeleportNavigate.lua`, using the game's `TeleportEvent` remote like Iambatman's TeleportSystem
> - **Door Teleport**: pick the T1 / T2 point of any door in `workspace.Interactions` from a dropdown, then press **Teleport To Door**
> - **Waypoint Teleport**: pick a waypoint from `workspace.Waypoints` (there is always a #0 Default), then press **Teleport To Waypoint**
> - The **Waypoint Number** field: type a number and press **Teleport To Number** to warp to that WP immediately, without waiting for it to stream into the folder
> - The door / waypoint lists update themselves when the folder gains or loses objects, or press **Refresh Doors** / **Refresh Waypoints**

### [x] Quest: Assign Quest button + Quest ID field

> **Done (v3.17):** a new **Quest** tab (after Teleport), file `Features/QuestAssign.lua`
> - Type an ID in the **Quest ID** field and press **Assign Quest** → sends `QuestEvent:FireServer("AssignQuest", ID)` (it finds `QuestEvent` recursively in ReplicatedStorage)
> - An empty field or a remote that cannot be found raises a notice and nothing is sent

### [x] Quest Helper: ESP showing where the quest's item/spot is

> **Done (v3.17):** the **Quest Helper** section in the Quest tab, file `Features/QuestHelper.lua`
> - Type item/spot names in the **Quest Targets** field (separate several with `,`, case-insensitive) and turn on **Quest ESP**
> - It finds Models / Parts in the workspace whose name matches, or parts with a ProximityPrompt showing that name (ObjectText / ActionText)
> - Each one gets a name label + distance (studs) drawn through walls · the closest 20 get a Highlight · the nearest is green, the others yellow
> - Objects that stream in later get their label by themselves · press **Rescan Quest Targets** to search the whole map again
> - Fixed (v3.18): it only searches inside the `QuestItems` folder in the workspace · both the item's name and the typed name are reduced to letters and digits only and lowercased before comparing, so typing `old key` matches `Old_Key` / `OldKey`
> - Added (v3.19): toggle **Show All Quest Items** labels every item in `QuestItems` with ESP without typing a name (it works together with the typed names) · at most 200 labels, the closest 20 Highlights as before
> - Quest targets are still not pulled automatically: it is not known where the game keeps quest data client-side → press **Copy Quest Info** while you are accepting a quest (it copies and saves `AutoFarmProfiles/QuestDump.txt`), then send that in and the targets can be entered by hand

### [x] Mob Dictionary: show AwardParam for mobs whose AwardType = HealthPercent

> **Done (v3.17):** a mob whose `Config.AwardType` is `"HealthPercent"` only gives its reward once you have dealt at least `AwardParam`% of the mob's HP (the attribute on AwardType)
> - The dictionary from the server does not send the attribute, so it is read from the mob spawned in `workspace.Mobs` (the same way as Drops); only numeric values are accepted
> - Shown as the stat **AWARD MIN HEALTH %** in the REWARDS group of the detail page (as a bar compared with other mobs), and it appears by itself once the real mob is found
> - Saved in `AutoFarmProfiles/MobDrops.json` (the `AwardParams` field), so the next run can show it right away without waiting to meet the mob again

### [x] Follower Guard: stop the farm when someone keeps joining your servers

> **Done (v3.23):** new toggle **Follower Guard** (Server tab > Server Safety, on by default, shared by every profile), file `Features/FollowerGuard.lua`
> - A sighting is one player in one server: already here when the guard looks (`present`, counted once per player and server while the log remembers it, so re-running the script cannot make a bystander look like a follower) or joining while it runs (`joined`; the same player rejoining the same server within `SIGHTING_DEDUPE` (60 s) counts once)
> - At `FOLLOWER_TRIP_SIGHTINGS` (3) sightings of one player inside `FOLLOWER_WINDOW` (30 min) Auto Farm is turned off and **held off**: a profile load switching it back on is turned straight back off every frame, and only a real click on the Auto Farm toggle lifts the hold (that also restarts the count, so the old sightings cannot trip it again straight away)
> - You, the Block Whitelist and the Party Leader are never counted
> - Sightings and the hold are saved in `AutoFarmProfiles/FollowerLog.json` (shared by every profile and place, entries kept `FOLLOWER_KEEP` (24 h)), so the window carries across server hops and re-runs of the script

### [x] Follower Guard: leave the server instead of stopping the farm

> **Done (v3.24):** a trip now gets the run out of the server instead of switching Auto Farm off
> - `FOLLOWER_TRIP_SIGHTINGS` is **2** (was 3), so the second sighting of one player inside `FOLLOWER_WINDOW` (30 min) trips the guard
> - A trip calls ServerHop's own hop (`ServerHop:Hop`), so the farm keeps running in the next public server; `ServerHop:Hop` gained an optional `OnFailed` reason, which the guard uses to know the hop could not be carried out
> - The player is **not** blocked and is not reported: the guard only leaves
> - The same player seen again is left for again, but not before `FOLLOWER_RETRIP_COOLDOWN` (60 s), because the sightings that tripped it are still inside the window — so a follower who follows us to the next server is left there too, and one trip cannot turn into a hop per sighting
> - The old hold is kept as the fallback: when no hop could be carried out (no other server with a free slot, an unreadable server list, or a refused teleport) Auto Farm goes off and stays off until the Auto Farm toggle is clicked, exactly as in v3.23

### [x] Follower Guard: leave the game instead of hopping servers

> **Done (v3.25):** a trip now kicks you out of the game rather than joining another server
> - The trip calls `Player:Kick`, which disconnects the client to the Roblox app and ends the run, so the follower is left behind for good instead of possibly meeting us again in the next public server
> - The Server Hop path is gone from the guard: `Features/FollowerGuard.lua` no longer depends on `ServerHop`, and `ServerHop:Hop`'s optional `OnFailed` reason has no caller left (it stays part of `ServerHop:Hop` for a future caller)
> - The old hold is kept as the fallback: if the kick itself fails, Auto Farm goes off and stays off until the Auto Farm toggle is clicked
> - `FOLLOWER_RETRIP_COOLDOWN` (60 s) now only matters after a trip whose kick failed and fell back to the hold

### [x] Repo: point the loader and README at the current repository

> **Done (v3.28):** the script now downloads from `Enthusiasticzz/Autofarm-Script-Sbor`, and the README reads as a landing page
> - `BASE` in `Init.lua` and the fallback in `Core/Runtime.lua` fetch from `Enthusiasticzz/Autofarm-Script-Sbor` (was `Enthusiasticz-sbor/sbor-script-tool`); the `getgenv().AICBaseURL` override is unchanged, so a fork or a pinned build still works
> - The README loadstring and "download base" line use the new repository, and the feature list is grouped by area instead of a flat dump
> - `AI-WALKTHROUGH.md` uses the new repository and records the standing rule to always commit and push every change

### [x] Reset Stats: explain why 500+ is refused (anticheat)

> **Done (v3.29):** the Reset Stats note now says the real reason a stat at or above the limit cannot be reset
> - The button's description (`UI/Descriptions.lua`) reads "Zeroes stats under 500 points; 500+ won't reset (trips the anticheat)" instead of the old "Puts stat points below the limit back to 0"
> - The on-screen refusal (`Features/ResetStats.lua`) now says the points trip the game anticheat, instead of the old wording that implied it was refused only to avoid wiping points by accident
> - `STAT_RESET_THRESHOLD` is unchanged at 500; only the wording changed. `USAGE.md` was corrected to match

### [x] UI: organize the Farming tab instead of one Features list

> **Done (v3.30):** the Farming tab no longer dumps every toggle into one "Features" section; it is split by what the feature does
> - `Core/Runtime.lua` keeps declaring every section in one place; the former `Features` section is now titled **Core** (kept as `UIRef.FeatureSection`, aliased to `UIRef.CoreSection`), and the Farming tab reads **Core → Combat → Targeting → Auto Block → Mob Gather → Booster Reset**
> - Core holds Auto Farm, Auto Find, Auto Patrol, Return To Farm Zone, Ignore Farm Zone and the combat HP% sliders; Combat holds Safe Combat, Jump While Fighting and Auto Skill
> - The **Auto Block** and **Auto Confirm Block** toggles moved out of Core into the **Auto Block** section with their own settings; **Gather Mobs** into **Mob Gather**; **Refill Booster** and **Safe Booster Reset** into **Booster Reset**
> - **Auto Start Game** and **FPS Boost** moved to a new **Utility** tab (`UIRef.UtilitySection`), and the **Debug Visualizer** master toggle to the **Debug** tab with its other toggles
> - Each feature now passes its section to `BindFeatureToggle` (4th arg) instead of relying on the default, so a new toggle lands with its own settings rather than in Core; no toggle, default, or save key changed
> - `USAGE.md` and `AI-WALKTHROUGH.md` document the section-per-area layout and the rule to always pass the matching section

### [x] Boss Route: its own tab and saved boss waypoints, separate from Auto Farm

> **Done (v3.31):** a new **Bosses** tab (`Features/BossNavigator.lua`) for the boss run where you go from a waypoint to a boss, fight it, and reset on a timer instead of dying to it
> - Its own list, saved on the place config as `BOSS_ROUTE` (`Core/Runtime.lua` `NormalizeBossStops`, so it saves, loads and exports with the profile): the Farming waypoint route and the Profile Settings waypoints are untouched by it and never move it
> - **Add Boss Stop Here** saves a stop; **Edit Boss Stop** picks one and the boxes below edit it: name, **Teleport Waypoint #** (the game's own `TeleportEvent`, 0 walks), **Wait At Spot (s)**, **Reset Below HP %**, **Respawn Wait (s)**, **Engage Radius** and **Boss Names** (entity names, empty fights anything at the stop) · **Move Stop Here** / **Remove Stop** · drag or ▲▼ reorders the route, and each row carries its own `Reset (s)` box and `Wait Exp` tick
> - The run walks each stop with `WalkController` (teleporting first when the stop names a waypoint), waits, then fights the nearest matching mob inside the radius with the same weapon/attack/skill inputs Auto Farm uses
> - A stop ends on the boss dying (2 s grace for a second mob), on **Reset After** seconds of fighting, on health at or below **Reset Below HP %**, or on nothing to fight for 5 s; the reset sets `Humanoid.Health = 0` like Party System does
> - **Wait Exp** holds the next stop until `PlayerStats.EXP` is lower than before the reset (15 s cap), so the loss is registered before walking off; otherwise **Respawn Wait** is all it waits
> - **Loop Route** (saved setting `BOSS_ROUTE_LOOP`, default on) loops back to the first stop; off, the route plays once and switches itself off
> - `Features/AutoFarming.lua` hands it the frame (`AICFeature.BossStep`) before the waypoint route, and again in the Auto Farm off branch, so it runs with Auto Farm on or off; `BossRecoverStep` keeps a reset waiting for its respawn while Auto Farm returns early on a dead character; the safety checks above it (party hold, retreat, Auto Block, server age) still run first
> - New save key `z` for the toggle, and `BOSS_ROUTE_LOOP` in `SaveConfig.Settings`; `USAGE.md` has a **Bosses tab** section, `UI/Descriptions.lua` describes every new control, and `README.md` lists the module
> - `.gitignore` now keeps the local `Backup-Copy/` and `Others-code/` folders out of the tree
> - Not tested in game: the reset timing (10 s by default), the EXP-loss wait and the boss-name matching need a run against a real boss

### [x] Boss Route: a stop the walker cannot find a way to should not strand the route

> **Done (v3.32):** `Features/BossNavigator.lua` reads the walker's result now instead of calling `MoveTo` and hoping
> - When `WalkController` reports `failed` (no navmesh, no allowed path, every detour refused) the character walks straight at the stop as a last resort and the stop is skipped with a notice after 15 s (`NO_PATH_TIMEOUT`) instead of standing there until the 120 s `WALK_TIMEOUT`
> - While the walker is still working (reported `moving` or `waiting` while a path solves) nothing changes; `USAGE.md` now has a **Walking to a stop** section describing the direct line, pathfinding, hole jumps, detours and the navmesh requirement

### [x] Boss Route: travel paces backwards and sideways, names are typed by hand, and the HP reset makes no sense

> **Done (v3.33):** three fixes to `Features/BossNavigator.lua`
> - **Travel**: the boss route no longer uses `WalkController`. That walker is built for a short line to an ore, and its blocked-line behaviour walks to detour points at 30°–150° to either side before retrying — which is exactly the "runs backwards for a second, then sideways, then at the boss" look. The route now follows one `PathfindingService` path waypoint by waypoint (character radius/height, `AgentCanJump`, 4-stud spacing, solved off the frame), and only re-solves when the destination moves, the path is 8 s old, or the character stalls (then it jumps and re-solves). The old path keeps being walked while a new one solves, so a recalculation is not a pause or a step in another direction. With no path at all it walks straight at the stop and retries every 2 s, and skips the stop after 15 s.
> - **Stuck check**: the stall detector samples the position every 0.5 s and counts a stall when < 0.75 studs were covered — a per-frame comparison called a normally walking character stuck and threw its path away every 1.5 s, which was the other half of the wandering
> - **Boss names**: the typed comma-separated box is gone. **Add Boss Name** is a dropdown built like **Add Zone Target**: the mobs around the player first (within 300 studs, nearest first, already-added names filtered out), then every other mob the game has loaded. **Boss Names** is the per-stop list (drag/▲▼/✕) and **Refresh Nearby Bosses** rebuilds the picker after walking somewhere new.
> - **Reset**: **Reset Below HP %** is removed from the storage, the UI and the fight. A new **Reset After Kill** toggle (on for a new stop) resets once the boss is down so the next stop is travelled to from spawn. **Reset After (s)** stays only as a fight timeout and now defaults to 0 (fight until the boss is down); **Respawn Wait (s)** is relabelled **Wait After Reset (s)** — it is the pause after that reset, not a fight timer.
> - Older saves migrate: `ResetBelow` is dropped, and a stop saved before `ResetAfterKill` existed (which always carried the old 10 s default timeout) becomes **Reset After Kill on**, **Reset After 0** — the run it had before, only resetting after the fight instead of mid-fight. An intentionally typed timeout is edited in the row as before.

## To Fix

### [x] Waypoints Looped & Paired Farmzone/Waypoint/Targets: walking back to waypoints that are not paired

- If only one farmzone is paired, farm and stay in that farmzone only; there is no need to walk back to other waypoints
- If two or more farmzones are paired, alternate only between the farmzones paired with waypoints
  - Example: 39 waypoints and 2 farmzones, where Farmzone#1 is paired with WP#33 and Farmzone#2 is paired with WP#39
  - All mobs in Farmzone#1 are dead → walk to Farmzone#2
  - All mobs in Farmzone#2 are dead → walk back to Farmzone#1
- Never loop back to a waypoint that has no farmzone/pair set

> **Fixed (v2.43):** no longer walks backwards N > N-1 > ... > 1 looking for a target
> - Once the route is complete it walks to the nearest paired waypoint (if it sees a zone with a target it goes there first)
> - One paired zone: it stays in that zone the whole time, and waits inside the zone when there are no mobs (Return To Farm Zone / Patrol apply to that zone only)
> - Two or more paired zones: a zone that has been empty for more than 1.5 seconds counts as cleared, then it walks to the next paired zone
>   in waypoint order and loops back to the first (if it sees a zone with a target it skips ahead to that one), e.g. WP#33 ↔ WP#39
> - It walks only through the waypoints that sit between paired points, because they are just the route, and it does not stop to fight at those points
>   and never walks outside the range from the first to the last paired waypoint

### [x] Pinned Items

- Save across `game.PlaceId`
- Pinned Items cannot be dragged off-screen
- Add a Reset Position button for Pinned Items in MainUI

> **Fixed:** stored in `AutoFarmProfiles/PinnedItems.json`, shared by every PlaceId (the old per-profile entries were migrated across the first time),
> the position is saved when the drag ends, it cannot be dragged off-screen and is pulled back on screen when the screen size changes,
> and the **Reset Pinned Items Position** button is on the Status tab

### [x] Combat

- Fighting mobs in the Farmzone and then it suddenly walks out of the farmzone
- Sometimes it jumps away into the Deadzone

> **Fixed:** the retreat path at low HP (`GetRetreatPosition`) did not check the Deadzone, and the fallback escape (raw away)
> checked neither the Farmzone nor the Deadzone yet still jumped after it; both are checked now
> As for escaping out of a Deadzone, it now prefers a point inside the Farmzone

### [x] AutoFind

- Turned on but it will not attack mobs

> **Fixed:** AutoFind skips the waypoint route, but the attack condition still waited for the waypoints to be completed
> so it only pressed Interact and would not attack

### [x] Walks out of the farmzone and stands still

> **Fixed:**
> - When it locked a target farther than 50 studs away (`COMBAT_ENGAGE_MAX_DISTANCE`), the combat code's `Move(0)` overwrote the walk-to-target command every frame, so it stood still; it now keeps walking towards the target
> - Retreating at low HP with no mob nearby (30 studs) made it stand and heal right there, and outside the farmzone it stood outside the zone until HP came back; it now walks into the zone first and only then stands and heals inside it (only once the waypoint route is complete and with Return To Farm Zone on)

### [x] Freezes when starting the script with a saved profile

> **Fixed:** `Dropdown:Set(value, false)` in Utils ignored the `false` value and called the callback every time
> With a profile loaded, the **Paired Farm Zone** dropdown saved → refreshed the waypoint list → created a new dropdown → Set → the callback looped forever
> (with no save it does not freeze, because the callback stops at "CREATE / LOAD PROFILE FIRST")
> Now `Set(value, false)` on a Dropdown/Textbox does not call the callback, like Toggle/Slider
> Side benefit: starting the script no longer loads the profile 2–3 times over

### [x] Targets: DuelOpponents

> **Fixed:** a player whose character has a `DuelOpponents` StringValue that is not our name is skipped (it goes for another player/mob instead)
> If we have `DuelOpponents`, it attacks only the players named in that value and ignores other Enemy Priority entries until the duel ends
> Ignore Farm Zone off: the duel partner must be inside the Farmzone and not in the Deadzone, like any other target
> Ignore Farm Zone on: the duel partner can be attacked anywhere (fixes the case with Waypoints + Ignore Farm Zone where it refused to attack and only pressed Interact)

### [x] Combat (PvP / PvE retreat)

> **Fixed:** retreating now counts target players as well (it used to count only mobs, so it stood still while fighting players)
> - In a duel: it always retreats from the duel partner, never stands still, never puts the sword away, never uses a potion
> - Not in a duel: it retreats at low HP and waits to heal as before, but if a player is closer than 50 studs (`RETREAT_PLAYER_SAFE_DISTANCE`) it will not stand still
> - While retreating (both PvP/PvE) it faces the nearest enemy, fights back as it retreats if the enemy comes into attack range, and does not put the sword away or use a potion until it is out of range

### [x] Party System: wait for the Leader to leave before resetting

> **Fixed:** Leader still in the server = farm normally (it does not reset even when a stranger joins)
> Leader leaves the server → reset → wait ~1 s → `ChatEvent:FireServer("Teleport", "tp friend <Leader>")`, tried 3 times

### [x] Waypoint Loop: fight along the way at the paired waypoints

> **Fixed:** when the route reaches the first paired WP, Waypoint Loop takes over
> - First pass: go through the paired WPs in order, and if a zone has a target, fight it out there before moving on to the next paired WP
> - After the last paired WP: go to the nearest zone that has a target; if there is none at all, stand and wait in the current zone instead of running back and forth
> - When walking past a paired WP whose zone has a target, it stops to fight first
> - It never walks past the first/last paired WP (e.g. with the first pair at #34 it will not back up to #33)

### [x] Waypoint Loop: walking past a zone with a boss / pacing back and forth after the boss dies

> Cause: the first pass went through the paired WPs in order without looking at which zone had a boss, and it measured "nearest" by WP number rather than by real distance
> Zones already checked as empty were not remembered, and it did not know when a boss would respawn
> **Fixed (v2.52):**
> - It reads `workspace.RespawnTimers` (a Configuration with `RespawnName` / `DiedAt` / `RespawnSeconds`; removed = already respawned)
>   used for zones that have Zone Targets set
> - It picks the nearest zone by real walking distance through the WPs that have targets, or one that has never been checked and whose timer does not say it is dead, and it re-decides at every WP
> - A zone already checked as empty is not revisited until a target respawns there
> - All bosses dead: go and wait in the zone whose boss respawns soonest, standing there instead of pacing around

### [x] Combat: Poor mob seeking — charges straight ahead and gets stuck in corners

> **Fixed (v2.62):** Every approach-to-target move goes through a single `ChaseMoveTo`.
> - Walks straight while the way is clear; if there is a wall ahead or the character stops moving (~0.7 s), it switches to Pathfinding for 2.5 s.
> - Stuck even while following a path → sidesteps out of the corner toward the most open direction (alternating left/right), then jumps.
> - After 4 sidesteps that still do not get closer to the target, the old system decides the target is unreachable (instead of circling inside the corner forever).
> - Path computations no longer overlap (it used to fire ComputeAsync every frame while waiting for the result).

### [x] Combat PvP: Cannot swim after falling in the water / cannot fight a player underwater

> **Fixed (v2.62):**
> - A player in the water is still a valid target (mobs in the water are still skipped as before); water is read from Terrain voxels, so someone submerged below the surface is still found.
> - Fighting a player and falling in the water, or the player being in the water: swims toward the target in 3D (dives down / rises with the target's height) instead of only jumping.
> - Swimming no longer ends before the attack step when fighting a player (the old Swim Recovery `return` meant it never attacked in the water). Mobs on land still jump up onto the bank as before.
> - Attack range in the water is measured in 3D, and line of sight does not treat the water surface as a wall.
> - Standing on land with the target in the water, it walks down into the water after them.

### [x] SaveConfig: Safe Booster Reset was not saved when turned on

> **Fixed (v2.62):** The value was saved, but loading a profile did not refresh the toggle (it was not in the `updateFeatureButtons` list).
> Every toggle in `SaveConfig.Features` is now refreshed automatically.

### [x] SaveConfig: Every saved value must live in SaveConfig / adding a module needed edits in several files

> **Fixed (v2.62):** `Core/SaveConfig.lua` is the single place that declares anything saved.
> - `Features` = every toggle (default + short export key), `Settings` = every setting (default / min-max / options)
> - Runtime, ProfileManager (save/load/import/export/reset), Components and the sliders all read from here.
> - A profile with no value for a toggle falls back to the default instead of keeping the value left over from the previous profile.
> - Init has a single module list (`MODULES`) used for both the download and the start order.
> - Adding a feature: create the file + 1 line in `MODULES` + 1 line in `SaveConfig.Features` + `AICUI.BindFeatureToggle(...)`

### [x] Vector3 rounded to 2 decimal places

> **Fixed (v2.62):** Newly saved Waypoints / Farmzones / Deadzones, values that are saved and exported, and values loaded from an old save are all rounded to 2 decimal places.
> Position labels in the UI show 2 decimal places.

### [x] AutoRefill and ResetOnBoostOut are the same thing

> **Fixed (v2.62):** Merged into the single file `Features/AutoRefill.lua` (the "Refill Booster" toggle still saves as `ResetOnBoostOut`, so existing profiles keep working).

### [x] Combat: Mobs circle around the character and facing cannot keep up

> **Fixed (v2.63):**
> - Turns much faster (`FACE_RESPONSIVENESS` 25 → 200), and if the facing error is over 35° (`FACE_SNAP_ANGLE`) it snaps around in a single frame.
> - Leads the mob by its velocity over 0.12 s (`FACE_LEAD_TIME`) instead of aiming at the position the mob was just in.
> - When pinned against the mob's blade / waiting for a path / unable to continue, the old code let AutoRotate turn the character itself (so the mob could walk around behind us); it now faces the mob the whole time.
> - Walking in and attacking use the same facing function.

### [x] Farming: Add Target split into Player / Mob

> **Done (v2.64):** The Farming > Targeting tab has 2 dropdowns instead of the old "Add Target".
> - **Add Player Target**: players in the server (`@name`), refreshed quickly (`PLAYER_TARGET_REFRESH_DELAY` 0.5 s) when someone joins or leaves.
> - **Add Mob Target**: mobs in sight, with spawns/deaths batched into a single update every 3 s (`MOB_TARGET_REFRESH_DELAY`).
> - The dropdown is rebuilt only when the list really changes (the same mob type respawning does not make it flicker).
> - It is not rebuilt while a dropdown is open — it waits for it to close — and its position in the section stays fixed.
> - Adding a target / loading a profile / pressing Refresh Detected Targets still updates immediately as before.

### [x] Combat PvP: Does not turn to face a targeted player

> **Cause:** The lead aiming added in v2.63 had no limits. A player runs ~28-38 studs/s, so the aim point overshot by 3-5 studs,
> which is about melee range: a player running at us made the aim point pass behind us (turning our back), and a player circling skewed it 40-55°.
> Snap then flipped on and off every frame, so the turn stuttered.
> **Fixed (v2.65):**
> - No lead aiming when the target is closer than 6 studs (`FACE_LEAD_MIN_DISTANCE`).
> - The velocity used for the lead is capped at 20 studs/s (`FACE_LEAD_MAX_SPEED`) to survive dashes and knockback.
> - The lead distance is at most 35% of the target distance (`FACE_LEAD_MAX_RATIO`), so the error is at most ~20° and never passes through our body.
> - Snap is decided from the target's real direction, not from the lead point.

### [x] Waypoint: A boss casting on the route caused permanent retreat instead of continuing

> **Cause:**
> - After dodging a skill it stayed in retreat mode, because the only way out of retreat was HP back to ≥70%, and a single boss skill drops below that.
> - While retreating, the code hit `return` before the waypoint-walking step every frame (so it either kept fleeing the boss or stood waiting for full HP).
> - The dodge-spot finder was forced to stay inside the Farmzone, but the waypoint route runs outside the zone, so it found nowhere to dodge and stood in the skill.
> **Fixed (v2.66):**
> - The reasons to retreat are separated: retreat because of a skill → it stops retreating the moment the skill ends; retreat because of low HP → waits for HP to come back as before.
> - While walking the waypoint route it can dodge skills outside the Farmzone (Deadzone is still forbidden), then continues the route.
> - While walking the waypoint route it does not retreat on low HP: it keeps going and drinks a potion on the move.

### [x] Combat PvP: Does not swim over to attack a player who is in the water

> **Cause:** Roblox's ControlModule calls `Player:Move` (the pressed button = not pressed = 0) and sets `Humanoid.Jump` every RenderStepped before physics,
> but SwimChase issued `Humanoid:Move` from Heartbeat, so it was overwritten with 0 every frame before the character could move.
> (`MoveTo` was not overwritten, so it could walk to the water's edge and then floated motionless at the surface, unable to dive down or swim up.)
> **Fixed (v2.67):**
> - SwimChase keeps the last swim command (3D direction + swim up) and repeats it every frame through `BindToRenderStep` running after ControlModule.
> - The command expires by itself after 0.25 s, so leaving a water fight does not leave it swimming.

### [x] Combat PvP: Walking up to a player who stands still, then jumping on top of them

> **Cause:** The combat-spot picker (`GetSafeCombatPosition`) scored spots behind the target better than any other spot (bonus -20).
> A player standing still and facing us means the spot behind them is on the far side of their body, so walking straight in bumped into them,
> and pushing further either climbed them or got stuck, which the code answered by jumping — so it jumped up and stood on top of them.
> **Fixed (v2.67):**
> - It no longer picks a spot it would have to walk through the target to reach (a path passing within 3.5 studs of the target, `TARGET_BODY_CLEARANCE`); it goes around to the side instead.
> - If the target blocks the way at point-blank range, it stops, stands and attacks facing them instead of pushing, and immediately picks a new spot.
> - When hugging the target and stuck, it does not jump to unstick (including while following a path).
> - Fixed the `IsSafeCombatPathClear` raycast, which did not really exclude other players / the Debug folder (it now inserts a copy of FilterDescendantsInstances).

### [x] Combat: Swimming attacks tilt the body up/down to aim at the target

> **Done (v2.68):** In the Swimming state `FaceGoblin` pitches the AlignOrientation up/down with the target's height,
> like swimming straight in to attack, with the angle capped at 70° (`SWIM_FACE_MAX_PITCH`) so the body does not spin when the target is exactly below or above.
> Back on land it stands upright again.

### [x] Combat: Retreating on land made the character swing its facing back and forth

> **Cause:** While retreating it alternated between facing the enemy and facing the run direction every time the enemy crossed 22 studs (`COMBAT_FACE_RANGE`),
> and the counterattack moment (`FightBackThreat`) ordered another turn in the same frame — all through `FaceGoblin`, which snaps instantly past 35°.
> **Fixed (v2.68):** Retreating uses a single `FaceWhileRetreating` at every call site.
> - No snap; turning is smoother (`RETREAT_FACE_RESPONSIVENESS` 30) and capped at 6 rad/s (`RETREAT_FACE_MAX_TURN_SPEED`).
> - A direction change under 15° does not turn at all (`RETREAT_FACE_DEADBAND`).
> - It stops facing the enemy once the distance is over the range +6 studs (`RETREAT_FACE_HYSTERESIS`), and after switching it holds that choice for at least 0.8 s (`RETREAT_FACE_HOLD`).
> - The counterattack faces the target immediately, and the next retreating frame follows that facing instead of turning back and forth.

### [x] Combat: Mob farming seeks mobs worse than the older version and jumps more than usual

> **Cause (from v2.62):** Inside attack range (8-14.5 studs), while swinging or blocked by mobs crowding in, the character walks slower, so the system thought it was stuck
> and switched to Pathfinding + sidesteps. Sidestepping jumped every frame, and Pathfinding that could not find a route over rough ground
> kept sidestepping until all 4 attempts were used and it gave up (Safe Combat off = stand still, on = decide the target is unreachable and skip it for 15 s).
> **Fixed (v2.73):**
> - Being inside attack range of the target no longer counts as stuck: no switching to Pathfinding / sidesteps / jumping in the middle of a fight.
> - A sidestep jumps only when there really is an obstacle in front.
> - Pathfinding finds no route → walk straight at the target like the older version, and only sidestep if actually blocked by a wall.
>   It gives up only after 4 sidesteps that still do not get closer to the target.

### [x] Server: Notifications fired too often

> **Fixed (v2.77):** Every Server notification goes through a single filter: the same message is not shown again within 8 s (`NOTICE_COOLDOWN`).
> - Join Alerts: players who join close together (within 1.5 s) are merged into one notification, e.g. "3 players joined: @a, @b, @c"; it shows at most 4 names and reports the rest as a count.
>   Turning Join Alerts on / loading a profile merges players already in the server into one notification (previously one per player).
>   Someone who left and came back within 120 s does not notify again; if they leave, or are added to the whitelist, while the merge is pending, nothing is shown.
> - Teleport failed: only Server's own teleport notifies (previously Auto Block / Party teleport failures notified again too).
> - Server Hop: pressing again while it is already searching does not start an overlapping search (previously searches overlapped and notifications came twice).
> - Group check failed: at most one notification per 60 s, no matter how many players failed it (details in the console).

### [x] Combat: A mob that is unseen but reachable made it stand facing instead of running over / Safe Combat off made it stand still facing the mob

> **Cause:**
> - (v2.62) While waiting for a Pathfinding computation, the other frames fell through to the last step that issues `Move(0)`, which cancels MoveTo, so it just stood facing the mob.
>   The path to the standing spot and the path to the mob itself were also computed alternately in the same frame, and each cancelled the other's path, so it never followed either.
> - (v2.67) If the mob itself blocked the way to the spot behind it, it waited for Safe Combat to pick a new spot, but with Safe Combat off nobody picked one, so it stood facing the mob forever.
>   And with Safe Combat on, spots behind the mob were all discarded whenever we were standing in front of it.
> **Fixed (v2.78):**
> - While waiting for a path it does not stop walking (it keeps following the previous MoveTo) and faces the target; a path pending longer than 3 s (`PATH_COMPUTE_TIMEOUT`) is cancelled and recomputed.
> - One path is computed at a time: if the path to the standing spot fails, it paths straight at the mob for 2 s (`PATH_TO_MOB_HOLD`) before retrying the standing spot.
> - Mob blocking the way to a spot behind it → walk around the mob's side (3.5 + 2 studs away, `BODY_DETOUR_MARGIN`) instead of standing and waiting.
> - Safe Combat on: spots behind the mob are selectable again even when standing in front (only player targets are discarded).

### [x] Combat: With Safe Combat off it did not dodge around and stood in front of the mob taking damage

> **Cause:** With Safe Combat off, combat only walked straight at the mob and never used the standing-spot picker (behind the mob, circling with the mob's turn timing) that Safe Combat uses.
> And Safe Enemy Range, once it reached the spot, dropped back to walking at the mob's face, so it walked in and out and stood taking the blade (and did not work at all against mobs with no BladePart).
> **Fixed (v2.81):** With Safe Combat off it behaves exactly like Safe Combat on (prefers a spot behind the mob, then the side, circles with the mob's turn timing, paths around obstacles).
> - The only differences are the distances: it stands close to the mob at 5 / 6.5 / 8 studs (`CLOSE_COMBAT_DISTANCES`) instead of outside blade range, and it does not back away from the blade.
> - Safe Enemy Range (when set and the mob has a BladePart) still sets the distance: it walks to the spot, stands there facing the mob, and does not walk back toward its face.

### [x] Server: Leave On Danger Group should default to off

> **Fixed (v2.82):** The default changed from on to off (profiles that already saved it keep that profile's own value).

### [x] Combat: With Safe Combat off it should not retreat the way Safe Combat does

> **Fixed (v2.83):** With Safe Combat off it does not back away from the mob at all.
> - It neither backs away from a second mob that comes close (threat escape) nor uses Safe Enemy Range (keeping out of blade reach); both remain only for Safe Combat on.
> - Within 8 studs and not in front of the mob (outside 60° from the mob's facing, `CLOSE_FRONT_DOT`) → attack from where it stands instead of walking out to another spot.
> - It only moves when the mob turns toward us → circles to behind the mob (at 5 / 6.5 / 8 studs).
> - Retreating on low HP / dodging mob skills still behaves as before (a separate system).

### [x] Combat: With Auto Patrol on it does not walk / sees a mob but does not go to it (Safe Combat off, Gather Mobs off, nobody else in the server)

> Still no cause found from the code: every file was checked for syntax / undeclared variables with luau-compile / luau-analyze and there are no errors.
> v2.84: added a **FARM STATE** line in the Status tab saying what the farm loop is doing that frame,
> e.g. `RETREAT (Skill)`, `AUTO BLOCK @name`, `ROUTE #3`, `PATROL`, `IDLE (NO TARGET)`,
> `CHASE Goblin 12 // CLOSE HOLD`, `CHASE ... // CHASE TO SPOT / STRAIGHT`, `CHASE ... // WAITING (NO WAY FOUND)`
> → when the bot is not moving, look at what this line says and then fix that specific step.
> FARM STATE showed `PATH SOLVING` alternating with `WAITING (NO WAY FOUND)`:
> **Cause (v2.81):** With Safe Combat off the standing spot hangs only 5 studs from the mob; the straight-line check with a ray hit another mob in the group and concluded the way was blocked.
> It was then sent to Pathfinding, which cannot find a route to a spot that close to the mob (it is inside the mob), so it waited for a path and stood still, never chasing the mob, and Patrol did not work either because the target was still locked.
> **Fixed (v2.85):** With Safe Combat off it uses `ChaseMoveTo` to walk straight to the standing spot (it walks straight / switches to a path / sidesteps on its own); only a route through water or a deadzone is forbidden.
> Cannot reach the standing spot → walk straight at the mob itself, like before v2.81, and only use Pathfinding as a last resort.

### [x] Mining: Small hills are not jumped over

> **Fixed (v2.88):** In `WalkController`, an obstacle low enough to jump over (nothing blocking at 3 studs above the feet, `MAX_HOP_RISE`) is no longer sent to path around.
> It walks straight in and jumps at 2 studs away (`HOP_EDGE`) · there must be 2 studs of clear space after the hill (`HOP_LANDING`)
> **Cause:** Previously every obstacle taller than 1 stud was sent to Pathfinding even when it could be jumped, and the old jump check measured from the base of the HumanoidRootPart, which is higher than a low hill, so it never saw the hill.
> This also applies to Auto Smithing (same walker); combat was not changed.

### [x] Mining: The character moves while mining and gets kicked for being too far away

> **Fixed (v2.88):** while claiming / mining, `WalkSpeed` is set to 0 every frame and restored once mining finishes (turning Auto Farm off mid-mine also restores it within 0.5 s, `STEP_STALE_SECONDS`)
> - Auto Farm no longer pushes `WalkSpeed` back up while it is locked
> - Only mobs that come within 10 studs are fought (`DEFEND_RANGE`, previously 15); while mining the character stands still and fights in place

### [x] Combat: With Safe Combat off, the distance to the target is still too far

> **Fixed (v2.88):** only the `CLOSE_COMBAT_DISTANCES` value changed, from 5 / 6.5 / 8 to 4 / 5 / 6 studs (still further from the mob's body than `TARGET_BODY_CLEARANCE` 3.5); the combat logic is unchanged
> - The character stands still and attacks in place (CLOSE HOLD) at 6 studs (previously 8)

### [x] Server: Leave On Danger Group hops in and out of the same server

> **Fixed (v2.90):** the cause was leaving with `Teleport(PlaceId)`, which lets Roblox pick the server itself without blocking that player first, so it kept being sent back to the same server
> - It now blocks the danger-group player first (using Auto Block's prompt; with **Auto Confirm Block** on it clicks for you), waits up to 10 s for the block to land (`DANGER_BLOCK_WAIT`) and only then leaves
> - It leaves for another server picked from the public server list (never this one), like the Server Hop button; if the list cannot be read it falls back to letting Roblox choose as before
> - If the block does not land within 10 s (Auto Confirm Block off and the user did not click) it warns and leaves anyway · if that player left the server first, the hop is cancelled

### [x] Auto Start Game: The script loads before the title screen and gives up clicking too early

- The script finishes loading long before the title screen, runs all 3 click attempts without getting through (the page has not actually finished loading) and then stops for good
- Make it keep checking until a click gets through or the PlaceId changes

> **Fixed (v2.95):** it no longer gives up: it keeps clicking until Start Game is passed, the PlaceId changes or the toggle is turned off
> - A failed click means another attempt, with the gap growing by 2 s each time up to 10 s (`MAX_RETRY_DELAY`); the "Click it manually" notice is gone
> - No title screen found means it keeps scanning; after 60 s (`IDLE_SLOW_AFTER`) the scan slows to every 2 s (`IDLE_SCAN_INTERVAL`)
> - Turning the toggle on while already in-game leaves the loop scanning in the background until the toggle is turned off or the script is run again
>
> **Fixed (v2.96):** it only acts in the menu place (PlaceId `4733278992`, `MENU_PLACE_ID`)
> - Running in another place (in-game) scans nothing at all, so it never clicks anything in-game · leaving the menu place stops it immediately

### [x] UI: Clicks on a popup pass through to the main UI

> **Fixed (v2.98):** the cause was that the floating windows were plain Frames, which Roblox does not stop clicks on (a click is only stopped by the top-most button), so a click on the window background / text / scroll field reached the main window's button underneath
> - The background of the Server Browser, Recipe Browser, material popup, dropdown lists, Pinned Items, the Configuration page and the colour picker is now a blank button (same appearance), so a click anywhere in the window stops at that window while the buttons inside still work normally

### [x] Mob Dictionary: v3.01 fails to load the script (LOAD FAILED)

> **Fixed (v3.02):** `Features/MobDictionary.lua` had `return Dictionary` duplicated on two lines, so it did not compile and the whole script stopped at the loading screen
> - Removed the duplicate line · every file was checked with `luau-compile` and all pass
> - An empty / `None` StatusEffect no longer shows an empty ☠ label
> - A drop that reads as empty (the mob has not fully loaded) is read again from the next instance instead of remembering "drops nothing" forever
> - If the server does not answer MobDict within 20 s (`LOAD_TIMEOUT`) it shows a message with a RELOAD button to press (previously it stayed on Loading forever)
> - The Luck cap value (`CoreCommons`) is read in the background so the window does not hang if the require waits · list rows recalculate threat after RELOAD

### [x] Bug sweep across every feature since v2.90

> **Fixed (v3.04):** went through every commit from v2.90 to v3.03 and found 5 problems
> - Re-running the script while fighting / mining: the old run's `FaceGoblin` (AlignOrientation) stayed in the HumanoidRootPart still enabled, so the character could not turn until it died · the old run now removes FaceGoblin and its attachment and restores AutoRotate when it stops · Auto Mining also restores the `WalkSpeed` it locked to 0
> - Leave On Danger Group: if the danger-group player left the server while waiting for the Block, it counted as one server hop, and after 3 the feature silently stopped working for the rest of the run · that case is no longer counted
> - Retreat At HP% = 0 still retreated at exactly 0 HP (the frame the character dies) · 0 now genuinely means never retreat
> - Floating windows: if Roblox did not send MouseLeave, the hover background colour got stuck · the hover colour is no longer remembered as the original colour
> - Dropdowns did not close when clicking on a floating window / Pinned Items (after v2.98 changed them to buttons, the click counted as already handled by the UI) · a click outside the dropdown now closes it wherever it is

### [x] UI: Text Scale in Configuration is barely usable

> **Fixed (v3.07):**
> - It used to multiply the current text size by the ratio and round every time, so changing scale back and forth drifted away from the original size · it now remembers each text's base size (attribute `AICBaseTextSize`) and always computes base size × scale
> - It used to affect only the main window, and text created later (dropdowns, notices, floating windows, newly built rows) was not adjusted · it now adjusts the whole ScreenGui and new text picks up the current scale
> - Saved globally in `Global.json` (`UI_TEXT_SCALE`), shared by every profile, so reopening the script keeps the same size · Reset Default returns it to 1

### [x] Mob Dictionary: Save each mob's drops (and check whether it was already saved)

> **Done (v3.07):**
> - Drops read from a real mob are saved to `AutoFarmProfiles/MobDrops.json` (shared by every profile / PlaceId) and loaded when the script starts, so drops are visible even when that mob has not spawned in this server yet
> - Before writing the file it checks whether that mob was already saved: it writes only when it has never been saved, or when the drops it just read differ from the saved ones (the game updated) · identical data is not rewritten
> - Each mob is read from a real instance only once per run · if the read comes back empty (possibly not loaded yet) it neither overwrites what is saved nor saves an empty value
> - `workspace.Mobs` is scanned every 5 seconds (`LIVE_SCAN_INTERVAL`) even when the Mob Dictionary window is not open

### [x] Asset Explorer: Text in TRAITS does not wrap and overflows the UI

> **Fixed (v3.08):** the badge (`Kit.Badge`) was as wide as the whole line of text and did not wrap, so a long one overflowed the card · it is now capped to the card's area (`UISizeConstraint`, resized when the window is shrunk / expanded), longer text wraps to a new line and the badge grows taller on its own · also used by badges in the Mob Dictionary

### [x] Asset Explorer: The type line under the item name on the left collides with the text above it; no auto layout

> **Fixed (v3.08):** the name and the line beneath it (type) used fixed pixel positions (Y=5 / Y=20), so they collided once the text was scaled up · they are now laid out with `UIListLayout` (`ROW_TEXT_GAP` apart), centred in the row, and the row grows taller by itself when Text Scale makes the text bigger · also used by the Mob Dictionary (both use the same BrowserShell)

### [x] Feature: FPS Boost (turn off non-essential things such as lights and shadows)

> **Done (v3.09):** new **FPS Boost** toggle (`Features/FpsBoost.lua`); when on:
> - Lighting: shadows off (`GlobalShadows`), fog distance maxed, environment lighting off · all post effects off (Bloom, Blur, SunRays, ColorCorrection, DepthOfField) · Atmosphere density 0 · clouds off
> - In workspace: particles, trails, beams, smoke, fire, sparkles, lights (Point/Spot/SurfaceLight) and explosions off · decals/textures made transparent · every part stops casting shadows
> - Terrain: water waves/reflections and grass (Decoration) off · render quality lowered to the minimum
> - Things created later (mobs, skill effects) are disabled too · the Lighting settings are reapplied every 5 seconds (`REAPPLY_INTERVAL`) in case the game reverts them · the first scan walks 2000 instances per frame (`SCAN_BATCH`) so nothing stalls
> - Turning the toggle off or stopping the script restores everything · Debug Visualizer objects are left alone
> - Saved globally (shared by every profile)

### [x] Auto Block / Auto Confirm Block: Check that the block succeeded before hopping servers

> **Cause:** Roblox adds the name to the block list the moment the Block button is clicked, before the block request really completes (if it fails the name is removed again afterwards)
> Auto Block saw the name in the list and hopped immediately, which could cut the block request off halfway, and then ran into the same player again
> **Fixed (v3.10):**
> - It hops only once the player has been in the block list continuously for 1.5 s (`BLOCK_SETTLE_SECONDS`) and Auto Confirm Block has finished clicking; while waiting it shows the status `AUTO BLOCK  CHECKING @name`
> - If the block fails and the name drops out of the list, the Block window is opened again instead of hopping
> - It does not open another Block window while Auto Confirm Block is still clicking (so windows do not stack up mid-click); if the click hangs for more than 20 s (`CONFIRM_MAX_SECONDS`) it is treated as stuck and work continues
> - Leave On Danger Group uses the same check before leaving (it still leaves anyway once the 10 s wait is up and the block has not landed, for safety)

### [x] Waypoints: Walking a waypoint route falls into a hole where a parkour jump is required

> **Cause:** walking waypoints only used `MoveTo` plus a check for obstacles ahead (`DoJumpIfObstacle`) and never checked whether the ground ahead was a hole, so the character walked off the gap between parkour platforms
> **Fixed (v3.12):** `AICCombatUtils.IsRouteHoleAhead` raycasts down to the ground along `RootPart.CFrame.LookVector` every 0.5 studs up to 2 studs ahead (`ROUTE_HOLE_PROBE_DISTANCE`)
> - No ground / water / ground more than 1 stud below the feet (`ROUTE_HOLE_MIN_DEPTH`) counts as a hole, so the character jumps at the edge
> - Only used while walking a waypoint route and in Waypoint Loop; fighting / patrol / mining are unchanged
> - Only checked while the character is walking and standing on the ground (no jumping again in mid-air)

### [x] UI: Font preview + find dropdown options that do nothing

> **Done (v3.13):**
> - The **Font** dropdown in Configuration shows each font's name in that font (preview); these options do not change with the UI font selection
> - Options that changed nothing when clicked: GothamBold / GothamBlack / SourceSansItalic / BuilderSansBold etc. are only other weights/italics of the same font, and since the UI keeps each text's own weight they all produced the same font as the main one → they were merged into one option per font (a value previously saved as bold now shows as the regular option)
> - When the script starts it tries to load every font in the background (`TextService:GetTextBoundsAsync`); any font that fails to load is hidden from the list and its name is warned to the console
> - Fixed dropdowns that were rebuilt when their list changed reappearing at the bottom of the section: Edit Farm Zone, Edit Deadzone, Pair Waypoint, Paired Farm Zone, Add Zone Target, Set Leader, Profile, Add Player In Server (Auto Block) now use `AICUI.ReplaceDropdown`, which puts them back where they were

### [x] Waypoints: Make the hole-check values from v3.12 configurable

> **Done (v3.14):** Profile Settings > Waypoints has 3 sliders, saved in the profile
> - **Hole Check Distance** (`ROUTE_HOLE_PROBE_DISTANCE`, default 2, 0.5–6): how far ahead the hole is checked, i.e. the distance from the edge at which the character jumps
> - **Hole Check Step** (`ROUTE_HOLE_SAMPLE_STEP`, default 0.5, 0.25–2): spacing between check points; smaller catches narrower gaps
> - **Hole Min Depth** (`ROUTE_HOLE_MIN_DEPTH`, default 1, 0.5–10): at least this deep counts as a hole (raise it if the character jumps while going down stairs)
> - Every slider built with `AICUI.AddSettingSlider` now updates itself when a profile is loaded (the Mob Gather sliders previously did not follow the loaded profile)

### [x] Waypoints: Tick which waypoints should jump

> **Cause:** the automatic hole check (v3.12/v3.14) does not jump at some spots, such as the last gap of a parkour
> **Done (v3.15):** the **All Waypoints** list has a ☐ tick box per row (next to the Wait field), saved in the profile (`WAYPOINT_JUMPS`)
> - Place a waypoint at the edge of a hole and tick Jump → reaching that point always jumps, then the character runs on to the next waypoint (there should be a waypoint on the far side of the hole)
> - A waypoint with Jump ticked counts as reached when the character is within 1.5 studs (`AICConfig.JUMP_WAYPOINT_REACH`) and standing on the ground, instead of the normal Reach Distance, so it jumps right at the edge
> - Used by both the normal route and Waypoint Loop · moving/removing a waypoint moves its tick box with it · the automatic hole check still works as before

### [x] UI: Dropdown bugs (round 2)

> **Fixed (v3.16)** in `UI/Utils.lua` (the dropdown itself):
> - **Leak**: rebuilding a dropdown when its list changed (player names, zones, Teleport, etc.) left the old one's RenderStepped + InputBegan connections behind every time, piling up and getting laggier the longer the session ran → the Frame is now removed and all its connections cut, and it is taken out of the dropdown list itself (`component:Destroy()` / `Frame.Destroying`)
> - **Opening does not scroll to the selected row**: it used to read `Position`, which UIListLayout does not set, so it always stayed at the top (e.g. the long Font and Profile lists) → it counts from the row index instead
> - **Popup size distorted when the UI scale is not 1**: the on-screen (pixel) size was written back as an offset and then scaled a second time → the units are now kept separate
> - **Touch screens**: tapping outside the dropdown did not close it (previously only mouse clicks were checked)
> - Teleport: the Door / Waypoint dropdowns are no longer rebuilt while one is open; it waits for it to close

### [x] Auto Start Game: Store globally

> **Done (v3.16):** **Auto Start Game** moved to `AutoFarmProfiles/Global.json` like FPS Boost / Leave On Danger Group, so the same value is shared by every profile and every PlaceId; profiles no longer save/load/export this value
> - Old values already saved in a profile are not migrated; the toggle must be turned on once

### [x] UI: Theme is not saved

> **Fixed (v3.17):** the colours set in Configuration (clicking **APPLY**) were never saved at all, so reopening brought back the old colours
> - They are now stored in `AutoFarmProfiles/Global.json` (`UI_THEME`) like Font / Text Scale, shared by every profile and every PlaceId, and loaded when the script starts
> - Only colours that differ from the defaults are stored · **RESET DEFAULT** also clears the saved values

### [x] Waypoint: Dropdown cannot be clicked

> **Fixed (v3.17):** the dropdown was destroyed and rebuilt even when its list was unchanged; if that happened between mouse-down and mouse-up, the click was lost
> - Teleport **Waypoint** / **Door**: the `Waypoints` / `Interactions` folders have things entering and leaving constantly (loaded by distance) and the dropdown used to be rebuilt every 0.5 seconds → it is now rebuilt only when the list really changes
> - Profile Settings **Pair Waypoint** / **Paired Farm Zone**: it used to be rebuilt twice on every waypoint / zone edit (including while choosing from the dropdown itself) → it is now rebuilt only when the number of waypoints / zones changes, and otherwise just updates the selected value

### [x] UI: Dropdowns across the whole system cannot be selected (round 3)

> **Symptom:** the list opens, but no option can be added/selected, in any dropdown
> **Confirmed symptom:** **the last option is never clickable** → the mouse coordinates (`GetMouseLocation`, including the ~36px top bar) are shifted about 1 row away from the GUI coordinates
> **Cause:** the "clicked outside the dropdown, so close it" check compared mouse/finger coordinates (`GetMouseLocation` / `input.Position` + `GetGuiInset`) against `AbsolutePosition`, which can drift because of Roblox's top bar / ScreenInsets → the click hit the option but was counted as outside, the list closed on press, and the release never landed on the button
> **Fixed (v3.20):** coordinates are no longer compared; it uses `InputBegan` on the dropdown button, the list and every option itself (Roblox works out what was pressed) and waits 1 frame before deciding that the press was outside. Works with both mouse and touch screens
> - Also fixed (v3.20): a dropdown near the bottom of a long page (one that has to be scrolled to) opened and closed itself immediately, because it used to close whenever the main page moved, even just momentum / the bounce after a flick, or the page shrinking and squeezing the position → the list now moves with the button and closes only when the button is scrolled past the page edge
> - Removed the **+ ADD** button from every priority list: it was left over from the original UI template (Initial commit) and was never wired up, so clicking it did nothing; items are added through the "Add ..." dropdown next to it anyway

### [x] Whitelist / Danger: Store globally

> **Done (v3.21):** **Block Whitelist** and the **Whitelist Skips Safety** toggle moved to `AutoFarmProfiles/Global.json`, shared by every profile and every PlaceId; profiles no longer save/load/export this value
> - The Danger side (**Leave On Danger Group**, **Danger Groups**, **Danger Whitelist**) has already been global since before, so nothing needed changing
> - Existing values are migrated automatically the first time: Block Whitelist = the names from every profile of the PlaceId open at that moment (deduplicated), Whitelist Skips Safety = the value of the profile used most recently
> - Profiles of other PlaceIds are not merged (the migration runs once, from the first PlaceId opened), so names kept elsewhere must be added by hand

### [x] Refill Booster: pick which boosters reset the character

> **Cause:** the watcher was written with the two booster names it knew (`Boost`, `BoostDrops`), so any other booster the game runs was never watched and nothing said so.
> **Done (v3.22):** the **Booster Reset** section of the Farming tab scans `PlayerStats` for every value whose name contains `boost` and gives each one its own toggle, behind a `BOOSTERS  <name> ON/off` readout and a **Refresh Boosters** button.
> - The selection is the profile setting `RESET_BOOSTERS`, defaulting to `Boost` + `BoostDrops`, so an existing profile resets for exactly what it did before.
> - Every discovered booster is watched and the selection is read when a boost changes, not when the connection was made: switching one on or off takes effect with no rescan, and refreshing duplicates neither a toggle nor a connection.
> - The scan waits for `PlayerStats` to exist, so a character that joins later is covered.

### [x] Status: the event currency is called Fallen Camellia now

> **Fixed (v3.22):** the readout counted one hard-coded inventory item (`Golden Shell`)
> - `AICUI.S.TargetCurrency` (`Core/Runtime.lua`) is now `"Fallen Camellia"`.
> - The Status line is named after that currency instead of the fixed `EVENT CURRENCY` label, so it reads `FALLEN CAMELLIA  1,204` and follows the name from that one place (`AICUI.FormatEventCurrency`).

### [x] Combat: the character jumps constantly while fighting mobs

> **Cause:** two probes at the character's feet decided whether to jump, and a mob standing beside it read exactly like a low ledge with clear space above it, so it hopped at the crowd it was fighting on every frame. The probe's own filter only dropped characters under `workspace.Mobs`, so any mob kept elsewhere was read as terrain. On top of that, bodies pressing in made the character look stuck, and the chase answered being stuck with a hop.
> **Fixed (v3.22):**
> - New toggle **Jump While Fighting** (Farming tab, saved in the profile, default **off**). Off, nothing that moves the character towards, away from or around a target leaves the ground: the chase (`ChaseMoveTo` / path follow), its sidestep and stuck recovery, the retreat and the swim chase all go through `CombatUtils.DoCombatJump` / `DoCombatJumpIfObstacle`.
> - The waypoint route (route holes and ticked Jump waypoints), Waypoint Loop, patrol, mining and smithing keep their own jumps, and so does the return-to-zone walker: a parkour gap is still cleared on the route with the toggle off.
> - `CombatUtils.IsJumpableObstacleAhead` no longer reads a character as terrain: each raycast hit is checked by walking its ancestors for a `Humanoid`, so a mob or a player is never a ledge to hop over nor a step to climb, whatever folder the game keeps it in.

### [x] Auto Smithing: the strike is pressed too early on the second strike

> **Cause:** the mover's speed was measured between every pair of rendered frames, including the pair that straddles a strike: the game resets the mover for the next strike, so the reset itself read as a speed several times the real one. A synthetic click (`VirtualInputManager` / real mouse, the fallback when the executor has no `firesignal`) checks where the mover will be one frame later, so that phantom speed threw the check past the band and the next strike was pressed early — while the first strike stayed clean, because it is judged from the sweep that led into it.
> **Fixed (v3.26):** `Features/SmithingMinigame.lua` now only measures the mover between two frames of the **same** sweep.
> - The frame on which the mover is first seen after a gap — the minigame opened, the round ended, the strike button came back, or a strike was just pressed — only takes the sample and never strikes: it may be the frame the game reset the mover on.
> - The speed is dropped (`ForgetMover`) whenever the minigame window or its parts come and go (`Main` missing, the result shown, `ClickArea` / `Mover` / `Action` missing) and right after a strike, so a speed measured before the reset can no longer reach a check after it. Before, only the last position was cleared and the stale speed survived.
> - The one-frame prediction for the synthetic click methods is unchanged, and now only ever runs on a speed measured from two consecutive frames of the current sweep.
> - Assumption that needs checking in game: the mover keeps sweeping continuously between strikes.

### [x] Auto Smithing: the strike is still pressed too early on the second strike

> **Cause:** v3.26 stopped the speed being measured across the game's reset, but the strike was still *decided* at the band's leading edge: the check passed as soon as the mover's box touched `ClickArea` (plus 1 px) and, for the synthetic click methods, only the projection was used to reach it — so any error in the prediction (a speed a frame stale, a click the game handles a frame or two later, or a reset that lands a frame after the one that was skipped) put the press **before** the mover had arrived. The first strike survived it because it is judged from a sweep measured from its very beginning; the second one is the first that follows a reset, so it is the first that shows it. What the prediction should have aimed at is the band, not its edge.
> **Fixed (v3.27):** `Features/SmithingMinigame.lua` no longer strikes at the edge of the band, and no projection can decide a strike on its own:
> - Across the bar the mover's **centre** is what counts, not the edge that arrives first, so a press is never made before the mover is at the band.
> - The centre has to be inside the band on the frame the strike is decided on **and** on the frame the click lands on (`Position + MoverVelocity * DeltaTime`). The 1 px of slack is given to the latter only, so it can no longer make a press early.
> - This holds for every click method now instead of only the synthetic ones: `DIRECT_METHODS` is gone and a direct click (`firesignal` / `getconnections`) has to satisfy both checks as well, because the game can read the mover on its next step rather than in the frame the signal is fired.
> - The v3.26 rule stands: the first frame after any gap only takes the sample, and `ForgetMover` drops the speed at a reset, so the projection a later frame uses is never measured across a reset.
> - Assumptions that need checking in game: the band is wider than the distance the mover covers in two frames (a narrower one would skip a strike rather than press it early), and the mover's centre is what the game judges across the bar.
