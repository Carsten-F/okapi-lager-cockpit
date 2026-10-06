# Legt die getrennte Kundendatenbank okapi_kunden an (wiederholbar). Im Repo-Ordner:  .\scripts\migrate_kunden.ps1
# Enthaelt Personendaten (DSGVO). Zugriff nur ueber die Rolle kunden_reader, die einzeln vergeben wird.
param([string]$Server = 'root@server7.centaurus.info')
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
  ssh $Server "mkdir -p /opt/migrations-lager"; if ($LASTEXITCODE -ne 0) { throw 'Ordner anlegen fehlgeschlagen.' }
  scp "migrations/pii/001_kunden_db.sql" "${Server}:/opt/migrations-lager/"; if ($LASTEXITCODE -ne 0) { throw 'Upload fehlgeschlagen.' }
  ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/001_kunden_db.sql"
  if ($LASTEXITCODE -ne 0) { throw 'Anlegen der Kundendatenbank fehlgeschlagen - siehe Ausgabe oben.' }
  ssh $Server "docker exec supabase-db psql -U postgres -d okapi_kunden -Atc ""select 'okapi_kunden ok: ' || count(*) || ' Tabellen' from information_schema.tables where table_schema='kunden'"""
  Write-Host 'Fertig.'
} finally { Pop-Location }
