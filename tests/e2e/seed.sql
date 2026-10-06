-- Testdaten fuer den E2E-Test (nach stub.sql, 001 und 003). Ersetzt die Stub-Beispieldaten.
truncate okapi_stock.stock_history restart identity;
delete from lager.stock_daily;
-- 14 Artikel, 60 Tage Historie, unterschiedliche Verlaeufe
insert into okapi_stock.stock_history(product_name, sku, stock_qty, stock_offset, effective_stock, date)
select p.name, p.sku, eff - p.off, p.off, eff, current_date - (59 - i)
from (values
  ('OKAPI Hagebutten',                          '1101216', 1.4, 90, 2),
  ('OKAPI Kieselgur Plus',                      '1101019', 0.4, 30, 0),
  ('OKAPI Pränat Plus Typ Z & K',               '1101001', 3.0, 400, 0),
  ('OKAPI Relax',                               '1101070', 0.8, 60, 1),
  ('OKAPI Vierjahreszeitenfutter Sommerkräuter - 5.000g',  '1101236', 2.2, 220, 4),
  ('OKAPI Vierjahreszeitenfutter Sommerkräuter - 10.000g', '1101237', 1.1, 140, 0),
  ('OKAPI Vierjahreszeitenfutter Winterweide - 5.000g',    '1101245', 1.9, 300, 3),
  ('OKAPI Vierjahreszeitenfutter Winterweide - 10.000g',   '1101246', 0.0, 75, 0),
  ('OKAPI Leinöl',                              '1101300', 0.9, 45, 0),
  ('OKAPI Mineralfutter Basis',                 '1101310', 4.5, 700, 6),
  ('OKAPI Magnesium Plus',                      '1101320', 0.5, 12, 0),
  ('OKAPI Zink Organisch',                      '1101330', 1.3, 250, 0),
  ('KNÄX Mash Flocken',                         '1101340', 2.8, 90, 5),
  ('biostickies Heucobs',                       '1101350', 6.0, 900, 8)
) as p(name, sku, rate, start, off)
cross join generate_series(0, 59) i
cross join lateral (select greatest(0, round(p.start - p.rate * i + case when p.sku in ('1101216','1101300') and i >= 40 then 150 else 0 end))::numeric as eff) e
on conflict do nothing;
-- Lagerlauf bis heute; Artikel 1101246 stagniert (kein Verbrauch)
update okapi_stock.stock_history set effective_stock = 75, stock_qty = 75 where sku = '1101246';
select lager.sync_from_magento();

insert into auth.users(id) values
 ('a0000000-0000-0000-0000-000000000001'),('a0000000-0000-0000-0000-000000000002'),
 ('a0000000-0000-0000-0000-000000000003'),('a0000000-0000-0000-0000-000000000004'),
 ('a0000000-0000-0000-0000-000000000005') on conflict do nothing;
insert into lager.user_roles values
 ('a0000000-0000-0000-0000-000000000001','admin','Admin Test'),
 ('a0000000-0000-0000-0000-000000000002','einkauf','Einkauf Test'),
 ('a0000000-0000-0000-0000-000000000003','lager','Lager Test'),
 ('a0000000-0000-0000-0000-000000000004','viewer','Lesender Test')
 on conflict do nothing;

-- Absatzhistorie fuer das Jahresvergleichs-Diagramm (Hagebutten, 2023 bis heute)
insert into lager.sales_daily (sku, date, qty_endkunde, qty_therapeut, lines)
select '1101216', make_date(y, m, 15), 20 + (m * 7 + (y % 100) * 3) % 40, 5, 3
from generate_series(2023, extract(year from current_date)::int) y cross join generate_series(1, 12) m
where make_date(y, m, 15) <= current_date;
