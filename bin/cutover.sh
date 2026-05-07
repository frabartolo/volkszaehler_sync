#!/bin/bash
###############################################################################
# cutover.sh
#
# One-shot-Cutover-Orchestrator für die einmalige Migration der
# Volkszähler-Datenbank von Raspi (Quelle) auf cold-lairs (Ziel).
#
# Ablauf:
#   Phase 1  Vor-Checks (Verbindungen, Schema, Disk Space, Daemon-Status)
#   Phase 2  Großer Sync unter laufendem Betrieb (kann lange dauern)
#   Phase 3  vzlogger auf dem Raspi stoppen      (manueller User-Schritt)
#   Phase 4  Finaler Delta-Sync (kurz)
#   Phase 5  Verify (Counts/Max-Timestamps)
#   Phase 6  Anweisungen für den finalen Switch (Middleware-Config / vzlogger)
#
# Das Skript ist in jeder Phase abbruch-/wiederholbar. Idempotent.
#
# Verwendung:
#   ./bin/cutover.sh                 # alle Phasen interaktiv durchgehen
#   ./bin/cutover.sh --phase 4       # ab Phase 4 weitermachen
#   ./bin/cutover.sh --yes           # nicht nachfragen (für Re-Runs)
#   ./bin/cutover.sh --dry-run       # nur prüfen, nichts schreiben
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
SYNC_SCRIPT="$REPO_DIR/sync_volkszaehler.sh"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_sync.sh"
CONF="$REPO_DIR/sync_volkszaehler.conf"

START_PHASE=1
NONINTERACTIVE=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --phase) START_PHASE="$2"; shift 2 ;;
        --yes|-y) NONINTERACTIVE=1; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --help|-h)
            sed -n '2,/^###/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; exit 2 ;;
    esac
done

###############################################################################
# Logging
###############################################################################
LOG_DIR="$REPO_DIR/logs"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/cutover_$(date +%Y%m%d_%H%M%S).log"

c_red='\033[0;31m'; c_grn='\033[0;32m'; c_yel='\033[0;33m'; c_blu='\033[0;34m'; c_off='\033[0m'

say()  { printf "${c_blu}== %s ==${c_off}\n" "$*" | tee -a "$RUN_LOG"; }
ok()   { printf "  ${c_grn}\xe2\x9c\x93 %s${c_off}\n" "$*" | tee -a "$RUN_LOG"; }
warn() { printf "  ${c_yel}! %s${c_off}\n" "$*" | tee -a "$RUN_LOG"; }
err()  { printf "  ${c_red}\xe2\x9c\x97 %s${c_off}\n" "$*" | tee -a "$RUN_LOG" >&2; }
info() { printf "    %s\n" "$*" | tee -a "$RUN_LOG"; }

confirm() {
    local prompt="$1"
    if [ "$NONINTERACTIVE" = "1" ]; then return 0; fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[YyJj]$ ]]
}

require_yes() {
    local prompt="$1"
    if [ "$NONINTERACTIVE" = "1" ]; then return 0; fi
    while true; do
        read -r -p "$prompt [yes/abort] " ans
        case "$ans" in
            yes)   return 0 ;;
            abort) err "Abbruch durch Benutzer."; exit 130 ;;
        esac
    done
}

###############################################################################
# Konfig laden
###############################################################################
[ -f "$CONF" ] || { err "$CONF fehlt"; info "Hinweis: zuerst sync_volkszaehler.conf.example kopieren und anpassen."; exit 2; }
# shellcheck source=/dev/null
source "$CONF"

[ -x "$SYNC_SCRIPT" ]   || { err "$SYNC_SCRIPT nicht ausführbar"; exit 2; }
[ -x "$VERIFY_SCRIPT" ] || { err "$VERIFY_SCRIPT nicht ausführbar"; exit 2; }

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

src() { mysql --defaults-extra-file="$SOURCE_CNF" -N -s -e "$1" 2>>"$RUN_LOG"; }
dst() { mysql --defaults-extra-file="$DEST_CNF"   -N -s -e "$1" 2>>"$RUN_LOG"; }

###############################################################################
# Phase 1 -- Vor-Checks
###############################################################################
phase1_precheck() {
    say "Phase 1 - Vor-Checks"

    info "Quelle:  $SOURCE_USER@$SOURCE_HOST:$SOURCE_PORT/$SOURCE_DB"
    info "Ziel:    $DEST_USER@$DEST_HOST:$DEST_PORT/$DEST_DB"

    # Verbindungen
    if mysql --defaults-extra-file="$SOURCE_CNF" -e "SELECT 1" >/dev/null 2>>"$RUN_LOG"; then
        ok "Quell-DB erreichbar"
    else
        err "Quell-DB nicht erreichbar -- Verbindung/Credentials prüfen"; return 1
    fi
    if mysql --defaults-extra-file="$DEST_CNF" -e "SELECT 1" >/dev/null 2>>"$RUN_LOG"; then
        ok "Ziel-DB erreichbar"
    else
        err "Ziel-DB nicht erreichbar -- Verbindung/Credentials prüfen"; return 1
    fi

    # Tabellen-Existenz
    local missing=()
    for t in entities properties entities_in_aggregator data aggregate; do
        local exists
        exists=$(dst "SHOW TABLES LIKE '$t';" || true)
        [ -n "$exists" ] || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        err "Auf Ziel fehlen Tabellen: ${missing[*]}"
        info "Schema vor dem Sync anlegen, z.B. mit:"
        info "  mysqldump --defaults-extra-file=$SOURCE_CNF --no-data $SOURCE_DB | mysql --defaults-extra-file=$DEST_CNF $DEST_DB"
        return 1
    fi
    ok "Alle benötigten Tabellen existieren auf Ziel"

    # Schema-Hash-Vergleich (best effort)
    local s_chk d_chk
    s_chk=$(src "SELECT GROUP_CONCAT(table_name,':',column_name,':',column_type ORDER BY table_name,ordinal_position) FROM information_schema.columns WHERE table_schema='$SOURCE_DB' AND table_name IN ('entities','properties','entities_in_aggregator','data','aggregate');")
    d_chk=$(dst "SELECT GROUP_CONCAT(table_name,':',column_name,':',column_type ORDER BY table_name,ordinal_position) FROM information_schema.columns WHERE table_schema='$DEST_DB'   AND table_name IN ('entities','properties','entities_in_aggregator','data','aggregate');")
    if [ "$s_chk" = "$d_chk" ]; then
        ok "Schemas Quell-/Ziel-DB sind identisch"
    else
        warn "Schemas unterscheiden sich -- Migration kann trotzdem klappen, aber prüfe ggf. Spalten."
    fi

    # Daten-Volumen
    local s_data_count s_agg_count
    s_data_count=$(src "SELECT COUNT(*) FROM data;" || echo "?")
    s_agg_count=$(src "SELECT COUNT(*) FROM aggregate;" || echo "?")
    info "Zeilen auf Quelle: data=$s_data_count, aggregate=$s_agg_count"

    # Disk Space auf cold-lairs (~Datenverzeichnis)
    local datadir
    datadir=$(dst "SELECT @@datadir;" || echo "")
    if [ -n "$datadir" ]; then
        info "MySQL-datadir auf Ziel: $datadir"
        df -h "$datadir" 2>/dev/null | awk 'NR<=2' | tee -a "$RUN_LOG" || true
    fi

    # vzlogger-Status auf Quelle (nur Hinweis)
    info "vzlogger-Status auf Raspi prüfst du bitte selbst: ssh $SOURCE_HOST 'systemctl status vzlogger'"

    ok "Phase 1 abgeschlossen"
}

###############################################################################
# Phase 2 -- Großer Sync unter laufendem Betrieb
#
# Volkszähler liefert weiter Daten an den Raspi -- der Sync zieht alles bis jetzt.
# Sehr lange beim Erstlauf (data-Tabelle), beim Re-Run nur Delta seit letztem Lauf.
###############################################################################
phase2_bulk_sync() {
    say "Phase 2 - Großer Sync (kann lange dauern)"

    info "Hinweis: Das Skript ist idempotent. Falls es abbricht, einfach erneut aufrufen."
    if [ "$DRY_RUN" = "1" ]; then
        warn "DRY-RUN: Skipping sync"
        return 0
    fi
    confirm "Bulk-Sync jetzt starten?" || { warn "Phase 2 übersprungen"; return 0; }

    local t0 t1
    t0=$(date +%s)
    if "$SYNC_SCRIPT" 2>&1 | tee -a "$RUN_LOG"; then
        t1=$(date +%s)
        ok "Bulk-Sync abgeschlossen in $((t1 - t0)) s"
    else
        err "Bulk-Sync abgebrochen -- siehe $RUN_LOG"
        return 1
    fi
}

###############################################################################
# Phase 3 -- vzlogger / middleware auf Raspi stoppen
#
# WICHTIG: Hier hört die Quelle auf, neue Daten zu schreiben.
# Wir bestätigen das vom User explizit.
###############################################################################
phase3_stop_source() {
    say "Phase 3 - Daemon auf Raspi stoppen"

    cat | tee -a "$RUN_LOG" <<EOF

  Bitte JETZT auf dem Raspi den vzlogger und (falls dort) die Middleware stoppen,
  damit keine neuen Daten mehr in die Quell-DB geschrieben werden.

  Beispiel (auf dem Raspi):
      sudo systemctl stop vzlogger
      sudo systemctl stop apache2          # falls Middleware lokal läuft
      # oder php-fpm/nginx -- je nach Setup

  Tipp -- per SSH von hier aus:
      ssh $SOURCE_HOST 'sudo systemctl stop vzlogger'

EOF

    if [ "$DRY_RUN" = "1" ]; then warn "DRY-RUN: skip stop"; return 0; fi

    require_yes "Hast du vzlogger auf dem Raspi gestoppt? Tippe 'yes' zum Fortfahren oder 'abort'"

    # Sanity-Check: liefert die Quelle noch neue Daten?
    local before after
    before=$(src "SELECT IFNULL(MAX(timestamp),0) FROM data;" || echo "")
    info "MAX(timestamp) Quelle direkt nach Stop: $before"
    info "Warte 30 s und prüfe nochmal …"
    sleep 30
    after=$(src "SELECT IFNULL(MAX(timestamp),0) FROM data;" || echo "")
    info "MAX(timestamp) Quelle 30 s später:     $after"
    if [ "$before" = "$after" ]; then
        ok "Keine neuen Daten mehr -- Quelle ist eingefroren."
    else
        warn "Quelle schreibt weiter Daten ($before -> $after). Daemon nicht wirklich gestoppt?"
        require_yes "Trotzdem fortfahren? 'yes' / 'abort'"
    fi
}

###############################################################################
# Phase 4 -- Finaler Delta-Sync
###############################################################################
phase4_final_sync() {
    say "Phase 4 - Finaler Delta-Sync"

    if [ "$DRY_RUN" = "1" ]; then warn "DRY-RUN: skip final sync"; return 0; fi

    if "$SYNC_SCRIPT" 2>&1 | tee -a "$RUN_LOG"; then
        ok "Finaler Sync abgeschlossen"
    else
        err "Finaler Sync fehlgeschlagen -- siehe $RUN_LOG"
        return 1
    fi
}

###############################################################################
# Phase 5 -- Verify
###############################################################################
phase5_verify() {
    say "Phase 5 - Verify"

    if "$VERIFY_SCRIPT" --strict 2>&1 | tee -a "$RUN_LOG"; then
        ok "Verify (strict) erfolgreich -- Ziel ist 1:1 mit Quelle"
    else
        warn "Verify im STRICT-Modus zeigt Differenzen. Prüfe das Log:"
        info "  $RUN_LOG"
        warn "Hinweis: 'Ziel >= Quelle' kann ok sein, wenn Ziel schon Vorbestand hatte."
        confirm "Trotzdem als erfolgreich werten?" || return 1
    fi
}

###############################################################################
# Phase 6 -- Switch-Anleitung
###############################################################################
phase6_switch_instructions() {
    say "Phase 6 - Cutover - Anwendungs-Switch"

    cat | tee -a "$RUN_LOG" <<EOF

  Die Daten sind jetzt auf cold-lairs -- nun die Volkszähler-Anwendung umstellen:

  1) Backup der Raspi-DB anlegen (zur Sicherheit):
       ssh $SOURCE_HOST 'sudo mysqldump --single-transaction $SOURCE_DB | gzip > /tmp/volkszaehler_$(date +%Y%m%d).sql.gz'

  2) Middleware-Konfiguration auf cold-lairs (oder wo sie läuft) anpassen:
       Pfad ist meist /var/www/volkszaehler.org/etc/config.yaml
       db.default.host:     $DEST_HOST  (bzw. localhost wenn Middleware auf cold-lairs läuft)
       db.default.dbname:   $DEST_DB
       db.default.user:     $DEST_USER
       db.default.password: <s.o.>

  3) vzlogger auf dem Raspi auf die neue Middleware zeigen lassen:
       /etc/vzlogger.conf -> "middleware": "http://<host>/middleware.php/"
       (zeigt jetzt auf den cold-lairs-Host bzw. weiter auf den Raspi-httpd,
        sofern der Middleware lokal weiter laufen lässt -- nur die DB-Backend-
        Verbindung wandert.)

  4) Dienste neu starten:
       ssh $SOURCE_HOST 'sudo systemctl start vzlogger'
       # ggf. Apache/PHP-FPM je nach Setup

  5) Funktionstest:
       - Frontend laden, ein paar Channels öffnen, "now"-Werte prüfen
       - In der DB auf cold-lairs schauen, ob neue Zeilen reinkommen:
           SELECT MAX(timestamp), FROM_UNIXTIME(MAX(timestamp)/1000) FROM data;

  6) Wenn alles 24h stabil läuft: alte Raspi-DB stoppen / read-only setzen.
       Nicht vorher löschen -- als Fallback behalten!

EOF

    ok "Phase 6 - Anleitung ausgegeben. Manuelle Schritte erforderlich."
}

###############################################################################
# Main -- Phasen-Steuerung
###############################################################################
say "Cutover gestartet -- Log: $RUN_LOG"
[ "$DRY_RUN" = "1" ] && warn "DRY-RUN aktiv: Sync-Aufrufe werden übersprungen."

case "$START_PHASE" in
    1) phase1_precheck && phase2_bulk_sync && phase3_stop_source && phase4_final_sync && phase5_verify && phase6_switch_instructions ;;
    2) phase2_bulk_sync && phase3_stop_source && phase4_final_sync && phase5_verify && phase6_switch_instructions ;;
    3) phase3_stop_source && phase4_final_sync && phase5_verify && phase6_switch_instructions ;;
    4) phase4_final_sync && phase5_verify && phase6_switch_instructions ;;
    5) phase5_verify && phase6_switch_instructions ;;
    6) phase6_switch_instructions ;;
    *) err "Unbekannte Phase: $START_PHASE"; exit 2 ;;
esac

RC=$?
[ "$RC" = "0" ] && say "Cutover erfolgreich. Log: $RUN_LOG" || err "Cutover ABGEBROCHEN. Log: $RUN_LOG"
exit "$RC"
