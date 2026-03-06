#!/bin/bash
# health-check.sh — daily status check for PostgreSQL stack
# Run via cron at 05:00, after the backup pipeline completes

LOGFILE="/opt/docker/postgres-fin/logs/health-$(date +%Y%m%d).log"
STATUS="OK"
WARNINGS=""

# 1. Disk usage check
DISK_PCT=$(df /opt/docker/postgres-fin | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$DISK_PCT" -gt 80 ]; then
    STATUS="WARN"
    WARNINGS="$WARNINGS | disk_usage=${DISK_PCT}%"
fi

# 2. Per-database dump freshness (each DB must have a dump within last 24h)
for db in macro mtm; do
    DB_DUMP=$(find /opt/docker/postgres-fin/backups/dumps -name "${db}_*.dump" -mtime -1 | wc -l)
    if [ "$DB_DUMP" -eq 0 ]; then
        STATUS="WARN"
        WARNINGS="$WARNINGS | no_recent_dump_${db}"
    fi
done

# 3. pgBackRest stanza status
PGBR_STATUS=$(docker exec postgres-fin pgbackrest info --stanza=main 2>&1 | grep -c 'status: ok')
if [ "$PGBR_STATUS" -eq 0 ]; then
    STATUS="WARN"
    WARNINGS="$WARNINGS | pgbackrest_not_ok"
fi

# 4. Backup storage size
BACKUP_SIZE=$(du -sh /opt/docker/postgres-fin/backups | awk '{print $1}')

# 5. Postgres container health
PG_HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' postgres-fin 2>/dev/null)
if [ "$PG_HEALTHY" != "healthy" ]; then
    STATUS="WARN"
    WARNINGS="$WARNINGS | container_not_healthy"
fi

# Write timestamped log line (JSON for easy parsing)
echo "{\"ts\":\"$(date -Iseconds)\",\"status\":\"$STATUS\",\"disk_pct\":$DISK_PCT,\"backup_size\":\"$BACKUP_SIZE\",\"warnings\":\"$WARNINGS\"}" >> "$LOGFILE"

# Exit non-zero if warnings found (useful for cron mail alerts)
[ "$STATUS" = "OK" ] && exit 0 || exit 1
