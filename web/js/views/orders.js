import { h, icon, num0, fmtDate, todayBerlin } from '../ui.js';
import { openSku, orderStatusLabel } from '../sku.js';
import { formOrder, formReceive, formOrderEdit } from '../forms.js';

const fs = { status: 'offen', q: '' };
const isOpen = (o) => ['bestellt', 'bestaetigt', 'teilgeliefert'].includes(o.status);

export async function renderOrders(ctx, root) {
  const tableHost = h('div', { class: 'card' });
  const statusSel = h('select', { 'aria-label': 'Status', onchange: (e) => { fs.status = e.target.value; draw(); } },
    [['offen', 'Offen'], ['alle', 'Alle'], ['bestellt', 'Bestellt'], ['bestaetigt', 'Bestätigt'], ['teilgeliefert', 'Teilgeliefert'], ['eingebucht', 'Eingebucht'], ['storniert', 'Storniert']]
      .map(([v, l]) => h('option', { value: v, selected: fs.status === v }, l)));
  const search = h('input', { type: 'search', placeholder: 'Produkt, SKU oder Lieferant', value: fs.q, 'aria-label': 'Suche', oninput: (e) => { fs.q = e.target.value; draw(); } });
  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Bestellungen'),
      ctx.can('order') ? h('button', { class: 'btn primary', type: 'button', onclick: async () => { if (await formOrder(ctx, null)) { await ctx.reload(); draw(); } } }, 'Bestellung erfassen') : null),
    h('div', { class: 'filters' }, h('label', { class: 'grow' }, 'Suche', search), h('label', null, 'Status', statusSel)),
    tableHost);

  function draw() {
    const today = todayBerlin(); const q = fs.q.trim().toLowerCase();
    const data = ctx.data.orders.filter((o) => (fs.status === 'alle' || (fs.status === 'offen' ? isOpen(o) : o.status === fs.status))
      && (!q || `${o.product_name} ${o.sku} ${o.supplier || ''}`.toLowerCase().includes(q)));
    if (!data.length) { tableHost.replaceChildren(h('div', { class: 'empty' }, 'Keine Bestellungen für diese Auswahl.')); return; }
    const after = async (p) => { if (await p) { await ctx.reload(); draw(); } };
    const rows = data.map((o) => {
      const late = isOpen(o) && o.eta && o.eta < today;
      return h('tr', null,
        h('td', null, `#${o.id}`),
        h('td', { class: 'wrap' }, h('a', { href: '#', onclick: (e) => { e.preventDefault(); openSku(ctx, o.sku); } }, o.product_name || o.sku), h('div', { class: 'sku' }, o.sku)),
        h('td', null, orderStatusLabel(o.status)),
        h('td', { class: 'num' }, num0(o.qty)), h('td', { class: 'num' }, num0(o.received_qty)),
        h('td', null, fmtDate(o.ordered_on)),
        h('td', null, o.eta ? fmtDate(o.eta) : '–', late ? h('div', { class: 'status small' }, icon('warn', 'var(--warning)', 13), 'überfällig') : null),
        h('td', null, o.received_on ? fmtDate(o.received_on) : '–'),
        h('td', { class: 'wrap' }, o.supplier || '', o.comment ? h('div', { class: 'small muted' }, o.comment) : null),
        h('td', null, isOpen(o) && ctx.can('receive') ? h('button', { class: 'btn small', type: 'button', onclick: () => after(formReceive(ctx, o)) }, 'Eingang buchen') : null, ' ',
          isOpen(o) && ctx.can('order') ? h('button', { class: 'btn small', type: 'button', onclick: () => after(formOrderEdit(ctx, o)) }, 'Bearbeiten') : null));
    });
    tableHost.replaceChildren(h('div', { class: 'table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Nr.', 'Produkt', 'Status', 'Menge', 'Eingegangen', 'Bestellt am', 'Erwartet', 'Warenzugang', 'Lieferant / Kommentar', ''].map((t, i) => h('th', { class: i === 3 || i === 4 ? 'num' : '' }, t)))),
      h('tbody', null, rows))));
  }
  draw();
}
