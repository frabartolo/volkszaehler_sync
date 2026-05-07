#!/bin/bash
###############################################################################
# verify_sync.sh
#
# Vergleicht Quell-DB (Raspi) mit Ziel-DB (cold-lairs) und gibt einen Bericht
# aus, der zeigt, ob beide Datenbanken inhaltlich übereinstimmen.
#
# Verglichen wird je Tabelle:
#   - COUNT(*)
#   - MAX(timestamp)/MAX(id) wo sinnvoll
#   - Anzahl distincter channels in data/aggregate
#
# Exit-Code 0   = identisch / Ziel >= Quelle (alles gut)
# Exit-Code 1   = Ziel hat weniger Daten als Quelle (Sync unvollständig)
# Exit-Code 2   = Verbindungsfehler / Konfig-Fehler
#
# Verwendung:
#   ./bin/verify_sync.sh                 # nutzt sync_volkszaehler.conf
#   ./bin/verify_sync.sh --strict        # erlaubt KEINE Ziel-Mehrwerte
#   ./bin/verify_sync.sh --quiet         # nur das Endergebnis ausgeben
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONF="$REPO_DIR/sync_volkszaehler.conf"

STRICT=0
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --strict) STRICT=1; shift ;;
        --quiet)  QUIET=1; shift ;;
        --help|-h)
            sed -n '2,/^###/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

[ -f "$CONF" ] || { echo "FEHLER: $CONF nicht gefunden" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONF"

###############################################################################
# Temporäre defaults-extra-files (Passwort nicht in Prozessliste)
###############################################################################
SOURCE_CNF=$(mktemp); chmod 600 "$SOURCE_CNF"
DEST_CNF=$(mktemp);   chmod 600 "$DEST_CNF"
trap 'rm -f "$SOURCE_CNF" "$DEST_CNF"' EXIT INT TERM

cat > "$SOURCE_CNF" <<EOF
[client]
host=$SOURCE_HOST
port=$SOURCE_PORT
user=$SOURCE_USER
password=$SOURCE_PASS
database=$SOURCE_DB
EOF

cat > "$DEST_CNF" <<EOF
[client]
host=$DEST_HOST
port=$DEST_PORT
user=$DEST_USER
password=$DEST_PASS
database=$DEST_DB
EOF

src() { mysql --defaults-extra-file="$SOURCE_CNF" -N -s -e "$1" 2>/dev/null; }
dst() { mysql --defaults-extra-file="$DEST_CNF"   -N -s -e "$1" 2>/dev/null; }

# Verbindungs-Smoketest
src "SELECT 1" >/dev/null || { echo "FEHLER: Quell-DB ($SOURCE_HOST) nicht erreichbar" >&2; exit 2; }
dst "SELECT 1" >/dev/null || { echo "FEHLER: Ziel-DB  ($DEST_HOST) nicht erreichbar" >&2; exit 2; }

###############################################################################
# Hilfsfunktion: Ergebniszeile drucken (mit Pass/Fail-Status)
###############################################################################
RC=0

print_row() {
    local table="$1" col="$2" src_val="$3" dst_val="$4" hint="${5:-}"
    src_val="${src_val:-0}"
    dst_val="${dst_val:-0}"
    local status
    if [ "$STRICT" = "1" ]; then
        if [ "$src_val" = "$dst_val" ]; then status="OK   "
        else status="DIFF "; RC=1; fi
    else
        if [ "$dst_val" -ge "$src_val" ] 2>/dev/null; then status="OK   "
        else status="LOW  "; RC=1; fi
    fi
    [ "$QUIET" = "0" ] && printf "  %s | %-28s %-12s | src=%-15s dst=%-15s %s\n" \
        "$status" "$table" "$col" "$src_val" "$dst_val" "$hint"
}

[ "$QUIET" = "0" ] && {
    echo "=================================================================="
    echo " Verify Volkszähler-Sync"
    echo "   Quelle: $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT/$SOURCE_DB"
    echo "   Ziel  : $DEST_USER@$DEST_HOST:$DEST_PORT/$DEST_DB"
    echo "   Modus : $([ "$STRICT" = 1 ] && echo "STRICT (exakt gleich)" || echo "SOFT (Ziel >= Quelle)")"
    echo "=================================================================="
}

###############################################################################
# Tabellen-Vergleich
###############################################################################
TABLES=(entities properties entities_in_aggregator data aggregate)

for t in "${TABLES[@]}"; do
    s_count=$(src "SELECT COUNT(*) FROM $t;")
    d_count=$(dst "SELECT COUNT(*) FROM $t;")
    print_row "$t" "COUNT(*)" "${s_count:-?}" "${d_count:-?}"

    case "$t" in
        data)
            s_max=$(src "SELECT IFNULL(MAX(timestamp),0) FROM data;")
            d_max=$(dst "SELECT IFNULL(MAX(timestamp),0) FROM data;")
            print_row "$t" "MAX(timestamp)" "${s_max:-0}" "${d_max:-0}" \
                "$( [ -n "$s_max" ] && [ "$s_max" -gt 0 ] && date -d "@$((s_max/1000))" '+%Y-%m-%d_%H:%M' 2>/dev/null )"

            s_ch=$(src "SELECT COUNT(DISTINCT channel_id) FROM data;")
            d_ch=$(dst "SELECT COUNT(DISTINCT channel_id) FROM data;")
            print_row "$t" "DISTINCT channel" "${s_ch:-0}" "${d_ch:-0}"
            ;;
        aggregate)
            s_max=$(src "SELECT IFNULL(MAX(timestamp),0) FROM aggregate;")
            d_max=$(dst "SELECT IFNULL(MAX(timestamp),0) FROM aggregate;")
            print_row "$t" "MAX(timestamp)" "${s_max:-0}" "${d_max:-0}" \
                "$( [ -n "$s_max" ] && [ "$s_max" -gt 0 ] && date -d "@$((s_max/1000))" '+%Y-%m-%d_%H:%M' 2>/dev/null )"
            ;;
        entities)
            s_max=$(src "SELECT IFNULL(MAX(id),0) FROM entities;")
            d_max=$(dst "SELECT IFNULL(MAX(id),0) FROM entities;")
            print_row "$t" "MAX(id)" "${s_max:-0}" "${d_max:-0}"
            ;;
    esac
done

###############################################################################
# Pro-Channel-Vergleich für data (zeigt, ob alle Kanäle aktuell sind)
###############################################################################
[ "$QUIET" = "0" ] && {
    echo "------------------------------------------------------------------"
    echo "Pro-Kanal-Vergleich (data):"
    echo "  channel_id | src_count        dst_count        max_diff(ms)"
    echo "  -----------+----------------------------------------------"
}

while IFS=$'\t' read -r ch s_cnt s_max; do
    [ -z "$ch" ] && continue
    d_cnt=$(dst "SELECT IFNULL(COUNT(*),0) FROM data WHERE channel_id=$ch;")
    d_max=$(dst "SELECT IFNULL(MAX(timestamp),0) FROM data WHERE channel_id=$ch;")
    diff=$(( ${s_max:-0} - ${d_max:-0} ))
    if [ "$STRICT" = "1" ] && [ "$s_cnt" != "$d_cnt" ]; then RC=1; fi
    if [ "$diff" -gt 0 ] 2>/dev/null; then RC=1; fi
    [ "$QUIET" = "0" ] && \
        printf "  %10s | %-16s %-16s %s\n" "$ch" "$s_cnt" "$d_cnt" "$diff"
done < <(src "SELECT channel_id, COUNT(*), IFNULL(MAX(timestamp),0) FROM data GROUP BY channel_id ORDER BY channel_id;")

[ "$QUIET" = "0" ] && {
    echo "=================================================================="
    if [ "$RC" = "0" ]; then
        echo "Ergebnis: OK -- Ziel-DB ist auf dem Stand der Quelle."
    else
        echo "Ergebnis: ABWEICHUNGEN gefunden -- Sync nicht vollständig."
    fi
    echo "=================================================================="
}

exit "$RC"
