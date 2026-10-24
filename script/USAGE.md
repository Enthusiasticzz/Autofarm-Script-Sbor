# AIC usage guide

How to use Automated Industry Complex (AutoFarmV3, `v3.41`) once it is loaded. The
loadstring and what the loader fetches are in [README.md](README.md); this file is
about the features and about why the farm sometimes appears to do nothing.

Everything below is read from the code. Where a behaviour depends on the game
exposing a particular object or remote, it is marked `(in-game check)`, because the
script can only be verified by running it inside a Roblox client.

## Before anything works

These are the conditions the farm loop checks before it will move a single stud. If
any one is missing, **the loop returns without a word** — no error, no notice, and
no FARM STATE update. That is almost always why "toggling it on does nothing".

1. **An executor, not Studio.** The script needs `loadstring`, `game:HttpGet` and
   `getgenv`.
2. **`PlayerStats`** must exist under the local Player, and **`InputBindableFunction`**
   under PlayerGui. These are what the loop reads for level, stamina and the
   Equip/Interact presses.
3. **A target list.** This is the one people miss. Auto Farm only attacks entities
   that are on the active target list — see *How Auto Farm decides what to do*
   below. With an empty list **no mob is ever a target**, and the farm stands still
   showing `IDLE (NO TARGET)`. Outside the two places that ship with a built-in
   target list (`10299594856` and `11987539001`), the list starts empty.
4. **A profile, if you want to keep anything.** Waypoints, zones, ores and recipes
   are saved per profile, and profiles are stored per place
   (`AutoFarmProfiles/<PlaceId>.json`). Adding a waypoint or a zone with no profile
   loaded reports `CREATE / LOAD PROFILE FIRST` in the STATUS line, and the built-in
   place presets are read-only (`DEFAULT PLACE_CONFIG IS READ-ONLY`).

## How Auto Farm decides what to do

`Features/AutoFarming.lua` is a feature module: `Init.lua` puts it in
`Context.Features` and `Core/Heartbeat.lua` calls `Feature:Update(dt)` on every
`RunService.Heartbeat`. One heartbeat runs this chain, in order, and the first test
that matches usually ends the frame:

1. Refresh WalkSpeed (by level) and the UI position.
2. No character, or dead → reset route and target state and stop.
3. Refresh the status labels every 0.5 s, and revalidate the mob list.
4. **Party hold** (`PARTY HOLD`) → stand still.
5. **Auto Farm off** (`AUTO FARM OFF`) → the Boss Route still runs (it is its own
   feature), then Auto Smithing; nothing else moves.
6. **Prerequisite gate** → no `InputBindableFunction`, no `Sword`/`MainWeld`, or no
   `PlayerStats`: stop silently. *(This is the silent one — see Troubleshooting.)*
7. Deadzone escape → if it is standing in a deadzone, leave and stop.
8. **Retreat.** An enemy skill makes it retreat until the skill ends; health below
   **Retreat At HP%** makes it retreat until health recovers (or, on the route, keeps
   walking). **Execute Charge at HP%** overrides retreat to finish a low-health
   target. Retreating skips everything below, with one exception: at a Boss Route
   stop whose boss is already down, the retreat yields, because the reset it is owed
   refills health anyway and healing first only held that reset back.
9. Drink a potion when **Auto Heal at HP%** is met (and not mid-dodge). A mob
   already in reach no longer blocks the drink while health is also below
   **Retreat At HP%**: standing in the fight that is taking the health was
   exactly when the heal was skipped. The Boss Route fights its stops before
   this step ever runs, so its fight drinks for itself, on the same threshold.
10. **Auto Block:** an un-whitelisted player past **Block Delay (s)** is blocked, then
    the server is left once the block settles. With a Party Leader set, Party handles
    intruders instead.
11. Server older than the game's play-time limit → hop.
12. **Boss Route** (`BOSS ROUTE`): while its toggle is on this is where it takes the
    frame — walking its own stops, fighting at each and resetting on its own timers —
    and everything below is skipped for that frame. With Auto Farm off it is offered
    the frame at step 5 instead.
13. **The waypoint route.** While `WAYPOINTS: n/m` has not reached the end, the loop
    only walks: reach checks, `Wait (s)` holds (`WAYPOINT WAIT`), jump waypoints,
    hole and stuck jumps. **It does not fight and does not mine or craft yet.**
14. Once the route is done, in this order: **Waypoint Loop** (`WAYPOINT LOOP`), then
    **Auto Smithing**, then **Auto Mining** (`MINING / SMITHING`), then **Return To
    Farm Zone** (`RETURN TO FARM ZONE`), then **Gather Mobs** (`GATHER`), then target
    acquisition and combat (`CHASE …`), then **Auto Patrol** (`PATROL`), else
    `IDLE (NO TARGET)` and it stands still.
15. Finally: jump probes, swim recovery, and the attack itself — or, while the route
    is unfinished, the `InteractButton` press.

With **Auto Find** on, step 12 is skipped entirely: there is no route, so it goes
straight to targets. That is the switch for "I do not want to walk anywhere".

### What it is allowed to attack

`AICCombat.GetActiveTargetList()` is the single source of truth, and it returns
exactly one of these, in this order of precedence:

1. **Your duel opponent**, if you are in a duel — nothing else counts while it lasts.
2. **The current farm zone's Zone Targets**, if that zone has any.
3. **Enemy Priority** (the ordered list in the Targeting section).

A mob is a candidate only if its entity name (`Config.Entity` inside
`workspace.Mobs`) is on that list, and mobs are re-scanned every frame, so a mob
that is not on the list is invisible to the farm no matter how close it is. The
order of the list is the order they are preferred; **Target Type** only breaks ties
between entries of equal rank.

### FARM STATE readouts

The Status tab's `FARM STATE` line names what the loop did on that frame. It is the
fastest way to tell a broken setup from a working one:

| FARM STATE | What it means |
|---|---|
| `AUTO FARM OFF` | The toggle is off. If the toggle looks on but this is showing, the button state and the loop state disagree — toggle it off and on again. |
| `PARTY HOLD` | Party System is resetting or waiting to Tp to its Leader. |
| `RETREAT (Skill)` / `RETREAT (Health)` | Dodging an enemy skill, or healing after low health. |
| `RETURN TO FARM ZONE` | Walking back into the farm zone (or out of a deadzone). |
| `AUTO BLOCK  @name` | Blocking that player; `AUTO BLOCK  CHECKING @name` means waiting for the block to settle before hopping. |
| `SERVER TOO OLD, HOPPING` | The server's age limit was reached. |
| `WAYPOINT WAIT` | Standing at a waypoint that has a `Wait (s)` set. |
| `ROUTE  #n` | Walking waypoint `n`. No fighting happens in this state. |
| `WAYPOINT LOOP` | Waypoint Loop is choosing which paired zone to farm. |
| `MINING / SMITHING` | Auto Mining or Auto Smithing owns the frame. |
| `GATHER` | Gather Mobs is pulling a pack together. |
| `CHASE  <mob>  <dist>  //  <step>` | Closing on that target; the step names what the movement code chose. |
| `PATROL` | Auto Patrol is looking for targets. |
| `IDLE (NO TARGET)` | Nothing to fight — usually an empty target list. |
| *(line never changes)* | The loop is bailing at the prerequisite gate before it can write anything. |

## Quick start from a fresh profile

1. Load the script (see [README.md](README.md)) and wait for the window.
2. **Equip your sword** so the tool is inside your character, and stand where mobs
   spawn — the mob pickers can only list mobs the game has loaded near you.
3. Create a profile in **Profile Settings** (type a name, press **Create New
   Profile**). Without this, waypoints and zones cannot be saved — and, more importantly,
   **Add Mob Target silently ignores you**: the picker's add is refused with no message at
   all when no profile is loaded, so an empty Enemy Priority is often this and not a bad
   mob name.
4. Farming tab → **Targeting** → **Add Mob Target** → pick the mobs you want (two or
   three is enough). Each pick is added to **Enemy Priority**. The Mob Dictionary's
   **ADD TO ENEMY PRIORITY** button does the same for anything you look up (that path does
   report `Load or create a profile first` when it refuses).
5. Optional but recommended: add a **farm zone** (**Add Farm Zone Here**) where you
   want it to fight, and a few **waypoints** (**Add Waypoint Here**) if you want it
   to walk a route first. With no farm zone nothing is restricted; with no waypoints
   it fights wherever you are.
6. Make sure **Auto Farm** is on, and watch `FARM STATE`. A healthy startup looks
   like `ROUTE  #1` while it walks, then `CHASE  …`, and `IDLE (NO TARGET)` only when
   nothing eligible is alive.
7. If it stands still on `IDLE (NO TARGET)` with mobs in sight, add those mobs to
   Enemy Priority — being able to see a mob is not the same as being allowed to
   attack it.

## Tab reference

The rest of this file walks the window tab by tab. Every control listed exists in
the code with that exact label; defaults and ranges come from the profile schema in
`Core/SaveConfig.lua`.

### Farming tab

The Farming tab is where the farm loop is switched on and told what to fight, split into
Core, Combat, Targeting, Auto Block, Mob Gather and Booster Reset sections. Every toggle here
is saved in the active profile unless it is marked global.

#### Core

The main switch and the ways the farm decides where to go. The toggles appear in the order their
modules start, so the exact order can differ between versions; each one writes its saved value
straight away.

- **Auto Farm** (default on) — the main loop. Useful only once the Targeting section has at least one entry, or the farm zone the character is in has Zone Targets; with none it stands still on `IDLE (NO TARGET)`. Switching it **off also switches Boss Route off**: the route is part of a farming session, and left on it would run a boss loop with no farm behind it. Turning Auto Farm back on does not turn the route back on.
- **Auto Find** (off) — ignores the waypoint route and goes straight for targets; needs a target list to find anything.
- **Auto Patrol** (off) — walks around the farm zone looking for targets when none are near. Needs at least one farm zone, otherwise there is nowhere to patrol.
- **Return To Farm Zone** (on) — walks back inside the farm zone after leaving it, or after the route ends outside it. Needs farm zones.
- **Ignore Farm Zone** (off) — fights and mines anywhere instead of only inside farm zones; it also ignores the zone's Zone Targets rule.

The Core section ends with three sliders that belong to the combat loop:

- **Execute Charge at HP%** (default 0, range 0–90) — below this much health a target is finished off instead of retreated from. 0 disables it, and an incoming enemy skill still overrides it.
- **Retreat At HP%** (40, 0–80) — retreat below this share of health. 0 means never retreat, not even on the frame health reaches 0.
- **Auto Heal at HP%** (65, 30–80) — drinks the last used potion at or below this share, in the farm loop and in a Boss Route fight. The wait between attempts is **2 s** (a spam guard); the game's own potion cooldown decides whether the drink lands, so a potion that is ready is not sat on.

#### Combat

How the character fights once Auto Farm has a target. Auto Block has its own section below.

- **Safe Combat** (on) — fights from outside enemy weapon reach, backing off and circling. Off, it fights up close at the distance in **Close Combat Range**.
- **Jump While Fighting** (off) — jumps over something actually in the way while chasing a target. Off, the character keeps its feet on the ground for the whole fight: a crowd of mobs pressed against it used to read as low terrain, which hopped it at the fight on every frame. The waypoint route (route holes and ticked waypoints), Waypoint Loop, patrol, mining and smithing make their own jumps and are not affected.
- **Auto Skill** (on) — uses the weapon skill on the target when it is off cooldown.

Auto Mining, Auto Smithing, Leave On Danger Group and Join Alerts also exist as toggles, but on
the Mining, Crafting and Server tabs respectively; the Party System toggle is on the Party tab.

#### Targeting

This section decides what the character is allowed to attack: an ordered priority list, a
tie-break, the retreat thresholds, the fighting distances, and two pickers for adding targets.

- **Add Mob Target** — dropdown of the mobs that are currently loaded: it reads the `Entity` name out of `Config` on every model in `workspace.Mobs`. Stand where the mobs spawn before picking; picking one adds it to Enemy Priority.
- **Add Player Target** — dropdown of the players in this server except you, shown as `@name`. Adding one makes that player a target like a mob.
- **Enemy Priority** — the ordered list of targets, first to last. Drag a row to reorder. This is the list the loop reads when the current farm zone has no Zone Targets, so an empty list means no target is ever chosen.
- **Target Type** — tie-break between targets of equal priority: `Disabled` (the default: nearest first), `Highest HP` or `Lowest HP`.
- **Retreat At HP%** (40, 0–80) — same value as the slider in Features; either one changes the retreat threshold.
- **Auto Heal at HP%** (65, 30–80) — same value as the slider in Features.
- **Execute Charge at HP%** (0, 0–90) — same value as the slider in Features.
- **Safe Enemy Range** (4, 0–30) — extra gap kept from enemy weapons, used while Safe Combat is on.
- **Close Combat Range** (6, 4–12) — how far from the target it fights with Safe Combat off; 4 is just clear of the body, 12 is weapon reach.
- **Refresh Detected Targets** — rebuilds both pickers immediately instead of waiting for the next refresh.
- **Open Mob Dictionary** — opens the floating dictionary: health, speed, threat, drops, and an **ADD TO ENEMY PRIORITY** button (that button needs a profile to be loaded).

With a farm zone picked in Profile Settings, that zone's own Zone Targets replace Enemy Priority
while the character is inside it, so the same mobs can be fought in a different order per zone.

#### Auto Block

Handles players who are not on the whitelist, and the list itself. Above **Auto Block**, set apart
by a divider, **Leave Instead Of Block** (off, global) skips the block entirely and instead closes
the game — you drop out of the server to the Roblox app, not to another server (its help line says
so). **Auto Block** (on) blocks strangers and leaves the server, delayed by
**Block Delay (s)**; **Auto Confirm Block** (off), directly under it, presses Block in Roblox's
block dialog for you so it needs no manual press — executor only, since it reads CoreGui. The
whitelist, Whitelist Skips Safety and Leave Instead Of Block are shared by every profile and
every place, unlike the rest of this tab.

- **Leave Instead Of Block** (off, global) — instead of blocking an intruder, close the game as soon as their Block Delay runs out, plus the random pause below. The client is kicked out to the Roblox app (the connection closes and the run ends), so you are back at the home screen rather than on another server; a kick is the one thing a client script can use to get out of the game, and Roblox exposes no client API that leaves to the home screen directly, so the kick screen is what you see on the way out, with the intruder named. Nobody is added to Roblox's block list, so the same player can be met again next time.
- **It happens once per session.** The kick is made, the farm stops on the spot and nothing is reported again — not another kick, not another report. That matters because a kicked client can sit on the disconnect screen with the executor still running: before, the farm asked to leave on every frame of that screen, which is where the burst of kicks and the stream of end reports came from. A hop that silently fails is the one case that frees the latch again, after 20 s, so a dead teleport does not freeze the run — still with no second report.
- **Nobody on the Block Whitelist ever causes it.** Whitelisted players are already skipped by the intruder check, and Leave Instead Of Block refuses them a second time inside `LeaveGame`, so the list is who the setting leaves alone — including a whitelisted player who also sits on Roblox's block list, which a normal Auto Block would still hop for. With the setting on, that player is ignored and the status reads `IS WHITELISTED, STAYING`.
- **Block Delay (s)** (0, 0–120) — how long a stranger may stay before being blocked (or, with Leave Instead Of Block, closing the game) and the server left. 0 acts at once; each player's delay starts the moment they join (or the first look at them, for someone already here when the script loaded). The leave itself waits it out too: a kick asked for early waits on one timer for the rest and looks at them again before closing the game, so no path can leave before the delay. A player who is no longer in the server when that timer runs out is left alone, and their delay starts over when they come back.
- **Random Leave Delay** (on, global) — every leave the script starts on its own waits a random **2–4 s** first, so the client never drops the server on the very frame a stranger appeared. It is taken once per leave, not per ask, and the longer of it and the Block Delay still owed to the player is what runs. Covered: Leave Instead Of Block and the kick fallback, **Follower Guard's kick**, and the **Leave On Danger Group** hop. Manual exits (**Rejoin**, **Server Hop**, **Join Job ID**) and the server-age hop are your own doing and are not paused. Turn it off and only the Block Delay remains.
- **Whitelist Skips Safety** (on, global) — players on the Block Whitelist never make Auto Block or Leave On Danger Group leave the server, even if already blocked.
- **Block Whitelist** — the UserIds Auto Block never touches. Entries show as `UserId  ·  @name` once the name is known; drag to reorder.
- **Add Player In Server** — dropdown of the players in this server, listed as `DisplayName (@name)  UserId`. Picking one whitelists them.
- **User ID** — textbox for a raw UserId to whitelist.
- **Add User ID** — adds the UserId typed above; digits only.
- **Add Everyone Here** — whitelists every other player in the server in one press.
- **Refresh Player List** — rebuilds the dropdown now.
- **Clear Whitelist** — removes everyone from the Block Whitelist.

#### Mob Gather

**Gather Mobs** (off) turns the pull-and-skill pack routine on; these three controls say what
counts as a pack and how big it may get. It runs inside the farm loop after the waypoint route,
so Auto Farm must be on, and it fights on its own while it works, which skips the normal combat
for that frame.

- **Min Mobs** (3, 2–8) — fewest mobs that make gathering worth starting, all of them within Gather Radius of each other.
- **Max Mobs** (5, 2–10) — most mobs pulled into one pack before the skill is used.
- **Gather Radius** (40, 15–80) — how close together the mobs must be to count as one pack.

#### Booster Reset

**Refill Booster** (on) resets the character when a booster runs out, so the game refills it.
Saved under the `ResetOnBoostOut` key, so older profiles keep working. **Safe Booster Reset**
(off) makes it wait until no mob is hitting you before resetting. Which boosters count is chosen
here: the boosters are the game's, so the section finds them itself — every value under
`PlayerStats` whose name contains `boost` gets a toggle of its own, rather than the script deciding
in advance how many kinds there are. Names it has never seen are listed and start switched off.

- **BOOSTERS** (readout) — every booster found, each marked `ON` or `off`. `none found yet` while `PlayerStats` does not exist; the scan waits for the game to create it, and **Refresh Boosters** looks again on demand.
- One toggle per booster, labelled with the game's own name — **ON** means that booster running out resets the character, so one kind of boost can refill while another does not.
- **Refresh Boosters** — scans `PlayerStats` again, adds a toggle for anything new and starts watching it. Never duplicates a toggle or a connection.
- The selection is the profile's `RESET_BOOSTERS` setting: the names switched on. The default is `Boost` and `BoostDrops`, the two the script knew before the section existed, so an existing profile keeps resetting for exactly what it did before. Anything else the game has stays off until you switch it on.
- A booster is watched even while switched off, and the setting is read when the boost changes — so switching one on takes effect at once, with no rescan.
- Names are matched as a substring, so a stat that merely contains `boost` is listed too. It is off by default, and switching it off again is permanent for that profile.

### Profile Settings tab

Everything here is per profile and per place: the route the character walks, the areas it may
fight in, the areas it must stay out of, and the profiles themselves. The "Default Config" entry
in the Profile dropdown is read-only — pressing any Add/Edit/Clear button without a profile
loaded reports `CREATE / LOAD PROFILE FIRST` in the STATUS line.

#### Profiles

- **STATUS:** — one line telling you what just happened: which profile loaded, or why it did not.
- **Profile Name** — the name used by Create New Profile, and filled with the active profile's name.
- **Create New Profile** — saves the current settings under the name above and switches to it.
- **Save Profile** — writes the current settings into the active profile.
- **Export Save** — copies the active profile to the clipboard as text to share.
- **Import Data** — textbox for pasted profile text.
- **Import Save** — creates a profile from the text above.
- **Delete Profile** — deletes the active profile and falls back to the place defaults.
- **Profile** — the dropdown that loads a profile. On startup it auto-loads the profile last used in this place, if there is one.

#### Waypoints

The route walked before farming starts. Waypoints are recorded as positions, so they are per
place as well as per profile.

- **Add Waypoint Here** — adds a waypoint at the character's current position.
- **All Waypoints** — the numbered route, each row showing its position. Rows with a paired zone show `> Z#`, and dragging a row reorders the route along with its wait, zone pair and jump tick.
- **Wait (s)** — per-row number of seconds to stand at that waypoint before moving on (0 up to `AICConfig.MAX_WAYPOINT_WAIT`). While waiting the character stands still and does not fight.
- **Jump** — per-row tick: jump on reaching that waypoint. Put the waypoint at the edge of a gap and the next one on the far side.
- **Clear Waypoints** — removes every waypoint.
- **Waypoint Reach Distance** — how close counts as reaching a waypoint (default 5 studs). Higher values cut corners; too high can skip a waypoint entirely.
- **Hole Check Distance** (2, 0.5–6) — how far ahead the route looks for a gap to jump, in studs.
- **Hole Check Step** (0.5, 0.25–2) — spacing between those ground checks; smaller catches narrow gaps.
- **Hole Min Depth** (1, 0.5–10) — a drop at least this deep counts as a hole worth jumping.
- **Pair Waypoint** / **Paired Farm Zone** — pair one waypoint with one farm zone. The pair is what waypoint **Waypoint Loop** follows, and it also tells the loop which zone to fight in after the route.
- **Waypoint Loop** (off) — turns the route into a loop over the paired zones only: it farms the zone paired with the waypoint it reached, and walks between paired zones when a zone has nothing to fight. Needs at least one waypoint paired with a farm zone, otherwise it has nothing to loop over.

#### Farm Zones

The areas the character is allowed to fight in. With no farm zone at all, nothing is restricted
and it fights wherever the target is; with one or more, it stays inside them.

- **Farm Radius** (100, 1–500) — size of the zone picked in **Edit Farm Zone**.
- **Add Farm Zone Here** — adds a circular zone centred on the character, using the current Farm Radius.
- **Edit Farm Zone** — picks which zone the radius and Zone Targets apply to.
- **Zone Targets** — targets for the picked zone, in order. Empty means the zone falls back to Enemy Priority; that is why a zone can be worth filling in.
- **Add Zone Target** — dropdown that adds a mob or player to the picked zone's Zone Targets.
- **All Farm Zones** — the zone list; drag to reorder, which also changes the order Waypoint Loop walks them in.
- **Clear Farm Zones** — removes every farm zone.

#### Deadzones

Areas the character never fights in and never walks through, checked by combat, mining and the
route. Dead zones are independent of farm zones, so they can be used with none configured.

- **Deadzone Radius** (35, 1–250) — size of the zone picked in **Edit Deadzone**.
- **Add Deadzone Here** — adds a deadzone centred on the character, using the current Deadzone Radius.
- **Edit Deadzone** — picks which deadzone the radius applies to.
- **All Deadzones** — the deadzone list, drag to reorder.
- **Clear Deadzones** — removes every deadzone.

### Mining tab

Mining is not a second farm loop: Auto Mining is offered the frame by Auto Farm, so it only acts while **Auto Farm** is on and only once the waypoint route has been walked (`STATUS  WAITING FOR WAYPOINT ROUTE` while the route is still being walked, `WAITING FOR AUTO FARM` while Auto Farm is off). It never mines outside a mine zone, and when there is nothing to mine it hands the frame straight back to farming. The tab has two sections, **Auto Mining** and **Mine Zone**.

#### Auto Mining

- **Auto Mining** (off by default) — the toggle. Switching it on with no mine zone configured warns you instead of starting: "Add a mine zone first; ores outside one are never mined."
- **STATUS** — one line, rewritten every 0.25 s, saying what mining is doing: `OFF`, `WAITING FOR AUTO FARM`, `WAITING FOR WAYPOINT ROUTE`, `WALKING TO  <ore>`, `CLAIMING  <ore>`, `MINING  <ore>  3.2s`, `DEFENDING`, `IDLE  //  NO MINE ZONE`, `IDLE  //  NO ORES IN PRIORITY`, `IDLE  //  NOTHING TO MINE`. Reading this line is the fastest way to see why nothing is being mined.
- Mining runs in rounds: it picks the highest-priority ore that has a free node in a mine zone, walks to it with the shared walk controller, claims it from within 15 studs, then stands still for the game's mining cooldown plus 0.15 s. **WalkSpeed is held at 0 while claiming or mining**, so nothing can walk the character off the node (the game cancels mining, and can kick, when it gets too far away).
- Anything within 10 studs while a job is on is fought: the weapon is drawn and hit once in range, and the status shows `DEFENDING`. Retreating on low health still outranks mining, as it does for farming.
- A node it cannot reach in 15 s is skipped for 30 s, and a claim that another player takes over within 1 s is dropped rather than fought over.

#### Ore Priority

The list of ores to collect, in the order to collect them; each row carries its own target count. Ores are mined top to bottom, and each one is mined until the inventory holds its `Target`.

- **Ore Priority** (default `Iron Ore` 500, `Copper Ore` 500) — the list itself. Drag a row to reorder it, or use the ▲▼ buttons; the number box on each row is that ore's `Target`, 0–500 (`ITEM_MAX_STACK`, the game's per-item cap). What you already carry counts toward the target, so 250 held against a target of 500 leaves 250 to go.
- When every node of the top ore is unavailable — taken by another player, still regenerating, or unreachable — it moves on to the next ore in the list instead of waiting. Ore outside every mine zone, or inside a deadzone, is never chosen.
- **Add Ore** — dropdown of ores currently loaded near you that are not already in the list ("No ores found" when there are none). It is rebuilt only when that set changes, and never while you have it open.
- **Ore Name** + **Add Ore By Name** — for an ore that is streamed out of range: type its exact name and add it. The text box clears after adding.
- **Refresh Ore List** — rebuilds the **Add Ore** options on demand (e.g. after you walk to a different part of the map).
- Adding a name that is already in the list reports "`<ore>` is already in the list" rather than duplicating the row.

#### Mine Zone

Auto Mining works only inside mine zones, so this section is what makes the rest of the tab do anything. Zones are saved with the profile (like farm zones and deadzones), so different profiles can hold different sets.

- **All Mine Zones** — the list of zones, each row showing `#<n>  R:<radius>  (<centre>)` (the index, the radius and the centre). Drag to reorder, or use ▲▼; each row can be removed.
- **Add Mine Zone Here** — adds a zone at your current position, with the radius currently set on the slider below.
- **Edit Mine Zone** — picks which zone the radius slider applies to.
- **Mine Zone Radius** (5–300, default 60) — size of the zone picked in **Edit Mine Zone**.
- **Clear Mine Zones** — removes every mine zone, which stops mining until one is added again.
- Any zone edit needs a profile: without one loaded it reports `CREATE / LOAD PROFILE FIRST`, and a built-in place preset is read-only ("DEFAULT PLACE_CONFIG IS READ-ONLY"). Load or create a profile first, then add zones.
- Cross-reference: the Debug tab's **Debug Mine Zones** draws the zones and **Debug Ore Status** labels each ore with what mining thinks of it — `TARGET`, `CLAIMING`, `MINING  2.0s`, `READY  120 / 500`, `DONE  500 / 500`, `TAKEN  <player>`, `REGENERATING`, `OUTSIDE MINE ZONE`, `IN DEADZONE`, `NOT IN PRIORITY`, `UNREACHABLE`.

### Crafting tab

Crafting uses a smithing table: with **Auto Farm** on it runs after the waypoint route is walked and *before* Auto Mining, and it is never pulled off a table mid-craft by mining. With Auto Farm off it still works on its own — it walks to a table and crafts. The tab has the **Auto Smithing** section, plus **Recipe Status** and **Material Reserve** below it.

#### Auto Smithing

- **Auto Smithing** (off by default) — the toggle.
- **STATUS** — what crafting is doing right now (also `OFF` while the toggle is off).
- **SMITHING SKILL  <n>** — your current smithing skill, read from the game; recipes above it are skipped.
- **TABLE  NEAREST** or `TABLE  SET  (x, y, z)` — which table is in use. `NEAREST` means it picks whichever table is closest; otherwise it uses the position you saved.
- Recipes are worked in priority order, one craft at a time. A recipe is skipped when your SmithingSkill is below the recipe's `CraftingSkill`, when the materials left after reserves do not cover even one craft, or when the inventory already holds its `Target`. Once it decides, it walks to the table and calls `CraftingStart` from within 8 studs; the strike minigame is then played automatically. A craft ends when the minigame shows its result and the window closes, and the next one waits for the inventory to update.
- Three failed crafts in a row pause that recipe for 60 s (`PAUSED AFTER FAILURES`) so one bad recipe cannot stall the list; the other recipes keep going.
- A table it cannot reach in 30 s, or cannot path to, is skipped for 30 s. Mobs that get in the way while walking are fought first, then it carries on.
- **Set Smithing Table** — stand within 20 studs of a table and press it to save that table for this profile. It saves the position, not the instance (the Id can change between servers), and later matches a table within 10 studs of that spot. Needs a profile loaded, otherwise `CREATE / LOAD PROFILE FIRST`.
- **Use Nearest Table** — forgets the saved table and goes back to using whichever is closest.
- **Open Recipe Browser** — opens the floating Recipe Browser window described below.
- **Refresh Recipes** — reloads the recipe and material data, and rebuilds the **Add Material** options.

#### Recipe Priority

The recipes to craft, in order, each with its own target count. Recipes are crafted top to bottom until each reaches its `Target`.

- **Recipe Priority** (default `Iron Ingot` 500, `Copper Ingot` 500) — drag a row to reorder, or use ▲▼; the number box per row is that recipe's `Target`, 0–500 (`ITEM_MAX_STACK`). Setting a target of 0 effectively parks that recipe.
- This is the same list as the **PRIORITY** tab inside the Recipe Browser — editing either one reloads the other. Newer recipes are added from the Browser's **RECIPE** tab.

#### Recipe Status

One line per recipe in the priority list, refreshed about once a second, telling you exactly why a recipe is or is not being crafted:

- `#1  Iron Ingot  120/500  //  READY  x3` — craftable now, and how many crafts the materials allow.
- `//  LOCKED  SKILL 2 / 1` — the recipe needs skill 2 and you have 1.
- `//  NEED Iron Ore 3/1` — the material that is short, with how many you have against how many one craft needs (counted after reserves).
- `//  DONE` — the inventory already holds the target.
- `//  PAUSED AFTER FAILURES` — three failures in a row; it resumes after 60 s.
- `//  UNKNOWN RECIPE` — a name in the list that the recipe data does not know.
- `NO RECIPES IN PRIORITY` — the list is empty, so nothing will be crafted.

#### Material Reserve

Materials listed here are kept back and never spent on crafting, which is how you stop Auto Smithing from eating ore you want for something else.

- **Keep In Inventory** (empty by default) — one row per material, each with a `Keep` count (0–500, default 0). The recipe planner subtracts these before deciding whether it can craft.
- **Add Material** — dropdown of every material any recipe uses that has no reserve row yet ("No materials found" when there are none). Adding one reports "Reserve added for `<material>`; set how many to keep" — the row starts at 0 until you set it.
- Reserves apply to the priority list and to `NEED`/`MISSING` counts shown in the Recipe Browser.

#### Recipe Browser

A floating, draggable window opened with **Open Recipe Browser**; everything about crafting can be done from it without the main window. It re-reads your inventory and skill every 1 s while open.

- Left side: every recipe, narrowed by the search box (it matches recipe or material names, so typing an ore name finds every recipe that uses it), the item-type chips (`ALL  <count>`, plus one chip per type), and a **READY ONLY** filter. Each row shows the skill needed and its status, so locked, short-of-materials and craftable recipes are distinguishable at a glance.
- **RECIPE** tab — the recipe you picked: its type, level or skill, stats, whether it is tradeable, `SMITHING SKILL <needed>  ·  YOURS  <yours>  ·  HAVE  <held>`, a status line, and `MATERIALS PER CRAFT  (tap one to see how it is made)` with have/need and missing counts per material (after reserves). Tapping a material opens a small popup next to the row saying what it is crafted from, and from there you can open that recipe.
- **CRAFT NOW  ·  UP TO <n>** — a craft order for the picked recipe, with an `Amount` slider, an amount box, `MAX` and `CRAFT`. An order runs *before* the priority list and works even with **Auto Smithing off**. The running order is shown as `ORDER  <name>  <done> / <count>` with a `CANCEL` button, and it stops on its own when the count is done or it cannot continue (materials, skill too low, paused after failures).
- **ADD TO RECIPE PRIORITY** / **REMOVE FROM RECIPE PRIORITY** — adds or removes the picked recipe from the same priority list shown on the Crafting tab.
- **PRIORITY** tab — the recipe priority list itself, with the note "Recipes are crafted top to bottom until each reaches its Target. Add them from the RECIPE tab."
- **Open Asset Explorer** (on the Crafting tab) — a separate window for every item: stats, price, recipe, drops and uses. Useful for finding what a material is for or where a drop comes from.

### Bosses tab

A boss route is its own list of stops. It is saved in the profile like waypoints
and zones, but kept apart from them (place config `BOSS_ROUTE`): the Farming
waypoint route and the Profile Settings waypoints never move it, and editing a
boss stop never moves either of those. Use it for the run where you walk (or
teleport) to a boss, fight it, and reset back to spawn before the next one.

#### Boss Route

- **Boss Route** (off by default) — the tab's master switch. It works with Auto
  Farm on or off; while it is on it owns movement and combat, and the safety
  checks above it (party hold, retreat, Auto Block, server age) still run first.
- **STATUS:  …** — what the route is doing: `STOP 2/4  PATH 3/8`,
  `STOP 2/4  WALKING`, `… FIGHT`, `… CLEARING  7s  LOSE 95 EXP`,
  `… CLEARING  7s  LOSE 95 EXP  RUNNING`, `… BOSS DOWN`,
  `… TELEPORT WP3`, `… TELEPORT <prompt>`, `… RESET PENDING`, `… RESET RETRY 1`,
  `ROUTE FINISHED`, `OFF`.
- **Add Boss Stop Here** — saves a stop at your current position, with an empty
  **Path to Boss**. A new stop starts with **Reset After Kill on**, a 10 s
  **Reset (s)**, **Dodge Skills on**, **Teleport To Prompt off** and a 120-stud
  engage radius.
- **Boss Route** (list) — one row per stop, `#1  Boss 1  > WP3  P6  Goblin
  (x, y, z)`: the stop's name, its teleport waypoint, how many path points it
  has, its first boss name and where it is. Drag a row (or use ▲▼) to reorder
  the  route. Its `Reset (s)` box is the pause held at the corpse before the
  character resets (0–600), used **only when the EXP sits above the part of
  the bar a reset keeps** — see *What a stop does*; ✕ removes the row. There
  is no fight timer: the row can never reset while the boss lives.
- **Clear Boss Route** — removes every stop.
- **Edit Boss Stop** — picks which stop the boxes below change, and which stop
  **Path to Boss** and **Boss Names** edit.
- **Boss Stop Name** — the name shown in the list.
- **Teleport Waypoint #** — one of the game's waypoints to teleport to before
  walking to the stop (0 walks the whole way). Uses the same `TeleportEvent`
  remote as the Teleport tab.
- **Dodge Distance** — how far from the boss the skill dodge settles, 6–80
  studs (16 by default). The default is a step out of a short-range skill; raise
  it for a boss with a wide one.
- **Wait At Spot (s)** — seconds stood at the stop before the fight starts,
  **0 by default**. Raise it for a boss that spawns a moment after the walk
  arrives; at 0 the first swing is on the frame the stop is reached. It is
  **not held on the run back from a death**: the stop is walked again right
  after the respawn and the fight starts on arrival, whatever this box says —
  including on a game that respawns the character in the same instant it dies,
  where no dead frame is ever drawn for the script to see.
- **Engage Radius** — how far from the stop a boss is picked up.
- **Reset After Kill** (on for a new stop) — once the boss is down, reset the
  character so the next stop is travelled to from spawn. Off, the next stop
  starts from wherever the fight ended.
- **Dodge Skills** (on for a new stop) — whether this boss's skill is dodged.
  Off, the character fights through the cast, never sprints away and never
  touches its own walk speed: the stop for a boss whose effects never switch
  off.
- **Teleport To Prompt** (off for a new stop) — travel by the interaction
  prompt (a door, a portal, a boss-room button) instead of a waypoint. The
  character is put next to the prompt and then walks the rest of the Path;
  **nothing is pressed**, not on landing and not during the walk: the teleport
  is the travel, and a press at the prompt it landed on re-fires that same door
  or menu (a door that teleports the character turned that into an endless loop
  of presses). The suppression is set **before the teleport**, not on landing,
  so no press can slip out while it moves, and it lasts the whole visit. A stop
  with both set uses the prompt, not the waypoint.
- **Save Prompt Here** — records the nearest interaction to where you stand as
  this stop's prompt and switches **Teleport To Prompt** on: a `ProximityPrompt`
  or a `ClickDetector` within 40 studs, found whether it hangs off a part, an
  `Attachment` or a model. With nothing that close it saves the spot you are
  standing on instead (`HERE`), because that is where the game's prompt is
  anyway — that also covers a game whose interaction is not a `ProximityPrompt`.
  Every press answers on screen: a toast (`Prompt saved: …`, or
  `No prompt within 40 studs (nearest 73); saved where you stand`) and the
  label under the toggle, which always shows the saved name and position. With
  nothing saved the nearest prompt to the stop itself is used at run time, so
  the button is optional.
- **Add Boss Name** — a dropdown, nothing typed: the mobs **around the player**
  (within 300 studs) nearest first, then every other mob the game has loaded.
  Pick one to add it to the selected stop. This is the same picker pattern as
  Zone Targets.
- **Refresh Nearby Bosses** — sits directly under **Add Boss Name**; rebuilds
  the dropdown after walking somewhere new.
- **Boss Names** (list) — the names the stop fights, in order; drag to reorder,
  ▲▼ or ✕ to change. Empty fights whatever is at the spot.
- **Move Stop Here** / **Remove Stop** — move the selected stop to the character,
  or delete it.
- **Loop Route** (on by default) — after the last stop, start again at the first.
  Off, the route plays once and switches Boss Route off.

#### Path to Boss

The way to each boss is a list of points you record once, in the order you walk
them. This is the whole navigation: the route walks point to point and never
solves or guesses a way round anything.

- **PATH TO <STOP>  (#n)  m POINTS** (readout) — which stop, and how many points
  the list below has.
- **Add Path Point Here** — saves the character's current position as the next
  point of the stop selected in **Edit Boss Stop** above. Walk the route once,
  pressing it at each corner: around the building, through the door, along the
  corridor, and at the boss.
- **Path Points** (list) — `#1  (x, y, z)` per point; drag to reorder, ▲▼ to
  swap two neighbours, ✕ to delete one.
- **Clear Path** — empties the selected stop's path, so the route walks straight
  at the stop from wherever it is (fine for open ground).

Points are per stop, and the list always follows **Edit Boss Stop**. A stop with
no points walks straight at it, which is what the route did before Path to Boss
existed — and it says so, `WALKING  NO PATH POINTS` on the status, so a stop
whose points never arrived can be told apart from one that never had any. The
last leg is the stop itself (**Move Stop Here** sets it), so the final point can
be the doorway and the stop the boss.

A visit walks the points the stop had when it began, pinned for that visit. A
place config that lands mid-visit (a profile apply, another feature normalizing
the config) replaces the stop table, and reading the points back off it each
frame was the one way the walk could leave the points part-way and head at
`Stop.Position` instead. A stop that began with no points takes whatever the
config holds as soon as it arrives, so points saved — or loaded — a moment after
the route started on the stop are still walked.

#### What a stop does

1. Teleports to its prompt (when **Teleport To Prompt** is on) and waits 0.6 s
   for the landing; nothing is pressed there. Otherwise it teleports to its
   waypoint (when one is set) and waits 2 s to land.
2. Walks its **Path to Boss** points in order, then the stop itself. A point
   counts as reached within 4 studs (`Waypoint Reach Distance` for the stop).
   The points are the visit's own copy, taken when the stop began: replacing or
   reloading the place config mid-walk can no longer send the walk straight at
   the stop. A stop with no points at all shows `WALKING  NO PATH POINTS`.
3. Fights as soon as the stop is reached, unless the stop sets **Wait At Spot
   (s)** — 0 by default, so normally there is no wait. That wait is skipped on
   a visit that continues a stop the character **died** at: the walk back
   starts again from the stop's first path point once the character respawns,
   and the fight starts the moment it is there — the boss that killed it is
   already standing in the spot, so there is no spawn to wait for. A death is
   read from the character's health **and** from the player's own death counter
   (`CharacterAdded`), so a game that respawns in the same instant it kills —
   no dead frame at all — is still walked back to the stop instead of being
   taken for a fresh arrival that waits. The nearest
   living mob inside **Engage Radius** that matches **Boss Names** (anything
   when empty)   is the target. The sword is asked for from 60
   studs out on the last leg, and again every frame of the fight until the
   tool's weld says it is really in the hand (the cached equipped flag is not
   trusted: it survives a respawn that sheathed the sword). The frame the equip
   input goes out the character stands still, so it is not running at the boss
   with the sword still on its back. The same attack and skill inputs as Auto
   Farm are pressed from then on.
4. Ends the stop when the target dies and nothing else is left there (a 2 s
   grace), or when there is nothing to fight for 5 s. The fight is only over
   when the game says the boss is gone: a scan that loses a living boss (out
   of **Engage Radius**, a model swap, a root gone for a frame) keeps the mob
   already being fought, so it can no longer reset mid-fight. That keep is a
   grace, not a switch — the scan reads the `Mobs` folder every 0.2 s, and a
   mob it has not found for **4 s** is not the stop's boss any more. Without
   the limit, a boss killed by another player whose body the game took out of
   that folder without ever setting its health to 0 held the stop in `FIGHT`
   on a reference nothing could reach: the character stood at the corpse until
   the game finally dropped the model, which is why it looked like the route
   was waiting for the character to heal before it would reset.
5. If it ends on the kill and **Reset After Kill** is on, where the character
   is in its EXP bar decides the reset. A reset keeps the **first 10% of the
   bar for every 100 levels**, stopping at **90% from level 900 up** — the part
   of the bar the game protects. The bar is the level's own requirement, the
   number the HUD prints: `EXP <value>/<neededExp(Level)>`, **2,438,097** at
   level 900, with the value starting again at 0 on every level. The kept part
   there is therefore the first **2,194,287** EXP: 100,000 into the bar comes
   back as 100,000 (nothing lost), 2,300,000 comes back as 2,194,287 (about
   105,700 lost), and the numbers grow with the level rather than being fixed.
   A game publishing a **running total** instead is read too: a value between
   this level's requirement and the next is treated as progress in the next
   level's bar. An EXP inside the protected part loses nothing, so the reset
   happens **at once** — one scan tick after the kill, with `RESET NOW` on the
   status line. Above it the
   character holds at the corpse for the row's **Reset (s)** — **10 s** for a
   stop that has not set one — and `CLEARING  7s  LOSE 50 EXP` counts it down.
   During that hold a living mob within **40 studs** is run from: the character
   sprints to a ring 45 studs on the far side of it (further when the stop's
   **Dodge Distance** is larger), and the status adds `RUNNING`. Standing at
   the corpse while a mob hits it is what killed the character before the
   reset it was waiting for. The borrowed sprint speed is put back when the
   hold ends.

   **A boss killed while you were dead still counts.** If the character dies at
   a stop it was fighting, the walk back watches the spot instead of assuming:
   a boss that is still there is walked to and fought as usual, and a spot that
   stays empty for a second is this stop's kill — the duo (or another player)
   finished it while you were down. The status says `BOSS DOWN WHILE AWAY` and
   the toast `Boss at stop #n died while away; counted as this stop's kill`, and
   the route runs the ordinary **Reset After Kill** flow from step 5, EXP hold
   included, instead of walking to an empty spot and moving on without one. The
   check needs a boss that had been engaged at the stop before the death; a stop
   whose boss was never seen is still treated as not spawned rather than killed,
   so a wrong spot cannot reset the character over and over.
   The protection is a property of the bar, not of the level, so a level where
   a reset was free is still held once the EXP climbs past it. Then the
   character is reset (health set to 0, the same reset Party System uses). That
   is the **only** reset: the character never resets while the boss is still
   standing, and there is no fight timeout to reset on. A corpse left in the
   stop's radius counts as the kill even when the fight never saw the boss
   standing, so a boss that dies between two scans still resets the stop
   instead of sending the route to the next waypoint.
6. Once the character is back it goes straight on to the next leg — there is no
   second pause after the reset, and nothing waits for the EXP drop either: the
   wait that matters is the one before the reset. A reset the game ignores
   (health restored, the request dropped) is asked again after 3 s, up to twice,
   and the status says `RESET PENDING` / `RESET RETRY n` in the meantime.
7. Then the next stop begins — teleporting to its own waypoint first. Reaching
   the end loops, or finishes when **Loop Route** is off.

**Skill dodge (Boss Route only).** The dodge starts on the **cast**, not on the
damage: the boss's `Skill` sound or its blade/body particles switching on is the
signal, so the character steps out before the hit lands. A loss of **20% of the
bar within 0.6 s** is still read as a skill landing and used as the backup when
the effects were missed. Either way the character stops swinging and runs — the
normal run speed plus a sprint — out to a ring **16 studs from the boss**
(**Dodge Distance** on the stop, 6–80, sets its own), picking a direction that
has ground and a clear line. It stays on that ring: once it is out it stands
there facing the boss (the sprint put away) instead of picking a point further
out, so a skill that lasts walks it a step out, not across the room.

How long it stays out is read from the boss, not from a timer. The game turns on
the blade's `Sparkles`/particles and plays a `Skill` sound while the skill is
running, so the dodge holds while those effects are showing and comes back
**0.5 s after they go out** (at least 1.5 s, at most 8 s in case an effect never
switches off). A long skill is therefore dodged for its whole length instead of
walking back into it, and a short one still gets the minimum. Slow damage is not
a skill and never triggers it. **Dodge Skills** on the stop turns all of this off
for that boss. This lives in the Bosses tab only: the Farming tab's own retreat
behaves exactly as before.

#### Walking to a stop

Each leg is a straight `Humanoid:MoveTo` to the next saved point. Nothing
solves a route: no `PathfindingService`, no steering, no detours. Where you put
the points is where the character walks, so the way round a building is the one
you recorded. Steps, curbs and fences are handled by a jump: the position is
sampled twice a second and a hop is added when under 0.75 studs were covered,
plus a jump when something low is in the way.

While it walks it also presses the game's **Interact** input every 0.5 s — the
same `INTERACTION_INTERVAL` the Farming waypoint route uses — so doors, levers,
chests and other proximity prompts on the path are used as the character passes
them instead of being walked past. It stops pressing on the frame the stop is
reached, so a prompt cannot take the place of the first swing. A visit that
**teleported** — by prompt or by waypoint — does not press at all for the whole
visit: the switch goes off before the teleport request, because a waypoint or
prompt can sit on the landing spot and the walk can pass it again, and a press
on the prompt the character landed on re-fires that same door or menu. The
shared mute also covers Auto Farm's presses and the **Teleport** tab's
door/waypoint warps for **10 s**.

A stop is given up when the character has not got **closer** to the next point
for 20 s (a point saved inside a wall, or on the wrong floor), or when one leg
takes more than 120 s; the notice says which stop was skipped and the route
moves on. That is the only time a stop is abandoned — a long walk with many
points is never a failure, because the 120 s counts per leg.

A **Teleport Waypoint #** near the boss is still the most reliable option: it
warps most of the way, leaving only the last short leg to walk.

Notes:

- The route is saved per profile on the place config, so a profile without one
  starts empty and adding stops needs a loaded profile (`CREATE / LOAD PROFILE
  FIRST`, `DEFAULT PLACE_CONFIG IS READ-ONLY` on a built-in preset).
- A prompt teleport the game refuses (a dead character, a load) falls back to
  the stop's waypoint or the walk, and the teleport is retried once when nothing
  moved and the stop is still far away.
- Dying on the way, or in the fight, is **not** treated as the stop being done:
  the route waits for the respawn, then teleports to
  that stop's **Teleport Waypoint #** again (if it has one) and walks the same
  **Path to Boss** from its first point. Only a kill moves the route on. A
  teleport the game drops while the new body is still loading is retried once,
  when the character has not moved and the stop is still far away.
- With **Auto Farm** on, the route runs before the farming waypoint route, so the
  two never fight over the character. Turn Boss Route off to farm normally.

### Party tab

Keeps the farm on the same server as a chosen player: when that Leader leaves, the character follows with the game's `tp friend` command. Nothing here does anything until the toggle is on **and** a Leader is picked.

#### Controls

- **Party System** (default off) — the tab's master switch. With no Leader set the tab stays idle.
- **Set Leader** (dropdown) — the other players in this server, each shown as `DisplayName (@Name)`. Picking one saves the Leader into the profile; only a player still in this server can be picked, and the list rebuilds as people join and leave.
- **LEADER:  NONE** (readout) — the Leader currently saved for this profile.
- **STATUS:  IDLE** (readout) — what the system is doing, e.g. `WITH LEADER`.
- **Clear Leader** (button) — stops following anyone.
- **Refresh Player List** (button) — rebuilds the dropdown from the server right now.

#### What happens when

- With the Leader in the server: the farm runs normally, strangers included — Party does not block anyone.
- Something other than the Leader joins and the Leader leaves: the character is reset and held still, awaiting the Leader's move.
- The Leader is already gone: the character is reset, `TeleportEvent(0)` is fired, and 0.5 s later `ChatEvent` fires `Party, tp friend <LeaderName>`. A try counts as successful once the Leader is in the same server.
- Failing tries cost `PARTY_TP_ATTEMPT_TIMEOUT` (15 s) each, up to `PARTY_TP_ATTEMPTS` (3). After that it waits `PARTY_FAILED_COOLDOWN` (60 s), and during that pause Auto Block handles intruders again.
- While Party is following a Leader it takes over intruder handling from Auto Block entirely, so the Block Delay has no effect then.
- Needs the game's `TeleportEvent` and `ChatEvent` remotes; if one is missing a notice appears instead of a silent failure.

### Server tab

This server's live numbers plus leaving it: hop at random, rejoin, or join by Job ID. The hop and the browser read Roblox's public server list with `game:HttpGet`, so they are **executor only** — in Studio they report that the list could not be loaded.

#### Current Server

- **PLAYERS  0**, **JOB ID  -**, **FPS  --**, **PING  -- MS**, **STATUS  IDLE** (readouts) — players against the maximum with the place name (`PLAYERS  n / m  //  <place>`, the name from `MarketplaceService:GetProductInfo`), the Job ID, frame rate, network ping and the hop engine's state. FPS colours at 50/30, ping at 100/200 ms.
- **Rejoin** (button) — rejoins this exact server by Job ID; unavailable if the server reports no Job ID.
- **Server Hop** (button) — picks a random public server that is not full, reading up to `HOP_MAX_PAGES` (4) pages of the list. Pressing it again while one is already finding a server does nothing.
- **Copy Job ID** (button) — copies this server's Job ID to the clipboard.
- **Job ID** (textbox) + **Join Job ID** (button) — joins the Job ID typed in; an empty value or this server's own ID is refused with a notice.
- **Open Server Browser** (button) — opens the browser window below.

#### Server Browser window

- The list puts this server first and marks it `◆  YOU ARE HERE  ·  n / m PLAYERS`; other rows show players, `PING … · FPS …` and a shortened Job ID.
- **REFRESH** / **LOAD MORE** (buttons) — reload the list, or read the next page.
- The right pane shows `◇  THIS SERVER` or `◇  PUBLIC SERVER`, `PLAYERS n / m`, `PING … · FPS …`, the full `JOB ID`, then **COPY JOB ID** and **JOIN**. Until something is picked it reads `Pick a server from the list`.
- Only the current server can list player names under `PLAYERS IN THIS SERVER`; for other servers Roblox reports counts only, which the window states.

#### Server Safety

- **Leave On Danger Group** (default off; shared by every profile) — leaves when someone in a Danger Group is in the server, after the random 2–4 s **Random Leave Delay**. The roster is re-checked every `SCAN_INTERVAL` (2 s), so taking someone off a list is acted on.
- **Follower Guard** (default on; shared by every profile) — watches who keeps ending up in your servers and **kicks you out of the game** when one player looks like they are following you. A sighting is one player in one server: someone already here when the guard starts, or someone joining while it runs (`present` counts once per player and server, so re-running the script cannot make a bystander look like a follower). At `FOLLOWER_TRIP_SIGHTINGS` (2) sightings of one player inside `FOLLOWER_WINDOW` (30 min) the guard trips and calls `Player:Kick`, which disconnects the client to the Roblox app and ends the run, so the follower is left behind for good — after the same random 2–4 s **Random Leave Delay** every other leave takes, so the kick never lands on the frame they joined. The player is not blocked or reported; only leaving is done. If the kick itself fails, the old hold comes back: Auto Farm goes off and **stays off until you click the Auto Farm toggle yourself**; a profile load switching it back on is turned straight back off while the hold is up, and clicking Auto Farm on starts a fresh count, so the old sightings cannot trip it again. You, the Block Whitelist and the Party Leader are never counted. Sightings and the hold are kept in `AutoFarmProfiles/FollowerLog.json` (shared by every profile and place, kept 24 h), so the 30-minute window carries across re-runs of the script.
- **Danger Groups** (priority list) — the group IDs that count as dangerous. Ships with `5928691`.
- **Group ID** (textbox) + **Add Group ID** (button) — validates a numeric ID, rejects duplicates, and clears the box.
- **Danger Whitelist** (priority list) — UserIds this feature stays for even when their group matches. Separate from the Auto Block whitelist.
- **Add Player In Server** (dropdown) — players in this server not already on the Danger Whitelist, each shown with their UserId.
- **User ID** (textbox) + **Add User ID** (button) — adds a UserId typed by hand; non-numeric input is refused.
- **Clear Danger Whitelist** (button) — empties that list.
- On a trigger: it waits up to `DANGER_BLOCK_WAIT` (10 s) for the block to land (so a dialog can be pressed by hand when Auto Confirm Block is off) and then leaves anyway, retrying the hop up to `DANGER_HOP_MAX_ATTEMPTS` (3) times, `DANGER_HOP_RETRY_DELAY` (3 s) apart. A group lookup that fails is retried `GROUP_CHECK_MAX_ATTEMPTS` (3) times, 5 s apart, and only one "could not check" notice appears per 60 s.

#### Alerts and Log

- **Join Alerts** (default off) — notices when someone off the Block Whitelist joins or is already here. Players arriving close together are merged into one notice, and the same message is suppressed for `NOTICE_COOLDOWN` (8 s).
- **Player Log** (readout, 15 rows) — the most recent JOINED / LEFT / PRESENT entries with time and name, tagged `[WHITELIST]`, `[DANGER WHITELIST]` or `[DANGER]`; keeps the last `LOG_LIMIT` (100).
- **Clear Log** (button) — empties it.

### Teleport tab

Warps the character to the doors and waypoints the game exposes, for travelling without walking. It moves only the character; nothing else about the farm changes.

- **Door** (dropdown) + **Teleport To Door** (button) — the doors found in `workspace.Interactions`, one entry per point as `<place>  T1` / `<place>  T2`.
- **Refresh Doors** (button) — rebuilds that dropdown from the folder. Doors stream in and out as you move, so the list follows the folder automatically and only rebuilds when it really changes.
- **Waypoint** (dropdown) + **Teleport To Waypoint** (button) — the game's own waypoints from `workspace.Waypoints`, i.e. only the ones currently streamed in. Pressing it with nothing picked reports "Pick a waypoint first".
- **Refresh Waypoints** (button) — rebuilds the waypoint dropdown.
- **Waypoint Number** (textbox) + **Teleport To Number** (button) — warps to a waypoint number directly, including one that has not streamed in yet; a non-numeric or negative entry is refused with a notice.

### Quest tab

Taking a quest by ID, and finding its objectives in the world.

- **Quest ID** (textbox) + **Assign Quest** (button) — asks the game for that quest through its remote. If the remote is not in the place, a notice says so instead of failing quietly.
- **Quest ESP** (toggle, default off) — highlights the QuestItems folder.
- **Show All Quest Items** (toggle, default off) — tags every item in the folder rather than only the names typed below.
- **Quest Targets** (textbox) — the item names to find, comma separated; case, spaces and symbols are ignored when matching.
- **Rescan Quest Targets** (button) — searches the folder again and reports how many targets were tagged.
- **Copy Quest Info** (button) — copies what the game shows for your quest, writing a dump file as well when file storage is available, so targets can be set from it later.
- Limits: `MAX_HIGHLIGHTS` (20) highlights and `MAX_TAGS` (200) labels at once, distances refreshed every `UPDATE_INTERVAL` (0.25 s), labels hidden past `LABEL_MAX_DISTANCE` (5000 studs), and items that stream in later are tagged as they arrive.

### Status tab

A read-only window on what the farm is doing, plus two buttons.

- **FARM STATE  --** (readout) — what the farm loop did this frame.
- **PLACE ID**, **WALKSPEED**, **WAYPOINTS:  n / m**, **FALLEN CAMELLIA**, **PLAY TIME**, **POSITION**, **DEATH**, **EXP** (readouts) — the current place, walk speed, route progress, the event currency, time on the server, position, death count and experience. The event currency line is named after the currency this event hands out and counts the inventory item of that name (`AICUI.S.TargetCurrency` in `Core/Runtime.lua`), so it is renamed when the event's currency changes.
- **Reset Stats** (button) — fires `StatsEvent` with 0 for Vitality, Agility, Luck, Strength and Defense. A stat at or above `STAT_RESET_THRESHOLD` (500) is refused with a notice: firing that many points at the game's anticheat trips it and the reset never lands, so 499 is the highest that resets.
- **Show Pinned Items** (toggle) — shows the floating Pinned Items panel, which is the only way back after its × closes it. Panel contents, open/closed state and position live in the global `PinnedItems.json`.
- **Reset Pinned Items Position** (button) — docks the panel back on the right.

### Debug tab

World-space drawing for the zones, routes and targets the farm uses. Everything here is saved per
profile. **Debug Visualizer** (default on) is the master switch — off removes the debug folder from
the workspace and nothing below draws; the toggles below it pick which overlays appear while it is
on.
- **Debug Waypoints** (default on) — waypoint markers and the route.
- **Debug Farm Zones** (default on) — farm zone circles.
- **Debug Deadzones** (default on) — deadzone circles.
- **Debug Mine Zones** (default on) — mine zone circles.
- **Debug Ore Status** (default on) — a label per ore with what Auto Mining thinks of it. Fed by Auto Mining, so it needs that feature running to update.
- **Debug Smithing Tables** (default on) — a label per smithing table with its state. Fed by Auto Smithing the same way.
- **Radius Billboard Labels** (default on) — each zone's number and radius over it.

### Utility tab

Global controls that are about the client rather than the farm loop, plus the Discord report.
Everything here is shared by every profile and PlaceId, so none of it is part of a profile export.

- **Auto Start Game** (off, global) — clicks through the title screen into the game. Shared by every profile: it runs before a profile has been loaded.
- **FPS Boost** (off, global) — turns off shadows, post effects, particles, lights and water waves for frames. Shared by every profile; it is about the machine, not the farm.

#### Webhook

One place for the Discord webhook and what goes into its report. Paste the URL once; it is kept
in `AutoFarmProfiles/Global.json`, so every profile and place reports to the same hook.

- **Discord Logging** (on, global) — the master switch, first in the section. Off means nothing
  is posted at all: no start, no end, and **Send Report** does nothing but say logging is off.
  The URL and the rest of the settings are kept, so turning it back on needs no re-typing.
- **Webhook URL** — the Discord webhook URL (`https://discord.com/api/webhooks/...`). Blank sends nothing.
- **Ping User ID** — a UserId to mention with the report, `everyone` for `@everyone`, or blank to mention nobody. A hand-typed `@name` is passed through.
- **Ping Duo User ID** — your duo's UserId, mentioned alongside yours so both accounts get the ping. Blank mentions nobody extra; the same id in both boxes is only mentioned once.
- **Duo Username** — who you are duoing with. Blank reports only your account; filled in, the Account line reads `You and Them`.
- **Report Format** — **Event Currency** or **EXP Grind**; it chooses which two numbers the report carries (see below).
- **EC Item Name** — the inventory item counted as event currency. Blank uses the currency the script already tracks for the current event (`Fallen Camellia` now).
- **Send Report** — posts the report for the current session.
- **Reset Session** — stamps a new start time and takes today's EC/Level as the starting numbers, for a new run or a new floor.
- The **SESSION STARTED** line under the buttons shows the report's start time and how long it has been going.

The report is plain message text. A **started** report says only where the run is now:

```text
# Macro Started at 03:41 PM EST
Account: YourName and DuoName
Floor: Floor Name (10299594856)
Current EC: 1204
Time: 2 Hours, 15 Minutes, 42 Seconds
```

An **ended** report (`# Macro Turned off at …`) adds the numbers the run started from, so
the two messages read as a before and after:

```text
# Macro Turned off at 05:56 PM EST
Account: YourName and DuoName
Floor: Floor Name (10299594856)
Current EC: 1204
Starting EC: 900
Time: 2 Hours, 15 Minutes, 42 Seconds
```

With **EXP Grind** picked, the two number lines become four — the level on its own,
then the progress inside that level's EXP bar as `exp/needed`. A started report has the
first pair, an ended one has both:

```text
Current Level: 250
Current EXP: 1234/2438097
Starting Level: 248
Starting EXP: 8110/2394027
```

`Needed` comes from the same EXP curve the HUD uses (`AICUI.neededExp`), so it always
matches the bar on screen. Both the level and the EXP are captured when the session
starts, so the starting line keeps the numbers it had before levelling up.

`Time` is spelled out in minutes and seconds — `23 Minutes, 10 Seconds` — with hours
added in front for a longer run: `2 Hours, 15 Minutes, 42 Seconds`.

- The start time is **US Eastern** (`EST`, or `EDT` while daylight saving is on — the clock is correct either way). Only the clock is shown — no date — so the header stays short. A report posted on the way out (see below) reads `# Macro Turned off at` instead of `# Macro Started at`, so a leave is distinguishable from a manual **Send Report** at a glance.
- **Sending does not restart the session**, so repeated reports keep the same start and starting numbers (an ended report prints them) and only the current ones move; press **Reset Session** to start a new one. Because the shape follows the header, **Send Report** reads like a started message: current numbers only.
- **The macro reports its own start and end.** A report headed `# Macro Started at` goes out when Auto Farm comes on — at the first load where the saved profile has it on, and every time the toggle is switched on — and the session clock and starting EC/level restart with it. A report headed `# Macro Turned off at` goes out when Auto Farm is switched off, and on every leave below. So a hop produces an ended report, and the next server's load produces a started one.
- **The toggle reports the moment it is clicked**, not on the next frame: the Auto Farm toggle tells the Webhook which way it went, so switching the farm off posts the ended report even though the farm loop has already stopped, and the heartbeat that follows does not post it a second time. A profile load still reports through the flag, so the same pair appears whichever way the farm was switched.
- **A started report carries only the current numbers; an ended report carries both** — the starting EC/level and the current ones — so the pair shows exactly what the run gained.
- **One departure per session**: a leave is reported once, and the client is moved or kicked once. After a script-started leave, the signals meant for departures it did not start (a teleport, the player being removed, `BindToClose`) stay silent, so a kicked client cannot post the end over and over from the disconnect screen.
- **A report is posted every time the script leaves a server**, before the client moves: Auto Block after the block goes through, **Leave Instead Of Block** closing the game, the server-age hop, the Danger Group hop, **Rejoin** / **Server Hop** / **Join Job ID**, and Follower Guard's kick. The post is synchronous, so the teleport or kick cannot cut the request off. **A departure always posts**, even if a report went out a moment ago: the client is about to disappear, and a missed end cannot be retried — that is what made the end vanish when a kick followed a started report within a few seconds. The leave itself still happens once, so the extra guarantee cannot produce a repeat. Plain ends (Auto Farm switched off, a manual leave) keep the 8-second window, so the same event seen twice posts once.
- **A leave caused by a player names them**, on the line `Left because of: @name (UserId)` under the floor: the intruder Auto Block blocked or left for, the whitelisted player you had blocked, the Danger Group player, and Follower Guard's follower. A leave with nobody behind it — the server-age hop, a Rejoin or Server Hop, a hand-leave, Auto Farm switched off — has no such line at all, rather than an empty one. The same follower or intruder is named in the kick text, so the closed client says who it was on the way out.
- A teleport the script did not start — a door in the game, the game's own party teleport, another script — is caught from `Player.OnTeleport` and reports too. A manual leave through Roblox's own menu is caught by three best-effort signals: `Players.PlayerRemoving` for you, the local player being destroyed (`AncestryChanged` with no parent), and `game:BindToClose` where the executor allows it on the client. None of them is guaranteed — the client can be gone before the request finishes — so an occasional missing end report on a hand-leave is expected; the script's own leaves always report.
- With **Webhook URL** blank (or **Discord Logging** off), nothing is posted and no notice is shown.
- The floor name is looked up from the PlaceId; until that answers (or if it cannot), the report uses the server's own name.
- Some executors blacklist `HttpService:RequestAsync` (the `disabled/blacklisted` notice). The report goes through the executor's own request function when it has one — `syn.request`, `http.request`, `http_request`, `request` — and only falls back to `HttpService` when none does, so it sends either way. If every route fails, the notification carries the reason.

### Configuration panel

Opened from the **CONFIGURATION** button at the bottom of the window (`SYSTEM CONFIGURATION  //  THEME / WINDOW / TYPOGRAPHY`). It holds the theme swatches (click a swatch for the colour picker; hex/RGB), the window size limits, the text scale and the font. All three of those live in `AutoFarmProfiles/Global.json` and are **shared by every profile and PlaceId**, so they are not part of a profile export.

- **Font** (dropdown) — every Roblox font, each option previewed in its own font; picking one retargets the whole UI at once and is saved immediately. Fonts that fail to load are hidden and warned about in the console.
- **TEXT SCALE** (number field, 0.8–2.2) — resizes text across the whole window and floating windows. Each text remembers its base size, so scaling back and forth does not drift.
- **MIN WIDTH / MIN HEIGHT / MAX WIDTH / MAX HEIGHT** (number fields) — the resize limits for the main window.
- **APPLY** (button) — applies the theme colours typed or picked above; colours identical to the built-in theme are not saved.
- **RESET DEFAULT** (button) — restores the default theme, window size, text scale and font, and clears the saved copies.
- **RETURN** (button) — closes the panel without further changes.

## Troubleshooting

Start from the `FARM STATE` line on the Status tab: it is written by the farm loop
itself, so it is the difference between "the loop is running and picked no target"
and "the loop is not running at all".

### The silent failure mode

`Feature:Update` returns without any message at three places, before it writes a
FARM STATE line at all: no `InputBindableFunction`, no `Sword`/`MainWeld` in the
character, or no `PlayerStats`. A fourth, quieter one is the deadzone escape
(`HandleDeadzoneEscape`), which returns on the frames it has something to do.

The symptom is always the same: the toggle is on, nothing moves, and the console is
clean. If `FARM STATE` is not updating at all:

1. Check the sword is **worn** (a `Sword` tool inside your character, with a
   `MainWeld` child). A sword in the Backpack does not count and the script never
   takes it out for you. `(in-game check)` the name — the loop looks for `Sword`
   exactly.
2. Check you are not standing in a deadzone (**Debug Deadzones** draws them) and
   that `PlayerStats` exists under your Player.
3. Confirm the script actually started: the boot window reaching 100% and the tabs
   appearing means `Init.lua` got that far.

### Nothing to fight

| Symptom | Cause | Fix |
|---|---|---|
| `IDLE (NO TARGET)` with mobs in sight | Enemy Priority is empty, or does not name those mobs | **Add Mob Target** while standing near them, or Mob Dictionary → **ADD TO ENEMY PRIORITY**. Mobs the game has not loaded yet cannot be picked. |
| Picked a mob and Enemy Priority stayed empty | No profile is loaded, so the picker's add is refused silently | Create or load a profile, then pick again. This is why the dropdown can appear to do nothing while the Mob Dictionary's button reports the same problem out loud. |
| `IDLE (NO TARGET)` with a target list filled in | The mobs are outside every farm zone, or inside a deadzone | Farm zones constrain where things may be fought. Delete them, or move the zone, or turn on **Ignore Farm Zone**. |
| `PATROL` on and off, no fighting | Auto Patrol is looking for targets on its own; the list is still empty | Add targets, as above. |
| `CHASE …` but it never lands a hit | Engagement range: it closes, then stops to fight | Read the step after `//` in the FARM STATE line; **Close Combat Range** (Safe Combat off) and **Safe Enemy Range** (Safe Combat on) decide how close it stands. |
| One mob targeted forever while others are ignored | Target locking is deliberately sticky | Reorder **Enemy Priority**, or set **Target Type** to `Highest HP` / `Lowest HP`. |

### It walks a route forever

While the waypoint route is unfinished, the loop only walks — by design there is no
fighting, mining or crafting until `WAYPOINTS` reaches the end. So:

- `ROUTE  #n` that never advances means that waypoint cannot be reached. Raise
  **Waypoint Reach Distance**, delete the offending waypoint (**Clear Waypoints** and
  add fresh ones), or turn on **Auto Find** to skip the route entirely.
- `WAYPOINT WAIT` is that row's `Wait (s)` doing its job — set it back to 0.
- A route copied from a place preset will not fit a different place: presets exist
  only for two PlaceIds, and anything you record is per profile **and** per place.

### It jumps constantly while fighting

The character hops over whatever the jump probe reads as a low ledge — and a mob
standing beside or in front of it reads exactly like one.

- **Jump While Fighting** on the Farming tab is the switch: off, nothing that moves
the character towards, away from or around a target leaves the ground. The waypoint
route, Waypoint Loop, patrol, mining and smithing keep their own jumps, which is why
the route still clears a parkour gap with the toggle off.
- A mob or a player in the probe's way is no longer read as terrain at all, whatever
folder the game keeps its mobs in, so a crowd is walked through instead of hopped
over.
- Turning it on restores the old behaviour, hops included.

### Mining and crafting

- **Auto Mining** needs all of: Auto Farm on, the waypoint route finished, a mine
  zone configured (it warns "Add a mine zone first; ores outside one are never
  mined"), and at least one ore in **Ore Priority**. Its own STATUS line names which
  of these is missing.
- **Auto Smithing** runs with Auto Farm off too, but needs a table within reach and
  a recipe it is allowed to craft. **Recipe Status** says exactly which rule stopped
  it: `LOCKED SKILL`, `NEED <material>`, `DONE`, `PAUSED AFTER FAILURES`.
- Both fight off anything that comes close, so a build-up of mobs can look like
  mining or crafting "hanging"; the STATUS line will say `DEFENDING` while that
  happens.

### Server behaviour that looks like a bug

- Being hopped or blocked shortly after joining is Auto Block working. Put the
  players on the **Block Whitelist** (**Add Everyone Here** is the quick way), or
  raise **Block Delay (s)**.
- With a Party Leader set, the **Block Delay** has no effect: Party handles
  intruders instead.
- **Leave On Danger Group** is global and off by default; if it is on, any player in
  a group on **Danger Groups** makes the script leave.

### Profiles

- `CREATE / LOAD PROFILE FIRST` — add or edit a waypoint, zone, ore or recipe only
  after creating or loading a profile.
- `DEFAULT PLACE_CONFIG IS READ-ONLY` — the built-in preset cannot be edited; make a
  profile and the edits go there.
- `IMPORT FAILED: PlaceId mismatch` — an exported profile only imports into the same
  place it came from.
- Font, Text Scale, Theme, **Block Whitelist**, **Whitelist Skips Safety**,
  **Leave On Danger Group**, **Danger Groups**, **Danger Whitelist**, **Auto Start
  Game**, **FPS Boost** and the Pinned Items panel are stored globally
  (`AutoFarmProfiles/Global.json`), shared by every profile and place, and are not
  part of a profile export.

### Executor-only

**Auto Confirm Block** (presses Roblox's block dialog, reads CoreGui) and the
**Server Hop** / **Open Server Browser** buttons (they read Roblox's public server
list over `game:HttpGet`) cannot work in Studio, and **Auto Start Game** depends on
clicking the game's own title UI. Everything else in the window is plain Roblox API.

### What this guide cannot prove

The object and remote names the script expects — the `Sword` tool, `MainWeld`,
`PlayerStats`, `InputBindableFunction`, `workspace.Mobs[*].Config.Entity`,
`UseConsumable`, `TeleportEvent`, `ChatEvent`, `StatsEvent`, the `Interactions` and
`Waypoints` folders — come from the game, and none of them can be checked from the
source alone. Where a name does not match, the feature is usually silent rather than
erroring, which is why `FARM STATE` and the per-tab STATUS lines are worth reading
before assuming something is broken.
