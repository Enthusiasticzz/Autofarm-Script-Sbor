# Quick start: making Auto Farm kill mobs

Auto Farm does **not** hunt on its own. It attacks a guest list, and that list starts empty on
every place except the couple that ship a built-in preset. An empty list is silent — no error,
no warning, no movement — which is why it looks broken.

Four things, in this order, and it fights:

## 1. Create a profile

Open **Profile Settings**, type a name in **Profile Name**, press **Create New Profile**.

> **Add Mob Target does nothing at all until a profile is loaded.** Picking a mob from the
> dropdown with no profile loaded is silently ignored: the list stays empty, no message
> appears. If you pick a mob and Enemy Priority stays empty, this is why.
>
> The Mob Dictionary's **ADD TO ENEMY PRIORITY** button has the same rule, but that one does
> warn you (`Load or create a profile first`). If the dictionary warns and the dropdown does
> not, you are seeing exactly this.

Profiles are stored **per floor/place**. A profile you made in one place does not exist in another,
so if you changed floors you have to create one there too.

## 2. Add the mobs you want it to attack

Go to the **Farming** tab → **Targeting** → **Add Mob Target**, and pick every mob you want
it to fight. Each pick is added to **Enemy Priority**.

Two rules for the picker:

- It lists the mobs that are **loaded right now**, so stand in the spawn area before opening it.
- If the list is empty or does not have the mob you want, walk closer to it and press
  **Refresh Detected Targets**.

The Mob Dictionary (**Open Mob Dictionary**) does the same thing for anything you look up,
with its **ADD TO ENEMY PRIORITY** button.

You do not need a farm zone, waypoints, mining or crafting for this. Enemy Priority alone is
enough for it to start fighting.

## 3. Leave Auto Farm on and read FARM STATE

**Auto Farm** is already on by default. Leave it on. Go to the **Status** tab and watch the
`FARM STATE` line — that one line tells you whether it is working and, if not, why.

| FARM STATE | What it means |
|---|---|
| `AUTO FARM OFF` | The toggle is off (or the button and the loop disagree — toggle off and on). |
| `IDLE (NO TARGET)` | It found nothing it is allowed to attack. The list is wrong or empty, or the mobs are outside your farm zones. |
| `CHASE  Goblin  12  //  ...` | Working. The name and distance, then the step after `//` explains how it is closing in. |
| `ROUTE  #1`, `WAYPOINT LOOP` | Walking your route instead of fighting. |
| `RETREAT (Health)` | Low HP, backing off. **Retreat At HP%** controls this. |
| `AUTO BLOCK  @name` | A player it does not recognise is in the server. |

**If FARM STATE never changes at all** — it still says `FARM STATE  --` — then it is bailing
out before the loop can even report anything. There is no error for this by design. It means
one of: the script never loaded (look for `LOAD FAILED` on the loading window), or the loop is
returning before its first report — no sword on your character (step 1), or the game has not
given you a `PlayerStats` folder yet. Rejoin if it stays frozen.

A healthy start looks like: it walks the route (if you have one), then `CHASE …`, then
`IDLE (NO TARGET)` whenever everything around you is dead. That idle is normal — it is waiting
for respawns.

## You can ignore almost every other setting

The tabs are full of options because they exist, not because you need them. The defaults are
sane; leave them alone until something specific bothers you. The only ones worth touching at
the start:

- **Safe Combat** (on) — fights from outside the mob's weapon reach. Turn it off if you want
  it to fight up close.
- **Auto Find** (off) — ignores your waypoint route and goes straight for targets. Turn this on
  if you do not want it walking anywhere.
- **Retreat At HP%** (40) — how hurt it gets before running away.

Optional additions, once fighting works:

- **Add Farm Zone Here** (Profile Settings) — keeps it inside a circle. Only useful once you
  have targets working; **with no farm zone nothing is restricted**.
- **Add Waypoint Here** (Profile Settings) — a route to walk before it starts farming.
- **Add Deadzone Here** (Profile Settings) — spots it never fights in and never walks through.

## The trap that catches most people

With a farm zone added, mobs **outside** it are not targetable: the status goes back to
`IDLE (NO TARGET)` even with a full Enemy Priority. If that happens, delete the zones
(**Clear Farm Zones**), move the zone to where you actually fight, or turn on
**Ignore Farm Zone**.

For every control, its real default and what each status line means, see
[USAGE.md](USAGE.md).
