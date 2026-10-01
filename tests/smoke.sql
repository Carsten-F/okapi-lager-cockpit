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
select jsonb_array_length(okapi_stock.lager_stock_latest()) as skus_erwartet_4;
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
