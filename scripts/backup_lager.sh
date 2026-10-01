#!/usr/bin/env bash
# Taegliche Sicherung der Lager-Cockpit-Daten (Schemas lager und okapi_stock).
#   okapi_stock.stock_history enthaelt die Tageshistorie und ist aus Magento NICHT nachladbar.
# Ablage: $BACKUP_DIR/lager_YYYY-MM-DD_HHMM.dump (pg_dump Custom-Format, komprimiert).
# Pruefung: Dump wird mit pg_restore --list gelesen; bei Fehler Exitcode 1 und Eintrag im Log.
# Aufbewahrung: $KEEP_DAYS Tage. Nur eigene Dateien (lager_*.dump) werden geloescht.
# Aufruf per Cron, siehe README.md.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/backups/lager}"
KEEP_DAYS="${KEEP_DAYS:-30}"
MIN_BYTES="${MIN_BYTES:-2048}"
# Auf dem Server (Standard) laeuft pg_dump im Datenbank-Container. Fuer Tests ueberschreibbar.
DUMP_CMD="${DUMP_CMD:-docker exec supabase-db pg_dump -U postgres -d postgres}"
RESTORE_CMD="${RESTORE_CMD:-docker exec -i supabase-db pg_restore}"

log() { echo "$(date '+%F %T') $*"; }

umask 077
mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { log "FEHLER: anderer Lauf aktiv"; exit 1; }

stamp="$(date +%F_%H%M)"
target="$BACKUP_DIR/lager_${stamp}.dump"
tmp="$target.part"
trap 'rm -f "$tmp"' EXIT

log "Sicherung startet -> $target"
# shellcheck disable=SC2086
if ! $DUMP_CMD -n lager -n okapi_stock -Fc -Z 6 > "$tmp"; then
  log "FEHLER: pg_dump fehlgeschlagen"; exit 1
fi

size="$(stat -c %s "$tmp")"
if [ "$size" -lt "$MIN_BYTES" ]; then
  log "FEHLER: Dump ungewoehnlich klein ($size Bytes)"; exit 1
fi
# shellcheck disable=SC2086
if ! $RESTORE_CMD --list < "$tmp" > /dev/null; then
  log "FEHLER: Dump nicht lesbar"; exit 1
fi
mv "$tmp" "$target"
trap - EXIT

removed="$(find "$BACKUP_DIR" -maxdepth 1 -name 'lager_*.dump' -mtime +"$KEEP_DAYS" -print -delete | wc -l)"
count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'lager_*.dump' | wc -l)"
log "OK: $size Bytes, $count Sicherungen vorhanden, $removed alte geloescht"
