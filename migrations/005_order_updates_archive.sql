-- 005_order_updates_archive.sql
-- 1. Lager darf Bestellungen nachtraeglich aendern (Liefertermin, Menge, Kommentar, Lieferant);
--    Statuswechsel (bestaetigt, storniert, ...) bleibt einkauf/admin.
-- 2. Jede Aenderung wird protokolliert (lager.purchase_order_log): wer, wann, alt -> neu.
-- 3. Automatische Wareneingangs-Erkennung: Steigt der Bestand eines Artikels, wird der Zugang
--    den offenen Bestellungen zugeordnet (aelteste erwartete Lieferung zuerst). Eine Bestellung
--    gilt als eingebucht und wird archiviert, sobald mindestens 90 % der bestellten Menge
--    eingegangen sind; sonst teilgeliefert (Rest bleibt offen). Zugaenge unter 10 % der Restmenge
--    werden nicht zugeordnet. Jeder Zugang wird nur einmal verarbeitet (lager.inflow_log).
--    Automatisch gebuchte Bestellungen lassen sich zuruecksetzen (lager_order_reopen).
-- 4. Archiv: eingebuchte und stornierte Bestellungen (archived_at). Offene Bestellungen liefern
--    weiterhin allein die "naechste Lieferung" in der Prognose.
-- Wiederholbar.

begin;

-- Spalten und Tabellen ---------------------------------------------------------------
alter table lager.purchase_orders add column if not exists archived_at timestamptz;
alter table lager.purchase_orders add column if not exists received_source text
  check (received_source in ('manuell', 'auto'));
update lager.purchase_orders set archived_at = coalesce(updated_at, now())
 where status in ('eingebucht', 'storniert') and archived_at is null;

create table if not exists lager.purchase_order_log (
  id       bigint generated always as identity primary key,
  order_id bigint not null references lager.purchase_orders (id) on delete cascade,
  at       timestamptz not null default now(),
  by_user  uuid references auth.users (id) on delete set null,
  source   text not null default 'user' check (source in ('user', 'auto')),
  action   text not null,
  changes  jsonb,
  note     text
);
create index if not exists purchase_order_log_order_idx on lager.purchase_order_log (order_id, at);

create table if not exists lager.inflow_log (
  sku          text not null,
  date         date not null,
  inflow       numeric not null,
  allocations  jsonb not null default '[]'::jsonb,   -- [{order_id, qty}]
  surplus      numeric not null default 0,
  processed_at timestamptz not null default now(),
  primary key (sku, date)
);

do $$
declare t text;
begin
  foreach t in array array['purchase_order_log', 'inflow_log'] loop
    execute format('alter table lager.%I enable row level security', t);
    execute format('drop policy if exists no_direct_client_access on lager.%I', t);
    execute format(
      'create policy no_direct_client_access on lager.%I as restrictive for all to public using (false) with check (false)', t);
    execute format('revoke all on lager.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- Interne Hilfsfunktionen ----------------------------------------------------------------
create or replace function lager.log_order(p_order bigint, p_action text, p_changes jsonb,
                                           p_source text default 'user', p_note text default null)
returns void
language sql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
  insert into lager.purchase_order_log (order_id, by_user, source, action, changes, note)
  values (p_order, case when p_source = 'user' then auth.uid() end, p_source, p_action, p_changes, p_note);
$$;
revoke all on function lager.log_order(bigint, text, jsonb, text, text) from public, anon, authenticated;

-- Erkennt Bestandszugaenge und ordnet sie offenen Bestellungen zu. Gibt die Zahl der
-- gebuchten Zuordnungen zurueck.
create or replace function lager.reconcile_receipts()
returns integer
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  c_close  constant numeric := 0.9;   -- ab 90 % der bestellten Menge: eingebucht
  c_min    constant numeric := 0.1;   -- Zugang mindestens 10 % der Restmenge, sonst keine Zuordnung
  r        record;
  o        record;
  v_left   numeric;
  v_rem    numeric;
  v_take   numeric;
  v_status text;
  v_alloc  jsonb;
  n        integer := 0;
begin
  for r in
    select s.sku, s.date, s.inflow
    from (
      select d.sku, d.date,
             d.effective_stock - lag(d.effective_stock) over (partition by d.sku order by d.date)
             - coalesce((select sum(k.qty_delta) from lager.sku_notes k
                         where k.sku = d.sku and k.kind = 'inventurkorrektur' and k.effective_date = d.date), 0) as inflow
      from lager.stock_daily d
    ) s
    where s.inflow > 0
      and not exists (select 1 from lager.inflow_log l where l.sku = s.sku and l.date = s.date)
    order by s.date, s.sku
  loop
    v_left := r.inflow;
    v_alloc := '[]'::jsonb;
    for o in
      select p.id, p.qty, p.received_qty
      from lager.purchase_orders p
      where p.sku = r.sku and p.status in ('bestellt', 'bestaetigt', 'teilgeliefert')
        and p.qty > p.received_qty and p.ordered_on <= r.date
      order by coalesce(p.expected_delivery, p.ordered_on + p.expected_lead_days, p.ordered_on), p.id
      for update
    loop
      exit when v_left <= 0;
      v_rem := o.qty - o.received_qty;
      continue when v_left < c_min * v_rem;
      v_take := least(v_left, v_rem);
      v_status := case when o.received_qty + v_take >= c_close * o.qty then 'eingebucht' else 'teilgeliefert' end;
      update lager.purchase_orders
         set received_qty = received_qty + v_take, received_on = r.date, status = v_status,
             received_source = 'auto',
             archived_at = case when v_status = 'eingebucht' then now() else null end,
             updated_at = now()
       where id = o.id;
      perform lager.log_order(o.id, 'wareneingang_erkannt',
        jsonb_build_object('zugang_am', r.date, 'menge', v_take, 'status', v_status), 'auto');
      v_alloc := v_alloc || jsonb_build_object('order_id', o.id, 'qty', v_take);
      v_left := v_left - v_take;
      n := n + 1;
    end loop;
    insert into lager.inflow_log (sku, date, inflow, allocations, surplus)
    values (r.sku, r.date, r.inflow, v_alloc, v_left);
  end loop;
  return n;
end;
$$;
revoke all on function lager.reconcile_receipts() from public, anon, authenticated;

-- Abgleich aus Magento: Kopie aktualisieren, dann Wareneingaenge erkennen.
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
  perform lager.reconcile_receipts();
  return n;
end;
$$;
revoke all on function lager.sync_from_magento() from public, anon, authenticated;

-- API ---------------------------------------------------------------------------------------

-- Bestellung anlegen (einkauf, admin); wie 003, zusaetzlich mit Protokoll.
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
  if p_expected_delivery is null and p_expected_lead_days is null then
    raise exception 'Bitte Liefertermin oder Zeitspanne bis zur Einbuchung angeben' using errcode = '22023';
  end if;
  if not exists (select 1 from lager.stock_daily d where d.sku = p_sku) then
    raise exception 'Unbekannte SKU: %', p_sku using errcode = '22023';
  end if;
  insert into lager.purchase_orders
    (sku, qty, ordered_on, expected_delivery, expected_lead_days, supplier, comment, created_by, updated_by)
  values (p_sku, p_qty, p_ordered_on, p_expected_delivery, p_expected_lead_days,
          nullif(trim(p_supplier), ''), nullif(trim(p_comment), ''), auth.uid(), auth.uid())
  returning id into v_id;
  perform lager.log_order(v_id, 'angelegt', jsonb_build_object('menge', p_qty, 'bestellt_am', p_ordered_on,
    'liefertermin', p_expected_delivery, 'zeitspanne_tage', p_expected_lead_days, 'lieferant', nullif(trim(p_supplier), '')));
  return jsonb_build_object('id', v_id);
end;
$$;

-- Bestellung aendern. lager, einkauf, admin duerfen Menge, Liefertermin, Zeitspanne, Lieferant und
-- Kommentar aendern (lager nur an offenen Bestellungen); den Status nur einkauf und admin.
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
declare
  v_role    text;
  o         lager.purchase_orders%rowtype;
  v_ch      jsonb := '{}'::jsonb;
  v_status  text;
  v_sup     text := nullif(trim(p_supplier), '');
  v_com     text := nullif(trim(p_comment), '');
begin
  v_role := lager.require_role(array['lager', 'einkauf', 'admin']);
  if p_status is not null and p_status not in ('bestellt', 'bestaetigt', 'teilgeliefert', 'eingebucht', 'storniert') then
    raise exception 'Ungueltiger Status: %', p_status using errcode = '22023';
  end if;
  if p_status is not null and v_role not in ('einkauf', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into o from lager.purchase_orders where id = p_id for update;
  if not found then
    raise exception 'Bestellung % nicht gefunden', p_id using errcode = 'P0002';
  end if;
  if v_role = 'lager' and o.status not in ('bestellt', 'bestaetigt', 'teilgeliefert') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_qty is not null and p_qty <= 0 then
    raise exception 'Menge muss groesser 0 sein' using errcode = '22023';
  end if;
  if p_qty is not null and p_qty < o.received_qty then
    raise exception 'Menge darf nicht kleiner sein als die bereits eingegangene Menge (%)', o.received_qty using errcode = '22023';
  end if;
  if p_qty is not null and p_qty is distinct from o.qty then
    v_ch := v_ch || jsonb_build_object('menge', jsonb_build_object('alt', o.qty, 'neu', p_qty)); end if;
  if p_expected_delivery is not null and p_expected_delivery is distinct from o.expected_delivery then
    v_ch := v_ch || jsonb_build_object('liefertermin', jsonb_build_object('alt', o.expected_delivery, 'neu', p_expected_delivery)); end if;
  if p_expected_lead_days is not null and p_expected_lead_days is distinct from o.expected_lead_days then
    v_ch := v_ch || jsonb_build_object('zeitspanne_tage', jsonb_build_object('alt', o.expected_lead_days, 'neu', p_expected_lead_days)); end if;
  if v_sup is not null and v_sup is distinct from o.supplier then
    v_ch := v_ch || jsonb_build_object('lieferant', jsonb_build_object('alt', o.supplier, 'neu', v_sup)); end if;
  if p_status is not null and p_status is distinct from o.status then
    v_ch := v_ch || jsonb_build_object('status', jsonb_build_object('alt', o.status, 'neu', p_status)); end if;
  if v_com is not null and v_com is distinct from o.comment then
    v_ch := v_ch || jsonb_build_object('kommentar', jsonb_build_object('alt', o.comment, 'neu', v_com)); end if;
  if v_ch = '{}'::jsonb then
    return jsonb_build_object('id', p_id, 'changed', false);
  end if;
  v_status := coalesce(p_status, o.status);
  update lager.purchase_orders
     set qty                = coalesce(p_qty, qty),
         expected_delivery  = coalesce(p_expected_delivery, expected_delivery),
         expected_lead_days = coalesce(p_expected_lead_days, expected_lead_days),
         supplier           = coalesce(v_sup, supplier),
         status             = v_status,
         comment            = coalesce(v_com, comment),
         archived_at        = case when v_status in ('eingebucht', 'storniert') then coalesce(archived_at, now()) else null end,
         updated_by         = auth.uid(),
         updated_at         = now()
   where id = p_id;
  perform lager.log_order(p_id, 'geaendert', v_ch);
  return jsonb_build_object('id', p_id, 'changed', true);
end;
$$;

-- Wareneingang manuell buchen (lager, einkauf, admin); mit Protokoll und Archivierung.
create or replace function okapi_stock.lager_order_receive(
  p_id bigint, p_received_on date, p_received_qty numeric, p_comment text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  o        lager.purchase_orders%rowtype;
  v_status text;
  v_total  numeric;
begin
  perform lager.require_role(array['lager', 'einkauf', 'admin']);
  if p_received_on is null or p_received_qty is null or p_received_qty <= 0 then
    raise exception 'Warenzugangsdatum und Menge > 0 erforderlich' using errcode = '22023';
  end if;
  select * into o from lager.purchase_orders where id = p_id and status <> 'storniert' for update;
  if not found then
    raise exception 'Bestellung % nicht gefunden oder storniert', p_id using errcode = 'P0002';
  end if;
  v_total := o.received_qty + p_received_qty;
  v_status := case when v_total >= o.qty then 'eingebucht' else 'teilgeliefert' end;
  update lager.purchase_orders
     set received_qty = v_total, received_on = p_received_on, status = v_status, received_source = 'manuell',
         archived_at = case when v_status = 'eingebucht' then coalesce(archived_at, now()) else null end,
         comment = coalesce(nullif(trim(p_comment), ''), comment),
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  perform lager.log_order(p_id, 'wareneingang_gebucht',
    jsonb_build_object('zugang_am', p_received_on, 'menge', p_received_qty, 'gesamt_eingegangen', v_total, 'status', v_status),
    'user', nullif(trim(p_comment), ''));
  return jsonb_build_object('id', p_id, 'status', v_status, 'received_qty', v_total);
end;
$$;

-- Eingebuchte Bestellung wieder oeffnen (z. B. falsche automatische Zuordnung). lager, einkauf, admin.
create or replace function okapi_stock.lager_order_reopen(p_id bigint, p_comment text default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  o lager.purchase_orders%rowtype;
begin
  perform lager.require_role(array['lager', 'einkauf', 'admin']);
  select * into o from lager.purchase_orders where id = p_id for update;
  if not found then
    raise exception 'Bestellung % nicht gefunden', p_id using errcode = 'P0002';
  end if;
  if o.status not in ('eingebucht', 'teilgeliefert') then
    raise exception 'Nur eingebuchte oder teilgelieferte Bestellungen koennen zurueckgesetzt werden' using errcode = '22023';
  end if;
  update lager.purchase_orders
     set status = 'bestellt', received_qty = 0, received_on = null, received_source = null, archived_at = null,
         updated_by = auth.uid(), updated_at = now()
   where id = p_id;
  -- Zuordnung aus dem Zugangsprotokoll entfernen, damit der Zugang wieder "nicht zugeordnet" erscheint
  update lager.inflow_log l
     set allocations = coalesce((select jsonb_agg(a) from jsonb_array_elements(l.allocations) a
                                 where (a->>'order_id')::bigint <> p_id), '[]'::jsonb)
   where jsonb_path_exists(l.allocations, '$[*] ? (@.order_id == $id)', jsonb_build_object('id', p_id));
  update lager.inflow_log l
     set surplus = l.inflow - coalesce((select sum((a->>'qty')::numeric) from jsonb_array_elements(l.allocations) a), 0)
   where l.sku = o.sku;
  perform lager.log_order(p_id, 'zurueckgesetzt',
    jsonb_build_object('status', jsonb_build_object('alt', o.status, 'neu', 'bestellt'),
                       'eingegangen', jsonb_build_object('alt', o.received_qty, 'neu', 0)),
    'user', nullif(trim(p_comment), ''));
  return jsonb_build_object('id', p_id, 'status', 'bestellt');
end;
$$;

-- Verlauf einer Bestellung (alle Rollen).
create or replace function okapi_stock.lager_order_history(p_id bigint)
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
             'at', l.at, 'source', l.source, 'action', l.action, 'changes', l.changes, 'note', l.note,
             'by', coalesce((select r.display_name from lager.user_roles r where r.user_id = l.by_user),
                            case when l.source = 'auto' then 'automatisch' end))
           order by l.at desc, l.id desc)
    from lager.purchase_order_log l where l.order_id = p_id
  ), '[]'::jsonb);
end;
$$;

-- Bestellungen auflisten. p_status: offen | archiv (eingebucht, storniert) | alle | einzelner Status
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
             'received_on', o.received_on, 'received_source', o.received_source, 'archived_at', o.archived_at,
             'comment', o.comment,
             'created_by', (select r.display_name from lager.user_roles r where r.user_id = o.created_by),
             'updated_at', o.updated_at)
           order by (o.archived_at is not null), coalesce(o.expected_delivery, o.ordered_on + o.expected_lead_days, o.ordered_on), o.id)
    from lager.purchase_orders o
    where case coalesce(p_status, 'offen')
            when 'alle' then true
            when 'offen' then o.status in ('bestellt', 'bestaetigt', 'teilgeliefert')
            when 'archiv' then o.status in ('eingebucht', 'storniert')
            else o.status = p_status
          end
  ), '[]'::jsonb);
end;
$$;

-- Erkannte Zugaenge (30 Tage) mit Zuordnung zu Bestellungen.
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
             (select jsonb_agg(distinct b.id) from (
                select (a->>'order_id')::bigint as id
                  from jsonb_array_elements(coalesce(l.allocations, '[]'::jsonb)) a
                union
                select o.id from lager.purchase_orders o
                 where o.sku = w.sku and o.received_source = 'manuell' and o.received_on between w.date - 1 and w.date
              ) b) as booked_orders
      from (
        select d.sku, d.product_name, d.date,
               d.effective_stock - lag(d.effective_stock) over (partition by d.sku order by d.date)
               - coalesce((select sum(n.qty_delta) from lager.sku_notes n
                           where n.sku = d.sku and n.kind = 'inventurkorrektur' and n.effective_date = d.date), 0)
               as inflow
        from lager.stock_daily d
        where d.date >= (now() at time zone 'Europe/Berlin')::date - v_days - 1
      ) w
      left join lager.inflow_log l on l.sku = w.sku and l.date = w.date
      where w.inflow > 0 and w.date >= (now() at time zone 'Europe/Berlin')::date - v_days
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Rechte der API-Funktionen ---------------------------------------------------------------
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

-- Ausgangslage: bisherige Zugaenge werden nur protokolliert (ohne Zuordnung), damit sie nicht
-- rueckwirkend auf bereits erfasste Bestellungen gebucht werden. Nur beim ersten Einspielen.
insert into lager.inflow_log (sku, date, inflow, allocations, surplus)
select s.sku, s.date, s.inflow, '[]'::jsonb, s.inflow
from (
  select d.sku, d.date,
         d.effective_stock - lag(d.effective_stock) over (partition by d.sku order by d.date)
         - coalesce((select sum(k.qty_delta) from lager.sku_notes k
                     where k.sku = d.sku and k.kind = 'inventurkorrektur' and k.effective_date = d.date), 0) as inflow
  from lager.stock_daily d
) s
where s.inflow > 0
  and not exists (select 1 from lager.inflow_log);

commit;
