import { h, num0, signed, fmtDate, toast } from '../ui.js';
import { rpc } from '../api.js';
import { openSku } from '../sku.js';
import { formNote } from '../forms.js';

export async function renderFlows(ctx, root) {
  const inflowHost = h('div', { class: 'card' }); const notesHost = h('div', { class: 'card' });
  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Bewegungen und Kommentare')),
    h('section', { style: 'margin-bottom:20px' }, h('h2', { style: 'margin-bottom:4px' }, 'Erkannte Zugänge (30 Tage)'),
      h('p', { class: 'muted small', style: 'margin:0 0 8px' }, 'Bestandssprünge nach oben (Inventurkorrekturen abgezogen). Eingänge ohne gebuchte Bestellung bitte prüfen.'), inflowHost),
    h('section', null, h('div', { class: 'view-head', style: 'margin-bottom:6px' }, h('h2', null, 'Kommentare und Inventurkorrekturen (90 Tage)'),
      ctx.can('note') ? h('button', { class: 'btn primary', type: 'button', onclick: async () => { if (await formNote(ctx, null)) load(); } }, 'Eintrag hinzufügen') : null), notesHost));

  async function load() {
    try {
      const [inflows, notes] = await Promise.all([rpc('lager_detected_inflows', { p_days: 30 }), rpc('lager_notes_list', { p_days: 90 })]);
      inflowHost.replaceChildren(inflows.length ? h('div', { class: 'table-wrap' }, h('table', null,
        h('thead', null, h('tr', null, h('th', null, 'Datum'), h('th', null, 'Produkt'), h('th', { class: 'num' }, 'Zugang'), h('th', null, 'Gebuchte Bestellung'))),
        h('tbody', null, inflows.map((r) => h('tr', { class: 'click', onclick: () => openSku(ctx, r.sku) },
          h('td', null, fmtDate(r.date)), h('td', null, h('span', { class: 'pname' }, r.product_name), h('span', { class: 'sku' }, ` ${r.sku}`)),
          h('td', { class: 'num' }, signed(r.inflow)), h('td', null, r.booked_orders ? r.booked_orders.map((i) => `#${i}`).join(', ') : h('span', { class: 'pill' }, 'nicht zugeordnet'))))))) : h('div', { class: 'empty' }, 'Keine Zugänge erkannt.'));
      const names = Object.fromEntries(ctx.data.stock.map((r) => [r.sku, r.product_name]));
      notesHost.replaceChildren(notes.length ? h('div', { class: 'table-wrap' }, h('table', null,
        h('thead', null, h('tr', null, ['Datum', 'Art', 'Produkt', 'Änderung', 'Text', 'von'].map((t, i) => h('th', { class: i === 3 ? 'num' : '' }, t)))),
        h('tbody', null, notes.map((n) => h('tr', { class: 'click', onclick: () => openSku(ctx, n.sku) },
          h('td', null, fmtDate(n.effective_date)), h('td', null, n.kind === 'inventurkorrektur' ? 'Inventurkorrektur' : 'Kommentar'),
          h('td', null, names[n.sku] || n.sku), h('td', { class: 'num' }, n.qty_delta == null ? '' : signed(n.qty_delta)),
          h('td', { class: 'wrap' }, n.note || ''), h('td', null, n.created_by || '')))))) : h('div', { class: 'empty' }, 'Keine Einträge.'));
    } catch (e) { toast(e.message, true); }
  }
  await load();
}
