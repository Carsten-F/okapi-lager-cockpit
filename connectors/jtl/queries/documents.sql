-- ENTWURF: nach der Schema-Pruefung anpassen, dann diese Zeile entfernen. Parameter: %(since)s (Rechnungsdatum ab).
-- Ergebnis: doc_no, doc_type (rechnung|gutschrift|storno), doc_date (Rechnungsdatum), order_no, customer_no,
-- customer_group, country, currency, net_total, gross_total. KEINE Namen/Adressen/E-Mail.
SELECT r.cRechnungsNr                         AS doc_no,
       CASE WHEN r.nStorno = 1 THEN 'storno' ELSE 'rechnung' END AS doc_type,
       CAST(r.dErstellt AS date)              AS doc_date,
       b.cBestellNr                           AS order_no,
       k.cKundenNr                            AS customer_no,
       g.cName                                AS customer_group,
       ra.cISO                                AS country,
       r.cWaehrung                            AS currency,
       e.fVkNetto                             AS net_total,
       e.fVkBrutto                            AS gross_total
FROM Rechnung.tRechnung r
LEFT JOIN Rechnung.tRechnungEckdaten e ON e.kRechnung = r.kRechnung
LEFT JOIN dbo.tBestellung b ON b.kBestellung = r.kBestellung
LEFT JOIN dbo.tKunde k ON k.kKunde = r.kKunde
LEFT JOIN dbo.tKundenGruppe g ON g.kKundenGruppe = k.kKundenGruppe
LEFT JOIN Rechnung.tRechnungAdresse ra ON ra.kRechnung = r.kRechnung AND ra.nTyp = 1
WHERE CAST(r.dErstellt AS date) >= %(since)s
UNION ALL
-- Gutschriften (Retouren/Korrekturen)
SELECT gs.cGutschriftNr, 'gutschrift', CAST(gs.dErstellt AS date), NULL, k.cKundenNr, g.cName, NULL, NULL,
       gs.fPreis, NULL
FROM dbo.tgutschrift gs
LEFT JOIN dbo.tKunde k ON k.kKunde = gs.kKunde
LEFT JOIN dbo.tKundenGruppe g ON g.kKundenGruppe = k.kKundenGruppe
WHERE CAST(gs.dErstellt AS date) >= %(since)s
