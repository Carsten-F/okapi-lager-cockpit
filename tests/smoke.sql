-- Rauchtest der API-Funktionen. Erwartete Fehler sind mit "erwartet" markiert.
\set VERBOSITY terse
insert into lager.user_roles values
 ('11111111-1111-1111-1111-111111111111','admin','Admin'),
 ('22222222-2222-2222-2222-222222222222','viewer','Viewer'),
 ('44444444-4444-4444-4444-444444444444','lager','Lager'),
 ('55555555-5555-5555-5555-555555555555','einkauf','Einkauf');

\echo == anon (erwartet permission denied)
set role anon; select okapi_stock.lager_forecast(); reset role;

\echo == ohne Rolle (erwartet forbidden)
set role authenticated; set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select okapi_stock.lager_stock_latest();
\echo == direkter Tabellenzugriff (erwartet permission denied)
select * from lager.purchase_orders;
reset role;

\echo == viewer: lesen ok, schreiben verboten (erwartet forbidden)
set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select jsonb_array_length(okapi_stock.lager_stock_latest()) as skus_erwartet_6;
select okapi_stock.lager_note_add('A','kommentar','x');
select okapi_stock.lager_order_add('A',1,current_date);
reset role;

\echo == lager: Notiz ok, Bestellung anlegen verboten (erwartet forbidden)
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select okapi_stock.lager_note_add('D','inventurkorrektur','Zaehlung',-10, current_date-2);
select okapi_stock.lager_note_add('A','kommentar','Palette beschaedigt');
select okapi_stock.lager_order_add('A',1,current_date);
reset role;

\echo == einkauf: Bestellungen A (Eingang in 3 Tagen) und C (Eingang in 30 Tagen)
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select okapi_stock.lager_order_add('C', 100, current_date, current_date+30, null, 'Lieferant X', 'Test');
select okapi_stock.lager_order_add('A', 100, current_date, null, 3, 'ONYX', null);
select okapi_stock.lager_order_add('ZZZ', 1, current_date);
select okapi_stock.lager_order_add('A', -5, current_date);
select okapi_stock.lager_sku_settings_upsert('C', 5, 2, 'extern', 'Lieferant X');
select okapi_stock.lager_sku_settings_upsert('A', null, 7, 'intern');
select okapi_stock.lager_sku_settings_upsert('A', 1, 7, 'foo');
reset role;

\echo == Forecast (Verbrauch D = 2/Tag trotz Korrektur; A = 4.5; B kein Verbrauch)
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select f->>'sku' sku, f->>'status' status, f->>'avg_daily_usage' usage, f->>'days_of_cover' cover,
       f->>'lead_time_days' lead, f->>'lead_time_source' src, f->>'stockout_date_incl_orders' so_incl, f->>'incoming_qty' incoming
from jsonb_array_elements(okapi_stock.lager_forecast()) f;

\echo == Wareneingang buchen, Lieferzeit wird beobachtet
select okapi_stock.lager_order_receive(2, current_date, 100);
select okapi_stock.lager_order_receive(1, current_date, 30);
select f->>'sku' sku, f->>'status' status, f->>'lead_time_days' lead, f->>'lead_time_source' src, f->>'incoming_qty' incoming
from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku' in ('A','C');
select jsonb_array_length(okapi_stock.lager_orders_list('alle')) alle, jsonb_array_length(okapi_stock.lager_orders_list('offen')) offen;
select jsonb_array_length(okapi_stock.lager_notes_list()) notes;
select jsonb_array_length(okapi_stock.lager_detected_inflows(30)) inflows;
select okapi_stock.lager_sync_now();
reset role;

\echo == Sync: neue Magento-Zeile erscheint in der Kopie
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date) values ('Prod A','A',270,0,270,current_date+1);
select lager.sync_from_magento() as geaendert, lager.sync_from_magento() as zweiter_lauf_erwartet_0;

\echo == Status: C (Lieferzeit 25 > Reichweite 20). Bestellung kommt zu spaet -> kritisch, dann rechtzeitig -> bestellt
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select okapi_stock.lager_sku_settings_upsert('C', 25, 2, 'extern', 'Lieferant X');
select f->>'status' status_zu_spaet_erwartet_kritisch from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku'='C';
select okapi_stock.lager_order_update(1, null, current_date+10);
select f->>'status' status_rechtzeitig_erwartet_bestellt, f->>'stockout_date_incl_orders' so_incl from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku'='C';
reset role;

\echo == Bestand 0 ohne Verbrauch (E) -> kritisch, ausverkauft
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select f->>'status' status, f->>'out_of_stock' leer, f->>'days_of_cover' cover from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku'='E';
reset role;

-- ========== Migration 005: Aenderungen durch das Lager, Verlauf, automatische Wareneingangs-Erkennung ==========
\echo == 005: einkauf legt Bestellungen an (D: 100 Stk., B: 100 Stk., E: 1000 Stk.)
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select okapi_stock.lager_order_add('D', 100, current_date, current_date+5, null, 'Lieferant D', null) as d_order;
select okapi_stock.lager_order_add('B', 100, current_date, current_date+3, null, null, null) as b_order;
select okapi_stock.lager_order_add('E', 1000, current_date, null, 20, null, null) as e_order;
reset role;

\echo == 005: lager aendert Liefertermin und Menge (ok), Status (erwartet forbidden), Menge < eingegangen (erwartet Fehler)
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select okapi_stock.lager_order_update(3, null, current_date + 12) as termin;
select okapi_stock.lager_order_update(3, 50) as menge_50;
select okapi_stock.lager_order_update(3, 100) as menge_100;
select okapi_stock.lager_order_update(3, 100) as unveraendert_changed_false;
select okapi_stock.lager_order_update(3, null, null, null, null, 'storniert');
select jsonb_array_length(okapi_stock.lager_order_history(3)) as verlauf_erwartet_4;
select h->>'action' as aktion, h->>'by' as von, h->'changes' as aenderung from jsonb_array_elements(okapi_stock.lager_order_history(3)) h;
reset role;

\echo == 005: viewer darf nichts aendern (erwartet forbidden)
set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select okapi_stock.lager_order_update(3, null, current_date);
select okapi_stock.lager_order_reopen(3);
reset role;

\echo == 005: Magento liefert neuen Tag. D +98 (>=90 % von 100 -> eingebucht), B +30 (Teillieferung), E +5 (unter 10 % der Restmenge -> nicht zugeordnet)
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date) values
 ('Prod D','D',168,3,168,current_date+1), ('Prod B','B',80,0,80,current_date+1), ('Prod E','E',5,0,5,current_date+1);
select lager.sync_from_magento() as zeilen_geaendert;
select lager.sync_from_magento() as zweiter_lauf_erwartet_0;
select id, sku, status, received_qty, received_source, archived_at is not null as archiviert from lager.purchase_orders where id in (3,4,5) order by id;
select sku, date, inflow, allocations, surplus from lager.inflow_log where date = current_date + 1 order by sku;

\echo == 005: Prognose/Listen nach der Zuordnung
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select f->>'sku' sku, f->>'incoming_qty' offen_bestellt, f->>'next_arrival' naechste_lieferung, f->>'status' status
  from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku' in ('D','B','E') order by 1;
select jsonb_array_length(okapi_stock.lager_orders_list('offen')) as offen, jsonb_array_length(okapi_stock.lager_orders_list('archiv')) as archiv;
select i->>'sku' sku, i->>'inflow' zugang, i->>'booked_orders' gebucht from jsonb_array_elements(okapi_stock.lager_detected_inflows(30)) i where (i->>'date')::date = current_date + 1 order by 1;
select h->>'action' aktion, h->>'by' von from jsonb_array_elements(okapi_stock.lager_order_history(3)) h limit 1;

\echo == 005: lager setzt falsch zugeordnete Bestellung 3 zurueck; Bestellung 5 (nie gebucht) nicht (erwartet Fehler)
select okapi_stock.lager_order_reopen(3, 'war Rueckbuchung');
select okapi_stock.lager_order_reopen(5);
select i->>'sku' sku, i->>'booked_orders' gebucht from jsonb_array_elements(okapi_stock.lager_detected_inflows(30)) i where (i->>'date')::date = current_date + 1 and i->>'sku' = 'D';
select f->>'incoming_qty' offen_bestellt_D from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku' = 'D';
reset role;
select lager.sync_from_magento() as dritter_lauf_erwartet_0;
select status, received_qty from lager.purchase_orders where id = 3;

\echo == 006: Artikel G (Reichweite 3,33 Tage, keine Bestellung): erwartet kritisch, KEIN 'bestellt', KEIN Datum mit Lieferung
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select f->>'status' status, f->>'days_of_cover' cover, f->>'stockout_date' leer_am, f->>'stockout_date_incl_orders' leer_mit_lieferung, f->>'incoming_qty' offen
  from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku' = 'G';
select count(*) as zeilen_bestellt_ohne_bestellung_erwartet_0
  from jsonb_array_elements(okapi_stock.lager_forecast()) f
 where f->>'status' = 'bestellt' and (f->>'incoming_qty')::numeric = 0;
select count(*) as zeilen_mit_lieferdatum_ohne_bestellung_erwartet_0
  from jsonb_array_elements(okapi_stock.lager_forecast()) f
 where f->>'stockout_date_incl_orders' is not null and (f->>'incoming_qty')::numeric = 0;
reset role;

-- ========== Migration 007: Marke, Lebenszyklus, CSV-Import, Absatzhistorie ==========
\echo == 007: Markenerkennung aus dem Produktnamen
select lager.derive_brand('biostickies Standard Natur Pur-3 kg') b1, lager.derive_brand('Biostickies Clickerli') b2,
       lager.derive_brand('KNÄX Aurora-1.500g') b3, lager.derive_brand('KNäX Feine Gräser') b4, lager.derive_brand('KNAX Test') b5,
       lager.derive_brand('OKAPI Zink Plus') b6, lager.derive_brand('Happy Belly - Karton') b7, lager.derive_brand('Teepferdchen Mix') b8,
       lager.derive_brand('Irgendwas') b9;

\echo == 007: einkauf setzt Lebenszyklus und Marke (B: nicht aktiv Jahreszeit, Marke TestMarke)
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select okapi_stock.lager_sku_settings_upsert('B', null, 7, null, null, 'inaktiv_saison', 'Sommerartikel', 'TestMarke');
select okapi_stock.lager_sku_settings_upsert('B', null, 7, null, null, 'quatsch');
select f->>'sku' sku, f->>'brand' marke, f->>'lifecycle' lebenszyklus, f->>'bestellbar' bestellbar, f->>'stock_qty' lager
  from jsonb_array_elements(okapi_stock.lager_forecast()) f where f->>'sku' in ('A','B') order by 1;
select s->>'sku' sku, s->>'brand' marke, s->>'lifecycle' lebenszyklus from jsonb_array_elements(okapi_stock.lager_stock_latest()) s where s->>'sku' in ('A','B') order by 1;
reset role;

\echo == 007: CSV-Import, Probelauf mit Fehlern (nichts darf geschrieben werden)
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select jsonb_pretty(okapi_stock.lager_sku_settings_import('[
  {"row":2,"sku":"A","brand":"OKAPI","supply_source":"ONYX","lead_time_days":"21","safety_days":"10","lifecycle":"ja"},
  {"row":3,"sku":"C","lifecycle":"Nicht aktiv (Archiv)","supplier":"Lieferant Z"},
  {"row":4,"sku":"NIX","lifecycle":"aktiv"},
  {"row":5,"sku":"D","lead_time_days":"abc"},
  {"row":6,"sku":"E","lifecycle":"vielleicht"},
  {"row":7,"sku":"A","brand":"doppelt"},
  {"row":8,"sku":"G","supply_source":"Zauberer"},
  {"row":9,"sku":"","brand":"x"}
]'::jsonb, true)) as probelauf;
select s->>'sku' sku, s->>'lifecycle' lz, s->>'supply_source' herkunft from jsonb_array_elements(okapi_stock.lager_sku_settings_list()) s where s->>'sku' in ('A','C') order by 1;
\echo == 007: Import ausfuehren mit Fehler in einer spaeteren Zeile (erwartet Abbruch, A darf NICHT geaendert sein)
select okapi_stock.lager_sku_settings_import('[{"row":2,"sku":"A","lead_time_days":"33"},{"row":3,"sku":"NIX"}]'::jsonb, false);
select s->>'lead_time_days' lead_A_unveraendert from jsonb_array_elements(okapi_stock.lager_sku_settings_list()) s where s->>'sku' = 'A';
reset role;

\echo == 007: gueltiger Import (A: intern/21/10; C: Archiv; D: Saison, Lieferzeit auto; leere Felder bleiben unveraendert)
set role authenticated; set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select okapi_stock.lager_sku_settings_import('[
  {"row":2,"sku":"A","brand":"OKAPI","supply_source":"ONYX","lead_time_days":"21","safety_days":"10","lifecycle":"ja"},
  {"row":3,"sku":"C","lifecycle":"Nicht aktiv (Archiv)","supplier":"Lieferant Z"},
  {"row":4,"sku":"D","lifecycle":"Jahreszeit","lead_time_days":"auto"}
]'::jsonb, false)->'summary' as ergebnis;
select s->>'sku' sku, s->>'brand' marke, s->>'lifecycle' lz, s->>'supply_source' herkunft, s->>'lead_time_days' lieferzeit, s->>'safety_days' puffer, s->>'supplier' lieferant
  from jsonb_array_elements(okapi_stock.lager_sku_settings_list()) s where s->>'sku' in ('A','C','D') order by 1;
select okapi_stock.lager_sku_settings_import('[{"row":2,"sku":"A","brand":"OKAPI","lifecycle":"aktiv"}]'::jsonb, false)->'summary' as zweiter_lauf_unveraendert;
reset role;

\echo == 007: lager darf nicht importieren (erwartet forbidden)
set role authenticated; set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select okapi_stock.lager_sku_settings_import('[{"row":2,"sku":"A","brand":"x"}]'::jsonb, true);
reset role;

\echo == 007: Absatzhistorie
insert into lager.sales_daily (sku, date, qty_endkunde, qty_therapeut, qty_haendler, lines) values
  ('A', '2024-03-05', 10, 2, 0, 3), ('A', '2024-03-20', 5, 0, 3, 2), ('A', '2025-03-11', 7, 0, 0, 1), ('A', '2025-04-01', 4, 1, 0, 2);
set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select m->>'year' jahr, m->>'month' monat, m->>'qty' menge, m->>'qty_b2b' davon_b2b from jsonb_array_elements(okapi_stock.lager_sales_monthly('A')) m;
reset role;
\echo == 007: anon und direkte Tabellen weiterhin gesperrt
set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select * from lager.sales_daily;
reset role;

\echo == 008: Wareneingang nur aus stock_qty. H: offene Bestellung 100. Tag +2: Reservierung storniert (bestellbar +40, Lager gleich) -> KEINE Buchung; Tag +3: Lager +100 -> Buchung
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date)
select 'Prod H','H',60,0,60,current_date-(10-i) from generate_series(0,10) i;
select lager.sync_from_magento() as sync_h;
insert into lager.purchase_orders (sku, qty, ordered_on, expected_delivery) values ('H', 100, current_date - 5, current_date + 3);
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date) values ('Prod H','H',60,-40,100,current_date+2);
select lager.sync_from_magento() as sync_reservierung;
select sku, status, received_qty from lager.purchase_orders where sku = 'H';
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date) values ('Prod H','H',160,-40,200,current_date+3);
select lager.sync_from_magento() as sync_wareneingang;
select sku, status, received_qty, received_source from lager.purchase_orders where sku = 'H';
select sku, date, inflow, surplus from lager.inflow_log where sku = 'H' order by date;
