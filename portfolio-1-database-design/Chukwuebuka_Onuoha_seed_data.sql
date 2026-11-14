-- =========================================================================
-- ECEWS SPEED Osun Hub - Synthetic Seed Data
-- ALL DATA IS SYNTHETIC. No real client/patient records are used.
-- Run after create_tables.sql. Deterministic (setseed) so results are
-- reproducible. Reference "today" for the data set is 2026-11-01.
-- Approx volume: 50k clients, 30k ART enrolments, ~400k pickups,
-- ~55k TB screenings, ~60k viral load results.
-- =========================================================================

SELECT setseed(0.42);

-- 30 Osun State LGAs grouped by senatorial district
INSERT INTO LGAs (lga_name, senatorial_district) VALUES
 ('Boluwaduro','Osun Central'),('Boripe','Osun Central'),('Ifedayo','Osun Central'),
 ('Ifelodun','Osun Central'),('Ila','Osun Central'),('Irepodun','Osun Central'),
 ('Odo Otin','Osun Central'),('Olorunda','Osun Central'),('Orolu','Osun Central'),
 ('Osogbo','Osun Central'),
 ('Atakumosa East','Osun East'),('Atakumosa West','Osun East'),('Ife Central','Osun East'),
 ('Ife East','Osun East'),('Ife North','Osun East'),('Ife South','Osun East'),
 ('Ilesa East','Osun East'),('Ilesa West','Osun East'),('Obokun','Osun East'),
 ('Oriade','Osun East'),
 ('Aiyedaade','Osun West'),('Aiyedire','Osun West'),('Ede North','Osun West'),
 ('Ede South','Osun West'),('Egbedore','Osun West'),('Ejigbo','Osun West'),
 ('Irewole','Osun West'),('Isokan','Osun West'),('Iwo','Osun West'),
 ('Ola Oluwa','Osun West');

-- 3 facilities per LGA (90 total)
INSERT INTO Facilities (facility_name, lga_id, facility_type)
SELECT l.lga_name || ' ' || t.ftype, l.lga_id, t.ftype
FROM LGAs l
CROSS JOIN (VALUES ('Primary Health Centre'), ('General Hospital'), ('Comprehensive Health Centre')) t(ftype)
ORDER BY l.lga_id;

-- 50,000 clients; Osogbo (state capital) deliberately over-represented (~15%)
INSERT INTO Clients (pepfar_uid, first_name, last_name, dob, gender, lga_id, date_registered)
SELECT 'OS-' || lpad(g::text, 6, '0'),
       (ARRAY['Adebayo','Funmilayo','Olumide','Aisha','Tunde','Bisi','Kehinde','Yetunde','Segun','Ngozi','Ibrahim','Folake'])[1 + floor(random() * 12)::int],
       (ARRAY['Adeyemi','Ogunleye','Afolabi','Olawale','Bello','Adeleke','Oyewole','Akinola','Salami','Ojo'])[1 + floor(random() * 10)::int],
       DATE '1960-01-01' + floor(random() * 15000)::int,
       CASE WHEN random() < 0.6 THEN 'Female' ELSE 'Male' END,
       CASE WHEN random() < 0.15 THEN (SELECT lga_id FROM LGAs WHERE lga_name = 'Osogbo')
            ELSE 1 + floor(random() * 30)::int END,
       TIMESTAMP '2022-01-01' + random() * (TIMESTAMP '2026-06-30' - TIMESTAMP '2022-01-01')
FROM generate_series(1, 50000) g;

-- 20 outreach events per LGA
INSERT INTO Community_Outreaches (lga_id, outreach_date, location_name)
SELECT l.lga_id,
       DATE '2022-01-01' + floor(random() * 1640)::int,
       l.lga_name || ' Community Outreach #' || g
FROM LGAs l CROSS JOIN generate_series(1, 20) g;

-- One HTS encounter per client: 30% community, 70% facility; 60% positive
WITH s AS MATERIALIZED (
    SELECT c.client_id,
           c.date_registered::date AS reg_date,
           random() < 0.3          AS is_community,
           random()                AS r,
           f.facility_id,
           o.outreach_id,
           o.outreach_date
    FROM Clients c
    CROSS JOIN LATERAL (SELECT f2.facility_id FROM Facilities f2
                        WHERE f2.lga_id = c.lga_id ORDER BY random() LIMIT 1) f
    CROSS JOIN LATERAL (SELECT o2.outreach_id, o2.outreach_date FROM Community_Outreaches o2
                        WHERE o2.lga_id = c.lga_id ORDER BY random() LIMIT 1) o
)
INSERT INTO HTS_Encounters (client_id, facility_id, outreach_id, testing_point, hiv_status, encounter_date)
SELECT client_id,
       CASE WHEN is_community THEN NULL ELSE facility_id END,
       CASE WHEN is_community THEN outreach_id END,
       CASE WHEN is_community THEN 'Community-Outreach'
            ELSE (ARRAY['Facility-OPD','Facility-ANC','Facility-TB','Index-Testing'])[1 + floor(r * 4)::int] END,
       CASE WHEN client_id % 5 < 3 THEN 'Positive' ELSE 'Negative' END,
       reg_date
FROM s;

-- ART enrolment for every positive client (placeholder pickup dates, fixed below)
WITH s AS MATERIALIZED (
    SELECT h.client_id,
           COALESCE(h.facility_id, f.facility_id) AS facility_id,
           LEAST(h.encounter_date + floor(random() * 14)::int, DATE '2026-10-31') AS enrol_date,
           random() AS r1, random() AS r2, random() AS r3
    FROM HTS_Encounters h
    JOIN Clients c ON c.client_id = h.client_id
    CROSS JOIN LATERAL (SELECT f2.facility_id FROM Facilities f2
                        WHERE f2.lga_id = c.lga_id ORDER BY random() LIMIT 1) f
    WHERE h.hiv_status = 'Positive'
)
INSERT INTO ART_Enrollments (client_id, facility_id, enrollment_date, clinical_stage, regimen_line, regimen,
                             current_status, last_pickup_date, next_appointment_date)
SELECT client_id, facility_id, enrol_date,
       CASE WHEN r1 < 0.50 THEN 1 WHEN r1 < 0.80 THEN 2 WHEN r1 < 0.95 THEN 3 ELSE 4 END,
       CASE WHEN r2 < 0.85 THEN 'First-Line' WHEN r2 < 0.98 THEN 'Second-Line' ELSE 'Third-Line' END,
       CASE WHEN r2 < 0.85 THEN 'TLD' WHEN r2 < 0.98 THEN 'AZT/3TC/ATV/r' ELSE 'DRV/r + DTG' END,
       CASE WHEN r3 < 0.85 THEN 'Active' WHEN r3 < 0.90 THEN 'Transferred-Out'
            WHEN r3 < 0.98 THEN 'Lost-To-Follow-Up' ELSE 'Deceased' END,
       enrol_date, enrol_date + 30
FROM s;

-- Pickup history. Each client has a fixed MMD interval (1, 3 or 6 months).
-- Active clients' last pickup is jittered up to 120 days back so that some
-- have missed their next appointment; inactive clients stop a year earlier.
INSERT INTO ART_Pickups (art_id, facility_id, pickup_date, months_dispensed, next_appointment_date)
SELECT a.art_id,
       a.facility_id,
       a.enrollment_date + k * m.months * 30,
       m.months,
       a.enrollment_date + (k + 1) * m.months * 30
FROM ART_Enrollments a
CROSS JOIN LATERAL (SELECT (ARRAY[1, 3, 3, 3, 6])[1 + (a.art_id % 5)] AS months) m
CROSS JOIN LATERAL generate_series(
    0,
    GREATEST(0, ((DATE '2026-11-01' - (a.art_id % 120)
                  - CASE WHEN a.current_status <> 'Active' THEN 365 ELSE 0 END)
                 - a.enrollment_date) / (m.months * 30))
) k;

-- Sync the enrolment "current snapshot" with the latest pickup
UPDATE ART_Enrollments a
SET last_pickup_date      = p.pickup_date,
    next_appointment_date = p.next_appointment_date
FROM (SELECT DISTINCT ON (art_id) art_id, pickup_date, next_appointment_date
      FROM ART_Pickups ORDER BY art_id, pickup_date DESC) p
WHERE a.art_id = p.art_id;

-- TB screening at enrolment and 6 months later (~4% confirmed, ~11% presumptive)
WITH s AS MATERIALIZED (
    SELECT a.client_id, a.facility_id,
           a.enrollment_date + k * 180 AS screening_date,
           random() AS r, random() AS r2
    FROM ART_Enrollments a
    CROSS JOIN generate_series(0, 1) k
    WHERE a.enrollment_date + k * 180 <= DATE '2026-11-01'
), t AS (
    SELECT s.*,
           CASE WHEN r < 0.04 THEN 'Confirmed-TB' WHEN r < 0.15 THEN 'Presumptive' ELSE 'No-Signs' END AS tb_status
    FROM s
)
INSERT INTO TB_Screening_Outcomes (client_id, facility_id, screening_date, cough_status, fever_status,
                                   tb_status, tb_treatment_started, treatment_outcome)
SELECT client_id, facility_id, screening_date,
       tb_status <> 'No-Signs' AND r2 < 0.8,
       tb_status <> 'No-Signs' AND r2 > 0.4,
       tb_status,
       tb_status = 'Confirmed-TB',
       CASE WHEN tb_status = 'Confirmed-TB'
            THEN (ARRAY['Ongoing','Cured','Treatment-Completed','Failed'])[1 + floor(r2 * 4)::int]
            ELSE 'Not-Applicable' END
FROM t;

-- Viral load: first at 6 months on ART, then yearly. Samples from the last
-- month are still Pending. ~88% of resulted tests are suppressed.
WITH s AS MATERIALIZED (
    SELECT a.client_id, a.facility_id,
           a.enrollment_date + 180 + k * 365 AS sample_date,
           random() AS r, random() AS r2
    FROM ART_Enrollments a
    CROSS JOIN generate_series(0, 4) k
    WHERE a.enrollment_date + 180 + k * 365 <= DATE '2026-11-01'
)
INSERT INTO Lab_Viral_Load (client_id, facility_id, sample_collected_date, result_date,
                            viral_load_copies, suppression_status)
SELECT client_id, facility_id, sample_date,
       CASE WHEN sample_date > DATE '2026-10-01' THEN NULL ELSE sample_date + 7 + floor(r2 * 14)::int END,
       CASE WHEN sample_date > DATE '2026-10-01' THEN NULL
            WHEN r < 0.88 THEN 20 + floor(r2 * 979)::int
            ELSE 1000 + floor(r2 * 199000)::int END,
       CASE WHEN sample_date > DATE '2026-10-01' THEN 'Pending'
            WHEN r < 0.88 THEN 'Suppressed' ELSE 'Unsuppressed' END
FROM s;

ANALYZE;

-- Row counts for evidence
SELECT 'LGAs' AS table_name, COUNT(*) FROM LGAs
UNION ALL SELECT 'Facilities', COUNT(*) FROM Facilities
UNION ALL SELECT 'Clients', COUNT(*) FROM Clients
UNION ALL SELECT 'Community_Outreaches', COUNT(*) FROM Community_Outreaches
UNION ALL SELECT 'HTS_Encounters', COUNT(*) FROM HTS_Encounters
UNION ALL SELECT 'ART_Enrollments', COUNT(*) FROM ART_Enrollments
UNION ALL SELECT 'ART_Pickups', COUNT(*) FROM ART_Pickups
UNION ALL SELECT 'TB_Screening_Outcomes', COUNT(*) FROM TB_Screening_Outcomes
UNION ALL SELECT 'Lab_Viral_Load', COUNT(*) FROM Lab_Viral_Load;
