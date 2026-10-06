-- 008: Wareneingang aus dem Lagerwert (stock_qty), Artikelnummern-Zuordnung alt -> neu, Retouren-Spalte.
-- Wiederholbar. Voraussetzung: 001-007.
--  * Bestaetigt: stock_qty steigt beim Wareneingang. effective_stock (bestellbar) steigt auch, wenn eine
--    Reservierung storniert wird - das waere ein falscher Wareneingang. Darum jetzt stock_qty.
--  * lager.sku_alias: alte Artikelnummer -> aktuelle Artikelnummer (neues Format ist das richtige). Befuellt
--    tools/aggregate_sales.py (Absatz wird schon beim Verdichten unter der neuen Nummer gefuehrt).
--  * lager.sales_daily.qty_retoure: Gutschriften/Retouren/Stornos (kommen aus dem JTL-Connector).
begin;

create table if not exists lager.sku_alias (
  old_sku    text primary key,
  new_sku    text not null,
  method     text not null default 'regel',   -- regel | name | manuell
  note       text,
  created_at timestamptz not null default now(),
  check (old_sku <> new_sku)
);
alter table lager.sku_alias enable row level security;
drop policy if exists no_direct_client_access on lager.sku_alias;
create policy no_direct_client_access on lager.sku_alias as restrictive for all to public using (false) with check (false);
revoke all on lager.sku_alias from public, anon, authenticated;

alter table lager.sales_daily add column if not exists qty_retoure numeric not null default 0;

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
             d.stock_qty - lag(d.stock_qty) over (partition by d.sku order by d.date)
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

-- Erkannte Zugaenge (30 Tage) mit Zuordnung zu Bestellungen - jetzt auf Basis von stock_qty.
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
               d.stock_qty - lag(d.stock_qty) over (partition by d.sku order by d.date)
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

-- Rechte der neuen/ersetzten API-Funktion
revoke all on function okapi_stock.lager_detected_inflows(integer) from public, anon;
grant execute on function okapi_stock.lager_detected_inflows(integer) to authenticated, service_role;

-- Umstellung ohne Rueckwirkung: bisherige stock_qty-Zugaenge nur protokollieren (nicht auf Bestellungen buchen).
insert into lager.inflow_log (sku, date, inflow, allocations, surplus)
select s.sku, s.date, s.inflow, '[]'::jsonb, s.inflow
from (
  select d.sku, d.date,
         d.stock_qty - lag(d.stock_qty) over (partition by d.sku order by d.date)
         - coalesce((select sum(k.qty_delta) from lager.sku_notes k
                     where k.sku = d.sku and k.kind = 'inventurkorrektur' and k.effective_date = d.date), 0) as inflow
  from lager.stock_daily d
) s
where s.inflow > 0
  and not exists (select 1 from lager.inflow_log l where l.sku = s.sku and l.date = s.date);

commit;
