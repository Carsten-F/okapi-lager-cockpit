# Holt die neueste Sicherung vom Server auf diesen Rechner (woechentlich per Aufgabenplanung,
# siehe register_task.ps1). Voraussetzung: SSH-Anmeldung per Schluessel (wie bisher).
param(
  [string]$Server    = 'root@server7.centaurus.info',
  [string]$RemoteDir = '/opt/backups/lager',
  [string]$LocalDir  = (Join-Path $env:USERPROFILE 'Backups\okapi-lager'),
  [int]$KeepWeeks    = 26,
  [int]$MaxAgeDays   = 3
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
$log = Join-Path $LocalDir 'pull_backup.log'
function Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Tee-Object -FilePath $log -Append }

try {
  $remoteFile = (ssh -o BatchMode=yes $Server "ls -1t $RemoteDir/lager_*.dump | head -1" | Out-String).Trim()
  if (-not $remoteFile) { throw 'Keine Sicherung auf dem Server gefunden.' }
  $name = $remoteFile.Split('/')[-1]

  # Ist die Sicherung auf dem Server aktuell? (Warnung, falls der Server-Cronjob ausfaellt)
  $mtime = [int64](ssh -o BatchMode=yes $Server "stat -c %Y $remoteFile" | Out-String).Trim()
  $ageDays = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $mtime) / 86400
  if ($ageDays -gt $MaxAgeDays) { Log ("WARNUNG: neueste Sicherung auf dem Server ist {0:N1} Tage alt ({1})." -f $ageDays, $name) }

  $local = Join-Path $LocalDir $name
  if (Test-Path $local) {
    Log "Bereits vorhanden: $name"
  } else {
    Push-Location $LocalDir   # relatives Ziel, damit scp den Laufwerksbuchstaben nicht als Host liest
    try { scp -o BatchMode=yes "${Server}:${remoteFile}" "$name.part" } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "scp fehlgeschlagen (Exitcode $LASTEXITCODE)." }
    $remoteHash = ((ssh -o BatchMode=yes $Server "sha256sum $remoteFile | cut -d' ' -f1" | Out-String).Trim()).ToLower()
    $localHash = (Get-FileHash -Algorithm SHA256 (Join-Path $LocalDir "$name.part")).Hash.ToLower()
    if ($remoteHash -ne $localHash) { Remove-Item (Join-Path $LocalDir "$name.part") -Force; throw "Pruefsumme stimmt nicht ueberein ($name)." }
    Move-Item (Join-Path $LocalDir "$name.part") $local
    Log ("OK: {0} ({1:N0} KB), Pruefsumme stimmt." -f $name, ((Get-Item $local).Length / 1KB))
  }

  $old = Get-ChildItem $LocalDir -Filter 'lager_*.dump' | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7 * $KeepWeeks) }
  foreach ($f in $old) { Remove-Item $f.FullName -Force; Log "Alte Sicherung geloescht: $($f.Name)" }
}
catch {
  Log "FEHLER: $($_.Exception.Message)"
  exit 1
}
