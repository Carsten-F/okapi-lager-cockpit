# Laedt Web-Interface, Server-Skripte und Apache-Vorlage nach /opt/lager-cockpit auf den Server.
# Im Repo-Ordner ausfuehren:   .\scripts\deploy_server.ps1
param(
  [string]$Server = 'root@server7.centaurus.info',
  [string]$Target = '/opt/lager-cockpit'
)
$ErrorActionPreference = 'Stop'
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what fehlgeschlagen (Exitcode $LASTEXITCODE)." } }

Push-Location (Join-Path $PSScriptRoot '..')
try {
  # Shell-Skripte mit Windows-Zeilenenden (CRLF) laufen auf dem Server nicht.
  foreach ($f in Get-ChildItem -Recurse -Include *.sh -Path scripts, deploy) {
    if ((Get-Content -Raw $f.FullName) -match "`r") {
      throw "$($f.Name) hat Windows-Zeilenenden. Einmalig im Repo-Ordner ausfuehren: git rm --cached -r -q . ; git reset --hard -q"
    }
  }
  ssh $Server "mkdir -p $Target/scripts $Target/deploy /opt/backups/lager && chmod 700 /opt/backups/lager"; Check 'Ordner anlegen'
  scp -r web "${Server}:${Target}/"; Check 'Upload web'
  scp deploy/apache-lager.snippet.conf deploy/apply_apache.sh "${Server}:${Target}/deploy/"; Check 'Upload deploy'
  scp scripts/backup_lager.sh scripts/server/disable_signup.sh "${Server}:${Target}/scripts/"; Check 'Upload scripts'
  # Web-Dateien muessen fuer den Apache-Benutzer lesbar sein (Ordner 755, Dateien 644); Skripte nur fuer root.
  ssh $Server "chmod 755 $Target $Target/scripts $Target/deploy; chmod -R u=rwX,go=rX $Target/web; chmod 644 $Target/deploy/apache-lager.snippet.conf; chmod 700 $Target/scripts/backup_lager.sh $Target/scripts/disable_signup.sh $Target/deploy/apply_apache.sh"; Check 'Dateirechte setzen'
  Write-Host "Hochgeladen nach $Target (web, deploy, scripts)."
} finally { Pop-Location }
