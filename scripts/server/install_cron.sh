#!/usr/bin/env bash
# Richtet die Cronjobs des Lager-Cockpits ein (Serverzeit Europe/Berlin). Idempotent: ein zweiter
# Lauf ersetzt nur den eigenen Block, bestehende Eintraege anderer Projekte bleiben unveraendert.
#   06:30 und 07:30  Arbeitskopie aus Magento abgleichen (Magento-Import laeuft um 06:15)
#   08:00            Sicherung (scripts/backup_lager.sh)
# Ohne Argument nur Anzeige ("Trockenlauf"); mit "apply" wird die Crontab geschrieben.
set -euo pipefail
BEGIN='# --- lager-cockpit (automatisch gepflegt: scripts/server/install_cron.sh) ---'
END='# --- /lager-cockpit ---'
DIR="${DIR:-/opt/lager-cockpit}"

current="$(crontab -l 2>/dev/null || true)"
rest="$(printf '%s\n' "$current" | awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}')"
rest="$(printf '%s\n' "$rest" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"   # Leerzeilen am Ende entfernen

block="$BEGIN
CRON_TZ=Europe/Berlin
30 6 * * * docker exec supabase-db psql -U postgres -d postgres -X -c \"select lager.sync_from_magento()\" >> /var/log/lager-sync.log 2>&1
30 7 * * * docker exec supabase-db psql -U postgres -d postgres -X -c \"select lager.sync_from_magento()\" >> /var/log/lager-sync.log 2>&1
0 8 * * * $DIR/scripts/backup_lager.sh >> /var/log/lager-backup.log 2>&1
$END"

new="$(printf '%s\n\n%s\n' "$rest" "$block" | sed '1{/^$/d}')"
echo "Vorhandene Eintraege bleiben erhalten. Neue Crontab:"; echo "-----"; printf '%s\n' "$new"; echo "-----"
[ "${1:-}" = "apply" ] || { echo "Trockenlauf. Zum Anwenden:  $0 apply"; exit 0; }

[ -x "$DIR/scripts/backup_lager.sh" ] || { echo "FEHLER: $DIR/scripts/backup_lager.sh fehlt oder ist nicht ausfuehrbar"; exit 1; }
[ -z "$current" ] || printf '%s\n' "$current" > "/root/crontab.bak.$(date +%F_%H%M%S)"
printf '%s\n' "$new" | crontab -
echo "OK: Crontab geschrieben (Sicherung der alten Fassung: /root/crontab.bak.*)."
