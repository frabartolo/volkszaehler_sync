#!/bin/bash
###############################################################################
# Volkszaehler Sync - Testskript
# Prüft Syntax, Struktur und Konfiguration ohne echte Datenbankverbindung
###############################################################################

SCRIPT="sync_volkszaehler.sh"
CONF_EXAMPLE="sync_volkszaehler.conf.example"
ERRORS=0

ok()   { echo "   ✓ $1"; }
fail() { echo "   ✗ $1"; ERRORS=$((ERRORS + 1)); }

echo "=== Volkszaehler Sync - Strukturtest ==="
echo ""

# 1. Syntax
echo "1. Syntax-Check..."
if bash -n "$SCRIPT" 2>/dev/null; then
    ok "Syntax OK"
else
    fail "Syntaxfehler in $SCRIPT"
fi

# 2. Ausführbar
echo ""
echo "2. Ausführbarkeit..."
if [ -x "$SCRIPT" ]; then
    ok "Skript ist ausführbar"
else
    fail "Skript ist nicht ausführbar (chmod +x $SCRIPT)"
fi

# 3. Config-Beispiel vorhanden
echo ""
echo "3. Konfigurationsdatei..."
if [ -f "$CONF_EXAMPLE" ]; then
    ok "Beispiel-Konfiguration vorhanden"
    echo ""
    echo "   Konfigurationsparameter:"
    grep -E "^(SOURCE_|DEST_|LOG_|VERBOSE|MAX_LOG)" "$CONF_EXAMPLE" \
        | grep -v "^#" | sed 's/=.*//' | sed 's/^/     - /'
else
    fail "Beispiel-Konfiguration nicht gefunden: $CONF_EXAMPLE"
fi

# 4. Sync-Funktionen
echo ""
echo "4. Sync-Funktionen im Skript..."
FUNCS=$(grep -c "^sync_" "$SCRIPT" 2>/dev/null || echo 0)
ok "Gefundene Sync-Funktionen: $FUNCS"
grep "^sync_" "$SCRIPT" | sed 's/() {//' | sed 's/^/     - /'

# 5. Sicherheits-Features
echo ""
echo "5. Sicherheits-Features..."
grep -q "defaults-extra-file" "$SCRIPT" \
    && ok "Passwörter über .cnf-Datei (nicht in Prozessliste sichtbar)" \
    || fail "Passwörter werden unsicher übergeben"

grep -q "chmod 600" "$SCRIPT" \
    && ok "Temporäre Config-Dateien mit chmod 600 geschützt" \
    || fail "chmod 600 fehlt"

grep -q "\[\[ .*\^\[0-9\]" "$SCRIPT" \
    && ok "Numerische Validierung vorhanden (SQL-Injection-Schutz)" \
    || fail "Eingabe-Validierung fehlt"

grep -q "set -eo pipefail" "$SCRIPT" \
    && ok "set -eo pipefail aktiv" \
    || fail "Fehlerbehandlung unvollständig"

# 6. Logging & Robustheit
echo ""
echo "6. Logging & Robustheit..."
grep -q "rotate_log" "$SCRIPT" \
    && ok "Log-Rotation implementiert" \
    || fail "Log-Rotation fehlt"

grep -q "trap cleanup" "$SCRIPT" \
    && ok "Cleanup-Trap vorhanden (Tempfiles werden aufgeräumt)" \
    || fail "Cleanup-Trap fehlt"

grep -q "flock" "$CONF_EXAMPLE" \
    && ok "flock-Hinweis im Cron-Eintrag vorhanden" \
    || fail "flock fehlt (parallele Ausführung möglich)"

# 7. Import-Methode
echo ""
echo "7. Import-Strategie..."
grep -q "mysqldump" "$SCRIPT" \
    && ok "mysqldump für Batch-Import (effizient bei großen Datenmengen)" \
    || fail "Kein mysqldump gefunden"

grep -q "ON DUPLICATE KEY UPDATE" "$SCRIPT" \
    && ok "ON DUPLICATE KEY UPDATE für kleine Tabellen" \
    || fail "Kein ON DUPLICATE KEY UPDATE gefunden"

# Ergebnis
echo ""
echo "=================================="
if [ "$ERRORS" -eq 0 ]; then
    echo "✓ Alle Tests bestanden"
    echo ""
    echo "Nächste Schritte:"
    echo "  1. cp $CONF_EXAMPLE sync_volkszaehler.conf"
    echo "  2. sync_volkszaehler.conf anpassen (Hosts, User, Passwörter)"
    echo "  3. DB-User anlegen (siehe Kommentare in .conf.example)"
    echo "  4. chmod +x $SCRIPT"
    echo "  5. Cron: */5 * * * * flock -n /tmp/vz_sync.lock \$(pwd)/$SCRIPT"
else
    echo "✗ $ERRORS Test(s) fehlgeschlagen"
    exit 1
fi
