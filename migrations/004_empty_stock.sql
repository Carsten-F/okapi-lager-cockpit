-- 004_empty_stock.sql
-- Bestand 0 (oder negativ) ist der dringendste Fall und gilt als 'kritisch' (mit offener
-- Bestellung 'bestellt'), auch wenn im Fenster kein Verbrauch erkennbar ist. Neu im Ergebnis:
-- out_of_stock; Reichweite 0 Tage, Ausverkaufsdatum = Bestandsdatum.
-- Ersetzt nur okapi_stock.lager_forecast (gleiche Signatur und Rechte). Wiederholbar.

begin;

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
             case when c.u > 0 then c.effective_stock / c.u when c.effective_stock <= 0 then 0 end as cover,
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
             case when r.u > 0 then r.stock_date + floor(r.cover)::integer when r.effective_stock <= 0 then r.stock_date end as stockout_date,
             r.incoming_qty, r.next_arrival, r.overdue_orders,
             case when r.u > 0 and r.stockout_day is not null then r.stock_date + r.stockout_day end
               as stockout_date_incl_orders,
             r.lead_time_days, r.lead_time_source, r.safety_days, r.supply_source, r.default_supplier,
             case when r.u > 0 then r.stock_date + floor(r.cover)::integer - r.lead_time_days - r.safety_days
                  when r.effective_stock <= 0 then r.stock_date - r.lead_time_days - r.safety_days end
               as order_by_date,
             (r.effective_stock <= 0) as out_of_stock,
             (r.stock_date < v_today - 2) as data_stale,
             case
               when r.effective_stock <= 0 and r.incoming_qty > 0 then 'bestellt'
               when r.effective_stock <= 0 then 'kritisch'
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
               when r.effective_stock <= 0 and r.incoming_qty > 0 then 1
               when r.effective_stock <= 0 then 0
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

revoke all on function okapi_stock.lager_forecast(integer) from public, anon;
grant execute on function okapi_stock.lager_forecast(integer) to authenticated, service_role;

commit;
