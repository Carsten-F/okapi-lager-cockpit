// Kleine UI-Hilfen. Alle Daten werden als Text eingefuegt (nie als HTML).
const SVGNS = 'http://www.w3.org/2000/svg';

function append(el, kids) {
  for (const k of kids) {
    if (k == null || k === false) continue;
    if (Array.isArray(k)) append(el, k);
    else if (k instanceof Node) el.appendChild(k);
    else el.appendChild(document.createTextNode(String(k)));
  }
}
function applyAttrs(el, attrs) {
  const late = [];
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.setAttribute('class', v);
    else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
    else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'selected') late.push([k, v]);
    else el.setAttribute(k, v === true ? '' : String(v));
  }
  return late;
}
export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  const late = applyAttrs(el, attrs);
  append(el, kids);
  for (const [k, v] of late) el[k] = v;
  return el;
}
export function s(tag, attrs, ...kids) {
  const el = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v != null && v !== false) el.setAttribute(k, String(v));
  append(el, kids);
  return el;
}

// ---- Formate (de-DE) -------------------------------------------------------------
const nf0 = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 0 });
const nf1 = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 });
const nf2 = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 2 });
export const num0 = (v) => (v == null || v === '' ? '–' : nf0.format(Number(v)));
export const num1 = (v) => (v == null || v === '' ? '–' : nf1.format(Number(v)));
export const num2 = (v) => (v == null || v === '' ? '–' : nf2.format(Number(v)));
export const signed = (v) => (v == null ? '–' : (Number(v) > 0 ? '+' : '') + nf2.format(Number(v)));
export function fmtDate(iso) {
  if (!iso) return '–';
  const t = String(iso).slice(0, 10);
  return `${t.slice(8, 10)}.${t.slice(5, 7)}.${t.slice(0, 4)}`;
}
export const fmtShort = (iso) => (iso ? `${String(iso).slice(8, 10)}.${String(iso).slice(5, 7)}.` : '–');
export function todayBerlin() {
  return new Date().toLocaleDateString('sv-SE', { timeZone: 'Europe/Berlin' });
}
export function dayNum(iso) {
  const [y, m, d] = String(iso).slice(0, 10).split('-').map(Number);
  return Math.round(Date.UTC(y, m - 1, d) / 86400000);
}
export function dayToIso(n) {
  return new Date(n * 86400000).toISOString().slice(0, 10);
}
export function parseNum(v) {
  if (v == null) return null;
  const t = String(v).trim().replace(/\s/g, '').replace(',', '.');
  if (t === '') return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : NaN;
}

// ---- Status: Symbol + Text, Farbe allein traegt nie die Bedeutung -------------------
export const STATUS = {
  kritisch:       { label: 'Kritisch',        short: 'Kritisch',  icon: 'alert', color: 'var(--critical)', hint: 'Ware reicht kürzer als die Lieferzeit' },
  bestellen:      { label: 'Jetzt bestellen', short: 'Bestellen', icon: 'warn',  color: 'var(--warning)',  hint: 'Bestellzeitpunkt ist erreicht' },
  bestellt:       { label: 'Bestellt',        short: 'Bestellt',  icon: 'clock', color: 'var(--series-1)', hint: 'Offene Bestellung deckt die Lücke' },
  ok:             { label: 'Ausreichend',     short: 'Ok',        icon: 'check', color: 'var(--good)',     hint: 'Bestand reicht über Lieferzeit und Puffer hinaus' },
  kein_verbrauch: { label: 'Kein Verbrauch',  short: 'Ruhend',    icon: 'dash',  color: 'var(--muted)',    hint: 'Im Fenster kein Verbrauch erkennbar' },
};
export function icon(name, color, size = 16) {
  const c = color || 'currentColor';
  const svg = s('svg', { viewBox: '0 0 16 16', width: size, height: size, 'aria-hidden': 'true', focusable: 'false' });
  if (name === 'alert') {
    svg.append(s('path', { d: 'M8 1.4 15.2 14.4H0.8z', fill: c, stroke: c, 'stroke-linejoin': 'round', 'stroke-width': 1 }),
      s('path', { d: 'M8 6v4M8 11.9v.2', stroke: '#fff', 'stroke-width': 1.6, 'stroke-linecap': 'round' }));
  } else if (name === 'warn') {
    svg.append(s('circle', { cx: 8, cy: 8, r: 7, fill: c }),
      s('path', { d: 'M8 4.4v4.2M8 10.7v.2', stroke: '#0b0b0b', 'stroke-width': 1.7, 'stroke-linecap': 'round' }));
  } else if (name === 'clock') {
    svg.append(s('circle', { cx: 8, cy: 8, r: 6.2, fill: 'none', stroke: c, 'stroke-width': 1.8 }),
      s('path', { d: 'M8 4.5V8l2.4 1.6', fill: 'none', stroke: c, 'stroke-width': 1.6, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
  } else if (name === 'check') {
    svg.append(s('circle', { cx: 8, cy: 8, r: 7, fill: c }),
      s('path', { d: 'M4.6 8.2l2.3 2.3 4.5-4.7', fill: 'none', stroke: '#fff', 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }));
  } else {
    svg.append(s('circle', { cx: 8, cy: 8, r: 6.2, fill: 'none', stroke: c, 'stroke-width': 1.8 }),
      s('path', { d: 'M5 8h6', stroke: c, 'stroke-width': 1.8, 'stroke-linecap': 'round' }));
  }
  return svg;
}
export function statusBadge(status) {
  const st = STATUS[status] || STATUS.kein_verbrauch;
  return h('span', { class: 'status', title: st.hint }, icon(st.icon, st.color), st.label);
}

// ---- Toast ---------------------------------------------------------------------------
export function toast(msg, isErr) {
  const host = document.getElementById('toasts');
  const t = h('div', { class: 'toast' + (isErr ? ' err' : ''), role: isErr ? 'alert' : 'status' }, msg);
  host.appendChild(t);
  setTimeout(() => t.remove(), isErr ? 7000 : 3500);
}

// ---- Dialoge -------------------------------------------------------------------------
export function openDialog({ title, subtitle, narrow, body, onClose }) {
  const dlg = h('dialog', { class: narrow ? 'narrow' : '' });
  const closeBtn = h('button', { class: 'btn ghost', type: 'button', 'aria-label': 'Schließen', onclick: () => dlg.close() }, '✕');
  dlg.append(
    h('div', { class: 'dlg-head' },
      h('div', null, h('h2', null, title), subtitle ? h('div', { class: 'muted small' }, subtitle) : null),
      closeBtn),
    h('div', { class: 'dlg-body' }, body));
  dlg.addEventListener('close', () => { dlg.remove(); if (onClose) onClose(); });
  dlg.addEventListener('click', (e) => { if (e.target === dlg) dlg.close(); });
  document.body.appendChild(dlg);
  dlg.showModal();
  return dlg;
}

// Formular-Dialog. Gibt true zurueck, wenn gespeichert wurde.
// fields: {name,label,type,required,value,options,step,min,help,full,placeholder}
export function openForm({ title, subtitle, fields, submitLabel = 'Speichern', submit }) {
  return new Promise((resolve) => {
    let saved = false;
    const err = h('p', { class: 'form-error', role: 'alert', hidden: true });
    const inputs = {};
    const grid = h('div', { class: 'form-grid' });
    for (const f of fields) {
      let input;
      if (f.type === 'select') {
        input = h('select', { name: f.name, required: f.required },
          (f.options || []).map((o) => h('option', { value: o.value, selected: String(o.value) === String(f.value ?? '') }, o.label)));
      } else if (f.type === 'textarea') {
        input = h('textarea', { name: f.name, required: f.required, placeholder: f.placeholder, value: f.value ?? '' });
      } else if (f.type === 'checkbox') {
        input = h('input', { type: 'checkbox', name: f.name, checked: !!f.value });
      } else {
        input = h('input', {
          type: f.type === 'number' ? 'text' : (f.type || 'text'), inputmode: f.type === 'number' ? 'decimal' : null,
          name: f.name, required: f.required, placeholder: f.placeholder, value: f.value ?? '',
        });
      }
      inputs[f.name] = { el: input, def: f };
      grid.appendChild(h('label', { class: f.full || f.type === 'textarea' ? 'full' : '' },
        f.label + (f.required ? ' *' : ''), input, f.help ? h('span', { class: 'small muted' }, f.help) : null));
    }
    const okBtn = h('button', { class: 'btn primary', type: 'submit' }, submitLabel);
    const form = h('form', { class: 'dlg-body', style: 'padding:0;overflow:visible' }, grid, err,
      h('div', { class: 'dlg-actions' },
        h('button', { class: 'btn', type: 'button', onclick: () => dlg.close() }, 'Abbrechen'), okBtn));
    const dlg = openDialog({ title, subtitle, narrow: true, body: form, onClose: () => resolve(saved) });
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const values = {};
      for (const [name, { el, def }] of Object.entries(inputs)) {
        if (def.type === 'checkbox') values[name] = el.checked;
        else if (def.type === 'number') values[name] = parseNum(el.value);
        else values[name] = el.value.trim() === '' ? null : el.value.trim();
        if (def.type === 'number' && Number.isNaN(values[name])) {
          err.textContent = `${def.label}: bitte eine Zahl eingeben.`; err.hidden = false; return;
        }
      }
      err.hidden = true; okBtn.disabled = true;
      try {
        await submit(values);
        saved = true; dlg.close();
      } catch (ex) {
        err.textContent = ex.message || String(ex); err.hidden = false; okBtn.disabled = false;
      }
    });
    const first = grid.querySelector('input,select,textarea'); if (first) first.focus();
  });
}
