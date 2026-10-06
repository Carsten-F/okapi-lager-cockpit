# Spielt Migrationen auf die Instanz ein (wiederholbar). Im Repo-Ordner:  .\scripts\migrate.ps1
# Standard: 003 bis 008. Erstinstallation: -Files 001_lager_schema.sql,003_...,004_...,005_...
param(
  [string]$Server = 'root@server7.centaurus.info',
  [string[]]$Files = @('003_order_eta_required.sql', '004_empty_stock.sql', '005_order_updates_archive.sql', '006_forecast_rounding_fix.sql', '007_lifecycle_brand_import_sales.sql', '008_receipts_stockqty_alias.sql')
)
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
  ssh $Server "mkdir -p /opt/migrations-lager"; if ($LASTEXITCODE -ne 0) { throw 'Ordner anlegen fehlgeschlagen.' }
  foreach ($f in $Files) {
    Write-Host "== $f"
    scp "migrations/$f" "${Server}:/opt/migrations-lager/"; if ($LASTEXITCODE -ne 0) { throw "Upload $f fehlgeschlagen." }
    ssh $Server "docker exec -i supabase-db psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 < /opt/migrations-lager/$f"
    if ($LASTEXITCODE -ne 0) { throw "Migration $f fehlgeschlagen - siehe Ausgabe oben. Die Datei laeuft in einer Transaktion, es wurde nichts halb angewendet." }
  }
  Write-Host 'Fertig.'
} finally { Pop-Location }
