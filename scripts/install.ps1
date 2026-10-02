# Gesamte Einrichtung auf dem Server in einem Lauf (laeuft von jedem Ordner aus):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\okapi-lager-cockpit\scripts\install.ps1"
# Bewusst NICHT enthalten (eigene Entscheidung): Selbstregistrierung abschalten, Cronjobs.
param([string]$Server = 'root@server7.centaurus.info')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Step($t) { Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }

Step '1/5  Migrationen 003, 004, 005 (jeweils in einer Transaktion)'
& (Join-Path $PSScriptRoot 'migrate.ps1') -Server $Server

Step '2/5  Dateien auf den Server laden (/opt/lager-cockpit)'
& (Join-Path $PSScriptRoot 'deploy_server.ps1') -Server $Server

Step '3/5  Apache: /lager eintragen (Sicherung, configtest, nur bei Erfolg reload)'
ssh $Server "/opt/lager-cockpit/deploy/apply_apache.sh"
if ($LASTEXITCODE -ne 0) { throw 'apply_apache.sh fehlgeschlagen - siehe Ausgabe oben. Die Apache-Konfiguration wurde dabei zurueckgesetzt.' }

Step '4/5  Kontrolle der Datenbank (nur lesend)'
Get-Content (Join-Path $root 'migrations\verify.sql') | ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X"

Step '5/5  Selbstregistrierung: Trockenlauf (aendert nichts)'
ssh $Server "/opt/lager-cockpit/scripts/disable_signup.sh"

Write-Host ''
Write-Host 'Fertig. Bitte die komplette Ausgabe schicken. Aufruf der Seite: https://supabase.okapi-online.de/lager/' -ForegroundColor Green
