# Plan: Auto Equip (wear the best gear you can actually use)

Status: **PLAN ONLY** — no feature code yet. One open question at the bottom.

## What the probe settled

One card per owned item under
`GameGui["MenuGui-NEW"].FrontRight.Menu.Frames.Equipment.FrameB.List`, named
exactly after the item:

| Field | Type | Example |
|---|---|---|
| item name | the card's own name | `Sanctum Edge Oathbreaker` |
| `Type` | **StringValue** (`.Value`) | `One-Handed`, `Rapier`, `Dagger`, `Two-Handed`, `Melee`, `Shield`, `Outfit`, `UpperHeadwear`, `LowerHeadwear`, `Facewear`, `Armor3D`, each `…Overlay` twin |
| `Entry.Requirement` | TextLabel | `Skill` or `Level` |
| `Entry.RequiredAmount` | TextLabel | `435` |
| `Entry.Amount` | TextLabel | `1`, `2`, `999` — **quantity**, next to `Entry.QuantityChar` = `x` |
| `isEquipped` | BoolValue | `true` on 11 cards |
| `Buttons.E` / `Buttons.E2` | ImageButton, `Slot` = `1` / `2` | equip slot 1 / 2 |

Also: 603 children, ~601 cards; strip the `Base` template (its `999` / `9999` /
empty `Type` would otherwise look like the best item in the game); the page must
be **shown** for cards to exist; the menu's open button is
`PlayerGui.DeviceGui.ConsolePC.MenuButton` (mobile `DeviceGui.Mobile.MobileMenuButton`);
the tab is `…Menu.MidFrames.Player.Equipment`; `Buttons.De`, `Dr`, `I` and the
`[Equip] …` gamepass buttons are never pressed.

## The power numbers (not on the card)

`Entry.Amount` is a stack count, so damage comes from the game's own assets —
already read by `Features/AssetDictionary.lua` (`POWER_KEYS = { "DMG", "DEF",
"DEX" }`, from `CoreCommons.getAssets`). Your worn weapons measure 2690 / 2648 /
2606 in exactly the order you'd rank them.

**Capes, cloaks, mantles, amulets and pendants are all `LowerHeadwear`** — the
same slot as `Crimson Coil Mk III` — so they are covered by the lower-headwear
checkbox, not a separate one. There is no `Necklace` type in the game at all
(`PlayerStats.Necklace` is never populated), so the plan drops that checkbox
rather than shipping one that can never do anything.

## Two builds: Defence and Dexterity

This is the part you asked for, and the data says the two builds really do pick
different items — the stats are not spread evenly:

| Slot type | items with DEF | items with DEX |
|---|---|---|
| `Outfit` | 195 of 197 | 185 |
| `UpperHeadwear` | **11 of 71** | 62 |
| `LowerHeadwear` | **9 of 55** | 45 |
| `Shield` | 74 of 74 | **0** |

So a helmet can be a DEF helmet or a DEX helmet and they are different cards
(`Kringlewrath Sanctified Helm`: DEF 37, DEX 592), a cape is almost always a DEX
item (`Frostveil Echo Mantle` DEX 671, `Two-Headed Cape` DEX 438), and a shield
is always DEF (`Sky Shield` DEF 112.2, no DEX anywhere).

- **`Armour Build` dropdown** (new control, saved as `EQUIP_ARMOUR_BUILD`):
  **Dexterity** (default) or **Defence**. It applies to Outfit, Upper headwear,
  Lower headwear and Shield.
- **Rule per slot:** sort by the chosen stat, highest first; a card with no value
  for it can never beat one that has. If *no* candidate in that slot has the
  chosen stat, the other stat decides. If neither exists, the slot is only
  filled when it is empty — never swapped on a tie.
- **Shield ignores the build** (DEF is all it has), and **weapons always use
  `DMG`** — the dropdown only changes armour.
- Default is **Dexterity** because DEX is the stat that actually exists across
  every armour slot (and your worn outfit is DEF 344.5 / DEX 1953). Flip it in
  one click if your DEF set is the better one.

## Decisions

| Question | Answer | Plan |
|---|---|---|
| "Best" | damage/power stat | weapons `DMG`; armour per the build dropdown, `DEX`/`DEF` with the other as fallback |
| Slots | a checklist | Eight checkboxes, each saved: **Weapon**, **Dual**, **Shield**, **Outfit**, **Upper headwear**, **Lower headwear** (capes, mantles, amulets), **Facewear**, **3D armour** (`Armor3D`). `…Overlay` types never eligible |
| When | only on **Equip Now** | one press = one pass; no loop, timer or respawn scan |
| Menu | needs to be open | open with `MenuButton`, press the Equipment tab, wait ≤ 2 s for cards, equip, then close it again if we opened it |
| Worn item | `PlayerStats` | `isEquipped` on the card skips and verifies; `PlayerStats` cross-checks |

## The pass, exactly

1. **Equip Now** → one pass at a time; a second press while it runs is ignored.
   First press also reads the asset table (`READING ITEMS…`).
2. Open the menu if needed; press the Equipment tab; wait for cards. None →
   `NO CARDS` with the reason, and it stops.
3. Skip the template (`Base`, no `Entry`, empty `Type.Value`), and skip any card
   whose name is not in `PlayerStats.Inventory` (`Fists` excepted) — the panel
   should only hold owned items, and this makes sure of it.
4. Disqualify: `Type` contains `Overlay`; `isEquipped` is true; `Type` or the
   requirement unreadable; `Requirement` is neither `Level` nor `Skill`; the
   requirement is above your number (Level 1125, or the skill the `Type` names —
   `One-Handed` → 1582.6, `Rapier` → 460, `Dagger` → 83.45, `Two-Handed` → 4.3,
   `Melee` → 1.1).
5. Group by slot; keep the ticked ones.
6. Rank: weapons by `DMG`; armour by the build stat with the fallback rule
   above; then name, so the winner is stable between passes.
7. Equip: click `Buttons.E`; the dual slot uses `Buttons.E2`. Wait for
   `isEquipped` to flip, cross-check `PlayerStats`; if nothing moved, try the
   other of `E`/`E2` once, then give up on that slot. Never a loop.
8. Report one line per slot and one notice at the end; nothing is clicked when
   nothing is better.

## Where it lives

- `script/Features/AutoEquip.lua` — a feature module (no master toggle, only the
  button), depending on `Runtime`, `SaveConfig`, `GuiClick`, `AssetDictionary`.
- `ModuleConfig.START_ORDER` + `FEATURE_MODULES`; the fallback `MODULES` list in
  `Init.lua`.
- `Core/SaveConfig.lua`: setting `EQUIP_ARMOUR_BUILD` (`Options = {"Dexterity",
  "Defence"}`) plus one boolean per slot — `EQUIP_SLOT_WEAPON`,
  `EQUIP_SLOT_DUAL`, `EQUIP_SLOT_SHIELD`, `EQUIP_SLOT_OUTFIT`,
  `EQUIP_SLOT_UPPER_HEADWEAR`, `EQUIP_SLOT_LOWER_HEADWEAR`,
  `EQUIP_SLOT_FACEWEAR`, `EQUIP_SLOT_ARMOR3D`. No export keys.
- UI: new **`Gear`** tab, `Auto Equip` section: `Equip Now`, status label,
  `Armour Build` dropdown, then a `Slots` divider with the eight checkboxes,
  `Refresh List`.
- Docs: `### Gear tab` in `USAGE.md`, a `TODO.md` entry, the feature list in
  `README.md`; then rebuild the bundle (a run reads `Bundle/PartN.lua`).

## Testing

1. `luau-compile`; `tools/build-bundle.ps1`; `tests/run-bundle-check.ps1`
   (0 compile failures).
2. A stubbed-world harness (style of `tests/output/quest-harness`) with a fake
   card list and asset table, asserting:
   - the `Base` template is never equipped despite its huge numbers;
   - an `…Overlay` card is never equipped, even with the highest `DMG`;
   - `isEquipped` cards are skipped, and unowned names are skipped;
   - the higher-`DMG` weapon wins and the other is not clicked;
   - **with `Dexterity` the DEX helmet/cape wins; with `Defence` the DEF outfit
     wins** — the same card list, two different winners;
   - a card with no value for the chosen stat never beats one that has it, and
     the slot falls back to the other stat only when nothing has the chosen one;
   - a `Facewear` card only fills an empty slot and never swaps;
   - an unticked slot's cards are untouched;
   - a weapon whose `Skill` requirement exceeds its matching skill is skipped
     while the same number under another `Type` is judged against its own skill;
   - a click that does not flip `isEquipped` retries the other button once, then
     gives up; no cards ends with a message, not a hang.
3. Not provable outside the game: what `E`/`E2` mean, and whether equipping ever
   raises a confirm dialog.

## Risks

- `E`/`E2` semantics (slot 1 / slot 2) may differ per item family.
- Ranking armour across a build you did not pick is deliberately narrow: with
  `Defence` on, a purely DEX cape has no DEF and so loses to any cape that has
  one. That is what a DEF build should do, but it is worth watching the first
  time it runs.
- The first press reads every asset; `AssetDictionary:Load()` is the same work
  the Asset Browser already does on open.
- Some items carry `AlwaysEquip` / `RotatedEquip` flags — worth watching for one
  the game refuses to equip from this panel.

## Out of scope

Buying, crafting or upgrading gear; overlays; separate weapon sets; inventory
sorting.

## Open question

Every card has both `E` and `E2` (`Slot` = `1` / `2`). My plan treats `E2` as
the **dual weapon** slot and uses `E` for everything else. If those two buttons
are actually two full loadouts (a DEF set and a DEX set side by side in the
menu), say so and I will add a second toggle — "put the other build in slot 2" —
which is a small addition on top of the build dropdown. Otherwise the plan is
ready to build as written.
