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

  const SKEY = 'gilded.v2';
  const STAFF_KEY = 'gilded.staff';
  const SCRIPT = GA.SCRIPT || {};
  const RAW = SCRIPT.raw || 'https://raw.githubusercontent.com/Enthusiasticzz/Autofarm-Script-Sbor/refs/heads/main/Init.lua';
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
          base.listings = d.listings || base.listings;
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
  const src = v => `<span class="tag ${slug(v)}">${esc(v)}</span>`;
  const dim = v => `<span class="dim">${esc(v)}</span>`;
  const plain = v => `<span class="nm">${esc(v)}</span>`;
  const bySource = (v, r) => `<span class="nm ${slug(r.source || 'starter')}">${esc(v)}</span>`;
  const side = v => `<span class="tag ${slug(v)}">${esc(v)}</span>`;
  const yes = v => (v ? '<span class="tag drop">Sold</span>' : '<span class="tag quest">Open</span>');

  const C = {
    items: [
      { k: 'category', t: 'Category', f: dim },
      { k: 'name', t: 'Name', f: plain },
      { k: 'rarity', t: 'Rarity', f: rar },
      { k: 'exp', t: 'EXP', num: 1, f: stat },
      { k: 'hp', t: 'HP', num: 1, f: stat },
      { k: 'str', t: 'STR', num: 1, f: stat },
      { k: 'vit', t: 'VIT', num: 1, f: stat },
      { k: 'def', t: 'DEF', num: 1, f: stat },
      { k: 'agi', t: 'AGI', num: 1, f: stat },
      { k: 'luck', t: 'LUCK', num: 1, f: stat },
      { k: 'drops', t: 'Drops', num: 1, f: v => n((v || []).length), sort: v => (v || []).length },
      { k: 'worth', t: 'Resale', num: 1, f: n }
    ],
    equipment: [
      { k: 'name', t: 'Name', f: bySource },
      { k: 'rarity', t: 'Rarity', f: rar },
      { k: 'attack', t: 'Attack', num: 1, f: stat },
      { k: 'crit', t: 'Crit', num: 1, f: v => (Number(v) ? v + '%' : '—') },
      { k: 'critDamage', t: 'Crit DMG', num: 1, f: v => (Number(v) ? v + '%' : '—') },
      { k: 'def', t: 'Defense', num: 1, f: stat },
      { k: 'effect', t: 'Effect', f: v => `<span class="clip" title="${esc(v)}">${esc(v || 'None')}</span>` },
      { k: 'source', t: 'Source', f: src },
      { k: 'worth', t: 'Resale', num: 1, f: n }
    ],
    overlays: [
      { k: 'name', t: 'Name', f: bySource },
      { k: 'rarity', t: 'Rarity', f: rar },
      { k: 'desc', t: 'Description', f: dim },
      { k: 'worth', t: 'Resale', num: 1, f: n },
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
    tradesMini: [
      { k: 'side', t: 'Type', f: side },
      { k: 'item', t: 'Item', f: plain },
      { k: 'price', t: 'Price', num: 1, f: n },
      { k: 'createdAt', t: 'Posted', f: ago }
    ]
  };

  /* ---------------------------------------------------------------- */
  /* Generic table: sort, filter, search                              */
  /* ---------------------------------------------------------------- */

  const T = {};

  function table(id, cols, rows, onRow) {
    const prev = T[id] || {};
    T[id] = Object.assign({ key: prev.key, dir: prev.dir, q: prev.q || '', fil: prev.fil || {}, drawn: prev.drawn }, { cols, rows, onRow });
    draw(id);
  }

  function draw(id) {
    const s = T[id];
    const w = $('#' + id);
    if (!s || !w) return;

    const q = (s.q || '').trim();
    const rows = s.rows.filter(x =>
      (!q || JSON.stringify(x).toLowerCase().includes(q)) &&
      Object.entries(s.fil || {}).every(([k, v]) => !v || x[k] === v));

    const keyOf = x => (s.key === 'rarity' ? RANK.indexOf(x.rarity) : s.cols.find(c => c.k === s.key)?.sort ? s.cols.find(c => c.k === s.key).sort(x[s.key]) : x[s.key]);
    if (s.key) rows.sort((a, b) => (keyOf(a) > keyOf(b) ? 1 : keyOf(a) < keyOf(b) ? -1 : 0) * s.dir);

    const head = s.cols.map(c => `<th data-k="${c.k}" tabindex="0" class="${c.num ? 'num' : ''}" aria-sort="${s.key === c.k ? (s.dir > 0 ? 'ascending' : 'descending') : 'none'}">${c.t}${s.key === c.k ? (s.dir > 0 ? ' ▲' : ' ▼') : ''}</th>`).join('');
    const body = rows.map((x, j) => `<tr data-id="${esc(x.id || '')}" tabindex="0" style="--d:${Math.min(j, 12) * 35}ms">${s.cols.map(c => `<td class="${c.num ? 'num' : ''}">${c.f ? c.f(x[c.k], x) : esc(x[c.k])}</td>`).join('')}</tr>`).join('');

    w.classList.toggle('settled', !!s.drawn);
    s.drawn = 1;
    w.innerHTML = `<table><thead><tr>${head}</tr></thead><tbody>${body ||
      `<tr><td class="empty" colspan="${s.cols.length}">Nothing matches. <button class="btn g s" data-clear="${id}">Clear filters</button></td></tr>`}</tbody></table>`;

    const c = $(`[data-for="${id}"]`);
    if (c) c.textContent = (rows.length === s.rows.length ? n(rows.length) : `Showing ${n(rows.length)} of ${n(s.rows.length)}`) + ' ' + c.dataset.u;
  }

  function chips() {
    $$('.chips').forEach(el => {
      const s = T[el.dataset.t];
      if (!s) return;
      const k = el.dataset.k;
      let vals = Array.from(new Set(s.rows.map(r => r[k]).filter(v => v !== undefined && v !== null && v !== '')));
      if (k === 'rarity') vals.sort((a, b) => RANK.indexOf(a) - RANK.indexOf(b));
      else vals.sort((a, b) => String(a).localeCompare(String(b)));
      const cur = (s.fil || {})[k] || '';
      el.innerHTML = ['', ...vals].map(v =>
        `<button data-v="${esc(v)}" class="${v === cur ? 'on' : ''}" aria-pressed="${v === cur}">${v ? esc(v) : 'All'}</button>`).join('');
    });
  }

  /* ---------------------------------------------------------------- */
  /* Drawer, dialog, toast                                            */
  /* ---------------------------------------------------------------- */

  let lastFocus = null;

  function drawer(html, actions = '') {
    lastFocus = document.activeElement;
    $('#drawer').innerHTML = `<div class="drawer-body">${html}</div><div class="acts">${actions}<button class="btn g" data-close>Close</button></div>`;
    $('#drawer').classList.add('open');
    const b = $('#drawer [data-close]');
    if (b) b.focus({ preventScroll: true });
  }

  function hideDrawer() {
    const box = $('#drawer');
    box.classList.remove('open');
    setTimeout(() => { if (!box.classList.contains('open')) box.innerHTML = ''; }, 220);
  }

  function closeDrawer() {
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

  const STATS = [
    ['exp', 'EXP'], ['hp', 'HP'], ['str', 'STR'], ['vit', 'VIT'],
    ['def', 'DEF'], ['agi', 'AGI'], ['luck', 'LUCK']
  ];

  const statBlock = r => `<div class="statgrid">${STATS.map(([k, t]) =>
    `<div${Number(r[k]) ? '' : ' class="off"'}><span>${t}</span><b>${stat(r[k])}</b></div>`).join('')}</div>`;

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
    return `<button class="btn" data-copy-link="${seg}/${esc(entry.id)}">Copy link</button>` +
      `<button class="btn" data-jump="market" data-name="${esc(entry.name)}">Find listings</button>`;
  };

  function showItem(r) {
    if (r.id) detailUrl('item', r.id);
    drawer(`<h3>${esc(r.name)}</h3><span class="chip">${esc(r.category)}</span> ${rar(r.rarity)}
      <p class="muted">${esc(r.desc || 'No description.')}</p>
      ${statBlock(r)}
      <dl><dt>Resale value</dt><dd>${n(r.worth)}</dd></dl>
      <p class="eyebrow spaced">Dropped by</p>
      ${dropTable(r.drops)}`, openActions(r, 'items'));
  }

  function showEquip(r) {
    if (r.id) detailUrl('gear', r.id);
    const stats = `<div class="statgrid"><div${Number(r.attack) ? '' : ' class="off"'}><span>ATK</span><b>${stat(r.attack)}</b></div>
      <div${Number(r.crit) ? '' : ' class="off"'}><span>CRIT</span><b>${Number(r.crit) ? r.crit + '%' : '—'}</b></div>
      <div${Number(r.critDamage) ? '' : ' class="off"'}><span>CRIT DMG</span><b>${Number(r.critDamage) ? r.critDamage + '%' : '—'}</b></div>
      ${STATS.slice(2).map(([k, t]) => `<div${Number(r[k]) ? '' : ' class="off"'}><span>${t}</span><b>${stat(r[k])}</b></div>`).join('')}</div>`;
    drawer(`<h3>${esc(r.name)}</h3><span class="chip">${esc(r.slot)}</span> ${rar(r.rarity)}
      ${image(r.image, r.name)}
      ${stats}
      <dl><dt>Effect</dt><dd>${esc(r.effect || 'None')}</dd><dt>Source</dt><dd>${src(r.source)}</dd><dt>Resale value</dt><dd>${n(r.worth)}</dd></dl>`,
      openActions(r, 'equipment'));
  }

  function showOverlay(r) {
    if (r.id) detailUrl('overlay', r.id);
    drawer(`<h3>${esc(r.name)}</h3><span class="chip">Overlay</span> ${rar(r.rarity)}
      ${image(r.image, r.name)}
      <p class="muted">${esc(r.desc || 'No description.')}</p>
      <dl><dt>Source</dt><dd>${src(r.source)}</dd><dt>Resale value</dt><dd>${n(r.worth)}</dd></dl>`,
      openActions(r, 'overlays'));
  }

  function showListing(r) {
    const entry = r.itemId
      ? [...S.items, ...S.equipment, ...S.overlays].find(x => x.id === r.itemId) || findEntry(r.item)
      : null;
    const view = entry ? entryKind(entry) : null;
    const seg = view === 'items' ? 'item' : view === 'equipment' ? 'gear' : 'overlay';
    drawer(`<h3>${esc(r.item)}</h3>${side(r.side)} <span class="tag ${r.mode === 'Exchange' ? 'quest' : 'starter'}">${esc(r.mode === 'Exchange' ? 'In-game exchange' : 'Crosstrading')}</span>
      <dl>
        <dt>Quantity</dt><dd>${n(r.qty)}</dd>
        <dt>Price each</dt><dd>${n(r.price)}</dd>
        <dt>Total</dt><dd>${n(r.qty * r.price)}</dd>
        <dt>Trader</dt><dd>${esc(r.user)}</dd>
        <dt>Posted</dt><dd>${ago(r.createdAt)}</dd>
        <dt>Note</dt><dd>${esc(r.note || 'None')}</dd>
      </dl>`,
      `<button class="btn" data-copy="${esc(r.user)}">Copy username</button>` +
      (entry ? `<button class="btn g" data-jump="${seg}" data-name="${esc(entry.name)}">View in database</button>` : '') +
      `<button class="btn g" data-sold="${esc(r.id)}">${r.sold ? 'Reopen listing' : 'Mark sold'}</button>`);
  }

  /* ---------------------------------------------------------------- */
  /* Home                                                             */
  /* ---------------------------------------------------------------- */

  function countFor(k) {
    if (k === 'listings') return S.listings.filter(x => !x.sold).length;
    return (S[k] || []).length;
  }

  function renderHome() {
    table('tHome', C.tradesMini, S.listings.filter(x => !x.sold).slice(0, 5), showListing);
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

  function renderMarket() {
    const open = S.listings.filter(x => !x.sold);
    table('tCross', C.trades, open.filter(x => x.mode === 'Crosstrading'), showListing);
    table('tExch', C.trades, open.filter(x => x.mode === 'Exchange'), showListing);
  }

  function postDialog(pane) {
    const names = [...S.items, ...S.equipment, ...S.overlays]
      .map(x => `<option value="${esc(x.name)}"></option>`).join('');
    dlg(`<h3>Post a trade</h3><p class="muted">No account needed. Add your in-game username so buyers can message you.</p>
      <form method="dialog" id="pf">
        <div class="fld"><label for="pMode">Trade type</label><select id="pMode" name="mode">
          <option value="Crosstrading">Crosstrading</option>
          <option value="Exchange"${pane === 'pExch' ? ' selected' : ''}>In-game exchange</option></select></div>
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
        mode: f.mode,
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
      showPane(f.mode === 'Exchange' ? 'pExch' : 'pCross');
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

  function renderLegend() {
    $('#legend').innerHTML = RARITY.map((r, i) => {
      const bands = ['1 in 1–4', '1 in 5–19', '1 in 20–99', '1 in 100–499', '1 in 500–4,999', '1 in 5,000+'];
      return `<span class="rar r-${slug(r)}"><i></i>${r}<small>${bands[i]}</small></span>`;
    }).join('');
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
    const cols = spec.adminCols.map(k => {
      const f = spec.fields.find(x => x.k === k);
      return { k, t: f ? f.label : k, f: v => (typeof v === 'number' ? n(v) : adminCell(v)) };
    });
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
        `<option${String(v) === o ? ' selected' : ''}>${esc(o)}</option>`).join('')}</select></div>`;
    }
    if (f.type === 'number') {
      return `<div class="fld">${label}<input id="${id}" name="${f.k}" type="number" step="1" value="${esc(v)}"></div>`;
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

      if (!data.name) return;

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
      .flatMap(([k, arr]) => (arr || []).filter(x => `${x.name} ${x.desc || ''} ${x.targets || ''}`.toLowerCase().includes(q)).map(x => [k, x.name]))
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
    draw(input.dataset.t);
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

    if (!t.closest('.search')) $('#sr').classList.remove('on');

    if (t.closest('[data-close]')) { closeDrawer(); return; }

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
      s.q = ''; s.fil = {};
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
      draw(wrap.dataset.t);
      chips();
      return;
    }

    const th = t.closest('th[data-k]');
    if (th) {
      const id = th.closest('.tw').id;
      const s = T[id];
      if (!s) return;
      s.dir = s.key === th.dataset.k ? -s.dir : 1;
      s.key = th.dataset.k;
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
        if (rec) s.onRow(rec);
      }
    }
  });

  /* ---------------------------------------------------------------- */
  /* Boot                                                             */
  /* ---------------------------------------------------------------- */

  $('#postBtn').addEventListener('click', () => postDialog($('#pExch').classList.contains('on') ? 'pExch' : 'pCross'));
  $('#loginBtn').addEventListener('click', loginDlg);
  $('#copyCode').addEventListener('click', () => copy(LOADSTRING));
  $('#addBtn').addEventListener('click', () => editEntry(adminKind, null));
  $('#resetBtn').addEventListener('click', () => {
    if (!confirm('Replace all records, listings and gains with the sample data from data.js?')) return;
    S = clone(GA.SEED);
    S.seedHash = seedHash();
    save();
    renderAll();
    toast('Sample data restored');
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
    if (e.key === 'Escape') {
      if ($('#drawer').classList.contains('open')) closeDrawer();
      const sr = $('#sr');
      if (sr) { sr.classList.remove('on'); $('#gs').value = ''; }
    }
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
  }

  renderLegend();
  renderAll();
  route();
})();
