#!/usr/bin/env python3
"""Verdichtet den Rechnungsexport (Orders_Full_Report_*.xlsx oder .csv) zu Tagesabsatz je Artikel.

Datenschutz: Kundenname, E-Mail, Rechnungs- und Auftragsnummern werden NICHT uebernommen. Ausgegeben wird nur,
was die Prognose braucht: Menge je Artikel, Bestelltag und Kaeufergruppe.

Aufruf:  python aggregate_sales.py EXPORT.xlsx|EXPORT.csv AUSGABEORDNER [--von 2026-05-08] [--sql] [--alias alias.csv]
Ausgabe: sales_import.sql (mit --sql; wiederholbar einspielbar, siehe scripts/import_sales.ps1)
         sales_daily.csv  (sku, date, qty_endkunde, qty_therapeut, qty_haendler, qty_mitarbeiter, qty_sonstige,
                           lines, revenue_net)
         sku_info.csv     (sku, product_name, company, first_sale, last_sale, total_qty)
         sku_alias.csv    (old_sku, new_sku, method, old_name, new_name): alte -> aktuelle Artikelnummer. Der Absatz alter
                          Nummern wird unter der neuen gefuehrt. Regel: 4-stellig n -> 1100000+n, wenn es diese Nummer im
                          Export gibt; sonst gleicher Produktname (eindeutig). --alias ergaenzt/ueberschreibt per CSV.
         sku_ohne_nachfolger.csv  Altnummern ohne neues Aequivalent (vermutlich ausgelaufen)
Die xlsx-Variante braucht openpyxl (pip install openpyxl); csv nicht.
"""
import csv, sys, os, argparse, re
from collections import defaultdict
from datetime import datetime

GROUPS = {'endkunde': 'qty_endkunde', 'therapeut': 'qty_therapeut', 'haendler': 'qty_haendler',
          'mitarbeiter': 'qty_mitarbeiter'}

def buyer_group(t):
    t = (t or '').strip().lower().replace('ä', 'ae')
    if t.startswith('endkunde'): return 'qty_endkunde'
    if t.startswith('therapeut'): return 'qty_therapeut'
    if t.startswith('haendler'): return 'qty_haendler'
    if t.startswith('mitarbeiter'): return 'qty_mitarbeiter'
    return 'qty_sonstige'

def to_date(v):
    if v is None or v == '': return None
    if hasattr(v, 'isoformat'): return v.isoformat()[:10]
    s = str(v).strip()[:10]
    for fmt in ('%Y-%m-%d', '%d.%m.%Y'):
        try: return datetime.strptime(s, fmt).date().isoformat()
        except ValueError: pass
    return None

def to_num(v):
    if v is None or v == '': return 0.0
    if isinstance(v, (int, float)): return float(v)
    return float(str(v).strip().replace('.', '').replace(',', '.')) if ',' in str(v) else float(str(v))

def rows(path):
    if path.lower().endswith('.csv'):
        with open(path, newline='', encoding='utf-8-sig') as f:
            sample = f.read(4096); f.seek(0)
            delim = ';' if sample.count(';') > sample.count(',') else ','
            yield from csv.DictReader(f, delimiter=delim)
    else:
        import openpyxl
        ws = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]
        it = ws.iter_rows(values_only=True)
        head = [str(h) for h in next(it)]
        for r in it: yield dict(zip(head, r))

def q(v):
    return "'" + str(v).replace("'", "''") + "'"

def write_sql(out, daily, info, cols, alias, batch=500):
    """Upserts in Bloecken; wiederholbar. Gesamtmenge je Artikel wird am Ende aus sales_daily neu berechnet."""
    with open(os.path.join(out, 'sales_import.sql'), 'w', encoding='utf-8') as f:
        f.write('-- Absatzimport (erzeugt von tools/aggregate_sales.py). Wiederholbar: vorhandene Tage werden ueberschrieben.\n')
        f.write('begin;\nset local statement_timeout = 0;\n')
        if alias:
            olds = sorted(alias)
            f.write('insert into lager.sku_alias (old_sku,new_sku,method) values\n'
                    + ',\n'.join('(%s,%s,%s)' % (q(o), q(alias[o][0]), q(alias[o][1])) for o in olds)
                    + '\non conflict (old_sku) do update set new_sku=excluded.new_sku, method=excluded.method;\n')
            f.write('delete from lager.sales_daily where sku in (select old_sku from lager.sku_alias);\n')
            f.write('delete from lager.sku_catalog where sku in (select old_sku from lager.sku_alias);\n')
        keys = sorted(daily)
        for i in range(0, len(keys), batch):
            vals = []
            for (sku, d) in keys[i:i + batch]:
                g = daily[(sku, d)]
                vals.append('(%s,%s,%s,%d,%s,%s)' % (q(sku), q(d), ','.join(repr(round(g.get(c, 0), 3)) for c in cols), int(g['lines']), repr(round(g.get('revenue_net', 0), 2)), q('excel')))
            f.write('insert into lager.sales_daily (sku,date,qty_endkunde,qty_therapeut,qty_haendler,qty_mitarbeiter,qty_sonstige,lines,revenue_net,source) values\n'
                    + ',\n'.join(vals) + '\non conflict (sku,date) do update set qty_endkunde=excluded.qty_endkunde, qty_therapeut=excluded.qty_therapeut, '
                    'qty_haendler=excluded.qty_haendler, qty_mitarbeiter=excluded.qty_mitarbeiter, qty_sonstige=excluded.qty_sonstige, '
                    'lines=excluded.lines, revenue_net=excluded.revenue_net, source=excluded.source;\n')
        skus = sorted(info)
        for i in range(0, len(skus), batch):
            vals = ['(%s,%s,%s,%s,%s)' % (q(s_), q(info[s_]['name']), q(info[s_]['company']), q(info[s_]['first']), q(info[s_]['last'])) for s_ in skus[i:i + batch]]
            f.write('insert into lager.sku_catalog (sku,product_name,company,first_sale,last_sale) values\n' + ',\n'.join(vals)
                    + '\non conflict (sku) do update set product_name=excluded.product_name, company=excluded.company, '
                    'first_sale=least(lager.sku_catalog.first_sale, excluded.first_sale), last_sale=greatest(lager.sku_catalog.last_sale, excluded.last_sale);\n')
        f.write('update lager.sku_catalog c set total_qty = coalesce((select sum(s.qty_endkunde+s.qty_therapeut+s.qty_haendler+s.qty_mitarbeiter+s.qty_sonstige) '
                'from lager.sales_daily s where s.sku = c.sku), 0);\n')
        f.write("select count(*) as tageswerte, min(date) as von, max(date) as bis, count(distinct sku) as artikel from lager.sales_daily;\n")
        f.write('commit;\n')

def build_alias(data, alias_file=None):
    """Alte -> aktuelle Artikelnummer. Rueckgabe: ({alt: (neu, methode, alter_name, neuer_name)}, [Altnummern ohne Nachfolger])"""
    names = {}; last = {}; qty = defaultdict(float)
    for sku, d, q, _g, _r, name, _c in data:
        if d >= last.get(sku, ''): last[sku] = d; names[sku] = name
        qty[sku] += q
    new7 = [s_ for s_ in names if re.fullmatch(r'\d{7}', s_)]
    by_name = defaultdict(list)
    for s_ in new7: by_name[norm_name(names[s_])].append(s_)
    alias = {}; orphans = []
    for old in sorted(s_ for s_ in names if re.fullmatch(r'\d{4}', s_)):
        tgt = str(1100000 + int(old))
        if tgt in names: alias[old] = (tgt, 'regel', names[old], names[tgt]); continue
        c = by_name.get(norm_name(names[old]), [])
        if len(c) == 1: alias[old] = (c[0], 'name', names[old], names[c[0]]); continue
        orphans.append((old, names[old], last[old], round(qty[old], 3)))
    if alias_file:
        with open(alias_file, newline='', encoding='utf-8-sig') as f:
            sample = f.read(2048); f.seek(0)
            for r in csv.DictReader(f, delimiter=';' if sample.count(';') > sample.count(',') else ','):
                o, n_ = (r.get('old_sku') or '').strip(), (r.get('new_sku') or '').strip()
                if o and n_ and o != n_: alias[o] = (n_, 'manuell', names.get(o, ''), names.get(n_, ''))
        orphans = [x for x in orphans if x[0] not in alias]
    return alias, orphans

def norm_name(t):
    return re.sub(r'[^a-z0-9]+', ' ', (t or '').lower().replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue').replace('ß', 'ss')).strip()

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('src'); ap.add_argument('out')
    ap.add_argument('--von', help='nur Bestelltage ab diesem Datum (JJJJ-MM-TT)')
    ap.add_argument('--alias', help='CSV old_sku,new_sku: bestaetigte/korrigierte Zuordnungen (haben Vorrang)')
    ap.add_argument('--sql', action='store_true', help='zusaetzlich sales_import.sql (Upserts) erzeugen')
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    ap_alias = a.alias
    data = []; n = skipped = bad_sku = 0
    SKU_OK = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$')
    for r in rows(a.src):
        n += 1
        sku = str(r.get('SKU') or '').strip()
        d = to_date(r.get('OrderDate')) or to_date(r.get('InvoiceDate'))
        try: q = to_num(r.get('Quantity'))
        except ValueError: q = 0
        if not sku or not d or q <= 0 or (a.von and d < a.von): skipped += 1; continue
        if not SKU_OK.match(sku): bad_sku += 1; continue   # Tippfehler/Sonderzeichen (z. B. "," oder "0,00")
        try: rev = to_num(r.get('LineTotal_Net'))
        except ValueError: rev = 0.0
        data.append((sku, d, q, buyer_group(r.get('BuyerType')), rev, (r.get('ProductName') or '').strip(),
                     (r.get('CompanyFirm') or '').strip()))
    alias, orphans = build_alias(data, ap_alias)
    daily = defaultdict(lambda: defaultdict(float)); info = {}
    for sku0, d, q, grp, rev, name, comp in data:
        sku = alias[sku0][0] if sku0 in alias else sku0
        k = (sku, d); g = daily[k]
        g[grp] += q; g['lines'] += 1; g['revenue_net'] += rev
        i = info.setdefault(sku, {'name': '', 'company': '', 'first': d, 'last': '', 'qty': 0.0, 'own': ''})
        i['qty'] += q; i['first'] = min(i['first'], d); i['last'] = max(i['last'], d)
        # Name/Firma: bevorzugt die juengste Zeile unter der aktuellen Nummer selbst, sonst die der Altnummer
        if sku0 == sku and d >= i['own']: i['own'] = d; i['name'] = name; i['company'] = comp
        elif not i['name']: i['name'] = name; i['company'] = comp
    cols = ['qty_endkunde', 'qty_therapeut', 'qty_haendler', 'qty_mitarbeiter', 'qty_sonstige']
    with open(os.path.join(a.out, 'sales_daily.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['sku', 'date'] + cols + ['lines', 'revenue_net'])
        for (sku, d) in sorted(daily):
            g = daily[(sku, d)]
            w.writerow([sku, d] + [round(g.get(c, 0), 3) for c in cols] + [int(g['lines']), round(g.get('revenue_net', 0), 2)])
    with open(os.path.join(a.out, 'sku_info.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['sku', 'product_name', 'company', 'first_sale', 'last_sale', 'total_qty'])
        for sku in sorted(info):
            i = info[sku]; w.writerow([sku, i['name'], i['company'], i['first'], i['last'], round(i['qty'], 3)])
    with open(os.path.join(a.out, 'sku_alias.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['old_sku', 'new_sku', 'method', 'old_name', 'new_name'])
        for o in sorted(alias):
            w.writerow([o, alias[o][0], alias[o][1], alias[o][2], alias[o][3]])
    with open(os.path.join(a.out, 'sku_ohne_nachfolger.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(['old_sku', 'product_name', 'last_sale', 'total_qty'])
        for o in orphans: w.writerow(o)
    if a.sql: write_sql(a.out, daily, info, cols, alias)
    print(f'{n} Zeilen gelesen, {skipped} uebersprungen (Menge <= 0, ohne SKU/Datum oder vor --von), '
          f'{bad_sku} wegen ungueltiger Artikelnummer ignoriert; {len(daily)} Tageswerte, {len(info)} Artikel -> {a.out}')
    print(f'Artikelnummern zugeordnet (alt -> neu): {len(alias)}, ohne Nachfolger (vermutlich ausgelaufen): {len(orphans)}')

if __name__ == '__main__':
    main()
