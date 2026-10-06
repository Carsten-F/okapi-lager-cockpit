// CSV lesen/schreiben (Excel-tauglich: Semikolon, UTF-8 mit BOM, Anfuehrungszeichen).

export function decodeBytes(buf) {
  try { return new TextDecoder('utf-8', { fatal: true }).decode(buf).replace(/^﻿/, ''); }
  catch { return new TextDecoder('windows-1252').decode(buf); }   // aeltere Excel-Dateien
}

export function parseCsv(text) {
  const first = text.split(/\r?\n/, 1)[0] || '';
  const delim = [';', '\t', ','].map((d) => [d, first.split(d).length]).sort((a, b) => b[1] - a[1])[0][0];
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) {
      if (c === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c;
    } else if (c === '"') q = true;
    else if (c === delim) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
  return rows.filter((r) => r.some((x) => String(x).trim() !== ''));
}

export function toCsv(rows) {
  const esc = (v) => { const s = v == null ? '' : String(v); return /[;"\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };
  return '﻿' + rows.map((r) => r.map(esc).join(';')).join('\r\n') + '\r\n';
}

export function download(filename, text, type = 'text/csv;charset=utf-8') {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement('a'); a.href = url; a.download = filename; document.body.appendChild(a); a.click();
  setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 500);
}

// Spaltenkoepfe erkennen (Gross-/Kleinschreibung, Umlaute und Sonderzeichen egal)
const norm = (s) => String(s).toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss').replace(/[^a-z0-9]/g, '');
const ALIASES = {
  sku: ['artikelnummer', 'sku', 'artikelnr', 'artnr', 'nummer'],
  brand: ['marke', 'brand', 'hersteller'],
  lifecycle: ['lebenszyklus', 'status', 'aktiv', 'lifecycle', 'aktivinaktiv'],
  supply_source: ['herkunft', 'quelle', 'bezug', 'supplysource'],
  supplier: ['lieferant', 'supplier'],
  lead_time_days: ['lieferzeittage', 'lieferzeit', 'lieferzeitintagen', 'leadtime', 'leadtimedays', 'lieferzeitd'],
  safety_days: ['puffertage', 'puffer', 'sicherheitspuffer', 'sicherheitspuffertage', 'safetydays'],
  note: ['notiz', 'bemerkung', 'kommentar', 'note'],
};
export function mapRows(table) {
  const head = table[0].map(norm); const idx = {};
  for (const [key, names] of Object.entries(ALIASES)) { const i = head.findIndex((h) => names.includes(h)); if (i >= 0) idx[key] = i; }
  if (idx.sku == null) throw new Error('Spalte "Artikelnummer" (oder "SKU") fehlt in der Kopfzeile.');
  const rows = table.slice(1).map((r, n) => {
    const o = { row: n + 2 };
    for (const [key, i] of Object.entries(idx)) o[key] = (r[i] ?? '').trim();
    return o;
  });
  return { rows, recognized: Object.keys(idx), ignored: table[0].filter((_, i) => !Object.values(idx).includes(i)) };
}
