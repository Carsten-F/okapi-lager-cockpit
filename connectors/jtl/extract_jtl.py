#!/usr/bin/env python3
"""JTL-Extraktion: liest lesend aus der JTL-Wawi-Datenbank (MS SQL Server) und haelt Zieltabellen aktuell.

Ziele (getrennt, DSGVO):
  main  Hauptdatenbank, Schema jtl     Artikel, Lagerbestand, Belege (nur Kundennummer)
  pii   Datenbank okapi_kunden         Name, Adresse, E-Mail, Telefon (Schema kunden)

Aufruf:   extract_jtl.py --env /etc/lager-cockpit/jtl.env [--entities articles,stock,customers,documents,document_items]
                         [--days 7 | --since JJJJ-MM-TT] [--source mssql | --source csv:ORDNER] [--dry-run] [--allow-draft]
Technik:  Nur Python-Standardbibliothek plus pymssql (nur fuer --source mssql). Geschrieben wird ueber psql
          (PSQL_MAIN / PSQL_PII aus der env-Datei, z. B. "docker exec -i supabase-db psql -U postgres -d postgres").
          Jede Entitaet laeuft in einer Transaktion (Staging-Tabelle, COPY, Upsert). Jeder Lauf ist wiederholbar.
Sicherheit: Zugangsdaten nur in der env-Datei (Modus 600). In Logs stehen nie Zeilen, nur Zaehler.
"""
import argparse, csv, datetime as dt, io, os, shlex, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))

# name: Entitaet; db: Ziel; mode: full (alles), window (Belege ab --since/--days), snapshot (Stand von heute);
# prune: in der Quelle geloeschte Zeilen auch im Ziel loeschen (DSGVO-Loeschung aus JTL wirkt hier mit)
ENTITIES = [
    dict(name='articles', db='main', table='jtl.articles', mode='full',
         key=['sku'], cols=['sku', 'name', 'ean', 'is_active', 'price_net', 'cost_net', 'created_on'],
         types=dict(is_active='bool', price_net='num', cost_net='num', created_on='date')),
    dict(name='stock', db='main', table='jtl.stock_snapshot', mode='snapshot',
         key=['snapshot_date', 'sku', 'warehouse'], cols=['snapshot_date', 'sku', 'warehouse', 'qty_total', 'qty_available'],
         types=dict(snapshot_date='date', qty_total='num', qty_available='num')),
    dict(name='customers', db='pii', table='kunden.customers', mode='full', prune=True,
         key=['customer_no'], cols=['customer_no', 'company', 'first_name', 'last_name', 'email', 'phone', 'street', 'zip',
                                    'city', 'country', 'customer_group', 'created_on', 'newsletter_optin'],
         types=dict(created_on='date', newsletter_optin='bool')),
    dict(name='documents', db='main', table='jtl.documents', mode='window',
         key=['doc_no'], cols=['doc_no', 'doc_type', 'doc_date', 'order_no', 'customer_no', 'customer_group', 'country',
                               'currency', 'net_total', 'gross_total'],
         types=dict(doc_date='date', net_total='num', gross_total='num')),
    dict(name='document_items', db='main', table='jtl.document_items', mode='window',
         key=['doc_no', 'line_no'], cols=['doc_no', 'line_no', 'sku', 'product_name', 'qty', 'unit_price_net', 'discount_pct',
                                          'line_net', 'tax_rate'],
         types=dict(line_no='int', qty='num', unit_price_net='num', discount_pct='num', line_net='num', tax_rate='num')),
]
DEFAULT_ORDER = ['articles', 'stock', 'customers', 'documents', 'document_items']


def log(msg):
    print(f"{dt.datetime.now():%F %T} {msg}", flush=True)


def load_env(path):
    env = dict(os.environ)
    if path:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env


# ---- Quellen -----------------------------------------------------------------------------------------------------
def read_mssql(env, ent, since, allow_draft):
    sql_path = os.path.join(HERE, 'queries', ent['name'] + '.sql')
    sql = open(sql_path, encoding='utf-8').read()
    if '-- ENTWURF' in sql and not allow_draft:
        raise SystemExit(f"Abfrage {ent['name']}.sql ist noch ein ENTWURF (nach der Schema-Pruefung freigeben "
                         f"oder --allow-draft verwenden).")
    import pymssql   # erst hier: Tests mit --source csv brauchen es nicht
    conn = pymssql.connect(server=env['JTL_HOST'], port=int(env.get('JTL_PORT', '1433')), user=env['JTL_USER'],
                           password=env['JTL_PASSWORD'], database=env.get('JTL_DB', 'eazybusiness'),
                           login_timeout=30, timeout=int(env.get('JTL_QUERY_TIMEOUT', '600')), as_dict=True,
                           tds_version=env.get('JTL_TDS_VERSION', '7.4'))
    try:
        cur = conn.cursor()
        cur.execute(sql, {'since': since})
        while True:
            batch = cur.fetchmany(5000)
            if not batch:
                break
            yield from batch
    finally:
        conn.close()


def read_csv(folder, ent):
    path = os.path.join(folder, ent['name'] + '.csv')
    with open(path, newline='', encoding='utf-8-sig') as f:
        yield from csv.DictReader(f)


# ---- Normalisierung -----------------------------------------------------------------------------------------------
def norm(v, typ):
    if v is None:
        return None
    if typ == 'date':
        if hasattr(v, 'isoformat'):
            return v.isoformat()[:10]
        s = str(v).strip()[:10]
        return s or None
    if typ == 'bool':
        if isinstance(v, bool):
            return v
        return str(v).strip().lower() in ('1', 'y', 'j', 'ja', 'true', 't', 'yes')
    if typ in ('num', 'int'):
        s = str(v).strip().replace(',', '.') if not isinstance(v, (int, float)) and ',' in str(v) else v
        if s == '' or s is None:
            return None
        return int(float(s)) if typ == 'int' else float(s)
    s = str(v).strip()
    return s or None


def prepare(ent, rows, snapshot_date):
    """Gibt (zeilen, uebersprungen) zurueck; Zeilen ohne Schluessel werden uebersprungen."""
    out, skipped = [], 0
    seen = set()
    for r in rows:
        rec = {}
        for c in ent['cols']:
            if c == 'snapshot_date' and ent['mode'] == 'snapshot':
                rec[c] = snapshot_date
            else:
                rec[c] = norm(r.get(c), ent['types'].get(c, 'text'))
        if any(rec[k] is None for k in ent['key']):
            skipped += 1
            continue
        k = tuple(rec[k_] for k_ in ent['key'])
        if k in seen:                      # doppelte Schluessel in der Quelle: der letzte gewinnt nicht, der erste bleibt
            skipped += 1
            continue
        seen.add(k)
        out.append(rec)
    return out, skipped


# ---- Ziel ---------------------------------------------------------------------------------------------------------
def build_script(ent, rows):
    cols, key, table = ent['cols'], ent['key'], ent['table']
    collist = ', '.join(cols)
    nonkey = [c for c in cols if c not in key]
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator='\n')
    for rec in rows:
        w.writerow(['\\N' if rec[c] is None else ('t' if rec[c] is True else 'f' if rec[c] is False else rec[c]) for c in cols])
    s = ['\\set ON_ERROR_STOP on', 'begin;',
         f'create temp table _stg (like {table} including defaults) on commit drop;',
         f"copy _stg ({collist}) from stdin with (format csv, null '\\N');", buf.getvalue() + '\\.']
    if nonkey:
        sets = ', '.join(f'{c} = excluded.{c}' for c in nonkey)
        diff = ' or '.join(f'{table}.{c} is distinct from excluded.{c}' for c in nonkey)
        s.append(f"insert into {table} ({collist}) select {collist} from _stg on conflict ({', '.join(key)}) "
                 f"do update set {sets}, loaded_at = now() where {diff};")
    else:
        s.append(f"insert into {table} ({collist}) select {collist} from _stg on conflict do nothing;")
    if ent.get('prune'):
        k = key[0]
        s.append(f"""do $$ declare s bigint; t bigint; begin
  select count(*) into s from _stg; select count(*) into t from {table};
  if t > 100 and s < t * 0.5 then
    raise exception 'Abgleich abgebrochen: Quelle liefert % Zeilen, Ziel hat % (weniger als 50 Prozent)', s, t;
  end if;
end $$;
delete from {table} x where not exists (select 1 from _stg where _stg.{k} = x.{k});""")
    s.append('commit;')
    return '\n'.join(s) + '\n'


def run_psql(cmd, script):
    p = subprocess.run(shlex.split(cmd) + ['-X', '-q', '-v', 'ON_ERROR_STOP=1'], input=script.encode('utf-8'),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        # Fehlertext der Datenbank enthaelt gelegentlich Zeilenwerte: auf die erste Zeile kuerzen
        err = p.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise RuntimeError(err[0][:300] if err else f'psql Exitcode {p.returncode}')
    return p.stdout.decode('utf-8', 'replace')


def q(v):
    return "'" + str(v).replace("'", "''") + "'"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--env')
    ap.add_argument('--entities', default=','.join(DEFAULT_ORDER))
    ap.add_argument('--days', type=int, default=7, help='Belege der letzten N Tage neu laden (Standard 7)')
    ap.add_argument('--since', help='Belege ab diesem Datum (JJJJ-MM-TT), ueberschreibt --days; fuer die Erstladung')
    ap.add_argument('--source', default='mssql', help='mssql oder csv:ORDNER (Tests)')
    ap.add_argument('--dry-run', action='store_true', help='nur lesen und zaehlen, nichts schreiben')
    ap.add_argument('--allow-draft', action='store_true')
    ap.add_argument('--no-refresh', action='store_true', help='lager.sales_daily nicht aus den Belegen neu aufbauen')
    a = ap.parse_args()
    env = load_env(a.env)
    today = dt.date.today().isoformat()
    since = a.since or (dt.date.today() - dt.timedelta(days=a.days)).isoformat()
    wanted = [e.strip() for e in a.entities.split(',') if e.strip()]
    by_name = {e['name']: e for e in ENTITIES}
    unknown = [w for w in wanted if w not in by_name]
    if unknown:
        sys.exit('Unbekannte Entitaet: ' + ', '.join(unknown))
    psql = {'main': env.get('PSQL_MAIN'), 'pii': env.get('PSQL_PII')}
    failed = []
    loaded = set()
    for name in wanted:
        ent = by_name[name]
        t0 = dt.datetime.now()
        run_id = None
        try:
            if not a.dry_run:
                if not psql.get(ent['db']):
                    raise RuntimeError(f"PSQL_{ent['db'].upper()} fehlt in der env-Datei")
                out = run_psql(psql['main'], f"insert into jtl.import_runs (entity) values ({q(name)}) returning id;\n")
                run_id = next((l.strip() for l in out.splitlines() if l.strip().isdigit()), None)
            if a.source.startswith('csv:'):
                src = read_csv(a.source[4:], ent)
            else:
                src = read_mssql(env, ent, since, a.allow_draft)
            rows, skipped = prepare(ent, src, today)
            if a.dry_run:
                log(f"{name}: {len(rows)} Zeilen gelesen, {skipped} uebersprungen (Trockenlauf, nichts geschrieben)")
                continue
            run_psql(psql[ent['db']], build_script(ent, rows))
            run_psql(psql['main'], f"update jtl.import_runs set finished_at = now(), rows_read = {len(rows)}, "
                                   f"rows_skipped = {skipped}, status = 'ok' where id = {run_id};\n")
            loaded.add(name)
            log(f"{name}: {len(rows)} Zeilen geladen, {skipped} uebersprungen ({(dt.datetime.now() - t0).seconds}s)")
        except (Exception, SystemExit) as e:
            msg = str(e)[:300]
            log(f"FEHLER {name}: {msg}")
            failed.append(name)
            if run_id and psql.get('main'):
                try:
                    run_psql(psql['main'], f"update jtl.import_runs set finished_at = now(), status = 'fehler', "
                                           f"error = {q(msg)} where id = {run_id};\n")
                except Exception:
                    pass
    if not a.dry_run and not a.no_refresh and {'documents', 'document_items'} <= loaded:
        try:
            out = run_psql(psql['main'], f"select lager.refresh_sales_from_jtl({q(since)}::date);\n")
            log('lager.sales_daily aus Belegen aufgebaut ab ' + since)
        except Exception as e:
            log(f'FEHLER Absatz-Aufbau: {e}')
            failed.append('refresh')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
