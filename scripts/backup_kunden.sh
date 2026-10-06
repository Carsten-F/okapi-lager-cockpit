#!/usr/bin/env bash
# Taegliche Sicherung der PERSONENBEZOGENEN Kundendatenbank okapi_kunden (DSGVO), getrennt von der Lager-Sicherung.
#   Die Datei bleibt auf dem Server (Verzeichnis nur fuer root) und wird NICHT automatisch auf den Windows-Rechner geholt.
# Ablage: $BACKUP_DIR/kunden_YYYY-MM-DD_HHMM.dump (pg_dump Custom-Format, komprimiert).
# Pruefung: Dump wird mit pg_restore --list gelesen; bei Fehler Exitcode 1 und Eintrag im Log.
# Aufbewahrung: $KEEP_DAYS Tage. Nur eigene Dateien (kunden_*.dump) werden geloescht.
# Aufruf per Cron, siehe README.md.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/opt/backups/kunden}"
KEEP_DAYS="${KEEP_DAYS:-14}"
MIN_BYTES="${MIN_BYTES:-2048}"
# Auf dem Server (Standard) laeuft pg_dump im Datenbank-Container. Fuer Tests ueberschreibbar.
DUMP_CMD="${DUMP_CMD:-docker exec supabase-db pg_dump -U postgres -d okapi_kunden}"
RESTORE_CMD="${RESTORE_CMD:-docker exec -i supabase-db pg_restore}"

log() { echo "$(date '+%F %T') $*"; }

umask 077
mkdir -p "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { log "FEHLER: anderer Lauf aktiv"; exit 1; }

stamp="$(date +%F_%H%M)"
target="$BACKUP_DIR/kunden_${stamp}.dump"
tmp="$target.part"
trap 'rm -f "$tmp"' EXIT

log "Sicherung startet -> $target"
# shellcheck disable=SC2086
if ! $DUMP_CMD -Fc -Z 6 > "$tmp"; then
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

removed="$(find "$BACKUP_DIR" -maxdepth 1 -name 'kunden_*.dump' -mtime +"$KEEP_DAYS" -print -delete | wc -l)"
count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'kunden_*.dump' | wc -l)"
log "OK: $size Bytes, $count Sicherungen vorhanden, $removed alte geloescht"
