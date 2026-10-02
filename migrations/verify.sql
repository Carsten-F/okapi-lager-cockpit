-- Nur lesend. Prueft das Ergebnis von 001_lager_schema.sql.

\echo === Tabellen in lager: RLS an? ===
select c.relname, c.relrowsecurity as rls_an
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'lager' and c.relkind = 'r' order by 1;

\echo === Policies in lager ===
select tablename, policyname, permissive, cmd from pg_policies where schemaname = 'lager' order by 1;

\echo === Client-Rechte auf lager-Tabellen (muss leer sein) ===
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'lager' and grantee in ('anon', 'authenticated', 'PUBLIC');

\echo === API-Funktionen und ihre Rechte ===
select p.proname, p.prosecdef as security_definer, p.proconfig as config,
       has_function_privilege('anon', p.oid, 'execute') as anon_exec,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_exec
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'okapi_stock' and p.proname like 'lager\_%' order by 1;

\echo === Arbeitskopie: Zeilen, Zeitraum, SKUs vs. Quelle ===
select (select count(*) from lager.stock_daily) as kopie_zeilen,
       (select count(*) from okapi_stock.stock_history) as quelle_zeilen,
       (select min(date) from lager.stock_daily) as von, (select max(date) from lager.stock_daily) as bis,
       (select count(distinct sku) from lager.stock_daily) as skus;

\echo === stock_history unveraendert: Policies und Grants ===
select policyname, cmd from pg_policies where tablename = 'stock_history' order by 1;
select grantee, privilege_type from information_schema.role_table_grants
where table_name = 'stock_history' and grantee in ('anon', 'authenticated') order by 1, 2;

\echo === Quelle okapi_stock.stock_history: Zeilen je Datum (letzte 7 Tage) ===
select date, count(*) as zeilen, count(distinct sku) as skus from okapi_stock.stock_history group by date order by date desc limit 7;

\echo === Bestellungen nach Status (ab Migration 005 mit Archiv) ===
select status, count(*) as anzahl, count(*) filter (where received_source = 'auto') as davon_automatisch from lager.purchase_orders group by 1 order by 1;

\echo === Zugangsprotokoll (letzte 10, ab Migration 005) ===
select date, sku, inflow, allocations, surplus from lager.inflow_log order by date desc, sku limit 10;
