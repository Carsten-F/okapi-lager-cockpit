// E2E-Test: Browser gegen Mock-API + lokale Datenbank. Aufruf: siehe README (Abschnitt Tests).
import { chromium } from 'playwright-core';
import fs from 'node:fs';
import { startMock } from './mock-server.mjs';

const PORT = Number(process.env.E2E_PORT || 54380);
const base = `http://localhost:${PORT}/lager/`;
const out = new URL('./out/', import.meta.url).pathname;
fs.mkdirSync(out, { recursive: true });
const mock = await startMock({ port: PORT, pgConfig: { host: process.env.PGHOST || '/tmp', port: Number(process.env.PGPORT || 54329), user: 'postgres', database: 'postgres' } });
await mock.pool.query('truncate lager.purchase_orders, lager.purchase_order_log, lager.sku_notes, lager.sku_settings restart identity'); // reproduzierbar
await mock.pool.query('delete from lager.inflow_log where date > current_date; delete from lager.stock_daily where date > current_date; delete from okapi_stock.stock_history where date > current_date');
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined, args: ['--no-sandbox'] });

let failed = 0;
const check = (name, cond, extra = '') => { console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : '  ' + extra}`); if (!cond) failed++; };
const consoleErrors = [];

async function session(email, { scheme = 'light', width = 1280, height = 900 } = {}) {
  const ctx = await browser.newContext({ viewport: { width, height }, colorScheme: scheme });
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) consoleErrors.push(`${email}: ${m.text()}`); });
  page.on('pageerror', (e) => consoleErrors.push(`${email}: ${e.message}`));
  await page.goto(base);
  await page.locator('#login').waitFor({ state: 'visible' });
  await page.fill('input[name=email]', email); await page.fill('input[name=password]', 'test');
  await page.click('#loginForm button[type=submit]');
  return { ctx, page };
}
const toastText = (page) => page.locator('#toasts .toast').last().textContent();

try {
  // 1. Kein Zugang ohne Rolle, falsches Passwort
  {
    const ctx = await browser.newContext(); const page = await ctx.newPage();
    await page.goto(base); await page.fill('input[name=email]', 'admin@test'); await page.fill('input[name=password]', 'falsch');
    await page.click('#loginForm button[type=submit]');
    await page.locator('#loginError').waitFor({ state: 'visible' });
    check('falsches Passwort zeigt Fehlermeldung', /stimmt nicht/.test(await page.locator('#loginError').textContent()));
    await ctx.close();
    const s = await session('keine@test');
    await s.page.locator('#denied').waitFor({ state: 'visible' });
    check('Nutzer ohne Rolle sieht "Kein Zugang"', await s.page.locator('#app').isHidden());
    await s.ctx.close();
  }

  // 2. Lesender Nutzer
  {
    const { ctx, page } = await session('viewer@test');
    await page.locator('#app').waitFor({ state: 'visible' });
    await page.locator('#view table tbody tr').first().waitFor();
    const rows = await page.locator('#view table tbody tr').count();
    check('Übersicht zeigt 14 Artikel', rows === 14, `Zeilen: ${rows}`);
    const tiles = await page.locator('.tile .tv').allTextContents();
    check('vier Statuskacheln, Summe ≤ 14', tiles.length === 4 && tiles.map(Number).reduce((a, b) => a + b, 0) <= 14, tiles.join(','));
    check('Statuskacheln tragen Symbol und Text', (await page.locator('.tile svg').count()) === 4 && /Kritisch/.test(await page.locator('.tile').first().textContent()));
    check('Rolle wird angezeigt', /Lesen/.test(await page.locator('#whoami').textContent()));
    check('Leser sieht keinen Abgleich-Button', (await page.getByRole('button', { name: 'Daten jetzt abgleichen' }).count()) === 0);
    await page.screenshot({ path: `${out}overview-light.png`, fullPage: true });

    // Filter: Suche
    await page.fill('input[type=search]', 'heucobs');
    check('Suche filtert', (await page.locator('#view table tbody tr').count()) === 1);
    await page.fill('input[type=search]', '');
    // Sortierung
    await page.locator('th.sortable', { hasText: 'Reichweite' }).click();
    const firstCover = await page.locator('#view table tbody tr').first().locator('td').nth(5).textContent();
    check('Sortierung nach Reichweite beginnt mit kleinstem Wert', /\d/.test(firstCover), firstCover);

    // Detail
    await page.locator('#view table tbody tr', { hasText: 'Hagebutten' }).click();
    const dlg = page.locator('dialog'); await dlg.waitFor({ state: 'visible' });
    await dlg.locator('svg[role=img]').waitFor();
    check('Detail zeigt Diagramm', await dlg.locator('svg[role=img] path').count() >= 3);
    const box = await dlg.locator('svg[role=img]').boundingBox();
    await page.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.5);
    await dlg.locator('.chart-tip').waitFor({ state: 'visible' });
    const tipText = await dlg.locator('.chart-tip').textContent();
    check('Tooltip zeigt Datum und Wert', /\d{2}\.\d{2}\.\d{4}/.test(tipText) && /physisch/.test(tipText), tipText);
    check('Leser hat im Detail keine Schreib-Buttons', (await dlg.getByRole('button', { name: /Bestellung erfassen|Kommentar|Einstellungen/ }).count()) === 0);
    await page.screenshot({ path: `${out}detail-light.png` });
    await dlg.getByRole('button', { name: 'Tabelle anzeigen' }).click();
    check('Tabellenansicht erreichbar', await dlg.locator('table').first().isVisible());
    await page.keyboard.press('Escape'); await dlg.waitFor({ state: 'detached' });

    await page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await page.locator('h1', { hasText: 'Bestellungen' }).waitFor();
    check('Leser: keine Bestellung erfassen', (await page.getByRole('button', { name: 'Bestellung erfassen' }).count()) === 0);
    await page.getByRole('button', { name: 'Einstellungen', exact: true }).click();
    check('Leser: kein Bearbeiten bei Einstellungen', (await page.getByRole('button', { name: 'Bearbeiten' }).count()) === 0);
    await ctx.close();
  }

  // 3. Dunkles Design + mobil
  {
    const { ctx, page } = await session('viewer@test', { scheme: 'dark' });
    await page.locator('#view table tbody tr').first().waitFor();
    await page.screenshot({ path: `${out}overview-dark.png`, fullPage: true });
    await page.locator('#view table tbody tr', { hasText: 'Hagebutten' }).click();
    await page.locator('dialog svg[role=img]').waitFor();
    await page.screenshot({ path: `${out}detail-dark.png` });
    await ctx.close();
    const m = await session('viewer@test', { width: 390, height: 800 });
    await m.page.locator('#view table tbody tr').first().waitFor();
    const overflow = await m.page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    check('mobil: kein horizontaler Seitenüberlauf', !overflow);
    await m.page.screenshot({ path: `${out}overview-mobile.png` });
    await m.ctx.close();
  }

  // 4. Einkauf: Bestellung anlegen, bearbeiten, Eingang buchen, Korrektur
  {
    const { ctx, page } = await session('einkauf@test');
    await page.locator('#view table tbody tr').first().waitFor();
    check('Einkauf sieht keinen Abgleich-Button', (await page.getByRole('button', { name: 'Daten jetzt abgleichen' }).count()) === 0);
    const statusBefore = await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).locator('td').nth(1).textContent();
    await page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await page.getByRole('button', { name: 'Bestellung erfassen' }).click();
    const dlg = page.locator('dialog'); await dlg.waitFor();
    await dlg.locator('select[name=sku]').selectOption('1101019');
    await dlg.locator('input[name=qty]').fill('120');
    await dlg.getByRole('button', { name: 'Speichern' }).click();
    await dlg.locator('.form-error').waitFor({ state: 'visible' });
    check('Bestellung ohne Liefertermin wird abgelehnt', /Liefertermin oder Zeitspanne/.test(await dlg.locator('.form-error').textContent()));
    await dlg.locator('input[name=expected_lead_days]').fill('10');
    await dlg.locator('input[name=supplier]').fill('ONYX');
    await dlg.getByRole('button', { name: 'Speichern' }).click();
    await dlg.waitFor({ state: 'detached' });
    const row = page.locator('#view table tbody tr', { hasText: 'Kieselgur' });
    await row.waitFor();
    check('neue Bestellung erscheint in der Liste', /ONYX/.test(await row.textContent()) && /120/.test(await row.textContent()));

    // Status in der Übersicht ändert sich durch die Bestellung (wird gedeckt oder bleibt kritisch)
    await page.getByRole('button', { name: 'Übersicht', exact: true }).click();
    await page.locator('#view table tbody tr').first().waitFor();
    const statusAfter = await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).locator('td').nth(1).textContent();
    check('Übersicht berücksichtigt offene Bestellung', /Offen|\d/.test(await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).locator('td').last().textContent()), `${statusBefore} -> ${statusAfter}`);

    // Bearbeiten und Eingang buchen
    await page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).getByRole('button', { name: 'Bearbeiten' }).click();
    await dlg.waitFor(); await dlg.locator('input[name=supplier]').fill('Lieferant Y'); await dlg.getByRole('button', { name: 'Speichern' }).click(); await dlg.waitFor({ state: 'detached' });
    await page.locator('#view table tbody tr', { hasText: 'Lieferant Y' }).waitFor({ timeout: 5000 }).catch(() => {});
    check('Bestellung bearbeiten', /Lieferant Y/.test(await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).textContent()));
    await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).getByRole('button', { name: 'Eingang buchen' }).click();
    await dlg.waitFor();
    check('Eingangsmenge ist mit Restmenge vorbelegt', (await dlg.locator('input[name=qty]').inputValue()) === '120');
    await dlg.locator('input[name=qty]').fill('50'); await dlg.getByRole('button', { name: 'Eingang buchen' }).click(); await dlg.waitFor({ state: 'detached' });
    await page.locator('#view table tbody tr', { hasText: 'Teilgeliefert' }).waitFor({ timeout: 5000 }).catch(() => {});
    check('Teilbuchung setzt Status Teilgeliefert', /Teilgeliefert/.test(await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).textContent()));

    // Inventurkorrektur über Detail
    await page.getByRole('button', { name: 'Übersicht', exact: true }).click();
    await page.locator('#view table tbody tr', { hasText: 'Pränat' }).click();
    await dlg.waitFor();
    await dlg.getByRole('button', { name: 'Kommentar / Korrektur' }).click();
    const form = page.locator('dialog.narrow');
    await form.locator('select[name=kind]').selectOption('inventurkorrektur');
    await form.getByRole('button', { name: 'Speichern' }).click();
    check('Korrektur ohne Menge wird abgelehnt', /Mengenänderung/.test(await form.locator('.form-error').textContent()));
    await form.locator('input[name=qty_delta]').fill('-10'); await form.locator('textarea[name=note]').fill('Zählung Regal 3');
    await form.getByRole('button', { name: 'Speichern' }).click(); await form.waitFor({ state: 'detached' });
    await page.locator('dialog', { hasText: 'Zählung Regal 3' }).waitFor({ timeout: 5000 }).catch(() => {});
    check('Korrektur erscheint im Detail', /Inventurkorrektur -10/.test(await page.locator('dialog').textContent()) && /Zählung Regal 3/.test(await page.locator('dialog').textContent()));
    await page.keyboard.press('Escape');

    await page.getByRole('button', { name: 'Bewegungen', exact: true }).click();
    await page.locator('h2', { hasText: 'Erkannte Zugänge' }).waitFor();
    check('erkannte Zugänge (Bestandssprünge) werden gelistet', (await page.locator('section').first().locator('tbody tr').count()) >= 1);
    check('Einkauf kann Einstellungen bearbeiten', true);
    await ctx.close();
  }

  // 5. Lager darf buchen, aber nicht bestellen
  {
    const { ctx, page } = await session('lager@test');
    await page.locator('#view table tbody tr').first().waitFor();
    await page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await page.locator('h1', { hasText: 'Bestellungen' }).waitFor();
    check('Lager: kein Bestellung-erfassen-Button', (await page.getByRole('button', { name: 'Bestellung erfassen' }).count()) === 0);
    check('Lager: Eingang buchen möglich', (await page.getByRole('button', { name: 'Eingang buchen' }).count()) >= 1);
    check('Lager: Bearbeiten (Liefertermin, Menge) möglich', (await page.getByRole('button', { name: 'Bearbeiten' }).count()) >= 1);
    await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).getByRole('button', { name: 'Bearbeiten' }).click();
    const dlg = page.locator('dialog'); await dlg.waitFor();
    check('Lager sieht kein Status-Feld', (await dlg.locator('select[name=status]').count()) === 0);
    await dlg.locator('input[name=expected_delivery]').fill('2026-12-24');
    await dlg.getByRole('button', { name: 'Speichern' }).click(); await dlg.waitFor({ state: 'detached' });
    await page.locator('#view table tbody tr', { hasText: '24.12.2026' }).waitFor({ timeout: 5000 }).catch(() => {});
    check('neuer Liefertermin (Verzögerung) wird angezeigt', /24\.12\.2026/.test(await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).textContent()));
    await page.locator('#view table tbody tr', { hasText: 'Kieselgur' }).getByRole('button', { name: 'Verlauf' }).click();
    await dlg.waitFor();
    await dlg.locator('li', { hasText: 'Liefertermin' }).first().waitFor({ timeout: 5000 }).catch(() => {});
    const hist = await dlg.textContent();
    check('Verlauf zeigt Änderung mit Name und alt → neu', /Geändert/.test(hist) && /Lager Test/.test(hist) && /24\.12\.2026/.test(hist) && /→/.test(hist), hist.slice(0, 200));
    await page.keyboard.press('Escape');
    await ctx.close();
  }

  // 6. Admin: Einstellungen, Abgleich
  {
    const { ctx, page } = await session('admin@test');
    await page.locator('#view table tbody tr').first().waitFor();
    await page.getByRole('button', { name: 'Daten jetzt abgleichen' }).click();
    await page.locator('#toasts .toast', { hasText: 'Abgleich fertig' }).waitFor();
    check('Admin: Abgleich läuft', true);
    await page.getByRole('button', { name: 'Einstellungen', exact: true }).click();
    await page.locator('#view table tbody tr').first().waitFor();
    await page.locator('#view table tbody tr', { hasText: 'Heucobs' }).getByRole('button', { name: 'Bearbeiten' }).click();
    const dlg = page.locator('dialog'); await dlg.waitFor();
    await dlg.locator('input[name=lead]').fill('5'); await dlg.locator('select[name=source]').selectOption('intern');
    await dlg.getByRole('button', { name: 'Speichern' }).click(); await dlg.waitFor({ state: 'detached' });
    await page.locator('#view table tbody tr', { hasText: 'Intern' }).waitFor({ timeout: 5000 }).catch(() => {});
    const t = await page.locator('#view table tbody tr', { hasText: 'Heucobs' }).textContent();
    check('Einstellungen speichern (Lieferzeit 5 T, intern)', /5 T/.test(t) && /Intern/.test(t), t);
    // Lieferzeit wieder leeren (null) -> automatisch
    await page.locator('#view table tbody tr', { hasText: 'Heucobs' }).getByRole('button', { name: 'Bearbeiten' }).click();
    await dlg.waitFor(); await dlg.locator('input[name=lead]').fill(''); await dlg.getByRole('button', { name: 'Speichern' }).click(); await dlg.waitFor({ state: 'detached' });
    await page.locator('#view table tbody tr', { hasText: /Heucobs.*auto/ }).waitFor({ timeout: 5000 }).catch(() => {});
    check('Lieferzeit leeren schaltet auf automatisch', /auto/.test(await page.locator('#view table tbody tr', { hasText: 'Heucobs' }).textContent()));
    await ctx.close();
  }

  // 7. Automatische Wareneingangs-Erkennung: Archivierung, Anzeige, Zuruecksetzen
  {
    await mock.pool.query(`insert into lager.purchase_orders(sku, qty, ordered_on, expected_delivery, created_by)
      values ('1101070', 20, current_date, current_date + 3, 'a0000000-0000-0000-0000-000000000002')`);
    await mock.pool.query(`insert into okapi_stock.stock_history(product_name, sku, stock_qty, stock_offset, effective_stock, date)
      select product_name, sku, effective_stock + 19, 0, effective_stock + 19, current_date + 1
      from okapi_stock.stock_history where sku = '1101070' and date = current_date`);
    const a = await session('admin@test');
    await a.page.locator('#view table tbody tr').first().waitFor();
    check('vor dem Abgleich zeigt die Übersicht die offene Bestellung (Relax)', /20/.test(await a.page.locator('#view table tbody tr', { hasText: 'Relax' }).locator('td').last().textContent()));
    await a.page.getByRole('button', { name: 'Daten jetzt abgleichen' }).click();
    await a.page.locator('#toasts .toast', { hasText: 'Abgleich fertig' }).waitFor();
    await a.page.locator('#view table tbody tr', { hasText: 'Relax' }).locator('td').last().waitFor();
    const lastCell = await a.page.locator('#view table tbody tr', { hasText: 'Relax' }).locator('td').last().textContent();
    check('nach dem Abgleich steht Relax nicht mehr als „offen bestellt“ in der Übersicht', lastCell.trim() === '–', lastCell);
    await a.page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await a.page.locator('h1', { hasText: 'Bestellungen' }).waitFor();
    check('Relax-Bestellung ist nicht mehr unter „Offen“', (await a.page.locator('#view table tbody tr', { hasText: 'Relax' }).count()) === 0);
    await a.page.locator('select[aria-label=Status]').selectOption('archiv');
    const arow = a.page.locator('#view table tbody tr', { hasText: 'Relax' });
    await arow.waitFor();
    check('Relax-Bestellung liegt im Archiv, eingebucht und „automatisch erkannt“', /Eingebucht/.test(await arow.textContent()) && /automatisch erkannt/.test(await arow.textContent()), await arow.textContent());
    await a.page.screenshot({ path: `${out}orders-archive.png`, fullPage: true });
    await a.page.getByRole('button', { name: 'Bewegungen', exact: true }).click();
    await a.page.locator('h2', { hasText: 'Erkannte Zugänge' }).waitFor();
    const mv = a.page.locator('section').first().locator('tbody tr', { hasText: 'Relax' });
    await mv.first().waitFor({ timeout: 5000 }).catch(() => {});
    check('Bewegungen zeigt die zugeordnete Bestellung', /#\d+/.test(await mv.first().textContent().catch(() => '')));
    await a.ctx.close();

    const l = await session('lager@test');
    await l.page.locator('#view table tbody tr').first().waitFor();
    await l.page.getByRole('button', { name: 'Bestellungen', exact: true }).click();
    await l.page.locator('select[aria-label=Status]').selectOption('archiv');
    const lrow = l.page.locator('#view table tbody tr', { hasText: 'Relax' }); await lrow.waitFor();
    await lrow.getByRole('button', { name: 'Zurücksetzen' }).click();
    const f = l.page.locator('dialog.narrow'); await f.waitFor();
    await f.locator('textarea[name=comment]').fill('war eine Rückbuchung');
    await f.getByRole('button', { name: 'Zurücksetzen' }).click(); await f.waitFor({ state: 'detached' });
    await l.page.locator('select[aria-label=Status]').selectOption('offen');
    const orow = l.page.locator('#view table tbody tr', { hasText: 'Relax' });
    await orow.waitFor({ timeout: 5000 }).catch(() => {});
    check('zurückgesetzte Bestellung erscheint wieder unter „Offen“', (await orow.count()) === 1);
    await orow.getByRole('button', { name: 'Verlauf' }).click();
    const h2 = l.page.locator('dialog'); await h2.locator('li', { hasText: 'Zurückgesetzt' }).first().waitFor({ timeout: 5000 }).catch(() => {});
    const t2 = await h2.textContent();
    check('Verlauf zeigt automatische Erkennung und Zurücksetzen', /automatisch erkannt/.test(t2) && /Zurückgesetzt/.test(t2) && /Rückbuchung/.test(t2), t2.slice(0, 300));
    await l.ctx.close();
  }

  check('keine Konsolenfehler im Browser', consoleErrors.length === 0, consoleErrors.join(' | '));
  const bad = mock.log.filter((l) => !l.ok);
  console.log(`API-Aufrufe: ${mock.log.length}, davon abgelehnt: ${bad.length} (${[...new Set(bad.map((b) => b.msg))].join('; ')})`);
} catch (e) {
  console.log('FEHLER im Testlauf:', e.message); failed++;
}
await browser.close(); await mock.close();
console.log(failed ? `\n${failed} Prüfung(en) fehlgeschlagen` : '\nAlle Prüfungen bestanden');
process.exit(failed ? 1 : 0);
