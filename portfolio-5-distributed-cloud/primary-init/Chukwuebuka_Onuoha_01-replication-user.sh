#!/bin/bash
# Runs once on the primary's first start (docker-entrypoint-initdb.d).
# Creates a dedicated least-privilege replication role and allows it to
# connect for streaming replication.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';"
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
