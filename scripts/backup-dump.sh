#!/bin/bash
set -euo pipefail

# Nightly pg_dump backup for all databases
# Run via cron at 02:00

BACKUP_DIR="/opt/docker/postgres-fin/backups/dumps"
LOGFILE="/opt/docker/postgres-fin/logs/backup-dump-$(date +%Y%m%d).log"
DATE=$(date +%Y%m%d)
FAILED=0

source /opt/docker/postgres-fin/.env

for db in macro mtm; do
    DUMP_FILE="${BACKUP_DIR}/${db}_${DATE}.dump"
    echo "[$(date -Iseconds)] Dumping ${db}..." >> "$LOGFILE"

    if docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin \
        pg_dump -Fc -U backup_user "$db" > "$DUMP_FILE" 2>> "$LOGFILE"; then

        # Verify non-empty
        if [ ! -s "$DUMP_FILE" ]; then
            echo "[$(date -Iseconds)] ERROR: ${db} dump is empty" >> "$LOGFILE"
            rm -f "$DUMP_FILE"
            FAILED=1
            continue
        fi

        echo "[$(date -Iseconds)] ${db} dump OK ($(du -h "$DUMP_FILE" | awk '{print $1}'))" >> "$LOGFILE"
    else
        echo "[$(date -Iseconds)] ERROR: ${db} dump failed" >> "$LOGFILE"
        rm -f "$DUMP_FILE"
        FAILED=1
        continue
    fi
done

# Retention cleanup — only after successful dumps
if [ "$FAILED" -eq 0 ]; then
    find "$BACKUP_DIR" -name "*.dump" -mtime +14 -delete
    echo "[$(date -Iseconds)] Retention cleanup done (14 days)" >> "$LOGFILE"
else
    echo "[$(date -Iseconds)] Skipping retention cleanup due to failures" >> "$LOGFILE"
fi

exit $FAILED
