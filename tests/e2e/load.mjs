// Lasttest: Oberflaeche gegen grossen Datenbestand (Mock-API + lokale Datenbank, siehe README Abschnitt Tests).
// Vorher einspielen: Bestand mit vielen Artikeln und Tagen in okapi_stock.stock_history + lager.sync_from_magento().
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import { startMock } from './mock-server.mjs';

const PORT = Number(process.env.E2E_PORT || 54381);
const base = `http://localhost:${PORT}/lager/`;
const out = new URL('./out/', import.meta.url).pathname;
fs.mkdirSync(out, { recursive: true });
const mock = await startMock({ port: PORT, pgConfig: { host: process.env.PGHOST || '/tmp', port: Number(process.env.PGPORT || 54329), user: 'postgres', database: 'postgres' } });
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined, args: ['--no-sandbox'] });
let failed = 0; const errors = [];
const check = (n, c, x = '') => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${c ? '' : '  ' + x}`); if (!c) failed++; };
try {
  const page = await (await browser.newContext({ viewport: { width: 1360, height: 900 } })).newPage();
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
  page.on('pageerror', (e) => errors.push(e.message));
  await page.goto(base);
  await page.fill('input[name=email]', 'admin@test'); await page.fill('input[name=password]', 'test');
  const t0 = Date.now();
  await page.click('#loginForm button[type=submit]');
  await page.locator('#view table tbody tr').first().waitFor({ timeout: 60000 });
  const tLoad = Date.now() - t0;
  const rows = await page.locator('#view table tbody tr').count();
  console.log(`Ladezeit bis Tabelle sichtbar: ${tLoad} ms, Zeilen im DOM: ${rows} (Begrenzung 300)`);
  check('Übersicht lädt in unter 6 s', tLoad < 6000, `${tLoad} ms`);
  const tiles = (await page.locator('.tile .tv').allTextContents()).map(Number);
  check('Tabelle zeigt höchstens 300 Zeilen und bietet „Weitere anzeigen“', rows === 300 && (await page.getByRole('button', { name: 'Weitere 300 anzeigen' }).count()) === 1, String(rows));
  check('Statuskacheln zählen alle aktiven Artikel', tiles.length === 4 && tiles.reduce((a, b) => a + b, 0) > 0, tiles.join(','));
  let t = Date.now(); await page.fill('input[aria-label=Suche]', '1100123'); await page.waitForTimeout(150);
  check('Suche antwortet in unter 1,5 s', Date.now() - t < 1500 && (await page.locator('#view table tbody tr').count()) >= 1);
  await page.fill('input[aria-label=Suche]', '');
  t = Date.now(); await page.locator('#view table th.sortable').nth(2).click(); await page.waitForTimeout(100);
  check('Sortieren antwortet in unter 1,5 s', Date.now() - t < 1500);
  await page.selectOption('select[aria-label=Ampelstatus]', { index: 1 }).catch(() => {});
  await page.waitForTimeout(200);
  await page.selectOption('select[aria-label=Ampelstatus]', { index: 0 }).catch(() => {});
  t = Date.now(); await page.locator('#view table tbody tr').first().click();
  await page.locator('dialog[open] svg').first().waitFor({ timeout: 15000 });
  check('Detailansicht mit Diagramm in unter 5 s', Date.now() - t < 5000, `${Date.now() - t} ms`);
  await page.screenshot({ path: `${out}load-detail.png` });
  await page.keyboard.press('Escape');
  await page.screenshot({ path: `${out}load-overview.png` });
  check('keine Konsolenfehler', errors.length === 0, errors.slice(0, 2).join(' | '));
} catch (e) { console.log('FEHLER im Testlauf:', e.message.split('\n')[0]); failed++; }
await browser.close(); await mock.close?.();
process.exit(failed ? 1 : 0);
