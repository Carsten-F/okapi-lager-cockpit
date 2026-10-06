-- ENTWURF: nach der Schema-Pruefung anpassen (Lager-Auswahl: nur die Lager, die zaehlen), dann diese Zeile entfernen.
-- Ergebnis: sku, warehouse, qty_total, qty_available. snapshot_date setzt das Werkzeug (heute).
SELECT a.cArtNr          AS sku,
       w.cName           AS warehouse,
       l.fLagerbestand   AS qty_total,
       l.fVerfuegbar     AS qty_available
FROM dbo.tlagerbestand l
JOIN dbo.tArtikel a   ON a.kArtikel = l.kArtikel
JOIN dbo.tWarenLager w ON w.kWarenLager = l.kWarenLager
WHERE a.cArtNr IS NOT NULL AND a.cArtNr <> ''
