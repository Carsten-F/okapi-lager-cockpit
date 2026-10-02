#!/usr/bin/env bash
# Traegt die Lager-Cockpit-Auslieferung in den Apache-vHost von supabase.okapi-online.de ein.
#  - idempotent (zweiter Lauf aendert nichts)
#  - Sicherung der Konfiguration, "configtest", nur bei Erfolg "reload" (kein Neustart; die Shops
#    laufen im selben Apache weiter)
#  - bei Fehler wird die urspruengliche Konfiguration zurueckgespielt
set -euo pipefail

CONF="${CONF:-/etc/apache2/sites-available/021-supabase.okapi-online.de.conf}"
SNIPPET="${SNIPPET:-/opt/lager-cockpit/deploy/apache-lager.snippet.conf}"
WEBDIR="${WEBDIR:-/opt/lager-cockpit/web}"
MARKER='# Alle normalen HTTP-Anfragen'   # Zeile unmittelbar vor "ProxyPass / ..."
CTL="$(command -v apache2ctl || command -v apachectl || true)"

[ -n "$CTL" ] || { echo "FEHLER: apache2ctl/apachectl nicht gefunden"; exit 1; }
[ -f "$CONF" ] || { echo "FEHLER: $CONF fehlt"; exit 1; }
[ -f "$SNIPPET" ] || { echo "FEHLER: $SNIPPET fehlt (deploy/ per scp hochladen)"; exit 1; }
[ -f "$WEBDIR/index.html" ] || { echo "FEHLER: $WEBDIR/index.html fehlt (erst .\\scripts\\deploy_web.ps1)"; exit 1; }

if grep -q 'Alias /lager ' "$CONF"; then echo "Bereits eingetragen - nichts zu tun."; exit 0; fi

count="$(grep -cF "$MARKER" "$CONF" || true)"
[ "$count" = 1 ] || { echo "FEHLER: Markerzeile '$MARKER' kommt $count-mal vor (erwartet 1). Bitte manuell einfuegen."; exit 1; }

mods="$("$CTL" -M 2>/dev/null || true)"
for m in headers_module alias_module proxy_module; do
  echo "$mods" | grep -q "$m" || { echo "FEHLER: Apache-Modul $m nicht geladen (a2enmod ${m%_module})"; exit 1; }
done

bak="$CONF.bak.$(date +%F_%H%M%S)"
cp -p "$CONF" "$bak"
line="$(grep -nF "$MARKER" "$bak" | cut -d: -f1)"
{ head -n $((line - 1)) "$bak"; cat "$SNIPPET"; tail -n +"$line" "$bak"; } > "$CONF"

if out="$("$CTL" configtest 2>&1)" && echo "$out" | grep -q 'Syntax OK'; then
  systemctl reload apache2
  echo "OK: eingetragen, Apache neu geladen (reload). Sicherung: $bak"
  echo "Aufruf: https://supabase.okapi-online.de/lager/"
else
  cp -p "$bak" "$CONF"
  echo "FEHLER: configtest schlug fehl, urspruengliche Konfiguration wiederhergestellt:"
  echo "$out"
  exit 1
fi
