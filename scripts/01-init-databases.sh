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
