# OKAPI Lager-Cockpit

Weboberfläche mit Login für Lagerverwaltung, Reichweitenprognose und Einkaufsoptimierung auf
der selbstgehosteten Supabase-Instanz `https://supabase.okapi-online.de`
(Aufruf: `https://supabase.okapi-online.de/lager/`).

## Datenfluss

```
Magento --(täglich 06:15 Uhr)--> okapi_stock.stock_history   Quelle, wird nie verändert
                                     |  lager.sync_from_magento()   (Cron 06:30 und 07:30)
                                     v
                                lager.stock_daily           Arbeitskopie
                                     |  lager.reconcile_receipts()  Wareneingang erkennen
                                     v
        Bestandssprung nach oben -> offene Bestellung wird gebucht und archiviert
Eingaben im Interface: lager.purchase_orders (+ purchase_order_log), lager.sku_notes, lager.sku_settings
(überschreiben die Kopie nie; Korrekturen werden in der Prognose herausgerechnet)
```

Bestandsgrößen (Magento): `effective_stock` = **bestellbarer Bestand** (Grundlage der Prognose), `stock_qty` = Lagerwert,
`stock_offset` = Reservierungen. In der Oberfläche heißen die Spalten „Bestellbar“ und „Lager“. Der physische Bestand kommt
später aus JTL (siehe `docs/connectors.md`).

## Sicherheit

- Tabellen im nicht exponierten Schema `lager`, RLS mit Verweigerungs-Policy, keine Grants.
- Zugriff nur über `SECURITY DEFINER`-Funktionen `okapi_stock.lager_*` (nur `authenticated`,
  zusätzlich rollengeprüft über `lager.user_roles`). `okapi_stock` ist bereits in
  `PGRST_DB_SCHEMAS` – die Instanzkonfiguration bleibt unverändert.
- Frontend: statische Dateien, Supabase Auth, nur `ANON_KEY`. Nie den `SERVICE_ROLE_KEY`
  einbetten. Die Seite lädt keine Skripte von fremden Servern (Client-Bibliothek liegt in
  `web/js/vendor`), dazu strenge Content-Security-Policy (`deploy/apache-lager.snippet.conf`).
- **Keine Selbstregistrierung:** Nutzer legt, ändert und löscht nur der Super-Admin in Studio
  (`scripts/server/disable_signup.sh`). Zugang zum Cockpit gewährt zusätzlich ein Eintrag in
  `lager.user_roles`.
- Seite und Studio liegen auf derselben Adresse und teilen sich damit den Browser-Speicher.
  Der Login-Schlüssel dieser Seite heißt `okapi-lager-auth`.

## Rollen

| Rolle | liest | Wareneingang buchen, Korrekturen, Kommentare | Bestellungen ändern (Termin, Menge, Lieferant, Kommentar) | Bestellungen anlegen, Status, Artikel-Einstellungen | Datenabgleich |
|---|---|---|---|---|---|
| `viewer` | ja | – | – | – | – |
| `lager` | ja | ja | ja (offene Bestellungen) | – | – |
| `einkauf` | ja | ja | ja | ja | – |
| `admin` | ja | ja | ja | ja | ja |

Jede Änderung an einer Bestellung wird protokolliert (wer, wann, alt → neu), im Interface unter
„Verlauf“.

## Wareneingang und Archiv

- **Manuell:** „Eingang buchen“ (Datum, Menge). Teillieferungen möglich.
- **Automatisch:** Steigt der Bestand eines Artikels (Inventurkorrekturen abgezogen), wird der Zugang
  den offenen Bestellungen zugeordnet, älteste erwartete Lieferung zuerst. Ab 90 % der bestellten
  Menge gilt die Bestellung als **eingebucht und wird archiviert**, sonst als teilgeliefert (Rest
  bleibt offen). Zugänge unter 10 % der Restmenge werden nicht zugeordnet. Jeder Zugang wird nur
  einmal verarbeitet. Nur Bestellungen, die vor dem Zugangsdatum erfasst wurden, werden berücksichtigt.
- Automatisch gebuchte Bestellungen sind mit „automatisch erkannt“ markiert und lassen sich
  **zurücksetzen** (z. B. bei einer Rückbuchung).
- **Archiv:** eingebuchte und stornierte Bestellungen. In der Prognose und als „nächste Lieferung“
  zählen nur offene Bestellungen.
- Unter „Bewegungen“ stehen die erkannten Zugänge und ihre zugeordneten Bestellungen.

## Migrationen (Reihenfolge, alle wiederholbar, jeweils in einer Transaktion)

| Datei | Inhalt |
|---|---|
| `001_lager_schema.sql` | Schema, Tabellen, RLS, API-Funktionen, Erstbefüllung der Kopie |
| `003_order_eta_required.sql` | Bestellung braucht Liefertermin oder Zeitspanne |
| `004_empty_stock.sql` | Bestand 0 gilt als kritisch / ausverkauft |
| `005_order_updates_archive.sql` | Lager darf Bestellungen ändern, Verlauf, automatische Wareneingangs-Erkennung, Archiv |
| `006_forecast_rounding_fix.sql` | Korrektur: kein Status „bestellt“ und kein Datum „mit Lieferung“ ohne offene Bestellung (Rundungsfehler) |
| `007_lifecycle_brand_import_sales.sql` | Artikelstatus (aktiv / nicht aktiv Jahreszeit / nicht aktiv Archiv), Marke, CSV-Import der Einstellungen, Absatzhistorie |
| `009_jtl_layer.sql` | Schema `jtl` (Artikel, Lagerbestand, Belege nur mit Kundennummer), Absatz-Aufbau aus JTL. Kundendaten: getrennte Datenbank `migrations/pii/001_kunden_db.sql` |
| `008_receipts_stockqty_alias.sql` | Wareneingangs-Erkennung aus `stock_qty` (Lagerwert) statt bestellbarem Bestand, Tabelle `sku_alias` (alte → neue Artikelnummer), Spalte `qty_retoure` |
| `002_assign_role.sql.example` | Vorlage: Nutzer eine Rolle geben (kein Teil der Migrationen) |
| `001_lager_schema_rollback.sql` | macht 001 rückgängig (löscht die Daten in `lager`) |
| `verify.sql` | Prüfung, nur lesend |

## Einrichtung auf dem Server (Windows PowerShell)

Alle Befehle im **Repo-Ordner** ausführen (`cd $HOME\okapi-lager-cockpit`), nicht im Benutzerordner.
Einmalig vorher (Zeilenenden der Shell-Skripte, die `.gitattributes` verhindert das künftig):

```powershell
cd $HOME\okapi-lager-cockpit
git pull
git rm --cached -r -q . ; git reset --hard -q
```

Dann alles in einem Lauf (Migrationen, Dateien hochladen, Apache eintragen, Abgleich der Kopie, Kontrolle, Trockenlauf
der Registrierung). `-ExecutionPolicy Bypass` gilt nur für diesen Aufruf und umgeht die Windows-Sperre
für unsignierte Skripte:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

Die Einzelschritte (`migrate.ps1`, `deploy_server.ps1`, `apply_apache.sh`) lassen sich auch getrennt
aufrufen. `apply_apache.sh` trägt `/lager` im vHost von supabase.okapi-online.de ein: Sicherung der
Datei, `configtest`, nur bei Erfolg `reload` (kein Neustart; die Shops laufen weiter), bei Fehler wird
das Original zurückgespielt. Wiederholbar.

Kontrolle der Datenbank jederzeit (nur lesend):

```powershell
Get-Content migrations\verify.sql | ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X"
```

### Selbstregistrierung abschalten (gilt für die ganze Instanz)

```powershell
ssh root@server7.centaurus.info "/opt/lager-cockpit/scripts/disable_signup.sh"          # Trockenlauf, ändert nichts
ssh root@server7.centaurus.info "/opt/lager-cockpit/scripts/disable_signup.sh apply"    # setzt DISABLE_SIGNUP=true, startet nur den Auth-Dienst neu
```

### Tägliche Synchronisation und Sicherung (Cron, Serverzeit Berlin)

Der Magento-Abruf läuft täglich um 06:15 Uhr. Abgleich um 06:30 Uhr und ein zweites Mal um 07:30 Uhr
(fängt einen verspäteten Import ab; ein erneuter Lauf ist harmlos), Sicherung danach um 08:00 Uhr.
`install_cron.sh` setzt genau diesen Block, lässt bestehende Einträge unverändert und ist wiederholbar
(Sicherung der alten Crontab unter `/root/crontab.bak.*`):

```powershell
ssh root@server7.centaurus.info "/opt/lager-cockpit/scripts/install_cron.sh"          # Trockenlauf, ändert nichts
ssh root@server7.centaurus.info "/opt/lager-cockpit/scripts/install_cron.sh apply"    # schreibt die Crontab
```

Voraussetzung: Der Testlauf `/opt/lager-cockpit/scripts/backup_lager.sh` endet mit `OK:`.
Kontrolle am Folgetag: `tail -n 3 /var/log/lager-sync.log /var/log/lager-backup.log`.

## Nutzer und Rollen verwalten

1. **Nutzer anlegen:** Studio unter `https://supabase.okapi-online.de/` öffnen (Basic-Auth mit
   `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` aus `/opt/supabase-project/.env`), dann
   Authentication → Users → Add user → Create new user, E-Mail und Passwort, „Auto Confirm User“.
   Ändern und Löschen ebenfalls dort.
2. **Rolle zuweisen:** Studio → SQL Editor, Vorlage `migrations/002_assign_role.sql.example`
   einfügen, E-Mail, Rolle und Namen eintragen, ausführen. Das letzte `select` zeigt alle
   freigeschalteten Nutzer.
3. Ohne Eintrag in `lager.user_roles` sieht ein angemeldeter Nutzer nur „Kein Zugang“.

## Marken und Artikelstatus

- **Marke:** automatisch aus dem Produktnamen (biostickies, KNÄX, OKAPI, Teepferdchen, Happy Belly, sonst „Sonstige“),
  pro Artikel in den Einstellungen oder per CSV änderbar. Die Übersicht lässt sich nach Marke filtern.
- **Artikelstatus:** *Aktiv*, *Nicht aktiv (Jahreszeit)* oder *Nicht aktiv (Archiv)*. Die Übersicht zeigt standardmäßig nur
  aktive Artikel; nicht aktive bleiben in der Datenbank und über den Filter „Artikelstatus“ sichtbar. Die Ampelkacheln
  zählen nur die gewählte Auswahl.

## Massenpflege per CSV (Einstellungen)

„CSV exportieren“ liefert alle Artikel mit den aktuellen Werten (Semikolon, UTF-8, öffnet in Excel). Nach der Bearbeitung
„CSV importieren“: Die Datei wird zuerst geprüft (Vorschau mit Zeilennummern und Fehlern); übernommen wird nur, wenn kein
Fehler besteht (alles oder nichts). Spalten: `Artikelnummer`, `Marke`, `Lebenszyklus` (aktiv / nicht aktiv (Jahreszeit) /
nicht aktiv (Archiv)), `Herkunft` (extern / intern), `Lieferzeit_Tage` (Zahl oder `auto`), `Puffer_Tage`, `Lieferant`, `Notiz`.
Leere Felder lassen den bisherigen Wert unverändert. Nur Einkauf und Admin dürfen importieren.

## Absatzhistorie (aus dem Rechnungsexport)

`tools/aggregate_sales.py` verdichtet den Excel-Export (`Orders_Full_Report_*.xlsx`) zu Tagesabsatz je Artikel und
Käufergruppe. **Kundennamen, E-Mail-Adressen und Rechnungsnummern werden nicht übernommen.** Das Diagramm „Absatz je Monat,
Jahre im Vergleich“ steht in der Detailansicht jedes Artikels. Einspielen (wiederholbar, eine Transaktion):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\import_sales.ps1 -SqlFile "C:\Pfad\sales_import.sql"
```

Alte Artikelnummern werden beim Verdichten auf die aktuelle Nummer umgeschrieben (Details: `docs/connectors.md`, Ausgabe `sku_alias.csv` und `sku_ohne_nachfolger.csv`).

Neue Exporte: `python tools/aggregate_sales.py EXPORT.xlsx AUSGABE --sql [--von JJJJ-MM-TT]` (xlsx braucht `pip install openpyxl`).
Die Anbindung direkt an Magento und JTL ist in `docs/connectors.md` geplant.

## Prognoselogik (v1)

- **Tagesverbrauch** = Summe der Bestandsrückgänge zwischen aufeinanderfolgenden Tagen im
  Fenster (Standard 28 Tage) ÷ Fensterlänge. Zugänge zählen nicht als negativer Verbrauch;
  Inventurkorrekturen werden herausgerechnet.
- **Reichweite** = bestellbarer Bestand (`effective_stock`) ÷ Tagesverbrauch. Bestand 0 gilt als kritisch (ausverkauft).
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
| `lager_detected_inflows(tage)` | erkannte Zugänge mit zugeordneten Bestellungen |
| `lager_orders_list(status)` | Bestellungen (`offen`, `archiv`, `alle`, …) |
| `lager_order_add(...)` | Bestellung anlegen (einkauf, admin) |
| `lager_order_update(...)` | Termin, Menge, Lieferant, Kommentar (lager, einkauf, admin); Status nur einkauf, admin |
| `lager_order_receive(id, datum, menge, kommentar)` | Wareneingang buchen (lager, einkauf, admin) |
| `lager_order_reopen(id, kommentar)` | eingebuchte Bestellung zurücksetzen |
| `lager_order_history(id)` | Verlauf einer Bestellung |
| `lager_note_add(...)`, `lager_notes_list(sku, tage)` | Kommentar / Inventurkorrektur |
| `lager_sku_settings_upsert(...)`, `lager_sku_settings_list()` | Lieferzeit, Puffer, Herkunft extern/intern |
| `lager_sync_now()` | Kopie sofort aktualisieren und Wareneingänge erkennen (admin) |

## Backup

`okapi_stock.stock_history` enthält die Tageshistorie und ist aus Magento **nicht nachladbar**
(Magento liefert nur den aktuellen Bestand). Deshalb sichert `scripts/backup_lager.sh` täglich
die Schemas `lager` und `okapi_stock` per `pg_dump` (Custom-Format), prüft den Dump mit
`pg_restore --list`, behält 30 Tage und schreibt nur Dateien `lager_*.dump`.
Platzbedarf: wenige MB pro Jahr. Testlauf auf dem Server:

```powershell
ssh root@server7.centaurus.info "/opt/lager-cockpit/scripts/backup_lager.sh"
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
  Rechte, Rollen, Prognose, Sync, Bestelländerungen und automatische Wareneingangs-Erkennung.
  Gegen ein leeres Postgres ≥ 15: `stub.sql` → Migrationen `001`, `003`, `004`, `005`, `006` → `smoke.sql`.
- **Browser (E2E):** `tests/e2e` startet einen Mock der Supabase-API vor einer lokalen Datenbank
  (`stub.sql`, Migrationen, `seed.sql`) und prüft die Oberfläche mit Chromium (Login, Rollen, Filter,
  Diagramm, Bestellungen, Wareneingang, Archiv, automatische Zuordnung, Zurücksetzen, Verlauf,
  Korrekturen, Einstellungen, Konsolenfehler). `cd tests/e2e && npm install && node e2e.mjs`
  (Postgres über `PGHOST`/`PGPORT`, Chromium über `CHROMIUM`). Screenshots: `tests/e2e/out/`.
- Die Skripte `deploy/apply_apache.sh` und `scripts/server/disable_signup.sh` wurden gegen
  nachgebaute Konfigurationen getestet (Einfügen, Wiederholung, Rollback).

## Offen

- Kennzeichnung extern/intern (ONYX) je Artikel: Spalte `sku_settings.supply_source` ist bereit.
- Eine zweite Sicherungskopie außerhalb des Servers ist über die Windows-Aufgabe vorgesehen.

## JTL-Anbindung und Datenplattform

Siehe `docs/datenplattform.md` (Architektur, DSGVO, Inbetriebnahme), `docs/connectors.md` (Anforderungen), `connectors/jtl/` (Extraktion, Discovery-Skript) und `tests/jtl/run.sh`.
