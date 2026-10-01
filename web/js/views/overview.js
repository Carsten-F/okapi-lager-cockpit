import { h, statusBadge, icon, STATUS, num0, num1, fmtDate, fmtShort, todayBerlin, toast } from '../ui.js';
import { rpc } from '../api.js';
import { openSku } from '../sku.js';

const fs = { status: '', source: '', q: '', sort: null, dir: 1 };
const ORDER = ['kritisch', 'bestellen', 'bestellt', 'ok', 'kein_verbrauch'];

export async function renderOverview(ctx, root) {
  const rows = () => ctx.data.forecast;
  const tiles = h('div', { class: 'tiles' });
  const notice = h('div', { hidden: true });
  const tableHost = h('div', { class: 'card' });

  const search = h('input', { type: 'search', placeholder: 'Produkt oder SKU', value: fs.q, 'aria-label': 'Suche', oninput: (e) => { fs.q = e.target.value; drawTable(); } });
  const statusSel = h('select', { 'aria-label': 'Status', onchange: (e) => { fs.status = e.target.value; drawTiles(); drawTable(); } },
    h('option', { value: '' }, 'Alle'), ORDER.map((k) => h('option', { value: k, selected: fs.status === k }, STATUS[k].label)));
  const sourceSel = h('select', { 'aria-label': 'Herkunft', onchange: (e) => { fs.source = e.target.value; drawTable(); } },
    [['', 'Alle'], ['extern', 'Externer Lieferant'], ['intern', 'Intern (ONYX)'], ['none', 'Nicht festgelegt']].map(([v, l]) => h('option', { value: v, selected: fs.source === v }, l)));
  const winSel = h('select', { 'aria-label': 'Verbrauchsfenster', onchange: async (e) => { ctx.window = Number(e.target.value); await ctx.reloadForecast(); drawAll(); } },
    [14, 28, 56].map((d) => h('option', { value: d, selected: ctx.window === d }, `${d} Tage`)));

  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Übersicht'),
      h('span', { class: 'muted small' }, 'Reichweite aus den Bestandsdifferenzen der letzten Tage'),
      ctx.can('sync') ? h('button', { class: 'btn', type: 'button', onclick: async (e) => {
        e.target.disabled = true;
        try { const r = await rpc('lager_sync_now'); await ctx.reload(); drawAll(); toast(`Abgleich fertig: ${r.rows_changed} Zeilen neu oder geändert.`); } catch (ex) { toast(ex.message, true); }
        e.target.disabled = false; } }, 'Daten jetzt abgleichen') : null),
    notice,
    tiles,
    h('div', { class: 'filters' },
      h('label', { class: 'grow' }, 'Suche', search), h('label', null, 'Status', statusSel),
      h('label', null, 'Herkunft', sourceSel), h('label', null, 'Verbrauchsfenster', winSel)),
    tableHost);

  function drawNotice() {
    const stock = ctx.data.stock;
    if (!stock.length) { notice.hidden = false; notice.className = 'notice'; notice.replaceChildren(icon('clock', 'var(--series-1)'), 'Noch keine Bestandsdaten vorhanden. Sobald der Magento-Abruf läuft, erscheinen die Artikel hier.'); return; }
    const latest = stock.map((r) => r.date).sort().pop();
    const stale = rows().some((r) => r.data_stale);
    notice.hidden = !stale; notice.className = 'notice';
    if (stale) notice.replaceChildren(icon('warn', 'var(--warning)'), `Der letzte Bestand ist vom ${fmtDate(latest)}. Der tägliche Abruf scheint nicht zu laufen – die Prognose ist veraltet.`);
  }
  function drawTiles() {
    const counts = Object.fromEntries(ORDER.map((k) => [k, 0]));
    for (const r of rows()) counts[r.status] = (counts[r.status] || 0) + 1;
    tiles.replaceChildren(...['kritisch', 'bestellen', 'bestellt', 'ok'].map((k) => h('button', { class: 'tile', type: 'button', 'aria-pressed': String(fs.status === k),
      onclick: () => { fs.status = fs.status === k ? '' : k; statusSel.value = fs.status; drawTiles(); drawTable(); } },
      h('span', { class: 'tl' }, icon(STATUS[k].icon, STATUS[k].color), STATUS[k].label), h('span', { class: 'tv' }, String(counts[k])), h('span', { class: 'ts' }, STATUS[k].hint))));
  }

  const COLS = [
    { k: 'product', t: 'Produkt', get: (r) => r.product_name.toLowerCase() },
    { k: 'status', t: 'Status', get: (r) => ORDER.indexOf(r.status) },
    { k: 'stock', t: 'Bestand', num: true, get: (r) => Number(r.effective_stock) },
    { k: 'free', t: 'Bestellbar', num: true, get: (r) => Number(r.bestellbar) },
    { k: 'usage', t: 'Verbrauch/Tag', num: true, get: (r) => Number(r.avg_daily_usage ?? -1) },
    { k: 'cover', t: 'Reichweite', get: (r) => Number(r.days_of_cover ?? 1e9) },
    { k: 'out', t: 'Leer am', get: (r) => r.stockout_date || '9999' },
    { k: 'by', t: 'Bestellen bis', get: (r) => r.order_by_date || '9999' },
    { k: 'lead', t: 'Lieferzeit', num: true, get: (r) => r.lead_time_days },
    { k: 'inc', t: 'Offen bestellt', get: (r) => Number(r.incoming_qty) },
  ];
  function filtered() {
    const q = fs.q.trim().toLowerCase();
    let out = rows().filter((r) => (!fs.status || r.status === fs.status)
      && (!fs.source || (fs.source === 'none' ? !r.supply_source : r.supply_source === fs.source))
      && (!q || r.product_name.toLowerCase().includes(q) || r.sku.toLowerCase().includes(q)));
    if (fs.sort) { const c = COLS.find((x) => x.k === fs.sort); out = [...out].sort((a, b) => { const x = c.get(a), y = c.get(b); return (x < y ? -1 : x > y ? 1 : 0) * fs.dir; }); }
    return out;
  }
  function drawTable() {
    const data = filtered(); const today = todayBerlin();
    if (!data.length) { tableHost.replaceChildren(h('div', { class: 'empty' }, rows().length ? 'Keine Artikel für diese Filter.' : 'Keine Daten.')); return; }
    const head = h('tr', null, COLS.map((c) => h('th', { class: `sortable ${c.num ? 'num' : ''}`, tabindex: 0, 'aria-sort': fs.sort === c.k ? (fs.dir === 1 ? 'ascending' : 'descending') : 'none',
      onclick: () => { fs.dir = fs.sort === c.k ? -fs.dir : 1; fs.sort = c.k; drawTable(); },
      onkeydown: (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.target.click(); } } },
      c.t, fs.sort === c.k ? (fs.dir === 1 ? ' ▲' : ' ▼') : '')));
    const body = data.map((r) => {
      const st = STATUS[r.status] || STATUS.kein_verbrauch;
      const cover = r.days_of_cover == null ? null : Number(r.days_of_cover);
      const pct = cover == null ? 0 : Math.min(1, cover / (r.lead_time_days + r.safety_days + 30));
      const tr = h('tr', { class: 'click', tabindex: 0, onclick: () => openSku(ctx, r.sku), onkeydown: (e) => { if (e.key === 'Enter') openSku(ctx, r.sku); } },
        h('td', { class: 'wrap pcell' }, h('div', { class: 'pname' }, r.product_name), h('div', { class: 'sku' }, r.sku, r.supply_source ? h('span', { class: 'pill', style: 'margin-left:6px' }, r.supply_source === 'intern' ? 'intern' : 'extern') : null)),
        h('td', null, statusBadge(r.status), r.out_of_stock ? h('div', { class: 'small muted' }, 'ausverkauft') : null),
        h('td', { class: 'num' }, num0(r.effective_stock)),
        h('td', { class: 'num' }, num0(r.bestellbar)),
        h('td', { class: 'num' }, r.avg_daily_usage == null ? '–' : num1(r.avg_daily_usage)),
        h('td', null, h('span', { class: 'meter' }, h('span', { class: 'bar' }, h('span', { class: 'fill', style: `display:block;width:${Math.round(pct * 100)}%;background:${st.color}` })),
          cover == null ? '–' : `${num0(cover)} Tage`)),
        h('td', { class: 'wrap' }, r.stockout_date ? fmtDate(r.stockout_date) : '–',
          r.stockout_date_incl_orders && r.stockout_date_incl_orders !== r.stockout_date ? h('div', { class: 'small muted' }, `mit Lieferung ${fmtDate(r.stockout_date_incl_orders)}`) : null),
        h('td', { class: 'wrap' }, r.order_by_date ? fmtDate(r.order_by_date) : '–', r.order_by_date && r.order_by_date < today ? h('div', { class: 'small', style: 'font-weight:600' }, 'überfällig') : null),
        h('td', { class: 'num' }, `${r.lead_time_days} T`, h('div', { class: 'small muted' }, r.lead_time_source)),
        h('td', null, Number(r.incoming_qty) > 0 ? [num0(r.incoming_qty), r.next_arrival ? h('div', { class: 'small muted' }, `Eingang ${fmtShort(r.next_arrival)}`) : null,
          Number(r.overdue_orders) > 0 ? h('div', { class: 'status small' }, icon('warn', 'var(--warning)', 13), 'überfällig') : null] : '–'));
      return tr;
    });
    tableHost.replaceChildren(h('div', { class: 'table-wrap' }, h('table', null, h('thead', null, head), h('tbody', null, body))));
  }
  function drawAll() { drawNotice(); drawTiles(); drawTable(); }
  drawAll();
  return { refresh: drawAll };
}
