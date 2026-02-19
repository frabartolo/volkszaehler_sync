# Volkszaehler Database Synchronization Script

Ein Shell-Skript zur Synchronisation einer MariaDB-Datenbank vom Volkszähler auf einem Raspberry Pi zu einem Hauptrechner.

## Übersicht

Dieses Skript synchronisiert automatisch alle Daten aus einer Volkszaehler-Datenbank auf einem Raspberry Pi zu einer MariaDB-Datenbank auf einem Hauptrechner. Es ist für die Integration in einen Cron-Job konzipiert und läuft auf dem Hauptrechner (der mehr Ressourcen hat).

## Features

- **Vollständige Synchronisation** aller Volkszaehler-Tabellen:
  - `entities` - Entitäten/Kanäle
  - `properties` - Eigenschaften der Entitäten
  - `entities_in_aggregator` - Beziehungen zwischen Entitäten
  - `data` - Messdaten (inkrementell)
  - `aggregate` - Aggregierte Daten (inkrementell)

- **Inkrementelle Synchronisation**: Nur neue Daten werden übertragen
- **Update bestehender Daten**: Vorhandene Einträge werden aktualisiert
- **Logging**: Ausführliche Protokollierung mit konfigurierbarem Ausgabeziel
- **Fehlerbehandlung**: Robuste Fehlerbehandlung mit aussagekräftigen Fehlermeldungen
- **Konfigurierbar**: Alle Parameter über Konfigurationsdatei anpassbar

## Voraussetzungen

- Bash Shell
- MySQL/MariaDB Client (`mysql`)
- Netzwerkzugriff vom Hauptrechner zum Raspberry Pi
- Entsprechende Datenbankberechtigungen auf beiden Systemen

## Installation

1. Repository klonen oder Dateien herunterladen:
```bash
git clone https://github.com/frabartolo/volkszaehler_sync.git
cd volkszaehler_sync
```

2. Skript ausführbar machen:
```bash
chmod +x sync_volkszaehler.sh
```

3. Konfigurationsdatei erstellen:
```bash
cp sync_volkszaehler.conf.example sync_volkszaehler.conf
```

4. Konfigurationsdatei anpassen:
```bash
nano sync_volkszaehler.conf
```

Passen Sie die Werte an Ihre Umgebung an:
- `SOURCE_HOST`: Hostname oder IP des Raspberry Pi
- `SOURCE_USER` / `SOURCE_PASS`: Datenbankzugangsdaten für Raspberry Pi
- `DEST_HOST`: Hostname des Hauptrechners (meist `localhost`)
- `DEST_USER` / `DEST_PASS`: Datenbankzugangsdaten für Hauptrechner

## Verwendung

### Manuelle Ausführung

```bash
./sync_volkszaehler.sh
```

### Cron-Job einrichten

Für eine automatische stündliche Synchronisation:

```bash
crontab -e
```

Fügen Sie folgende Zeile hinzu (z.B. für stündliche Synchronisation um Minute 5):
```cron
5 * * * * /pfad/zum/sync_volkszaehler.sh
```

Für eine tägliche Synchronisation um 2:30 Uhr:
```cron
30 2 * * * /pfad/zum/sync_volkszaehler.sh
```

### Logging

Das Skript schreibt Logs nach `/var/log/volkszaehler_sync.log` (konfigurierbar). 
Stellen Sie sicher, dass das Skript Schreibrechte für die Log-Datei hat:

```bash
sudo touch /var/log/volkszaehler_sync.log
sudo chown $USER:$USER /var/log/volkszaehler_sync.log
```

Oder ändern Sie den `LOG_FILE` Pfad in der Konfiguration auf ein Verzeichnis mit Schreibrechten.

## Konfiguration

### Umgebungsvariablen

Alternativ zur Konfigurationsdatei können auch Umgebungsvariablen gesetzt werden:

```bash
export SOURCE_HOST="raspi.local"
export SOURCE_USER="volkszaehler"
export SOURCE_PASS="password"
./sync_volkszaehler.sh
```

### Verfügbare Parameter

| Parameter | Beschreibung | Standard |
|-----------|--------------|----------|
| `SOURCE_HOST` | Hostname/IP des Raspberry Pi | `raspi` |
| `SOURCE_PORT` | MySQL Port Raspberry Pi | `3306` |
| `SOURCE_USER` | Datenbankbenutzer Raspberry Pi | `volkszaehler` |
| `SOURCE_PASS` | Datenbankpasswort Raspberry Pi | (leer) |
| `SOURCE_DB` | Datenbankname Raspberry Pi | `volkszaehler` |
| `DEST_HOST` | Hostname/IP Hauptrechner | `localhost` |
| `DEST_PORT` | MySQL Port Hauptrechner | `3306` |
| `DEST_USER` | Datenbankbenutzer Hauptrechner | `volkszaehler` |
| `DEST_PASS` | Datenbankpasswort Hauptrechner | (leer) |
| `DEST_DB` | Datenbankname Hauptrechner | `volkszaehler` |
| `LOG_FILE` | Pfad zur Log-Datei | `/var/log/volkszaehler_sync.log` |
| `VERBOSE` | Konsolen-Ausgabe (1=an, 0=aus) | `1` |

## Funktionsweise

1. **Verbindungsprüfung**: Prüft die Verbindung zu beiden Datenbanken
2. **Entitäten-Sync**: Synchronisiert die `entities` Tabelle (Master-Daten)
3. **Properties-Sync**: Synchronisiert die `properties` Tabelle
4. **Beziehungs-Sync**: Synchronisiert die `entities_in_aggregator` Tabelle
5. **Daten-Sync**: 
   - Ermittelt für jeden Kanal den höchsten Zeitstempel im Ziel
   - Holt alle neueren Daten von der Quelle
   - Fügt neue Daten ein oder aktualisiert bestehende
6. **Aggregat-Sync**: Wie Daten-Sync, für aggregierte Daten

## Sicherheit

**Wichtig**: Die Konfigurationsdatei enthält Passwörter im Klartext!

Schützen Sie die Datei entsprechend:
```bash
chmod 600 sync_volkszaehler.conf
```

Stellen Sie sicher, dass nur der Benutzer, der das Skript ausführt, Lesezugriff hat.

## Troubleshooting

### "Failed to connect to source database"
- Prüfen Sie die Netzwerkverbindung zum Raspberry Pi
- Prüfen Sie, ob der MySQL-Server auf dem Raspberry Pi läuft
- Prüfen Sie die Zugangsdaten in der Konfiguration
- Prüfen Sie, ob der MySQL-Port (3306) erreichbar ist

### "Failed to connect to destination database"
- Prüfen Sie, ob der MySQL-Server auf dem Hauptrechner läuft
- Prüfen Sie die Zugangsdaten in der Konfiguration

### Sehr lange Synchronisationszeiten
- Bei der ersten Synchronisation kann es lange dauern, wenn viele Daten vorhanden sind
- Nachfolgende Synchronisationen sind deutlich schneller (nur neue Daten)
- Erwägen Sie, die Synchronisation seltener auszuführen

### Berechtigung Log-Datei
```bash
sudo touch /var/log/volkszaehler_sync.log
sudo chown $USER:$USER /var/log/volkszaehler_sync.log
```

## Lizenz

Dieses Projekt ist Open Source. Siehe LICENSE Datei für Details.

## Unterstützung

Bei Problemen oder Fragen öffnen Sie bitte ein Issue auf GitHub.