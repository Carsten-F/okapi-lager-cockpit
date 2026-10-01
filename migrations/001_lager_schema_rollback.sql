-- Rollback zu 001_lager_schema.sql
-- ACHTUNG: loescht user_roles, sku_settings und alle erfassten expected_orders.
-- okapi_stock.stock_history und ihre Policies bleiben unberuehrt.

begin;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'okapi_stock' and p.proname like 'lager\_%'
  loop
    execute format('drop function %s', f);
  end loop;
end $$;

drop schema if exists lager cascade;

commit;
