# Connectoren: JTL (Absatz und Lager) und Magento-Verkauf (Planung)

Stand: Anforderungen geklärt, noch nichts gebaut. Offen sind die Zugänge (siehe „Was ich zum Bauen brauche“).

## Geklärt

| Frage | Antwort |
|---|---|
| Wo liegt Magento? | MaxCluster (Hoster) |
| Wo liegt JTL für den OKAPI-Shop? | ecomDATA (gehostetes JTL) |
| Wo steht der Gesamtabsatz und der korrekte Lagerbestand? | JTL |
| Maßgebliches Datum | Rechnungsdatum |
| Stornos und Retouren | werden in JTL erfasst und sollen sichtbar sein |
| Artikelnummern | JTL und Magento sind synchronisiert, SKU = JTL-Artikelnummer |
| `stock_qty` (Magento-Lagerdatenbank) | steigt beim Wareneingang. Die Wareneingangs-Erkennung nutzt seit Migration 008 `stock_qty` |
| Alte Artikelnummern | das neue Format ist das richtige; gibt es kein neues Äquivalent, ist das Produkt vermutlich ausgelaufen |

Folgerung: **JTL ist die Hauptquelle für Absatz und Lagerbestand.** Die Magento-Lagerdatenbank bleibt, weil nur dort
die Reservierungen stehen. Eine eigene Magento-Verkaufsdatenbank ist nur nötig, wenn Shop-Daten fehlen, die JTL nicht hat.

## Ziel

Täglich früh zur gleichen Zeit aktuelle Daten holen und in die Lager-Datenbank schreiben:

| Quelle | Inhalt | Ziel in der Datenbank |
|---|---|---|
| Magento-Lagerdatenbank (besteht) | `stock_qty`, `stock_offset`, `effective_stock` (bestellbar) | `okapi_stock.stock_history` → `lager.stock_daily` |
| JTL (neu) | Absatz je Artikel, Rechnungstag und Käufergruppe, dazu Retouren/Gutschriften/Stornos | `lager.sales_daily` (`source = 'jtl'`, Spalte `qty_retoure`) |
| JTL (neu, Phase 2) | physischer Lagerbestand je Artikel (ggf. je Lager) | neue Tabelle `lager.jtl_stock_daily` |
| Magento-Verkauf (optional) | Webshop-Absatz | `lager.sales_daily` (`source = 'magento'`) |

Der Rechnungsexport (Excel) deckt 2020-12-30 bis 2026-05-07 ab und ist die Historie. Die Connectoren holen ab dem
Folgetag nach (Zeitfenster der letzten 7 Tage jeweils neu laden, damit nichts fehlt und nichts doppelt zählt).

## Architektur

1. **Der Datenabzug ist ein kleines Programm auf server7 (Cron), kein MCP.** Ein MCP-Server beantwortet Fragen, wenn jemand
   fragt. Er schreibt nicht täglich selbständig in unsere Datenbank. Das Tagesgeschäft braucht deshalb einen Cron-Job.
2. **Nur lesender Zugriff** auf die Quellen (eigener Benutzer mit reinen Leserechten), Zugangsdaten in einer Datei nur für
   root (`/etc/lager-cockpit/<name>.env`, Modus 600), nie im Repository oder im Chat.
3. **Idempotent** (Upsert je Artikel und Tag), Laufprotokoll in `lager.import_runs`; das Interface zeigt „Daten veraltet“,
   wenn ein Lauf fehlt.
4. **Datenschutz:** nur Mengen je Artikel und Tag, Käufergruppe und Umsatz. Keine Namen, E-Mail-Adressen, Rechnungsnummern.
5. **Retouren/Stornos** (Gutschriften in JTL) kommen in `qty_retoure`. Die Prognose rechnet mit Absatz minus Retouren, das
   Interface zeigt beides getrennt.

## MCP über AnythingMCP

[AnythingMCP](https://github.com/googio/anythingmcp) (Open Source, AGPL-3.0, selbst gehostet, Docker) macht aus REST-, SOAP-,
GraphQL- oder SQL-Zugängen MCP-Werkzeuge. Das passt gut für **Analysen**: Claude könnte JTL oder Magento direkt abfragen,
ohne dass wir dafür Code schreiben.

- Für den **täglichen Import** reicht es nicht, weil es nichts selbständig schreibt. Der Cron-Job bleibt.
- Der Gateway muss die Quellen erreichen (ecomDATA, MaxCluster). Ob er auf server7 läuft oder woanders, ist egal, solange
  der Zugang mit Lesebenutzer und IP-Freigabe steht. Dieselbe Freigabe braucht auch der Cron-Job.
- Bei GitHub gibt es viele Forks mit ähnlichem Namen. Wir nehmen nur das Hauptrepository, eine feste Version
  (kein `latest`), und prüfen vor dem Betrieb Lizenz und Abhängigkeiten.
- Zugriff nur über Datenbankbenutzer mit SELECT-Recht, damit über MCP nichts verändert werden kann.

Empfehlung: erst den Cron-Import bauen (liefert der Prognose die Daten), AnythingMCP danach als Analysezugang obendrauf.

## Was ich zum Bauen brauche

**JTL bei ecomDATA** (Hauptquelle)
- Welchen Zugang bietet ecomDATA an? Üblich sind: (a) lesender SQL-Zugang zur Datenbank `eazybusiness` mit Freigabe der
  Server-IP von server7, (b) die JTL-Wawi-REST-API, (c) ein geplanter Export (CSV/SQL-Abfrage) auf einen Ort, den server7 holen kann.
  Bitte bei ecomDATA anfragen; was davon möglich ist, entscheidet den Bau.
- Welche Lager zählen für den Lagerbestand (Hauptlager, Zugang, Sperrlager)?
- Rechnungsarten: Gibt es eigene Belegarten für Gutschrift/Storno/Retoure (im Export: `REK…`, `RET…`)?
- Käufergruppe: Kommt sie wie im Excel (`BuyerType`) aus dem Kunden oder der Kundengruppe?

**Magento-Verkauf bei MaxCluster** (nur wenn nötig)
- Datenbanktyp, Host, Port und Freigabe für server7.

Passwörter bitte nie in den Chat. Ich gebe dir die Datei vor, die du auf dem Server selbst ausfüllst.

## Artikelnummern aus der Vergangenheit

Die Zuordnung alt → neu steckt in `tools/aggregate_sales.py` und in `lager.sku_alias`:

1. Regel: vierstellige Altnummer `n` → `1100000 + n`, wenn es diese Nummer im Export gibt (z. B. `1001` → `1101001`).
   Das trifft auf rund 280 Artikel zu.
2. Sonst: gleicher Produktname, wenn er genau einen neuen Artikel trifft (z. B. Leinsamenriegel `1445` → `1104292`).
3. Ohne Treffer: kein Nachfolger. Diese Artikel gelten als ausgelaufen und stehen in `sku_ohne_nachfolger.csv`.
4. Korrekturen per CSV (`old_sku,new_sku`) mit `--alias`.

Die Namen unterscheiden sich teilweise („OKAPI Synofit 150g“ → „OKAPI Synofit - 150g“), daher gilt die Nummernregel zuerst
und der Name nur als Reserve.
