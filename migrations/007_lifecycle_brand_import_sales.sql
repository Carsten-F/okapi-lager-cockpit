-- 007_lifecycle_brand_import_sales.sql
-- 1. Lebenszyklus je Artikel: aktiv | inaktiv_saison (nicht aktiv, Jahreszeit) | inaktiv_archiv (nicht aktiv, Archiv).
--    Ersetzt das bisherige Feld "active" (Altwerte: active = false -> inaktiv_archiv).
-- 2. Marke je Artikel (Standard: aus dem Produktnamen abgeleitet, pro Artikel aenderbar).
-- 3. Massenpflege der Artikel-Einstellungen per CSV (Pruefung vorab, alles oder nichts).
-- 4. Absatzhistorie (Tagesabsatz je Artikel, aus dem Rechnungsexport) fuer die Prognose.
-- 5. Bestandsangaben: effective_stock = bestellbarer Bestand (Magento). "bestellbar" in der API = effective_stock;
--    zusaetzlich stock_qty und stock_offset.
-- Wiederholbar.

begin;

-- 1. + 2. Spalten -------------------------------------------------------------------------
alter table lager.sku_settings add column if not exists brand text;
alter table lager.sku_settings add column if not exists lifecycle text not null default 'aktiv';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'sku_settings_lifecycle_check') then
    alter table lager.sku_settings add constraint sku_settings_lifecycle_check
      check (lifecycle in ('aktiv', 'inaktiv_saison', 'inaktiv_archiv'));
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'lager' and table_name = 'sku_settings' and column_name = 'active') then
    update lager.sku_settings set lifecycle = 'inaktiv_archiv' where active = false and lifecycle = 'aktiv';
  end if;
end $$;

-- Marke aus dem Produktnamen. Pro Artikel ueberschreibbar (sku_settings.brand).
create or replace function lager.derive_brand(p_name text)
returns text
language sql
immutable
set search_path to 'pg_temp'
as $$
  select case
    when p_name ~ '^\s*[bB][iI][oO][sS][tT][iI][cC][kK][iI][eE][sS]' then 'biostickies'
    when p_name ~ '^\s*[kK][nN](ä|Ä|ae|AE|a|A)[xX]' then 'KNÄX'
    when p_name ~ '^\s*[tT][eE][eE][pP][fF][eE][rR][dD][cC][hH][eE][nN]' then 'Teepferdchen'
    when p_name ~ '^\s*[hH][aA][pP][pP][yY] [bB][eE][lL][lL][yY]' then 'Happy Belly'
    when p_name ~ '^\s*[oO][kK][aA][pP][iI]' then 'OKAPI'
    else 'Sonstige'
  end;
$$;
revoke all on function lager.derive_brand(text) from public, anon, authenticated;

-- 4. Absatzhistorie -------------------------------------------------------------------------
create table if not exists lager.sales_daily (
  sku             text not null,
  date            date not null,           -- Bestelltag
  qty_endkunde    numeric not null default 0,
  qty_therapeut   numeric not null default 0,
  qty_haendler    numeric not null default 0,
  qty_mitarbeiter numeric not null default 0,
  qty_sonstige    numeric not null default 0,
  lines           integer not null default 0,
  revenue_net     numeric not null default 0,
  source          text not null default 'excel',
  primary key (sku, date)
);
create index if not exists sales_daily_date_idx on lager.sales_daily (date);

-- Artikelstamm aus dem Absatz (auch ausgelaufene / alte Artikelnummern)
create table if not exists lager.sku_catalog (
  sku          text primary key,
  product_name text,
  company      text,
  first_sale   date,
  last_sale    date,
  total_qty    numeric not null default 0
);

do $$
declare t text;
begin
  foreach t in array array['sales_daily', 'sku_catalog'] loop
    execute format('alter table lager.%I enable row level security', t);
    execute format('drop policy if exists no_direct_client_access on lager.%I', t);
    execute format(
      'create policy no_direct_client_access on lager.%I as restrictive for all to public using (false) with check (false)', t);
    execute format('revoke all on lager.%I from public, anon, authenticated', t);
  end loop;
end $$;

-- Funktionen: Signaturen aendern sich -> alte entfernen ------------------------------------
drop function if exists okapi_stock.lager_sku_settings_upsert(text, integer, integer, text, text, boolean, text);

-- Letzter Bestand je Artikel mit Marke und Lebenszyklus.
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
             d.effective_stock, d.effective_stock as bestellbar,
             coalesce(nullif(trim(s.brand), ''), lager.derive_brand(d.product_name)) as brand,
             coalesce(s.lifecycle, 'aktiv') as lifecycle
      from lager.stock_daily d
      left join lager.sku_settings s on s.sku = d.sku
      order by d.sku, d.date desc
    ) x
  ), '[]'::jsonb);
end;
$$;

-- Bestandsverlauf: bestellbar = effective_stock
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
             'stock_offset', d.stock_offset, 'bestellbar', d.effective_stock,
             'korrektur', (select sum(n.qty_delta) from lager.sku_notes n
                           where n.sku = d.sku and n.kind = 'inventurkorrektur' and n.effective_date = d.date))
           order by d.date)
    from lager.stock_daily d
    where d.sku = p_sku
      and d.date >= (now() at time zone 'Europe/Berlin')::date - v_days
  ), '[]'::jsonb);
end;
$$;

-- Prognose (wie 006), jetzt mit Marke, Lebenszyklus und allen Artikeln; die Oberflaeche filtert.
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
             d.effective_stock, d.effective_stock as bestellbar, d.stock_qty, d.stock_offset
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
      select l.sku, l.product_name, l.stock_date, l.effective_stock, l.bestellbar, l.stock_qty, l.stock_offset,
             coalesce(s.safety_days, 7) as safety_days,
             coalesce(s.lifecycle, 'aktiv')  as lifecycle,
             coalesce(nullif(trim(s.brand), ''), lager.derive_brand(l.product_name)) as brand,
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
                          and greatest(coalesce(o.eta, c.stock_date + 1) - c.stock_date, 1) <= g.day), 0) < c.u
      group by c.sku
    ),
    res as (
      select c.*, i.incoming_qty, i.next_arrival, i.overdue_orders,
             case when c.u > 0 then c.effective_stock / c.u when c.effective_stock <= 0 then 0 end as cover,
             sim.stockout_day
      from calc c
      join inc i on i.sku = c.sku
      left join sim on sim.sku = c.sku
    )
    select jsonb_agg(to_jsonb(r2) order by r2.sort_key, r2.product_name)
    from (
      select r.sku, r.product_name, r.brand, r.lifecycle, r.stock_date, r.effective_stock, r.bestellbar, r.stock_qty, r.stock_offset,
             round(r.u, 3) as avg_daily_usage,
             round(r.cover, 1) as days_of_cover,
             case when r.u > 0 then r.stock_date + floor(r.cover)::integer when r.effective_stock <= 0 then r.stock_date end as stockout_date,
             r.incoming_qty, r.next_arrival, r.overdue_orders,
             case when r.u > 0 and r.incoming_qty > 0 and r.stockout_day is not null then r.stock_date + r.stockout_day end
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
               when r.cover <= r.lead_time_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > floor(r.cover)) then 'bestellt'
               when r.cover <= r.lead_time_days then 'kritisch'
               when r.cover <= r.lead_time_days + r.safety_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > floor(r.cover)) then 'bestellt'
               when r.cover <= r.lead_time_days + r.safety_days then 'bestellen'
               else 'ok'
             end as status,
             case
               when r.effective_stock <= 0 and r.incoming_qty > 0 then 1
               when r.effective_stock <= 0 then 0
               when r.u is null or r.u = 0 then 3
               when r.cover <= r.lead_time_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > floor(r.cover)) then 1
               when r.cover <= r.lead_time_days then 0
               when r.cover <= r.lead_time_days + r.safety_days and r.incoming_qty > 0
                    and (r.stockout_day is null or r.stockout_day > floor(r.cover)) then 2
               when r.cover <= r.lead_time_days + r.safety_days then 1
               else 2
             end as sort_key
      from res r
    ) r2
  ), '[]'::jsonb);
end;
$$;


-- Artikel-Einstellungen --------------------------------------------------------------------
create or replace function okapi_stock.lager_sku_settings_upsert(
  p_sku text, p_lead_time_days integer, p_safety_days integer,
  p_supply_source text default null, p_supplier text default null,
  p_lifecycle text default 'aktiv', p_note text default null, p_brand text default null)
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
  if coalesce(p_lifecycle, 'aktiv') not in ('aktiv', 'inaktiv_saison', 'inaktiv_archiv') then
    raise exception 'Ungueltiger Lebenszyklus: %', p_lifecycle using errcode = '22023';
  end if;
  insert into lager.sku_settings (sku, lead_time_days, safety_days, supply_source, supplier, lifecycle, note, brand)
  values (p_sku, p_lead_time_days, coalesce(p_safety_days, 7), p_supply_source, nullif(trim(p_supplier), ''),
          coalesce(p_lifecycle, 'aktiv'), p_note, nullif(trim(p_brand), ''))
  on conflict (sku) do update
    set lead_time_days = excluded.lead_time_days,
        safety_days    = excluded.safety_days,
        supply_source  = excluded.supply_source,
        supplier       = excluded.supplier,
        lifecycle      = excluded.lifecycle,
        note           = excluded.note,
        brand          = excluded.brand,
        updated_at     = now();
  return jsonb_build_object('sku', p_sku);
end;
$$;

-- Massenpflege per CSV. p_rows: [{"row": 2, "sku": "...", "brand": "...", "lifecycle": "...", "supply_source": "...",
--   "supplier": "...", "lead_time_days": "14" | "auto", "safety_days": "7", "note": "..."}]
--   Leere Felder lassen den bisherigen Wert unveraendert; "auto" bei lead_time_days stellt auf automatisch.
--   p_dry_run = true: nur pruefen. Gibt es Fehler, wird nichts geschrieben (alles oder nichts).
create or replace function okapi_stock.lager_sku_settings_import(p_rows jsonb, p_dry_run boolean default true)
returns jsonb
language plpgsql
volatile
security definer
set search_path to 'lager', 'pg_temp'
as $$
declare
  r        jsonb;
  v_row    integer;
  v_sku    text;
  v_errs   jsonb := '[]'::jsonb;
  v_chg    jsonb := '[]'::jsonb;
  v_neu    integer := 0;
  v_geaend integer := 0;
  v_gleich integer := 0;
  v_seen   text[] := '{}';
  cur      lager.sku_settings%rowtype;
  v_exists boolean;
  txt      text;
  low      text;
  n_brand  text; n_life text; n_src text; n_sup text; n_note text;
  n_lead   integer; n_lead_set boolean; n_safe integer;
  fields   text[];
begin
  perform lager.require_role(array['einkauf', 'admin']);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'Keine Zeilen uebergeben' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'Zu viele Zeilen (maximal 5000)' using errcode = '22023';
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := coalesce(nullif(r->>'row', '')::integer, 0);
    v_sku := nullif(trim(r->>'sku'), '');
    fields := '{}';
    n_brand := null; n_life := null; n_src := null; n_sup := null; n_note := null;
    n_lead := null; n_lead_set := false; n_safe := null;

    if v_sku is null then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', null, 'message', 'Artikelnummer fehlt'); continue;
    end if;
    if v_sku = any (v_seen) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku, 'message', 'Artikelnummer kommt mehrfach vor'); continue;
    end if;
    v_seen := v_seen || v_sku;
    if not exists (select 1 from lager.stock_daily d where d.sku = v_sku) then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku, 'message', 'Unbekannte Artikelnummer (nicht im Lagerbestand)'); continue;
    end if;

    -- Lebenszyklus (auch in Umgangssprache)
    txt := nullif(trim(r->>'lifecycle'), '');
    if txt is not null then
      low := lower(txt);
      n_life := case
        when low in ('aktiv', 'ja', 'j', '1', 'true', 'active') then 'aktiv'
        when low in ('inaktiv_saison', 'saison', 'jahreszeit', 'nicht aktiv (jahreszeit)', 'inaktiv (saison)',
                     'inaktiv (jahreszeit)', 'nicht aktiv jahreszeit', 'nicht aktiv saison') then 'inaktiv_saison'
        when low in ('inaktiv_archiv', 'archiv', 'inaktiv', 'nicht aktiv', 'nicht aktiv (archiv)', 'inaktiv (archiv)',
                     'nein', 'n', '0', 'false') then 'inaktiv_archiv'
        else null end;
      if n_life is null then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku,
          'message', format('Lebenszyklus nicht erkannt: "%s" (erlaubt: aktiv, nicht aktiv (Jahreszeit), nicht aktiv (Archiv))', txt));
        continue;
      end if;
    end if;

    -- Herkunft
    txt := nullif(trim(r->>'supply_source'), '');
    if txt is not null then
      low := lower(txt);
      n_src := case
        when low in ('extern', 'externer lieferant', 'lieferant', 'fremd', 'e') then 'extern'
        when low in ('intern', 'onyx', 'intern (onyx)', 'eigenfertigung', 'i') then 'intern'
        else null end;
      if n_src is null then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku,
          'message', format('Herkunft nicht erkannt: "%s" (erlaubt: extern, intern)', txt));
        continue;
      end if;
    end if;

    -- Lieferzeit ("auto" = automatisch) und Puffer
    txt := nullif(trim(r->>'lead_time_days'), '');
    if txt is not null then
      if lower(txt) in ('auto', 'automatisch') then n_lead := null; n_lead_set := true;
      elsif txt ~ '^[0-9]{1,3}$' then n_lead := txt::integer; n_lead_set := true;
      else
        v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku,
          'message', format('Lieferzeit: ganze Zahl 0 bis 999 oder "auto", gefunden "%s"', txt));
        continue;
      end if;
    end if;
    txt := nullif(trim(r->>'safety_days'), '');
    if txt is not null then
      if txt ~ '^[0-9]{1,3}$' then n_safe := txt::integer;
      else
        v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku,
          'message', format('Puffer: ganze Zahl 0 bis 999, gefunden "%s"', txt));
        continue;
      end if;
    end if;

    n_brand := nullif(trim(r->>'brand'), '');
    n_sup := nullif(trim(r->>'supplier'), '');
    n_note := nullif(trim(r->>'note'), '');
    if length(coalesce(n_brand, '')) > 60 or length(coalesce(n_sup, '')) > 120 or length(coalesce(n_note, '')) > 500 then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'sku', v_sku,
        'message', 'Text zu lang (Marke 60, Lieferant 120, Notiz 500 Zeichen)');
      continue;
    end if;

    select * into cur from lager.sku_settings where sku = v_sku;
    v_exists := found;
    -- Marke, die der automatisch erkannten entspricht, ist keine Aenderung (Roundtrip Export -> Excel -> Import)
    if n_brand is not null and cur.brand is null and n_brand = lager.derive_brand(
         (select d.product_name from lager.stock_daily d where d.sku = v_sku order by d.date desc limit 1)) then
      n_brand := null;
    end if;
    if not v_exists then
      cur.sku := v_sku; cur.lead_time_days := null; cur.safety_days := 7; cur.supply_source := null;
      cur.supplier := null; cur.lifecycle := 'aktiv'; cur.brand := null; cur.note := null;
    end if;
    if n_life  is not null and n_life  is distinct from cur.lifecycle     then fields := array_append(fields, 'Lebenszyklus'); end if;
    if n_brand is not null and n_brand is distinct from cur.brand         then fields := array_append(fields, 'Marke'); end if;
    if n_src   is not null and n_src   is distinct from cur.supply_source then fields := array_append(fields, 'Herkunft'); end if;
    if n_sup   is not null and n_sup   is distinct from cur.supplier      then fields := array_append(fields, 'Lieferant'); end if;
    if n_lead_set and n_lead is distinct from cur.lead_time_days          then fields := array_append(fields, 'Lieferzeit'); end if;
    if n_safe  is not null and n_safe  is distinct from cur.safety_days   then fields := array_append(fields, 'Puffer'); end if;
    if n_note  is not null and n_note  is distinct from cur.note          then fields := array_append(fields, 'Notiz'); end if;

    if array_length(fields, 1) is null then v_gleich := v_gleich + 1; continue; end if;
    if v_exists then v_geaend := v_geaend + 1; else v_neu := v_neu + 1; end if;
    if jsonb_array_length(v_chg) < 100 then
      v_chg := v_chg || jsonb_build_object('row', v_row, 'sku', v_sku, 'fields', to_jsonb(fields), 'new', not v_exists);
    end if;

    if not p_dry_run then
      insert into lager.sku_settings (sku, brand, lifecycle, supply_source, supplier, lead_time_days, safety_days, note)
      values (v_sku, coalesce(n_brand, cur.brand), coalesce(n_life, cur.lifecycle), coalesce(n_src, cur.supply_source),
              coalesce(n_sup, cur.supplier), case when n_lead_set then n_lead else cur.lead_time_days end,
              coalesce(n_safe, cur.safety_days), coalesce(n_note, cur.note))
      on conflict (sku) do update
        set brand = excluded.brand, lifecycle = excluded.lifecycle, supply_source = excluded.supply_source,
            supplier = excluded.supplier, lead_time_days = excluded.lead_time_days,
            safety_days = excluded.safety_days, note = excluded.note, updated_at = now();
    end if;
  end loop;

  -- Alles oder nichts: ein Fehler in einer spaeteren Zeile rollt bereits geschriebene Zeilen zurueck
  if not p_dry_run and jsonb_array_length(v_errs) > 0 then
    raise exception 'Import abgebrochen: % Fehler, nichts wurde geschrieben', jsonb_array_length(v_errs) using errcode = 'P0001';
  end if;

  return jsonb_build_object('applied', (not p_dry_run), 'errors', v_errs, 'changes', v_chg,
    'summary', jsonb_build_object('neu', v_neu, 'geaendert', v_geaend, 'unveraendert', v_gleich));
end;
$$;

-- Liste der Einstellungen (alle Rollen duerfen lesen), mit Marke und Lebenszyklus
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

-- Absatz je Monat und Jahr (Vergleich der Jahre). Menge ohne Mitarbeiter.
create or replace function okapi_stock.lager_sales_monthly(p_sku text)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'lager', 'pg_temp'
as $$
begin
  perform lager.require_role(array['viewer', 'lager', 'einkauf', 'admin']);
  return coalesce((
    select jsonb_agg(jsonb_build_object('year', y, 'month', m, 'qty', q, 'qty_b2b', b) order by y, m)
    from (
      select extract(year from s.date)::int as y, extract(month from s.date)::int as m,
             sum(s.qty_endkunde + s.qty_therapeut + s.qty_haendler + s.qty_sonstige) as q,
             sum(s.qty_therapeut + s.qty_haendler) as b
      from lager.sales_daily s
      where s.sku = p_sku
      group by 1, 2
    ) t
  ), '[]'::jsonb);
end;
$$;

-- Rechte der API-Funktionen --------------------------------------------------------------
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

-- Altes Feld "active" entfernen (Werte sind in lifecycle uebernommen; keine Funktion nutzt es mehr)
alter table lager.sku_settings drop column if exists active;

commit;
