-- Minimal-Nachbau der Instanz fuer lokale Tests (KEINE Produktion).
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth; create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create schema okapi_stock;
grant usage on schema okapi_stock to anon;  -- unguenstigster Fall: anon darf das Schema sehen
create table okapi_stock.stock_history(id bigint generated always as identity primary key, product_name text not null, sku text not null, stock_qty numeric not null, stock_offset numeric not null, effective_stock numeric not null, date date not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(sku,date));
insert into auth.users values ('11111111-1111-1111-1111-111111111111'),('22222222-2222-2222-2222-222222222222'),('33333333-3333-3333-3333-333333333333'),('44444444-4444-4444-4444-444444444444'),('55555555-5555-5555-5555-555555555555');
-- A: sinkt 5/Tag, Wareneingang +200 an Tag 5; B: konstant; C: sinkt 1/Tag; D: sinkt 2/Tag, Inventurkorrektur -10 an Tag 8
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date)
select 'Prod A','A',v,0,v,current_date-(10-i) from (select i, case when i<5 then 100-5*i else 300-5*(i-5) end v from generate_series(0,10) i) t;
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date)
select 'Prod B','B',50,0,50,current_date-(10-i) from generate_series(0,10) i;
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date)
select 'Prod C','C',30-i,0,30-i,current_date-(10-i) from generate_series(0,10) i;
insert into okapi_stock.stock_history(product_name,sku,stock_qty,stock_offset,effective_stock,date)
select 'Prod D','D',v,3,v,current_date-(10-i) from (select i, case when i<8 then 100-2*i else 100-2*i-10 end v from generate_series(0,10) i) t;
