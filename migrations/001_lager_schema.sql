-- 001_lager_schema.sql
-- OKAPI Lager-Cockpit: Rollen, SKU-Einstellungen, erwartete Bestellungen,
-- Reichweitenprognose und Zugriffsfunktionen.
--
-- Konventionen der Instanz (siehe Zugangsanleitung server7):
--   * Tabellen liegen in einem NICHT exponierten Schema (lager); kein Client-Zugriff.
--   * Clients kommen nur ueber SECURITY DEFINER-Funktionen herein. Diese liegen im
--     bereits exponierten Schema okapi_stock (Prefix lager_), damit PGRST_DB_SCHEMAS
--     NICHT geaendert werden muss.
--   * Bestehende Objekte (okapi_stock.stock_history, ihre Policies und Grants fuer den
--     Magento-Sync) werden nicht veraendert.
--
-- Ausfuehren als Rolle postgres, siehe README.md.

begin;

-- 1. Schema (nicht exponiert) ---------------------------------------------------------
create schema if not exists lager;
revoke all on schema lager from public;
grant usage on schema lager to service_role;

-- 2. Tabellen -------------------------------------------------------------------------

-- Wer darf das Cockpit nutzen? viewer = lesen, orderer = lesen + Bestellungen erfassen,
-- admin = zusaetzlich SKU-Einstellungen pflegen.
create table if not exists lager.user_roles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  role         text not null check (role in ('viewer', 'orderer', 'admin')),
  display_name text,
  created_at   timestamptz not null default now()
);

-- Parameter je SKU fuer die Prognose. Fehlt eine Zeile, gelten die Standardwerte.
create table if not exists lager.sku_settings (
  sku            text primary key,
  lead_time_days integer not null default 14 check (lead_time_days >= 0),
  safety_days    integer not null default 7  check (safety_days >= 0),
  active         boolean not null default true,
  note           text,
  updated_at     timestamptz not null default now()
);

-- Von Nutzern erfasste, noch erwartete Lieferungen.
create table if not exists lager.expected_orders (
  id            bigint generated always as identity primary key,
  sku           text not null,
  qty           numeric not null check (qty > 0),
  expected_date date not null,
  status        text not null default 'open' check (status in ('open', 'received', 'cancelled')),
  supplier      text,
  note          text,
  created_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists expected_orders_sku_status_idx on lager.expected_orders (sku, status);
create index if not exists expected_orders_open_date_idx on lager.expected_orders (expected_date)
  where status = 'open';

-- RLS an, Verweigerungs-Policy, keine Grants fuer Clients.
do $$
declare t text;
begin
  foreach t in array array['user_roles', 'sku_settings', 'expected_orders'] loop
    execute format('alter table lager.%I enable row level security', t);
    execute format('drop policy if exists no_direct_client_access on lager.%I', t);
    execute format(
      'create policy no_direct_client_access on lager.%I as restrictive for all to public using (false) with check (false)',
      t);
    execute format('revoke all on lager.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- 3. Interne Hilfsfunktion (nicht fuer Clients) ---------------------------------------
create or replace function lager.require_role(p_allowed text[])
returns text
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_role text;
begin
  select r.role into v_role from lager.user_roles r where r.user_id = auth.uid();
  if v_role is null or not (v_role = any (p_allowed)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return v_role;
end;
$$;
revoke all on function lager.require_role(text[]) from public, anon, authenticated;

-- 4. Zugriffsfunktionen (exponiert ueber okapi_stock) ---------------------------------

-- Eigene Rolle; null, wenn nicht freigeschaltet. Wirft nie, damit das Frontend den Login
-- sauber auswerten kann.
create or replace function okapi_stock.lager_whoami()
returns jsonb
language sql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'role', (select r.role from lager.user_roles r where r.user_id = auth.uid()),
    'display_name', (select r.display_name from lager.user_roles r where r.user_id = auth.uid())
  );
$$;

-- Letzter Bestand je SKU.
create or replace function okapi_stock.lager_stock_latest()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'orderer', 'admin']);
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.product_name)
    from (
      select distinct on (h.sku)
             h.sku, h.product_name, h.date, h.stock_qty, h.stock_offset, h.effective_stock
      from okapi_stock.stock_history h
      order by h.sku, h.date desc
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Bestandsverlauf einer SKU.
create or replace function okapi_stock.lager_stock_series(p_sku text, p_days integer default 90)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 90), 1), 730);
begin
  perform lager.require_role(array['viewer', 'orderer', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object('date', h.date, 'effective_stock', h.effective_stock,
                                        'stock_qty', h.stock_qty, 'stock_offset', h.stock_offset)
                     order by h.date)
    from okapi_stock.stock_history h
    where h.sku = p_sku
      and h.date >= (now() at time zone 'Europe/Berlin')::date - v_days
  ), '[]'::jsonb);
end;
$$;

-- Reichweitenprognose je SKU.
--   Verbrauch   = Summe der Bestandsrueckgaenge zwischen aufeinanderfolgenden Tagen im
--                 Fenster, geteilt durch die Fensterlaenge. Zugaenge (Wareneingang)
--                 zaehlen nicht als negativer Verbrauch.
--   Reichweite  = aktueller effective_stock / Tagesverbrauch.
--   Bestellen bis = Ausverkaufsdatum - Lieferzeit - Sicherheitspuffer.
create or replace function okapi_stock.lager_forecast(p_window_days integer default 28)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
declare
  v_window integer := least(greatest(coalesce(p_window_days, 28), 7), 180);
  v_today  date    := (now() at time zone 'Europe/Berlin')::date;
begin
  perform lager.require_role(array['viewer', 'orderer', 'admin']);
  return coalesce((
    with latest as (
      select distinct on (h.sku) h.sku, h.product_name, h.date as stock_date, h.effective_stock
      from okapi_stock.stock_history h
      order by h.sku, h.date desc
    ),
    win as (
      select h.sku, h.date, h.effective_stock,
             lag(h.effective_stock) over (partition by h.sku order by h.date) as prev_stock
      from okapi_stock.stock_history h
      where h.date >= (select max(date) from okapi_stock.stock_history) - v_window
    ),
    usage as (
      select w.sku,
             sum(greatest(w.prev_stock - w.effective_stock, 0)) as consumed,
             (max(w.date) - min(w.date)) as span_days
      from win w
      group by w.sku
    ),
    incoming as (
      select o.sku, sum(o.qty) as incoming_qty, min(o.expected_date) as next_arrival
      from lager.expected_orders o
      where o.status = 'open'
      group by o.sku
    ),
    calc as (
      select l.sku, l.product_name, l.stock_date, l.effective_stock,
             coalesce(s.lead_time_days, 14) as lead_time_days,
             coalesce(s.safety_days, 7)     as safety_days,
             coalesce(s.active, true)       as active,
             case when u.span_days > 0 then u.consumed / u.span_days end as avg_daily_usage,
             coalesce(i.incoming_qty, 0) as incoming_qty,
             i.next_arrival
      from latest l
      left join usage u on u.sku = l.sku
      left join incoming i on i.sku = l.sku
      left join lager.sku_settings s on s.sku = l.sku
    )
    select jsonb_agg(to_jsonb(r) order by r.sort_key, r.product_name)
    from (
      select c.sku, c.product_name, c.stock_date, c.effective_stock,
             round(c.avg_daily_usage, 3) as avg_daily_usage,
             case when c.avg_daily_usage > 0
                  then round(c.effective_stock / c.avg_daily_usage, 1) end as days_of_cover,
             case when c.avg_daily_usage > 0
                  then c.stock_date + floor(c.effective_stock / c.avg_daily_usage)::integer end as stockout_date,
             c.incoming_qty, c.next_arrival,
             case when c.avg_daily_usage > 0
                  then round((c.effective_stock + c.incoming_qty) / c.avg_daily_usage, 1) end as days_of_cover_incl_orders,
             c.lead_time_days, c.safety_days,
             case when c.avg_daily_usage > 0
                  then c.stock_date + floor(c.effective_stock / c.avg_daily_usage)::integer
                       - c.lead_time_days - c.safety_days end as order_by_date,
             (c.stock_date < v_today - 2) as data_stale,
             case
               when c.avg_daily_usage is null or c.avg_daily_usage = 0 then 'kein_verbrauch'
               when c.effective_stock / c.avg_daily_usage <= c.lead_time_days then 'kritisch'
               when c.effective_stock / c.avg_daily_usage <= c.lead_time_days + c.safety_days then 'bestellen'
               else 'ok'
             end as status,
             case
               when c.avg_daily_usage is null or c.avg_daily_usage = 0 then 3
               when c.effective_stock / c.avg_daily_usage <= c.lead_time_days then 0
               when c.effective_stock / c.avg_daily_usage <= c.lead_time_days + c.safety_days then 1
               else 2
             end as sort_key
      from calc c
      where c.active
    ) r
  ), '[]'::jsonb);
end;
$$;

-- Erwartete Bestellungen auflisten (p_status: open | received | cancelled | all).
create or replace function okapi_stock.lager_orders_list(p_status text default 'open')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'orderer', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'sku', o.sku,
             'product_name', (select h.product_name from okapi_stock.stock_history h
                              where h.sku = o.sku order by h.date desc limit 1),
             'qty', o.qty, 'expected_date', o.expected_date, 'status', o.status,
             'supplier', o.supplier, 'note', o.note,
             'created_by', (select r.display_name from lager.user_roles r where r.user_id = o.created_by),
             'created_at', o.created_at)
           order by o.expected_date, o.id)
    from lager.expected_orders o
    where p_status = 'all' or o.status = coalesce(p_status, 'open')
  ), '[]'::jsonb);
end;
$$;

-- Neue erwartete Lieferung erfassen (orderer, admin).
create or replace function okapi_stock.lager_order_add(
  p_sku text, p_qty numeric, p_expected_date date,
  p_supplier text default null, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
declare
  v_id bigint;
begin
  perform lager.require_role(array['orderer', 'admin']);
  if p_qty is null or p_qty <= 0 then
    raise exception 'Menge muss groesser 0 sein' using errcode = '22023';
  end if;
  if p_expected_date is null then
    raise exception 'Liefertermin fehlt' using errcode = '22023';
  end if;
  if not exists (select 1 from okapi_stock.stock_history h where h.sku = p_sku) then
    raise exception 'Unbekannte SKU: %', p_sku using errcode = '22023';
  end if;
  insert into lager.expected_orders (sku, qty, expected_date, supplier, note, created_by)
  values (p_sku, p_qty, p_expected_date, nullif(trim(p_supplier), ''), nullif(trim(p_note), ''), auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- Status einer Bestellung aendern: received | cancelled | open (orderer, admin).
create or replace function okapi_stock.lager_order_set_status(p_id bigint, p_status text)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
begin
  perform lager.require_role(array['orderer', 'admin']);
  if p_status not in ('open', 'received', 'cancelled') then
    raise exception 'Ungueltiger Status: %', p_status using errcode = '22023';
  end if;
  update lager.expected_orders set status = p_status, updated_at = now() where id = p_id;
  if not found then
    raise exception 'Bestellung % nicht gefunden', p_id using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p_id, 'status', p_status);
end;
$$;

-- Lieferzeit/Puffer/aktiv je SKU pflegen (nur admin).
create or replace function okapi_stock.lager_sku_settings_upsert(
  p_sku text, p_lead_time_days integer, p_safety_days integer,
  p_active boolean default true, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
begin
  perform lager.require_role(array['admin']);
  if p_lead_time_days < 0 or p_safety_days < 0 then
    raise exception 'Werte duerfen nicht negativ sein' using errcode = '22023';
  end if;
  insert into lager.sku_settings (sku, lead_time_days, safety_days, active, note)
  values (p_sku, p_lead_time_days, p_safety_days, coalesce(p_active, true), p_note)
  on conflict (sku) do update
    set lead_time_days = excluded.lead_time_days,
        safety_days    = excluded.safety_days,
        active         = excluded.active,
        note           = excluded.note,
        updated_at     = now();
  return jsonb_build_object('sku', p_sku);
end;
$$;

create or replace function okapi_stock.lager_sku_settings_list()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
begin
  perform lager.require_role(array['admin']);
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.sku) from lager.sku_settings s), '[]'::jsonb);
end;
$$;

-- 5. Rechte der API-Funktionen: nur eingeloggte Nutzer, nie anon/public ---------------
-- Schema-Nutzung fuer eingeloggte Nutzer (auf der Instanz vermutlich schon vorhanden,
-- hier nur abgesichert). anon bekommt bewusst nichts.
grant usage on schema okapi_stock to authenticated, service_role;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'okapi_stock' and p.proname like 'lager\_%'
  loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

commit;
