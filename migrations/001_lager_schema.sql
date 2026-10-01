-- 001_lager_schema.sql
-- OKAPI Lager-Cockpit: Lagerverwaltung, Reichweitenprognose, Einkaufsoptimierung.
--
-- Datenfluss:
--   Magento --(taeglicher Import)--> okapi_stock.stock_history   (Quelle, wird NICHT veraendert)
--                                        |  lager.sync_from_magento()
--                                        v
--                                    lager.stock_daily          (Arbeitskopie)
--   Nutzereingaben (Bestellungen, Wareneingang, Inventurkorrekturen, Kommentare)
--   liegen in eigenen Tabellen und ueberschreiben die Kopie nie.
--
-- Konventionen der Instanz (siehe Zugangsanleitung server7):
--   * Tabellen in einem NICHT exponierten Schema (lager); kein Client-Zugriff.
--   * Clients kommen nur ueber SECURITY DEFINER-Funktionen herein. Diese liegen im bereits
--     exponierten Schema okapi_stock (Prefix lager_), damit PGRST_DB_SCHEMAS NICHT
--     geaendert werden muss.
--   * Bestehende Objekte von okapi_stock.stock_history (Policies, Grants fuer den
--     Magento-Sync) werden nicht veraendert.
--
-- Bestandsgroessen (Magento):
--   effective_stock = physischer Bestand am Lager  -> Grundlage der Prognose
--   bestellbar      = stock_qty - stock_offset     -> nur zur Anzeige
--
-- Ausfuehren als Rolle postgres, siehe README.md. Wiederholbar (idempotent).

begin;

-- 1. Schema ---------------------------------------------------------------------------
create schema if not exists lager;
revoke all on schema lager from public;
grant usage on schema lager to service_role;

-- 2. Tabellen -------------------------------------------------------------------------

-- Wer darf das Cockpit nutzen?
--   viewer  = lesen
--   lager   = lesen + Wareneingang buchen, Inventurkorrekturen, Kommentare
--   einkauf = wie lager + Bestellungen anlegen/aendern, SKU-Einstellungen
--   admin   = alles
create table if not exists lager.user_roles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  role         text not null check (role in ('viewer', 'lager', 'einkauf', 'admin')),
  display_name text,
  created_at   timestamptz not null default now()
);

-- Parameter je SKU. Fehlt die Zeile oder ist lead_time_days null, wird die beobachtete
-- Lieferzeit aus eingebuchten Bestellungen genutzt, sonst 14 Tage.
create table if not exists lager.sku_settings (
  sku            text primary key,
  lead_time_days integer check (lead_time_days >= 0),
  safety_days    integer not null default 7 check (safety_days >= 0),
  supply_source  text check (supply_source in ('extern', 'intern')),  -- extern = Lieferant, intern = ONYX
  supplier       text,
  active         boolean not null default true,
  note           text,
  updated_at     timestamptz not null default now()
);

-- Arbeitskopie der Magento-Bestandsdaten (ein Eintrag je SKU und Tag).
create table if not exists lager.stock_daily (
  sku               text not null,
  date              date not null,
  product_name      text not null,
  stock_qty         numeric not null,
  stock_offset      numeric not null,
  effective_stock   numeric not null,
  source_id         bigint,
  source_updated_at timestamptz,
  synced_at         timestamptz not null default now(),
  primary key (sku, date)
);
create index if not exists stock_daily_date_idx on lager.stock_daily (date);

-- Bestellungen beim Lieferanten bzw. Auftraege an ONYX.
create table if not exists lager.purchase_orders (
  id                 bigint generated always as identity primary key,
  sku                text not null,
  qty                numeric not null check (qty > 0),
  supplier           text,
  status             text not null default 'bestellt'
                       check (status in ('bestellt', 'bestaetigt', 'teilgeliefert', 'eingebucht', 'storniert')),
  ordered_on         date not null,
  expected_delivery  date,                                   -- voraussichtliches Lieferdatum
  expected_lead_days integer check (expected_lead_days >= 0),-- voraussichtl. Zeitspanne Bestellung bis Wareneinbuchung
  received_on        date,                                   -- Warenzugangsdatum (letzte Einbuchung)
  received_qty       numeric not null default 0 check (received_qty >= 0),
  comment            text,
  created_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_by         uuid references auth.users (id) on delete set null,
  updated_at         timestamptz not null default now()
);
create index if not exists purchase_orders_sku_idx on lager.purchase_orders (sku, status);

-- Kommentare und Inventurkorrekturen je SKU.
--   qty_delta = vorzeichenbehaftete Bestandsaenderung durch die Korrektur (z. B. -10 bei
--   Schwund). effective_date = Datum des ersten Bestandssnapshots, der die Korrektur
--   enthaelt. Die Prognose rechnet die Korrektur aus dem Verbrauch heraus.
create table if not exists lager.sku_notes (
  id             bigint generated always as identity primary key,
  sku            text not null,
  kind           text not null check (kind in ('kommentar', 'inventurkorrektur')),
  note           text,
  qty_delta      numeric,
  effective_date date not null default ((now() at time zone 'Europe/Berlin')::date),
  created_by     uuid references auth.users (id) on delete set null,
  created_at     timestamptz not null default now(),
  check (kind <> 'inventurkorrektur' or qty_delta is not null),
  check (kind = 'inventurkorrektur' or qty_delta is null)
);
create index if not exists sku_notes_sku_idx on lager.sku_notes (sku, effective_date);

-- RLS an, Verweigerungs-Policy, keine Grants fuer Clients.
do $$
declare t text;
begin
  foreach t in array array['user_roles', 'sku_settings', 'stock_daily', 'purchase_orders', 'sku_notes'] loop
    execute format('alter table lager.%I enable row level security', t);
    execute format('drop policy if exists no_direct_client_access on lager.%I', t);
    execute format(
      'create policy no_direct_client_access on lager.%I as restrictive for all to public using (false) with check (false)',
      t);
    execute format('revoke all on lager.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- 3. Interne Funktionen (nicht fuer Clients) -----------------------------------------

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

-- Kopiert neue/geaenderte Zeilen aus der Magento-Tabelle in die Arbeitskopie.
-- Gibt die Zahl der neu angelegten oder geaenderten Zeilen zurueck. Aufruf per Cron
-- (siehe README) oder ueber okapi_stock.lager_sync_now().
create or replace function lager.sync_from_magento()
returns integer
language plpgsql
volatile
security definer
set search_path to 'lager', 'okapi_stock', 'pg_temp'
as $$
declare
  n integer;
begin
  with up as (
    insert into lager.stock_daily as d
      (sku, date, product_name, stock_qty, stock_offset, effective_stock, source_id, source_updated_at)
    select h.sku, h.date, h.product_name, h.stock_qty, h.stock_offset, h.effective_stock, h.id, h.updated_at
    from okapi_stock.stock_history h
    on conflict (sku, date) do update
      set product_name      = excluded.product_name,
          stock_qty         = excluded.stock_qty,
          stock_offset      = excluded.stock_offset,
          effective_stock   = excluded.effective_stock,
          source_id         = excluded.source_id,
          source_updated_at = excluded.source_updated_at,
          synced_at         = now()
      where (d.product_name, d.stock_qty, d.stock_offset, d.effective_stock)
            is distinct from (excluded.product_name, excluded.stock_qty, excluded.stock_offset, excluded.effective_stock)
    returning 1
  )
  select count(*) into n from up;
  return n;
end;
$$;
revoke all on function lager.sync_from_magento() from public, anon, authenticated;

-- 4. API-Funktionen (exponiert ueber okapi_stock) ------------------------------------

-- Eigene Rolle; role = null, wenn nicht freigeschaltet. Wirft nie.
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

-- Arbeitskopie sofort aus Magento-Daten aktualisieren (admin).
create or replace function okapi_stock.lager_sync_now()
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['admin']);
  return jsonb_build_object('rows_changed', lager.sync_from_magento());
end;
$$;

-- Letzter Bestand je SKU.
create or replace function okapi_stock.lager_stock_latest()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.product_name)
    from (
      select distinct on (d.sku)
             d.sku, d.product_name, d.date, d.stock_qty, d.stock_offset,
             d.effective_stock, d.stock_qty - d.stock_offset as bestellbar
      from lager.stock_daily d
      order by d.sku, d.date desc
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Bestandsverlauf einer SKU inkl. Korrekturen des Tages.
create or replace function okapi_stock.lager_stock_series(p_sku text, p_days integer default 90)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 90), 1), 730);
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'date', d.date, 'effective_stock', d.effective_stock, 'stock_qty', d.stock_qty,
             'stock_offset', d.stock_offset, 'bestellbar', d.stock_qty - d.stock_offset,
             'korrektur', (select sum(n.qty_delta) from lager.sku_notes n
                           where n.sku = d.sku and n.kind = 'inventurkorrektur' and n.effective_date = d.date))
           order by d.date)
    from lager.stock_daily d
    where d.sku = p_sku
      and d.date >= (now() at time zone 'Europe/Berlin')::date - v_days
  ), '[]'::jsonb);
end;
$$;

-- Erkannte Bestandszugaenge (positive Spruenge) der letzten Tage, abzueglich bekannter
-- positiver Korrekturen. Hilft, Wareneingaenge den Bestellungen zuzuordnen.
create or replace function okapi_stock.lager_detected_inflows(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.date desc, x.product_name)
    from (
      select w.sku, w.product_name, w.date, w.inflow,
             (select jsonb_agg(o.id) from lager.purchase_orders o
              where o.sku = w.sku and o.received_on = w.date) as booked_orders
      from (
        select d.sku, d.product_name, d.date,
               d.effective_stock - lag(d.effective_stock) over (partition by d.sku order by d.date)
               - coalesce((select sum(n.qty_delta) from lager.sku_notes n
                           where n.sku = d.sku and n.kind = 'inventurkorrektur' and n.effective_date = d.date), 0)
               as inflow
        from lager.stock_daily d
        where d.date >= (now() at time zone 'Europe/Berlin')::date - v_days - 1
      ) w
      where w.inflow > 0 and w.date >= (now() at time zone 'Europe/Berlin')::date - v_days
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Reichweitenprognose je SKU.
--   Verbrauch     = Summe der Bestandsrueckgaenge zwischen aufeinanderfolgenden Tagen im
--                   Fenster (Inventurkorrekturen herausgerechnet), geteilt durch die
--                   Fensterlaenge. Zugaenge (Wareneingang) zaehlen nicht als negativer Verbrauch.
--   Reichweite    = aktueller effective_stock / Tagesverbrauch.
--   Lieferzeit    = sku_settings.lead_time_days, sonst Mittel der letzten 5 eingebuchten
--                   Bestellungen (Bestelldatum bis Warenzugang), sonst 14 Tage.
--   Bestellen bis = Ausverkaufsdatum - Lieferzeit - Sicherheitspuffer.
--   Offene Bestellungen (bestellt/bestaetigt/teilgeliefert) kommen mit ihrer Restmenge zum
--   erwarteten Liefertermin hinzu; ueberfaellige Termine zaehlen ab morgen.
create or replace function okapi_stock.lager_forecast(p_window_days integer default 28)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_window integer := least(greatest(coalesce(p_window_days, 28), 7), 180);
  v_today  date    := (now() at time zone 'Europe/Berlin')::date;
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    with latest as (
      select distinct on (d.sku) d.sku, d.product_name, d.date as stock_date,
             d.effective_stock, d.stock_qty - d.stock_offset as bestellbar
      from lager.stock_daily d
      order by d.sku, d.date desc
    ),
    win as (
      select d.sku, d.date, d.effective_stock,
             lag(d.effective_stock) over (partition by d.sku order by d.date) as prev_stock,
             coalesce((select sum(n.qty_delta) from lager.sku_notes n
                       where n.sku = d.sku and n.kind = 'inventurkorrektur' and n.effective_date = d.date), 0) as corr
      from lager.stock_daily d
      where d.date >= (select max(date) from lager.stock_daily) - v_window
    ),
    usage as (
      select w.sku,
             sum(greatest(w.prev_stock - w.effective_stock + w.corr, 0)) as consumed,
             (max(w.date) - min(w.date)) as span_days
      from win w
      group by w.sku
    ),
    open_orders as (
      select o.sku, o.id,
             o.qty - o.received_qty as qty_open,
             coalesce(o.expected_delivery, o.ordered_on + o.expected_lead_days) as eta
      from lager.purchase_orders o
      where o.status in ('bestellt', 'bestaetigt', 'teilgeliefert') and o.qty > o.received_qty
    ),
    observed as (
      select r.sku, round(avg(r.received_on - r.ordered_on))::integer as lead_days
      from (
        select o.sku, o.received_on, o.ordered_on,
               row_number() over (partition by o.sku order by o.received_on desc) as rn
        from lager.purchase_orders o
        where o.status = 'eingebucht' and o.received_on is not null and o.received_on > o.ordered_on
      ) r
      where r.rn <= 5
      group by r.sku
    ),
    calc as (
      select l.sku, l.product_name, l.stock_date, l.effective_stock, l.bestellbar,
             coalesce(s.safety_days, 7) as safety_days,
             coalesce(s.active, true)   as active,
             s.supply_source, s.supplier as default_supplier,
             coalesce(s.lead_time_days, ob.lead_days, 14) as lead_time_days,
             case when s.lead_time_days is not null then 'manuell'
                  when ob.lead_days is not null then 'beobachtet' else 'standard' end as lead_time_source,
             case when u.span_days > 0 then u.consumed / u.span_days end as u
      from latest l
      left join usage u on u.sku = l.sku
      left join observed ob on ob.sku = l.sku
      left join lager.sku_settings s on s.sku = l.sku
    ),
    inc as (
      select c.sku,
             coalesce(sum(o.qty_open), 0) as incoming_qty,
             min(o.eta) as next_arrival,
             count(*) filter (where o.eta is not null and o.eta < v_today) as overdue_orders
      from calc c left join open_orders o on o.sku = c.sku
      group by c.sku
    ),
    sim as (
      select c.sku, min(g.day) as stockout_day
      from calc c
      cross join generate_series(0, 365) as g(day)
      where c.u > 0
        and c.effective_stock - c.u * g.day
            + coalesce((select sum(o.qty_open) from open_orders o
                        where o.sku = c.sku
                          and greatest(coalesce(o.eta, c.stock_date + 1) - c.stock_date, 1) <= g.day), 0) <= 0
      group by c.sku
    ),
    res as (
      select c.*, i.incoming_qty, i.next_arrival, i.overdue_orders,
             case when c.u > 0 then c.effective_stock / c.u end as cover,
             sim.stockout_day
      from calc c
      join inc i on i.sku = c.sku
      left join sim on sim.sku = c.sku
      where c.active
    )
    select jsonb_agg(to_jsonb(r2) order by r2.sort_key, r2.product_name)
    from (
      select r.sku, r.product_name, r.stock_date, r.effective_stock, r.bestellbar,
             round(r.u, 3) as avg_daily_usage,
             round(r.cover, 1) as days_of_cover,
             case when r.u > 0 then r.stock_date + floor(r.cover)::integer end as stockout_date,
             r.incoming_qty, r.next_arrival, r.overdue_orders,
             case when r.u > 0 and r.stockout_day is not null then r.stock_date + r.stockout_day end
               as stockout_date_incl_orders,
             r.lead_time_days, r.lead_time_source, r.safety_days, r.supply_source, r.default_supplier,
             case when r.u > 0 then r.stock_date + floor(r.cover)::integer - r.lead_time_days - r.safety_days end
               as order_by_date,
             (r.stock_date < v_today - 2) as data_stale,
             case
               when r.u is null or r.u = 0 then 'kein_verbrauch'
               when r.cover <= r.lead_time_days
                    and (r.stockout_day is null or r.stockout_day > r.cover + 0.5) then 'bestellt'
               when r.cover <= r.lead_time_days then 'kritisch'
               when r.cover <= r.lead_time_days + r.safety_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > r.cover + 0.5) then 'bestellt'
               when r.cover <= r.lead_time_days + r.safety_days then 'bestellen'
               else 'ok'
             end as status,
             case
               when r.u is null or r.u = 0 then 3
               when r.cover <= r.lead_time_days
                    and (r.stockout_day is null or r.stockout_day > r.cover + 0.5) then 1
               when r.cover <= r.lead_time_days then 0
               when r.cover <= r.lead_time_days + r.safety_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > r.cover + 0.5) then 2
               when r.cover <= r.lead_time_days + r.safety_days then 1
               else 2
             end as sort_key
      from res r
    ) r2
  ), '[]'::jsonb);
end;
$$;

-- Bestellungen auflisten. p_status: offen | alle | bestellt | bestaetigt | teilgeliefert |
-- eingebucht | storniert
create or replace function okapi_stock.lager_orders_list(p_status text default 'offen')
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'sku', o.sku,
             'product_name', (select d.product_name from lager.stock_daily d
                              where d.sku = o.sku order by d.date desc limit 1),
             'qty', o.qty, 'received_qty', o.received_qty, 'supplier', o.supplier,
             'status', o.status, 'ordered_on', o.ordered_on,
             'expected_delivery', o.expected_delivery, 'expected_lead_days', o.expected_lead_days,
             'eta', coalesce(o.expected_delivery, o.ordered_on + o.expected_lead_days),
             'received_on', o.received_on, 'comment', o.comment,
             'created_by', (select r.display_name from lager.user_roles r where r.user_id = o.created_by),
             'updated_at', o.updated_at)
           order by coalesce(o.expected_delivery, o.ordered_on + o.expected_lead_days, o.ordered_on), o.id)
    from lager.purchase_orders o
    where case coalesce(p_status, 'offen')
            when 'alle' then true
            when 'offen' then o.status in ('bestellt', 'bestaetigt', 'teilgeliefert')
            else o.status = p_status
          end
  ), '[]'::jsonb);
end;
$$;

-- Bestellung anlegen (einkauf, admin).
create or replace function okapi_stock.lager_order_add(
  p_sku text, p_qty numeric, p_ordered_on date,
  p_expected_delivery date default null, p_expected_lead_days integer default null,
  p_supplier text default null, p_comment text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_id bigint;
begin
  perform lager.require_role(array['einkauf', 'admin']);
  if p_qty is null or p_qty <= 0 then
    raise exception 'Menge muss groesser 0 sein' using errcode = '22023';
  end if;
  if p_ordered_on is null then
    raise exception 'Bestelldatum fehlt' using errcode = '22023';
  end if;
  if not exists (select 1 from lager.stock_daily d where d.sku = p_sku) then
    raise exception 'Unbekannte SKU: %', p_sku using errcode = '22023';
  end if;
  insert into lager.purchase_orders
    (sku, qty, ordered_on, expected_delivery, expected_lead_days, supplier, comment, created_by, updated_by)
  values (p_sku, p_qty, p_ordered_on, p_expected_delivery, p_expected_lead_days,
          nullif(trim(p_supplier), ''), nullif(trim(p_comment), ''), auth.uid(), auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- Bestellung aendern (einkauf, admin). Nur uebergebene (nicht-null) Felder werden gesetzt.
create or replace function okapi_stock.lager_order_update(
  p_id bigint, p_qty numeric default null, p_expected_delivery date default null,
  p_expected_lead_days integer default null, p_supplier text default null,
  p_status text default null, p_comment text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['einkauf', 'admin']);
  if p_status is not null and p_status not in ('bestellt', 'bestaetigt', 'teilgeliefert', 'eingebucht', 'storniert') then
    raise exception 'Ungueltiger Status: %', p_status using errcode = '22023';
  end if;
  if p_qty is not null and p_qty <= 0 then
    raise exception 'Menge muss groesser 0 sein' using errcode = '22023';
  end if;
  update lager.purchase_orders o
     set qty                = coalesce(p_qty, o.qty),
         expected_delivery  = coalesce(p_expected_delivery, o.expected_delivery),
         expected_lead_days = coalesce(p_expected_lead_days, o.expected_lead_days),
         supplier           = coalesce(nullif(trim(p_supplier), ''), o.supplier),
         status             = coalesce(p_status, o.status),
         comment            = coalesce(nullif(trim(p_comment), ''), o.comment),
         updated_by         = auth.uid(),
         updated_at         = now()
   where o.id = p_id;
  if not found then
    raise exception 'Bestellung % nicht gefunden', p_id using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p_id);
end;
$$;

-- Wareneingang einbuchen (lager, einkauf, admin). Menge wird zur bisherigen
-- Eingangsmenge addiert; Status wird teilgeliefert oder eingebucht.
create or replace function okapi_stock.lager_order_receive(
  p_id bigint, p_received_on date, p_received_qty numeric, p_comment text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_status text;
  v_total  numeric;
begin
  perform lager.require_role(array['lager', 'einkauf', 'admin']);
  if p_received_on is null or p_received_qty is null or p_received_qty <= 0 then
    raise exception 'Warenzugangsdatum und Menge > 0 erforderlich' using errcode = '22023';
  end if;
  update lager.purchase_orders o
     set received_qty = o.received_qty + p_received_qty,
         received_on  = p_received_on,
         status       = case when o.received_qty + p_received_qty >= o.qty then 'eingebucht' else 'teilgeliefert' end,
         comment      = coalesce(nullif(trim(p_comment), ''), o.comment),
         updated_by   = auth.uid(),
         updated_at   = now()
   where o.id = p_id and o.status <> 'storniert'
   returning o.status, o.received_qty into v_status, v_total;
  if not found then
    raise exception 'Bestellung % nicht gefunden oder storniert', p_id using errcode = 'P0002';
  end if;
  return jsonb_build_object('id', p_id, 'status', v_status, 'received_qty', v_total);
end;
$$;

-- Kommentar oder Inventurkorrektur zu einer SKU (lager, einkauf, admin).
create or replace function okapi_stock.lager_note_add(
  p_sku text, p_kind text, p_note text,
  p_qty_delta numeric default null, p_effective_date date default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_id bigint;
begin
  perform lager.require_role(array['lager', 'einkauf', 'admin']);
  if p_kind not in ('kommentar', 'inventurkorrektur') then
    raise exception 'Ungueltige Art: %', p_kind using errcode = '22023';
  end if;
  if p_kind = 'inventurkorrektur' and p_qty_delta is null then
    raise exception 'Inventurkorrektur braucht eine Mengenaenderung' using errcode = '22023';
  end if;
  if p_kind = 'kommentar' and nullif(trim(p_note), '') is null then
    raise exception 'Kommentar darf nicht leer sein' using errcode = '22023';
  end if;
  if not exists (select 1 from lager.stock_daily d where d.sku = p_sku) then
    raise exception 'Unbekannte SKU: %', p_sku using errcode = '22023';
  end if;
  insert into lager.sku_notes (sku, kind, note, qty_delta, effective_date, created_by)
  values (p_sku, p_kind, nullif(trim(p_note), ''),
          case when p_kind = 'inventurkorrektur' then p_qty_delta end,
          coalesce(p_effective_date, (now() at time zone 'Europe/Berlin')::date), auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- Kommentare/Korrekturen auflisten (alle Rollen). p_sku = null: alle SKUs.
create or replace function okapi_stock.lager_notes_list(p_sku text default null, p_days integer default 90)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  v_days integer := least(greatest(coalesce(p_days, 90), 1), 730);
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', n.id, 'sku', n.sku, 'kind', n.kind, 'note', n.note, 'qty_delta', n.qty_delta,
             'effective_date', n.effective_date, 'created_at', n.created_at,
             'created_by', (select r.display_name from lager.user_roles r where r.user_id = n.created_by))
           order by n.created_at desc)
    from lager.sku_notes n
    where (p_sku is null or n.sku = p_sku)
      and n.effective_date >= (now() at time zone 'Europe/Berlin')::date - v_days
  ), '[]'::jsonb);
end;
$$;

-- Lieferzeit/Puffer/Herkunft je SKU pflegen (einkauf, admin).
create or replace function okapi_stock.lager_sku_settings_upsert(
  p_sku text, p_lead_time_days integer, p_safety_days integer,
  p_supply_source text default null, p_supplier text default null,
  p_active boolean default true, p_note text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['einkauf', 'admin']);
  if coalesce(p_lead_time_days, 0) < 0 or coalesce(p_safety_days, 0) < 0 then
    raise exception 'Werte duerfen nicht negativ sein' using errcode = '22023';
  end if;
  if p_supply_source is not null and p_supply_source not in ('extern', 'intern') then
    raise exception 'Herkunft muss extern oder intern sein' using errcode = '22023';
  end if;
  insert into lager.sku_settings (sku, lead_time_days, safety_days, supply_source, supplier, active, note)
  values (p_sku, p_lead_time_days, coalesce(p_safety_days, 7), p_supply_source,
          nullif(trim(p_supplier), ''), coalesce(p_active, true), p_note)
  on conflict (sku) do update
    set lead_time_days = excluded.lead_time_days,
        safety_days    = excluded.safety_days,
        supply_source  = excluded.supply_source,
        supplier       = excluded.supplier,
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
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
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

-- 6. Erstbefuellung der Arbeitskopie --------------------------------------------------
select lager.sync_from_magento() as initial_rows_copied;

commit;
