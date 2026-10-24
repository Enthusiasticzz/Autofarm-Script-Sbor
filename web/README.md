# Web

The Gilded Archive site: a crosstrading market, an item and equipment database,
the script guide with a gains wall, and a staff panel.

No framework and no build step. Three files do the work:

| File | What it holds |
| --- | --- |
| `index.html` | Page structure, one section per route |
| `styles.css` | The whole visual system — theme tokens are at the top |
| `data.js` | Schema and seed records |
| `app.js` | State, routing, tables, forms, staff panel |

Open `index.html` directly, or serve the folder while working:

```sh
py -m http.server 8138 --directory web
```

## Routes

| Route | Page |
| --- | --- |
| `#home` | Hero, global search, counts, latest trades, gains |
| `#market` | Crosstrading and in-game exchange listings, with posting |
| `#database/items` | Items: EXP, HP, STR, VIT, DEF, AGI, LUCK, resale |
| `#database/equipment` | Equipment: attack, crit, crit damage, defence, effect, source, resale, image |
| `#database/overlays` | Cosmetics |
| `#item/<id>` · `#gear/<id>` · `#overlay/<id>` | A record, opened directly — every entry is linkable |
| `#script` | Loadstring, first run, per-floor guide, gains wall |
| `#signup` | Account mock-up (see below) |
| `#staff` | Gated editor |

## Data

Records live in `data.js` under `GA.SEED`, shaped by `GA.SCHEMA`. Adding a
record by hand means adding an object with an `id` you choose; the staff panel
also creates them, and the latest state always wins.

The site copies `SEED` into `localStorage` (`gilded.v2`) on first load. It
re-seeds the reference records whenever `GA.SEED` changes, while keeping
listings and gains people posted, so editing `data.js` is enough to see new rows
after a refresh.

Drops mirror the game:

```js
drops: [{ mob: 'Goblin', oneIn: 50, rolls: 2 }]
```

`oneIn` is the "1 in N" roll and `rolls` is how many times it is rolled per
kill. The shown chance is `1 - (1 - 1/oneIn)^rolls` and the rarity tier is
derived from `oneIn`, so the legend and the drop table cannot disagree.

The seeded records are placeholders, clearly not real game values. Replace them
in `data.js` with the real database.

## Script link

The loadstring and the Download button both read `GA.SCRIPT.raw` at the top of
`data.js`. It currently points at `main/Init.lua`, which is what the repository
serves today; change it to `main/script/Init.lua` once the folder move is pushed.

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
drop table), equipment, overlays, floors, listings, gains and quotes. Reset
restores the sample records.

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
