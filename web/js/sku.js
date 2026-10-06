// Detailansicht eines Artikels: Kennzahlen, Verlauf, Bestellungen, Kommentare.
import { h, openDialog, statusBadge, num0, num1, num2, signed, fmtDate, fmtShort, todayBerlin, toast, lifecycleLabel } from './ui.js';
import { rpc } from './api.js';
import { stockChart, stockTable, yearsChart, yearsTable } from './chart.js';
import { formNote, formOrder, formSettings } from './forms.js';
import { ordersTable, isOpen, isArchived } from './orders-ui.js';

export function openSku(ctx, sku) {
  const root = h('div', null);
  let disposeChart = () => {}; let disposeSales = () => {};
  const dlg = openDialog({ title: '…', body: root, onClose: () => { disposeChart(); disposeSales(); } });

  async function fill() {
    const f = ctx.data.forecast.find((r) => r.sku === sku);
    const st = ctx.data.stock.find((r) => r.sku === sku);
    const name = f?.product_name || st?.product_name || sku;
    dlg.querySelector('.dlg-head h2').textContent = name;
    const [series, notes, sales] = await Promise.all([rpc('lager_stock_series', { p_sku: sku, p_days: 90 }), rpc('lager_notes_list', { p_sku: sku, p_days: 365 }), rpc('lager_sales_monthly', { p_sku: sku })]);
    const orders = ctx.data.orders.filter((o) => o.sku === sku);
    const points = series.map((p) => ({ date: p.date, value: Number(p.effective_stock), lager: Number(p.stock_qty), korrektur: p.korrektur == null ? 0 : Number(p.korrektur) }));
    const arrivals = orders.filter((o) => isOpen(o) && o.eta).map((o) => ({ date: o.eta, qty: Number(o.qty) - Number(o.received_qty) }));

    const sub = h('div', { class: 'muted small' }, `SKU ${sku}`, f ? ` · ${f.brand}` : '', f && f.lifecycle !== 'aktiv' ? h('span', { class: 'pill', style: 'margin-left:6px' }, lifecycleLabel(f.lifecycle)) : null, f ? ' · ' : '', f ? statusBadge(f.status) : '');
    const facts = h('div', { class: 'facts' },
      fact('Bestellbar', st ? num0(st.effective_stock) : '–', st ? `Stand ${fmtDate(st.date)}` : ''),
      fact('Lager (stock_qty)', st ? num0(st.stock_qty) : '–', st && Number(st.stock_offset) ? `Offset ${num0(st.stock_offset)}` : ''),
      fact('Verbrauch / Tag', f?.avg_daily_usage == null ? '–' : num1(f.avg_daily_usage), ''),
      fact('Reichweite', f?.days_of_cover == null ? '–' : `${num0(f.days_of_cover)} Tage`, f?.stockout_date ? `leer ca. ${fmtDate(f.stockout_date)}` : ''),
      fact('Bestellen bis', f?.order_by_date ? fmtDate(f.order_by_date) : '–', f ? `Lieferzeit ${f.lead_time_days} T (${f.lead_time_source}) + ${f.safety_days} T Puffer` : ''),
      fact('Offen bestellt', f ? num0(f.incoming_qty) : '–', f?.next_arrival ? `nächster Eingang ${fmtDate(f.next_arrival)}` : ''));

    const actions = h('div', { class: 'dlg-actions', style: 'justify-content:flex-start' },
      ctx.can('note') ? h('button', { class: 'btn', type: 'button', onclick: async () => { if (await formNote(ctx, sku)) { await ctx.reload(); await fill(); } } }, 'Kommentar / Korrektur') : null,
      ctx.can('order') ? h('button', { class: 'btn primary', type: 'button', onclick: async () => { if (await formOrder(ctx, sku)) { await ctx.reload(); await fill(); } } }, 'Bestellung erfassen') : null,
      ctx.can('settings') ? h('button', { class: 'btn', type: 'button', onclick: async () => { if (await formSettings(ctx, sku)) { await ctx.reload(); await fill(); } } }, 'Einstellungen') : null);

    const chartHost = h('div', null);
    const tableHost = h('div', { hidden: true }, stockTable(points));
    const toggle = h('button', { class: 'btn small', type: 'button', 'aria-pressed': 'false', onclick: () => {
      const showT = tableHost.hidden; tableHost.hidden = !showT; chartHost.hidden = showT; toggle.setAttribute('aria-pressed', String(showT));
      toggle.textContent = showT ? 'Diagramm anzeigen' : 'Tabelle anzeigen';
    } }, 'Tabelle anzeigen');
    const chartSection = h('section', null,
      h('div', { class: 'section-title' }, h('h3', null, 'Verlauf des bestellbaren Bestands (90 Tage)'), toggle),
      chartHost, tableHost,
      h('div', { class: 'chart-note' }, h('span', null, '– – Prognose ohne weitere Lieferungen'), h('span', null, '◆ erwartete Lieferung')));

    const openOrders = orders.filter((o) => !isArchived(o)); const archived = orders.filter(isArchived);
    const refill = () => fill();
    const tableOf = (list) => ordersTable(ctx, list, { product: false, onChange: refill });
    const ordersSection = h('section', null, h('h3', { style: 'margin-bottom:6px' }, 'Offene Bestellungen / nächste Lieferung'),
      openOrders.length ? h('div', { class: 'card' }, tableOf(openOrders)) : h('p', { class: 'muted' }, 'Keine offene Bestellung.'),
      archived.length ? h('details', { style: 'margin-top:10px' }, h('summary', { style: 'cursor:pointer;font-weight:600' }, `Archiv (${archived.length})`),
        h('div', { class: 'card', style: 'margin-top:6px' }, tableOf(archived))) : null);

    const noteItems = notes.map((n) => h('li', null,
      h('b', null, fmtDate(n.effective_date)), ' · ', n.kind === 'inventurkorrektur' ? `Inventurkorrektur ${signed(n.qty_delta)}` : 'Kommentar',
      n.created_by ? ` · ${n.created_by}` : '', n.note ? h('div', { class: 'muted' }, n.note) : null));
    const notesSection = h('section', null, h('h3', { style: 'margin-bottom:6px' }, 'Kommentare und Korrekturen'),
      notes.length ? h('ul', { style: 'margin:0;padding-left:18px;display:grid;gap:6px' }, noteItems) : h('p', { class: 'muted' }, 'Keine Einträge.'));

    // Absatz je Monat, Jahre im Vergleich (aus dem Rechnungsexport)
    const salesChart = h('div', null); const salesTable = h('div', { hidden: true }, sales.length ? yearsTable(sales) : null);
    const salesToggle = h('button', { class: 'btn small', type: 'button', onclick: () => {
      const showT = salesTable.hidden; salesTable.hidden = !showT; salesChart.hidden = showT; salesToggle.textContent = showT ? 'Diagramm anzeigen' : 'Tabelle anzeigen';
    } }, 'Tabelle anzeigen');
    const salesSection = h('section', null,
      h('div', { class: 'section-title' }, h('h3', null, 'Absatz je Monat, Jahre im Vergleich (Menge)'), sales.length ? salesToggle : null),
      salesChart, salesTable,
      h('div', { class: 'chart-note' }, h('span', null, 'Quelle: Rechnungsexport, Bestelltag; ohne Mitarbeiter')));

    root.replaceChildren(sub, facts, actions, chartSection, salesSection, ordersSection, notesSection);
    disposeSales(); disposeSales = yearsChart(salesChart, sales);
    disposeChart(); disposeChart = stockChart(chartHost, { points, usage: f?.avg_daily_usage == null ? 0 : Number(f.avg_daily_usage), arrivals });
  }
  root.style.display = 'grid'; root.style.gap = '16px';
  fill().catch((e) => { toast(e.message, true); dlg.close(); });
  return dlg;
}

function fact(k, v, sub) {
  return h('div', { class: 'fact' }, h('span', { class: 'k' }, k), h('span', { class: 'v' }, v), sub ? h('span', { class: 'small muted' }, sub) : null);
}
