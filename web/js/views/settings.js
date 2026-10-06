import { h, LIFECYCLE, lifecycleLabel, toast, todayBerlin, num0, openDialog } from '../ui.js';
import { rpc } from '../api.js';
import { formSettings } from '../forms.js';
import { decodeBytes, parseCsv, mapRows, toCsv, download } from '../csv.js';

const fs = { q: '', brand: '', lifecycle: 'alle', source: '' };
const COLNAME = { sku: 'Artikelnummer', brand: 'Marke', lifecycle: 'Lebenszyklus', supply_source: 'Herkunft', supplier: 'Lieferant', lead_time_days: 'Lieferzeit', safety_days: 'Puffer', note: 'Notiz' };
const LIFE_EXPORT = { aktiv: 'aktiv', inaktiv_saison: 'nicht aktiv (Jahreszeit)', inaktiv_archiv: 'nicht aktiv (Archiv)' };

export async function renderSettings(ctx, root) {
  const host = h('div', { class: 'card' });
  const info = h('span', { class: 'muted small' });
  const fileInput = h('input', { type: 'file', accept: '.csv,text/csv,text/plain', hidden: true, onchange: async (e) => { const f = e.target.files[0]; e.target.value = ''; if (f) await startImport(f); } });

  const search = h('input', { type: 'search', placeholder: 'Produkt oder SKU', value: fs.q, 'aria-label': 'Suche', oninput: (e) => { fs.q = e.target.value; draw(); } });
  const brandSel = h('select', { 'aria-label': 'Marke', onchange: (e) => { fs.brand = e.target.value; draw(); } });
  const lifeSel = h('select', { 'aria-label': 'Artikelstatus', onchange: (e) => { fs.lifecycle = e.target.value; draw(); } },
    [['alle', 'Alle'], ['aktiv', 'Aktiv'], ['inaktiv_saison', LIFECYCLE.inaktiv_saison], ['inaktiv_archiv', LIFECYCLE.inaktiv_archiv]].map(([v, l]) => h('option', { value: v, selected: fs.lifecycle === v }, l)));
  const srcSel = h('select', { 'aria-label': 'Herkunft', onchange: (e) => { fs.source = e.target.value; draw(); } },
    [['', 'Alle'], ['extern', 'Extern'], ['intern', 'Intern (ONYX)'], ['none', 'Nicht festgelegt']].map(([v, l]) => h('option', { value: v, selected: fs.source === v }, l)));

  root.replaceChildren(
    h('div', { class: 'view-head' }, h('h1', null, 'Artikel-Einstellungen'),
      h('div', { class: 'sticky-actions' },
        h('button', { class: 'btn', type: 'button', onclick: exportCsv }, 'CSV exportieren'),
        ctx.can('settings') ? h('button', { class: 'btn primary', type: 'button', onclick: () => fileInput.click() }, 'CSV importieren') : null, fileInput)),
    h('p', { class: 'muted small', style: 'margin:0 0 10px' },
      'Status (aktiv / nicht aktiv), Marke, Herkunft, Lieferzeit, Sicherheitspuffer und Lieferant je Artikel. Ohne Eintrag gelten die Standardwerte. ',
      'Massenpflege: „CSV exportieren“, in Excel bearbeiten, „CSV importieren“. Leere Felder bleiben unverändert; bei der Lieferzeit stellt „auto“ auf automatisch.'),
    h('div', { class: 'filters' }, h('label', { class: 'grow' }, 'Suche', search), h('label', null, 'Marke', brandSel), h('label', null, 'Artikelstatus', lifeSel), h('label', null, 'Herkunft', srcSel)),
    info, host);

  const merged = () => {
    const bySku = Object.fromEntries(ctx.data.settings.map((s) => [s.sku, s]));
    const fc = Object.fromEntries(ctx.data.forecast.map((f) => [f.sku, f]));
    return ctx.data.stock.map((r) => ({ ...r, s: bySku[r.sku] || {}, f: fc[r.sku] }));
  };
  function fillBrands() {
    const brands = [...new Set(ctx.data.stock.map((r) => r.brand))].sort((a, b) => a.localeCompare(b, 'de'));
    if (fs.brand && !brands.includes(fs.brand)) fs.brand = '';
    brandSel.replaceChildren(h('option', { value: '' }, 'Alle Marken'), ...brands.map((b) => h('option', { value: b, selected: fs.brand === b }, b)));
  }

  function draw() {
    const q = fs.q.trim().toLowerCase();
    const all = merged();
    const list = all.filter((r) => (fs.lifecycle === 'alle' || r.lifecycle === fs.lifecycle) && (!fs.brand || r.brand === fs.brand)
      && (!fs.source || (fs.source === 'none' ? !r.s.supply_source : r.s.supply_source === fs.source))
      && (!q || r.product_name.toLowerCase().includes(q) || r.sku.toLowerCase().includes(q)));
    info.textContent = `${list.length} von ${all.length} Artikeln`;
    const rows = list.map((r) => h('tr', null,
      h('td', { class: 'wrap pcell' }, h('div', { class: 'pname' }, r.product_name), h('div', { class: 'sku' }, r.sku)),
      h('td', null, r.brand),
      h('td', null, r.lifecycle === 'aktiv' ? 'Aktiv' : h('span', { class: 'pill' }, lifecycleLabel(r.lifecycle))),
      h('td', null, r.s.supply_source === 'intern' ? 'Intern (ONYX)' : r.s.supply_source === 'extern' ? 'Extern' : '–'),
      h('td', { class: 'num' }, r.s.lead_time_days != null ? `${r.s.lead_time_days} T` : (r.f ? `auto: ${r.f.lead_time_days} T` : 'auto')),
      h('td', { class: 'num' }, `${r.s.safety_days ?? 7} T`),
      h('td', null, r.s.supplier || ''),
      h('td', null, ctx.can('settings') ? h('button', { class: 'btn small', type: 'button', onclick: async () => { if (await formSettings(ctx, r.sku)) { await ctx.reload(); fillBrands(); draw(); } } }, 'Bearbeiten') : null)));
    host.replaceChildren(rows.length ? h('div', { class: 'table-wrap' }, h('table', null,
      h('thead', null, h('tr', null, ['Produkt', 'Marke', 'Artikelstatus', 'Herkunft', 'Lieferzeit', 'Puffer', 'Lieferant', ''].map((t, i) => h('th', { class: i === 4 || i === 5 ? 'num' : '' }, t)))),
      h('tbody', null, rows))) : h('div', { class: 'empty' }, 'Keine Artikel für diese Filter.'));
  }

  function exportCsv() {
    const sorted = merged().sort((a, b) => a.brand.localeCompare(b.brand, 'de') || a.product_name.localeCompare(b.product_name, 'de'));
    const table = [['Artikelnummer', 'Produkt', 'Marke', 'Lebenszyklus', 'Herkunft', 'Lieferzeit_Tage', 'Puffer_Tage', 'Lieferant', 'Notiz'],
      ...sorted.map((r) => [r.sku, r.product_name, r.brand, LIFE_EXPORT[r.lifecycle] || 'aktiv', r.s.supply_source || '',
        r.s.lead_time_days != null ? r.s.lead_time_days : 'auto', r.s.safety_days ?? 7, r.s.supplier || '', r.s.note || ''])];
    download(`lager-einstellungen_${todayBerlin()}.csv`, toCsv(table));
    toast(`${sorted.length} Artikel exportiert.`);
  }

  async function startImport(file) {
    let mapped;
    try { mapped = mapRows(parseCsv(decodeBytes(await file.arrayBuffer()))); } catch (e) { toast(e.message, true); return; }
    if (!mapped.rows.length) { toast('Die Datei enthält keine Datenzeilen.', true); return; }
    if (mapped.rows.length > 5000) { toast('Zu viele Zeilen (maximal 5000).', true); return; }
    let res;
    try { res = await rpc('lager_sku_settings_import', { p_rows: mapped.rows, p_dry_run: true }); } catch (e) { toast(e.message, true); return; }
    const errs = res.errors || [];
    const sum = res.summary;
    const body = h('div', { style: 'display:grid;gap:12px' });
    const apply = h('button', { class: 'btn primary', type: 'button', disabled: errs.length > 0 || sum.neu + sum.geaendert === 0 }, `${sum.neu + sum.geaendert} Artikel übernehmen`);
    const dlg = openDialog({ title: 'CSV-Import prüfen', subtitle: file.name, body });
    body.append(
      h('div', { class: 'facts' },
        h('div', { class: 'fact' }, h('span', { class: 'k' }, 'Zeilen'), h('span', { class: 'v' }, num0(mapped.rows.length))),
        h('div', { class: 'fact' }, h('span', { class: 'k' }, 'werden geändert'), h('span', { class: 'v' }, num0(sum.geaendert + sum.neu))),
        h('div', { class: 'fact' }, h('span', { class: 'k' }, 'unverändert'), h('span', { class: 'v' }, num0(sum.unveraendert))),
        h('div', { class: 'fact' }, h('span', { class: 'k' }, 'Fehler'), h('span', { class: 'v' }, num0(errs.length)))),
      h('p', { class: 'muted small', style: 'margin:0' }, `Erkannte Spalten: ${mapped.recognized.map((k) => COLNAME[k] || k).join(', ')}.`, mapped.ignored.length ? ` Ignoriert: ${mapped.ignored.join(', ')}.` : ''),
      errs.length ? h('div', null, h('h3', { style: 'margin-bottom:6px' }, 'Fehler – es wird nichts übernommen, solange einer besteht'),
        h('div', { class: 'card table-wrap', style: 'max-height:220px' }, h('table', null, h('thead', null, h('tr', null, h('th', null, 'Zeile'), h('th', null, 'Artikel'), h('th', null, 'Problem'))),
          h('tbody', null, errs.slice(0, 100).map((e) => h('tr', null, h('td', null, String(e.row)), h('td', null, e.sku || ''), h('td', { class: 'wrap' }, e.message))))))) : null,
      res.changes.length ? h('div', null, h('h3', { style: 'margin-bottom:6px' }, `Änderungen${sum.neu + sum.geaendert > res.changes.length ? ` (erste ${res.changes.length})` : ''}`),
        h('div', { class: 'card table-wrap', style: 'max-height:220px' }, h('table', null, h('thead', null, h('tr', null, h('th', null, 'Zeile'), h('th', null, 'Artikel'), h('th', null, 'Felder'))),
          h('tbody', null, res.changes.map((c) => h('tr', null, h('td', null, String(c.row)), h('td', null, c.sku), h('td', { class: 'wrap' }, c.fields.join(', ')))))))) : null,
      h('div', { class: 'dlg-actions' }, h('button', { class: 'btn', type: 'button', onclick: () => dlg.close() }, 'Abbrechen'), apply));
    apply.addEventListener('click', async () => {
      apply.disabled = true;
      try { const r = await rpc('lager_sku_settings_import', { p_rows: mapped.rows, p_dry_run: false }); dlg.close(); await ctx.reload(); fillBrands(); draw();
        toast(`Import fertig: ${r.summary.neu + r.summary.geaendert} Artikel aktualisiert.`); }
      catch (e) { toast(e.message, true); apply.disabled = false; }
    });
  }

  fillBrands(); draw();
}
