// Bestandsverlauf als Linie (eine Reihe) mit Prognose, Fadenkreuz und Tooltip.
import { h, s, num0, num1, signed, fmtDate, fmtShort, dayNum, dayToIso } from './ui.js';

function niceStep(raw) {
  const p = Math.pow(10, Math.floor(Math.log10(raw || 1)));
  const f = raw / p;
  return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p;
}

// points: [{date, value, bestellbar, korrektur}]; usage: Tagesverbrauch (optional)
// arrivals: [{date, qty, supplier}] erwartete Lieferungen
export function stockChart(host, { points, usage, arrivals = [] }) {
  host.textContent = '';
  if (!points.length) { host.appendChild(h('p', { class: 'muted' }, 'Noch keine Verlaufsdaten.')); return () => {}; }
  const tip = h('div', { class: 'chart-tip', hidden: true });
  const wrap = h('div', { class: 'chart' });
  host.appendChild(wrap);
  let svg = null; let idx = points.length - 1;

  function draw() {
    const W = Math.max(300, wrap.clientWidth || host.clientWidth || 640);
    const H = Math.round(Math.max(210, Math.min(300, W * 0.36)));
    const m = { l: 46, r: 62, t: 14, b: 26 };
    const last = points[points.length - 1];
    const x0 = dayNum(points[0].date), xl = dayNum(last.date);
    // Prognoselinie: ohne Lieferungen, bis Bestand 0 oder maximal 75 Tage.
    let proj = null;
    if (usage > 0 && last.value > 0) {
      const days = Math.min(75, Math.ceil(last.value / usage));
      proj = { d0: xl, v0: last.value, d1: xl + days, v1: Math.max(0, last.value - usage * days), empty: last.value / usage <= 75 };
    }
    const xMax = Math.max(xl, proj ? proj.d1 : xl);
    const xs = xMax === x0 ? x0 + 1 : xMax;
    const yTop = Math.max(...points.map((p) => p.value), last.value, 1) * 1.08;
    const step = niceStep(yTop / 4);
    const yMax = Math.ceil(yTop / step) * step;
    const X = (d) => m.l + ((d - x0) / (xs - x0)) * (W - m.l - m.r);
    const Y = (v) => H - m.b - (v / yMax) * (H - m.t - m.b);

    svg = s('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', tabindex: 0,
      'aria-label': `Verlauf des bestellbaren Bestands, letzter Wert ${num0(last.value)} am ${fmtDate(last.date)}` });
    const grid = s('g', { class: 'grid' }); const axis = s('g', { class: 'axis' });
    for (let v = 0; v <= yMax + 1e-9; v += step) {
      if (v > 0) grid.append(s('line', { x1: m.l, x2: W - m.r, y1: Y(v), y2: Y(v) }));
      axis.append(s('text', { x: m.l - 8, y: Y(v) + 4, 'text-anchor': 'end' }, num0(v)));
    }
    const ticks = 5;
    for (let i = 0; i < ticks; i++) {
      const d = Math.round(x0 + ((xs - x0) * i) / (ticks - 1));
      axis.append(s('text', { x: X(d), y: H - 7, 'text-anchor': i === 0 ? 'start' : i === ticks - 1 ? 'end' : 'middle' }, fmtShort(dayToIso(d))));
    }
    svg.append(grid, s('g', { class: 'base' }, s('line', { x1: m.l, x2: W - m.r, y1: Y(0), y2: Y(0) })), axis);

    const pts = points.map((p) => [X(dayNum(p.date)), Y(p.value)]);
    const line = pts.map((p, i) => `${i ? 'L' : 'M'}${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join('');
    svg.append(
      s('path', { d: `${line}L${pts[pts.length - 1][0].toFixed(1)} ${Y(0)}L${pts[0][0].toFixed(1)} ${Y(0)}Z`, fill: 'var(--series-1)', 'fill-opacity': 0.10 }),
      s('path', { d: line, fill: 'none', stroke: 'var(--series-1)', 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
    if (proj) {
      svg.append(s('path', { d: `M${X(proj.d0)} ${Y(proj.v0)}L${X(proj.d1)} ${Y(proj.v1)}`, fill: 'none', stroke: 'var(--series-1)',
        'stroke-opacity': 0.65, 'stroke-width': 2, 'stroke-dasharray': '6 5', 'stroke-linecap': 'round' }));
      if (proj.empty) {
        svg.append(s('circle', { cx: X(proj.d1), cy: Y(0), r: 4.5, fill: 'var(--surface)', stroke: 'var(--series-1)', 'stroke-width': 2 }),
          s('text', { x: X(proj.d1), y: Y(0) - 10, 'text-anchor': 'end', class: 'endlabel', style: 'font-weight:400;fill:var(--ink-2)' }, `leer ca. ${fmtShort(dayToIso(proj.d1))}`));
      }
    }
    for (const a of arrivals) {
      const d = dayNum(a.date); if (d < x0 || d > xs) continue;
      const cx = X(d), cy = Y(0);
      svg.append(s('path', { d: `M${cx} ${cy - 7}l6 7l-6 7l-6-7z`, fill: 'var(--ink)', stroke: 'var(--surface)', 'stroke-width': 2 }));
    }
    svg.append(s('circle', { cx: pts[pts.length - 1][0], cy: pts[pts.length - 1][1], r: 4.5, fill: 'var(--series-1)', stroke: 'var(--surface)', 'stroke-width': 2 }),
      s('text', { x: pts[pts.length - 1][0] + 9, y: pts[pts.length - 1][1] + 4, class: 'endlabel' }, num0(last.value)));

    const cross = s('line', { y1: m.t, y2: Y(0), stroke: 'var(--muted)', 'stroke-width': 1, visibility: 'hidden' });
    const dot = s('circle', { r: 5, fill: 'var(--series-1)', stroke: 'var(--surface)', 'stroke-width': 2, visibility: 'hidden' });
    const hit = s('rect', { x: m.l, y: 0, width: W - m.l - m.r, height: H, fill: 'transparent' });
    svg.append(cross, dot, hit);

    function show(i) {
      idx = Math.max(0, Math.min(points.length - 1, i));
      const p = points[idx], px = pts[idx][0], py = pts[idx][1];
      cross.setAttribute('x1', px); cross.setAttribute('x2', px); cross.setAttribute('visibility', 'visible');
      dot.setAttribute('cx', px); dot.setAttribute('cy', py); dot.setAttribute('visibility', 'visible');
      const prev = idx > 0 ? points[idx - 1] : null;
      const rows = [
        h('div', { class: 'd' }, fmtDate(p.date)),
        h('div', { class: 'r' }, h('span', { class: 'key' }), h('b', null, num0(p.value)), h('span', { class: 'muted' }, 'bestellbar')),
      ];
      if (p.lager != null) rows.push(h('div', { class: 'muted' }, `Lager (stock_qty) ${num0(p.lager)}`));
      if (prev) { const dlt = p.value - prev.value; rows.push(h('div', { class: 'muted' }, `Veränderung ${signed(dlt)}`)); }
      if (p.korrektur) rows.push(h('div', null, `Inventurkorrektur ${signed(p.korrektur)}`));
      for (const a of arrivals) if (a.date === p.date) rows.push(h('div', null, `Lieferung erwartet: ${num0(a.qty)}`));
      tip.textContent = ''; tip.append(...rows); tip.hidden = false;
      const left = Math.min(Math.max(px * (wrap.clientWidth / W) + 12, 0), wrap.clientWidth - 170);
      tip.style.left = `${left}px`; tip.style.top = `${Math.max(0, py * (wrap.clientWidth / W) - 24)}px`;
    }
    function hide() { cross.setAttribute('visibility', 'hidden'); dot.setAttribute('visibility', 'hidden'); tip.hidden = true; }
    hit.addEventListener('pointermove', (e) => {
      const r = svg.getBoundingClientRect();
      const x = ((e.clientX - r.left) / r.width) * W;
      let best = 0, bd = Infinity;
      pts.forEach((p, i) => { const d = Math.abs(p[0] - x); if (d < bd) { bd = d; best = i; } });
      show(best);
    });
    hit.addEventListener('pointerleave', hide);
    svg.addEventListener('focus', () => show(idx));
    svg.addEventListener('blur', hide);
    svg.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowLeft') { e.preventDefault(); show(idx - 1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); show(idx + 1); }
      else if (e.key === 'Escape') hide();
    });
    wrap.textContent = ''; wrap.append(svg, tip);
  }

  draw();
  let raf = 0, lastW = wrap.clientWidth;
  const ro = new ResizeObserver(() => {
    if (Math.abs(wrap.clientWidth - lastW) < 4) return;
    lastW = wrap.clientWidth; cancelAnimationFrame(raf); raf = requestAnimationFrame(draw);
  });
  ro.observe(wrap);
  return () => ro.disconnect();
}

// Tabellenansicht derselben Daten (Zugang ohne Maus).
export function stockTable(points) {
  const body = [...points].reverse().map((p) => h('tr', null,
    h('td', null, fmtDate(p.date)), h('td', { class: 'num' }, num0(p.value)), h('td', { class: 'num' }, num0(p.lager)),
    h('td', { class: 'num' }, p.korrektur ? signed(p.korrektur) : '')));
  return h('div', { class: 'table-wrap', style: 'max-height:260px' }, h('table', null,
    h('thead', null, h('tr', null, h('th', null, 'Datum'), h('th', { class: 'num' }, 'Bestellbar'), h('th', { class: 'num' }, 'Lager'), h('th', { class: 'num' }, 'Korrektur'))),
    h('tbody', null, body)));
}

// ---- Absatz je Monat, Jahre im Vergleich (eine Linie je Jahr) -------------------------------
const MONTHS = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];
const YEAR_BASE = 2021;   // feste Farbe je Jahr: 2021 = Reihe 1, 2022 = Reihe 2, ...
const slotOf = (y) => Math.min(8, Math.max(1, y - YEAR_BASE + 1));

// data: [{year, month, qty}]
export function yearsChart(host, data) {
  host.textContent = '';
  if (!data.length) { host.appendChild(h('p', { class: 'muted' }, 'Keine Absatzdaten.')); return () => {}; }
  const years = [...new Set(data.map((d) => d.year))].sort().slice(-8);
  const val = {}; for (const d of data) (val[d.year] ||= {})[d.month] = Number(d.qty);
  const tip = h('div', { class: 'chart-tip', hidden: true }); const wrap = h('div', { class: 'chart' });
  host.append(wrap, h('div', { class: 'legend' }, years.map((y) => h('span', null, h('i', { style: `border-color:var(--series-${slotOf(y)})` }), String(y)))));
  let svg = null;

  function draw() {
    const W = Math.max(300, wrap.clientWidth || 640); const H = Math.round(Math.max(200, Math.min(280, W * 0.34)));
    const m = { l: 46, r: 40, t: 14, b: 26 };
    const max = Math.max(1, ...years.flatMap((y) => Object.values(val[y] || {})));
    const step = niceStep(max * 1.08 / 4); const yMax = Math.ceil(max * 1.08 / step) * step;
    const X = (mo) => m.l + ((mo - 1) / 11) * (W - m.l - m.r); const Y = (v) => H - m.b - (v / yMax) * (H - m.t - m.b);
    svg = s('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': `Absatz je Monat, Jahre ${years[0]} bis ${years[years.length - 1]} im Vergleich` });
    const grid = s('g', { class: 'grid' }); const axis = s('g', { class: 'axis' });
    for (let v = 0; v <= yMax + 1e-9; v += step) { if (v > 0) grid.append(s('line', { x1: m.l, x2: W - m.r, y1: Y(v), y2: Y(v) })); axis.append(s('text', { x: m.l - 8, y: Y(v) + 4, 'text-anchor': 'end' }, num0(v))); }
    MONTHS.forEach((name, i) => axis.append(s('text', { x: X(i + 1), y: H - 7, 'text-anchor': 'middle' }, name)));
    svg.append(grid, s('g', { class: 'base' }, s('line', { x1: m.l, x2: W - m.r, y1: Y(0), y2: Y(0) })), axis);
    for (const y of years) {
      const pts = Object.keys(val[y]).map(Number).sort((a, b) => a - b); let d = ''; let prev = null;
      for (const mo of pts) { d += `${prev != null && mo === prev + 1 ? 'L' : 'M'}${X(mo).toFixed(1)} ${Y(val[y][mo]).toFixed(1)}`; prev = mo; }
      const col = `var(--series-${slotOf(y)})`;
      svg.append(s('path', { d, fill: 'none', stroke: col, 'stroke-width': 2, 'stroke-linejoin': 'round', 'stroke-linecap': 'round' }));
      const lm = pts[pts.length - 1];
      svg.append(s('circle', { cx: X(lm), cy: Y(val[y][lm]), r: 4, fill: col, stroke: 'var(--surface)', 'stroke-width': 2 }));
      if (y === years[years.length - 1]) svg.append(s('text', { x: X(lm) + 8, y: Y(val[y][lm]) + 4, class: 'endlabel' }, String(y)));
    }
    const cross = s('line', { y1: m.t, y2: Y(0), stroke: 'var(--muted)', 'stroke-width': 1, visibility: 'hidden' });
    const hit = s('rect', { x: m.l - 10, y: 0, width: W - m.l - m.r + 20, height: H, fill: 'transparent' });
    svg.append(cross, hit);
    function show(mo, px, py) {
      cross.setAttribute('x1', X(mo)); cross.setAttribute('x2', X(mo)); cross.setAttribute('visibility', 'visible');
      const rows = [h('div', { class: 'd' }, MONTHS[mo - 1])];
      for (const y of [...years].reverse()) if (val[y] && val[y][mo] != null)
        rows.push(h('div', { class: 'r' }, h('span', { class: 'key', style: `border-top-color:var(--series-${slotOf(y)})` }), h('b', null, num0(val[y][mo])), h('span', { class: 'muted' }, String(y))));
      tip.textContent = ''; tip.append(...rows); tip.hidden = false;
      const left = Math.min(Math.max(X(mo) * (wrap.clientWidth / W) + 12, 0), wrap.clientWidth - 170);
      tip.style.left = `${left}px`; tip.style.top = `${Math.max(0, py * (wrap.clientWidth / W) - 24)}px`;
    }
    hit.addEventListener('pointermove', (e) => {
      const r = svg.getBoundingClientRect(); const x = ((e.clientX - r.left) / r.width) * W; const y = ((e.clientY - r.top) / r.height) * H;
      show(Math.min(12, Math.max(1, Math.round(1 + ((x - m.l) / (W - m.l - m.r)) * 11))), x, y);
    });
    hit.addEventListener('pointerleave', () => { cross.setAttribute('visibility', 'hidden'); tip.hidden = true; });
    wrap.textContent = ''; wrap.append(svg, tip);
  }
  draw();
  let raf = 0, lastW = wrap.clientWidth;
  const ro = new ResizeObserver(() => { if (Math.abs(wrap.clientWidth - lastW) < 4) return; lastW = wrap.clientWidth; cancelAnimationFrame(raf); raf = requestAnimationFrame(draw); });
  ro.observe(wrap);
  return () => ro.disconnect();
}

export function yearsTable(data) {
  const years = [...new Set(data.map((d) => d.year))].sort().slice(-8); const val = {};
  for (const d of data) (val[d.year] ||= {})[d.month] = Number(d.qty);
  return h('div', { class: 'table-wrap', style: 'max-height:260px' }, h('table', null,
    h('thead', null, h('tr', null, h('th', null, 'Monat'), years.map((y) => h('th', { class: 'num' }, String(y))))),
    h('tbody', null, MONTHS.map((name, i) => h('tr', null, h('td', null, name), years.map((y) => h('td', { class: 'num' }, val[y] && val[y][i + 1] != null ? num0(val[y][i + 1]) : '')))))));
}
