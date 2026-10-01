# Richtet die woechentliche Aufgabe ein (sonntags 10:00; verpasste Laeufe werden nachgeholt,
# sobald der Rechner wieder an ist). Einmalig ausfuehren, in diesem Ordner.
$script = Join-Path $PSScriptRoot 'pull_backup.ps1'
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger  = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 10:00
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'OKAPI Lager Backup holen' -Action $action -Trigger $trigger -Settings $settings `
  -Description 'Holt die Lager-Cockpit-Sicherung vom Server (SSH-Schluessel des angemeldeten Benutzers).' -Force | Out-Null
Write-Host 'Aufgabe eingerichtet. Testlauf: Start-ScheduledTask -TaskName "OKAPI Lager Backup holen"'
Write-Host "Protokoll: $env:USERPROFILE\Backups\okapi-lager\pull_backup.log"
