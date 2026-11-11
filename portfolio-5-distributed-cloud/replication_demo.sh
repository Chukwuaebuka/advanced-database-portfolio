#!/usr/bin/env bash
# =========================================================================
# Replication, read-only standby and failover demonstration.
# Prerequisite: docker compose up -d   (in this folder)
#   ./replication_demo.sh > evidence/replication_output.txt 2>&1
# WARNING: step 6 stops the primary and promotes the replica. Run
#   docker compose down -v && docker compose up -d   to start over.
# =========================================================================
set -u
cd "$(dirname "$0")"
P() { docker exec -i speed-primary psql -X -U postgres -d speed_osun -P pager=off "$@"; }
R() { docker exec -i speed-replica psql -X -U postgres -d speed_osun -P pager=off "$@"; }
h() { echo; echo "==================== $* ===================="; }

h "0. Waiting for replica to accept connections"
for i in $(seq 1 60); do R -Atc "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
echo "ready"

h "1. Replication status on PRIMARY (pg_stat_replication)"
P -c "SELECT application_name, client_addr, state, sync_state,
             sent_lsn, replay_lsn, write_lag, replay_lag
      FROM pg_stat_replication;"
P -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;"

h "2. Roles: primary vs replica"
P -c "SELECT 'primary' AS node, pg_is_in_recovery() AS in_recovery;"
R -c "SELECT 'replica' AS node, pg_is_in_recovery() AS in_recovery;"

h "3. Data was cloned: row counts on both nodes"
P -Atc "SELECT 'primary clients=' || COUNT(*) FROM Clients;"
R -Atc "SELECT 'replica clients=' || COUNT(*) FROM Clients;"

h "4. Write on primary -> visible on replica (asynchronous replication)"
P -c "DELETE FROM Clients WHERE pepfar_uid LIKE 'OS-REPL-%';" >/dev/null
P -c "INSERT INTO Clients (pepfar_uid, first_name, last_name, dob, gender, lga_id)
      VALUES ('OS-REPL-0001', 'Replica', 'Test', '1991-01-01', 'Male', 1)
      RETURNING pepfar_uid, clock_timestamp()::time(3) AS committed_on_primary;"
R -c "SELECT pepfar_uid, clock_timestamp()::time(3) AS read_on_replica
      FROM Clients WHERE pepfar_uid = 'OS-REPL-0001';"
R -c "SELECT pg_last_wal_replay_lsn() AS replica_replayed_lsn,
             now() - pg_last_xact_replay_timestamp() AS time_since_last_replayed_txn;"
P -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind
      FROM pg_stat_replication;"

h "5. Replica is read-only (writes rejected)"
R -c "INSERT INTO Clients (pepfar_uid, first_name, last_name, dob, gender, lga_id)
      VALUES ('OS-REPL-0002', 'Should', 'Fail', '1991-01-01', 'Male', 1);" 2>&1

h "6. FAILOVER: stop primary, promote replica"
docker stop speed-primary >/dev/null && echo "primary stopped at $(date +%H:%M:%S)"
R -c "SELECT pg_promote(wait => true) AS promoted;"
R -c "SELECT pg_is_in_recovery() AS in_recovery_after_promote;"
R -c "INSERT INTO Clients (pepfar_uid, first_name, last_name, dob, gender, lga_id)
      VALUES ('OS-REPL-0003', 'After', 'Failover', '1991-01-01', 'Female', 1)
      RETURNING pepfar_uid, 'write accepted by new primary' AS result;"
R -Atc "SELECT 'clients on new primary=' || COUNT(*) FROM Clients;"
