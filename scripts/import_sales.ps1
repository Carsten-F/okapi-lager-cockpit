# Spielt eine SQL-Datei mit Absatzdaten (erzeugt von tools/aggregate_sales.py --sql) auf den Server ein.
# Wiederholbar. Aufruf:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\okapi-lager-cockpit\scripts\import_sales.ps1" -SqlFile "C:\Pfad\sales_import.sql"
param(
  [Parameter(Mandatory = $true)][string]$SqlFile,
  [string]$Server = 'root@server7.centaurus.info'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $SqlFile)) { throw "Datei nicht gefunden: $SqlFile" }
if ($Server -notmatch '^[^@\s]+@[^@\s:]+$') { throw "Ungueltiger Server '$Server' (erwartet: benutzer@host)." }
$full = (Resolve-Path $SqlFile).Path
$dir = Split-Path $full -Parent
$name = Split-Path $full -Leaf
if ($name -notmatch '^[A-Za-z0-9._-]+\.sql$') { throw 'Dateiname nur mit Buchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und Endung .sql.' }

Write-Host '-> Lege Datenordner auf dem Server an'
ssh $Server "mkdir -p /opt/lager-cockpit/data && chmod 700 /opt/lager-cockpit/data"
if ($LASTEXITCODE -ne 0) { throw 'Ordner anlegen fehlgeschlagen.' }
Write-Host "-> Lade $name hoch ($([math]::Round((Get-Item $full).Length / 1MB, 1)) MB)"
Push-Location $dir   # relativer Pfad, damit scp den Laufwerksbuchstaben nicht als Host liest
try { scp -C $name "${Server}:/opt/lager-cockpit/data/$name" } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw 'Upload fehlgeschlagen.' }
Write-Host '-> Spiele die Daten ein (eine Transaktion; bei Fehler wird nichts uebernommen)'
ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/lager-cockpit/data/$name"
if ($LASTEXITCODE -ne 0) { throw 'Import fehlgeschlagen - siehe Ausgabe oben. Es wurde nichts uebernommen.' }
Write-Host 'Fertig.' -ForegroundColor Green
