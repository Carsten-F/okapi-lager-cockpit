#!/usr/bin/env bash
# Schaltet die Selbstregistrierung der Supabase-Instanz ab (Auth-Dienst GoTrue). Nutzer koennen
# danach nur noch ueber Studio (Super-Admin) angelegt, geaendert und geloescht werden.
# GILT FUER DIE GANZE INSTANZ. Ohne Argument nur Anzeige ("Trockenlauf"); "apply" fuehrt aus.
set -euo pipefail
DIR="${DIR:-/opt/supabase-project}"
cd "$DIR"

line="$(grep -E 'GOTRUE_DISABLE_SIGNUP' docker-compose.yml | head -1 || true)"
[ -n "$line" ] || { echo "FEHLER: GOTRUE_DISABLE_SIGNUP steht nicht in docker-compose.yml - Abbruch, bitte melden."; exit 1; }
var="$(echo "$line" | sed -nE 's/.*\$\{([A-Za-z0-9_]+)(:-[^}]*)?\}.*/\1/p')"
[ -n "$var" ] || { echo "FEHLER: Compose-Zeile hat keine Variable: $line"; exit 1; }

current="$(grep -E "^${var}=" .env || echo '(nicht gesetzt)')"
echo "Compose-Zeile : $(echo "$line" | sed 's/^ *//')"
echo "Variable      : $var"
echo "Aktuell in .env: $current"
echo "Laufender Dienst: $(docker exec supabase-auth env 2>/dev/null | grep GOTRUE_DISABLE_SIGNUP || echo 'nicht lesbar')"

[ "${1:-}" = "apply" ] || { echo; echo "Trockenlauf. Zum Anwenden:  $0 apply"; exit 0; }

cp -p .env ".env.bak.$(date +%F_%H%M%S)"
if grep -qE "^${var}=" .env; then sed -i -E "s/^${var}=.*/${var}=true/" .env; else echo "${var}=true" >> .env; fi
docker compose up -d --force-recreate auth
sleep 5
echo "Laufender Dienst nach Neustart: $(docker exec supabase-auth env | grep GOTRUE_DISABLE_SIGNUP)"
docker ps --filter name=supabase-auth --format '{{.Names}}: {{.Status}}'
