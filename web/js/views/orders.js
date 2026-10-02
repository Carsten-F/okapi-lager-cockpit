import { h } from '../ui.js';
import { openSku } from '../sku.js';
import { formOrder } from '../forms.js';
import { ordersTable, isOpen, isArchived } from '../orders-ui.js';

const fs = { status: 'offen', q: '' };

export async function renderOrders(ctx, root) {
  const tableHost = h('div', { class: 'card' });
  const statusSel = h('select', { 'aria-label': 'Status', onchange: (e) => { fs.status = e.target.value; draw(); } },
    [['offen', 'Offen (nächste Lieferungen)'], ['archiv', 'Archiv (eingebucht, storniert)'], ['alle', 'Alle'], ['bestellt', 'Bestellt'], ['bestaetigt', 'Bestätigt'], ['teilgeliefert', 'Teilgeliefert']]
      .map(([v, l]) => h('option', { value: v, selected: fs.status === v }, l)));
  const search = h('input', { type: 'search', placeholder: 'Produkt, SKU oder Lieferant', value: fs.q, 'aria-label': 'Suche', oninput: (e) => { fs.q = e.target.value; draw(); } });
  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Bestellungen'),
      ctx.can('order') ? h('button', { class: 'btn primary', type: 'button', onclick: async () => { if (await formOrder(ctx, null)) { await ctx.reload(); draw(); } } }, 'Bestellung erfassen') : null),
    h('div', { class: 'filters' }, h('label', { class: 'grow' }, 'Suche', search), h('label', null, 'Status', statusSel)),
    tableHost);

  function draw() {
    const q = fs.q.trim().toLowerCase();
    const data = ctx.data.orders.filter((o) => (fs.status === 'alle' || (fs.status === 'offen' ? isOpen(o) : fs.status === 'archiv' ? isArchived(o) : o.status === fs.status))
      && (!q || `${o.product_name} ${o.sku} ${o.supplier || ''}`.toLowerCase().includes(q)));
    if (!data.length) { tableHost.replaceChildren(h('div', { class: 'empty' }, 'Keine Bestellungen für diese Auswahl.')); return; }
    tableHost.replaceChildren(ordersTable(ctx, data, { product: true, onSku: (sku) => openSku(ctx, sku), onChange: draw }));
  }
  draw();
}
