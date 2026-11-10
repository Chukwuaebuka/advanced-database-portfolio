-- =========================================================================
-- ECEWS SPEED Osun Hub - Transactions (single-session scenarios)
-- Run with psql (uses \gset variables):
--   psql -d speed_osun -f transactions.sql > evidence/transactions_output.txt 2>&1
-- Errors in Scenarios 2 and 4 are INTENTIONAL and demonstrate rollback.
-- Re-runnable.
-- =========================================================================
\set ON_ERROR_STOP off
\set ECHO queries
\pset pager off

SHOW default_transaction_isolation;

-- Pick a real active client to work with.
SELECT art_id, facility_id, last_pickup_date, next_appointment_date
FROM ART_Enrollments WHERE current_status = 'Active' ORDER BY art_id LIMIT 1 \gset

-- =========================================================================
-- Scenario 1: COMMIT - atomic Multi-Month Dispensing (MMD) pickup
-- The pickup history row and the enrolment "current snapshot" must change
-- together, or the retention dashboard (Portfolio 2 Q1) shows wrong data.
-- =========================================================================
BEGIN;

INSERT INTO ART_Pickups (art_id, facility_id, pickup_date, months_dispensed, next_appointment_date)
VALUES (:art_id, :facility_id, DATE :'next_appointment_date', 3, DATE :'next_appointment_date' + 90);

UPDATE ART_Enrollments
SET last_pickup_date      = DATE :'next_appointment_date',
    next_appointment_date = DATE :'next_appointment_date' + 90
WHERE art_id = :art_id;

COMMIT;

-- Verify: both changes are visible together.
SELECT a.art_id, a.last_pickup_date, a.next_appointment_date,
       (SELECT COUNT(*) FROM ART_Pickups p WHERE p.art_id = a.art_id) AS pickup_rows
FROM ART_Enrollments a WHERE a.art_id = :art_id;

-- Capture state for the next scenarios.
SELECT last_pickup_date AS s2_last, next_appointment_date AS s2_next
FROM ART_Enrollments WHERE art_id = :art_id \gset

-- =========================================================================
-- Scenario 2: Automatic ROLLBACK on error (atomicity)
-- The UPDATE succeeds, then the INSERT violates CHECK (months_dispensed IN
-- (1,2,3,6)). PostgreSQL aborts the whole transaction; the earlier UPDATE
-- must NOT survive.
-- =========================================================================
BEGIN;

UPDATE ART_Enrollments
SET last_pickup_date = DATE :'s2_next', next_appointment_date = DATE :'s2_next' + 120
WHERE art_id = :art_id;

INSERT INTO ART_Pickups (art_id, facility_id, pickup_date, months_dispensed, next_appointment_date)
VALUES (:art_id, :facility_id, DATE :'s2_next', 4, DATE :'s2_next' + 120);   -- 4 months: invalid

-- Any further statement is refused until the transaction ends:
SELECT 'this will not run';

ROLLBACK;

-- Verify: dates are unchanged from the end of Scenario 1.
SELECT art_id, last_pickup_date, next_appointment_date,
       (last_pickup_date = DATE :'s2_last' AND next_appointment_date = DATE :'s2_next') AS unchanged
FROM ART_Enrollments WHERE art_id = :art_id;

-- =========================================================================
-- Scenario 3: Explicit ROLLBACK - clerk cancels a mistaken status change
-- =========================================================================
BEGIN;

UPDATE ART_Enrollments SET current_status = 'Deceased' WHERE art_id = :art_id;
SELECT art_id, current_status AS status_inside_txn FROM ART_Enrollments WHERE art_id = :art_id;

ROLLBACK;   -- wrong client selected; undo

SELECT art_id, current_status AS status_after_rollback FROM ART_Enrollments WHERE art_id = :art_id;

-- =========================================================================
-- Scenario 4: SAVEPOINT - partial rollback during new-client registration
-- Register client + HIV test + ART enrolment. The lab clerk then keys an
-- inconsistent VL result (Suppressed with 5,000 copies), which the CHECK
-- constraint rejects. Roll back ONLY the VL insert, store it as Pending,
-- and keep the registration.
-- =========================================================================
DELETE FROM Clients WHERE pepfar_uid = 'OS-DEMO-0001';   -- makes the script re-runnable

BEGIN;

INSERT INTO Clients (pepfar_uid, first_name, last_name, dob, gender, lga_id)
VALUES ('OS-DEMO-0001', 'Demo', 'Client', DATE '1990-05-20', 'Female',
        (SELECT lga_id FROM LGAs WHERE lga_name = 'Osogbo'))
RETURNING client_id AS new_client_id \gset

INSERT INTO HTS_Encounters (client_id, facility_id, testing_point, hiv_status, encounter_date)
VALUES (:new_client_id, :facility_id, 'Facility-OPD', 'Positive', CURRENT_DATE);

INSERT INTO ART_Enrollments (client_id, facility_id, enrollment_date, clinical_stage, regimen_line, regimen,
                             last_pickup_date, next_appointment_date)
VALUES (:new_client_id, :facility_id, CURRENT_DATE, 1, 'First-Line', 'TLD', CURRENT_DATE, CURRENT_DATE + 30);

SAVEPOINT before_lab;

INSERT INTO Lab_Viral_Load (client_id, facility_id, sample_collected_date, result_date, viral_load_copies, suppression_status)
VALUES (:new_client_id, :facility_id, CURRENT_DATE, CURRENT_DATE, 5000, 'Suppressed');   -- inconsistent: rejected

ROLLBACK TO SAVEPOINT before_lab;

INSERT INTO Lab_Viral_Load (client_id, facility_id, sample_collected_date, suppression_status)
VALUES (:new_client_id, :facility_id, CURRENT_DATE, 'Pending');

COMMIT;

-- Verify: client, HTS and ART enrolment were kept; only the bad VL row was discarded.
SELECT c.pepfar_uid,
       (SELECT COUNT(*) FROM HTS_Encounters  h WHERE h.client_id = c.client_id) AS hts_rows,
       (SELECT COUNT(*) FROM ART_Enrollments a WHERE a.client_id = c.client_id) AS art_rows,
       (SELECT string_agg(suppression_status, ',') FROM Lab_Viral_Load v WHERE v.client_id = c.client_id) AS vl_rows
FROM Clients c WHERE c.pepfar_uid = 'OS-DEMO-0001';

-- =========================================================================
-- Scenario 5: Constraint as concurrency/integrity control
-- Re-entering the same pickup visit (same client, same day) is rejected by
-- UNIQUE (art_id, pickup_date), even if two workstations try it at once
-- (see run_concurrency_demo.sh, Demo 4).
-- =========================================================================
INSERT INTO ART_Pickups (art_id, facility_id, pickup_date, months_dispensed, next_appointment_date)
VALUES (:art_id, :facility_id, DATE :'s2_last', 3, DATE :'s2_last' + 90);
