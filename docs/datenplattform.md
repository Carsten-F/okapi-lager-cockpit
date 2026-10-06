# Datenplattform: JTL als Quelle, getrennte Datenbanken, mehrere Auswertungs-Tools

Ziel: alle Unternehmensdaten innerhalb von supabase.okapi-online.de konsolidieren und je Bereich mit eigenen Tools auswerten
(Lager, CRM, Controlling/Finanzen, Produktmanagement). Personenbezogene Kundendaten liegen getrennt und werden nur gezielt freigegeben.

## Aufbau

```
JTL-Wawi (ecomDATA, nur lesen)
        │  connectors/jtl/extract_jtl.py   (Cron 06:40, nach Magento 06:15)
        ├──────────────► Hauptdatenbank "postgres"
        │                  schema jtl      Artikel, Lagerbestand je Tag, Belege + Positionen (nur Kundennummer)
        │                  schema lager    Lager-Cockpit (Prognose, Bestellungen, ...)  ← liest aus jtl
        │                  schema okapi_stock  Magento-Lagerdatenbank (Reservierungen)
        └──────────────► Datenbank "okapi_kunden"   (getrennt, DSGVO)
                           schema kunden    Name, Adresse, E-Mail, Telefon
```

| Bereich | Daten | Wo | Wer darf |
|---|---|---|---|
| Artikel, Lager, Belege, Absatz | keine Personendaten, Belege nur mit `customer_no` | Hauptdatenbank, Schema `jtl` | alle Auswertungs-Tools |
| Kunden (Name, Adresse, E-Mail, Telefon) | personenbezogen | Datenbank `okapi_kunden` | nur Rolle `kunden_reader`, einzeln vergeben (z. B. spätere CRM-Anwendung) |
| Auswertung ohne Personenbezug | Kundennummer, Kundengruppe, Land, Anlagedatum | View `kunden.customers_pseudonym` | Rollen ohne Personenzugriff |

Verknüpfung: `jtl.documents.customer_no` ↔ `kunden.customers.customer_no`. Eine Datenbank kann die andere nicht abfragen. Ein Tool, das
Umsatz **und** Namen braucht (CRM), bekommt zwei getrennte Zugänge, und der Zugriff auf die Kundendatenbank ist damit sichtbar und widerrufbar.

## Was extrahiert wird

| Entität | Ziel | Rhythmus | Hinweis |
|---|---|---|---|
| `articles` | `jtl.articles` | täglich komplett | Artikelnummer, Name, EAN, aktiv, Preis, Einkaufspreis |
| `stock` | `jtl.stock_snapshot` | täglich ein Stand je Artikel und Lager | zählt nur, was die Abfrage `stock.sql` liefert (Lager-Auswahl) |
| `customers` | `okapi_kunden.kunden.customers` | täglich komplett | in JTL gelöschte Kunden werden mitgelöscht (siehe unten) |
| `documents` | `jtl.documents` | letzte 7 Tage neu laden | Rechnung, Gutschrift, Storno; Rechnungsdatum maßgeblich |
| `document_items` | `jtl.document_items` | letzte 7 Tage neu laden | Positionen mit Menge, Preis, Rabatt |

Aus `documents` + `document_items` baut `lager.refresh_sales_from_jtl()` den Tagesabsatz für die Prognose (`lager.sales_daily`),
mit Käufergruppe aus der Kundengruppe, Retouren in `qty_retoure` und alten Artikelnummern über `lager.sku_alias` auf die neuen gelegt.
Ab dem 08.05.2026 kommt der Absatz aus JTL, davor bleibt die Excel-Historie. Die Erstladung der Belege lädt `--since 2021-01-01`.

Später (Phase 2): Aufträge (AU), Lieferantenbestellungen und Wareneingänge aus JTL (ersetzt die manuelle Bestell-Erfassung im Lager-Cockpit),
Zahlungen/offene Posten für Controlling, Artikelstamm mit Kategorien/Hersteller/Stücklisten für das Produktmanagement.

## Datenschutz (DSGVO) – was eingebaut ist und was du noch festlegen musst

Eingebaut:
- **Trennung:** Personendaten nur in `okapi_kunden`, eigene Rolle, für `public` gesperrt. Belege tragen nur die Kundennummer.
- **Datensparsamkeit:** Die Extraktion holt nur die Felder der Abfragen in `connectors/jtl/queries/`. Kreditkarten, Bankdaten, Notizen werden nicht geholt.
- **Löschung wirkt durch:** Löscht JTL einen Kunden (Betroffenenrecht), verschwindet er beim nächsten Lauf auch in `okapi_kunden`. Eine Schutzgrenze
  bricht den Abgleich ab, wenn die Quelle plötzlich weniger als 50 % der bekannten Kunden liefert (Fehler oder leere Antwort), statt alles zu löschen.
- **Keine Personendaten in Logs:** Die Extraktion protokolliert nur Zähler. Fehlermeldungen werden gekürzt.
- **Sicherung getrennt:** `okapi_kunden` wird mit `scripts/backup_kunden.sh` nach `/opt/backups/kunden` gesichert (14 Tage, nur root) und **nicht**
  auf den Windows-Rechner geholt. Die Lager-Sicherung enthält keine Personendaten.
- **Nur lesend an JTL:** Zugangsdaten in `/etc/lager-cockpit/jtl.env` (Modus 600), Lesebenutzer in JTL.

Von dir zu klären (kein Code, sondern Organisation):
- **Auftragsverarbeitung:** ecomDATA ist für JTL bereits Auftragsverarbeiter. Das Verarbeitungsverzeichnis sollte die neue Kopie in Supabase aufnehmen.
- **Speicherdauer:** Wie lange bleiben Kundendaten nach der letzten Bestellung (gesetzlich Aufbewahrung für Rechnungen 8 bzw. 10 Jahre, Marketingnutzung kürzer)?
  Wenn JTL löscht, folgt die Kopie automatisch. Eigene Fristen bräuchten einen Löschjob.
- **Newsletter-Einwilligung:** Für ein CRM mit Mailing muss die Einwilligung mit Datum aus JTL oder dem Shop übernommen werden. Das Feld `newsletter_optin` ist vorgesehen,
  die Abfrage liefert es erst, wenn wir die Quelle kennen.
- **Server:** Beide Datenbanken laufen im selben Datenbank-Container auf server7. Das trennt Rechte, Sicherung und Zugriff, aber nicht den Rechner. Wenn später
  Dritte Zugriff auf das CRM bekommen, ist ein eigener Container oder Server der nächste Schritt.

## Inbetriebnahme (wenn der JTL-Zugang da ist)

1. Discovery: `connectors/jtl/discovery.sql` ausführen lassen und das Ergebnis liefern. Danach passe ich die fünf Abfragen an und gebe sie frei.
2. Auf server7 `/etc/lager-cockpit/jtl.env` aus `config.example.env` anlegen (Modus 600) und `pip3 install pymssql`.
3. `.\scripts\migrate.ps1` (009) und `.\scripts\migrate_kunden.ps1` (Kundendatenbank), dann `.\scripts\deploy_server.ps1`.
4. Trockenlauf: `python3 -I /opt/lager-cockpit/connectors/jtl/extract_jtl.py --env /etc/lager-cockpit/jtl.env --dry-run`.
5. Erstladung der Belege: `... --entities documents,document_items --since 2021-01-01`, dann `install_cron.sh apply`.

Test ohne JTL: `tests/jtl/run.sh` (CSV-Testdaten, 27 Prüfungen: Trennung, Idempotenz, Löschung, Schutzgrenze, Absatz-Aufbau).
