# Web

The Gilded Archive site: a crosstrading market, an item and equipment database,
the script guide with a gains wall, and a staff panel.

No framework and no build step. Three files do the work:

| File | What it holds |
| --- | --- |
| `index.html` | Page structure, one section per route |
| `styles.css` | The whole visual system — theme tokens are at the top |
| `database.js` | The game's records, generated — do not edit by hand |
| `data.js` | Schema, floors, sample listings, gains, quotes |
| `app.js` | State, routing, tables, forms, staff panel |
| `DatabaseDump.json` | The raw in-game dump the records are built from |

Open `index.html` directly, or serve the folder while working:

```sh
py -m http.server 8138 --directory web
```

## Routes

| Route | Page |
| --- | --- |
| `#home` | Hero, global search, counts, latest trades, gains |
| `#market` | Crosstrading and in-game exchange listings, with posting |
| `#database/items` | Materials and consumables: type, rarity, worth, shop price, source |
| `#database/equipment` | Weapons, armor, headwear, accessories, offhands and tools: slot, rarity, level, damage, defence, dexterity, worth, source |
| `#database/overlays` | 3D armor, outfit/headwear/accessory/weapon overlays and facewear |
| `#item/<id>` · `#gear/<id>` · `#overlay/<id>` | A record, opened directly — every entry is linkable |
| `#script` | Loadstring, first run, per-floor guide, gains wall |
| `#signup` | Account mock-up (see below) |
| `#staff` | Gated editor |

## Data

Every record comes from the game itself. In game, open the **Asset Explorer**
and press **DUMP DATABASE**; the script writes `AutoFarmProfiles/DatabaseDump.json`
in the executor's folder. Put that file here as `DatabaseDump.json` and rebuild:

```sh
py tools/build-database.py
```

That writes `database.js` (`window.GA_DB`), which the page loads before
`data.js`. The two are split so a re-dump never touches the hand-written parts —
floors, sample listings, gains, quotes. `tools/build-database.py` documents the
mapping; in short:

- **items** — game type `Material` or `Consumable`
- **equipment** — what carries stats: weapons (DMG), `Outfit` armor (DEF/DEX),
  `UpperHeadwear` headwear (DEF/DEX), `LowerHeadwear` accessories — capes,
  scarves, necklaces (DEF/DEX) — shields (DEF) and fishing rods. The slot comes
  from the type, so headwear and accessories are separate slots.
- **overlays** — cosmetics with no stats: `Armor3D` (a 3D shell worn over an
  outfit), facewear and every `*Overlay` type. Overlays carry a friendlier
  `group` (“3D armor”, “Outfit overlay”, “Accessory overlay”, …) for the tab's
  type filter.

Guild-locked gear and cosmetics are dropped from the build (`EXCLUDED_SOURCES`
in the script): they cannot be traded and only clutter the lists.

The record shape is `id, name, type, kind, slot, group, level, skill, dmg, def,
dex, worth, sell, sellAgility, rarity, source, obtained, flags, eventCurrency,
desc, effect, recipe, drops`.

The game has no rarity stat. Every record gets one from the drop rate it does
give: the tier of the record's rarest known 1-in-N drop, shown in the table, the
filter row and the detail sheet. Anything the game never revealed a drop for
stays blank (“—”), and the staff panel's **Rarity** field sets it by hand. Items
with drops (31 of 408) therefore get Uncommon or Rare from the real rates.

The site copies the seed into `localStorage` (`gilded.v3`) on first load. It
re-seeds the records whenever the seed changes, while keeping listings and gains
people posted. Tables paint **50 rows a page** with a pager under each table, so
only a page is ever in the DOM; search, filters and sorting still run over every
row.

Drops mirror the game:

```js
drops: [{ mob: 'Goblin', oneIn: 50, rolls: 2 }]
```

`oneIn` is the "1 in N" roll and `rolls` is how many times it is rolled per
kill. The shown chance is `1 - (1 - 1/oneIn)^rolls` and the tier is derived from
`oneIn`, so the tier chip and the percentage always agree. Drops only exist for
mobs the script has seen in a server, which is why most items say none are
known.

## Script link

The loadstring and the Download button both read `GA.SCRIPT.raw` at the top of
`data.js`. It points at `main/script/Init.lua` — the script lives in the
repository's `script/` folder, so `main/Init.lua` is a 404. If the entry point
ever moves again, this is the one line to change.

## Market and gains

Both are anonymous and need no account: a listing is an item, a side, a
quantity, a price and an in-game username. Everything is stored in this browser
until there is a server, and the pages say so. Listings can be marked sold and
reopened.

## Staff

Passcode: **`gilded-staff`**, kept in `sessionStorage` for the tab. It is in
`data.js`, so it stops a visitor, not a developer — a real deployment needs
server-side auth.

The panel edits every collection: add, edit and remove items (including their
drop table), equipment, overlays, floors, listings, gains and quotes. Filter box
and pager included, since the database is thousands of rows. **Rarity** is a
select on equipment and overlays, blank when unknown. Reset restores the records
shipped with the site.

## Accounts

Login and sign-up are a design mock-up. They say so on screen and never send
anything; posting works signed out by design.

## Extending

- **New page:** add a `<section class="view" id="...">`, a nav link, and handle
  the id in `route()`.
- **New record type:** add it to `GA.SCHEMA` (fields + admin columns) and to
  `SEED`. The staff form, table and tabs are generated from the schema.
- **New page section:** reuse `.panel`, `.tw`, `.chips`, `.phead`.
- **Re-theme:** edit the tokens at the top of `styles.css`; nothing else hard-codes
  the palette.
