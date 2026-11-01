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

## Crosstrading (escrow)

Crosstrading is anonymous. Seller and buyer never deal with each other; an
escrow account holds both sides until each has paid in.

1. **List.** A seller posts one or more items and a single total price, plus
   their in-game username. The public sees a bundle, a price and a short
   listing code, never the username. The seller is given a private
   `S-XXXX-XXXX` code to track or cancel the listing.
2. **Reserve.** A buyer gives their own username and reserves it. They get a
   `B-XXXX-XXXX` code. The listing shows as Reserved and cannot be bought twice.
3. **Deposit.** The buyer sends the price to the escrow account, and the seller
   sends the items to it. Staff confirm each deposit in the staff panel
   (**Escrow** tab: *Mark received*).
4. **Release.** Once both are in, staff press *Release*: the items go to the
   buyer's username and the payment to the seller's. The listing is sold.

**Prices and the fee.** Crosstrading is priced in US dollars and stored as whole
cents (`price: 1200` is $12.00). The site keeps `GA.ESCROW.feePct` percent of
each sale, taken from the seller's side; the buyer pays exactly the listed
price. The fee is shown on the Trading page, in the listing pop-up, in the buy
and post dialogs (the seller sees their payout as they type) and in the
tracker. An order copies its price and fee when it is reserved, so changing the
percentage later never alters a trade already under way. `10` is a placeholder:
set the real figure in `data.js`. Exchange listings and database values stay in
game currency and are not affected.

**Chat.** Once a buyer reserves, the buyer and the seller each get a private
thread with the escrow staff inside *Track a trade*; neither can read the
other's. Staff open both threads from the **Escrow** tab (*Chat* button, which
turns into *Reply needed* when someone has written last) and can set the name
people see in the *Handled by* field. Messages are kept in `localStorage`
(`gilded.chat`), so a reply written in another tab of the same browser appears
live, with an unread badge on *Track a trade*. Chats are read-only once a trade
is released, cancelled or expired.

A reservation with nothing deposited lapses after `GA.ESCROW.holdMinutes`
(default 60) and the listing reopens. Once escrow holds anything, the order
stays open until staff release or cancel it, so no deposit is stranded. Either
side can cancel on their own until something has reached escrow.

State is derived from the order's flags (`itemsHeld`, `payHeld`, `stage`), so
there is no status to keep in sync. Listings store `items: [{ name, qty }]`,
`price` (total), `code` (public) and `sellerUser` / `sellerCode` (private).
Public tables, search and the pop-up are built from `publicRow()`, which copies
only the public fields. Set the real escrow account in `GA.ESCROW.account` in
`data.js`; `GildedEscrow` is a placeholder.

**This is a front-end prototype.** Everything is stored in this browser, so the
"private" username is private only from the pages, not from someone reading
local storage, and a buyer on another device cannot see your listing. Real
anonymity needs a server that holds the usernames and codes, and a person (or
bot) operating the escrow account, plus a way to take the dollar payments;
the chat is where staff tell each person how to pay. In-game exchange listings are unchanged and
stay open: the trader's username is public and people message each other.

## Market and gains

Both need no account. Exchange listings are an item, a side, a quantity, a
price and an in-game username. Everything is stored in this browser
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
