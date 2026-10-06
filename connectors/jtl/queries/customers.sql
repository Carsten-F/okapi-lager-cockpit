-- ENTWURF: nach der Schema-Pruefung anpassen, dann diese Zeile entfernen.
-- PERSONENBEZOGEN: Ergebnis geht ausschliesslich in die Datenbank okapi_kunden.
SELECT k.cKundenNr          AS customer_no,
       ad.cFirma            AS company,
       ad.cVorname          AS first_name,
       ad.cName             AS last_name,
       ad.cMail             AS email,
       ad.cTel              AS phone,
       ad.cStrasse          AS street,
       ad.cPLZ              AS zip,
       ad.cOrt              AS city,
       ad.cISO              AS country,
       g.cName              AS customer_group,
       CAST(k.dErstellt AS date) AS created_on,
       NULL                 AS newsletter_optin
FROM dbo.tKunde k
LEFT JOIN dbo.tAdresse ad ON ad.kKunde = k.kKunde AND ad.nStandard = 1
LEFT JOIN dbo.tKundenGruppe g ON g.kKundenGruppe = k.kKundenGruppe
WHERE k.cKundenNr IS NOT NULL AND k.cKundenNr <> ''
