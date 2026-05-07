#!/bin/bash
###############################################################################
# extract_credentials.sh
#
# Hilfsskript zum (halb-)automatischen Befüllen der sync_volkszaehler.conf.
#
# Sucht in den üblichen Volkszähler-Quellen nach DB-Zugangsdaten und schlägt
# eine Config vor. Schreibt NICHT direkt in die Config-Datei, sondern gibt die
# gefundenen Werte als sourcebare Zuweisungen aus, damit du sie kontrollieren
# kannst, bevor sie in sync_volkszaehler.conf landen.
#
# Quellen (in Reihenfolge):
#   1. Optionale Pfade als Argumente: extract_credentials.sh <yaml> [<my.cnf>]
#   2. /etc/volkszaehler.conf
#   3. /var/www/volkszaehler.org/etc/config.yaml
#   4. /var/www/html/volkszaehler.org/etc/config.yaml
#   5. ~/.my.cnf
#   6. /etc/mysql/conf.d/*.cnf
#
# Optional: per SSH auf einem entfernten Host suchen
#   extract_credentials.sh --ssh raspi.local
#
# Beispiel:
#   ./bin/extract_credentials.sh --ssh raspi.local > /tmp/raspi_creds.env
#   source /tmp/raspi_creds.env
#   # Werte prüfen, dann in sync_volkszaehler.conf übernehmen
###############################################################################

set -uo pipefail

REMOTE_HOST=""
PREFIX="SOURCE"  # SOURCE oder DEST -- wofür wir die Werte vorschlagen
EXTRA_PATHS=()

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--ssh HOST] [--prefix SOURCE|DEST] [PATH ...]

Options:
  --ssh HOST        Über SSH auf diesem Host suchen (statt lokal)
  --prefix NAME     Variablen-Präfix (default: SOURCE; sinnvoll: SOURCE oder DEST)
  --help            Diese Hilfe

Sucht nach DB-Credentials in Volkszähler-/MySQL-Configs und gibt sie als
shell-Variablen-Zuweisungen aus (z.B. SOURCE_HOST=..., SOURCE_USER=...).

Beispiele:
  # Lokal auf cold-lairs (Ziel-DB):
  ./bin/extract_credentials.sh --prefix DEST

  # Per SSH auf dem Raspi (Quell-DB):
  ./bin/extract_credentials.sh --ssh raspi.local --prefix SOURCE

  # Mit explizitem Config-Pfad:
  ./bin/extract_credentials.sh /etc/volkszaehler.conf
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssh)         REMOTE_HOST="$2"; shift 2 ;;
        --prefix)      PREFIX="$2";      shift 2 ;;
        --help|-h)     usage; exit 0 ;;
        --*)           echo "Unbekannte Option: $1" >&2; usage; exit 1 ;;
        *)             EXTRA_PATHS+=("$1"); shift ;;
    esac
done

###############################################################################
# Helfer: Befehl lokal oder per SSH ausführen
###############################################################################
run_remote() {
    if [ -n "$REMOTE_HOST" ]; then
        ssh -o ConnectTimeout=5 "$REMOTE_HOST" "$@"
    else
        bash -c "$*"
    fi
}

###############################################################################
# YAML-Parser für Volkszähler-Middleware-Config
#
# Volkszähler nutzt typischerweise:
#   db:
#     default:
#       driver: pdo_mysql
#       host: localhost
#       user: vz
#       password: secret
#       dbname: volkszaehler
#
# Wir parsen nur die ersten 30 Zeilen ab "db:" und extrahieren die 5 Felder.
###############################################################################
parse_yaml_db() {
    local content="$1"
    awk '
        /^[[:space:]]*db[[:space:]]*:/ {indb=1; next}
        indb && /^[a-zA-Z]/ {indb=0}
        indb {
            sub(/[[:space:]]*#.*$/, "")  # Kommentare entfernen
            if (match($0, /^[[:space:]]*host[[:space:]]*:[[:space:]]*/)) {
                v=substr($0, RLENGTH+1); gsub(/["\047]/,"",v); gsub(/[[:space:]]+$/,"",v)
                print "host=" v
            }
            if (match($0, /^[[:space:]]*user[[:space:]]*:[[:space:]]*/)) {
                v=substr($0, RLENGTH+1); gsub(/["\047]/,"",v); gsub(/[[:space:]]+$/,"",v)
                print "user=" v
            }
            if (match($0, /^[[:space:]]*password[[:space:]]*:[[:space:]]*/)) {
                v=substr($0, RLENGTH+1); gsub(/["\047]/,"",v); gsub(/[[:space:]]+$/,"",v)
                print "password=" v
            }
            if (match($0, /^[[:space:]]*dbname[[:space:]]*:[[:space:]]*/)) {
                v=substr($0, RLENGTH+1); gsub(/["\047]/,"",v); gsub(/[[:space:]]+$/,"",v)
                print "dbname=" v
            }
            if (match($0, /^[[:space:]]*port[[:space:]]*:[[:space:]]*/)) {
                v=substr($0, RLENGTH+1); gsub(/["\047]/,"",v); gsub(/[[:space:]]+$/,"",v)
                print "port=" v
            }
        }
    ' <<< "$content"
}

###############################################################################
# my.cnf-Parser (Sektion [client] oder [mysql])
###############################################################################
parse_mycnf() {
    local content="$1"
    awk '
        /^\[client\]|\[mysql\]/ {insec=1; next}
        /^\[/ {insec=0}
        insec {
            sub(/[[:space:]]*#.*$/, "")
            sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
            if ($0=="") next
            split($0, kv, /[[:space:]]*=[[:space:]]*/)
            k=kv[1]; v=kv[2]
            gsub(/["\047]/, "", v)
            if (k=="host"||k=="user"||k=="password"||k=="port"||k=="database")
                print k "=" v
        }
    ' <<< "$content"
}

###############################################################################
# Suche nach Config-Dateien
###############################################################################
SEARCH_PATHS=(
    "/etc/volkszaehler.conf"
    "/var/www/volkszaehler.org/etc/config.yaml"
    "/var/www/html/volkszaehler.org/etc/config.yaml"
    "/opt/volkszaehler/etc/config.yaml"
    "$HOME/volkszaehler.org/etc/config.yaml"
)

# Extra-Pfade aus Argumenten zuerst
for p in "${EXTRA_PATHS[@]}"; do
    SEARCH_PATHS=("$p" "${SEARCH_PATHS[@]}")
done

CHOSEN_FILE=""
CHOSEN_CONTENT=""

for p in "${SEARCH_PATHS[@]}"; do
    if run_remote "test -r '$p'" 2>/dev/null; then
        CHOSEN_FILE="$p"
        CHOSEN_CONTENT=$(run_remote "cat '$p'" 2>/dev/null)
        break
    fi
done

###############################################################################
# Auswerten
###############################################################################
declare -A VALS
VALS[host]=""
VALS[port]="3306"
VALS[user]=""
VALS[password]=""
VALS[dbname]="volkszaehler"

if [ -n "$CHOSEN_FILE" ]; then
    echo "# gefunden: $CHOSEN_FILE${REMOTE_HOST:+ (auf $REMOTE_HOST)}" >&2

    if [[ "$CHOSEN_FILE" == *.yaml ]] || [[ "$CHOSEN_FILE" == *.yml ]] || [[ "$CHOSEN_FILE" == */volkszaehler.conf ]]; then
        # /etc/volkszaehler.conf ist auf manchen Distros auch YAML
        while IFS='=' read -r k v; do
            [ -n "$k" ] && [ -n "$v" ] && VALS[$k]="$v"
        done < <(parse_yaml_db "$CHOSEN_CONTENT")
    fi

    # falls über /etc/volkszaehler.conf nichts gefunden: try my.cnf-Style
    if [ -z "${VALS[user]}" ]; then
        while IFS='=' read -r k v; do
            [ -n "$k" ] && [ -n "$v" ] && {
                [ "$k" = "database" ] && k="dbname"
                VALS[$k]="$v"
            }
        done < <(parse_mycnf "$CHOSEN_CONTENT")
    fi
else
    echo "# WARNUNG: keine Volkszähler-Config gefunden. Suche in ~/.my.cnf …" >&2
fi

# Fallback: ~/.my.cnf für User+Password
if [ -z "${VALS[user]}" ] || [ -z "${VALS[password]}" ]; then
    MYCNF_CONTENT=$(run_remote "cat ~/.my.cnf 2>/dev/null" || true)
    if [ -n "$MYCNF_CONTENT" ]; then
        echo "# zusätzlich aus ~/.my.cnf${REMOTE_HOST:+ ($REMOTE_HOST)}" >&2
        while IFS='=' read -r k v; do
            [ -n "$k" ] && [ -n "$v" ] && {
                [ "$k" = "database" ] && k="dbname"
                [ -z "${VALS[$k]}" ] && VALS[$k]="$v"
            }
        done < <(parse_mycnf "$MYCNF_CONTENT")
    fi
fi

###############################################################################
# Heuristik für SOURCE_HOST: bei --ssh den SSH-Hostnamen verwenden,
# wenn Volkszähler-Config "localhost" sagt (was vom Raspi aus stimmt,
# aber für uns auf cold-lairs nicht).
###############################################################################
if [ -n "$REMOTE_HOST" ] && { [ -z "${VALS[host]}" ] || [ "${VALS[host]}" = "localhost" ] || [ "${VALS[host]}" = "127.0.0.1" ]; }; then
    echo "# Hinweis: host war '${VALS[host]:-leer}', ersetze durch '$REMOTE_HOST' (von außen sichtbar)" >&2
    VALS[host]="$REMOTE_HOST"
fi

###############################################################################
# Ausgabe als shell-fähige Zuweisungen
###############################################################################
P="$PREFIX"
echo "# === ${P}_* (zur Übernahme in sync_volkszaehler.conf) ==="
echo "${P}_HOST=\"${VALS[host]}\""
echo "${P}_PORT=\"${VALS[port]}\""
echo "${P}_USER=\"${VALS[user]}\""
echo "${P}_PASS=\"${VALS[password]}\""
echo "${P}_DB=\"${VALS[dbname]}\""

# Hinweise auf fehlende Werte
for k in host user password dbname; do
    if [ -z "${VALS[$k]}" ]; then
        echo "# WARNUNG: '$k' konnte nicht ermittelt werden — bitte manuell setzen." >&2
    fi
done
