# Connectoren: Magento-Absatz und JTL-Lager (Planung)

Stand: Entwurf zur Abstimmung. Es ist noch nichts davon gebaut.

## Ziel

Täglich zur gleichen Zeit frühmorgens aktuelle Daten holen und in die Lager-Datenbank schreiben:

| Quelle | Inhalt | Ziel in der Datenbank |
|---|---|---|
| Magento-Lagerdatenbank (besteht bereits) | `stock_qty`, `stock_offset`, `effective_stock` (bestellbar), Reservierungen | `okapi_stock.stock_history` → `lager.stock_daily` |
| Magento-Verkaufsdatenbank (neu, getrennte Datenbank) | Abverkauf je Artikel und Tag (Webshop) | `lager.sales_daily` (`source = 'magento'`) |
| JTL-Wawi (neu) | physischer Lagerbestand je Artikel (ggf. je Lager), später Wareneingänge und Bestellungen | neue Tabelle `lager.jtl_stock_daily` |

Der Rechnungsexport (Excel) deckt 2020-12-30 bis 2026-05-07 ab und ist als Historie eingespielt. Die Connectoren
holen ab dem Folgetag, sodass keine Lücke entsteht.

## Vorgeschlagene Architektur

1. **Jeder Connector ist ein kleines, eigenständiges Programm** (Python) auf server7, das per Cron läuft
   (Serverzeit Berlin, z. B. 06:30 Magento-Absatz, 06:35 JTL; der Magento-Lagerabruf läuft um 06:15).
2. **Nur lesender Zugriff** auf die Quellen (eigener Datenbank-Benutzer mit SELECT-Rechten), Zugangsdaten in
   einer Datei nur für root (`/etc/lager-cockpit/<name>.env`, Modus 600), nie im Repository oder im Chat.
3. **Idempotent:** Jeder Lauf kann beliebig wiederholt werden (Upsert je Artikel und Tag), ein verpasster Tag
   wird beim nächsten Lauf nachgeholt (Zeitfenster der letzten 7 Tage neu laden).
4. **Laufprotokoll** in einer Tabelle `lager.import_runs` (Start, Ende, Zeilen, Fehler). Das Interface zeigt
   „Daten veraltet“, wenn ein Lauf fehlt (wie heute für den Lagerbestand).
5. **MCP:** Die Connectoren selbst sind Cron-Jobs, kein MCP. Zusätzlich lässt sich je Quelle ein schreibgeschützter
   MCP-Server bereitstellen, damit Claude für Analysen direkt nachsehen kann. Voraussetzung ist, dass der MCP-Server
   die Quelle erreicht; Claude-Sitzungen in der Cloud erreichen interne Datenbanken nicht.
6. **Datenschutz:** Nur Mengen je Artikel und Tag, Käufergruppe und Umsatz. Keine Namen, E-Mail-Adressen oder
   Rechnungsnummern (so auch der Excel-Aggregator).

## Was ich zum Bauen brauche

**Magento-Verkaufsdatenbank**
- Datenbanktyp und Version (MySQL/MariaDB?), Host und Port; ist sie von server7 aus erreichbar (Firewall, VPN)?
- Ein Lesebenutzer; das Passwort legst du selbst auf dem Server ab (ich gebe dir die Datei vor).
- Welche Bestellungen zählen als Absatz (Status `complete`, `processing`, auch `canceled` ausschließen?),
  und nach welchem Datum (Bestelldatum oder Versanddatum)?
- Gibt es in Magento die Käufergruppe (Endkunde, Therapeut, Händler)? Händler- und Telefonverkäufe laufen vermutlich
  über JTL, nicht über den Shop.

**JTL-Wawi**
- JTL läuft auf Microsoft SQL Server (Datenbank `eazybusiness`): Host, Port, Version.
- Wo steht der Server (im Büro oder gehostet), und kann server7 ihn erreichen? Sonst wäre ein täglicher Export
  (CSV/SQL-Abfrage) vom JTL-Rechner auf den Server die Alternative.
- Welche Lager sollen zählen (Hauptlager, Zugang, Sperrlager)? Gibt es mehrere Lager je Artikel?
- Artikelnummern: Ist die JTL-Artikelnummer gleich der Magento-SKU (`1101216`)?

**Entscheidung zur Verkaufsquelle**
Der Excel-Export hat Rechnungs- und Auftragsnummern im JTL-Format (RE…, AU…) und enthält Händler, Therapeuten und
Mitarbeiter. Der Gesamtabsatz steht damit in JTL. Magento bildet nur den Webshop ab. Für die Prognose ist der
Gesamtabsatz besser. Falls das stimmt, wäre JTL die Hauptquelle für Absatz **und** Lager, und der Magento-Absatz
nur eine Ergänzung.

## Artikelnummern aus der Vergangenheit

Die Historie enthält alte Nummern (z. B. `1001` für den heutigen Artikel `1101001`, Pränat Plus Typ Z & K). Damit
die fünf Jahre für die aktuellen Artikel nutzbar sind, braucht es eine Zuordnung alt → neu. Vorschlag: automatisch
nach gleichem Produktnamen vorschlagen, du bestätigst per CSV.
