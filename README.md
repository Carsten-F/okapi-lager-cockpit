# OKAPI Lager-Cockpit

HTML-Interface mit Login für Lagerverwaltung, Reichweitenprognose und Einkaufsoptimierung
auf der selbstgehosteten Supabase-Instanz `https://supabase.okapi-online.de`.

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
- Frontend: statisches HTML, Supabase Auth, nur `ANON_KEY`. Nie den `SERVICE_ROLE_KEY` einbetten.
- Die Auth-Nutzer sind für alle Projekte auf der Instanz gemeinsam. Zugang gewährt
  ausschließlich ein Eintrag in `lager.user_roles`.

## Rollen

| Rolle | darf |
|---|---|
| `viewer` | alles lesen |
| `lager` | + Wareneingang buchen, Inventurkorrekturen, Kommentare |
| `einkauf` | + Bestellungen anlegen/ändern, SKU-Einstellungen |
| `admin` | + Sync auslösen |

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

## Prognoselogik (v1)

- **Tagesverbrauch** = Summe der Bestandsrückgänge zwischen aufeinanderfolgenden Tagen im
  Fenster (Standard 28 Tage) ÷ Fensterlänge. Zugänge zählen nicht als negativer Verbrauch;
  Inventurkorrekturen werden herausgerechnet.
- **Reichweite** = `effective_stock` ÷ Tagesverbrauch.
- **Lieferzeit** = Wert aus `sku_settings`, sonst Mittel der letzten 5 eingebuchten Bestellungen
  (Bestelldatum bis Warenzugang), sonst 14 Tage. Puffer Standard 7 Tage.
- **Bestellen bis** = Ausverkaufsdatum − Lieferzeit − Puffer.
- **Offene Bestellungen** (Restmenge) kommen zum erwarteten Liefertermin hinzu
  (`stockout_date_incl_orders`); überfällige zählen ab morgen.
- **Status:** `kritisch` (Reichweite ≤ Lieferzeit, keine rechtzeitige Lieferung),
  `bestellen` (≤ Lieferzeit + Puffer), `bestellt` (offene Bestellung deckt die Lücke),
  `ok`, `kein_verbrauch`. `data_stale` = letzter Bestand älter als 2 Tage.

## Einspielen (Windows PowerShell)

Einmalig Repo holen (der Ordner `migrations` muss im aktuellen Verzeichnis liegen):

```powershell
cd $HOME
git clone https://github.com/Carsten-F/okapi-lager-cockpit.git
cd okapi-lager-cockpit
git checkout claude/supabase-lagerdaten-interface-vkb4si
```

Bei späteren Änderungen: `git pull`. Dann:

```powershell
ssh root@server7.centaurus.info "mkdir -p /opt/migrations-lager"
scp migrations\001_lager_schema.sql root@server7.centaurus.info:/opt/migrations-lager/
ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/001_lager_schema.sql"
Get-Content migrations\verify.sql | ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X" | Tee-Object $env:TEMP\verify.txt
```

Die Migration ist wiederholbar. Rückgängig machen: `migrations/001_lager_schema_rollback.sql`
(löscht alle Daten in `lager`, nicht `okapi_stock.stock_history`).

### Erster Admin

Nutzer-UUID aus Studio → Authentication → Users kopieren, `002_seed_first_admin.sql.example`
als `002_seed_first_admin.sql` speichern, UUID eintragen, wie oben per `scp` und `psql` ausführen.
Nicht die UUID des Magento-Sync-Nutzers verwenden.

### Tägliche Synchronisation (optional, erst nach Freigabe)

Die Arbeitskopie wird nach dem Magento-Import aktualisiert. Der Import läuft derzeit gegen
ca. 17:35 Uhr Berlin; Cron-Zeile ergänzen, ohne bestehende Einträge zu überschreiben:

```bash
( crontab -l 2>/dev/null; echo 'CRON_TZ=Europe/Berlin'; echo '0 18 * * * docker exec supabase-db psql -U postgres -d postgres -X -c "select lager.sync_from_magento()" >> /var/log/lager-sync.log 2>&1' ) | crontab -
```

Alternativ löst ein Admin den Sync im Interface aus (`lager_sync_now`).

## Tests

`tests/stub.sql` baut die relevanten Teile der Instanz nach, `tests/smoke.sql` prüft Rechte,
Rollen, Prognose und Sync. Lokal gegen ein leeres Postgres ≥ 15 ausführen:
`stub.sql` → `migrations/001_lager_schema.sql` → `tests/smoke.sql`.

## Offen

- Sicherung der Datenbank (auf der Instanz gibt es aktuell keine).
- Kennzeichnung extern/intern (ONYX) je Produkt: Spalte `sku_settings.supply_source` ist bereit.
- Frontend (Login, Tagesauswertung, Prognose, Bestell- und Wareneingangsformulare).
