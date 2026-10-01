// Eingabeformulare. Jede Funktion gibt zurueck, ob gespeichert wurde.
import { openForm, todayBerlin, toast, num0 } from './ui.js';
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
  const saved = await openForm({
    title: `Bestellung ${o.id} bearbeiten`, subtitle: `${o.product_name || o.sku} (${o.sku})`,
    fields: [
      { name: 'qty', label: 'Menge', type: 'number', value: o.qty },
      { name: 'expected_delivery', label: 'Voraussichtl. Lieferdatum', type: 'date', value: o.expected_delivery || '' },
      { name: 'expected_lead_days', label: 'Zeitspanne bis Wareneinbuchung (Tage)', type: 'number', value: o.expected_lead_days ?? '' },
      { name: 'supplier', label: 'Lieferant / Hersteller', type: 'text', value: o.supplier || '' },
      { name: 'status', label: 'Status', type: 'select', value: o.status, options: [
        { value: 'bestellt', label: 'Bestellt' }, { value: 'bestaetigt', label: 'Bestätigt' }, { value: 'teilgeliefert', label: 'Teilgeliefert' },
        { value: 'eingebucht', label: 'Eingebucht' }, { value: 'storniert', label: 'Storniert' }] },
      { name: 'comment', label: 'Kommentar', type: 'textarea', value: o.comment || '' },
    ],
    submit: async (v) => {
      await rpc('lager_order_update', { p_id: o.id, p_qty: v.qty, p_expected_delivery: v.expected_delivery,
        p_expected_lead_days: v.expected_lead_days, p_supplier: v.supplier, p_status: v.status, p_comment: v.comment });
    },
  });
  if (saved) toast('Bestellung aktualisiert.');
  return saved;
}

export async function formSettings(ctx, sku) {
  const st = ctx.data.settings.find((r) => r.sku === sku) || {};
  const fc = ctx.data.forecast.find((r) => r.sku === sku);
  const saved = await openForm({
    title: 'Artikel-Einstellungen', subtitle: `${nameOf(ctx, sku)} (${sku})`,
    fields: [
      { name: 'lead', label: 'Lieferzeit (Tage)', type: 'number', value: st.lead_time_days ?? '',
        help: fc ? `Leer = automatisch (aktuell ${fc.lead_time_days} Tage, ${fc.lead_time_source}).` : 'Leer = automatisch aus eingebuchten Bestellungen, sonst 14 Tage.' },
      { name: 'safety', label: 'Sicherheitspuffer (Tage)', type: 'number', value: st.safety_days ?? 7 },
      { name: 'source', label: 'Herkunft', type: 'select', value: st.supply_source || '', options: [
        { value: '', label: '– nicht festgelegt –' }, { value: 'extern', label: 'Externer Lieferant' }, { value: 'intern', label: 'Intern (ONYX)' }] },
      { name: 'supplier', label: 'Standard-Lieferant', type: 'text', value: st.supplier || '' },
      { name: 'active', label: 'In der Prognose berücksichtigen', type: 'checkbox', value: st.active ?? true },
      { name: 'note', label: 'Notiz', type: 'textarea', value: st.note || '' },
    ],
    submit: async (v) => {
      if (v.lead != null && (v.lead < 0 || !Number.isInteger(v.lead))) throw new Error('Lieferzeit: ganze Zahl ≥ 0 oder leer lassen.');
      if (v.safety == null || v.safety < 0 || !Number.isInteger(v.safety)) throw new Error('Puffer: ganze Zahl ≥ 0.');
      await rpc('lager_sku_settings_upsert', { p_sku: sku, p_lead_time_days: v.lead, p_safety_days: v.safety,
        p_supply_source: v.source, p_supplier: v.supplier, p_active: v.active, p_note: v.note }, ['p_lead_time_days']);
    },
  });
  if (saved) toast('Einstellungen gespeichert.');
  return saved;
}
