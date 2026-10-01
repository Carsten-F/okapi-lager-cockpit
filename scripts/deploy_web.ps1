# Laedt das Web-Interface auf den Server (nur statische Dateien). Im Repo-Ordner ausfuehren:
#   .\scripts\deploy_web.ps1
param(
  [string]$Server = 'root@server7.centaurus.info',
  [string]$Target = '/opt/lager-cockpit'
)
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
  ssh $Server "mkdir -p $Target"
  scp -r web "${Server}:${Target}/"
  if ($LASTEXITCODE -ne 0) { throw 'scp fehlgeschlagen.' }
  Write-Host "Hochgeladen nach ${Target}/web. Aufruf: https://supabase.okapi-online.de/lager/"
} finally { Pop-Location }
