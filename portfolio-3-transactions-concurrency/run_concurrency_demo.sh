#!/usr/bin/env bash
# =========================================================================
# ECEWS SPEED Osun Hub - Two-session concurrency demonstrations.
# Runs two psql sessions ("Clerk A" and "Clerk B") at the same time against
# the same client record and prints a timestamped log of what happened.
#
# Usage:
#   PSQL="psql -d speed_osun" ./run_concurrency_demo.sh
#   PSQL="docker exec -i adbs-pg psql -U postgres -d speed_osun" ./run_concurrency_demo.sh
# Save evidence:
#   ./run_concurrency_demo.sh > evidence/concurrency_output.txt 2>&1
# =========================================================================
set -u
cd "$(dirname "$0")"
PSQL=${PSQL:-"psql -d speed_osun"}
run() { $PSQL -X -q -P pager=off "$@"; }
LOG_A=$(mktemp); LOG_B=$(mktemp)
show_logs() { echo "--- Clerk A log ---"; cat "$LOG_A"; echo "--- Clerk B log ---"; cat "$LOG_B"; }

ART=$(run -At -c "SELECT art_id FROM ART_Enrollments WHERE current_status='Active' ORDER BY art_id OFFSET 10 LIMIT 1")
ORIG=$(run -At -c "SELECT next_appointment_date FROM ART_Enrollments WHERE art_id=$ART")
BASE='2027-01-04'

reset_row() { run -c "UPDATE ART_Enrollments SET next_appointment_date = DATE '$BASE' WHERE art_id = $ART" >/dev/null; }
final()     { echo "Final next_appointment_date = $(run -At -c "SELECT next_appointment_date FROM ART_Enrollments WHERE art_id=$ART")"; }

# clerk NAME ISO LOCK ADD HOLD
clerk() {
  run -v ON_ERROR_STOP=0 -v name="$1" -v art="$ART" -v iso="$2" -v lock="$3" -v add="$4" -v hold="$5" \
      < clerk_extend_appointment.sql 2>&1 | sed "s/^psql:<stdin>:[0-9]*: /    [$1] /"
}

scenario() {   # ISO LOCK
  reset_row
  echo "Start: next_appointment_date = $BASE. Clerk A adds 90 days (3-month MMD), Clerk B adds 30 days (top-up)."
  echo "Correct serial result would be $BASE + 120 days = $(date -j -v+120d -f %Y-%m-%d "$BASE" +%Y-%m-%d 2>/dev/null || date -d "$BASE +120 days" +%Y-%m-%d)"
  clerk "Clerk A" "$1" "$2" 90 2 > "$LOG_A" &
  sleep 0.5
  clerk "Clerk B" "$1" "$2" 30 3 > "$LOG_B" &
  wait
  show_logs
  final
}

echo "Client art_id used: $ART"
echo
echo "========== Demo 1: LOST UPDATE under READ COMMITTED with plain SELECT =========="
scenario "READ COMMITTED" ""
echo
echo "========== Demo 2: Pessimistic locking - SELECT ... FOR UPDATE (READ COMMITTED) =========="
scenario "READ COMMITTED" "FOR UPDATE"
echo
echo "========== Demo 3: Optimistic control - REPEATABLE READ detects the conflict =========="
scenario "REPEATABLE READ" ""
echo
echo "========== Demo 4: Duplicate pickup entry from two workstations (UNIQUE constraint) =========="
PICK='2027-01-05'
run -c "DELETE FROM ART_Pickups WHERE art_id=$ART AND pickup_date=DATE '$PICK'" >/dev/null
pickup() { run -v ON_ERROR_STOP=0 -v name="$1" -v art="$ART" -v pickup="$PICK" -v hold="$2" \
              < clerk_record_pickup.sql 2>&1 | sed "s/^psql:<stdin>:[0-9]*: /    [$1] /"; }
pickup "Clerk A" 2 > "$LOG_A" &
sleep 0.5
pickup "Clerk B" 0 > "$LOG_B" &
wait
show_logs
echo "Pickup rows for $PICK: $(run -At -c "SELECT COUNT(*) FROM ART_Pickups WHERE art_id=$ART AND pickup_date=DATE '$PICK'")"

# Clean up: restore the client's original state.
run -c "DELETE FROM ART_Pickups WHERE art_id=$ART AND pickup_date=DATE '$PICK'" >/dev/null
run -c "UPDATE ART_Enrollments SET next_appointment_date = DATE '$ORIG' WHERE art_id=$ART" >/dev/null
rm -f "$LOG_A" "$LOG_B"
