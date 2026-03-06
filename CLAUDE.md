# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Shared PostgreSQL/TimescaleDB stack for internal finance projects (Macro Terminal, MTM). Container name: `postgres-fin`. Base image: `timescale/timescaledb:2.17.2-pg16` with pgBackRest added via Dockerfile.

## Common Commands

```bash
# Build and start
docker compose up -d --build

# Stop
docker compose down

# Logs
docker compose logs -f

# Connect via psql (superuser)
docker exec -it postgres-fin psql -U postgres

# Connect as app user
docker exec -it postgres-fin psql -U macro_user -d macro
docker exec -it postgres-fin psql -U mtm_user -d mtm

# Dump a database (as backup_user)
source .env
docker exec -e PGPASSWORD="$BACKUP_PASSWORD" postgres-fin pg_dump -Fc -U backup_user macro > backups/dumps/macro_$(date +%Y%m%d).dump

# Restore a dump
docker exec -i postgres-fin pg_restore -U postgres -d macro < backups/dumps/macro_YYYYMMDD.dump

# pgBackRest status (must run as postgres user)
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest info --stanza=main"

# Health check
./scripts/health-check.sh
```

## Architecture

- **Single Postgres instance** hosting two databases: `macro` (Macro Terminal) and `mtm` (MTM portfolio tracking)
- **No host port exposure** — all connections via `lalonet_private` Docker network at `postgres-fin:5432`
- **Init script** (`scripts/01-init-databases.sh`) runs once on first boot: creates users, databases, extensions (timescaledb, pg_stat_statements). It's a shell script (not SQL) because the Postgres entrypoint doesn't substitute env vars in `.sql` files.
- **Custom config** at `config/postgresql.conf` and `config/pg_hba.conf`, loaded via `command: postgres -c config_file=/etc/postgresql/postgresql.conf`
- Data volume is explicitly named `postgres_data` (no Compose project prefix)

## Role Hierarchy

| Role | Access |
|------|--------|
| `postgres` | Superuser — admin only, never in app configs |
| `macro_user` | Owns `macro` database |
| `mtm_user` | Owns `mtm` database |
| `backup_user` | Read-only (`pg_read_all_data`) — dump scripts only |

Passwords are in `.env` (not tracked): `POSTGRES_PASSWORD`, `MACRO_PASSWORD`, `MTM_PASSWORD`, `BACKUP_PASSWORD`.

## Backup Layers

1. **pg_dump** (logical) — nightly per-database dumps to `backups/dumps/`, 14-day retention
2. **pgBackRest** (physical) — weekly full + daily incremental, WAL archiving, config at `config/pgbackrest.conf`
3. **rclone** (offsite) — syncs `backups/` to remote object storage

Cron pipeline: 02:00 dumps, 03:00 pgBackRest, 04:00 rclone, 05:00 health check.

## Key Constraints

- App containers (MTM, Macro) are in separate Compose projects — they **cannot** use `depends_on`. Each app must poll `postgres-fin:5432` in its entrypoint before running migrations.
- The `scripts/` directory is NOT mounted into `/docker-entrypoint-initdb.d/`. Only `01-init-databases.sh` is COPYed in via Dockerfile to prevent backup/restore scripts from executing on first boot.
- WAL archiving failure can cause disk exhaustion even with `max_wal_size` set — it's not a hard ceiling. The health check script monitors this.
- Data checksums are enabled (`--data-checksums`) to detect silent disk corruption.

## Alpine Base Image

The TimescaleDB image is Alpine-based (not Debian). Packages are installed with `apk`, not `apt-get`. Alpine's pgbackrest package lacks zstd support — use `compress-type=gz` in pgbackrest.conf.

## pgBackRest Operations

pgBackRest commands must run as the `postgres` OS user (not `root`):

```bash
# All pgbackrest commands inside the container
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main <command>"

# First-time stanza init (after first container start)
docker exec postgres-fin su -s /bin/sh postgres -c "pgbackrest --stanza=main stanza-create"
```

The Dockerfile creates `/var/log/pgbackrest` and `/tmp/pgbackrest` owned by `postgres:postgres` for logs and lock files. The `pg_hba.conf` uses `local all all trust` so pgBackRest (running as any local user) can connect to verify the cluster.

## Full Spec

See `postgres_spec_v1.2.md` (current version: 1.4) for complete details including restore procedures, MTM migration plan, upgrade strategy, and networking reference.
