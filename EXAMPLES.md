# Verwendungsbeispiele / Usage Examples

## Schnellstart / Quick Start

### 1. Konfiguration erstellen / Create Configuration

```bash
cd volkszaehler_sync
cp sync_volkszaehler.conf.example sync_volkszaehler.conf
nano sync_volkszaehler.conf
```

Bearbeiten Sie die Konfigurationsdatei mit Ihren Datenbank-Zugangsdaten:

```bash
# Source Database (Raspberry Pi)
SOURCE_HOST="192.168.1.100"  # IP oder Hostname des Raspberry Pi
SOURCE_PORT="3306"
SOURCE_USER="volkszaehler"
SOURCE_PASS="mein_raspi_passwort"
SOURCE_DB="volkszaehler"

# Destination Database (Main Computer)
DEST_HOST="localhost"
DEST_PORT="3306"
DEST_USER="volkszaehler"
DEST_PASS="mein_hauptrechner_passwort"
DEST_DB="volkszaehler"

# Logging
LOG_FILE="/var/log/volkszaehler_sync.log"
VERBOSE="1"
```

### 2. Erste Synchronisation testen / Test First Sync

```bash
# Log-Datei vorbereiten
sudo touch /var/log/volkszaehler_sync.log
sudo chown $USER:$USER /var/log/volkszaehler_sync.log

# Skript ausführen
./sync_volkszaehler.sh
```

### 3. Ausgabe prüfen / Check Output

```bash
# Log-Datei anzeigen
tail -f /var/log/volkszaehler_sync.log
```

Erwartete Ausgabe:
```
[2024-02-19 10:30:00] === Starting Volkszaehler Database Sync ===
[2024-02-19 10:30:01] Checking source database connection...
[2024-02-19 10:30:01] Source database connection OK
[2024-02-19 10:30:01] Checking destination database connection...
[2024-02-19 10:30:01] Destination database connection OK
[2024-02-19 10:30:01] Syncing entities table...
[2024-02-19 10:30:02] Processed 5 entity INSERT statements
[2024-02-19 10:30:02] Entities sync completed.
...
[2024-02-19 10:35:00] === Volkszaehler Database Sync Completed Successfully ===
```

## Cron-Job Konfiguration / Cron Job Configuration

### Stündliche Synchronisation / Hourly Sync

```bash
crontab -e
```

Fügen Sie hinzu:
```cron
# Volkszaehler Sync - jede Stunde um Minute 5
5 * * * * /home/user/volkszaehler_sync/sync_volkszaehler.sh >> /var/log/volkszaehler_sync_cron.log 2>&1
```

### Tägliche Synchronisation / Daily Sync

```cron
# Volkszaehler Sync - täglich um 2:30 Uhr
30 2 * * * /home/user/volkszaehler_sync/sync_volkszaehler.sh >> /var/log/volkszaehler_sync_cron.log 2>&1
```

### Alle 15 Minuten / Every 15 Minutes

```cron
# Volkszaehler Sync - alle 15 Minuten
*/15 * * * * /home/user/volkszaehler_sync/sync_volkszaehler.sh >> /var/log/volkszaehler_sync_cron.log 2>&1
```

## Erweiterte Verwendung / Advanced Usage

### Ohne Konfigurationsdatei (Umgebungsvariablen) / Without Config File

```bash
SOURCE_HOST="raspi.local" \
SOURCE_USER="volkszaehler" \
SOURCE_PASS="password" \
DEST_HOST="localhost" \
DEST_USER="volkszaehler" \
DEST_PASS="password" \
./sync_volkszaehler.sh
```

### Stille Ausführung (kein Console Output) / Silent Mode

```bash
VERBOSE=0 ./sync_volkszaehler.sh
```

### Eigene Log-Datei / Custom Log File

```bash
LOG_FILE="/tmp/mein_sync.log" ./sync_volkszaehler.sh
```

## Fehlersuche / Troubleshooting

### Verbindungsprobleme prüfen / Check Connection

```bash
# Von Hauptrechner zu Raspberry Pi
mysql -h raspi.local -u volkszaehler -p volkszaehler -e "SELECT VERSION();"

# Lokale Verbindung
mysql -h localhost -u volkszaehler -p volkszaehler -e "SELECT VERSION();"
```

### Datenbank-Struktur prüfen / Check Database Structure

```bash
mysql -h raspi.local -u volkszaehler -p volkszaehler -e "SHOW TABLES;"
mysql -h localhost -u volkszaehler -p volkszaehler -e "SHOW TABLES;"
```

### Log-Datei überwachen / Monitor Log File

```bash
# Letzte 50 Zeilen
tail -n 50 /var/log/volkszaehler_sync.log

# Live-Monitoring
tail -f /var/log/volkszaehler_sync.log

# Nur Fehler anzeigen
grep ERROR /var/log/volkszaehler_sync.log
```

### Test ohne tatsächliche Ausführung / Dry Run Check

Das Skript unterstützt keinen "Dry Run" Modus, aber Sie können die Konfiguration testen:

```bash
# Verbindungen testen (Skript bricht nach Verbindungsprüfung ab wenn Fehler auftreten)
timeout 10 ./sync_volkszaehler.sh
```

## Performance-Tipps / Performance Tips

1. **Erste Synchronisation**: Kann lange dauern bei vielen Daten (mehrere Stunden möglich)
2. **Nachfolgende Syncs**: Sehr schnell, da nur neue Daten übertragen werden
3. **Netzwerk**: Schnelle Verbindung zwischen Raspberry Pi und Hauptrechner empfohlen
4. **Zeitplan**: Häufigkeit an Datenmenge anpassen (mehr Daten = seltener synchronisieren)

## Sicherheitshinweise / Security Notes

1. **Konfigurationsdatei schützen**:
   ```bash
   chmod 600 sync_volkszaehler.conf
   ```

2. **Log-Dateien rotieren** (verhindert zu große Dateien):
   ```bash
   # /etc/logrotate.d/volkszaehler_sync erstellen
   sudo nano /etc/logrotate.d/volkszaehler_sync
   ```
   
   Inhalt:
   ```
   /var/log/volkszaehler_sync.log {
       daily
       rotate 7
       compress
       delaycompress
       missingok
       notifempty
   }
   ```

3. **Separate Benutzer verwenden**: Erstellen Sie dedizierte Datenbank-Benutzer mit minimalen Rechten

## Überwachung / Monitoring

### E-Mail bei Fehlern / Email on Errors

Erstellen Sie ein Wrapper-Skript:

```bash
#!/bin/bash
# sync_with_mail.sh

OUTPUT=$(mktemp)
/pfad/zum/sync_volkszaehler.sh > "$OUTPUT" 2>&1

if [ $? -ne 0 ]; then
    mail -s "Volkszaehler Sync Fehler" admin@example.com < "$OUTPUT"
fi

rm -f "$OUTPUT"
```

### Erfolgs-Überwachung / Success Monitoring

```bash
# Im Cron-Job
5 * * * * /home/user/volkszaehler_sync/sync_volkszaehler.sh && touch /tmp/volkszaehler_sync_success
```

Dann mit einem Monitoring-Tool `/tmp/volkszaehler_sync_success` auf Aktualität prüfen.
