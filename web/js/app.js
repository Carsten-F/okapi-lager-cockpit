import { sb, rpc } from './api.js';
import { h, toast } from './ui.js';
import { renderOverview } from './views/overview.js';
import { renderOrders } from './views/orders.js';
import { renderFlows } from './views/flows.js';
import { renderSettings } from './views/settings.js';

const PERMS = { note: ['lager', 'einkauf', 'admin'], receive: ['lager', 'einkauf', 'admin'], order: ['einkauf', 'admin'], orderEdit: ['lager', 'einkauf', 'admin'], reopen: ['lager', 'einkauf', 'admin'], settings: ['einkauf', 'admin'], sync: ['admin'] };
const ROLE_LABEL = { viewer: 'Lesen', lager: 'Lager', einkauf: 'Einkauf', admin: 'Admin' };
const VIEWS = [
  { id: 'uebersicht', label: 'Übersicht', render: renderOverview },
  { id: 'bestellungen', label: 'Bestellungen', render: renderOrders },
  { id: 'bewegungen', label: 'Bewegungen', render: renderFlows },
  { id: 'einstellungen', label: 'Einstellungen', render: renderSettings },
];
const $ = (id) => document.getElementById(id);
const ctx = {
  role: null, window: 28, data: { forecast: [], stock: [], orders: [], settings: [] },
  can: (p) => (PERMS[p] || []).includes(ctx.role),
  async reloadForecast() { ctx.data.forecast = await rpc('lager_forecast', { p_window_days: ctx.window }); },
  async reload() {
    const [forecast, stock, orders, settings] = await Promise.all([
      rpc('lager_forecast', { p_window_days: ctx.window }), rpc('lager_stock_latest'), rpc('lager_orders_list', { p_status: 'alle' }), rpc('lager_sku_settings_list')]);
    ctx.data = { forecast, stock, orders, settings };
  },
};

// ---- Darstellung hell/dunkel ----------------------------------------------------------
function applyTheme(t) { if (t) document.documentElement.setAttribute('data-theme', t); else document.documentElement.removeAttribute('data-theme'); }
try { applyTheme(localStorage.getItem('okapi-lager-theme')); } catch { /* ohne Speicher weiter */ }
$('themeBtn').addEventListener('click', () => {
  const dark = document.documentElement.getAttribute('data-theme') === 'dark'
    || (!document.documentElement.getAttribute('data-theme') && matchMedia('(prefers-color-scheme: dark)').matches);
  const next = dark ? 'light' : 'dark'; applyTheme(next);
  try { localStorage.setItem('okapi-lager-theme', next); } catch { /* egal */ }
});

// ---- Navigation -----------------------------------------------------------------------
function currentView() { const id = location.hash.replace(/^#\/?/, ''); return VIEWS.find((v) => v.id === id) || VIEWS[0]; }
let rendering = 0;
async function route() {
  const v = currentView(); const my = ++rendering;
  $('nav').replaceChildren(...VIEWS.map((x) => h('button', { type: 'button', 'aria-current': x.id === v.id ? 'page' : null, onclick: () => { location.hash = `#/${x.id}`; } }, x.label)));
  const view = $('view'); view.style.opacity = '0.6';
  try { await v.render(ctx, view); } catch (e) { if (my === rendering) toast(e.message, true); }
  if (my === rendering) view.style.opacity = '';
}
window.addEventListener('hashchange', () => { if (ctx.role) route(); });

// ---- Anmeldung ------------------------------------------------------------------------
function show(which) { for (const id of ['login', 'app', 'denied']) $(id).hidden = id !== which; }
async function enter(session) {
  let who;
  try { who = await rpc('lager_whoami'); } catch (e) { toast(e.message, true); who = null; }
  if (!who?.role) { $('deniedUser').textContent = session.user?.email || ''; show('denied'); return; }
  ctx.role = who.role;
  $('whoami').replaceChildren(who.display_name || session.user?.email || '', h('span', { class: 'role-chip' }, ROLE_LABEL[who.role] || who.role));
  show('app');
  try { await ctx.reload(); } catch (e) { toast(e.message, true); }
  await route();
}
async function logout() { ctx.role = null; await sb.auth.signOut(); show('login'); }
$('logoutBtn').addEventListener('click', logout); $('deniedLogout').addEventListener('click', logout);
$('loginForm').addEventListener('submit', async (e) => {
  e.preventDefault(); const f = e.target; const err = $('loginError'); err.hidden = true;
  const btn = f.querySelector('button[type=submit]'); btn.disabled = true;
  const { data, error } = await sb.auth.signInWithPassword({ email: f.email.value.trim(), password: f.password.value });
  btn.disabled = false;
  if (error) { err.textContent = /invalid/i.test(error.message) ? 'E-Mail oder Passwort stimmt nicht.' : error.message; err.hidden = false; return; }
  f.password.value = ''; await enter(data.session);
});

(async function boot() {
  const { data } = await sb.auth.getSession();
  if (data.session) await enter(data.session); else show('login');
  sb.auth.onAuthStateChange((ev) => { if (ev === 'SIGNED_OUT' && ctx.role) { ctx.role = null; show('login'); } });
})();
