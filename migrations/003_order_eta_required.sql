-- 003_order_eta_required.sql
-- Eine Bestellung braucht Liefertermin ODER Zeitspanne bis zur Einbuchung. Ohne beides
-- wuerde die Prognose sie als "kommt morgen" werten.
-- Nur die Funktion lager_order_add wird ersetzt (gleiche Signatur und Rechte). Wiederholbar.

begin;

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
  return jsonb_build_object('id', v_id);
end;
$$;

revoke all on function okapi_stock.lager_order_add(text, numeric, date, date, integer, text, text) from public, anon;
grant execute on function okapi_stock.lager_order_add(text, numeric, date, date, integer, text, text) to authenticated, service_role;

commit;
