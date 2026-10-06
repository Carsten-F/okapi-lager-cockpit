-- JTL-Wawi Schema-Erkundung. NUR LESEND, liefert Struktur und Zeilenzahlen, KEINE Dateninhalte.
-- Ausfuehren in SSMS / Azure Data Studio / sqlcmd gegen die Datenbank eazybusiness (Lese-Login genuegt).
-- Ergebnis jeder der 6 Abfragen bitte als CSV/Excel exportieren (Rechtsklick > Ergebnisse speichern) und mir geben.
-- Beispiel sqlcmd:  sqlcmd -S HOST,PORT -d eazybusiness -U LOGIN -C -s ";" -W -i discovery.sql -o discovery_ergebnis.txt

SET NOCOUNT ON;

-- 1) Server und Version
SELECT @@VERSION AS version, DB_NAME() AS datenbank, SERVERPROPERTY('Collation') AS collation;

-- 2) Alle Tabellen mit Zeilenzahl (grosse Tabellen zuerst)
SELECT s.name AS schema_name, t.name AS tabelle, SUM(p.row_count) AS zeilen
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
GROUP BY s.name, t.name
ORDER BY SUM(p.row_count) DESC;

-- 3) Spalten der fachlich relevanten Tabellen (Name enthaelt eines der Stichworte)
SELECT s.name AS schema_name, t.name AS tabelle, c.column_id AS pos, c.name AS spalte,
       ty.name AS typ, c.max_length AS laenge, c.is_nullable AS null_erlaubt
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE t.name LIKE '%Artikel%' OR t.name LIKE '%Lager%' OR t.name LIKE '%Rechnung%' OR t.name LIKE '%Gutschrift%'
   OR t.name LIKE '%Kunde%' OR t.name LIKE '%Adresse%' OR t.name LIKE '%Auftrag%' OR t.name LIKE '%Bestellung%'
   OR t.name LIKE '%Lieferant%' OR t.name LIKE '%Wareneingang%' OR t.name LIKE '%Storno%' OR t.name LIKE '%Retoure%'
   OR t.name LIKE '%Versand%' OR t.name LIKE '%Zahlung%' OR t.name LIKE '%Kategorie%' OR t.name LIKE '%Hersteller%'
ORDER BY s.name, t.name, c.column_id;

-- 4) Fremdschluessel dieser Tabellen (zeigt, welche Tabellen zusammengehoeren)
SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id) AS von_schema, OBJECT_NAME(fk.parent_object_id) AS von_tabelle,
       COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS von_spalte,
       OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS nach_schema, OBJECT_NAME(fk.referenced_object_id) AS nach_tabelle,
       COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS nach_spalte
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
WHERE OBJECT_NAME(fk.parent_object_id) LIKE '%Rechnung%' OR OBJECT_NAME(fk.parent_object_id) LIKE '%Gutschrift%'
   OR OBJECT_NAME(fk.parent_object_id) LIKE '%Lager%' OR OBJECT_NAME(fk.parent_object_id) LIKE '%Kunde%'
   OR OBJECT_NAME(fk.parent_object_id) LIKE '%Auftrag%' OR OBJECT_NAME(fk.parent_object_id) LIKE '%Bestellung%'
ORDER BY 1, 2;

-- 5) Sichten (Views) zu Lager, Rechnung, Auftrag - JTL liefert dafuer fertige Sichten
SELECT s.name AS schema_name, v.name AS sicht
FROM sys.views v JOIN sys.schemas s ON s.schema_id = v.schema_id
WHERE v.name LIKE '%Lager%' OR v.name LIKE '%Rechnung%' OR v.name LIKE '%Auftrag%' OR v.name LIKE '%Gutschrift%'
   OR v.name LIKE '%Artikel%' OR v.name LIKE '%Kunde%'
ORDER BY s.name, v.name;

-- 6) Welche Rechte hat das Login? (zeigt, ob wirklich nur gelesen werden kann)
SELECT dp.name AS datenbank_benutzer, dp.type_desc, rp.name AS rolle
FROM sys.database_principals dp
LEFT JOIN sys.database_role_members drm ON drm.member_principal_id = dp.principal_id
LEFT JOIN sys.database_principals rp ON rp.principal_id = drm.role_principal_id
WHERE dp.name = USER_NAME();
