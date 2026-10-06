-- 009: JTL-Schicht (Hauptdatenbank). Hier liegen Artikel, Lagerbestand und Belege (Rechnungen/Gutschriften) aus JTL.
-- Personenbezogene Daten gehoeren NICHT hierher: Belege tragen nur die Kundennummer. Name, Adresse, E-Mail, Telefon
-- liegen in der getrennten Datenbank okapi_kunden (migrations/pii/001_kunden_db.sql).
-- Wiederholbar. Voraussetzung: 001-008.
begin;

create schema if not exists jtl;

create table if not exists jtl.articles (
  sku         text primary key,
  name        text,
  ean         text,
  is_active   boolean,
  price_net   numeric,
  cost_net    numeric,
  created_on  date,
  loaded_at   timestamptz not null default now()
);

-- Lagerbestand je Tag, Artikel und JTL-Lager (ein Abzug pro Tag, am selben Tag wiederholbar)
create table if not exists jtl.stock_snapshot (
  snapshot_date date not null,
  sku           text not null,
  warehouse     text not null,
  qty_total     numeric not null default 0,
  qty_available numeric,
  loaded_at     timestamptz not null default now(),
  primary key (snapshot_date, sku, warehouse)
);
create index if not exists stock_snapshot_sku_idx on jtl.stock_snapshot (sku, snapshot_date);

-- Belege: Rechnung, Gutschrift (Retoure/Korrektur), Storno. Nur Kundennummer, keine Personendaten.
create table if not exists jtl.documents (
  doc_no         text primary key,
  doc_type       text not null check (doc_type in ('rechnung', 'gutschrift', 'storno')),
  doc_date       date not null,                -- Rechnungsdatum (massgeblich)
  order_no       text,
  customer_no    text,                         -- Verweis auf okapi_kunden.kunden.customers
  customer_group text,                         -- Kundengruppe (Endkunde, Therapeut, Haendler ...) - keine Personendaten
  country        text,                         -- nur Land
  currency       text,
  net_total      numeric,
  gross_total    numeric,
  loaded_at      timestamptz not null default now()
);
create index if not exists documents_date_idx on jtl.documents (doc_date);
create index if not exists documents_customer_idx on jtl.documents (customer_no);

create table if not exists jtl.document_items (
  doc_no         text not null,
  line_no        integer not null,
  sku            text,
  product_name   text,
  qty            numeric not null,
  unit_price_net numeric,
  discount_pct   numeric,
  line_net       numeric,
  tax_rate       numeric,
  loaded_at      timestamptz not null default now(),
  primary key (doc_no, line_no)
);
create index if not exists document_items_sku_idx on jtl.document_items (sku);

-- Zuordnung Kundengruppe -> Kaeufergruppe der Prognose. Eintraege hier ueberschreiben die Namensregel.
create table if not exists jtl.customer_group_map (
  group_name text primary key,
  buyer_type text not null check (buyer_type in ('endkunde', 'therapeut', 'haendler', 'mitarbeiter', 'sonstige'))
);

create table if not exists jtl.import_runs (
  id          bigint generated always as identity primary key,
  entity      text not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  rows_read   integer,
  rows_skipped integer,
  status      text not null default 'laeuft' check (status in ('laeuft', 'ok', 'fehler')),
  error       text
);

do $$
declare t text;
begin
  foreach t in array array['articles', 'stock_snapshot', 'documents', 'document_items', 'customer_group_map', 'import_runs'] loop
    execute format('alter table jtl.%I enable row level security', t);
    execute format('drop policy if exists no_direct_client_access on jtl.%I', t);
    execute format('create policy no_direct_client_access on jtl.%I as restrictive for all to public using (false) with check (false)', t);
    execute format('revoke all on jtl.%I from public, anon, authenticated', t);
  end loop;
end $$;
revoke all on schema jtl from public, anon, authenticated;

-- Kaeufergruppe aus dem Namen der Kundengruppe (Karte hat Vorrang)
create or replace function jtl.buyer_type(p_group text)
returns text
language sql
stable
set search_path to 'jtl', 'pg_temp'
as $$
  select coalesce(
    (select m.buyer_type from jtl.customer_group_map m where m.group_name = p_group),
    case
      when lower(coalesce(p_group, '')) like 'endkunde%'    then 'endkunde'
      when lower(coalesce(p_group, '')) like 'therapeut%'   then 'therapeut'
      when lower(coalesce(p_group, '')) like 'h_ndler%'     then 'haendler'
      when lower(coalesce(p_group, '')) like 'mitarbeiter%' then 'mitarbeiter'
      else 'sonstige'
    end)
$$;
revoke all on function jtl.buyer_type(text) from public, anon, authenticated;

-- Tagesabsatz fuer die Prognose aus den JTL-Belegen neu aufbauen (ab p_from, wiederholbar).
--   rechnung            -> qty_<gruppe> (nur Positionen mit Menge > 0)
--   gutschrift / storno -> qty_retoure (positiv), Umsatz negativ
--   alte Artikelnummern werden ueber lager.sku_alias auf die aktuelle gelegt
-- Tage ab p_from werden ersetzt (auch die der Excel-Historie), davor bleibt alles unveraendert.
create or replace function lager.refresh_sales_from_jtl(p_from date default date '2026-05-08')
returns integer
language plpgsql
set search_path to 'lager', 'jtl', 'pg_temp'
as $$
declare n integer;
begin
  delete from lager.sales_daily where date >= p_from;
  insert into lager.sales_daily (sku, date, qty_endkunde, qty_therapeut, qty_haendler, qty_mitarbeiter, qty_sonstige,
                                 qty_retoure, lines, revenue_net, source)
  select coalesce(a.new_sku, i.sku) as sku, d.doc_date,
         sum(case when d.doc_type = 'rechnung' and i.qty > 0 and jtl.buyer_type(d.customer_group) = 'endkunde'    then i.qty else 0 end),
         sum(case when d.doc_type = 'rechnung' and i.qty > 0 and jtl.buyer_type(d.customer_group) = 'therapeut'   then i.qty else 0 end),
         sum(case when d.doc_type = 'rechnung' and i.qty > 0 and jtl.buyer_type(d.customer_group) = 'haendler'    then i.qty else 0 end),
         sum(case when d.doc_type = 'rechnung' and i.qty > 0 and jtl.buyer_type(d.customer_group) = 'mitarbeiter' then i.qty else 0 end),
         sum(case when d.doc_type = 'rechnung' and i.qty > 0 and jtl.buyer_type(d.customer_group) = 'sonstige'    then i.qty else 0 end),
         sum(case when d.doc_type <> 'rechnung' then abs(i.qty) else 0 end),
         count(*)::integer,
         coalesce(sum(case when d.doc_type = 'rechnung' then abs(i.line_net) else -abs(i.line_net) end), 0),
         'jtl'
  from jtl.document_items i
  join jtl.documents d on d.doc_no = i.doc_no
  left join lager.sku_alias a on a.old_sku = i.sku
  where d.doc_date >= p_from
    and i.sku ~ '^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$'
  group by coalesce(a.new_sku, i.sku), d.doc_date;
  get diagnostics n = row_count;
  update lager.sku_catalog c set total_qty = coalesce((
    select sum(s.qty_endkunde + s.qty_therapeut + s.qty_haendler + s.qty_mitarbeiter + s.qty_sonstige)
    from lager.sales_daily s where s.sku = c.sku), 0);
  return n;
end;
$$;
revoke all on function lager.refresh_sales_from_jtl(date) from public, anon, authenticated;

commit;
