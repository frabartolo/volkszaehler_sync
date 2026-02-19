#!/bin/bash

###############################################################################
# Volkszaehler Database Sync Script
# Synchronizes MariaDB Volkszaehler database from Raspberry Pi to main computer
# 
# This script should be run on the main computer (has more resources)
# It can be added to cron for automatic synchronization
###############################################################################

set -eo pipefail  # Exit on error and handle pipe failures

# Configuration - adjust these values or source from a config file
if [ -f "$(dirname "$0")/sync_volkszaehler.conf" ]; then
    source "$(dirname "$0")/sync_volkszaehler.conf"
else
    # Source Database (Raspberry Pi)
    SOURCE_HOST="${SOURCE_HOST:-raspi}"
    SOURCE_PORT="${SOURCE_PORT:-3306}"
    SOURCE_USER="${SOURCE_USER:-volkszaehler}"
    SOURCE_PASS="${SOURCE_PASS:-}"
    SOURCE_DB="${SOURCE_DB:-volkszaehler}"

    # Destination Database (Main Computer)
    DEST_HOST="${DEST_HOST:-localhost}"
    DEST_PORT="${DEST_PORT:-3306}"
    DEST_USER="${DEST_USER:-volkszaehler}"
    DEST_PASS="${DEST_PASS:-}"
    DEST_DB="${DEST_DB:-volkszaehler}"
fi

# Logging
LOG_FILE="${LOG_FILE:-/var/log/volkszaehler_sync.log}"
VERBOSE="${VERBOSE:-1}"

# Temporary files for MySQL config (to avoid password in process list)
SOURCE_CNF=""
DEST_CNF=""

###############################################################################
# Helper Functions
###############################################################################

cleanup() {
    # Clean up temporary config files
    [ -n "$SOURCE_CNF" ] && rm -f "$SOURCE_CNF"
    [ -n "$DEST_CNF" ] && rm -f "$DEST_CNF"
}

trap cleanup EXIT INT TERM

setup_mysql_config() {
    # Create temporary MySQL config files to avoid password exposure
    if [ -n "$SOURCE_PASS" ]; then
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
    fi

    if [ -n "$DEST_PASS" ]; then
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
    fi
}

mysql_source() {
    if [ -n "$SOURCE_CNF" ]; then
        mysql --defaults-extra-file="$SOURCE_CNF" -N -s "$@"
    else
        mysql -h"$SOURCE_HOST" -P"$SOURCE_PORT" -u"$SOURCE_USER" "$SOURCE_DB" -N -s "$@"
    fi
}

mysql_dest() {
    if [ -n "$DEST_CNF" ]; then
        mysql --defaults-extra-file="$DEST_CNF" -N -s "$@"
    else
        mysql -h"$DEST_HOST" -P"$DEST_PORT" -u"$DEST_USER" "$DEST_DB" -N -s "$@"
    fi
}

log_message() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    if [ "$VERBOSE" -eq 1 ]; then
        echo "$message"
    fi
    if [ -n "$LOG_FILE" ]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

log_error() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1"
    echo "$message" >&2
    if [ -n "$LOG_FILE" ]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

check_connection() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    local db=$5
    
    if [ -n "$pass" ]; then
        local tmp_cnf=$(mktemp)
        cat > "$tmp_cnf" << EOF
[client]
host=$host
port=$port
user=$user
password=$pass
database=$db
EOF
        chmod 600 "$tmp_cnf"
        if ! mysql --defaults-extra-file="$tmp_cnf" -e "USE ${db};" 2>/dev/null; then
            rm -f "$tmp_cnf"
            return 1
        fi
        rm -f "$tmp_cnf"
    else
        if ! mysql -h"${host}" -P"${port}" -u"${user}" -e "USE ${db};" 2>/dev/null; then
            return 1
        fi
    fi
    return 0
}

###############################################################################
# Sync Functions
###############################################################################

sync_entities() {
    log_message "Syncing entities table..."
    
    # Create a temporary SQL file for bulk insert
    local tmp_sql=$(mktemp)
    
    # Generate INSERT statements with proper escaping
    mysql_source -e "
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
    
    # Execute the bulk insert
    if [ -s "$tmp_sql" ]; then
        mysql_dest < "$tmp_sql"
        local count=$(wc -l < "$tmp_sql")
        log_message "Synced $count entities"
    fi
    
    rm -f "$tmp_sql"
    log_message "Entities sync completed."
}

sync_properties() {
    log_message "Syncing properties table..."
    
    # Create a temporary SQL file for bulk insert
    local tmp_sql=$(mktemp)
    
    # Generate INSERT statements with proper escaping
    mysql_source -e "
        SELECT CONCAT(
            'INSERT INTO properties (pkey, entity_id, value) VALUES (',
            QUOTE(pkey), ', ',
            entity_id, ', ',
            QUOTE(value),
            ') ON DUPLICATE KEY UPDATE value=VALUES(value);'
        )
        FROM properties;
    " > "$tmp_sql"
    
    # Execute the bulk insert
    if [ -s "$tmp_sql" ]; then
        mysql_dest < "$tmp_sql"
        local count=$(wc -l < "$tmp_sql")
        log_message "Synced $count properties"
    fi
    
    rm -f "$tmp_sql"
    log_message "Properties sync completed."
}

sync_entities_in_aggregator() {
    log_message "Syncing entities_in_aggregator table..."
    
    # Create a temporary SQL file for bulk insert
    local tmp_sql=$(mktemp)
    
    # Generate INSERT statements
    mysql_source -e "
        SELECT CONCAT(
            'INSERT IGNORE INTO entities_in_aggregator (parent_id, child_id) VALUES (',
            parent_id, ', ',
            child_id,
            ');'
        )
        FROM entities_in_aggregator;
    " > "$tmp_sql"
    
    # Execute the bulk insert
    if [ -s "$tmp_sql" ]; then
        mysql_dest < "$tmp_sql"
        local count=$(wc -l < "$tmp_sql")
        log_message "Synced $count aggregator relationships"
    fi
    
    rm -f "$tmp_sql"
    log_message "Entities_in_aggregator sync completed."
}

sync_data() {
    log_message "Syncing data table..."
    
    # Get all channel_ids from source
    local channel_ids=$(mysql_source -e "SELECT DISTINCT channel_id FROM data;")
    
    for channel_id in $channel_ids; do
        # Validate channel_id is numeric
        if ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            log_error "Invalid channel_id: $channel_id"
            continue
        fi
        
        # Get highest timestamp for this channel in destination
        local max_timestamp=$(mysql_dest -e "SELECT IFNULL(MAX(timestamp), 0) FROM data WHERE channel_id = $channel_id;")
        
        # Validate max_timestamp is numeric
        if ! [[ "$max_timestamp" =~ ^[0-9]+$ ]]; then
            max_timestamp=0
        fi
        
        log_message "Channel $channel_id: Syncing data after timestamp $max_timestamp"
        
        # Get count of new records
        local new_count=$(mysql_source -e "SELECT COUNT(*) FROM data WHERE channel_id = $channel_id AND timestamp > $max_timestamp;")
        
        if [ "$new_count" -gt 0 ]; then
            log_message "Found $new_count new records for channel $channel_id"
            
            # Create a temporary SQL file for bulk insert
            local tmp_sql=$(mktemp)
            
            # Generate INSERT statements for new data
            mysql_source -e "
                SELECT CONCAT(
                    'INSERT INTO data (timestamp, channel_id, value) VALUES (',
                    timestamp, ', ',
                    channel_id, ', ',
                    value,
                    ') ON DUPLICATE KEY UPDATE value=VALUES(value);'
                )
                FROM data
                WHERE channel_id = $channel_id AND timestamp > $max_timestamp
                ORDER BY timestamp;
            " > "$tmp_sql"
            
            # Execute the bulk insert
            if [ -s "$tmp_sql" ]; then
                mysql_dest < "$tmp_sql"
            fi
            
            rm -f "$tmp_sql"
        fi
    done
    
    log_message "Data sync completed."
}

sync_aggregate() {
    log_message "Syncing aggregate table..."
    
    # Get all unique type and channel_id combinations from source
    mysql_source -e "SELECT DISTINCT type, channel_id FROM aggregate;" | while IFS=$'\t' read -r type channel_id; do
        # Validate inputs are numeric
        if ! [[ "$type" =~ ^[0-9]+$ ]] || ! [[ "$channel_id" =~ ^[0-9]+$ ]]; then
            log_error "Invalid type or channel_id: $type, $channel_id"
            continue
        fi
        
        # Get highest timestamp for this type and channel in destination
        local max_timestamp=$(mysql_dest -e "SELECT IFNULL(MAX(timestamp), 0) FROM aggregate WHERE type = $type AND channel_id = $channel_id;")
        
        # Validate max_timestamp is numeric
        if ! [[ "$max_timestamp" =~ ^[0-9]+$ ]]; then
            max_timestamp=0
        fi
        
        log_message "Type $type, Channel $channel_id: Syncing aggregates after timestamp $max_timestamp"
        
        # Get count of new records
        local new_count=$(mysql_source -e "SELECT COUNT(*) FROM aggregate WHERE type = $type AND channel_id = $channel_id AND timestamp > $max_timestamp;")
        
        if [ "$new_count" -gt 0 ]; then
            log_message "Found $new_count new aggregate records for type $type, channel $channel_id"
            
            # Create a temporary SQL file for bulk insert
            local tmp_sql=$(mktemp)
            
            # Generate INSERT statements for new aggregates
            mysql_source -e "
                SELECT CONCAT(
                    'INSERT INTO aggregate (type, timestamp, channel_id, value, count) VALUES (',
                    type, ', ',
                    timestamp, ', ',
                    channel_id, ', ',
                    value, ', ',
                    count,
                    ') ON DUPLICATE KEY UPDATE value=VALUES(value), count=VALUES(count);'
                )
                FROM aggregate
                WHERE type = $type AND channel_id = $channel_id AND timestamp > $max_timestamp
                ORDER BY timestamp;
            " > "$tmp_sql"
            
            # Execute the bulk insert
            if [ -s "$tmp_sql" ]; then
                mysql_dest < "$tmp_sql"
            fi
            
            rm -f "$tmp_sql"
        fi
    done
    
    log_message "Aggregate sync completed."
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_message "=== Starting Volkszaehler Database Sync ==="
    
    # Setup MySQL configuration files
    setup_mysql_config
    
    # Check connections
    log_message "Checking source database connection..."
    if ! check_connection "$SOURCE_HOST" "$SOURCE_PORT" "$SOURCE_USER" "$SOURCE_PASS" "$SOURCE_DB"; then
        log_error "Failed to connect to source database at ${SOURCE_HOST}:${SOURCE_PORT}"
        exit 1
    fi
    log_message "Source database connection OK"
    
    log_message "Checking destination database connection..."
    if ! check_connection "$DEST_HOST" "$DEST_PORT" "$DEST_USER" "$DEST_PASS" "$DEST_DB"; then
        log_error "Failed to connect to destination database at ${DEST_HOST}:${DEST_PORT}"
        exit 1
    fi
    log_message "Destination database connection OK"
    
    # Sync tables in order
    # First sync master data (entities, properties, relationships)
    sync_entities
    sync_properties
    sync_entities_in_aggregator
    
    # Then sync time-series data
    sync_data
    sync_aggregate
    
    log_message "=== Volkszaehler Database Sync Completed Successfully ==="
}

# Run main function
main "$@"
