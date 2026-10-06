-- Getrennte Datenbank fuer personenbezogene Kundendaten (DSGVO). Wiederholbar.
-- Aufruf als Superuser gegen die Datenbank "postgres":
--   docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < migrations/pii/001_kunden_db.sql
-- Warum eine eigene Datenbank: Sie hat eigene Zugriffsrechte, eigene Sicherung und ist von der Auswertungs-/Lager-Datenbank
-- aus nicht abfragbar. Belege in der Hauptdatenbank tragen nur die Kundennummer (customer_no). Ein Zugriff auf Namen,
-- Adressen und E-Mail-Adressen ist nur ueber die Rolle kunden_reader moeglich, die einzeln vergeben wird.
select 'create database okapi_kunden' where not exists (select 1 from pg_database where datname = 'okapi_kunden') \gexec

revoke connect on database okapi_kunden from public;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'kunden_reader') then
    create role kunden_reader nologin;     -- Lesezugriff auf Kundendaten; nur gezielt vergeben
  end if;
end $$;
grant connect on database okapi_kunden to kunden_reader;

\connect okapi_kunden

create schema if not exists kunden;
revoke all on schema kunden from public;
grant usage on schema kunden to kunden_reader;

create table if not exists kunden.customers (
  customer_no    text primary key,            -- Schluessel zu jtl.documents.customer_no in der Hauptdatenbank
  company        text,
  first_name     text,
  last_name      text,
  email          text,
  phone          text,
  street         text,
  zip            text,
  city           text,
  country        text,
  customer_group text,
  created_on     date,
  newsletter_optin boolean,
  loaded_at      timestamptz not null default now()
);
create index if not exists customers_email_idx on kunden.customers (lower(email));

revoke all on kunden.customers from public;
grant select on kunden.customers to kunden_reader;

-- Auswertung ohne Direktidentifikatoren (Land und Gruppe), fuer Rollen ohne Personenzugriff
create or replace view kunden.customers_pseudonym as
  select customer_no, customer_group, country, created_on from kunden.customers;
revoke all on kunden.customers_pseudonym from public;
