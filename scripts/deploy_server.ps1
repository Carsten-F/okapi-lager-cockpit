# Laedt Web-Interface, Server-Skripte und Apache-Vorlage nach /opt/lager-cockpit auf den Server.
# Aufruf (laeuft von jedem Ordner aus):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\okapi-lager-cockpit\scripts\deploy_server.ps1"
param(
  [string]$Server = 'root@server7.centaurus.info',
  [string]$Target = '/opt/lager-cockpit'
)
$ErrorActionPreference = 'Stop'
function Step($t) { Write-Host "-> $t" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what fehlgeschlagen (Exitcode $LASTEXITCODE)." } }

Push-Location (Join-Path $PSScriptRoot '..')
try {
  Step 'Pruefe Zeilenenden der Shell-Skripte'
  # Shell-Skripte mit Windows-Zeilenenden (CRLF) laufen auf dem Server nicht.
  foreach ($f in Get-ChildItem -Recurse -Include *.sh -Path scripts, deploy) {
    if ((Get-Content -Raw $f.FullName) -match "`r") {
      throw "$($f.Name) hat Windows-Zeilenenden. Einmalig im Repo-Ordner ausfuehren: git rm --cached -r -q . ; git reset --hard -q"
    }
  }
  # Schutz gegen eine versehentlich lokale Kopie (scp ohne Ziel ueberschreibt sonst Dateien)
  if ($Server -notmatch '^[^@\s]+@[^@\s:]+$') { throw "Ungueltiger Server '$Server' (erwartet: benutzer@host)." }

  Step 'Lege Ordner auf dem Server an'
  ssh $Server "mkdir -p $Target/scripts $Target/deploy $Target/connectors/jtl/queries /opt/backups/lager /opt/backups/kunden /etc/lager-cockpit && chmod 700 /opt/backups/lager /opt/backups/kunden /etc/lager-cockpit"; Check 'Ordner anlegen'
  Step 'Lade web/ hoch'
  scp -r web "${Server}:${Target}/"; Check 'Upload web'
  Step 'Lade deploy/ hoch'
  scp deploy/apache-lager.snippet.conf deploy/apply_apache.sh "${Server}:${Target}/deploy/"; Check 'Upload deploy'
  Step 'Lade connectors/ hoch'
  scp connectors/jtl/extract_jtl.py connectors/jtl/config.example.env connectors/jtl/discovery.sql connectors/jtl/requirements.txt "${Server}:${Target}/connectors/jtl/"; Check 'Upload connectors'
  scp connectors/jtl/queries/*.sql "${Server}:${Target}/connectors/jtl/queries/"; Check 'Upload queries'
  Step 'Lade scripts/ hoch'
  scp scripts/backup_lager.sh scripts/backup_kunden.sh scripts/server/disable_signup.sh scripts/server/install_cron.sh "${Server}:${Target}/scripts/"; Check 'Upload scripts'
  Step 'Setze Dateirechte (Web lesbar fuer den Apache, Skripte nur fuer root)'
  # scp von Windows legt Dateien mit zu strengen Rechten an; ohne diesen Schritt antwortet die Seite mit 403.
  ssh $Server "chmod 755 $Target $Target/scripts $Target/deploy; chmod -R u=rwX,go=rX $Target/web; chmod 644 $Target/deploy/apache-lager.snippet.conf; chmod 700 $Target/scripts/*.sh $Target/deploy/apply_apache.sh"; Check 'Dateirechte setzen'

  Step 'Pruefe die Seite von diesem Rechner aus'
  try { $r = Invoke-WebRequest -UseBasicParsing -Uri 'https://supabase.okapi-online.de/lager/' -TimeoutSec 20; Write-Host "   https://supabase.okapi-online.de/lager/ -> HTTP $($r.StatusCode)" -ForegroundColor Green }
  catch { Write-Host "   Seite nicht erreichbar: $($_.Exception.Message)" -ForegroundColor Yellow }
  Write-Host "Fertig: web, deploy und scripts liegen in $Target." -ForegroundColor Green
} finally { Pop-Location }
