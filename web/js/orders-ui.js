// Bestelltabelle mit Aktionen, gemeinsam genutzt von der Bestellliste und der Artikel-Detailansicht.
import { h, icon, num0, fmtDate, todayBerlin } from './ui.js';
import { formReceive, formOrderEdit, formReopen, openOrderHistory } from './forms.js';

const LABEL = { bestellt: 'Bestellt', bestaetigt: 'Bestätigt', teilgeliefert: 'Teilgeliefert', eingebucht: 'Eingebucht', storniert: 'Storniert' };
export const orderStatusLabel = (s) => LABEL[s] || s;
export const isOpen = (o) => ['bestellt', 'bestaetigt', 'teilgeliefert'].includes(o.status);
export const isArchived = (o) => ['eingebucht', 'storniert'].includes(o.status);

// onChange: wird nach jeder Aenderung aufgerufen (Daten sind dann neu geladen).
export function ordersTable(ctx, orders, { product = false, onSku, onChange }) {
  const today = todayBerlin();
  const done = async (p) => { if (await p) { await ctx.reload(); onChange(); } };
  const rows = orders.map((o) => {
    const late = isOpen(o) && o.eta && o.eta < today;
    const canEdit = isOpen(o) ? ctx.can('orderEdit') : ctx.can('order');
    const canReopen = ctx.can('reopen') && ['eingebucht', 'teilgeliefert'].includes(o.status) && Number(o.received_qty) > 0;
    return h('tr', null,
      h('td', null, `#${o.id}`),
      product ? h('td', { class: 'wrap' }, h('a', { href: '#', onclick: (e) => { e.preventDefault(); onSku(o.sku); } }, o.product_name || o.sku), h('div', { class: 'sku' }, o.sku)) : null,
      h('td', null, orderStatusLabel(o.status),
        o.received_source === 'auto' ? h('div', null, h('span', { class: 'pill', title: 'Aus dem Bestandsanstieg erkannt. Bitte prüfen; bei Fehlzuordnung zurücksetzen.' }, 'automatisch erkannt')) : null),
      h('td', { class: 'num' }, num0(o.qty)), h('td', { class: 'num' }, num0(o.received_qty)),
      h('td', null, fmtDate(o.ordered_on)),
      h('td', null, o.eta ? fmtDate(o.eta) : '–', late ? h('div', { class: 'status small' }, icon('warn', 'var(--warning)', 13), 'überfällig') : null),
      h('td', null, o.received_on ? fmtDate(o.received_on) : '–'),
      h('td', { class: 'wrap' }, o.supplier || '', o.comment ? h('div', { class: 'small muted' }, o.comment) : null),
      h('td', { class: 'actions' },
        isOpen(o) && ctx.can('receive') ? h('button', { class: 'btn small', type: 'button', onclick: () => done(formReceive(ctx, o)) }, 'Eingang buchen') : null,
        canEdit ? h('button', { class: 'btn small', type: 'button', onclick: () => done(formOrderEdit(ctx, o)) }, 'Bearbeiten') : null,
        canReopen ? h('button', { class: 'btn small', type: 'button', onclick: () => done(formReopen(ctx, o)) }, 'Zurücksetzen') : null,
        h('button', { class: 'btn small', type: 'button', onclick: () => openOrderHistory(o) }, 'Verlauf')));
  });
  const heads = ['Nr.', product ? 'Produkt' : null, 'Status', 'Menge', 'Eingegangen', 'Bestellt am', 'Erwartet', 'Warenzugang', 'Lieferant / Kommentar', ''].filter((x) => x !== null);
  const numCols = product ? [3, 4] : [2, 3];
  return h('div', { class: 'table-wrap' }, h('table', null,
    h('thead', null, h('tr', null, heads.map((t, i) => h('th', { class: numCols.includes(i) ? 'num' : '' }, t)))),
    h('tbody', null, rows)));
}
