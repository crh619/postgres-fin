# PostgreSQL / TimescaleDB Stack — Technical Specification

**Version 1.4 — March 2026**
Internal Infrastructure — Macro Terminal & MTM

> Reproducible · Safe · Single-Operator Maintainable

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03 | Initial spec |
| 1.1 | 2026-03 | Healthcheck, backup_user, post-init convention, WAL config, health monitoring |
| 1.2 | 2026-03-06 | Networking fix (no host port exposure), init script fix (shell wrapper for env vars), Dockerfile corrections (add pgBackRest, drop unused extensions), remove soma (separate stack), add MTM migration section, add `pg_cron` to extensions section, pin base image version |
| 1.2.1 | 2026-03-06 | App users own their databases + public schema, backup_user explicit CONNECT/auth, pgBackRest restore procedure rewritten (restore container), WAL max_wal_size claim corrected, health check validates both DB dumps individually, pg_cron availability note clarified |
| 1.2.2 | 2026-03-06 | Explicit volume name (`postgres_data`) for copy-paste reliable restore commands, simplified restore image reference, removed misleading `depends_on` snippets (cross-project — apps must use wait-for-Postgres in entrypoint), added Section 10.1 backup script conventions (`set -euo pipefail`, retention after success, per-DB logging) |
| 1.3 | 2026-03-06 | Directory rename `postgres/` → `postgres-fin/`, added `pg_hba.conf` content, added pgBackRest `stanza-create` step, added `archive_timeout`, fixed `backup_user` dump command (missing `PGPASSWORD`), added `logs/` directory creation note |
| 1.4 | 2026-03-06 | Implementation fixes: Alpine base image (`apk` not `apt-get`), pgBackRest dir permissions in Dockerfile, `compress-type=gz` (Alpine pgbackrest lacks zstd), `pg1-user=postgres` in pgbackrest.conf, `pg_hba.conf` local trust for all users (pgBackRest runs as root), pgBackRest commands must run as `postgres` OS user |

---

## 1. Overview

This document defines the architecture and operational procedures for the shared PostgreSQL / TimescaleDB database stack used by internal projects. It is a living specification intended to guide both initial setup and ongoing operations.

The stack is designed to support:

- **Macro Terminal** (macro data platform)
- **MTM** (mark-to-market portfolio tracking)
- Future internal analytics projects

The database stack provides:

- Time-series optimized storage via TimescaleDB
- Reproducible containerized deployment
- Strong backup and recovery capabilities
- Safe schema experimentation
- Shared database infrastructure across projects

> **Out of scope:** The health tracking project (soma) will run on a separate Postgres instance so its lifecycle is fully independent of the finance stack.

---

## 2. Design Goals

### Reliability

Data must survive: application bugs, schema mistakes, accidental deletes, VPS failure, and disk corruption.

### Reproducibility

Infrastructure must be rebuildable from source: Dockerfile-based images, declarative configuration, scripted initialization, and deterministic dependency versions.

### Project Isolation

Multiple projects must share the same PostgreSQL instance while maintaining logical isolation. Each project receives its own database, its own database user, and independent schemas.

### Time-Series Optimization

The stack must support high-volume time-series storage, efficient range queries, hypertables, and compression. TimescaleDB provides these capabilities.

### Operational Simplicity

The system must be maintainable by a single operator: minimal moving parts, simple backup strategy, and understandable restore procedures.

---

## 3. System Architecture

The PostgreSQL stack runs as a single containerized database server hosting multiple logical databases.

```
+---------------------------------------+
|  PostgreSQL / TimescaleDB Server      |
|                                       |
|  Databases                            |
|                                       |
|    macro   --> Macro Terminal          |
|    mtm     --> Market tracking        |
|                                       |
+---------------------------------------+
          |                |
          | Docker volume  | Docker network
          |                |
  postgres_data       lalonet_private
```

All applications connect to the same server but different databases over the `lalonet_private` Docker network. This simplifies backups, monitoring, and upgrades.

> **v1.2 change:** The `soma` (health) database has been removed from this stack. It will run on a separate Postgres instance so the finance and health stacks can move independently.

---

## 4. Filesystem Layout

All database infrastructure resides under:

```
/opt/docker/postgres-fin
```

Directory structure:

```
/opt/docker/postgres-fin/
├── docker-compose.yml
├── Dockerfile
├── .env                          # passwords, not tracked in git
├── .gitignore
│
├── config/
│   ├── postgresql.conf
│   └── pg_hba.conf
│
├── scripts/
│   ├── 01-init-databases.sh      # first-run: create DBs, users, extensions
│   ├── backup-dump.sh
│   ├── restore-dump.sh
│   ├── backup-rclone.sh
│   ├── health-check.sh
│   └── test-restore.sh
│
├── backups/
│   ├── dumps/
│   ├── pgbackrest/
│   └── restore-tests/
│
└── logs/
```

Notes:

- `backups/`, `logs/`, `.env` are gitignored.
- Database data itself lives in Docker volumes.
- Only `scripts/01-init-databases.sh` goes into `/docker-entrypoint-initdb.d/` (see Section 7).

> **v1.2 change:** Renamed `init-databases.sql` to `01-init-databases.sh` (shell script). The Postgres entrypoint does not perform environment variable substitution in `.sql` files, so passwords must be injected via a shell wrapper that reads from environment variables. The `post-init.sql` convention is removed — use `psql` directly for post-setup changes; a convention file that is never executed automatically adds confusion.

> **v1.2 change:** The `scripts/` volume mount now targets a staging directory, not `/docker-entrypoint-initdb.d/` directly. Only the init script is copied in. Mounting the entire `scripts/` folder into the entrypoint directory would cause Postgres to execute backup and restore scripts on first boot.

---

## 5. Docker Image Specification

The database container is built from a custom Dockerfile.

Base image:

```
timescale/timescaledb:2.17.2-pg16
```

TimescaleDB already includes PostgreSQL, Timescale extensions, and hypertable support.

> **v1.2 change:** Pin the base image to a specific TimescaleDB release (`2.17.2-pg16`) instead of `latest-pg16`. Using `latest` means a `docker compose build` could silently upgrade TimescaleDB or PostgreSQL, potentially breaking compatibility with existing data or extensions. Pin to a known-good version and upgrade deliberately.

### Dockerfile

```dockerfile
FROM timescale/timescaledb:2.17.2-pg16

# pgBackRest for physical backups + WAL archiving
# Note: Alpine-based image — use apk, not apt-get
RUN apk add --no-cache pgbackrest \
    && mkdir -p /var/log/pgbackrest /tmp/pgbackrest \
    && chown -R postgres:postgres /var/log/pgbackrest /tmp/pgbackrest

# Custom config
COPY config/postgresql.conf /etc/postgresql/postgresql.conf
COPY config/pg_hba.conf /etc/postgresql/pg_hba.conf

# Init script (only this file goes into entrypoint dir)
COPY scripts/01-init-databases.sh /docker-entrypoint-initdb.d/

# Enable data checksums to detect silent on-disk corruption
ENV POSTGRES_INITDB_ARGS="--data-checksums"
```

> **v1.4 change:** The TimescaleDB image is Alpine-based, not Debian. Package installation uses `apk add` instead of `apt-get`. The Dockerfile also creates `/var/log/pgbackrest` and `/tmp/pgbackrest` owned by `postgres:postgres` — pgBackRest needs these directories for logging and lock files when run as the `postgres` user.

> **v1.2 change — extensions removed from Dockerfile:**
>
> - `postgresql-16-postgis` — no project currently needs geospatial queries. Can be added later if needed.
> - `postgresql-16-pg-stat-kcache` — useful for deep performance analysis but premature for this workload. Add when needed.
> - `postgresql-16-pg-cron` — not needed; `pg_cron` ships with TimescaleDB image already if the `shared_preload_libraries` entry is added.
>
> **Added:** `pgbackrest` — required for Layer 2 physical backups (Section 10) but was missing from the v1.1 Dockerfile.

### Why data checksums matter

Without checksums, PostgreSQL can silently serve corrupted pages from disk. With checksums enabled, it will error immediately when it detects a bad page rather than propagating corrupt data into query results or backups. On a VPS with shared storage, this is standard practice.

---

## 6. Docker Compose Configuration

File: `/opt/docker/postgres-fin/docker-compose.yml`

```yaml
services:
  postgres:
    build: .
    container_name: postgres-fin
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./backups:/backups
      - ./config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    networks:
      - lalonet_private
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d postgres"]
      interval: 10s
      timeout: 5s
      retries: 6
      start_period: 20s

volumes:
  postgres_data:
    name: postgres_data   # Explicit name — prevents Compose project prefix.
                          # Restore commands can reference 'postgres_data' directly
                          # regardless of COMPOSE_PROJECT_NAME or directory name.

networks:
  lalonet_private:
    external: true
```

### `.env` file

```
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<superuser_password>
MTM_PASSWORD=<mtm_user_password>
MACRO_PASSWORD=<macro_user_password>
BACKUP_PASSWORD=<backup_user_password>
```

> **v1.2 change — no host port exposure:** Removed `ports: "5432:5432"`. Exposing Postgres to the host (and potentially the internet via VPS firewall gaps) is unnecessary. All client apps (MTM, Macro) connect over the shared `lalonet_private` Docker network using the container hostname `postgres-fin`. This is the same networking pattern used by every other service on this VPS.

> **v1.2 change — removed `version: "3.9"`:** The `version` key is obsolete in modern Docker Compose and triggers a warning on every command. Removed.

> **v1.2 change — scripts volume mount removed:** The v1.1 spec mounted `./scripts:/docker-entrypoint-initdb.d`. This would cause Postgres to execute `backup-dump.sh`, `restore-dump.sh`, and every other script in that directory on first boot. The init script is now `COPY`ed in the Dockerfile instead.

### Why the healthcheck matters

Without a healthcheck, dependent app containers start against an unready or half-initialized database. This causes misleading migration errors and broken startup sequences after host reboots. The `pg_isready` check is lightweight and ensures PostgreSQL is genuinely ready before accepting connections.

Since app containers live in separate Compose projects, they cannot use `depends_on` to reference `postgres-fin`. Instead, each app's entrypoint/start script must poll `postgres-fin:5432` before running migrations. See Section 13 for the full pattern.

---

## 7. Database Initialization

During first startup, PostgreSQL executes all scripts in `/docker-entrypoint-initdb.d/`. This runs **once only** — on initial cluster creation.

> **Important:** If you need to add databases, users, or grants after initial setup, connect via `psql` manually:
> ```bash
> docker exec -it postgres-fin psql -U postgres
> ```

### scripts/01-init-databases.sh

```bash
#!/bin/bash
set -e

# This script runs as the postgres superuser during first-time init.
# Passwords come from environment variables set in .env.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL

    -- Application users (least-privilege: no superuser, no createdb)
    CREATE USER macro_user WITH PASSWORD '${MACRO_PASSWORD}';
    CREATE USER mtm_user   WITH PASSWORD '${MTM_PASSWORD}';

    -- Project databases — owned by their app users from the start.
    -- This avoids "permission denied for schema public" during migrations
    -- and ensures all objects created by Alembic/app are owned predictably.
    CREATE DATABASE macro OWNER macro_user;
    CREATE DATABASE mtm   OWNER mtm_user;

    -- Dedicated backup role (read-only: can dump but cannot write or drop)
    CREATE USER backup_user WITH PASSWORD '${BACKUP_PASSWORD}';
    GRANT pg_read_all_data TO backup_user;

    -- Backup user needs CONNECT on each database for pg_dump
    GRANT CONNECT ON DATABASE macro TO backup_user;
    GRANT CONNECT ON DATABASE mtm   TO backup_user;

EOSQL

# Enable extensions and fix schema ownership per database.
# The public schema is owned by postgres by default — transfer it to the
# app user so Alembic migrations can CREATE/ALTER in public without errors.
declare -A DB_OWNERS=( [macro]=macro_user [mtm]=mtm_user )

for db in "${!DB_OWNERS[@]}"; do
    owner="${DB_OWNERS[$db]}"
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" <<-EOSQL
        -- Schema ownership
        ALTER SCHEMA public OWNER TO ${owner};
        GRANT ALL ON SCHEMA public TO ${owner};

        -- Backup user needs schema access for pg_dump
        GRANT USAGE ON SCHEMA public TO backup_user;

        -- Extensions
        CREATE EXTENSION IF NOT EXISTS timescaledb;
        CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
EOSQL
done

echo "=== Database initialization complete ==="
```

> **v1.2 change:** This is a shell script, not raw SQL. The Postgres entrypoint passes environment variables to `.sh` scripts but does **not** substitute `${VAR}` in `.sql` files. The v1.1 spec had `'secure_password'` placeholders in SQL that would have been stored as literal strings.

### Role Hierarchy

| Role | Purpose and Permissions |
|------|------------------------|
| `postgres` | Superuser. Admin operations only. Never used by applications. |
| `macro_user` | App role for Macro Terminal. Full access to `macro` database only. |
| `mtm_user` | App role for MTM. Full access to `mtm` database only. |
| `backup_user` | Read-only. `pg_read_all_data` grant. Used by dump scripts only. |

### Why role separation matters

If an app credential is leaked or a migration has a bug, damage is contained to that project's database. A `backup_user` that can read but not write or drop cannot cause data loss even if its credentials are compromised. The `postgres` superuser should never appear in application config files.

---

## 8. Database Extensions

Extensions are enabled per database in the init script (Section 7). Both databases get:

| Extension | Purpose |
|-----------|---------|
| `timescaledb` | Hypertables, compression, continuous aggregates |
| `pg_stat_statements` | Query performance tracking |

MTM does not currently need TimescaleDB hypertables, but having the extension available costs nothing and allows future use (e.g., converting `prices_eod` to a hypertable for faster range queries).

Additional extensions can be added per-database later via `psql`:

```sql
\c macro
CREATE EXTENSION IF NOT EXISTS pg_cron;
```

> **pg_cron availability:** The `pg_cron` extension may or may not be bundled in the pinned TimescaleDB image. Verify with `SELECT * FROM pg_available_extensions WHERE name = 'pg_cron';` after the container starts. If not present, add `postgresql-16-cron` to the `apt-get install` line in the Dockerfile and include `pg_cron` in `shared_preload_libraries` in `postgresql.conf`.

---

## 9. WAL and PostgreSQL Configuration

Intentional WAL configuration is critical on a VPS. Uncontrolled WAL growth is the most common cause of disk exhaustion and can cause PostgreSQL to stop accepting writes entirely.

### config/postgresql.conf (relevant excerpt)

```ini
# WAL archiving — archive to pgBackRest
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = 300

# WAL size bounds — prevent unbounded growth
max_wal_size = 4GB
min_wal_size = 1GB

# Query performance tracking
shared_preload_libraries = 'timescaledb,pg_stat_statements'

# Connection settings — sufficient for single-operator workload
max_connections = 100
```

> **Disk exhaustion risk:** If WAL archiving silently fails (network issue, pgBackRest misconfiguration), WAL files pile up in `/var/lib/postgresql/data/pg_wal/` until the disk is full. PostgreSQL then stops accepting writes.
>
### config/pg_hba.conf

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             0.0.0.0/0               scram-sha-256
host    all             all             ::/0                    scram-sha-256
```

Local trust for all users allows `docker exec psql -U postgres` without a password (standard for container admin) and lets pgBackRest connect locally to verify the cluster state. All network connections require password authentication (`scram-sha-256`).

> **v1.4 change:** Changed `local all postgres trust` to `local all all trust`. pgBackRest runs as the `root` OS user inside the container and connects via the local Unix socket. With user-restricted trust, pgBackRest's `stanza-create` and `archive-push` commands fail with `no pg_hba.conf entry for user "root"`. Since no ports are exposed to the host, local trust for all users carries no additional risk.

> `max_wal_size` controls checkpoint frequency and **helps** manage normal WAL growth, but it is **not a hard ceiling** — if archiving breaks and WAL segments cannot be recycled, they will accumulate beyond this value. `max_wal_size` alone does not guarantee protection from disk exhaustion. The health monitoring script (Section 17) and disk usage alerts are the actual safety net for this failure mode.

---

## 10. Backup Strategy

Backups operate on three layers. This design protects against both operator error and infrastructure failure.

### Layer 1: Logical Backups (pg_dump)

Used for quick recovery from schema mistakes and accidental deletes. Nightly dumps per database, run as `backup_user`.

```bash
# Run inside the container as backup_user
# PGPASSWORD is injected so pg_dump does not hang waiting for a password prompt.
docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin \
    pg_dump -Fc -U backup_user macro > backups/dumps/macro_$(date +%Y%m%d).dump
docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin \
    pg_dump -Fc -U backup_user mtm   > backups/dumps/mtm_$(date +%Y%m%d).dump
```

Stored in `/opt/docker/postgres-fin/backups/dumps/` with 14-day retention.

> **Credential handling for noninteractive dumps:** The backup scripts must supply credentials without human interaction. Three options exist:
>
> 1. **`PGPASSWORD` env var** (shown above) — simplest; injected per-command via `docker exec -e`.
> 2. **`.pgpass` file** inside the container — more secure for long-running sidecar setups.
> 3. **`trust` auth for `backup_user` in `pg_hba.conf`** — only safe if the container network is fully isolated (it is, since no host port is exposed).
>
> Option 1 is recommended for this stack. The `BACKUP_PASSWORD` value should be sourced from `/opt/docker/postgres-fin/.env` in the backup shell script.

### Layer 2: Physical Backups (pgBackRest)

pgBackRest performs full PostgreSQL cluster backups with WAL archiving, point-in-time recovery, incremental backups, and compression.

### config/pgbackrest.conf

```ini
[global]
repo1-path=/backups/pgbackrest

# Explicit retention — never leave this undefined
repo1-retention-full=3
repo1-retention-diff=7

# Performance options
start-fast=y
compress-type=gz

[main]
pg1-path=/var/lib/postgresql/data
pg1-user=postgres
```

> **v1.4 change:** `compress-type` changed from `zst` to `gz` — Alpine's pgbackrest package is not built with zstd support. Added `pg1-user=postgres` so pgBackRest connects to Postgres as the `postgres` role instead of the OS user (`root`).

### Backup Schedule

| Type | Frequency |
|------|-----------|
| Full backup | Weekly |
| Incremental | Daily |
| WAL archiving | Continuous |
| Retention: full cycles | 3 |
| Retention: incremental | 7 days |

### First-time setup: stanza-create

After the container starts for the first time, initialize the pgBackRest stanza before running any backups:

```bash
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main stanza-create"
```

This must run **once** before the first backup and before `archive_command` can succeed.

> **v1.4 change:** pgBackRest commands must run as the `postgres` OS user via `su -s /bin/sh postgres -c "..."`. Running as `root` fails because the `root` PostgreSQL role does not exist. The `archive_command` in `postgresql.conf` already runs as `postgres` (the Postgres server user), so WAL archiving works without modification. Without it, WAL archiving will fail silently and segments will accumulate in `pg_wal/`.

> **Why explicit retention is required:** If `pgbackrest.conf` does not define retention, backups accumulate until the VPS disk is full. `repo1-retention-full=3` keeps three full backup cycles and automatically expires older ones. Leaving retention undefined is a configuration error, not a safe default.

### Layer 3: Offsite Backups (rclone)

Backups are synced to remote object storage to protect against VPS loss, disk failure, and provider outage.

```bash
rclone sync /opt/docker/postgres-fin/backups remote:postgres-backups
```

Target: Backblaze B2 or S3-compatible storage with an encrypted remote bucket.

### 10.1 Backup Script Conventions

All backup scripts (`backup-dump.sh`, `backup-rclone.sh`) must follow these rules:

1. **`set -euo pipefail`** at the top of every script. A silent failure in a backup pipeline is worse than a loud crash.
2. **Source `.env` carefully.** Use `source /opt/docker/postgres-fin/.env` or `export $(grep -v '^#' .env | xargs)`. Never hardcode passwords.
3. **Dump filenames must include database name and date:** `macro_20260306.dump`, `mtm_20260306.dump`. This is required for the per-database health check (Section 17) to validate freshness.
4. **Retention cleanup happens after successful backup creation, not before.** If the new dump fails, the old one must still exist. Pattern: dump → verify file exists and is non-empty → delete dumps older than 14 days.
5. **Log success/failure per database.** A script that exits 0 after backing up one DB but silently skipping the other is a bug. Log each DB outcome and exit non-zero if any failed.

---

## 11. Backup Workflow

Nightly backup pipeline runs via host cron in the following sequence:

```
02:00  pg_dump logical backups (backup_user)
03:00  pgBackRest incremental backup
04:00  rclone offsite sync
05:00  health-check.sh status log
```

The health check runs after the pipeline completes so it can validate backup freshness.

---

## 12. Restore Procedures

Two restore methods exist depending on failure type.

### Logical Restore

Used for accidental deletes and schema errors.

```bash
# Restore specific database from logical dump
docker exec -i postgres-fin pg_restore -U postgres -d macro < backups/dumps/macro_20260301.dump

# Or restore to a test database first to verify
docker exec postgres-fin createdb -U postgres macro_restore_test
docker exec -i postgres-fin pg_restore -U postgres -d macro_restore_test < backups/dumps/macro_20260301.dump
```

### Full Cluster Restore

Used for disk corruption and complete database cluster loss.

> **Important:** You cannot `docker exec` into a stopped container. pgBackRest restore requires the Postgres server to be **stopped** while the data directory is restored. The solution is a one-off restore container that mounts the same volume.

```bash
# 1. Stop PostgreSQL
docker compose -f /opt/docker/postgres-fin/docker-compose.yml down

# 2. Clear the corrupted data directory (pgBackRest needs an empty target).
#    The volume still exists after 'down' — we run a temporary container to wipe it.
docker run --rm \
    -v postgres_data:/var/lib/postgresql/data \
    alpine sh -c "rm -rf /var/lib/postgresql/data/*"

# 3. Run pgBackRest restore using a one-off container with the same image
#    and the same volumes (data + backups + config).
#
#    Replace <IMAGE> with the built image name. Find it with:
#      docker compose -f /opt/docker/postgres-fin/docker-compose.yml images
#    It will be something like 'postgres-fin-postgres' or whatever Compose named it.
docker run --rm \
    -v postgres_data:/var/lib/postgresql/data \
    -v /opt/docker/postgres-fin/backups:/backups \
    -v /opt/docker/postgres-fin/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
    <IMAGE> \
    pgbackrest --stanza=main restore

# 4. (Optional) For point-in-time recovery, create a recovery.signal file
#    and set recovery_target_time in postgresql.conf before starting.

# 5. Start PostgreSQL — it will replay WAL to the recovery point.
docker compose -f /opt/docker/postgres-fin/docker-compose.yml up -d
```

> **Why a one-off container:** pgBackRest restores files into the data directory while Postgres is not running. Since the Postgres container's entrypoint starts the server, we use a plain `docker run` with the same image to execute just the restore command. The one-off container exits after restore completes, then the normal `docker compose up` starts the server against the restored data.

### Test Restore

Backups must be verified monthly.

```bash
# Create test target
docker exec postgres-fin createdb -U postgres macro_restore_test

# Restore latest dump
docker exec -i postgres-fin pg_restore -U postgres -d macro_restore_test < backups/dumps/latest.dump

# Verify: schema loads, tables present, row counts reasonable
docker exec postgres-fin psql -U postgres -d macro_restore_test -c "\dt"
docker exec postgres-fin psql -U postgres -d macro_restore_test -c "SELECT COUNT(*) FROM some_table;"

# Cleanup
docker exec postgres-fin dropdb -U postgres macro_restore_test
```

---

## 13. Data Safety Guidelines

### Never sync live database directories

Tools like Syncthing must not sync the live data directory (`/var/lib/postgresql/data`). Live database directories cannot be safely copied while running. Use `pg_dump` or pgBackRest for all backups.

### Always take a dump before migrations

```bash
docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin pg_dump -Fc -U backup_user mtm > backup_before_migration_$(date +%Y%m%d).dump
```

### Separate users per project

Each project has its own DB user. This limits the blast radius of bugs or credential exposure. Application configs must never contain the `postgres` superuser credentials.

### Application containers must wait for DB readiness

Since `postgres-fin` lives in a separate Compose project, application containers **cannot** use `depends_on` to reference it. Instead, each app's startup script must include a wait-for-Postgres step before running migrations or starting the server.

MTM already does this in `start.sh`: it polls Postgres, then runs `alembic upgrade head`, then starts uvicorn. Macro should follow the same pattern. The wait target is `postgres-fin:5432`.

---

## 14. Monitoring

Basic monitoring should include disk usage, WAL growth, backup success, backup age, and slow queries.

Recommended extension: `pg_stat_statements` (enabled in init script).

For monitoring backup health and disk state, see the `health-check.sh` script in Section 17.

---

## 15. Upgrade Strategy

Major PostgreSQL upgrades must follow this sequence:

1. Take a full `pg_dump` of all databases
2. Create the new container image (update pinned version in Dockerfile)
3. Run `pg_upgrade` in a test environment
4. Verify data integrity and application connectivity
5. Switch application connections to the upgraded instance

Never perform a major version upgrade in place without backups and a tested rollback path.

---

## 16. Future Enhancements

| Enhancement | Notes |
|-------------|-------|
| Read replicas | Useful if analytics workloads grow beyond primary capacity |
| Redis query cache | For expensive dashboard queries on Macro Terminal |
| Dedicated backup server | Move pgBackRest repository off the main VPS |
| Logical replication | Stream macro data to downstream services |
| PostGIS | Add to Dockerfile if any project needs geospatial queries |

---

## 17. Health Monitoring

A daily health check script provides early warning of the two most common single-VPS failure modes: disk exhaustion and silent backup failure.

### scripts/health-check.sh

```bash
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
```

### Prerequisites

Create the logs directory before the first health check run:

```bash
mkdir -p /opt/docker/postgres-fin/logs
```

### Cron entry

```
0 5 * * * /opt/docker/postgres-fin/scripts/health-check.sh
```

### What this catches

| Check | Failure Mode It Catches |
|-------|------------------------|
| `disk_pct > 80%` | Early warning before WAL or backup storage fills the disk |
| `no_recent_dump_{db}` | Silent failure of a specific database's nightly pg_dump |
| `pgbackrest not ok` | WAL archiving failure or pgBackRest stanza misconfiguration |
| `backup_size logged` | Trend data for catching unexpected storage growth |
| `container_not_healthy` | Postgres crashed or stuck in recovery |

> **v1.2 change:** Added container health check (item 5). Also fixed pgBackRest commands to run inside the container via `docker exec`.

---

## 18. MTM Migration Plan

This section describes how to move MTM from its current embedded Postgres (`mtmdev-db-1`) to the shared `postgres-fin` instance. This is a **day-one requirement** — the shared stack must work for MTM from the first boot.

### Current State

- MTM's Postgres runs as service `db` inside `/opt/docker/mtm-dev/docker-compose.yml`
- Database name: `mtm_dev`
- Database user: `mtm_user`
- Data volume: `mtmdev_db_data`
- `DATABASE_URL`: `postgresql+asyncpg://mtm_user:PASSWORD@db:5432/mtm_dev`

### Migration Steps

**Step 1: Dump existing MTM database**

```bash
docker compose -f /opt/docker/mtm-dev/docker-compose.yml exec -T db \
    pg_dump -Fc -U mtm_user mtm_dev > /opt/docker/postgres-fin/backups/dumps/mtm_pre_migration.dump
```

**Step 2: Start the shared Postgres stack**

```bash
cd /opt/docker/postgres-fin
docker compose up -d
# Wait for healthy status
docker compose ps
```

The init script creates the `mtm` database, `mtm_user`, and enables extensions automatically.

**Step 3: Restore MTM data into the new database**

```bash
docker exec -i postgres-fin pg_restore -U postgres --no-owner --no-acl -d mtm \
    < /opt/docker/postgres-fin/backups/dumps/mtm_pre_migration.dump
```

`--no-owner --no-acl` ensures objects are created owned by the restoring user and existing grants are applied cleanly.

**Step 4: Update MTM's docker-compose.yml**

Remove the `db` service entirely. Update the backend environment:

```yaml
# Before
DATABASE_URL: postgresql+asyncpg://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}

# After
DATABASE_URL: postgresql+asyncpg://mtm_user:${MTM_DB_PASSWORD}@postgres-fin:5432/mtm
```

Remove `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` from MTM's `.env`. Add `MTM_DB_PASSWORD`.

Ensure the backend service is on the `lalonet_private` network (it already is).

Remove the `db_data` volume definition.

**Step 5: Update MTM's start.sh**

Change the Postgres wait target from `db:5432` to `postgres-fin:5432`.

**Step 6: Verify**

```bash
docker compose -f /opt/docker/mtm-dev/docker-compose.yml up -d --build backend
docker compose -f /opt/docker/mtm-dev/docker-compose.yml exec backend pytest -q
# Expect: 49 passed
```

**Step 7: Clean up old volume**

After verification:

```bash
docker volume rm mtmdev_db_data
```

### Database Rename

The MTM database is renamed from `mtm_dev` to `mtm`. This is intentional — there is no longer a dev/prod split. Alembic migrations are path-independent (they track revision state in the `alembic_version` table inside the database, not externally). The rename is transparent to the application once the `DATABASE_URL` is updated.

---

## 19. Networking Reference

All inter-container communication uses the `lalonet_private` external Docker network. No database ports are exposed to the host.

| Container | Network | How Apps Connect |
|-----------|---------|-----------------|
| `postgres-fin` | `lalonet_private` | `postgres-fin:5432` |
| MTM backend | `lalonet_private` + `default` | Already on `lalonet_private` |
| Macro backend | `lalonet_private` + `default` | Will join `lalonet_private` |

Connection strings use the container name as hostname:

```
postgresql+asyncpg://mtm_user:PASSWORD@postgres-fin:5432/mtm
postgresql+asyncpg://macro_user:PASSWORD@postgres-fin:5432/macro
```

> **Why no host port:** Exposing `5432` to the host creates an attack surface. On a VPS, even with `ufw`, Docker's port mappings bypass iptables rules. The Docker network provides connectivity to all containers that need it without any host exposure.

---

## 20. Summary

The PostgreSQL stack provides shared database infrastructure, TimescaleDB time-series performance, reproducible container builds, safe logical and physical backups, and offsite redundancy.

### Key Technologies

| Component | Tool |
|-----------|------|
| Database | PostgreSQL 16 |
| Time-series extension | TimescaleDB |
| Containerization | Docker / Docker Compose |
| Physical backups | pgBackRest |
| Logical backups | pg_dump (via backup_user) |
| Offsite sync | rclone |
| Integrity protection | Data checksums + healthcheck |
| Monitoring | health-check.sh (daily cron) |
| Networking | lalonet_private (no host port exposure) |
