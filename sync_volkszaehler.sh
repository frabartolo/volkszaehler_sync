#!/bin/bash

###############################################################################
# Volkszaehler Database Sync Script
# Synchronisiert MariaDB Volkszaehler vom Raspberry Pi zum Hauptrechner
#
# Läuft auf dem Hauptrechner (mehr Ressourcen)
# Für Cron-Betrieb geeignet (mit flock gegen parallele Ausführung)
#
# Cron-Eintrag (alle 5 Minuten):
#   */5 * * * * flock -n /tmp/vz_sync.lock /usr/local/bin/sync_volkszaehler.sh
#
# Autor: Zusammengeführt aus eigenem Entwurf + GitHub Copilot-Vorschlag
###############################################################################

set -eo pipefail  # Abbruch bei Fehler und bei Pipe-Fehlern

###############################################################################
# Konfiguration laden
# Entweder aus sync_volkszaehler.conf (empfohlen) oder Umgebungsvariablen
###############################################################################
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

if [ -f "$SCRIPT_DIR/sync_volkszaehler.conf" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/sync_volkszaehler.conf"
else
    # Fallback: Defaults (bitte in sync_volkszaehler.conf auslagern!)
    SOURCE_HOST="${SOURCE_HOST:-raspi.local}"
    SOURCE_PORT="${SOURCE_PORT:-3306}"
    SOURCE_USER="${SOURCE_USER:-volkszaehler}"
    SOURCE_PASS="${SOURCE_PASS:-}"
    SOURCE_DB="${SOURCE_DB:-volkszaehler}"

    DEST_HOST="${DEST_HOST:-localhost}"
    DEST_PORT="${DEST_PORT:-3306}"
    DEST_USER="${DEST_USER:-volkszaehler}"
    DEST_PASS="${DEST_PASS:-}"
    DEST_DB="${DEST_DB:-volkszaehler}"

    LOG_FILE="${LOG_FILE:-/var/log/volkszaehler_sync.log}"
    VERBOSE="${VERBOSE:-1}"
fi

MAX_LOG_SIZE="${MAX_LOG_SIZE:-$((5 * 1024 * 1024))}"  # 5 MB Standard

###############################################################################
# Temporäre MySQL-Config-Dateien (Passwörter NICHT in Prozessliste sichtbar)
###############################################################################
SOURCE_CNF=""
DEST_CNF=""

###############################################################################
# Cleanup bei Exit, Interrupt oder Fehler
###############################################################################
cleanup() {
    [ -n "$SOURCE_CNF" ] && rm -f "$SOURCE_CNF"
    [ -n "$DEST_CNF" ]   && rm -f "$DEST_CNF"
    rm -f /tmp/vz_sync_*.sql 2>/dev/null || true
}
trap cleanup EXIT INT TERM

###############################################################################
# MySQL-Config-Dateien anlegen (chmod 600 — nur root lesbar)
###############################################################################
setup_mysql_configs() {
    SOURCE_CNF=$(mktemp)
    cat > "$SOURCE_CNF" << EOF
[client]
host=$SOURCE_HOST
port=$SOURCE_PORT
user=$SOURCE_USER
password=$SOURCE_PASS
database=$SOURCE_DB
EOF
    chmod 600 "$SOURCE_CNF"

    DEST_CNF=$(mktemp)
    cat > "$DEST_CNF" << EOF
[client]
host=$DEST_HOST
port=$DEST_PORT
user=$DEST_USER
password=$DEST_PASS
database=$DEST_DB
EOF
    chmod 600 "$DEST_CNF"
}

###############################################################################
# Hilfsfunktionen
###############################################################################
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    [ "${VERBOSE:-1}" -eq 1 ] && echo "$msg"
    [ -n "$LOG_FILE" ] && echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] FEHLER: $1"
    echo "$msg" >&2
    [ -n "$LOG_FILE" ] && echo "$msg" >> "$LOG_FILE"
}

# SQL auf Quell-DB (Raspi) ausführen
source_sql() {
    mysql --defaults-extra-file="$SOURCE_CNF" -N -s -e "$1" 2>>"$LOG_FILE"
}

# SQL auf Ziel-DB (Hauptrechner) ausführen
dest_sql() {
    mysql --defaults-extra-file="$DEST_CNF" -N -s -e "$1" 2>>"$LOG_FILE"
}

# SQL-Datei in Ziel-DB importieren
dest_import() {
    mysql --defaults-extra-file="$DEST_CNF" "$DEST_DB" < "$1" 2>>"$LOG_FILE"
}

# mysqldump von Quell-DB
source_dump() {
    mysqldump \
        --defaults-extra-file="$SOURCE_CNF" \
        --no-create-info \
        --skip-add-drop-table \
        --replace \
        --skip-comments \
        "$@"
}

# Log rotieren wenn zu groß
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "Log rotiert (>${MAX_LOG_SIZE} Bytes)"
    fi
}

###############################################################################
# Verbindungsprüfung
###############################################################################
check_connections() {
    log "Prüfe Verbindung zur Quell-DB ($SOURCE_HOST)..."
    if ! mysql --defaults-extra-file="$SOURCE_CNF" -e "SELECT 1;" > /dev/null 2>&1; then
        log_error "Keine Verbindung zur Quell-DB ($SOURCE_HOST:$SOURCE_PORT)"
        exit 1
    fi
    log "Quell-DB OK"

    log "Prüfe Verbindung zur Ziel-DB ($DEST_HOST)..."
    if ! mysql --defaults-extra-file="$DEST_CNF" -e "SELECT 1;" > /dev/null 2>&1; then
        log_error "Keine Verbindung zur Ziel-DB ($DEST_HOST:$DEST_PORT)"
        exit 1
    fi
    log "Ziel-DB OK"
}

###############################################################################
# Sync: entities
# Vollständiger Abgleich per ON DUPLICATE KEY UPDATE
# (kleine Tabelle, ändert sich selten)
###############################################################################
sync_entities() {
    log "--- Sync: entities ---"

    local tmp_sql
    tmp_sql=$(mktemp /tmp/vz_sync_XXXXXX.sql)

    source_sql "
        SELECT CONCAT(
            'INSERT INTO entities (id, uuid, type, class) VALUES (',
            id, ', ',
            QUOTE(uuid), ', ',
            QUOTE(type), ', ',
            QUOTE(class),
            ') ON DUPLICATE KEY UPDATE uuid=VALUES(uuid), type=VALUES(type), class=VALUES(class);'
        )
        FROM entities;
    " > "$tmp_sql"

    if [ -s "$tmp_sql" ]; then
        dest_import "$tmp_sql" \
            && log "  entities: $(wc -l < "$tmp_sql") Zeilen verarbeitet" \
            || { log_error "Import entities fehlgeschlagen"; rm -f "$tmp_sql"; return 1; }
    else
        log "  entities: keine Daten auf Quelle"
    fi

    rm -f "$tmp_sql"
}

###############################################################################
# Sync: properties
# Vollständiger Abgleich per ON DUPLICATE KEY UPDATE
###############################################################################
sync_properties() {
    log "--- Sync: properties ---"

    local tmp_sql
    tmp_sql=$(mktemp /tmp/vz_sync_XXXXXX.sql)

    source_sql "
        SELECT CONCAT(
            'INSERT INTO properties (pkey, entity_id, value) VALUES (',
            QUOTE(pkey), ', ',
            entity_id, ', ',
            QUOTE(value),
            ') ON DUPLICATE KEY UPDATE value=VALUES(value);'
        )
        FROM properties;
    " > "$tmp_sql"

    if [ -s "$tmp_sql" ]; then
        dest_import "$tmp_sql" \
            && log "  properties: $(wc -l < "$tmp_sql") Zeilen verarbeitet" \
            || { log_error "Import properties fehlgeschlagen"; rm -f "$tmp_sql"; return 1; }
    else
        log "  properties: keine Daten auf Quelle"
    fi

    rm -f "$tmp_sql"
}

###############################################################################
# Sync: entities_in_aggregator
# INSERT IGNORE reicht hier (keine änderbaren Felder, nur PK)
###############################################################################
sync_entities_in_aggregator() {
    log "--- Sync: entities_in_aggregator ---"

    local tmp_sql
    tmp_sql=$(mktemp /tmp/vz_sync_XXXXXX.sql)

    source_sql "
        SELECT CONCAT(
            'INSERT IGNORE INTO entities_in_aggregator (parent_id, child_id) VALUES (',
            parent_id, ', ',
            child_id,
            ');'
        )
        FROM entities_in_aggregator;
    " > "$tmp_sql"

    if [ -s "$tmp_sql" ]; then
        dest_import "$tmp_sql" \
            && log "  entities_in_aggregator: $(wc -l < "$tmp_sql") Zeilen verarbeitet" \
            || { log_error "Import entities_in_aggregator fehlgeschlagen"; rm -f "$tmp_sql"; return 1; }
    else
        log "  entities_in_aggregator: keine Daten auf Quelle"
    fi

    rm -f "$tmp_sql"
}

###############################################################################
# Sync: data
# Inkrementell per MAX(timestamp) pro channel_id
# mysqldump für effizienten Batch-Import (keine zeilenweisen INSERTs)
###############################################################################
sync_data() {
    log "--- Sync: data ---"

    local channel_ids
    channel_ids=$(source_sql "SELECT DISTINCT channel_id FROM data ORDER BY channel_id;") \
        || { log_error "Konnte channel_ids nicht lesen"; return 1; }

    if [ -z "$channel_ids" ]; then
        log "  data: keine Kanäle auf Quelle"
        return
    fi

    local total_new=0

    for channel_id in $channel_ids; do
        # Sicherheitscheck: nur numerische IDs zulassen
        if ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            log_error "Ungültige channel_id übersprungen: $channel_id"
            continue
        fi

        local max_ts
        max_ts=$(dest_sql "SELECT IFNULL(MAX(timestamp), 0) FROM data WHERE channel_id = $channel_id;")
        [[ "$max_ts" =~ ^[0-9]+$ ]] || max_ts=0

        local new_count
        new_count=$(source_sql "SELECT COUNT(*) FROM data WHERE channel_id = $channel_id AND timestamp > $max_ts;")
        [[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0

        if [ "$new_count" -eq 0 ]; then
            log "  channel_id $channel_id: aktuell (MAX ts=$max_ts)"
            continue
        fi

        log "  channel_id $channel_id: $new_count neue Einträge (ab ts=$max_ts)"

        local tmp_sql
        tmp_sql=$(mktemp /tmp/vz_sync_XXXXXX.sql)

        # mysqldump: effizienter Batch-Export (deutlich schneller als zeilenweise INSERTs
        # bei großen Datenmengen, wie sie Volkszähler produziert)
        source_dump \
            --where="channel_id = $channel_id AND timestamp > $max_ts" \
            "$SOURCE_DB" data > "$tmp_sql"

        if [ $? -ne 0 ] || [ ! -s "$tmp_sql" ]; then
            log_error "Dump channel_id $channel_id fehlgeschlagen"
            rm -f "$tmp_sql"
            continue
        fi

        dest_import "$tmp_sql" \
            && log "  channel_id $channel_id: $new_count Einträge importiert" \
            || log_error "Import channel_id $channel_id fehlgeschlagen"

        rm -f "$tmp_sql"
        total_new=$((total_new + new_count))
    done

    log "  data gesamt: $total_new neue Einträge importiert"
}

###############################################################################
# Sync: aggregate
# Inkrementell per MAX(timestamp) pro type + channel_id
# mysqldump für effizienten Batch-Import
###############################################################################
sync_aggregate() {
    log "--- Sync: aggregate ---"

    local total_new=0

    # process substitution verhindert Subshell-Probleme bei while+read
    while IFS=$'\t' read -r agg_type channel_id; do

        if ! [[ "$agg_type" =~ ^[0-9]+$ ]] || ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            log_error "Ungültige type/channel_id übersprungen: $agg_type / $channel_id"
            continue
        fi

        local max_ts
        max_ts=$(dest_sql "SELECT IFNULL(MAX(timestamp), 0) FROM aggregate
            WHERE type = $agg_type AND channel_id = $channel_id;")
        [[ "$max_ts" =~ ^[0-9]+$ ]] || max_ts=0

        local new_count
        new_count=$(source_sql "SELECT COUNT(*) FROM aggregate
            WHERE type = $agg_type AND channel_id = $channel_id AND timestamp > $max_ts;")
        [[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0

        if [ "$new_count" -eq 0 ]; then
            log "  aggregate type=$agg_type channel=$channel_id: aktuell"
            continue
        fi

        log "  aggregate type=$agg_type channel=$channel_id: $new_count neue Einträge"

        local tmp_sql
        tmp_sql=$(mktemp /tmp/vz_sync_XXXXXX.sql)

        source_dump \
            --where="type = $agg_type AND channel_id = $channel_id AND timestamp > $max_ts" \
            "$SOURCE_DB" aggregate > "$tmp_sql"

        if [ $? -ne 0 ] || [ ! -s "$tmp_sql" ]; then
            log_error "Dump aggregate type=$agg_type channel=$channel_id fehlgeschlagen"
            rm -f "$tmp_sql"
            continue
        fi

        dest_import "$tmp_sql" \
            && log "  aggregate type=$agg_type channel=$channel_id: importiert" \
            || log_error "Import aggregate type=$agg_type channel=$channel_id fehlgeschlagen"

        rm -f "$tmp_sql"
        total_new=$((total_new + new_count))

    done < <(source_sql "SELECT DISTINCT type, channel_id FROM aggregate ORDER BY type, channel_id;")

    log "  aggregate gesamt: $total_new neue Einträge importiert"
}

###############################################################################
# Main
###############################################################################
main() {
    rotate_log
    log "========== Sync gestartet =========="

    setup_mysql_configs
    check_connections

    # Erst Stammdaten (entities, properties, Beziehungen)
    sync_entities               || { log_error "Abbruch bei entities";                exit 1; }
    sync_properties             || { log_error "Abbruch bei properties";              exit 1; }
    sync_entities_in_aggregator || { log_error "Abbruch bei entities_in_aggregator"; exit 1; }

    # Dann Zeitreihendaten
    sync_data                   || { log_error "Abbruch bei data";                    exit 1; }
    sync_aggregate              || { log_error "Abbruch bei aggregate";               exit 1; }

    log "========== Sync erfolgreich abgeschlossen =========="
}

main "$@"
