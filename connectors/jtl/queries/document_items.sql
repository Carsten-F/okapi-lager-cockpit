-- ENTWURF: nach der Schema-Pruefung anpassen, dann diese Zeile entfernen. Parameter: %(since)s.
-- Ergebnis: doc_no, line_no, sku, product_name, qty, unit_price_net, discount_pct, line_net, tax_rate.
-- Gutschriftpositionen mit positiver Menge liefern; die Belegart steht in documents.doc_type.
-- Gutscheine/Rabattcodes haben keine Artikelnummer eines echten Artikels und werden im Absatz-Aufbau ausgefiltert.
SELECT r.cRechnungsNr AS doc_no,
       ROW_NUMBER() OVER (PARTITION BY r.kRechnung ORDER BY p.kRechnungPosition) AS line_no,
       p.cArtNr       AS sku,
       p.cString      AS product_name,
       p.fAnzahl      AS qty,
       p.fVKNetto     AS unit_price_net,
       p.fRabatt      AS discount_pct,
       p.fAnzahl * p.fVKNetto * (1 - p.fRabatt / 100.0) AS line_net,
       p.fMwSt        AS tax_rate
FROM Rechnung.tRechnungPosition p
JOIN Rechnung.tRechnung r ON r.kRechnung = p.kRechnung
WHERE CAST(r.dErstellt AS date) >= %(since)s
UNION ALL
SELECT gs.cGutschriftNr,
       ROW_NUMBER() OVER (PARTITION BY gs.kGutschrift ORDER BY gp.kGutschriftPos),
       gp.cArtNr, gp.cString, gp.fAnzahl, gp.fVKNetto, 0, gp.fAnzahl * gp.fVKNetto, gp.fMwSt
FROM dbo.tgutschriftpos gp
JOIN dbo.tgutschrift gs ON gs.kGutschrift = gp.kGutschrift
WHERE CAST(gs.dErstellt AS date) >= %(since)s
