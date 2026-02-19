#!/bin/bash

###############################################################################
# Volkszaehler Database Sync Script
# Synchronizes MariaDB Volkszaehler database from Raspberry Pi to main computer
# 
# This script should be run on the main computer (has more resources)
# It can be added to cron for automatic synchronization
###############################################################################

set -e  # Exit on error

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

# MySQL command aliases
MYSQL_SOURCE="mysql -h${SOURCE_HOST} -P${SOURCE_PORT} -u${SOURCE_USER} ${SOURCE_PASS:+-p$SOURCE_PASS} ${SOURCE_DB} -N -s"
MYSQL_DEST="mysql -h${DEST_HOST} -P${DEST_PORT} -u${DEST_USER} ${DEST_PASS:+-p$DEST_PASS} ${DEST_DB} -N -s"

###############################################################################
# Helper Functions
###############################################################################

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
    
    if ! mysql -h"${host}" -P"${port}" -u"${user}" ${pass:+-p"$pass"} -e "USE ${db};" 2>/dev/null; then
        return 1
    fi
    return 0
}

###############################################################################
# Sync Functions
###############################################################################

sync_entities() {
    log_message "Syncing entities table..."
    
    # Get all entities from source
    $MYSQL_SOURCE -e "SELECT id, uuid, type, class FROM entities;" | while IFS=$'\t' read -r id uuid type class; do
        # Check if entity exists in destination
        exists=$($MYSQL_DEST -e "SELECT COUNT(*) FROM entities WHERE id = $id;")
        
        if [ "$exists" -eq 0 ]; then
            # Insert new entity
            $MYSQL_DEST -e "INSERT INTO entities (id, uuid, type, class) VALUES ($id, '$uuid', '$type', '$class') ON DUPLICATE KEY UPDATE uuid='$uuid', type='$type', class='$class';"
        else
            # Update existing entity
            $MYSQL_DEST -e "UPDATE entities SET uuid='$uuid', type='$type', class='$class' WHERE id=$id;"
        fi
    done
    
    log_message "Entities sync completed."
}

sync_properties() {
    log_message "Syncing properties table..."
    
    # Get all properties from source
    $MYSQL_SOURCE -e "SELECT pkey, entity_id, value FROM properties;" | while IFS=$'\t' read -r pkey entity_id value; do
        # Escape single quotes in value
        value_escaped=$(echo "$value" | sed "s/'/''/g")
        
        # Insert or update property
        $MYSQL_DEST -e "INSERT INTO properties (pkey, entity_id, value) VALUES ('$pkey', $entity_id, '$value_escaped') ON DUPLICATE KEY UPDATE value='$value_escaped';"
    done
    
    log_message "Properties sync completed."
}

sync_entities_in_aggregator() {
    log_message "Syncing entities_in_aggregator table..."
    
    # Get all relationships from source
    $MYSQL_SOURCE -e "SELECT parent_id, child_id FROM entities_in_aggregator;" | while IFS=$'\t' read -r parent_id child_id; do
        # Insert relationship (ignore duplicates)
        $MYSQL_DEST -e "INSERT IGNORE INTO entities_in_aggregator (parent_id, child_id) VALUES ($parent_id, $child_id);"
    done
    
    log_message "Entities_in_aggregator sync completed."
}

sync_data() {
    log_message "Syncing data table..."
    
    # Get all channel_ids from source
    channel_ids=$($MYSQL_SOURCE -e "SELECT DISTINCT channel_id FROM data;")
    
    for channel_id in $channel_ids; do
        # Get highest timestamp for this channel in destination
        max_timestamp=$($MYSQL_DEST -e "SELECT IFNULL(MAX(timestamp), 0) FROM data WHERE channel_id = $channel_id;")
        
        log_message "Channel $channel_id: Syncing data after timestamp $max_timestamp"
        
        # Get count of new records
        new_count=$($MYSQL_SOURCE -e "SELECT COUNT(*) FROM data WHERE channel_id = $channel_id AND timestamp > $max_timestamp;")
        
        if [ "$new_count" -gt 0 ]; then
            log_message "Found $new_count new records for channel $channel_id"
            
            # Fetch new data from source and insert into destination
            # Use batching for better performance
            $MYSQL_SOURCE -e "SELECT timestamp, channel_id, value FROM data WHERE channel_id = $channel_id AND timestamp > $max_timestamp ORDER BY timestamp;" | while IFS=$'\t' read -r timestamp ch_id value; do
                $MYSQL_DEST -e "INSERT INTO data (timestamp, channel_id, value) VALUES ($timestamp, $ch_id, $value) ON DUPLICATE KEY UPDATE value=$value;"
            done
        fi
    done
    
    log_message "Data sync completed."
}

sync_aggregate() {
    log_message "Syncing aggregate table..."
    
    # Get all unique type and channel_id combinations from source
    $MYSQL_SOURCE -e "SELECT DISTINCT type, channel_id FROM aggregate;" | while IFS=$'\t' read -r type channel_id; do
        # Get highest timestamp for this type and channel in destination
        max_timestamp=$($MYSQL_DEST -e "SELECT IFNULL(MAX(timestamp), 0) FROM aggregate WHERE type = $type AND channel_id = $channel_id;")
        
        log_message "Type $type, Channel $channel_id: Syncing aggregates after timestamp $max_timestamp"
        
        # Get count of new records
        new_count=$($MYSQL_SOURCE -e "SELECT COUNT(*) FROM aggregate WHERE type = $type AND channel_id = $channel_id AND timestamp > $max_timestamp;")
        
        if [ "$new_count" -gt 0 ]; then
            log_message "Found $new_count new aggregate records for type $type, channel $channel_id"
            
            # Fetch new aggregates from source and insert into destination
            $MYSQL_SOURCE -e "SELECT type, timestamp, channel_id, value, count FROM aggregate WHERE type = $type AND channel_id = $channel_id AND timestamp > $max_timestamp ORDER BY timestamp;" | while IFS=$'\t' read -r agg_type timestamp ch_id value count; do
                $MYSQL_DEST -e "INSERT INTO aggregate (type, timestamp, channel_id, value, count) VALUES ($agg_type, $timestamp, $ch_id, $value, $count) ON DUPLICATE KEY UPDATE value=$value, count=$count;"
            done
        fi
    done
    
    log_message "Aggregate sync completed."
}

###############################################################################
# Main Execution
###############################################################################

main() {
    log_message "=== Starting Volkszaehler Database Sync ==="
    
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
