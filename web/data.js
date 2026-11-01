/* =====================================================================
   Gilded Archive — schema and site data
   ---------------------------------------------------------------------
   The database records (items, equipment, overlays) are generated from
   the game's own dump into `database.js` — see tools/build-database.py.
   Edit those there, or press DUMP DATABASE in the Asset Explorer and run
   the script again.

   This file holds everything else (floors, sample listings, gains,
   quotes) and the shapes the site and the staff panel use. Drop odds use
   the game's own shape: `oneIn` is the "1 in N" rolled per kill, `rolls`
   is how many times the table rolls it; the site computes the chance.

   Rarity is not a stat in the game: it is worked out from a record's rarest
   known drop rate. Records the game never revealed a drop for stay blank, so
   they can be set by hand here.
   ===================================================================== */
(function () {
  'use strict';

  var DB = window.GA_DB || { meta: {}, mobs: [], items: [], equipment: [], overlays: [] };

  var RARITIES = ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic'];
  var SOURCES = ['Shop', 'Event', 'Smithing', 'Crafting', 'Drop', 'Gamepass', 'Badge', 'Quest', 'Unique', 'Mining', 'Fishing', 'Unknown'];
  var SLOTS = ['Weapon', 'Offhand', 'Armor', 'Headwear', 'Accessory', 'Tool'];

  // Every game type present in the dump, for the staff panel's datalist.
  var ITEM_CATEGORIES = Array.from(new Set(
    [].concat(DB.items, DB.equipment, DB.overlays).map(function (x) { return x.type; }).filter(Boolean)
  )).sort();

  var FIELDS = {
    name: { k: 'name', label: 'Name', type: 'text', required: true },
    type: { k: 'type', label: 'Game type', type: 'text', list: 'itemCategories' },
    group: { k: 'group', label: 'Type', type: 'text' },
    slot: { k: 'slot', label: 'Slot', type: 'select', options: SLOTS },
    // The first option is blank: many records have no source in the game, and
    // a select would otherwise give them its first value on save.
    source: { k: 'source', label: 'Source', type: 'select', options: [''].concat(SOURCES) },
    // Blank first: a record without a known drop rate has no rarity, and it
    // can be picked by hand here.
    rarity: { k: 'rarity', label: 'Rarity', type: 'select', options: [''].concat(RARITIES) },
    level: { k: 'level', label: 'Level', type: 'number' },
    skill: { k: 'skill', label: 'Skill', type: 'number' },
    dmg: { k: 'dmg', label: 'Damage', type: 'number' },
    def: { k: 'def', label: 'Defense', type: 'number' },
    dex: { k: 'dex', label: 'Dexterity', type: 'number' },
    worth: { k: 'worth', label: 'Worth', type: 'number' },
    sell: { k: 'sell', label: 'Shop price', type: 'number' },
    sellAgility: { k: 'sellAgility', label: 'Shop price (Agility)', type: 'number' },
    desc: { k: 'desc', label: 'Description', type: 'textarea' },
    drops: { k: 'drops', label: 'Drops', type: 'drops' }
  };

  var SCHEMA = {
    items: {
      label: 'Item',
      plural: 'Items',
      fields: ['name', 'type', 'source', 'rarity', 'level', 'worth', 'sell', 'sellAgility', 'desc', 'drops'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'type', 'level', 'worth', 'sell']
    },
    equipment: {
      label: 'Equipment',
      plural: 'Equipment',
      fields: ['name', 'type', 'slot', 'source', 'rarity', 'level', 'skill', 'dmg', 'def', 'dex', 'worth', 'sell', 'sellAgility', 'desc', 'drops'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'slot', 'type', 'level', 'worth']
    },
    overlays: {
      label: 'Overlay',
      plural: 'Overlays',
      fields: ['name', 'group', 'type', 'source', 'rarity', 'worth', 'sell', 'desc'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'group', 'worth', 'source']
    },
    floors: {
      label: 'Floor',
      plural: 'Floors',
      fields: [
        { k: 'name', label: 'Floor name', type: 'text', required: true },
        { k: 'place', label: 'Place ID', type: 'text' },
        { k: 'targets', label: 'Targets (comma separated)', type: 'text' },
        { k: 'route', label: 'Route', type: 'text' },
        { k: 'notes', label: 'Notes', type: 'textarea' }
      ],
      adminCols: ['name', 'place', 'targets']
    },
    listings: {
      label: 'Listing',
      plural: 'Listings',
      fields: [
        { k: 'item', label: 'Item summary', type: 'text', required: true },
        { k: 'mode', label: 'Trade type', type: 'select', options: ['Crosstrading', 'Exchange'] },
        { k: 'side', label: 'Side', type: 'select', options: ['Selling', 'Buying'] },
        { k: 'qty', label: 'Quantity', type: 'number' },
        { k: 'price', label: 'Price (crosstrading: US cents in total; exchange: each)', type: 'number' },
        { k: 'user', label: 'Trader (exchange)', type: 'text' },
        { k: 'sellerUser', label: 'Seller username (crosstrading, private)', type: 'text' },
        { k: 'note', label: 'Note', type: 'text' },
        { k: 'sold', label: 'Sold (1 = yes)', type: 'number' }
      ],
      adminCols: ['item', 'mode', 'price', 'user', 'sellerUser']
    },
    orders: {
      label: 'Escrow order',
      plural: 'Escrow',
      fields: [
        { k: 'ref', label: 'Order reference', type: 'text', required: true },
        { k: 'stage', label: 'Stage', type: 'select', options: ['Waiting', 'Released', 'Cancelled'] },
        { k: 'handler', label: 'Handled by (name shown in the chat)', type: 'text' },
        { k: 'itemsHeld', label: 'Items received by escrow (1 = yes)', type: 'number' },
        { k: 'payHeld', label: 'Payment received by escrow (1 = yes)', type: 'number' },
        { k: 'sellerUser', label: 'Seller username', type: 'text' },
        { k: 'buyerUser', label: 'Buyer username', type: 'text' },
        { k: 'staffNote', label: 'Staff note', type: 'textarea' }
      ],
      adminCols: ['ref', 'stage', 'itemsHeld', 'payHeld', 'sellerUser', 'buyerUser']
    },
    gains: {
      label: 'Gain',
      plural: 'Gains',
      fields: [
        { k: 'lvl', label: 'Levels gained', type: 'number' },
        { k: 'ec', label: 'EC gained', type: 'number' },
        { k: 'floor', label: 'Floor', type: 'text' },
        { k: 'message', label: 'Message', type: 'text' }
      ],
      adminCols: ['lvl', 'ec', 'floor', 'message']
    },
    quotes: {
      label: 'Quote',
      plural: 'Quotes',
      fields: [{ k: 'text', label: 'Quote', type: 'text', required: true }],
      adminCols: ['text']
    }
  };

  var now = Date.now();
  var mins = function (m) { return new Date(now - m * 60000).toISOString(); };

  var SEED = {
    items: DB.items,
    equipment: DB.equipment,
    overlays: DB.overlays,

    floors: [
      {
        id: 'floor-16', name: 'Floor 16', place: '11987539001',
        targets: 'Goblin, Leader Goblin',
        route: 'Built-in route. The script walks its own preset waypoints and holds each one for respawns.',
        notes: 'This floor ships with a target preset, so Enemy Priority is already filled once a profile exists. The leader takes longer to drop — leave it in the list.'
      },
      {
        id: 'event-floor', name: 'Event Floor', place: '10299594856',
        targets: 'Karkinos the Visceral, Water Style Disciple, Drake the North Sea Commander, Marina the South Sea Commander',
        route: 'Built-in route across the island. Reach distance stays at 5 so it does not pull the whole beach.',
        notes: 'Auto Block is off here by default. The four bosses are already ordered in the priority list, strongest first.'
      },
      {
        id: 'other-floors', name: 'Other floors', place: '—',
        targets: 'Whatever is spawning where you stand',
        route: 'No preset. Add waypoints yourself, or turn Auto Find on to skip the route entirely.',
        notes: 'With no preset the list starts empty, which is the silent failure. Stand in the spawn area, refresh detected targets, then add each mob.'
      }
    ],

    // Crosstrading listings are bundles for one total price in US cents (1200 =
    // $12.00). `sellerUser` and
    // `sellerCode` are private: the public pages never show them, and only the
    // escrow side (the staff panel) reads the username.
    listings: [
      { id: 'l-1', mode: 'Crosstrading', side: 'Selling', code: 'K7M2', items: [{ name: 'Bane Wand', qty: 1 }], item: 'Bane Wand', qty: 1, price: 1200, currency: 'USD', note: '', sellerUser: 'Kaito_X', sellerCode: 'S-DEMO-0001', createdAt: mins(2) },
      { id: 'l-2', mode: 'Crosstrading', side: 'Selling', code: 'R4TN', items: [{ name: 'Antidote Crystal', qty: 5 }], item: 'Antidote Crystal ×5', qty: 5, price: 300, currency: 'USD', note: '', sellerUser: 'AsunaFan07', sellerCode: 'S-DEMO-0002', createdAt: mins(9) },
      { id: 'l-3', itemId: 'ironingot', item: 'Iron Ingot', mode: 'Exchange', side: 'Selling', qty: 40, price: 9, user: 'Forge_Lord', note: 'Bulk discount', createdAt: mins(31), sold: false },
      { id: 'l-4', mode: 'Crosstrading', side: 'Selling', code: 'W9QD', items: [{ name: 'Demon Dark Clover', qty: 1 }], item: 'Demon Dark Clover', qty: 1, price: 850, currency: 'USD', note: '', sellerUser: 'NightOwl_9', sellerCode: 'S-DEMO-0003', createdAt: mins(60) },
      { id: 'l-5', itemId: 'candycorn', item: 'Candy Corn', mode: 'Exchange', side: 'Buying', qty: 200, price: 3, user: 'Mira_K', note: '', createdAt: mins(120), sold: false },
      { id: 'l-6', mode: 'Crosstrading', side: 'Selling', code: 'F3HX', items: [{ name: 'Apple', qty: 20 }, { name: 'Candy', qty: 10 }], item: 'Apple ×20, Candy ×10', qty: 30, price: 200, currency: 'USD', note: 'Event leftovers', sellerUser: 'Mira_K', sellerCode: 'S-DEMO-0004', createdAt: mins(180) }
    ],

    // Escrow orders: one per purchase. See the Crosstrading section of the README.
    orders: [],

    gains: [
      { id: 'g-1', lvl: 14, ec: 52000, floor: 'Floor 16', message: 'Left it on overnight.', createdAt: mins(60) },
      { id: 'g-2', lvl: 9, ec: 31000, floor: 'Floor 16', message: '', createdAt: mins(180) },
      { id: 'g-3', lvl: 22, ec: 96000, floor: 'Event Floor', message: 'Boss preset carried it.', createdAt: mins(300) }
    ],

    quotes: [
      { id: 'q-1', text: 'Every item, every trade.' },
      { id: 'q-2', text: 'Climb higher. Trade smarter.' },
      { id: 'q-3', text: 'Gold remembers everything.' },
      { id: 'q-4', text: 'Know the floor before you climb it.' }
    ],

    settings: { quoteHours: 24 }
  };

  window.GA = {
    VERSION: 3,
    // The one place the loadstring points. The script lives in the repo's
    // script/ folder, so the entry point is .../main/script/Init.lua.
    SCRIPT: {
      raw: 'https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/script/Init.lua',
      repo: 'https://github.com/Enthusiasticzz/Autofarm-Script-Sbor'
    },
    DB_META: DB.meta || {},
    RARITIES: RARITIES,
    SOURCES: SOURCES,
    SLOTS: SLOTS,
    ITEM_CATEGORIES: ITEM_CATEGORIES,
    MOBS: (DB.mobs || []).slice(),
    SCHEMA: SCHEMA,
    SEED: SEED,
    // The middleman account both sides trade with. Set `account` to the real
    // in-game username that staff operate; it is shown to buyers and sellers.
    // `feePct` is the site's cut of every crosstrade, taken from the seller's side
    // and shown to both people. It is a placeholder: set the real percentage here.
    ESCROW: { account: 'GildedEscrow', holdMinutes: 60, feePct: 10 },
    PASS: 'gilded-staff'
  };
})();
