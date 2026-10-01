import { h, num0 } from '../ui.js';
import { formSettings } from '../forms.js';

export async function renderSettings(ctx, root) {
  const host = h('div', { class: 'card' });
  root.replaceChildren(h('div', { class: 'view-head' }, h('h1', null, 'Artikel-Einstellungen'),
    h('span', { class: 'muted small' }, 'Lieferzeit, Sicherheitspuffer und Herkunft je Artikel. Ohne Eintrag gelten die Standardwerte.')), host);
  function draw() {
    const bySku = Object.fromEntries(ctx.data.settings.map((s) => [s.sku, s]));
    const fc = Object.fromEntries(ctx.data.forecast.map((f) => [f.sku, f]));
    const rows = ctx.data.stock.map((r) => {
      const s = bySku[r.sku] || {}; const f = fc[r.sku];
      return h('tr', null,
        h('td', null, h('div', { class: 'pname' }, r.product_name), h('div', { class: 'sku' }, r.sku)),
        h('td', { class: 'num' }, s.lead_time_days != null ? `${s.lead_time_days} T` : (f ? `auto: ${f.lead_time_days} T` : 'auto')),
        h('td', { class: 'num' }, `${s.safety_days ?? 7} T`),
        h('td', null, s.supply_source === 'intern' ? 'Intern (ONYX)' : s.supply_source === 'extern' ? 'Extern' : '–'),
        h('td', null, s.supplier || ''),
        h('td', null, s.active === false ? h('span', { class: 'pill' }, 'inaktiv') : ''),
        h('td', null, ctx.can('settings') ? h('button', { class: 'btn small', type: 'button', onclick: async () => { if (await formSettings(ctx, r.sku)) { await ctx.reload(); draw(); } } }, 'Bearbeiten') : null));
    });
    host.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Produkt', 'Lieferzeit', 'Puffer', 'Herkunft', 'Lieferant', '', ''].map((t, i) => h('th', { class: i === 1 || i === 2 ? 'num' : '' }, t)))),
      h('tbody', null, rows))) : h('div', { class: 'empty' }, 'Keine Artikel.'));
  }
  draw();
}
