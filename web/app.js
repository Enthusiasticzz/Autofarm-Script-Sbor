/* =====================================================================
   Gilded Archive — application
   ---------------------------------------------------------------------
   Everything is plain DOM: no framework, no build. Records live in
   `data.js`, are copied into localStorage, and every view reads from
   that one state object.
   ===================================================================== */
(function () {
  'use strict';

  /* ---------------------------------------------------------------- */
  /* Helpers                                                          */
  /* ---------------------------------------------------------------- */

  const GA = window.GA;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => '&#' + c.charCodeAt(0) + ';');
  const n = v => (Number(v) || 0).toLocaleString();
  const stat = v => (Number(v) ? n(v) : '—');
  const slug = s => String(s || '').toLowerCase().replace(/\W/g, '');
  const uid = p => p + '-' + Math.random().toString(36).slice(2, 8);
  const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
  const clone = o => (window.structuredClone ? structuredClone(o) : JSON.parse(JSON.stringify(o)));

  // v3: the records now come from the game's own dump, so the old placeholder
  // listings were dropped with the data they pointed at.
  const SKEY = 'gilded.v3';
  const STAFF_KEY = 'gilded.staff';
  const SCRIPT = GA.SCRIPT || {};
  const RAW = SCRIPT.raw || 'https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/script/Init.lua';
  const LOADSTRING = `loadstring(game:HttpGet("${RAW}"))()`;

  /* ---------------------------------------------------------------- */
  /* State                                                            */
  /* ---------------------------------------------------------------- */

  function seedHash() {
    const s = JSON.stringify(GA.SEED);
    let h = 5381;
    for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
    return h.toString(36) + '.' + s.length;
  }

  function read() {
    const hash = seedHash();
    try {
      const raw = localStorage.getItem(SKEY);
      if (raw) {
        const d = JSON.parse(raw);
        if (d && d.items && d.settings) {
          if (d.seedHash === hash) return d;
          // data.js changed: refresh the reference records, keep what people posted.
          const base = clone(GA.SEED);
          base.seedHash = hash;
          // Rarity is the one field filled in by hand, so it survives a re-dump.
          ['items', 'equipment', 'overlays'].forEach(k => {
            const before = new Map((d[k] || []).map(r => [r.id, r.rarity]));
            (base[k] || []).forEach(r => {
              const was = before.get(r.id);
              if (was) r.rarity = was;
            });
          });
          base.listings = d.listings || base.listings;
          base.orders = d.orders || [];
          base.gains = d.gains || base.gains;
          base.settings = Object.assign(base.settings, d.settings);
          write(base);
          return base;
        }
      }
    } catch (e) {
      console.warn('Local storage unavailable, running from memory.', e);
    }
    const base = clone(GA.SEED);
    base.seedHash = hash;
    write(base);
    return base;
  }

  function write(d) {
    try { localStorage.setItem(SKEY, JSON.stringify(d)); } catch (e) { /* private mode */ }
  }

  let S = read();
  const save = () => write(S);

  // Codes people hold on to. No account exists, so a code is the only way
  // back to a listing or an order. The alphabet skips look-alikes (0/O, 1/I).
  const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  function code(len) {
    const out = [];
    const c = window.crypto && window.crypto.getRandomValues ? window.crypto : null;
    const buf = c ? c.getRandomValues(new Uint32Array(len)) : null;
    for (let i = 0; i < len; i++) out.push(CODE_CHARS[(buf ? buf[i] : Math.floor(Math.random() * 1e9)) % CODE_CHARS.length]);
    return out.join('');
  }
  const newCode = prefix => prefix + '-' + code(4) + '-' + code(4);

  // The trades this browser created, so people do not have to retype codes.
  const MINE_KEY = 'gilded.mine';
  let MINE = [];
  try { MINE = JSON.parse(localStorage.getItem(MINE_KEY)) || []; } catch (e) { MINE = []; }
  const saveMine = () => { try { localStorage.setItem(MINE_KEY, JSON.stringify(MINE.slice(0, 40))); } catch (e) { /* private mode */ } };

  // Crosstrading used to be a single item with a per-item price and a public
  // trader. It is now a bundle for one price with a private seller, so older
  // listings are converted once. Old "buying" crosstrades move to the exchange,
  // which still has a buying side.
  function migrate() {
    let changed = false;
    S.orders = S.orders || [];
    S.listings = (S.listings || []).map(l => {
      if (l.mode !== 'Crosstrading' || Array.isArray(l.items)) return l;
      changed = true;
      if (l.side === 'Buying') return Object.assign({}, l, { mode: 'Exchange' });
      const qty = Math.max(1, Number(l.qty) || 1);
      const o = Object.assign({}, l, {
        items: [{ name: l.item, qty }],
        price: Math.max(0, Math.round((Number(l.price) || 0) * qty)),
        sellerUser: l.user || '',
        code: code(4),
        sellerCode: newCode('S')
      });
      delete o.user;
      delete o.itemId;
      return o;
    });
    // Prices were in an unmarked in-game unit; crosstrading is now US dollars and
    // there is no honest conversion, so older listings are retired.
    S.listings = S.listings.map(l => {
      if (l.mode === 'Crosstrading' && Array.isArray(l.items) && l.currency !== 'USD' && !l.cancelled) {
        changed = true;
        return Object.assign({}, l, { cancelled: true });
      }
      return l;
    });
    if (changed) save();
  }
  migrate();

  /* ---------------------------------------------------------------- */
  /* Derived values                                                   */
  /* ---------------------------------------------------------------- */

  const RARITY = ['Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic'];
  const RANK = RARITY.slice();

  function chance(d) {
    const oneIn = Math.max(1, Number(d.oneIn) || 1);
    const rolls = Math.max(1, Number(d.rolls) || 1);
    return clamp(1 - Math.pow(1 - 1 / oneIn, rolls), 0, 1);
  }

  function pct(p) {
    const x = p * 100;
    if (x >= 10) return (Math.round(x * 10) / 10).toString() + '%';
    if (x >= 1) return x.toFixed(2) + '%';
    if (x >= 0.01) return x.toFixed(3) + '%';
    return x.toFixed(4) + '%';
  }

  function tierFor(oneIn) {
    const k = Math.max(1, Number(oneIn) || 1);
    if (k <= 4) return 'Common';
    if (k <= 19) return 'Uncommon';
    if (k <= 99) return 'Rare';
    if (k <= 499) return 'Epic';
    if (k <= 4999) return 'Legendary';
    return 'Mythic';
  }

  function ago(iso) {
    const t = Date.parse(iso);
    if (!t) return '—';
    const s = Math.max(0, (Date.now() - t) / 1000);
    if (s < 60) return 'just now';
    const m = Math.floor(s / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
    if (m < 60) return m + 'm ago';
    if (h < 24) return h + 'h ago';
    if (d < 7) return d + 'd ago';
    return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }

  const findEntry = name => {
    const q = String(name || '').trim().toLowerCase();
    return [...S.items, ...S.equipment, ...S.overlays].find(x => x.name.toLowerCase() === q) || null;
  };

  function entryKind(entry) {
    if (!entry) return null;
    if (S.items.includes(entry)) return 'items';
    if (S.equipment.includes(entry)) return 'equipment';
    return 'overlays';
  }

  /* ---------------------------------------------------------------- */
  /* Cell renderers                                                   */
  /* ---------------------------------------------------------------- */

  const rar = v => `<span class="rar r-${slug(v)}"><i></i>${esc(v)}</span>`;
  const src = v => (v ? `<span class="tag ${slug(v)}">${esc(v)}</span>` : '<span class="dim">—</span>');
  const dim = v => `<span class="dim">${esc(v)}</span>`;
  const plain = v => `<span class="nm">${esc(v)}</span>`;
  const side = v => `<span class="tag ${slug(v)}">${esc(v)}</span>`;
  const yes = v => (v ? '<span class="tag drop">Sold</span>' : '<span class="tag quest">Open</span>');

  const price = v => (Number(v) ? n(v) : '—');

  // First item by name, the rest as a count, so a bundle fits one table row.
  function crossItemsCell(r) {
    const [a, ...rest] = r.items || [];
    if (!a) return plain(r.item);
    return `<span class="nm">${esc(a.name)}${a.qty > 1 ? ` ×${n(a.qty)}` : ''}</span>${rest.length ? ` <span class="dim">+ ${n(rest.length)} more</span>` : ''}`;
  }

  const C = {
    items: [
      { k: 'name', t: 'Name', f: plain },
      { k: 'type', t: 'Type', f: dim },
      { k: 'rarity', t: 'Rarity', f: v => (v ? rar(v) : dim('—')) },
      { k: 'worth', t: 'Worth', num: 1, f: n },
      { k: 'sell', t: 'Sells for', num: 1, f: price },
      { k: 'source', t: 'Source', f: src }
    ],
    equipment: [
      { k: 'name', t: 'Name', f: plain },
      { k: 'slot', t: 'Slot', f: dim },
      { k: 'rarity', t: 'Rarity', f: v => (v ? rar(v) : dim('—')) },
      { k: 'level', t: 'Lvl', num: 1, f: stat },
      { k: 'dmg', t: 'DMG', num: 1, f: stat },
      { k: 'def', t: 'DEF', num: 1, f: stat },
      { k: 'dex', t: 'DEX', num: 1, f: stat },
      { k: 'worth', t: 'Worth', num: 1, f: n },
      { k: 'source', t: 'Source', f: src }
    ],
    overlays: [
      { k: 'name', t: 'Name', f: plain },
      { k: 'group', t: 'Type', f: dim },
      { k: 'rarity', t: 'Rarity', f: v => (v ? rar(v) : dim('—')) },
      { k: 'worth', t: 'Worth', num: 1, f: n },
      { k: 'source', t: 'Source', f: src }
    ],
    trades: [
      { k: 'side', t: 'Type', f: side },
      { k: 'item', t: 'Item', f: plain },
      { k: 'qty', t: 'Qty', num: 1 },
      { k: 'price', t: 'Price each', num: 1, f: n },
      { k: 'user', t: 'Trader' },
      { k: 'createdAt', t: 'Posted', f: ago }
    ],
    cross: [
      { k: 'item', t: 'Items', f: (v, r) => crossItemsCell(r) },
      { k: 'price', t: 'Price (USD)', num: 1, f: v => usd(v) },
      { k: 'code', t: 'Listing', f: v => `<span class="dim lcode">${esc(v)}</span>` },
      { k: 'createdAt', t: 'Posted', f: ago },
      { k: 'status', t: 'Status', f: v => `<span class="tag ${v === 'Reserved' ? 'crafted' : 'shop'}">${esc(v)}</span>` }
    ],
    tradesMini: [
      { k: 'side', t: 'Type', f: side },
      { k: 'item', t: 'Item', f: plain },
      { k: 'price', t: 'Price', num: 1, f: (v, r) => (r.mode === 'Crosstrading' ? usd(v) : n(v)) },
      { k: 'createdAt', t: 'Posted', f: ago }
    ]
  };

  /* ---------------------------------------------------------------- */
  /* Generic table: sort, filter, search                              */
  /* ---------------------------------------------------------------- */

  const T = {};
  // The database opens A to Z instead of in the order the game dumped it.
  ['tItems', 'tEquip', 'tOver'].forEach(id => { T[id] = { key: 'name', dir: 1 }; });
  // Listings open newest first.
  ['tCross', 'tExch'].forEach(id => { T[id] = { key: 'createdAt', dir: -1 }; });

  // The database is thousands of rows, so a table paints one page at a time.
  // Filtering and sorting run over every row; only the page is in the DOM.
  const PAGE = 50;

  // One searchable string per record, built once. Tagging it on the record
  // would put it in localStorage, so it lives beside the data.
  const HAY = new WeakMap();
  function hay(x) {
    let s = HAY.get(x);
    if (s === undefined) {
      s = JSON.stringify(x).toLowerCase();
      HAY.set(x, s);
    }
    return s;
  }

  function table(id, cols, rows, onRow) {
    const prev = T[id] || {};
    T[id] = Object.assign({ key: prev.key, dir: prev.dir, q: prev.q || '', fil: prev.fil || {}, drawn: prev.drawn, page: prev.page || 1 }, { cols, rows, onRow });
    draw(id);
  }

  // The pager lives beside the table, outside its horizontal scroll frame.
  function pagerFor(w) {
    let p = w.nextElementSibling;
    if (!p || !p.classList.contains('pager')) {
      p = document.createElement('div');
      p.className = 'pager';
      w.after(p);
    }
    return p;
  }

  function drawPager(w, s, pages) {
    const p = pagerFor(w);
    p.dataset.pager = w.id;
    p.hidden = pages < 2;
    if (pages < 2) { p.innerHTML = ''; return; }

    const page = s.page;
    const at = i => `<button data-page="${i}" class="${i === page ? 'on' : ''}"${i === page ? ' aria-current="page"' : ''}>${i}</button>`;
    const parts = [`<button class="step" data-page="${page - 1}"${page === 1 ? ' disabled' : ''} aria-label="Previous page">‹</button>`];
    const win = [];
    for (let i = Math.max(1, page - 2); i <= Math.min(pages, page + 2); i++) win.push(i);
    if (win[0] > 1) { parts.push(at(1)); if (win[0] > 2) parts.push('<span class="gap">…</span>'); }
    win.forEach(i => parts.push(at(i)));
    if (win[win.length - 1] < pages) {
      if (win[win.length - 1] < pages - 1) parts.push('<span class="gap">…</span>');
      parts.push(at(pages));
    }
    parts.push(`<button class="step" data-page="${page + 1}"${page === pages ? ' disabled' : ''} aria-label="Next page">›</button>`);
    p.innerHTML = parts.join('');
  }

  function draw(id) {
    const s = T[id];
    const w = $('#' + id);
    if (!s || !w) return;

    const q = (s.q || '').toLowerCase().trim();
    const rows = s.rows.filter(x =>
      (!q || hay(x).includes(q)) &&
      Object.entries(s.fil || {}).every(([k, v]) => !v || x[k] === v));

    const keyOf = x => (s.key === 'rarity' ? RANK.indexOf(x.rarity) : s.cols.find(c => c.k === s.key)?.sort ? s.cols.find(c => c.k === s.key).sort(x[s.key]) : x[s.key]);
    if (s.key) rows.sort((a, b) => (keyOf(a) > keyOf(b) ? 1 : keyOf(a) < keyOf(b) ? -1 : 0) * s.dir);

    s.view = rows;
    const pages = Math.max(1, Math.ceil(rows.length / PAGE));
    s.page = Math.min(Math.max(1, s.page || 1), pages);
    const start = (s.page - 1) * PAGE;
    const shown = rows.slice(start, start + PAGE);

    const head = s.cols.map(c => `<th data-k="${c.k}" tabindex="0" class="${c.num ? 'num' : ''}" aria-sort="${s.key === c.k ? (s.dir > 0 ? 'ascending' : 'descending') : 'none'}">${c.t}${s.key === c.k ? (s.dir > 0 ? ' ▲' : ' ▼') : ''}</th>`).join('');
    const body = shown.map((x, j) => `<tr data-id="${esc(x.id || '')}" tabindex="0" style="--d:${Math.min(j, 12) * 35}ms">${s.cols.map(c => `<td class="${c.num ? 'num' : ''}">${c.f ? c.f(x[c.k], x) : esc(x[c.k])}</td>`).join('')}</tr>`).join('');

    w.classList.toggle('settled', !!s.drawn);
    s.drawn = 1;
    w.innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${body ||
      `<tr><td class="empty" colspan="${s.cols.length}">Nothing matches. <button class="btn g s" data-clear="${id}">Clear filters</button></td></tr>`}</tbody></table>`;

    drawPager(w, s, pages);

    const c = $(`[data-for="${id}"]`);
    if (c) {
      if (pages > 1) {
        c.textContent = `${n(start + 1)}–${n(start + shown.length)} of ${n(rows.length)} ${rows.length === s.rows.length ? c.dataset.u : 'matches'}`;
      } else if (rows.length === s.rows.length) {
        c.textContent = n(rows.length) + ' ' + c.dataset.u;
      } else {
        c.textContent = `Showing ${n(rows.length)} of ${n(s.rows.length)} ${c.dataset.u}`;
      }
    }
  }

  function chips() {
    $$('.chips').forEach(el => {
      const s = T[el.dataset.t];
      if (!s) return;
      const k = el.dataset.k;
      let vals = Array.from(new Set(s.rows.map(r => r[k]).filter(v => v !== undefined && v !== null && v !== '')));
      if (k === 'rarity') vals.sort((a, b) => RANK.indexOf(a) - RANK.indexOf(b));
      else vals.sort((a, b) => String(a).localeCompare(String(b)));
      // A row with one choice filters nothing; it appears once there is a choice.
      el.hidden = vals.length < 2;
      if (el.hidden) { el.innerHTML = ''; return; }
      // Counts follow the search and the other filters, so each choice shows
      // how many rows it would leave.
      const q = (s.q || '').toLowerCase().trim();
      const base = s.rows.filter(x =>
        (!q || hay(x).includes(q)) &&
        Object.entries(s.fil || {}).every(([fk, v]) => fk === k || !v || x[fk] === v));
      const counts = {};
      base.forEach(x => { counts[x[k]] = (counts[x[k]] || 0) + 1; });
      const cur = (s.fil || {})[k] || '';
      el.innerHTML = ['', ...vals].map(v => {
        const c = v ? (counts[v] || 0) : base.length;
        const label = v ? (k === 'rarity' ? `<span class="rar r-${slug(v)}"><i></i>${esc(v)}</span>` : esc(v)) : 'All';
        return `<button data-v="${esc(v)}" class="${v === cur ? 'on' : ''}${c ? '' : ' zero'}" aria-pressed="${v === cur}"><span>${label}</span><small>${n(c)}</small></button>`;
      }).join('');
    });
  }

  /* ---------------------------------------------------------------- */
  /* Drawer, dialog, toast                                            */
  /* ---------------------------------------------------------------- */

  let lastFocus = null;
  // Set while a click is opening the drawer, so that same click does not
  // immediately count as a click outside it.
  let openedThisClick = false;

  // The record the panel is showing, and the list it was opened from, so the
  // arrows can step through whatever the table currently shows.
  let inspect = null;

  function navBar() {
    if (!inspect || inspect.list.length < 2) return '';
    const { list, i } = inspect;
    return `<span class="ins-pos">${n(i + 1)} of ${n(list.length)}</span>
      <button class="ins-step" data-nav="-1" aria-label="Previous record" title="Previous (← or ↑)"${i === 0 ? ' disabled' : ''}>←</button>
      <button class="ins-step" data-nav="1" aria-label="Next record" title="Next (→ or ↓)"${i === list.length - 1 ? ' disabled' : ''}>→</button>`;
  }

  function stepInspect(d) {
    if (!inspect) return;
    const k = inspect.i + d;
    if (k < 0 || k >= inspect.list.length) return;
    inspect.i = k;
    inspect.open(inspect.list[k]);
  }

  function drawer(html, actions = '', kind = '') {
    const box = $('#drawer');
    const active = document.activeElement;
    const stepFocus = active && active.dataset && active.dataset.nav;
    if (!box.classList.contains('open')) lastFocus = active;
    box.innerHTML = `<div class="ins-top"><span class="ins-kind">${kind}</span><span class="ins-tools">${navBar()}<button class="ins-x" data-close aria-label="Close details" title="Close (Esc)">×</button></span></div>
      <div class="drawer-scroll"><div class="drawer-body">${html}</div></div>
      ${actions ? `<div class="ins-foot">${actions}</div>` : ''}`;
    box.classList.add('open');
    $('#scrim').classList.add('on');
    document.documentElement.classList.add('lock');
    openedThisClick = true;
    const keep = stepFocus && box.querySelector(`[data-nav="${stepFocus}"]:not([disabled])`);
    const b = keep || box.querySelector('[data-close]');
    if (b) b.focus({ preventScroll: true });
  }

  function hideDrawer() {
    const box = $('#drawer');
    box.classList.remove('open');
    $('#scrim').classList.remove('on');
    document.documentElement.classList.remove('lock');
    setTimeout(() => { if (!box.classList.contains('open')) box.innerHTML = ''; }, 220);
  }

  function closeDrawer() {
    inspect = null;
    hideDrawer();
    const m = location.hash.match(/^#(item|gear|overlay)\//);
    if (m) {
      const pane = m[1] === 'item' ? 'items' : m[1] === 'gear' ? 'equipment' : 'overlays';
      history.replaceState(null, '', '#database/' + pane);
    }
    if (lastFocus && document.contains(lastFocus)) lastFocus.focus({ preventScroll: true });
  }

  function detailUrl(seg, id) {
    const want = '#' + seg + '/' + id;
    if (location.hash !== want) history.pushState(null, '', want);
  }

  function dlg(html) {
    $('#dlg').innerHTML = html;
    const d = $('#dlg');
    if (!d.open) d.showModal();
    const first = d.querySelector('input, select, textarea');
    if (first) first.focus({ preventScroll: true });
  }

  let toastT;
  function toast(msg) {
    const t = $('#toast');
    t.textContent = msg;
    t.classList.add('on');
    clearTimeout(toastT);
    toastT = setTimeout(() => t.classList.remove('on'), 2800);
  }

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
    } catch (e) {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch (e2) { /* ignore */ }
      ta.remove();
    }
    toast('Copied');
  }

  const link = hashPath => location.href.split('#')[0] + '#' + hashPath;

  function image(src, name) {
    const initials = (String(name || '?').match(/\b\w/g) || []).slice(0, 2).join('').toUpperCase();
    if (!src) return `<div class="img ph"><b>${esc(initials)}</b><small>No image yet</small></div>`;
    return `<div class="img" data-initials="${esc(initials)}"><img src="${esc(src)}" alt="${esc(name)}" loading="lazy"></div>`;
  }

  /* ---------------------------------------------------------------- */
  /* Detail views                                                     */
  /* ---------------------------------------------------------------- */

  // The stats the game actually stores on an item. A record only shows the
  // ones it has, so a material is not padded with five dashes.
  const STATS = [['level', 'LVL'], ['skill', 'SKILL'], ['dmg', 'DMG'], ['def', 'DEF'], ['dex', 'DEX']];

  const statBlock = r => {
    const rows = STATS.filter(([k]) => Number(r[k]));
    if (!rows.length) return '';
    return `<div class="statgrid">${rows.map(([k, t]) => `<div><span>${t}</span><b>${stat(r[k])}</b></div>`).join('')}</div>`;
  };

  const FLAGS = {
    Bound: 'Bound, cannot be traded',
    Unobtainable: 'No longer obtainable',
    Pass: 'Needs a gamepass',
    Group: 'Group members only',
    Badge: 'Badge reward'
  };

  const flagTags = flags => (flags || [])
    .map(f => `<span class="chip" title="${esc(FLAGS[f] || '')}">${esc(FLAGS[f] || f)}</span>`).join(' ');

  const sourceTags = r => {
    const list = r.obtained && r.obtained.length ? r.obtained : (r.source ? [r.source] : []);
    return list.map(src).join(' ');
  };

  const descText = v => esc(v || 'No description.').replace(/\n/g, '<br>');

  // A titled section; the index staggers the entrance of each one.
  let secN = 0;
  const sec = (title, body, cls = '') =>
    `<section class="ins-sec ${cls}" style="--i:${secN++}"><h4>${title}</h4>${body}</section>`;

  const row = (k, v) => `<div class="ins-row"><span>${k}</span><b>${v}</b></div>`;

  function recipeTable(recipe) {
    if (!recipe) return '';
    const rows = (recipe.materials || []).map(m =>
      `<tr><td>${esc(m.name)}</td><td class="num">×${n(m.amount)}</td></tr>`).join('');
    return sec(`Recipe${Number(recipe.skill) ? ` <small>skill ${n(recipe.skill)}</small>` : ''}`,
      `<div class="tw plain"><table class="mini"><thead><tr><th>Material</th><th class="num">Amount</th></tr></thead><tbody>${rows}</tbody></table></div>`);
  }

  // Open listings for a record. Crosstrading is priced in US dollars and the
  // exchange in game currency, so the two are never blended into one number.
  // A bundle has one price for everything, so only a single-item crosstrade
  // gives a per-item price; bundles are counted but not priced.
  function marketFor(entry) {
    const name = entry.name.toLowerCase();
    const m = marketRows();
    const same = x => x.itemId === entry.id || String(x.item).toLowerCase() === name;
    const exSells = m.exch.filter(x => x.side === 'Selling' && same(x));
    const buys = m.exch.filter(x => x.side === 'Buying' && same(x));
    const xs = m.cross.filter(x => x.items.some(i => i.name.toLowerCase() === name));
    const unit = xs.filter(x => x.items.length === 1).map(x => Math.round(x.price / Math.max(1, x.items[0].qty)));
    if (!xs.length && !exSells.length && !buys.length) return sec('Market', '<p class="muted small">No open listings for this yet.</p>');
    const cell = (label, count, text) => `<div class="ins-m"><span>${label}</span>${count
      ? `<b>${text}</b><small>${n(count)} open</small>` : '<b class="dim">None</b><small>&nbsp;</small>'}</div>`;
    return sec('Market', `<div class="ins-market">
      ${cell('Crosstrading', xs.length, unit.length ? `from ${usd(Math.min(...unit))} each` : 'In bundles')}
      ${cell('Exchange, selling', exSells.length, exSells.length ? `from ${n(Math.min(...exSells.map(x => x.price)))} each` : '')}
      ${cell('Exchange, wanted', buys.length, buys.length ? `up to ${n(Math.max(...buys.map(x => x.price)))}` : '')}
    </div>`);
  }

  const KIND_LABEL = { items: 'Item', equipment: 'Equipment', overlays: 'Overlay' };

  function showEntry(r) {
    if (!inspect || inspect.list[inspect.i] !== r) inspect = null;
    const kind = r.kind === 'equipment' ? 'equipment' : r.kind === 'overlays' ? 'overlays' : 'items';
    const seg = kind === 'items' ? 'item' : kind === 'equipment' ? 'gear' : 'overlay';
    if (r.id) detailUrl(seg, r.id);
    secN = 0;
    const flags = (r.flags || []).map(f => `<li>${esc(FLAGS[f] || f)}</li>`).join('');
    const sub = [r.type, r.slot, r.group].filter((v, i, all) => v && all.indexOf(v) === i).map(esc).join(' · ');
    const effect = r.effect
      ? sec('Effect', `<p>${esc(r.effect.name)}${(r.effect.props || []).map(p => `<br><span class="muted">${esc(p.label)}</span> ${esc(p.value)}`).join('')}</p>`)
      : '';
    const value = sec('Value', [
      row('Worth', n(r.worth)),
      row('Shop price', Number(r.sell) ? n(r.sell) : '<span class="dim">Not sold in shops</span>'),
      Number(r.sellAgility) ? row('With Agility pass', n(r.sellAgility)) : '',
      r.eventCurrency ? row('Bought with', esc(r.eventCurrency)) : ''
    ].join(''));
    const where = sec('Where to get it', `<div class="ins-src">${sourceTags(r) || '<span class="dim">Unknown</span>'}</div>`);

    drawer(`<div class="ins-grid"><div class="ins-col"><header class="ins-head">
        ${kind === 'items' && !r.image ? '' : image(r.image, r.name)}
        <div>
          <h3>${esc(r.name)}</h3>
          <p class="ins-meta">${r.rarity ? rar(r.rarity) : '<span class="dim">Unrated</span>'}${sub ? `<span class="ins-sub">${sub}</span>` : ''}</p>
        </div>
      </header>
      ${flags ? `<ul class="ins-flags">${flags}</ul>` : ''}
      <p class="ins-desc">${descText(r.desc)}</p>
      ${statBlock(r)}
      ${value}</div><div class="ins-col">
      ${where}
      ${marketFor(r)}
      ${effect}
      ${kind === 'overlays' ? '' : sec('Dropped by', dropTable(r.drops))}
      ${recipeTable(r.recipe)}</div></div>`, openActions(r, kind), `${KIND_LABEL[kind]}${r.slot ? ' / ' + esc(r.slot) : ''}`);
  }

  function dropTable(drops) {
    if (!drops || !drops.length) return '<p class="muted small">No known drops yet.</p>';
    const rows = drops.slice().sort((a, b) => a.oneIn - b.oneIn).map(d => {
      const p = chance(d);
      return `<tr>
        <td>${esc(d.mob)}</td>
        <td class="num">1 in ${n(d.oneIn)}${Number(d.rolls) > 1 ? ` ×${n(d.rolls)}` : ''}</td>
        <td class="num">${pct(p)}</td>
        <td class="num">${rar(tierFor(d.oneIn))}</td>
      </tr>`;
    }).join('');
    return `<div class="tw plain"><table class="mini"><thead><tr><th>Mob</th><th class="num">Rate</th><th class="num">Per kill</th><th class="num">Tier</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  }

  const openActions = (entry, kind) => {
    const seg = kind === 'items' ? 'item' : kind === 'equipment' ? 'gear' : 'overlay';
    return `<button class="btn" data-jump="market" data-name="${esc(entry.name)}">Find listings</button>` +
      `<button class="btn g" data-copy-link="${seg}/${esc(entry.id)}">Copy link</button>`;
  };

  // One sheet for all three tabs; the record's kind decides the header.
  const showItem = showEntry;
  const showEquip = showEntry;
  const showOverlay = showEntry;

  function showListing(r) {
    if (!inspect || inspect.list[inspect.i] !== r) inspect = null;
    const entry = r.itemId
      ? [...S.items, ...S.equipment, ...S.overlays].find(x => x.id === r.itemId) || findEntry(r.item)
      : findEntry(r.item);
    const view = entry ? entryKind(entry) : null;
    const seg = view === 'items' ? 'item' : view === 'equipment' ? 'gear' : 'overlay';
    secN = 0;
    const mode = r.mode === 'Exchange' ? 'In-game exchange' : 'Crosstrading';
    const initial = (String(r.user || '?').match(/[A-Za-z0-9]/) || ['?'])[0].toUpperCase();
    drawer(`<div class="ins-grid"><div class="ins-col"><header class="ins-head ins-head-l">
        <div>
          <h3>${esc(r.item)}</h3>
          <p class="ins-meta">${side(r.side)}<span class="ins-sub">${mode}${r.sold ? ' · Sold' : ''}</span></p>
        </div>
      </header>
      <div class="ins-price">
        <div><span>${r.side === 'Buying' ? 'Offering each' : 'Asking each'}</span><b>${n(r.price)}</b></div>
        <div><span>Quantity</span><b>${n(r.qty)}</b></div>
        <div class="total"><span>Total</span><b>${n(r.qty * r.price)}</b></div>
      </div></div><div class="ins-col">
      ${sec('Trader', `<div class="ins-trader"><i>${esc(initial)}</i><div><b>${esc(r.user)}</b><small>Posted ${ago(r.createdAt)}</small></div><button class="btn g s" data-copy="${esc(r.user)}">Copy</button></div>
        <p class="ins-how muted small">Message them in-game with this username to arrange the trade.</p>`)}
      ${r.note ? sec('Note', `<p class="ins-note">${esc(r.note)}</p>`) : ''}</div></div>`,
      (entry ? `<button class="btn" data-jump="${view}" data-name="${esc(entry.name)}">View in database</button>` : `<button class="btn" data-copy="${esc(r.user)}">Copy username</button>`) +
      `<button class="btn g" data-sold="${esc(r.id)}">${r.sold ? 'Reopen listing' : 'Mark sold'}</button>`,
      `Listing / ${mode}`);
  }

  /* ---------------------------------------------------------------- */
  /* Home                                                             */
  /* ---------------------------------------------------------------- */

  function countFor(k) {
    if (k === 'listings') { const m = marketRows(); return m.cross.length + m.exch.length; }
    if (k === 'cross') return marketRows().cross.length;
    if (k === 'exch') return marketRows().exch.length;
    return (S[k] || []).length;
  }

  function renderHome() {
    const m = marketRows();
    const latest = [...m.cross, ...m.exch].sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    table('tHome', C.tradesMini, latest.slice(0, 5), openListing);
    $('#fHome').innerHTML = S.gains.slice(0, 4).map(feed).join('') || '<li class="empty">No gains yet.</li>';
    $$('b[data-n]').forEach(el => {
      const to = countFor(el.dataset.n);
      el.textContent = n(to);
    });
  }

  const feed = g => {
    const bits = [];
    if (Number(g.lvl)) bits.push(`<b>+${n(g.lvl)} levels</b>`);
    if (Number(g.ec)) bits.push(`<span class="chip">${n(g.ec)} EC</span>`);
    if (g.message) bits.push(`<span class="muted">${esc(g.message)}</span>`);
    return `<li>${bits.join(' ')}<span class="muted">${esc(g.floor)} · ${ago(g.createdAt)}</span></li>`;
  };

  function renderQuote() {
    const q = S.quotes || [];
    const hours = Number(S.settings.quoteHours) || 0;
    const ms = hours * 36e5;
    const i = !q.length ? -1 : ms ? Math.floor(Date.now() / ms) % q.length : 0;
    const text = i < 0 ? '' : q[i].text;
    $('#quote').textContent = text ? `❝ ${text} ❞` : '';

    const now = $('#qNow');
    if (!now) return;
    if (!text) { now.textContent = 'No quotes yet. Add one under Quotes below.'; return; }
    if (!ms) { now.textContent = `Showing now: “${text}” · rotation is off.`; return; }
    const left = ms - (Date.now() % ms);
    const hrs = Math.floor(left / 36e5), mins = Math.floor(left % 36e5 / 6e4);
    const eta = hrs >= 48 ? `${Math.floor(hrs / 24)}d ${hrs % 24}h` : hrs ? `${hrs}h ${mins}m` : `${Math.max(1, mins)}m`;
    now.textContent = `Showing now: “${text}” · changes in about ${eta}.`;
  }
  setInterval(renderQuote, 30000);

  /* ---------------------------------------------------------------- */
  /* Market                                                           */
  /* ---------------------------------------------------------------- */

  /* ---------------------------------------------------------------- */
  /* Market: exchange listings are open, crosstrading goes via escrow */
  /* ---------------------------------------------------------------- */

  const CATS = { items: 'Items', equipment: 'Equipment', overlays: 'Overlays' };
  const ESCROW = Object.assign({ account: 'GildedEscrow', holdMinutes: 60, feePct: 10 }, GA.ESCROW || {});
  const itemsText = items => (items || []).map(i => `${i.name}${i.qty > 1 ? ' ×' + n(i.qty) : ''}`).join(', ');

  function categoryOf(r) {
    const entry = (r.itemId && [...S.items, ...S.equipment, ...S.overlays].find(x => x.id === r.itemId)) || findEntry(r.item);
    return CATS[entryKind(entry)] || 'Other';
  }

  function crossCategory(items) {
    const set = new Set((items || []).map(i => CATS[entryKind(findEntry(i.name))] || 'Other'));
    return set.size === 1 ? [...set][0] : 'Mixed';
  }

  /* Order rules. An order is a purchase waiting on two deposits to the escrow
     account: the seller's items and the buyer's payment. Staff confirm each
     one, then release. Everything below is derived from the stored flags, so
     nothing has to be kept in sync by hand. */

  // A reservation with nothing deposited lapses; once escrow holds anything it
  // stays open until staff release or cancel it, so no deposit is ever stranded.
  const orderExpired = o => o.stage === 'Waiting' && !o.itemsHeld && !o.payHeld && Date.parse(o.expiresAt) < Date.now();
  const orderActive = o => o.stage === 'Waiting' && !orderExpired(o);

  function orderPhase(o) {
    if (o.stage === 'Released') return 'released';
    if (o.stage === 'Cancelled') return 'cancelled';
    if (orderExpired(o)) return 'expired';
    return o.itemsHeld && o.payHeld ? 'ready' : 'waiting';
  }
  const PHASE_TEXT = { waiting: 'Waiting for deposits', ready: 'Ready to release', released: 'Complete', cancelled: 'Cancelled', expired: 'Expired' };

  const ordersOf = l => (S.orders || []).filter(o => o.listingId === l.id);
  const liveOrder = l => ordersOf(l).find(o => o.stage === 'Released') || ordersOf(l).find(orderActive) || null;

  function listingState(l) {
    if (l.cancelled) return 'gone';
    const os = ordersOf(l);
    if (os.some(o => o.stage === 'Released')) return 'sold';
    return os.some(orderActive) ? 'reserved' : 'open';
  }

  function timeLeft(iso) {
    const m = Math.max(0, Math.ceil((Date.parse(iso) - Date.now()) / 60000));
    return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m} min`;
  }

  // What the public sees of a crosstrading listing. The seller's username and
  // code are left out on purpose: this object is what tables, search and the
  // pop-up read, so anything not copied here can never leak into them.
  function publicRow(l, state) {
    return {
      id: l.id,
      mode: 'Crosstrading',
      side: 'Selling',
      code: l.code,
      items: l.items,
      item: itemsText(l.items),
      qty: l.items.reduce((s, i) => s + (Number(i.qty) || 0), 0),
      price: l.price,
      note: l.note || '',
      createdAt: l.createdAt,
      status: state === 'reserved' ? 'Reserved' : 'Available',
      cat: crossCategory(l.items)
    };
  }

  function marketRows() {
    const cross = [];
    const exch = [];
    S.listings.forEach(x => {
      if (x.mode === 'Crosstrading') {
        if (!Array.isArray(x.items)) return;
        const st = listingState(x);
        if (st === 'open' || st === 'reserved') cross.push(publicRow(x, st));
      } else if (!x.sold) {
        exch.push(Object.assign({}, x, { cat: categoryOf(x) }));
      }
    });
    return { cross, exch };
  }

  const openListing = r => (r.mode === 'Crosstrading' ? showCross(r) : showListing(r));

  function renderMarket() {
    $$('[data-fee]').forEach(el => { el.textContent = 'Crosstrading prices are in US dollars. ' + feeLine(); });
    const m = marketRows();
    table('tCross', C.cross, m.cross, showCross);
    table('tExch', C.trades, m.exch, showListing);
  }

  /* ---- Money: crosstrading is priced in US dollars, stored as whole cents ---- */

  const usd = c => '$' + ((Number(c) || 0) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // The site's cut: a percentage of the sale, taken from the seller's side. The
  // buyer always pays exactly the listed price.
  const feeOf = c => Math.round((Number(c) || 0) * (Number(ESCROW.feePct) || 0) / 100);
  // An order keeps the price and fee from the moment it was reserved, so a later
  // change to the fee never alters a trade already under way.
  function money(o, l) {
    const price = o && o.price != null ? o.price : (l ? l.price : 0);
    const pct = o && o.feePct != null ? o.feePct : (Number(ESCROW.feePct) || 0);
    const fee = o && o.fee != null ? o.fee : feeOf(price);
    return { price, pct, fee, payout: price - fee };
  }
  const feeLine = () => `Gilded Archive keeps a ${n(ESCROW.feePct)}% escrow fee on every crosstrade, taken from the seller’s side. Buyers pay exactly the listed price.`;

  /* ---- Chat with the escrow staff: one private thread per person per order ---- */

  const CHAT_KEY = 'gilded.chat';
  const SEEN_KEY = 'gilded.chatseen';
  const readJSON = k => { try { return JSON.parse(localStorage.getItem(k)) || {}; } catch (e) { return {}; } };
  const writeJSON = (k, v) => { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* private mode */ } };
  // The buyer and the seller each get their own thread with staff, so neither
  // ever sees the other's messages.
  const threadKey = (o, party) => o.id + ':' + party;
  const thread = key => readJSON(CHAT_KEY)[key] || [];

  function sendChat(key, from, text) {
    const t = String(text || '').trim().slice(0, 500);
    if (!t) return;
    const all = readJSON(CHAT_KEY);
    (all[key] = all[key] || []).push({ id: uid('m'), from, text: t, at: new Date().toISOString() });
    writeJSON(CHAT_KEY, all);
  }
  const staffCount = key => thread(key).filter(m => m.from === 'staff').length;
  const unreadFor = key => Math.max(0, staffCount(key) - (readJSON(SEEN_KEY)[key] || 0));
  function markSeen(key) { const s = readJSON(SEEN_KEY); s[key] = staffCount(key); writeJSON(SEEN_KEY, s); }

  function updateBadge() {
    const btn = $('#trackBtn');
    if (!btn) return;
    let total = 0;
    MINE.forEach(m => { const c = resolveCode(m.code); if (c && c.order) total += unreadFor(threadKey(c.order, c.role)); });
    btn.innerHTML = 'Track a trade' + (total ? ` <span class="badge" title="New messages from staff">${n(total)}</span>` : '');
  }

  function renderChat(el) {
    const { key, viewer, label } = el.dataset;
    const can = el.dataset.can === '1';
    const msgs = thread(key);
    const old = el.querySelector('input');
    const typed = old ? old.value : '';
    const hadFocus = !!old && el.contains(document.activeElement);
    el.innerHTML = `<div class="chat-log" aria-live="polite">${msgs.length
      ? msgs.map(m => `<div class="msg ${m.from === viewer ? 'me' : 'them'}"><p>${esc(m.text)}</p><small>${m.from === viewer ? 'You' : esc(label)}, ${esc(ago(m.at))}</small></div>`).join('')
      : `<p class="chat-empty">${esc(el.dataset.empty || 'No messages yet.')}</p>`}</div>
      ${can
        ? `<form class="chatf" data-key="${esc(key)}" data-viewer="${esc(viewer)}"><input name="text" maxlength="500" placeholder="Write a message" aria-label="Message" autocomplete="off" required><button class="btn s">Send</button></form>`
        : '<p class="fine">This trade is closed, so the chat is read-only.</p>'}`;
    const log = el.querySelector('.chat-log');
    log.scrollTop = log.scrollHeight;
    const inp = el.querySelector('input');
    if (inp && typed) inp.value = typed;
    if (inp && hadFocus) inp.focus();
    // Only count messages as read when the chat is actually on screen; a closed
    // dialog still holds old markup that must not mark anything as seen.
    if (viewer === 'user' && el.getClientRects().length) markSeen(key);
  }
  function renderChats() { $$('.chat').forEach(renderChat); updateBadge(); }

  document.addEventListener('submit', e => {
    const f = e.target && e.target.closest ? e.target.closest('.chatf') : null;
    if (!f) return;
    e.preventDefault();
    sendChat(f.dataset.key, f.dataset.viewer, f.elements.text.value);
    f.elements.text.value = '';
    renderChats();
    const again = document.querySelector(`.chatf[data-key="${f.dataset.key}"] input`);
    if (again) again.focus();
  });
  // A reply written in another tab shows up without a reload.
  window.addEventListener('storage', e => { if (e.key === CHAT_KEY || e.key === SEEN_KEY) renderChats(); });

  /* ---- The pop-up for one crosstrading listing ---- */

  function showCross(r) {
    if (!inspect || inspect.list[inspect.i] !== r) inspect = null;
    secN = 0;
    const reserved = r.status === 'Reserved';
    const one = r.items.length === 1;
    const fee = feeOf(r.price);
    const title = one
      ? `${esc(r.items[0].name)}${r.items[0].qty > 1 ? ` <span class="ins-qty">×${n(r.items[0].qty)}</span>` : ''}`
      : `Bundle of ${n(r.items.length)} items`;
    const list = r.items.map(it => {
      const e = findEntry(it.name);
      const k = e ? entryKind(e) : null;
      const name = k ? `<button class="linkbtn" data-jump="${k}" data-name="${esc(e.name)}">${esc(it.name)}</button>` : esc(it.name);
      return `<li><span>${name}</span><b>×${n(it.qty)}</b></li>`;
    }).join('');

    drawer(`<div class="ins-grid"><div class="ins-col">
        <header class="ins-head ins-head-l"><div>
          <h3>${title}</h3>
          <p class="ins-meta"><span class="tag ${reserved ? 'crafted' : 'shop'}">${esc(r.status)}</span><span class="ins-sub">Listing ${esc(r.code)}</span></p>
        </div></header>
        <div class="ins-price">
          <div class="total"><span>Price (USD)</span><b>${usd(r.price)}</b></div>
          <div><span>Pieces</span><b>${n(r.qty)}</b></div>
          <div><span>Posted</span><b class="ins-when">${esc(ago(r.createdAt))}</b></div>
        </div>
        ${sec('Includes', `<ul class="ins-items">${list}</ul>`)}
        ${r.note ? sec('Seller’s note', `<p class="ins-note">${esc(r.note)}</p>`) : ''}
      </div><div class="ins-col">
        ${sec('How this trade works', `<ol class="ins-flow">
          <li><b>Reserve it.</b> Give your in-game username. Only the escrow account and staff see it.</li>
          <li><b>Both sides deposit.</b> You pay ${usd(r.price)}; staff send payment details in a private chat. The seller sends the items to <code>${esc(ESCROW.account)}</code>.</li>
          <li><b>Escrow releases.</b> When both have arrived you get the items and the seller gets paid.</li>
        </ol>`)}
        ${sec('Escrow fee', `<p class="muted small">You pay exactly ${usd(r.price)}. ${esc(feeLine().replace(' Buyers pay exactly the listed price.', ''))} On this listing that is ${usd(fee)}.</p>`)}
        ${sec('Anonymous both ways', `<p class="muted small">You never see the seller and they never see you. A reservation holds for ${n(ESCROW.holdMinutes)} minutes, and you can cancel any time before something reaches escrow.</p>`)}
      </div></div>`,
      `<button class="btn" data-buy="${esc(r.id)}"${reserved ? ' disabled' : ''}>${reserved ? 'Reserved' : `Buy for ${usd(r.price)}`}</button>` +
      `<button class="btn g" data-track>Track a trade</button>`,
      'Crosstrading / Escrow');
  }

  /* ---- Buying ---- */

  function buyDialog(id) {
    const l = S.listings.find(x => x.id === id);
    if (!l || listingState(l) !== 'open') { toast('That listing is no longer available'); return; }
    dlg(`<h3>Buy ${esc(itemsText(l.items))}</h3>
      <p class="muted">The price is <b>${usd(l.price)}</b> (US dollars). You pay through escrow, not the seller, and the items are delivered by the escrow account. Once you reserve, staff message you in a private chat with how to pay.</p>
      <form method="dialog" id="bf">
        <div class="fld"><label for="bUser">Your in-game username</label>
          <input id="bUser" name="user" required maxlength="24" autocomplete="off">
          <p class="fine">Private. Only the escrow account and staff see it. The items are delivered to this account.</p></div>
        <p class="fine fee">${esc(feeLine())}</p>
        <label class="check"><input type="checkbox" name="ok" required><span>I will pay ${usd(l.price)} within ${n(ESCROW.holdMinutes)} minutes of reserving.</span></label>
        <div class="acts"><button class="btn g" value="x" formnovalidate>Cancel</button><button class="btn" value="ok">Reserve it</button></div>
      </form>`);

    $('#bf').addEventListener('submit', e => {
      if (e.submitter && e.submitter.value !== 'ok') return;
      e.preventDefault();
      const f = Object.fromEntries(new FormData(e.target));
      const user = String(f.user || '').trim().slice(0, 24);
      if (!user) return;
      const fresh = S.listings.find(x => x.id === id);
      if (!fresh || listingState(fresh) !== 'open') { $('#dlg').close(); toast('Someone reserved it first'); renderAll(); return; }
      const at = Date.now();
      const fee = feeOf(fresh.price);
      const order = {
        id: uid('o'),
        ref: 'T-' + code(4),
        listingId: fresh.id,
        buyerUser: user,
        sellerUser: fresh.sellerUser || '',
        buyerCode: newCode('B'),
        price: fresh.price,
        feePct: Number(ESCROW.feePct) || 0,
        fee,
        handler: '',
        itemsHeld: false,
        payHeld: false,
        stage: 'Waiting',
        staffNote: '',
        createdAt: new Date(at).toISOString(),
        expiresAt: new Date(at + ESCROW.holdMinutes * 60000).toISOString()
      };
      S.orders.unshift(order);
      MINE.unshift({ code: order.buyerCode, role: 'buyer' });
      save(); saveMine(); renderAll();
      trackDialog(order.buyerCode, true);
    });
  }

  /* ---- Selling ---- */

  const itemRow = (it = {}) => `<div class="irow">
      <input data-i="name" list="itemList" value="${esc(it.name || '')}" placeholder="Item name" aria-label="Item name" autocomplete="off">
      <input data-i="qty" type="number" min="1" step="1" value="${it.qty || 1}" aria-label="Quantity">
      <button type="button" class="btn d s" data-irow-del aria-label="Remove item">×</button>
    </div>`;

  function postCrossDialog() {
    const names = [...S.items, ...S.equipment, ...S.overlays].map(x => `<option value="${esc(x.name)}"></option>`).join('');
    dlg(`<h3>Sell through escrow</h3>
      <p class="muted">Post the items and one price in US dollars. Buyers never see who you are and you never deal with them: the escrow account moves everything.</p>
      <form method="dialog" id="cf">
        <div class="fld"><label>What are you selling?</label>
          <div class="irows" data-irows>${itemRow()}</div>
          <button type="button" class="btn g s" data-irow-add>Add another item</button>
          <datalist id="itemList">${names}</datalist></div>
        <div class="fld"><label for="cPrice">Price for everything (US$)</label>
          <div class="money"><span>$</span><input id="cPrice" name="price" type="number" min="1" step="0.01" inputmode="decimal" required placeholder="0.00"></div>
          <p class="fine fee" id="cFee">${esc(feeLine())}</p></div>
        <div class="fld"><label for="cUser">Your in-game username</label>
          <input id="cUser" name="user" required maxlength="24" autocomplete="off">
          <p class="fine">Private. Never shown on the site. You send the items from this account.</p></div>
        <div class="fld"><label for="cNote">Note (optional)</label><input id="cNote" name="note" maxlength="80" placeholder="Shown on the listing, e.g. event leftovers"></div>
        <div class="acts"><button class="btn g" value="x" formnovalidate>Cancel</button><button class="btn" value="ok">Post listing</button></div>
      </form>`);

    const form = $('#cf');
    // Show the seller what they will actually receive, as they type the price.
    form.querySelector('#cPrice').addEventListener('input', e => {
      const cents = Math.round(parseFloat(e.target.value) * 100);
      $('#cFee').textContent = cents > 0
        ? `${n(ESCROW.feePct)}% escrow fee: ${usd(feeOf(cents))}. You receive ${usd(cents - feeOf(cents))}.`
        : feeLine();
    });
    form.addEventListener('click', e => {
      const box = form.querySelector('[data-irows]');
      if (e.target.closest('[data-irow-add]')) {
        if (box.children.length < 8) box.insertAdjacentHTML('beforeend', itemRow());
        else toast('Eight items at most per listing');
        const last = box.lastElementChild; if (last) last.querySelector('input').focus();
      }
      const del = e.target.closest('[data-irow-del]');
      if (del) {
        if (box.children.length > 1) del.closest('.irow').remove();
        else del.closest('.irow').querySelectorAll('input').forEach(i => { i.value = i.dataset.i === 'qty' ? 1 : ''; });
      }
    });

    form.addEventListener('submit', e => {
      if (e.submitter && e.submitter.value !== 'ok') return;
      e.preventDefault();
      const f = Object.fromEntries(new FormData(form));
      const items = $$('.irow', form).map(r => {
        const typed = r.querySelector('[data-i="name"]').value.trim();
        const found = findEntry(typed);
        return { name: found ? found.name : typed, qty: Math.max(1, Math.floor(+r.querySelector('[data-i="qty"]').value) || 1) };
      }).filter(i => i.name);
      const user = String(f.user || '').trim().slice(0, 24);
      const cents = Math.round(parseFloat(f.price) * 100) || 0;
      if (!items.length) { toast('Add at least one item'); return; }
      if (cents < 100) { toast('The minimum price is $1.00'); return; }
      if (!user) return;
      const listing = {
        id: uid('l'),
        mode: 'Crosstrading',
        side: 'Selling',
        code: code(4),
        items,
        item: itemsText(items),
        qty: items.reduce((s, i) => s + i.qty, 0),
        price: cents,
        currency: 'USD',
        note: String(f.note || '').trim().slice(0, 80),
        sellerUser: user,
        sellerCode: newCode('S'),
        createdAt: new Date().toISOString()
      };
      S.listings.unshift(listing);
      MINE.unshift({ code: listing.sellerCode, role: 'seller' });
      save(); saveMine(); renderAll();
      showPane('pCross');
      trackDialog(listing.sellerCode, true);
    });
  }

  /* ---- Tracking a trade by code ---- */

  function resolveCode(raw) {
    const c = String(raw || '').trim().toUpperCase();
    if (!c) return null;
    const l = S.listings.find(x => x.sellerCode === c);
    if (l) return { role: 'seller', code: c, listing: l, order: liveOrder(l) };
    const o = (S.orders || []).find(x => x.buyerCode === c);
    if (o) return { role: 'buyer', code: c, listing: S.listings.find(x => x.id === o.listingId) || null, order: o };
    return null;
  }

  function statusOf(ctx) {
    const l = ctx.listing, o = ctx.order;
    if (!l) return 'Gone';
    if (ctx.role === 'seller') {
      if (l.cancelled) return 'Cancelled';
      return o ? PHASE_TEXT[orderPhase(o)] : 'Live, waiting for a buyer';
    }
    return PHASE_TEXT[orderPhase(o)];
  }

  const stepHtml = s => `<li class="${s.s}"><i></i><div><b>${s.t}</b>${s.d ? `<small>${s.d}</small>` : ''}</div></li>`;

  function tradeSteps(ctx) {
    const l = ctx.listing, o = ctx.order;
    const m = money(o, l);
    const phase = o ? orderPhase(o) : null;
    const live = phase === 'waiting' || phase === 'ready';
    const done = phase === 'released';
    const held = !!(o && o.itemsHeld), paid = !!(o && o.payHeld);
    const hold = o && !held && !paid && live ? ` Your reservation holds for ${timeLeft(o.expiresAt)}.` : '';
    const acct = `<code>${esc(ESCROW.account)}</code>`;
    if (ctx.role === 'seller') {
      return [
        { t: 'Listed', d: `Anonymous listing ${esc(l.code)}. If it sells you receive ${usd(m.payout)}: ${usd(m.price)} minus the ${n(m.pct)}% escrow fee (${usd(m.fee)}).`, s: 'done' },
        { t: o ? 'A buyer reserved it' : 'Waiting for a buyer', d: o ? '' : 'You do not need to do anything yet.', s: o ? 'done' : 'now' },
        { t: `Send the items to ${acct}`, d: o ? `${esc(itemsText(l.items))}, from ${esc(l.sellerUser)}.${held ? '' : hold}` : '', s: held ? 'done' : live ? 'now' : 'todo' },
        { t: 'Escrow holds the buyer’s payment', d: o && held && !paid ? 'Waiting on the buyer.' : '', s: paid ? 'done' : 'todo' },
        { t: `You are paid ${usd(m.payout)}`, d: 'Staff will agree how to pay you in the chat below.', s: done ? 'done' : phase === 'ready' ? 'now' : 'todo' }
      ];
    }
    return [
      { t: 'Reserved', d: `Reference ${esc(o.ref)}.`, s: 'done' },
      { t: `Pay ${usd(m.price)}`, d: `Staff will send payment details in the chat below.${paid ? '' : hold}`, s: paid ? 'done' : live ? 'now' : 'todo' },
      { t: 'Escrow holds the seller’s items', d: paid && !held ? 'Waiting on the seller.' : '', s: held ? 'done' : 'todo' },
      { t: 'You receive the items', d: `${l ? esc(itemsText(l.items)) : ''}, delivered to ${esc(o.buyerUser)}.`, s: done ? 'done' : phase === 'ready' ? 'now' : 'todo' }
    ];
  }

  function tradeCard(ctx, fresh) {
    const l = ctx.listing, o = ctx.order;
    if (!l) return '<p class="formnote">That trade no longer exists on this device.</p>';
    const m = money(o, l);
    const phase = o ? orderPhase(o) : null;
    const held = !!(o && (o.itemsHeld || o.payHeld));
    const sellerGone = ctx.role === 'seller' && l.cancelled;
    const buyerClosed = ctx.role === 'buyer' && (phase === 'cancelled' || phase === 'expired');
    let body;
    if (sellerGone) body = '<p class="tr-banner">You cancelled this listing.</p>';
    else if (buyerClosed) {
      body = `<p class="tr-banner">${phase === 'expired' ? 'This reservation expired. Nothing had been sent, so there is nothing to refund.' : 'This purchase was cancelled.'} If you did send something, staff will return it to you.</p>`;
    } else {
      body = `${phase === 'released' ? '<p class="tr-banner ok">Trade complete. Both sides have been paid out.</p>' : ''}<ol class="tr-steps">${tradeSteps(ctx).map(stepHtml).join('')}</ol>`;
    }

    let cancel = '';
    if (!sellerGone && phase !== 'released' && !buyerClosed) {
      if (held) cancel = '<p class="muted small">Escrow already holds something for this trade, so only staff can cancel it now.</p>';
      else cancel = `<button class="btn d s" data-cancel-trade="${ctx.role}" data-code="${esc(ctx.code)}">${ctx.role === 'seller' ? (o ? 'Cancel this sale' : 'Cancel listing') : 'Cancel purchase'}</button>`;
    }

    // Each person talks to staff in a thread of their own. Staff are the only
    // other reader, so buyer and seller stay anonymous to each other.
    let chat = '';
    const who = o ? (o.handler || 'Escrow staff') : '';
    if (o && !sellerGone && (orderActive(o) || thread(threadKey(o, ctx.role)).length)) {
      chat = `<p class="lab spaced">Chat with ${esc(who)}</p>
        <div class="chat" data-key="${esc(threadKey(o, ctx.role))}" data-viewer="user" data-label="${esc(who)}" data-can="${orderActive(o) ? 1 : 0}"
          data-empty="Ask anything about this trade, like how to pay. Only staff can read this chat; the other side never can."></div>`;
    } else if (ctx.role === 'seller' && !sellerGone) {
      chat = '<p class="fine">A private chat with the escrow staff opens here as soon as a buyer reserves your listing.</p>';
    }

    return `<div class="tr-top"><span class="tr-role">${ctx.role === 'seller' ? 'You are selling' : 'You are buying'}</span>
        <h4>${esc(itemsText(l.items))}</h4><p class="muted">${usd(m.price)} · ${esc(statusOf(ctx))}</p></div>
      <div class="tr-code"><span>Your code</span><code>${esc(ctx.code)}</code><button class="btn g s" data-copy="${esc(ctx.code)}">Copy</button></div>
      ${fresh ? '<p class="formnote">Save this code. It is the only way back to this trade, and nobody can look it up for you.</p>' : ''}
      ${body}${chat}${cancel ? `<div class="tr-cancel">${cancel}</div>` : ''}`;
  }

  function trackDialog(codeIn = '', fresh = false) {
    const ctx = codeIn ? resolveCode(codeIn) : null;
    const mine = MINE.map(m => ({ m, c: resolveCode(m.code) })).filter(x => x.c && (!ctx || x.m.code !== ctx.code));
    dlg(`<div class="track"><h3>${ctx ? 'Your trade' : 'Track a trade'}</h3>
      ${ctx ? tradeCard(ctx, fresh) : '<p class="muted">Enter the code you were given when you posted or bought. Seller codes start with S-, buyer codes with B-.</p>'}
      ${codeIn && !ctx ? '<p class="formnote">No trade matches that code on this device. Check it and try again.</p>' : ''}
      ${ctx ? '<p class="lab spaced">Look up another code</p>' : ''}
      <form id="trf" class="trf"><input name="code" placeholder="S-XXXX-XXXX" aria-label="Trade code" autocomplete="off" spellcheck="false"><button class="btn g">Find</button></form>
      ${mine.length ? `<p class="lab spaced">Your trades on this device</p><ul class="tr-mine">${mine.map(x => {
        const un = x.c.order ? unreadFor(threadKey(x.c.order, x.c.role)) : 0;
        return `<li><button data-track-code="${esc(x.m.code)}"><span>${x.m.role === 'seller' ? 'Selling' : 'Buying'}: ${esc(itemsText(x.c.listing ? x.c.listing.items : []))}</span><small>${un ? `<b class="new">${n(un)} new</b> ` : ''}${esc(statusOf(x.c))}</small></button></li>`;
      }).join('')}</ul>` : ''}
      <form method="dialog" class="acts"><button class="btn g">Close</button></form></div>`);
    $('#trf').addEventListener('submit', e => {
      e.preventDefault();
      trackDialog(new FormData(e.target).get('code'));
    });
    renderChats();
  }

  function cancelTrade(role, codeIn) {
    const ctx = resolveCode(codeIn);
    if (!ctx || !ctx.listing) return;
    const o = ctx.order;
    if (o && (o.itemsHeld || o.payHeld)) { toast('Escrow holds something already. Staff must cancel this one.'); return; }
    if (role === 'seller') {
      S.orders = S.orders.map(x => (x.listingId === ctx.listing.id && x.stage === 'Waiting' ? Object.assign({}, x, { stage: 'Cancelled' }) : x));
      S.listings = S.listings.map(x => (x.id === ctx.listing.id ? Object.assign({}, x, { cancelled: true }) : x));
    } else if (o) {
      S.orders = S.orders.map(x => (x.id === o.id ? Object.assign({}, x, { stage: 'Cancelled' }) : x));
    }
    save(); renderAll();
    trackDialog(codeIn);
    toast('Cancelled');
  }

  /* ---- Staff: the order's chat window, both threads side by side ---- */

  function staffChat(orderId) {
    const o = S.orders.find(x => x.id === orderId);
    if (!o) return;
    const l = S.listings.find(x => x.id === o.listingId);
    const m = money(o, l);
    const part = (party, name) => `<p class="lab spaced">${party === 'seller' ? 'Seller' : 'Buyer'}${name ? ` (${esc(name)})` : ''}</p>
      <div class="chat" data-key="${esc(threadKey(o, party))}" data-viewer="staff" data-label="${party === 'seller' ? 'Seller' : 'Buyer'}" data-can="1"
        data-empty="${party === 'seller' ? 'The seller' : 'The buyer'} has not written yet."></div>`;
    dlg(`<div class="track"><h3>Chat for ${esc(o.ref)}</h3>
      <p class="muted">${esc(l ? itemsText(l.items) : '')}<br>${usd(m.price)} sale, ${usd(m.fee)} fee (${n(m.pct)}%), ${usd(m.payout)} to the seller. ${esc(PHASE_TEXT[orderPhase(o)])}.</p>
      ${part('seller', o.sellerUser)}${part('buyer', o.buyerUser)}
      <p class="fine">Each person only ever sees their own thread with you. Set the name they see under Edit, in the “Handled by” field.</p>
      <form method="dialog" class="acts"><button class="btn g">Close</button></form></div>`);
    renderChats();
  }

  /* ---- Staff: moving an order along ---- */

  function staffOrder(id, action) {
    const o = S.orders.find(x => x.id === id);
    if (!o) return;
    if (action === 'chat') { staffChat(id); return; }
    let patch = null;
    if (action === 'items') patch = { itemsHeld: !o.itemsHeld };
    else if (action === 'pay') patch = { payHeld: !o.payHeld };
    else if (action === 'release') {
      if (!(o.itemsHeld && o.payHeld) && !confirm('Only part of this order has been deposited. Release it anyway?')) return;
      patch = { stage: 'Released' };
    } else if (action === 'cancel') {
      if (!confirm('Cancel this order? Return anything escrow is holding to its owner first.')) return;
      patch = { stage: 'Cancelled' };
    }
    if (!patch) return;
    S.orders = S.orders.map(x => (x.id === id ? Object.assign({}, x, patch) : x));
    save(); renderAll();
    toast(action === 'release' ? 'Order released' : action === 'cancel' ? 'Order cancelled' : 'Order updated');
  }

  /* ---- In-game exchange: the open kind, traders message each other ---- */

  function postDialog() {
    const names = [...S.items, ...S.equipment, ...S.overlays]
      .map(x => `<option value="${esc(x.name)}"></option>`).join('');
    dlg(`<h3>Post an exchange listing</h3><p class="muted">No account needed. Exchange listings are open: add your in-game username so people can message you.</p>
      <form method="dialog" id="pf">
        <div class="fld"><label for="pSide">I am</label><select id="pSide" name="side"><option>Selling</option><option>Buying</option></select></div>
        <div class="fld"><label for="pItem">Item</label><input id="pItem" name="item" list="itemList" required autocomplete="off" placeholder="Start typing a name..."><datalist id="itemList">${names}</datalist></div>
        <div class="frow">
          <div class="fld"><label for="pQty">Quantity</label><input id="pQty" name="qty" type="number" min="1" step="1" value="1" required></div>
          <div class="fld"><label for="pPrice">Price each</label><input id="pPrice" name="price" type="number" min="0" step="1" required></div>
        </div>
        <div class="fld"><label for="pUser">Your in-game username</label><input id="pUser" name="user" required maxlength="24" autocomplete="off"></div>
        <div class="fld"><label for="pNote">Note (optional)</label><input id="pNote" name="note" maxlength="80" placeholder="e.g. online evenings, will haggle"></div>
        <div class="acts"><button class="btn g" value="x" formnovalidate>Cancel</button><button class="btn" value="ok">Post listing</button></div>
      </form>`);

    $('#pf').addEventListener('submit', e => {
      if (e.submitter && e.submitter.value !== 'ok') return;
      e.preventDefault();
      const f = Object.fromEntries(new FormData(e.target));
      const name = String(f.item || '').trim();
      if (!name) return;
      const entry = findEntry(name);
      S.listings.unshift({
        id: uid('l'),
        itemId: entry ? entry.id : null,
        item: entry ? entry.name : name,
        mode: 'Exchange',
        side: f.side,
        qty: Math.max(1, Math.floor(+f.qty) || 1),
        price: Math.max(0, Math.floor(+f.price) || 0),
        user: String(f.user || '').trim().slice(0, 24),
        note: String(f.note || '').trim().slice(0, 80),
        createdAt: new Date().toISOString(),
        sold: false
      });
      save();
      renderAll();
      showPane('pExch');
      $('#dlg').close();
      toast('Listing posted');
    });
  }

  /* ---------------------------------------------------------------- */
  /* Databases                                                        */
  /* ---------------------------------------------------------------- */

  function renderDB() {
    table('tItems', C.items, S.items, showItem);
    table('tEquip', C.equipment, S.equipment, showEquip);
    table('tOver', C.overlays, S.overlays, showOverlay);
  }

  /* ---------------------------------------------------------------- */
  /* Script guide                                                     */
  /* ---------------------------------------------------------------- */

  let floorId = null;

  function renderGuide() {
    $('#loadCode').textContent = LOADSTRING;
    const dl = $('#downloadScript');
    dl.href = RAW;
    dl.setAttribute('target', '_blank');
    dl.setAttribute('rel', 'noopener');

    const floors = S.floors || [];
    if (!floorId || !floors.some(f => f.id === floorId)) floorId = floors[0] ? floors[0].id : null;
    $('#floorTabs').innerHTML = floors.map(f =>
      `<button data-floor="${esc(f.id)}" class="${f.id === floorId ? 'on' : ''}" aria-pressed="${f.id === floorId}">${esc(f.name)}</button>`).join('');
    $('#floorList').innerHTML = floors.map(f => `<option value="${esc(f.name)}"></option>`).join('');
    renderFloor();
    $('#fWall').innerHTML = S.gains.map(feed).join('') || '<li class="empty">No gains posted yet.</li>';
  }

  function renderFloor() {
    const f = (S.floors || []).find(x => x.id === floorId);
    const box = $('#floorPanel');
    if (!f) { box.innerHTML = '<p class="muted">No floors yet. Add one in the staff panel.</p>'; return; }
    const targets = String(f.targets || '').split(',').map(t => t.trim()).filter(Boolean);
    box.innerHTML = `
      <h4>${esc(f.name)}${f.place && f.place !== '—' ? ` <span class="chip">${esc(f.place)}</span>` : ''}</h4>
      <p class="lbl">Targets</p>
      <div class="chips inline">${targets.map(t => `<span class="chip">${esc(t)}</span>`).join('') || '<span class="muted">None set.</span>'}</div>
      <p><b>Route</b> ${esc(f.route || '—')}</p>
      <p><b>Notes</b> ${esc(f.notes || '—')}</p>`;
  }

  /* ---------------------------------------------------------------- */
  /* Staff                                                            */
  /* ---------------------------------------------------------------- */

  const authed = () => sessionStorage.getItem(STAFF_KEY) === '1';
  let adminKind = 'items';

  function renderStaff() {
    const gate = $('#gate');
    const panel = $('#staffPanel');
    const open = authed();
    gate.hidden = open;
    panel.hidden = !open;
    if (!open) return;

    $('#qRot').value = String(Number(S.settings.quoteHours) || 0);
    renderQuote();

    $('#kinds').innerHTML = Object.keys(GA.SCHEMA).map(k =>
      `<button data-kind="${k}" class="${k === adminKind ? 'on' : ''}">${esc(GA.SCHEMA[k].plural)}</button>`).join('');
    renderAdmin();
  }

  function adminCell(v) {
    if (Array.isArray(v)) return n(v.length) + ' rows';
    if (typeof v === 'boolean') return v ? 'yes' : 'no';
    if (typeof v === 'number') return n(v);
    return esc(v);
  }

  function renderAdmin() {
    const spec = GA.SCHEMA[adminKind];
    let cols = spec.adminCols.map(k => {
      const f = spec.fields.find(x => x.k === k);
      return { k, t: f ? f.label : k, f: v => (typeof v === 'number' ? n(v) : adminCell(v)) };
    });
    if (adminKind === 'listings') {
      cols = cols.map(c => (c.k === 'price' ? Object.assign({}, c, { f: (v, r) => (r.mode === 'Crosstrading' ? usd(v) : n(v)) }) : c));
    }
    if (adminKind === 'orders') {
      const flag = (act, on) => (r => (r.stage === 'Waiting'
        ? `<button class="btn ${on(r) ? '' : 'g'} s" data-ord="${act}">${on(r) ? '✓ Received' : 'Mark received'}</button>`
        : (on(r) ? 'Held' : '—')));
      cols = [
        { k: 'ref', t: 'Order', f: v => `<span class="nm">${esc(v)}</span>` },
        { k: 'stage', t: 'Status', f: (v, r) => esc(PHASE_TEXT[orderPhase(r)]) },
        { k: 'itemsHeld', t: 'Items in', f: (v, r) => flag('items', x => x.itemsHeld)(r) },
        { k: 'payHeld', t: 'Payment in', f: (v, r) => flag('pay', x => x.payHeld)(r) },
        { k: 'price', t: 'Sale', f: (v, r) => { const m = money(r, S.listings.find(x => x.id === r.listingId)); return `${usd(m.price)}<br><span class="dim small">fee ${usd(m.fee)}</span>`; } },
        { k: 'sellerUser', t: 'Seller', f: esc },
        { k: 'buyerUser', t: 'Buyer', f: esc },
        { k: 'handler', t: 'Handled by', f: v => (v ? esc(v) : '<span class="dim">Unassigned</span>') },
        { k: 'id', t: 'Chat', f: (v, r) => {
          const keys = [threadKey(r, 'seller'), threadKey(r, 'buyer')];
          const total = keys.reduce((s, k) => s + thread(k).length, 0);
          const need = keys.some(k => { const t = thread(k); return t.length && t[t.length - 1].from === 'user'; });
          return `<button class="btn ${need ? '' : 'g'} s" data-ord="chat">${need ? 'Reply needed' : total ? `Chat (${n(total)})` : 'Chat'}</button>`;
        } },
        { k: '_r', t: '', f: (v, r) => (r.stage === 'Waiting'
          ? '<button class="btn s" data-ord="release">Release</button> <button class="btn d s" data-ord="cancel">Cancel</button>' : '') }
      ];
    }
    cols.push({
      k: '_', t: '', f: () =>
        '<button class="btn g s" data-act="edit">Edit</button> <button class="btn d s" data-act="del">Remove</button>'
    });
    table('tAdmin', cols, S[adminKind] || []);
  }

  function blank(kind) {
    const o = { id: '' };
    GA.SCHEMA[kind].fields.forEach(f => {
      if (f.type === 'number') o[f.k] = 0;
      else if (f.type === 'drops') o[f.k] = [];
      else if (f.type === 'select') o[f.k] = f.options[0];
      else o[f.k] = '';
    });
    return o;
  }

  function inputField(f, v) {
    const id = 'e_' + f.k;
    const label = `<label for="${id}">${esc(f.label)}</label>`;
    if (f.type === 'textarea') {
      return `<div class="fld wide">${label}<textarea id="${id}" name="${f.k}" rows="2">${esc(v)}</textarea></div>`;
    }
    if (f.type === 'select') {
      return `<div class="fld">${label}<select id="${id}" name="${f.k}">${f.options.map(o =>
        `<option value="${esc(o)}"${String(v) === o ? ' selected' : ''}>${o ? esc(o) : 'Not set'}</option>`).join('')}</select></div>`;
    }
    if (f.type === 'number') {
      return `<div class="fld">${label}<input id="${id}" name="${f.k}" type="number" step="1" value="${esc(typeof v === 'boolean' ? (v ? 1 : 0) : v)}"></div>`;
    }
    const list = f.list === 'itemCategories' ? ` list="catList"` : '';
    return `<div class="fld${f.k === 'name' ? ' wide' : ''}">${label}<input id="${id}" name="${f.k}" value="${esc(v)}"${list}${f.required ? ' required' : ''}></div>`;
  }

  function dropRow(d) {
    return `<div class="drow">
      <input data-d="mob" list="mobList" value="${esc(d.mob || '')}" placeholder="Mob" aria-label="Mob">
      <input data-d="oneIn" type="number" min="1" step="1" value="${d.oneIn || ''}" placeholder="1 in N" aria-label="One in N">
      <input data-d="rolls" type="number" min="1" step="1" value="${d.rolls || 1}" placeholder="Rolls" aria-label="Rolls">
      <button type="button" class="btn d s" data-drop-del aria-label="Remove drop">×</button>
    </div>`;
  }

  function dropEditor(drops) {
    return `<div class="fld wide"><label>Drops</label>
      <div class="drops-edit" data-drops>${(drops && drops.length ? drops : [{}]).map(dropRow).join('')}</div>
      <button type="button" class="btn g s" data-drop-add>Add drop</button>
      <p class="muted small">One line per mob. “1 in N” is the game’s roll, Rolls is how many times it rolls.</p>
    </div>`;
  }

  function editEntry(kind, id) {
    const spec = GA.SCHEMA[kind];
    const isNew = !id;
    const row = isNew ? blank(kind) : (S[kind] || []).find(x => x.id === id);
    if (!row) return;

    const fields = spec.fields.map(f => (f.type === 'drops' ? dropEditor(row[f.k]) : inputField(f, row[f.k] ?? ''))).join('');
    dlg(`<h3>${isNew ? 'Add' : 'Edit'} ${esc(spec.label.toLowerCase())}</h3>
      <form method="dialog" id="ef" class="gridform">
        ${fields}
        <datalist id="mobList">${GA.MOBS.map(m => `<option value="${esc(m)}"></option>`).join('')}</datalist>
        <datalist id="catList">${GA.ITEM_CATEGORIES.map(c => `<option value="${esc(c)}"></option>`).join('')}</datalist>
        <div class="acts"><button class="btn g" value="x" formnovalidate>Cancel</button><button class="btn" value="ok">Save changes</button></div>
      </form>`);

    const form = $('#ef');
    form.addEventListener('click', e => {
      if (e.target.closest('[data-drop-add]')) {
        const box = form.querySelector('[data-drops]');
        box.insertAdjacentHTML('beforeend', dropRow({}));
      }
      if (e.target.closest('[data-drop-del]')) {
        const rows = form.querySelectorAll('[data-drops] .drow');
        const rowEl = e.target.closest('.drow');
        if (rows.length > 1) rowEl.remove();
        else rowEl.querySelectorAll('input').forEach(i => { i.value = ''; });
      }
    });

    form.addEventListener('submit', e => {
      if (e.submitter && e.submitter.value !== 'ok') return;
      e.preventDefault();
      const data = Object.fromEntries(new FormData(form));

      spec.fields.forEach(f => {
        if (f.type === 'drops') return;
        if (f.type === 'number') data[f.k] = Math.max(0, Math.floor(Number(data[f.k]) || 0));
        else data[f.k] = String(data[f.k] || '').trim();
      });

      const req = spec.fields.find(f => f.required);
      if (req && !data[req.k]) return;

      if (spec.fields.some(f => f.type === 'drops')) {
        data.drops = $$('[data-drops] .drow', form).map(r => ({
          mob: r.querySelector('[data-d="mob"]').value.trim(),
          oneIn: Math.max(1, Math.floor(Number(r.querySelector('[data-d="oneIn"]').value) || 0)),
          rolls: Math.max(1, Math.floor(Number(r.querySelector('[data-d="rolls"]').value) || 1))
        })).filter(d => d.mob && Number(d.oneIn) > 0);
      }

      data.id = row.id || uid(kind.slice(0, 1));
      if (kind === 'listings') data.createdAt = row.createdAt || new Date().toISOString();
      if (kind === 'gains') data.createdAt = row.createdAt || new Date().toISOString();
      if (kind === 'listings') data.sold = !!Number(data.sold);
      if (kind === 'orders') { data.itemsHeld = !!Number(data.itemsHeld); data.payHeld = !!Number(data.payHeld); }

      if (isNew) S[kind].push(data);
      else S[kind] = S[kind].map(x => (x.id === row.id ? Object.assign({}, x, data) : x));

      save();
      renderAll();
      $('#dlg').close();
      toast(isNew ? 'Entry added' : 'Entry saved');
    });
  }

  $('#gateForm').addEventListener('submit', e => {
    e.preventDefault();
    const msg = $('#gateMsg');
    if ($('#gatePw').value === GA.PASS) {
      sessionStorage.setItem(STAFF_KEY, '1');
      $('#gatePw').value = '';
      msg.hidden = true;
      renderStaff();
      toast('Unlocked');
    } else {
      msg.hidden = false;
      msg.textContent = 'That passcode is not right.';
      $('#gatePw').select();
    }
  });

  /* ---------------------------------------------------------------- */
  /* Login / signup (layout only)                                     */
  /* ---------------------------------------------------------------- */

  function loginMethod(m) {
    $$('#lm button').forEach(b => b.classList.toggle('on', b.dataset.lm === m));
    const acts = go => `<div class="acts"><button class="btn g" value="x" formnovalidate>Cancel</button><button class="btn" value="ok">${go}</button></div>`;
    $('#lf').innerHTML = m === 'Email'
      ? `<div class="fld"><label>Email</label><input name="email" type="email" required autocomplete="email"></div>
         <div class="fld"><label>Password</label><input name="pw" type="password" required autocomplete="current-password"></div>${acts('Log in')}`
      : `<p class="muted">You would be sent to ${m} to confirm your login.</p>${acts('Continue with ' + m)}`;
  }

  function loginDlg() {
    dlg(`<h3>Log in</h3>
      <div class="seg bar" id="lm">${['Email', 'Google', 'Discord', 'Roblox'].map((m, i) =>
        `<button type="button" data-lm="${m}" class="${i ? '' : 'on'}">${m}</button>`).join('')}</div>
      <form method="dialog" id="lf"></form>
      <p class="formnote">Accounts are not live yet. Posting a listing or a gain needs no sign-in.</p>
      <p class="muted">New here? <a href="#signup" data-signup>Sign Up</a></p>`);
    loginMethod('Email');
    $('#lf').addEventListener('submit', e => {
      e.preventDefault();
      $('#dlg').close();
      toast('Accounts are not live yet — no sign-in needed to post.');
    });
  }

  /* ---------------------------------------------------------------- */
  /* Search                                                           */
  /* ---------------------------------------------------------------- */

  const SEC = { items: 'Item', equipment: 'Equipment', overlays: 'Overlay', floors: 'Floor' };

  $('#gs').addEventListener('input', e => {
    const q = e.target.value.toLowerCase().trim();
    const sr = $('#sr');
    if (!q) { sr.classList.remove('on'); sr.innerHTML = ''; return; }
    const hits = [['items', S.items], ['equipment', S.equipment], ['overlays', S.overlays], ['floors', S.floors]]
      .flatMap(([k, arr]) => (arr || []).filter(x => `${x.name} ${x.type || ''} ${x.source || ''} ${x.desc || ''} ${x.targets || ''}`.toLowerCase().includes(q)).map(x => [k, x.name]))
      .slice(0, 8);
    sr.innerHTML = hits.map(([k, name]) =>
      `<button data-sec="${k}" data-name="${esc(name)}">${esc(name)}<span class="chip">${SEC[k]}</span></button>`).join('')
      || '<div class="empty">No items, equipment, overlays or floors match.</div>';
    sr.classList.add('on');
  });

  $('#gs').addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      const first = $('#sr button');
      if (first) { e.preventDefault(); first.click(); }
    }
  });

  /* ---------------------------------------------------------------- */
  /* Navigation                                                       */
  /* ---------------------------------------------------------------- */

  const PANES = { items: 'pItems', equipment: 'pEquip', overlays: 'pOver' };
  const SPOT = { items: ['database', 'pItems'], equipment: ['database', 'pEquip'], overlays: ['database', 'pOver'], market: ['market', 'pCross'] };
  const KIND_OF_PANE = { pItems: 'items', pEquip: 'equipment', pOver: 'overlays' };

  function showPane(id, remember = true) {
    const pane = $('#' + id);
    if (!pane) return;
    const view = pane.closest('.view');
    $$(':scope > .pane', view).forEach(p => p.classList.toggle('on', p === pane));
    $$('.tabs button', view).forEach(b => b.classList.toggle('on', b.dataset.tab === id));
    if (id === 'pCross' || id === 'pExch') $('#trackBtn').hidden = id === 'pExch';
    if (remember) {
      const kind = KIND_OF_PANE[id];
      if (kind) history.replaceState(null, '', '#database/' + kind);
    }
  }

  function go(page, pane) {
    const view = document.getElementById(page);
    if (!view) return;
    $$('.view').forEach(v => v.classList.toggle('on', v === view));
    if (pane) showPane(pane, false);
    history.replaceState(null, '', '#' + page + (pane && KIND_OF_PANE[pane] ? '/' + KIND_OF_PANE[pane] : ''));
    hideDrawer();
    scrollTo(0, 0);
  }

  function route() {
    const raw = decodeURIComponent(location.hash.replace(/^#/, '') || 'home');
    const [page, sub] = raw.split('/');
    let target = page;
    let detail = null;

    if (page === 'item' || page === 'gear' || page === 'overlay') {
      const kind = page === 'item' ? 'items' : page === 'gear' ? 'equipment' : 'overlays';
      target = 'database';
      detail = { kind, id: sub };
    } else if (page === 'database' && PANES[sub]) {
      target = 'database';
    }

    const view = document.getElementById(target);
    const safe = view && view.classList.contains('view') ? target : 'home';
    $$('.view').forEach(v => v.classList.toggle('on', v.id === safe));
    $$('#nav a').forEach(a => a.classList.toggle('on', a.getAttribute('href') === '#' + safe));

    if (safe === 'staff') renderStaff();

    if (detail) {
      showPane(PANES[detail.kind], false);
      const rec = (S[detail.kind] || []).find(x => x.id === detail.id);
      if (rec) {
        if (detail.kind === 'items') showItem(rec);
        else if (detail.kind === 'equipment') showEquip(rec);
        else showOverlay(rec);
      }
    } else {
      if (safe === 'database' && PANES[sub]) showPane(PANES[sub], false);
      hideDrawer();
    }
    scrollTo(0, 0);
  }

  function jump(kind, name) {
    if (kind === 'floors') {
      const f = (S.floors || []).find(x => x.name === name);
      if (f) floorId = f.id;
      go('script');
      renderGuide();
      return;
    }
    const [page, pane] = SPOT[kind];
    go(page, pane);
    const ids = kind === 'market' ? ['pCross', 'pExch'] : [pane];
    ids.forEach(id => {
      const input = $('#' + id + ' .f');
      const t = T[input.dataset.t];
      if (!t) return;
      t.fil = {};
      t.q = String(name || '').toLowerCase();
      t.page = 1;
      input.value = name || '';
      draw(input.dataset.t);
    });
    chips();
  }

  /* ---------------------------------------------------------------- */
  /* Events                                                           */
  /* ---------------------------------------------------------------- */

  document.addEventListener('input', e => {
    const input = e.target.closest('.f');
    if (!input) return;
    const t = T[input.dataset.t];
    if (!t) return;
    t.q = input.value.toLowerCase();
    t.page = 1;
    draw(input.dataset.t);
    chips();
  });

  document.addEventListener('keydown', e => {
    if (e.key !== 'Enter' && e.key !== ' ') return;
    const row = e.target.closest('tr[data-id]');
    const th = e.target.closest('th[data-k]');
    if (row && e.target === row) { e.preventDefault(); row.click(); }
    else if (th && e.target === th) { e.preventDefault(); th.click(); }
  });

  document.addEventListener('click', e => {
    const t = e.target;
    openedThisClick = false;

    if (!t.closest('.search')) $('#sr').classList.remove('on');

    if (t.closest('[data-close]')) { closeDrawer(); return; }

    const stepBtn = t.closest('[data-nav]');
    if (stepBtn) { stepInspect(Number(stepBtn.dataset.nav)); return; }

    const ft = t.closest('[data-facets]');
    if (ft) { ft.closest('.pane').querySelector('.facets').classList.toggle('open'); return; }

    const cp = t.closest('[data-copy]');
    if (cp) { copy(cp.dataset.copy); return; }

    const cl = t.closest('[data-copy-link]');
    if (cl) { copy(link(cl.dataset.copyLink)); return; }

    const sold = t.closest('[data-sold]');
    if (sold) {
      S.listings = S.listings.map(x => (x.id === sold.dataset.sold ? Object.assign({}, x, { sold: !x.sold }) : x));
      save(); renderAll(); closeDrawer();
      toast('Listing updated');
      return;
    }

    const buyBtn = t.closest('[data-buy]');
    if (buyBtn) { closeDrawer(); buyDialog(buyBtn.dataset.buy); return; }
    if (t.closest('[data-track]')) { closeDrawer(); trackDialog(''); return; }
    const trk = t.closest('[data-track-code]');
    if (trk) { trackDialog(trk.dataset.trackCode); return; }
    const cnl = t.closest('[data-cancel-trade]');
    if (cnl) { cancelTrade(cnl.dataset.cancelTrade, cnl.dataset.code); return; }
    const ord = t.closest('[data-ord]');
    if (ord) { staffOrder(ord.closest('tr').dataset.id, ord.dataset.ord); return; }

    const jp = t.closest('[data-jump]');
    if (jp) {
      if (jp.tagName === 'A') e.preventDefault();
      jump(jp.dataset.jump, jp.dataset.name || '');
      return;
    }

    const lm = t.closest('#lm button');
    if (lm) { loginMethod(lm.dataset.lm); return; }

    if (t.closest('[data-signup]')) { $('#dlg').close(); return; }
    if (t.closest('[data-login]')) { loginDlg(); return; }

    const tb = t.closest('.tabs button[data-tab]');
    if (tb) { showPane(tb.dataset.tab); return; }

    const clear = t.closest('[data-clear]');
    if (clear) {
      const id = clear.dataset.clear, s = T[id];
      s.q = ''; s.fil = {}; s.page = 1;
      const f = $(`.f[data-t="${id}"]`);
      if (f) f.value = '';
      draw(id); chips(); return;
    }

    const hit = t.closest('#sr button');
    if (hit) {
      jump(hit.dataset.sec, hit.dataset.name);
      $('#gs').value = '';
      $('#sr').classList.remove('on');
      $('#sr').innerHTML = '';
      return;
    }

    const kindBtn = t.closest('#kinds button');
    if (kindBtn) {
      adminKind = kindBtn.dataset.kind;
      delete T.tAdmin;
      $('#adminF').value = '';
      renderStaff();
      return;
    }

    const floorBtn = t.closest('#floorTabs button');
    if (floorBtn) {
      floorId = floorBtn.dataset.floor;
      $$('#floorTabs button').forEach(b => {
        b.classList.toggle('on', b === floorBtn);
        b.setAttribute('aria-pressed', String(b === floorBtn));
      });
      renderFloor();
      return;
    }

    const ch = t.closest('.chips button');
    if (ch) {
      const wrap = ch.parentNode;
      const s = T[wrap.dataset.t];
      if (!s) return;
      s.fil = Object.assign({}, s.fil || {}, { [wrap.dataset.k]: ch.dataset.v });
      s.page = 1;
      draw(wrap.dataset.t);
      chips();
      return;
    }

    const pg = t.closest('.pager button');
    if (pg && !pg.disabled) {
      const box = pg.parentNode;
      const s = T[box.dataset.pager];
      if (s) {
        s.page = Math.max(1, Number(pg.dataset.page) || 1);
        draw(box.dataset.pager);
        // The pager sits below a tall table, so bring the new page into view.
        // Offset by the sticky header so the first row is not hidden under it.
        const w = document.getElementById(box.dataset.pager);
        if (w) scrollTo({ top: Math.max(0, w.getBoundingClientRect().top + scrollY - 84) });
      }
      return;
    }

    const th = t.closest('th[data-k]');
    if (th) {
      const id = th.closest('.tw').id;
      const s = T[id];
      if (!s) return;
      s.dir = s.key === th.dataset.k ? -s.dir : 1;
      s.key = th.dataset.k;
      s.page = 1;
      draw(id);
      return;
    }

    const act = t.closest('[data-act]');
    if (act) {
      const id = act.closest('tr').dataset.id;
      if (act.dataset.act === 'edit') { editEntry(adminKind, id); return; }
      if (confirm('Remove this entry?')) {
        S[adminKind] = S[adminKind].filter(x => x.id !== id);
        save(); renderAll();
        toast('Entry removed');
      }
      return;
    }

    const row = t.closest('tr[data-id]');
    if (row) {
      const s = T[row.closest('.tw').id];
      if (s && s.onRow) {
        const rec = s.rows.find(x => x.id === row.dataset.id);
        if (rec) {
          const list = s.view || [rec];
          const at = list.indexOf(rec);
          inspect = at < 0 ? null : { list, i: at, open: s.onRow };
          s.onRow(rec);
        }
      }
    }
  });

  /* ---------------------------------------------------------------- */
  /* Boot                                                             */
  /* ---------------------------------------------------------------- */

  $('#postBtn').addEventListener('click', () => ($('#pExch').classList.contains('on') ? postDialog() : postCrossDialog()));
  $('#trackBtn').addEventListener('click', () => trackDialog(''));
  $('#loginBtn').addEventListener('click', loginDlg);
  $('#copyCode').addEventListener('click', () => copy(LOADSTRING));
  $('#addBtn').addEventListener('click', () => editEntry(adminKind, null));
  $('#resetBtn').addEventListener('click', () => {
    if (!confirm('Replace all records, listings and gains with the data shipped with the site?')) return;
    S = clone(GA.SEED);
    S.seedHash = seedHash();
    save();
    renderAll();
    toast('Site data restored');
  });
  $('#qRot').addEventListener('change', e => {
    S.settings.quoteHours = Number(e.target.value) || 0;
    save();
    renderQuote();
  });

  $('#gForm').addEventListener('submit', e => {
    e.preventDefault();
    const lvl = Math.max(0, Math.floor(Number($('#gLvl').value) || 0));
    const ec = Math.max(0, Math.floor(Number($('#gEc').value) || 0));
    const floor = $('#gFl').value.trim();
    const err = $('#gErr');
    if (!lvl && !ec) {
      err.hidden = false;
      $('#gLvl').focus();
      return;
    }
    err.hidden = true;
    S.gains.unshift({
      id: uid('g'), lvl, ec, floor,
      message: $('#gMsg').value.trim().slice(0, 80),
      createdAt: new Date().toISOString()
    });
    save();
    e.target.reset();
    renderAll();
    toast('Gain posted');
  });

  $('#suForm').addEventListener('input', () => {
    const a = $('#suPw'), b = $('#suPw2');
    b.setCustomValidity(b.value && b.value !== a.value ? 'Passwords do not match' : '');
  });
  $('#suForm').addEventListener('submit', e => {
    e.preventDefault();
    const msg = $('#suMsg');
    msg.hidden = false;
    msg.textContent = 'Accounts are not live yet. Nothing was sent, and no sign-in is needed to post.';
    toast('Accounts are not live yet');
  });

  document.addEventListener('error', e => {
    const img = e.target;
    if (img.tagName !== 'IMG') return;
    const box = img.closest('.img');
    if (!box) return;
    box.classList.add('ph');
    box.innerHTML = `<b>${esc(box.dataset.initials || '?')}</b><small>Image unavailable</small>`;
  }, true);

  addEventListener('keydown', e => {
    if (e.key === '/' && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName)) {
      e.preventDefault(); $('#gs').focus();
    }
    if (/^Arrow(Up|Down|Left|Right)$/.test(e.key) && $('#drawer').classList.contains('open') &&
        !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName) && !$('#dlg').open) {
      e.preventDefault(); stepInspect(/Down|Right/.test(e.key) ? 1 : -1);
    }
    // Keep Tab inside the pop-up while it is open.
    if (e.key === 'Tab' && $('#drawer').classList.contains('open') && !$('#dlg').open) {
      const f = $$('#drawer button:not([disabled]), #drawer a[href]').filter(el => el.offsetParent !== null);
      if (f.length) {
        const first = f[0], last = f[f.length - 1];
        if (!document.activeElement.closest('#drawer')) { e.preventDefault(); first.focus(); }
        else if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      }
    }
    if (e.key === 'Escape') {
      if ($('#drawer').classList.contains('open')) closeDrawer();
      const sr = $('#sr');
      if (sr) { sr.classList.remove('on'); $('#gs').value = ''; }
    }
  });

  // A click anywhere off the drawer closes it. Registered after the main
  // handler, so the click that opens it has already set openedThisClick.
  document.addEventListener('click', e => {
    if (openedThisClick) { openedThisClick = false; return; }
    const box = $('#drawer');
    if (!box.classList.contains('open')) return;
    if (e.target.closest('#drawer') || e.target.closest('dialog')) return;
    closeDrawer();
  });

  addEventListener('hashchange', route);
  addEventListener('popstate', route);

  function renderAll() {
    renderHome();
    renderMarket();
    renderDB();
    renderGuide();
    renderStaff();
    chips();
    renderQuote();
    updateBadge();
  }

  renderAll();
  route();
})();
