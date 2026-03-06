FROM timescale/timescaledb:2.17.2-pg16

# pgBackRest for physical backups + WAL archiving
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
