-- One data clerk's "read -> think -> write" session, used by run_concurrency_demo.sh.
-- Variables (passed with -v):
--   name  : label printed in the log (e.g. 'Clerk A')
--   art   : art_id being edited
--   iso   : isolation level, e.g. 'READ COMMITTED' or 'REPEATABLE READ'
--   lock  : '' (plain read) or 'FOR UPDATE' (pessimistic row lock)
--   add   : days to add to the appointment the clerk READ
--   hold  : seconds the clerk "thinks" between reading and writing
\set QUIET on
\pset footer off
\pset tuples_only on
\pset format unaligned
\pset fieldsep ' | '

BEGIN ISOLATION LEVEL :iso;
SELECT clock_timestamp()::time(3), :'name' || ': BEGIN ' || :'iso' || CASE WHEN :'lock' <> '' THEN ' (SELECT ... ' || :'lock' || ')' ELSE '' END;

SELECT next_appointment_date AS appt FROM ART_Enrollments WHERE art_id = :art :lock \gset
SELECT clock_timestamp()::time(3), :'name' || ': read next_appointment_date = ' || :'appt';

SELECT pg_sleep(:hold) \g /dev/null

UPDATE ART_Enrollments SET next_appointment_date = DATE :'appt' + :add WHERE art_id = :art;
SELECT clock_timestamp()::time(3), :'name' || ': wrote ' || :'appt' || ' + ' || :'add' || ' days = ' || (DATE :'appt' + :add);

COMMIT;
SELECT clock_timestamp()::time(3), :'name' || ': transaction ended';
