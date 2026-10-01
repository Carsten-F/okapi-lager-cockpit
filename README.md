# OKAPI Lager-Cockpit

Weboberfläche mit Login für Lagerverwaltung, Reichweitenprognose und Einkaufsoptimierung auf
der selbstgehosteten Supabase-Instanz `https://supabase.okapi-online.de`.

## Datenfluss

```
Magento --(täglicher Import)--> okapi_stock.stock_history   Quelle, wird nie verändert
                                     |  lager.sync_from_magento()
                                     v
                                lager.stock_daily           Arbeitskopie
Eingaben im Interface: lager.purchase_orders, lager.sku_notes, lager.sku_settings
(überschreiben die Kopie nie; Korrekturen werden in der Prognose herausgerechnet)
```

Bestandsgrößen: `effective_stock` = physischer Bestand (Grundlage der Prognose),
`bestellbar` = `stock_qty − stock_offset` (nur Anzeige).

## Sicherheit

- Tabellen im nicht exponierten Schema `lager`, RLS mit Verweigerungs-Policy, keine Grants.
- Zugriff nur über `SECURITY DEFINER`-Funktionen `okapi_stock.lager_*` (nur `authenticated`,
  zusätzlich rollengeprüft über `lager.user_roles`). `okapi_stock` ist bereits in
  `PGRST_DB_SCHEMAS` – die Instanzkonfiguration bleibt unverändert.
- Frontend: statische Dateien, Supabase Auth, nur `ANON_KEY`. Nie den `SERVICE_ROLE_KEY`
  einbetten. Die Seite lädt keine Skripte von fremden Servern (Client-Bibliothek liegt in
  `web/js/vendor`), dazu strenge Content-Security-Policy (`deploy/apache-lager.conf.example`).
- Die Auth-Nutzer sind für alle Projekte auf der Instanz gemeinsam. Zugang gewährt
  ausschließlich ein Eintrag in `lager.user_roles`.
- Seite und Studio liegen auf derselben Adresse und teilen sich damit den Browser-Speicher.
  Der Login-Schlüssel dieser Seite heißt `okapi-lager-auth`.

## Rollen

| Rolle | darf |
|---|---|
| `viewer` | alles lesen |
| `lager` | + Wareneingang buchen, Inventurkorrekturen, Kommentare |
| `einkauf` | + Bestellungen anlegen/ändern, Artikel-Einstellungen |
| `admin` | + Datenabgleich auslösen |

## Migrationen (Reihenfolge, alle wiederholbar)

| Datei | Inhalt |
|---|---|
| `001_lager_schema.sql` | Schema, Tabellen, RLS, API-Funktionen, Erstbefüllung der Kopie |
| `003_order_eta_required.sql` | Bestellung braucht Liefertermin oder Zeitspanne |
| `004_empty_stock.sql` | Bestand 0 gilt als kritisch / ausverkauft |
| `002_assign_role.sql.example` | Vorlage: Nutzer eine Rolle geben (kein Teil der Migrationen) |
| `001_lager_schema_rollback.sql` | macht 001 rückgängig (löscht die Daten in `lager`) |
| `verify.sql` | Prüfung, nur lesend |

Einspielen (Windows PowerShell, im Repo-Ordner; vorher `git pull`):

```powershell
ssh root@server7.centaurus.info "mkdir -p /opt/migrations-lager"
scp migrations\003_order_eta_required.sql migrations\004_empty_stock.sql root@server7.centaurus.info:/opt/migrations-lager/
ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/003_order_eta_required.sql"
ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/004_empty_stock.sql"
```

Erstinstallation: zusätzlich `001_lager_schema.sql` vorher auf dieselbe Weise.

## Nutzer und Rollen verwalten

1. **Nutzer anlegen:** Studio unter `https://supabase.okapi-online.de/` öffnen (Basic-Auth mit
   `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` aus `/opt/supabase-project/.env`), dann
   Authentication → Users → Add user → Create new user, E-Mail und Passwort, „Auto Confirm User“.
2. **Rolle zuweisen:** Studio → SQL Editor, Vorlage `migrations/002_assign_role.sql.example`
   einfügen, E-Mail, Rolle und Namen eintragen, ausführen. Das letzte `select` zeigt alle
   freigeschalteten Nutzer.
3. Ohne Eintrag in `lager.user_roles` sieht ein angemeldeter Nutzer nur „Kein Zugang“.

## Web-Interface

Dateien in `web/` (keine Build-Schritte): Übersicht mit Ampelstatus und Reichweite, Detailansicht
mit Verlaufsdiagramm, Bestellungen, Wareneingang, Inventurkorrekturen und Kommentare,
Artikel-Einstellungen; hell/dunkel, mobil nutzbar. `web/js/config.js` enthält die Adresse
(`window.location.origin`) und den öffentlichen `ANON_KEY`.

Hochladen (PowerShell im Repo-Ordner): `.\scripts\deploy_web.ps1` → liegt in
`/opt/lager-cockpit/web` auf dem Server.

Ausliefern über den Apache des Servers: Vorlage `deploy/apache-lager.conf.example`
(`Alias /lager`, `ProxyPass /lager !`, Sicherheits-Header). Der Apache bedient auch die Shops;
deshalb nur `apachectl configtest && systemctl reload apache2`, nie `restart`.
Aufruf danach: `https://supabase.okapi-online.de/lager/`.

## Prognoselogik (v1)

- **Tagesverbrauch** = Summe der Bestandsrückgänge zwischen aufeinanderfolgenden Tagen im
  Fenster (Standard 28 Tage) ÷ Fensterlänge. Zugänge zählen nicht als negativer Verbrauch;
  Inventurkorrekturen werden herausgerechnet.
- **Reichweite** = `effective_stock` ÷ Tagesverbrauch. Bestand 0 gilt als kritisch (ausverkauft).
- **Lieferzeit** = Wert aus den Artikel-Einstellungen, sonst Mittel der letzten 5 eingebuchten
  Bestellungen (Bestelldatum bis Warenzugang), sonst 14 Tage. Puffer Standard 7 Tage.
- **Bestellen bis** = Ausverkaufsdatum − Lieferzeit − Puffer.
- **Offene Bestellungen** (Restmenge) kommen zum erwarteten Liefertermin hinzu
  (`stockout_date_incl_orders`); überfällige zählen ab morgen.
- **Status:** `kritisch` (Reichweite ≤ Lieferzeit, keine rechtzeitige Lieferung),
  `bestellen` (≤ Lieferzeit + Puffer), `bestellt` (offene Bestellung deckt die Lücke),
  `ok`, `kein_verbrauch`. `data_stale` = letzter Bestand älter als 2 Tage.

## API-Funktionen (RPC, Header `Accept-Profile: okapi_stock`, `Content-Profile: okapi_stock`)

| Funktion | Zweck |
|---|---|
| `lager_whoami()` | eigene Rolle (null = nicht freigeschaltet) |
| `lager_stock_latest()` / `lager_stock_series(sku, tage)` | Bestand aktuell / Verlauf |
| `lager_forecast(fenster_tage)` | Reichweite, Ausverkaufsdatum, Bestellen-bis, Status |
| `lager_detected_inflows(tage)` | erkannte Zugänge aus Bestandssprüngen |
| `lager_orders_list(status)` | Bestellungen (`offen`, `alle`, …) |
| `lager_order_add(...)`, `lager_order_update(...)` | Bestellung anlegen/ändern (einkauf, admin) |
| `lager_order_receive(id, datum, menge, kommentar)` | Wareneingang buchen (lager, einkauf, admin) |
| `lager_note_add(sku, art, text, mengenänderung, datum)`, `lager_notes_list(sku, tage)` | Kommentar / Inventurkorrektur |
| `lager_sku_settings_upsert(...)`, `lager_sku_settings_list()` | Lieferzeit, Puffer, Herkunft extern/intern |
| `lager_sync_now()` | Kopie sofort aktualisieren (admin) |

## Tägliche Synchronisation (offen: Zeitpunkt)

Die Arbeitskopie `lager.stock_daily` wird per `lager.sync_from_magento()` aktualisiert. Der Zeitpunkt
hängt vom Magento-Abruf ab und steht noch nicht fest. Bis dahin: im Interface als Admin
„Daten jetzt abgleichen“. Vorlage für Cron (erst nach Festlegung der Uhrzeit, ohne bestehende
Einträge zu überschreiben):

```bash
( crontab -l 2>/dev/null; echo 'CRON_TZ=Europe/Berlin'; echo '0 18 * * * docker exec supabase-db psql -U postgres -d postgres -X -c "select lager.sync_from_magento()" >> /var/log/lager-sync.log 2>&1' ) | crontab -
```

## Backup

`okapi_stock.stock_history` enthält die Tageshistorie und ist aus Magento **nicht nachladbar**
(Magento liefert nur den aktuellen Bestand). Deshalb sichert `scripts/backup_lager.sh` täglich
die Schemas `lager` und `okapi_stock` per `pg_dump` (Custom-Format), prüft den Dump mit
`pg_restore --list`, behält 30 Tage und schreibt nur Dateien `lager_*.dump`.
Platzbedarf: wenige MB pro Jahr.

**Auf dem Server** (einmalig, PowerShell im Repo-Ordner, vorher `git pull`):

```powershell
ssh root@server7.centaurus.info "mkdir -p /opt/lager-cockpit /opt/backups/lager && chmod 700 /opt/backups/lager"
scp scripts\backup_lager.sh root@server7.centaurus.info:/opt/lager-cockpit/
ssh root@server7.centaurus.info "chmod 700 /opt/lager-cockpit/backup_lager.sh && /opt/lager-cockpit/backup_lager.sh"
```

Der Testlauf muss mit `OK:` enden. Dann Cron ergänzen (03:30 Berlin, unabhängig vom Magento-Sync):

```bash
( crontab -l 2>/dev/null; echo 'CRON_TZ=Europe/Berlin'; echo '30 3 * * * /opt/lager-cockpit/backup_lager.sh >> /var/log/lager-backup.log 2>&1' ) | crontab -
```

**Wöchentliche Kopie auf den Windows-Rechner** (SSH-Schlüssel wie bisher; Sonntag 10:00,
verpasste Läufe werden nachgeholt, 26 Wochen Aufbewahrung, Prüfsummenvergleich, Warnung im Log,
falls die Serversicherung älter als 3 Tage ist):

```powershell
cd scripts\windows
.\register_task.ps1
Start-ScheduledTask -TaskName "OKAPI Lager Backup holen"    # Testlauf
Get-Content $env:USERPROFILE\Backups\okapi-lager\pull_backup.log -Tail 5
```

Wiederherstellung (immer in dieselbe Instanz, weil `lager` auf `auth.users` verweist; vorher
Rücksprache, der Befehl ersetzt die Objekte):

```bash
docker exec -i supabase-db pg_restore -U postgres -d postgres --clean --if-exists -n lager -n okapi_stock < /opt/backups/lager/lager_DATUM.dump
```

Die Dumps enthalten Geschäftsdaten; der Windows-Rechner sollte verschlüsselt sein (BitLocker).

## Tests

- **SQL:** `tests/stub.sql` baut die relevanten Teile der Instanz nach, `tests/smoke.sql` prüft
  Rechte, Rollen, Prognose und Sync. Gegen ein leeres Postgres ≥ 15: `stub.sql` → Migrationen
  `001`, `003`, `004` → `smoke.sql`.
- **Browser (E2E):** `tests/e2e` startet einen Mock der Supabase-API vor einer lokalen Datenbank
  (`stub.sql`, Migrationen, `seed.sql`) und prüft die Oberfläche mit Chromium: Login, Rollen,
  Filter, Diagramm, Bestellungen, Wareneingang, Korrekturen, Einstellungen, Konsolenfehler.
  `cd tests/e2e && npm install && node e2e.mjs` (Postgres über `PGHOST`/`PGPORT`, Chromium über
  `CHROMIUM`). Screenshots landen in `tests/e2e/out/`.

## Offen

- Uhrzeit des Magento-Abrufs → Zeitpunkt der Synchronisation.
- Kennzeichnung extern/intern (ONYX) je Artikel: Spalte `sku_settings.supply_source` ist bereit.
- Hosting: Apache-Konfiguration auf dem Server (Vorlage liegt bereit, Datei muss gesichtet werden).
- Selbstregistrierung auf der Instanz abschalten (betrifft die ganze Instanz).
