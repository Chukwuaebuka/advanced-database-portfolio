-- One clerk inserting a pickup visit, used by run_concurrency_demo.sh (Demo 4).
-- Variables: name, art, pickup (date 'YYYY-MM-DD'), hold (seconds before COMMIT)
\set QUIET on
\pset footer off
\pset tuples_only on
\pset format unaligned
\pset fieldsep ' | '

BEGIN;
SELECT clock_timestamp()::time(3), :'name' || ': inserting pickup for ' || :'pickup';

INSERT INTO ART_Pickups (art_id, facility_id, pickup_date, months_dispensed, next_appointment_date)
SELECT art_id, facility_id, DATE :'pickup', 3, DATE :'pickup' + 90
FROM ART_Enrollments WHERE art_id = :art;

SELECT clock_timestamp()::time(3), :'name' || ': insert returned';
SELECT pg_sleep(:hold) \g /dev/null
COMMIT;
SELECT clock_timestamp()::time(3), :'name' || ': transaction ended';
