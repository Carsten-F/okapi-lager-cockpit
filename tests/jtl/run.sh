#!/bin/bash
# Test der JTL-Extraktion mit CSV-Quelle gegen lokale Datenbanken (main=postgres, pii=okapi_kunden).
# Voraussetzung: Test-Cluster laeuft (siehe README Tests), Migrationen 001-009 sind eingespielt.
set -u
cd "$(dirname "$0")"; R=../..
export PGHOST=/tmp PGPORT=54329 PGUSER=postgres
fail=0; ok() { echo "PASS  $1"; }; bad() { echo "FAIL  $1"; fail=1; }
chk() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (erwartet '$3', war '$2')"; }
M="psql -At -d postgres"; P="psql -At -d okapi_kunden"
psql -q -v ON_ERROR_STOP=1 -d postgres -f $R/migrations/009_jtl_layer.sql >/dev/null 2>&1 || bad "Migration 009"
psql -q -v ON_ERROR_STOP=1 -d postgres -f $R/migrations/pii/001_kunden_db.sql >/dev/null 2>&1 || bad "PII-Datenbank"
psql -q -v ON_ERROR_STOP=1 -d postgres -f $R/migrations/pii/001_kunden_db.sql >/dev/null 2>&1 && ok "PII-Migration wiederholbar" || bad "PII-Migration wiederholbar"
cat > /tmp/jtl_test.env <<EOF
PSQL_MAIN="psql -h /tmp -p 54329 -U postgres -d postgres"
PSQL_PII="psql -h /tmp -p 54329 -U postgres -d okapi_kunden"
EOF
$M -c "delete from lager.sku_alias; insert into lager.sku_alias(old_sku,new_sku,method) values ('1001','1101001','regel'); delete from lager.sales_daily where date >= '2026-05-08'" >/dev/null
$M -c "truncate jtl.import_runs" >/dev/null
X="python3 -I ../../connectors/jtl/extract_jtl.py --env /tmp/jtl_test.env --source csv:fixtures --since 2026-10-01"
$X > /tmp/jtl_run1.txt 2>&1; chk "Lauf 1 Exitcode 0" $? 0
chk "Artikel (Zeile ohne Nummer uebersprungen)" "$($M -c 'select count(*) from jtl.articles')" 2
chk "Lagerbestand Zeilen" "$($M -c 'select count(*) from jtl.stock_snapshot')" 3
chk "Kunden in PII-Datenbank" "$($P -c 'select count(*) from kunden.customers')" 3
chk "KEINE Kundentabelle in Hauptdatenbank" "$($M -c "select count(*) from information_schema.columns where table_schema in ('jtl','lager') and column_name in ('email','first_name','last_name','phone','street')")" 0
chk "Belege tragen nur Kundennummer" "$($M -c "select count(distinct customer_no) from jtl.documents")" 3
chk "Newsletter-Opt-in Bool" "$($P -c "select newsletter_optin from kunden.customers where customer_no='K1'")" t
# Absatz-Aufbau
chk "Rechnung Endkunde 1001 -> 1101001 (alias)" "$($M -c "select qty_endkunde::int from lager.sales_daily where sku='1101001' and date='2026-10-01'")" 1
chk "Therapeut 2 Stueck" "$($M -c "select qty_therapeut::int from lager.sales_daily where sku='1101001' and date='2026-10-02'")" 2
chk "Haendler 6 Stueck (Umlaut-Regel)" "$($M -c "select qty_haendler::int from lager.sales_daily where sku='1101014' and date='2026-10-02'")" 6
chk "Gutschrift als Retoure" "$($M -c "select qty_retoure::int from lager.sales_daily where sku='1101001' and date='2026-10-03'")" 1
chk "Gutschein-Position nicht im Absatz" "$($M -c "select count(*) from lager.sales_daily where sku like 'CUP%'")" 0
chk "Laufprotokoll ok" "$($M -c "select count(*) from jtl.import_runs where status='ok'")" 5
# Wiederholbarkeit
$X > /tmp/jtl_run2.txt 2>&1; chk "Lauf 2 Exitcode 0" $? 0
chk "Idempotent: Belege" "$($M -c 'select count(*) from jtl.documents')" 4
chk "Idempotent: Positionen" "$($M -c 'select count(*) from jtl.document_items')" 6
chk "Idempotent: Absatzzeilen" "$($M -c "select count(*) from lager.sales_daily where date >= '2026-10-01'")" 4
# DSGVO-Loeschung: Kunde K3 aus JTL geloescht -> auch aus okapi_kunden
mkdir -p /tmp/jtl_fx2 && cp fixtures/*.csv /tmp/jtl_fx2/ && sed -i '/^K3,/d' /tmp/jtl_fx2/customers.csv
python3 -I ../../connectors/jtl/extract_jtl.py --env /tmp/jtl_test.env --source csv:/tmp/jtl_fx2 --entities customers >/dev/null 2>&1
chk "Geloeschter Kunde verschwindet (Abgleich)" "$($P -c 'select count(*) from kunden.customers')" 2
# Sicherheitsgrenze: Quelle liefert fast nichts -> Abbruch statt Massenloeschung
$P -c "insert into kunden.customers(customer_no) select 'X'||g from generate_series(1,200) g" >/dev/null
python3 -I ../../connectors/jtl/extract_jtl.py --env /tmp/jtl_test.env --source csv:/tmp/jtl_fx2 --entities customers >/tmp/jtl_run3.txt 2>&1; chk "Massenloeschung wird verhindert (Exitcode 1)" $? 1
chk "Kunden bleiben erhalten" "$($P -c 'select count(*) from kunden.customers')" 202
$P -c "delete from kunden.customers where customer_no like 'X%'" >/dev/null
# Entwurfsschutz fuer echte JTL-Abfragen und Trockenlauf
python3 -I ../../connectors/jtl/extract_jtl.py --env /tmp/jtl_test.env --entities articles >/tmp/jtl_run4.txt 2>&1; chk "ENTWURF-Abfrage wird nicht ausgefuehrt" $? 1
grep -q ENTWURF /tmp/jtl_run4.txt && ok "Hinweistext ENTWURF" || bad "Hinweistext ENTWURF"
python3 -I ../../connectors/jtl/extract_jtl.py --source csv:fixtures --dry-run --entities customers 2>&1 | grep -q "Trockenlauf" && ok "Trockenlauf schreibt nichts" || bad "Trockenlauf"
grep -qi "anna\|example.org" /tmp/jtl_run1.txt /tmp/jtl_run2.txt /tmp/jtl_run3.txt && bad "Personendaten im Log!" || ok "Keine Personendaten im Log"
# Zugriffstrennung: kunden_reader sieht nur Kundendatenbank
chk "Hauptdatenbank enthaelt kein Schema kunden" "$($M -c "select count(*) from information_schema.schemata where schema_name='kunden'")" 0
chk "PII-Datenbank fuer PUBLIC gesperrt" "$($M -c "select has_database_privilege('anon','okapi_kunden','connect')" 2>/dev/null)" f
exit $fail
