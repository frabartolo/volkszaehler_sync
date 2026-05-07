# Volkszähler-Cutover: Raspi → cold-lairs

Anleitung für die einmalige Migration der Volkszähler-Datenbank vom Raspi
auf den Server `cold-lairs`. Aufbauend auf dem bestehenden Sync-Skript
`sync_volkszaehler.sh`.

> **Tipp:** Den ganzen Ablauf orchestriert `bin/cutover.sh` interaktiv.
> Falls etwas schief geht, kannst du jede Phase per `--phase N` einzeln
> wiederholen.

---

## Überblick

```
  ┌────────────┐    Phase 1-2: Bulk-Sync (lange)    ┌───────────────┐
  │            │ ───────────────────────────────►   │               │
  │   Raspi    │                                    │  cold-lairs   │
  │  vzlogger  │    Phase 3: vzlogger STOP                 │
  │  + DB      │ ───────────────────────────────►   │               │
  │            │    Phase 4: Delta-Sync             │               │
  │            │ ───────────────────────────────►   │               │
  └────────────┘    Phase 5: Verify                 └───────────────┘
                    Phase 6: Middleware-Switch
```

| Phase | Was passiert                              | Wo läuft's        | Dauer          |
| ----: | ----------------------------------------- | ----------------- | -------------- |
|     1 | Verbindungs-/Schema-/Disk-Checks          | cold-lairs        | < 1 min        |
|     2 | Bulk-Sync (alle bisherigen Daten)         | cold-lairs        | min - h        |
|     3 | vzlogger auf Raspi stoppen                | Raspi (manuell)   | 1 min          |
|     4 | Finaler Delta-Sync                        | cold-lairs        | < 1 min        |
|     5 | Verify (Counts/Max-Timestamps)            | cold-lairs        | < 1 min        |
|     6 | Middleware/vzlogger umkonfigurieren       | manuell           | wenige Minuten |

---

## Voraussetzungen

- Auf cold-lairs:
  - MariaDB/MySQL läuft, leere oder teilweise befüllte DB `volkszaehler` existiert.
  - Schema ist da (Tabellen `entities`, `properties`, `entities_in_aggregator`,
    `data`, `aggregate`). Wenn nicht, siehe **Schema initial anlegen** unten.
  - Bash, `mysql`, `mysqldump`, `awk`, `ssh`.
- DB-User auf beiden Seiten:
  - **Quelle (Raspi):** `SELECT` auf alle Tabellen reicht
  - **Ziel (cold-lairs):** `SELECT, INSERT, UPDATE, DELETE` (`REPLACE` braucht
    INSERT+DELETE). Empfehlung: dedizierter User, kein root.
- Netzzugang von cold-lairs zum Raspi auf Port 3306.

---

## Phase 0 - Setup

### 1. Repository auf cold-lairs deployen

```bash
ssh cold-lairs
cd ~
# entweder via git
git clone https://github.com/frabartolo/volkszaehler_sync.git
# oder per scp aus dieser Workstation
# scp -r ~/Workspace/volkszaehler_sync cold-lairs:~/
cd volkszaehler_sync
chmod +x sync_volkszaehler.sh bin/*.sh
```

### 2. Config befüllen

Auf cold-lairs:

```bash
cp sync_volkszaehler.conf.example sync_volkszaehler.conf
chmod 600 sync_volkszaehler.conf
```

Werte ermitteln (halb-automatisch):

```bash
# Quell-DB (Raspi) -- Heuristik per SSH:
./bin/extract_credentials.sh --ssh raspi.local --prefix SOURCE

# Ziel-DB (cold-lairs lokal):
./bin/extract_credentials.sh --prefix DEST
```

Die Ausgabe enthält fertige `SOURCE_*=`/`DEST_*=`-Zeilen, die du in
`sync_volkszaehler.conf` einträgst. Felder, die nicht gefunden wurden,
werden in der `# WARNUNG`-Zeile angemerkt -- die musst du selbst
nachpflegen (typisch: das Passwort).

### 3. Verbindungstest

```bash
./bin/verify_sync.sh
```

Wenn beide DBs erreichbar sind, zeigt das Skript einen Status-Bericht.
Erwartet ist beim ersten Lauf: Ziel < Quelle (das ist ja der Grund, warum
wir migrieren).

---

## Phase 1-6 - mit `bin/cutover.sh`

Bequem alles in einem Rutsch:

```bash
./bin/cutover.sh
```

Das Skript fragt an den kritischen Stellen nach (`yes`/`abort`). Bei
Abbruch oder Re-Run kannst du jede Phase einzeln wiederholen:

```bash
./bin/cutover.sh --phase 4   # ab Phase 4 weitermachen
./bin/cutover.sh --dry-run   # nur prüfen, nichts schreiben
```

Logs landen in `logs/cutover_<timestamp>.log`.

### Was passiert in welcher Phase

#### Phase 1 - Vor-Checks

- Verbindung zu Quell- und Ziel-DB
- Existenz aller benötigten Tabellen auf Ziel
- Schema-Vergleich (warnt bei Abweichungen)
- Größe der Datenmengen
- Disk-Space auf MySQL-datadir
- Hinweis auf vzlogger-Status

#### Phase 2 - Bulk-Sync

Ruft `sync_volkszaehler.sh` auf -- der eigentliche Datentransfer.
Die Volkszähler-Anwendung läuft in dieser Phase noch normal weiter,
neue Messwerte landen weiter auf dem Raspi (werden im finalen Delta
nachgezogen).

> ⚠ Beim **ersten** Lauf kann das je nach Datenmenge **Stunden** dauern.
> Pro `channel_id` macht das Skript einen `mysqldump --where="channel_id=X
> AND timestamp > <max_ts_im_ziel>"` und pipelined das Ergebnis nach
> cold-lairs.

#### Phase 3 - Quelle einfrieren

Das Skript stoppt **nicht** automatisch, sondern fragt explizit nach. Es
soll vermeiden, dass eine versehentliche Re-Ausführung den Daemon
stoppt. Die empfohlenen Befehle stehen im Output, z.B.:

```bash
ssh raspi.local 'sudo systemctl stop vzlogger'
# ggf. zusätzlich, falls die Middleware auch auf dem Raspi läuft:
ssh raspi.local 'sudo systemctl stop apache2'
```

Danach prüft das Skript 30 s lang, ob `MAX(timestamp)` auf der Quelle
wirklich konstant bleibt.

#### Phase 4 - Finaler Delta-Sync

Erneuter Aufruf von `sync_volkszaehler.sh` -- jetzt fließt nur noch das
kleine Delta seit Phase 2. Sollte unter einer Minute liegen.

#### Phase 5 - Verify

`bin/verify_sync.sh --strict` vergleicht **exakt**:

- `COUNT(*)` aller Tabellen
- `MAX(timestamp)` für `data` und `aggregate`
- pro `channel_id` Anzahl und letzter Zeitstempel

Im Erfolgsfall sind beide Seiten exakt identisch.

#### Phase 6 - Anwendungs-Switch

Hier orchestriert das Skript nichts mehr, sondern gibt eine Anleitung
aus. Sinngemäß:

1. **Backup** der Raspi-DB anlegen (Sicherheitsnetz).

2. **Middleware-Config** anpassen -- die DB-Verbindungs-Daten in
   `volkszaehler.org/etc/config.yaml` auf cold-lairs zeigen lassen:

   ```yaml
   db:
     default:
       driver: pdo_mysql
       host: cold-lairs        # neuer Host (oder localhost, wenn Middleware mit umzieht)
       port: 3306
       user: volkszaehler
       password: <neu>
       dbname: volkszaehler
   ```

3. **vzlogger** zeigt weiter auf dieselbe Middleware-URL -- der wechselt
   die DB nicht direkt, sondern indirekt über die Middleware. Wenn die
   Middleware mit umzieht, neue URL eintragen:

   ```json
   "middleware": "http://cold-lairs/middleware.php/"
   ```

4. **Dienste starten:** vzlogger und ggf. Webserver/PHP-FPM.

5. **Funktionstest:** Frontend laden, neue Datenpunkte sollten in der
   Ziel-DB erscheinen:

   ```sql
   SELECT MAX(timestamp), FROM_UNIXTIME(MAX(timestamp)/1000)
   FROM data;
   ```

6. Erst nach **24-48 h Stabilität** alte Raspi-DB stilllegen
   (umbenennen oder read-only). **Nicht löschen** -- noch ein paar
   Tage als Fallback aufheben.

---

## Schema initial anlegen (falls Ziel-DB leer)

Wenn auf cold-lairs noch gar keine Tabellen existieren, vor Phase 1
einmalig ausführen (auf cold-lairs):

```bash
mysqldump --defaults-extra-file=<(grep -E '^(SOURCE|DEST)' sync_volkszaehler.conf) ...
# oder direkt:
mysqldump -h $SOURCE_HOST -u $SOURCE_USER -p$SOURCE_PASS \
    --no-data --routines --triggers $SOURCE_DB \
  | mysql -h $DEST_HOST -u $DEST_USER -p$DEST_PASS $DEST_DB
```

`--no-data` überträgt nur die Strukturen (`CREATE TABLE`, Indizes).
Schnell, klein und erforderlich für `cutover.sh` Phase 1.

---

## Rollback

Solange die Raspi-DB noch existiert und unangetastet ist, ist der
Rollback trivial: Middleware-Config zurück auf den alten Host und
vzlogger neustarten.

```yaml
db:
  default:
    host: localhost     # zurück auf Raspi
```

---

## Troubleshooting

| Symptom                                                  | Ursache / Fix                                                                            |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `Lost connection to server during query`                 | Großer Channel beim Bulk-Sync. Skript erneut starten — wegen Idempotenz unproblematisch. |
| `verify_sync.sh` zeigt LOW bei einem Channel             | Sync nicht durch. Erneut `sync_volkszaehler.sh` laufen lassen.                           |
| `extract_credentials.sh` findet kein Passwort            | Volkszähler hält das Passwort oft nur in `config.yaml`. Manuell in Conf eintragen.       |
| Phase 3: MAX(timestamp) ändert sich noch nach Stop       | Daemon nicht wirklich gestoppt; `systemctl status vzlogger`, ggf. Cron prüfen.           |
| Phase 5 strict zeigt minimal mehr Zeilen auf Ziel        | Du hattest schon Daten teilweise migriert. Mit `--strict` weglassen, soft-mode reicht.   |

---

## Cron-Mode (nach erfolgreichem Cutover, optional)

Wenn du den Raspi als zusätzlichen Backup-Schreiber laufen lässt und nur
nachts auf cold-lairs spiegelst, kannst du das vorhandene
`sync_volkszaehler.sh` weiter via Cron laufen lassen -- siehe `README.md`.
Für die hier beschriebene **einmalige Migration** ist das nicht nötig.
