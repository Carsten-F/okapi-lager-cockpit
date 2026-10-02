# Gesamte Einrichtung auf dem Server in einem Lauf (laeuft von jedem Ordner aus):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\okapi-lager-cockpit\scripts\install.ps1"
# Bewusst NICHT enthalten (eigene Entscheidung): Selbstregistrierung abschalten, Cronjobs.
param([string]$Server = 'root@server7.centaurus.info')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Step($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

Step '1/6  Migrationen 003, 004, 005 (jeweils in einer Transaktion)'
& (Join-Path $PSScriptRoot 'migrate.ps1') -Server $Server

Step '2/6  Dateien auf den Server laden (/opt/lager-cockpit)'
& (Join-Path $PSScriptRoot 'deploy_server.ps1') -Server $Server

Step '3/6  Apache: /lager eintragen (Sicherung, configtest, nur bei Erfolg reload)'
ssh $Server "/opt/lager-cockpit/deploy/apply_apache.sh"
if ($LASTEXITCODE -ne 0) { throw 'apply_apache.sh fehlgeschlagen - siehe Ausgabe oben. Die Apache-Konfiguration wurde dabei zurueckgesetzt.' }

Step '4/6  Arbeitskopie aus den Magento-Daten abgleichen (idempotent)'
'select lager.sync_from_magento() as zeilen_neu_oder_geaendert;' | ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X"
if ($LASTEXITCODE -ne 0) { throw 'Abgleich fehlgeschlagen.' }

Step '5/6  Kontrolle der Datenbank (nur lesend)'
Get-Content (Join-Path $root 'migrations\verify.sql') | ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X"

Step '6/6  Selbstregistrierung: Trockenlauf (aendert nichts)'
ssh $Server "/opt/lager-cockpit/scripts/disable_signup.sh"

Step 'Pruefung der Seite von diesem Rechner aus'
try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://supabase.okapi-online.de/lager/' -TimeoutSec 20; Write-Host "https://supabase.okapi-online.de/lager/ -> HTTP $($r.StatusCode)" }
catch { Write-Host "https://supabase.okapi-online.de/lager/ -> FEHLER: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ''
Write-Host 'Fertig. Bitte die komplette Ausgabe schicken. Aufruf der Seite: https://supabase.okapi-online.de/lager/' -ForegroundColor Green
