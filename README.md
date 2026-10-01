# OKAPI Lager-Cockpit

HTML-Interface mit Login für tägliche Lagerauswertung, Reichweitenprognose und
Erfassung erwarteter Bestellungen. Datenquelle: `okapi_stock.stock_history` auf der
selbstgehosteten Supabase-Instanz `https://supabase.okapi-online.de`.

## Architektur

- **Daten:** `okapi_stock.stock_history` (ein Eintrag je SKU und Tag, vom Magento-Sync
  geschrieben). Wird von diesem Projekt nur gelesen.
- **Eigene Tabellen** im nicht exponierten Schema `lager`: `user_roles`, `sku_settings`,
  `expected_orders`. Kein direkter Clientzugriff (RLS mit Verweigerungs-Policy, keine Grants).
- **API:** `SECURITY DEFINER`-Funktionen `okapi_stock.lager_*`, nur für `authenticated`
  ausführbar und zusätzlich über `lager.user_roles` rollengeprüft. Das Schema `okapi_stock`
  ist bereits in `PGRST_DB_SCHEMAS` – dieses Projekt ändert die Instanzkonfiguration nicht.
- **Frontend:** statisches HTML, Supabase Auth (Login), nur `ANON_KEY`. Der
  `SERVICE_ROLE_KEY` kommt nie in den Browser.

Rollen: `viewer` (lesen), `orderer` (+ Bestellungen erfassen), `admin` (+ SKU-Einstellungen).

| Funktion | Rolle |
|---|---|
| `lager_whoami()` | jeder eingeloggte Nutzer |
| `lager_stock_latest()`, `lager_stock_series(sku, tage)`, `lager_forecast(fenster_tage)`, `lager_orders_list(status)` | viewer, orderer, admin |
| `lager_order_add(...)`, `lager_order_set_status(id, status)` | orderer, admin |
| `lager_sku_settings_upsert(...)`, `lager_sku_settings_list()` | admin |

## Prognoselogik (v1)

- Tagesverbrauch = Summe der Bestandsrückgänge zwischen aufeinanderfolgenden Tagen im
  Fenster (Standard 28 Tage) ÷ Fensterlänge. Zugänge zählen nicht als negativer Verbrauch.
- Reichweite = aktueller `effective_stock` ÷ Tagesverbrauch.
- Bestellen bis = Ausverkaufsdatum − Lieferzeit − Sicherheitspuffer (Standard 14 + 7 Tage,
  je SKU in `lager.sku_settings` änderbar).
- Status: `kritisch` (Reichweite ≤ Lieferzeit), `bestellen` (≤ Lieferzeit + Puffer), `ok`,
  `kein_verbrauch`. `data_stale` = letzter Bestand älter als 2 Tage.
- Offene `expected_orders` werden als `incoming_qty` und `days_of_cover_incl_orders`
  berücksichtigt.

## Migration einspielen (Windows PowerShell, im Repo-Ordner)

```powershell
ssh root@server7.centaurus.info "mkdir -p /opt/migrations-lager"
scp migrations\001_lager_schema.sql root@server7.centaurus.info:/opt/migrations-lager/
ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/001_lager_schema.sql"
```

Kontrolle (nur lesend):

```powershell
Get-Content migrations\verify.sql | ssh root@server7.centaurus.info "docker exec -i supabase-db psql -U postgres -d postgres -X"
```

Ersten Admin anlegen: `migrations/002_seed_first_admin.sql.example` kopieren, UUID eintragen,
auf dieselbe Weise ausführen. Rückgängig machen: `migrations/001_lager_schema_rollback.sql`
(löscht die Daten in `lager`).

## Wichtig auf dieser Instanz

- Die Auth-Nutzer sind für alle Projekte auf der Instanz gemeinsam. Zugriff gewährt
  ausschließlich ein Eintrag in `lager.user_roles`.
- `okapi_stock.stock_history` hat Policies und Grants für den Magento-Sync-Nutzer. Diese
  werden nicht angefasst.
- Es gibt aktuell keine Sicherung der Datenbank. Vor Produktivbetrieb klären.
