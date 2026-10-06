// Eingabeformulare. Jede Funktion gibt zurueck, ob gespeichert wurde.
import { h, openForm, openDialog, todayBerlin, toast, num0, num2, fmtDate, LIFECYCLE } from './ui.js';
import { rpc } from './api.js';

const skuOptions = (ctx) => [{ value: '', label: '– bitte wählen –' },
  ...ctx.data.stock.map((r) => ({ value: r.sku, label: `${r.product_name} (${r.sku})` }))];
const nameOf = (ctx, sku) => ctx.data.stock.find((r) => r.sku === sku)?.product_name || sku;

export async function formNote(ctx, sku) {
  const saved = await openForm({
    title: 'Kommentar oder Inventurkorrektur', subtitle: sku ? `${nameOf(ctx, sku)} (${sku})` : null,
    fields: [
      ...(sku ? [] : [{ name: 'sku', label: 'Artikel', type: 'select', required: true, options: skuOptions(ctx), full: true }]),
      { name: 'kind', label: 'Art', type: 'select', value: 'kommentar', options: [
        { value: 'kommentar', label: 'Kommentar' }, { value: 'inventurkorrektur', label: 'Inventurkorrektur' }] },
      { name: 'qty_delta', label: 'Mengenänderung', type: 'number', placeholder: 'z. B. -10', help: 'Nur bei Inventurkorrektur. Negativ = Schwund, positiv = Mehrbestand.' },
      { name: 'effective_date', label: 'Wirksam ab (Bestandsdatum)', type: 'date', value: todayBerlin(), help: 'Datum des ersten Bestands, der die Korrektur enthält.' },
      { name: 'note', label: 'Text', type: 'textarea', placeholder: 'z. B. Ware bestellt bei …, Palette beschädigt, Zählung vom …' },
    ],
    submit: async (v) => {
      if (v.kind === 'inventurkorrektur' && v.qty_delta == null) throw new Error('Bitte die Mengenänderung der Korrektur angeben.');
      await rpc('lager_note_add', { p_sku: sku || v.sku, p_kind: v.kind, p_note: v.note,
        p_qty_delta: v.kind === 'inventurkorrektur' ? v.qty_delta : null, p_effective_date: v.effective_date });
    },
  });
  if (saved) toast('Gespeichert.');
  return saved;
}

export async function formOrder(ctx, sku) {
  const st = ctx.data.settings.find((r) => r.sku === sku);
  const saved = await openForm({
    title: 'Bestellung erfassen', subtitle: sku ? `${nameOf(ctx, sku)} (${sku})` : null,
    fields: [
      ...(sku ? [] : [{ name: 'sku', label: 'Artikel', type: 'select', required: true, options: skuOptions(ctx), full: true }]),
      { name: 'qty', label: 'Menge', type: 'number', required: true },
      { name: 'ordered_on', label: 'Bestelldatum', type: 'date', required: true, value: todayBerlin() },
      { name: 'expected_delivery', label: 'Voraussichtl. Lieferdatum', type: 'date', help: 'Lieferdatum oder Zeitspanne – eines von beiden ist nötig.' },
      { name: 'expected_lead_days', label: 'Zeitspanne bis Wareneinbuchung (Tage)', type: 'number' },
      { name: 'supplier', label: 'Lieferant / Hersteller', type: 'text', value: st?.supplier || '' },
      { name: 'comment', label: 'Kommentar', type: 'textarea' },
    ],
    submit: async (v) => {
      if (!(v.qty > 0)) throw new Error('Die Menge muss größer als 0 sein.');
      if (v.expected_delivery == null && v.expected_lead_days == null) throw new Error('Bitte Liefertermin oder Zeitspanne angeben.');
      await rpc('lager_order_add', { p_sku: sku || v.sku, p_qty: v.qty, p_ordered_on: v.ordered_on,
        p_expected_delivery: v.expected_delivery, p_expected_lead_days: v.expected_lead_days, p_supplier: v.supplier, p_comment: v.comment });
    },
  });
  if (saved) toast('Bestellung erfasst.');
  return saved;
}

export async function formReceive(ctx, o) {
  const open = Math.max(0, Number(o.qty) - Number(o.received_qty));
  const saved = await openForm({
    title: 'Wareneingang buchen', subtitle: `${o.product_name || o.sku} · bestellt ${num0(o.qty)}, bisher eingegangen ${num0(o.received_qty)}`,
    submitLabel: 'Eingang buchen',
    fields: [
      { name: 'received_on', label: 'Warenzugangsdatum', type: 'date', required: true, value: todayBerlin() },
      { name: 'qty', label: 'Eingegangene Menge', type: 'number', required: true, value: open || '' },
      { name: 'comment', label: 'Kommentar', type: 'textarea' },
    ],
    submit: async (v) => {
      if (!(v.qty > 0)) throw new Error('Die Menge muss größer als 0 sein.');
      await rpc('lager_order_receive', { p_id: o.id, p_received_on: v.received_on, p_received_qty: v.qty, p_comment: v.comment });
    },
  });
  if (saved) toast('Wareneingang gebucht.');
  return saved;
}

export async function formOrderEdit(ctx, o) {
  const statusField = ctx.can('order') ? [{ name: 'status', label: 'Status', type: 'select', value: o.status, options: [
    { value: 'bestellt', label: 'Bestellt' }, { value: 'bestaetigt', label: 'Bestätigt' }, { value: 'teilgeliefert', label: 'Teilgeliefert' },
    { value: 'eingebucht', label: 'Eingebucht' }, { value: 'storniert', label: 'Storniert' }] }] : [];
  const saved = await openForm({
    title: `Bestellung ${o.id} bearbeiten`, subtitle: `${o.product_name || o.sku} (${o.sku}) · Änderungen werden mit Datum und Name protokolliert`,
    fields: [
      { name: 'qty', label: 'Bestellte Menge', type: 'number', value: o.qty, help: Number(o.received_qty) > 0 ? `Bereits eingegangen: ${num0(o.received_qty)}` : null },
      { name: 'expected_delivery', label: 'Voraussichtl. Lieferdatum', type: 'date', value: o.expected_delivery || '', help: 'Bei Verzögerung hier den neuen Termin eintragen.' },
      { name: 'expected_lead_days', label: 'Zeitspanne bis Wareneinbuchung (Tage)', type: 'number', value: o.expected_lead_days ?? '' },
      { name: 'supplier', label: 'Lieferant / Hersteller', type: 'text', value: o.supplier || '' },
      ...statusField,
      { name: 'comment', label: 'Kommentar', type: 'textarea', value: o.comment || '' },
    ],
    submit: async (v) => {
      const r = await rpc('lager_order_update', { p_id: o.id, p_qty: v.qty, p_expected_delivery: v.expected_delivery,
        p_expected_lead_days: v.expected_lead_days, p_supplier: v.supplier, p_status: ctx.can('order') ? v.status : null, p_comment: v.comment });
      if (r && r.changed === false) throw new Error('Es wurde nichts geändert.');
    },
  });
  if (saved) toast('Bestellung aktualisiert.');
  return saved;
}

export async function formReopen(ctx, o) {
  const saved = await openForm({
    title: 'Eingang zurücksetzen',
    subtitle: `Bestellung ${o.id} (${o.product_name || o.sku}) wird wieder geöffnet; die gebuchte Menge (${num0(o.received_qty)}) wird entfernt.`,
    submitLabel: 'Zurücksetzen',
    fields: [{ name: 'comment', label: 'Grund', type: 'textarea', placeholder: 'z. B. war eine Rückbuchung, falsche Zuordnung' }],
    submit: async (v) => { await rpc('lager_order_reopen', { p_id: o.id, p_comment: v.comment }); },
  });
  if (saved) toast('Bestellung wieder geöffnet.');
  return saved;
}

const FIELD = { menge: 'Menge', liefertermin: 'Liefertermin', zeitspanne_tage: 'Zeitspanne (Tage)', lieferant: 'Lieferant', status: 'Status',
  kommentar: 'Kommentar', eingegangen: 'Eingegangen', zugang_am: 'Zugang am', gesamt_eingegangen: 'Insgesamt eingegangen', bestellt_am: 'Bestellt am' };
const ACTION = { angelegt: 'Angelegt', geaendert: 'Geändert', wareneingang_gebucht: 'Wareneingang gebucht', wareneingang_erkannt: 'Wareneingang automatisch erkannt', zurueckgesetzt: 'Zurückgesetzt' };
const STATUS_L = { bestellt: 'Bestellt', bestaetigt: 'Bestätigt', teilgeliefert: 'Teilgeliefert', eingebucht: 'Eingebucht', storniert: 'Storniert' };
function fmtVal(k, v) {
  if (v == null || v === '') return '–';
  if (k === 'status') return STATUS_L[v] || v;
  if (typeof v === 'number') return num2(v);
  if (typeof v === 'string' && /^\d{4}-\d{2}-\d{2}/.test(v)) return fmtDate(v);
  return String(v);
}
export function openOrderHistory(o) {
  const body = h('div', null, h('p', { class: 'muted' }, 'Lade …'));
  openDialog({ title: `Verlauf Bestellung ${o.id}`, subtitle: `${o.product_name || o.sku} (${o.sku})`, narrow: true, body });
  rpc('lager_order_history', { p_id: o.id }).then((rows) => {
    body.replaceChildren(rows.length ? h('ul', { style: 'margin:0;padding:0;list-style:none;display:grid;gap:12px' }, rows.map((r) => h('li', null,
      h('div', null, h('b', null, ACTION[r.action] || r.action), h('span', { class: 'muted' }, ` · ${new Date(r.at).toLocaleString('de-DE', { timeZone: 'Europe/Berlin', dateStyle: 'short', timeStyle: 'short' })}`, r.by ? ` · ${r.by}` : '')),
      r.changes ? h('ul', { style: 'margin:2px 0 0;padding-left:18px' }, Object.entries(r.changes).map(([k, v]) => h('li', null,
        `${FIELD[k] || k}: `, v && typeof v === 'object' && 'neu' in v ? `${fmtVal(k, v.alt)} → ${fmtVal(k, v.neu)}` : fmtVal(k, v)))) : null,
      r.note ? h('div', { class: 'muted' }, r.note) : null))) : h('p', { class: 'muted' }, 'Keine Einträge.'));
  }).catch((e) => { body.replaceChildren(h('p', { class: 'form-error' }, e.message)); });
}

export async function formSettings(ctx, sku) {
  const st = ctx.data.settings.find((r) => r.sku === sku) || {};
  const fc = ctx.data.forecast.find((r) => r.sku === sku);
  const cur = ctx.data.stock.find((r) => r.sku === sku);
  const brands = [...new Set(ctx.data.stock.map((r) => r.brand))].sort();
  const saved = await openForm({
    title: 'Artikel-Einstellungen', subtitle: `${nameOf(ctx, sku)} (${sku})`,
    fields: [
      { name: 'lifecycle', label: 'Status des Artikels', type: 'select', value: st.lifecycle || 'aktiv', full: true,
        options: Object.entries(LIFECYCLE).map(([value, label]) => ({ value, label })),
        help: 'Nicht aktive Artikel (z. B. Saisonware oder Archiv) sind in der Übersicht standardmäßig ausgeblendet.' },
      { name: 'brand', label: 'Marke', type: 'text', value: st.brand || '', datalist: brands,
        placeholder: cur ? `automatisch: ${cur.brand}` : '', help: 'Leer = automatisch aus dem Produktnamen.' },
      { name: 'source', label: 'Herkunft', type: 'select', value: st.supply_source || '', options: [
        { value: '', label: '– nicht festgelegt –' }, { value: 'extern', label: 'Externer Lieferant' }, { value: 'intern', label: 'Intern (ONYX)' }] },
      { name: 'lead', label: 'Lieferzeit (Tage)', type: 'number', value: st.lead_time_days ?? '',
        help: fc ? `Leer = automatisch (aktuell ${fc.lead_time_days} Tage, ${fc.lead_time_source}).` : 'Leer = automatisch aus eingebuchten Bestellungen, sonst 14 Tage.' },
      { name: 'safety', label: 'Sicherheitspuffer (Tage)', type: 'number', value: st.safety_days ?? 7 },
      { name: 'supplier', label: 'Standard-Lieferant', type: 'text', value: st.supplier || '' },
      { name: 'note', label: 'Notiz', type: 'textarea', value: st.note || '' },
    ],
    submit: async (v) => {
      if (v.lead != null && (v.lead < 0 || !Number.isInteger(v.lead))) throw new Error('Lieferzeit: ganze Zahl ≥ 0 oder leer lassen.');
      if (v.safety == null || v.safety < 0 || !Number.isInteger(v.safety)) throw new Error('Puffer: ganze Zahl ≥ 0.');
      await rpc('lager_sku_settings_upsert', { p_sku: sku, p_lead_time_days: v.lead, p_safety_days: v.safety,
        p_supply_source: v.source, p_supplier: v.supplier, p_lifecycle: v.lifecycle, p_note: v.note, p_brand: v.brand }, ['p_lead_time_days']);
    },
  });
  if (saved) toast('Einstellungen gespeichert.');
  return saved;
}
