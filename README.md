# postgres-fin

Shared PostgreSQL/TimescaleDB stack for internal finance projects (Macro Terminal, MTM).

## Quick Start

```bash
# 1. Create .env from template
cp .env.template .env
# Edit .env with real passwords

# 2. Build and start
docker compose up -d --build

# 3. Verify
docker compose ps                          # should show "healthy"
docker exec postgres-fin psql -U postgres -c "\l"   # should list macro, mtm

# 4. Initialize pgBackRest (once, after first start)
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main stanza-create"

# 5. Take first full backup
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main backup --type=full"
```

## What's Running

A single Postgres 16 container with TimescaleDB 2.17.2, hosting two databases:

| Database | Owner | Purpose |
|----------|-------|---------|
| `macro` | `macro_user` | Macro Terminal data platform |
| `mtm` | `mtm_user` | Mark-to-market portfolio tracking |

No ports are exposed to the host. App containers connect via the `lalonet_private` Docker network at `postgres-fin:5432`.

## Connecting

```bash
# Superuser (admin only)
docker exec -it postgres-fin psql -U postgres

# App users
docker exec -it postgres-fin psql -U macro_user -d macro
docker exec -it postgres-fin psql -U mtm_user -d mtm
```

From app containers, use connection strings like:
```
postgresql+asyncpg://mtm_user:PASSWORD@postgres-fin:5432/mtm
```

## Roles

| Role | Purpose |
|------|---------|
| `postgres` | Superuser. Admin only, never in app configs. |
| `macro_user` | Owns `macro` database. Used by Macro Terminal. |
| `mtm_user` | Owns `mtm` database. Used by MTM. |
| `backup_user` | Read-only (`pg_read_all_data`). Used by dump scripts only. |

## Backups

Three layers protect against different failure modes.

### Layer 1: pg_dump (logical)

Nightly per-database dumps with 14-day retention. Run by `scripts/backup-dump.sh`.

```bash
# Manual dump
source .env
docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin \
    pg_dump -Fc -U backup_user macro > backups/dumps/macro_$(date +%Y%m%d).dump

# Restore a dump
docker exec -i postgres-fin pg_restore -U postgres -d macro < backups/dumps/macro_YYYYMMDD.dump
```

### Layer 2: pgBackRest (physical)

Weekly full + daily incremental backups with continuous WAL archiving. Supports point-in-time recovery.

```bash
# Check status
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest info --stanza=main"

# Manual full backup
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main backup --type=full"

# Manual incremental backup
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main backup --type=incr"
```

All pgBackRest commands must run as the `postgres` OS user (`su -s /bin/sh postgres -c "..."`).

### Layer 3: rclone (offsite)

Syncs `backups/` to remote object storage (not yet configured).

### Cron Schedule

| Time | Job |
|------|-----|
| 02:00 | `scripts/backup-dump.sh` — pg_dump both databases |
| 03:00 | pgBackRest incremental backup |
| 04:00 | rclone offsite sync |
| 05:00 | `scripts/health-check.sh` — disk, dump freshness, container health |

## Health Monitoring

```bash
./scripts/health-check.sh
```

Checks disk usage (>80% warns), per-database dump freshness (must exist within 24h), pgBackRest stanza status, backup storage size, and container health. Writes JSON log lines to `logs/`.

## Restore Procedures

### Logical restore (accidental delete, schema mistake)

```bash
# Restore to production database
docker exec -i postgres-fin pg_restore -U postgres -d macro < backups/dumps/macro_YYYYMMDD.dump

# Or restore to a test database first
docker exec postgres-fin createdb -U postgres macro_restore_test
docker exec -i postgres-fin pg_restore -U postgres -d macro_restore_test < backups/dumps/macro_YYYYMMDD.dump
# Verify, then: docker exec postgres-fin dropdb -U postgres macro_restore_test
```

### Full cluster restore (disk corruption, data loss)

```bash
# 1. Stop Postgres
docker compose down

# 2. Clear corrupted data
docker run --rm -v postgres_data:/var/lib/postgresql/data alpine sh -c "rm -rf /var/lib/postgresql/data/*"

# 3. Restore via pgBackRest (use image name from: docker compose images)
docker run --rm \
    -v postgres_data:/var/lib/postgresql/data \
    -v $(pwd)/backups:/backups \
    -v $(pwd)/config/pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf:ro \
    <IMAGE> \
    pgbackrest --stanza=main restore

# 4. Start Postgres (replays WAL to recovery point)
docker compose up -d
```

## Updating

### Rebuild after config changes

Config files in `config/` are handled differently:

- `pgbackrest.conf` — bind-mounted, changes take effect on container restart
- `postgresql.conf`, `pg_hba.conf` — baked into the image via `COPY`, require a rebuild

```bash
# After editing postgresql.conf or pg_hba.conf
docker compose up -d --build

# After editing pgbackrest.conf
docker compose restart
```

### Upgrading TimescaleDB / PostgreSQL

1. Take a full backup: `pg_dump` of both databases + pgBackRest full backup
2. Update the version tag in `Dockerfile` (e.g., `timescale/timescaledb:2.18.0-pg16`)
3. Rebuild: `docker compose up -d --build`
4. Verify: check databases, extensions, and run app tests

For **major** PostgreSQL version upgrades (e.g., pg16 to pg17), see the full spec (`postgres_spec_v1.2.md`, Section 15). Never upgrade in place without backups and a tested rollback path.

## File Layout

```
postgres-fin/
├── Dockerfile                  # Image: TimescaleDB + pgBackRest
├── docker-compose.yml          # Service definition
├── .env                        # Passwords (not tracked)
├── .env.template               # Password template
├── config/
│   ├── postgresql.conf         # WAL, connections, extensions
│   ├── pg_hba.conf             # Authentication rules
│   └── pgbackrest.conf         # Backup retention and compression
├── scripts/
│   ├── 01-init-databases.sh    # First-boot: users, databases, extensions
│   ├── backup-dump.sh          # Nightly pg_dump script
│   └── health-check.sh         # Daily health monitoring
├── backups/                    # Not tracked
│   ├── dumps/                  # pg_dump output
│   ├── pgbackrest/             # Physical backups + WAL archive
│   └── restore-tests/
└── logs/                       # Not tracked
```

## Implementation Notes

- **Alpine-based image**: The TimescaleDB image uses Alpine Linux. Packages install via `apk`, not `apt-get`.
- **pgBackRest compression**: Uses `gz` (gzip) because Alpine's pgbackrest package lacks zstd support.
- **Data checksums**: Enabled via `POSTGRES_INITDB_ARGS="--data-checksums"` to detect silent disk corruption.
- **WAL archiving**: `archive_command` pushes WAL to pgBackRest. If archiving fails, WAL accumulates in `pg_wal/` regardless of `max_wal_size` — the health check monitors for this.
- **App container startup**: Apps in separate Compose projects cannot use `depends_on`. Each app must poll `postgres-fin:5432` before running migrations.

## Full Spec

See `postgres_spec_v1.2.md` (v1.4) for complete details including the MTM migration plan, networking reference, and design rationale.
