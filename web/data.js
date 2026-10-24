/* =====================================================================
   Gilded Archive — schema and seed data
   ---------------------------------------------------------------------
   This is the only file you edit to add records by hand. The site copies
   it into localStorage on first load and reseeds whenever SEED changes,
   so saving this file is enough to see new rows.

   Drops use the game's own shape: `oneIn` is the "1 in N" rolled per
   kill and `rolls` is how many times the table rolls it. The site
   computes the displayed chance from those two numbers.
   ===================================================================== */
(function () {
  'use strict';

  var RARITIES = ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic'];
  var SOURCES = ['Starter', 'Event Shop', 'Gamepasses', 'Badges', 'Crafted', 'Drop', 'Quest'];
  var SLOTS = ['Weapon', 'Armor', 'Helmet', 'Cape'];
  var ITEM_CATEGORIES = ['Consumable', 'Material', 'Quest Item', 'Currency'];
  var MOBS = [
    'Goblin', 'Leader Goblin',
    'Karkinos the Visceral', 'Water Style Disciple',
    'Drake the North Sea Commander', 'Marina the South Sea Commander'
  ];

  var FIELDS = {
    name: { k: 'name', label: 'Name', type: 'text', required: true },
    category: { k: 'category', label: 'Category', type: 'text', list: 'itemCategories' },
    slot: { k: 'slot', label: 'Slot', type: 'select', options: SLOTS },
    rarity: { k: 'rarity', label: 'Rarity', type: 'select', options: RARITIES },
    source: { k: 'source', label: 'Source', type: 'select', options: SOURCES },
    desc: { k: 'desc', label: 'Description', type: 'textarea' },
    effect: { k: 'effect', label: 'Effect', type: 'text' },
    exp: { k: 'exp', label: 'EXP', type: 'number' },
    hp: { k: 'hp', label: 'HP', type: 'number' },
    str: { k: 'str', label: 'Strength', type: 'number' },
    vit: { k: 'vit', label: 'Vitality', type: 'number' },
    def: { k: 'def', label: 'Defense', type: 'number' },
    agi: { k: 'agi', label: 'Agility', type: 'number' },
    luck: { k: 'luck', label: 'Luck', type: 'number' },
    attack: { k: 'attack', label: 'Attack', type: 'number' },
    crit: { k: 'crit', label: 'Crit chance %', type: 'number' },
    critDamage: { k: 'critDamage', label: 'Crit damage %', type: 'number' },
    worth: { k: 'worth', label: 'Resale value', type: 'number' },
    image: { k: 'image', label: 'Image URL', type: 'text' },
    drops: { k: 'drops', label: 'Drops', type: 'drops' }
  };

  var SCHEMA = {
    items: {
      label: 'Item',
      plural: 'Items',
      fields: ['name', 'category', 'rarity', 'desc', 'exp', 'hp', 'str', 'vit', 'def', 'agi', 'luck', 'worth', 'drops'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'category', 'rarity', 'worth']
    },
    equipment: {
      label: 'Equipment',
      plural: 'Equipment',
      fields: ['name', 'slot', 'rarity', 'source', 'attack', 'crit', 'critDamage', 'def', 'str', 'vit', 'agi', 'luck', 'effect', 'worth', 'image'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'slot', 'rarity', 'source', 'worth']
    },
    overlays: {
      label: 'Overlay',
      plural: 'Overlays',
      fields: ['name', 'rarity', 'source', 'desc', 'worth', 'image'].map(function (k) { return FIELDS[k]; }),
      adminCols: ['name', 'rarity', 'source', 'worth']
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
        { k: 'item', label: 'Item', type: 'text', required: true },
        { k: 'mode', label: 'Trade type', type: 'select', options: ['Crosstrading', 'Exchange'] },
        { k: 'side', label: 'Side', type: 'select', options: ['Selling', 'Buying'] },
        { k: 'qty', label: 'Quantity', type: 'number' },
        { k: 'price', label: 'Price each', type: 'number' },
        { k: 'user', label: 'Trader', type: 'text' },
        { k: 'note', label: 'Note', type: 'text' },
        { k: 'sold', label: 'Sold (1 = yes)', type: 'number' }
      ],
      adminCols: ['item', 'side', 'qty', 'price', 'user', 'sold']
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
    eta: 'Sample records. Replace them with real game data.',
    items: [
      {
        id: 'moon-elixir', name: 'Moon Elixir', category: 'Consumable', rarity: 'Uncommon',
        desc: 'Restores HP over a few seconds.', exp: 0, hp: 300, str: 0, vit: 0, def: 0, agi: 0, luck: 0,
        worth: 400,
        drops: [
          { mob: 'Water Style Disciple', oneIn: 40, rolls: 1 },
          { mob: 'Marina the South Sea Commander', oneIn: 120, rolls: 1 }
        ]
      },
      {
        id: 'slime-gel', name: 'Slime Gel', category: 'Material', rarity: 'Common',
        desc: 'Sticky gel used in crafting.', exp: 15, hp: 0, str: 0, vit: 0, def: 0, agi: 0, luck: 0,
        worth: 40,
        drops: [
          { mob: 'Goblin', oneIn: 3, rolls: 2 },
          { mob: 'Leader Goblin', oneIn: 9, rolls: 1 }
        ]
      },
      {
        id: 'iron-core', name: 'Iron Core', category: 'Material', rarity: 'Rare',
        desc: 'Dense core used to forge gear.', exp: 0, hp: 0, str: 0, vit: 6, def: 4, agi: 0, luck: 0,
        worth: 1200,
        drops: [
          { mob: 'Leader Goblin', oneIn: 25, rolls: 1 },
          { mob: 'Drake the North Sea Commander', oneIn: 60, rolls: 2 }
        ]
      },
      {
        id: 'bat-wing', name: 'Bat Wing', category: 'Material', rarity: 'Uncommon',
        desc: 'Light wing used in crafting.', exp: 0, hp: 0, str: 0, vit: 0, def: 0, agi: 5, luck: 2,
        worth: 90,
        drops: [
          { mob: 'Goblin', oneIn: 12, rolls: 1 },
          { mob: 'Karkinos the Visceral', oneIn: 30, rolls: 1 }
        ]
      }
    ],

    equipment: [
      {
        id: 'crimson-blade', name: 'Crimson Blade', slot: 'Weapon', rarity: 'Epic', source: 'Event Shop',
        attack: 320, crit: 12, critDamage: 65, def: 0, str: 40, vit: 0, agi: 8, luck: 0,
        effect: 'Burn on hit (10%)', worth: 12500, image: ''
      },
      {
        id: 'iron-sword', name: 'Iron Sword', slot: 'Weapon', rarity: 'Common', source: 'Starter',
        attack: 80, crit: 5, critDamage: 10, def: 0, str: 12, vit: 0, agi: 0, luck: 0,
        effect: 'None', worth: 600, image: ''
      },
      {
        id: 'warden-plate', name: 'Warden Plate', slot: 'Armor', rarity: 'Rare', source: 'Gamepasses',
        attack: 0, crit: 0, critDamage: 0, def: 140, str: 0, vit: 90, agi: 0, luck: 0,
        effect: 'Take 6% less damage', worth: 9800, image: ''
      },
      {
        id: 'iron-helm', name: 'Iron Helm', slot: 'Helmet', rarity: 'Uncommon', source: 'Badges',
        attack: 0, crit: 0, critDamage: 0, def: 40, str: 0, vit: 25, agi: 0, luck: 0,
        effect: 'None', worth: 450, image: ''
      },
      {
        id: 'sunfire-cape', name: 'Sunfire Cape', slot: 'Cape', rarity: 'Legendary', source: 'Event Shop',
        attack: 0, crit: 0, critDamage: 0, def: 95, str: 0, vit: 120, agi: 0, luck: 10,
        effect: '+10% EXP', worth: 48000, image: ''
      }
    ],

    overlays: [
      { id: 'ember-trail', name: 'Ember Trail', rarity: 'Epic', source: 'Event Shop', desc: 'Drifting embers around your gear.', worth: 5000, image: '' },
      { id: 'frost-veil', name: 'Frost Veil', rarity: 'Rare', source: 'Gamepasses', desc: 'A pale frost shimmer on your outfit.', worth: 2500, image: '' },
      { id: 'gilded-outline', name: 'Gilded Outline', rarity: 'Mythic', source: 'Badges', desc: 'A thin gold edge on every piece.', worth: 8000, image: '' }
    ],

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

    listings: [
      { id: 'l-1', itemId: 'crimson-blade', item: 'Crimson Blade', mode: 'Crosstrading', side: 'Selling', qty: 1, price: 12000, user: 'Kaito_X', note: 'Negotiable', createdAt: mins(2), sold: false },
      { id: 'l-2', itemId: 'moon-elixir', item: 'Moon Elixir', mode: 'Crosstrading', side: 'Buying', qty: 5, price: 800, user: 'AsunaFan07', note: '', createdAt: mins(9), sold: false },
      { id: 'l-3', itemId: 'iron-core', item: 'Iron Core', mode: 'Exchange', side: 'Selling', qty: 3, price: 2400, user: 'Forge_Lord', note: 'Bulk discount', createdAt: mins(31), sold: false },
      { id: 'l-4', itemId: 'sunfire-cape', item: 'Sunfire Cape', mode: 'Crosstrading', side: 'Buying', qty: 1, price: 52000, user: 'NightOwl_9', note: 'Online evenings', createdAt: mins(60), sold: false },
      { id: 'l-5', itemId: 'frost-veil', item: 'Frost Veil', mode: 'Exchange', side: 'Buying', qty: 1, price: 3000, user: 'Mira_K', note: '', createdAt: mins(120), sold: false }
    ],

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
    VERSION: 2,
    // The one place the loadstring points. Switch `raw` to .../main/script/Init.lua
    // once the script folder move is pushed; until then the live build is at the root.
    SCRIPT: {
      raw: 'https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/Init.lua',
      repo: 'https://github.com/Enthusiasticzz/Autofarm-Script-Sbor'
    },
    RARITIES: RARITIES,
    SOURCES: SOURCES,
    SLOTS: SLOTS,
    ITEM_CATEGORIES: ITEM_CATEGORIES,
    MOBS: MOBS,
    SCHEMA: SCHEMA,
    SEED: SEED,
    PASS: 'gilded-staff'
  };
})();
