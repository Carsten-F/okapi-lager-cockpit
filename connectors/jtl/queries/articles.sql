-- ENTWURF: nach der Schema-Pruefung (discovery.sql) an die tatsaechlichen Tabellen und Spalten anpassen,
-- danach diese Zeile entfernen. Spaltennamen im Ergebnis = Zielspalten (sku, name, ean, is_active, price_net, cost_net, created_on).
SELECT a.cArtNr                 AS sku,
       b.cName                  AS name,
       a.cBarcode               AS ean,
       a.cAktiv                 AS is_active,
       a.fVKNetto               AS price_net,
       a.fEKNetto               AS cost_net,
       CAST(a.dErstellt AS date) AS created_on
FROM dbo.tArtikel a
LEFT JOIN dbo.tArtikelBeschreibung b ON b.kArtikel = a.kArtikel AND b.kSprache = 1 AND b.kPlattform = 1
WHERE a.cArtNr IS NOT NULL AND a.cArtNr <> ''
