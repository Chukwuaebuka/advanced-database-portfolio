-- =========================================================================
-- EXPLAIN (ANALYZE, BUFFERS) for each portfolio query.
-- Run once before indexes.sql and once after; save both outputs:
--   psql -d speed_osun -f explain_queries.sql > evidence/explain_before.txt
--   psql -d speed_osun -f indexes.sql
--   psql -d speed_osun -f explain_queries.sql > evidence/explain_after.txt
-- Each query is run once untimed first so that both runs use a warm cache.
-- =========================================================================
\pset pager off
SET max_parallel_workers_per_gather = 0;   -- single-threaded plans: easier to read and compare

\echo '==================== Query 1: IIT risk list ===================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT c.pepfar_uid, l.lga_name, f.facility_name, a.next_appointment_date
FROM ART_Enrollments a
JOIN Clients    c ON c.client_id   = a.client_id
JOIN Facilities f ON f.facility_id = a.facility_id
JOIN LGAs       l ON l.lga_id      = c.lga_id
WHERE a.current_status = 'Active'
  AND a.next_appointment_date < CURRENT_DATE
ORDER BY a.next_appointment_date
LIMIT 50;

\echo '==================== Query 2: LGA TB/HIV cascade ===================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
WITH tb_per_client AS (
    SELECT client_id,
           bool_or(tb_status = 'Presumptive')  AS ever_presumptive,
           bool_or(tb_status = 'Confirmed-TB') AS ever_confirmed,
           bool_or(tb_treatment_started)       AS ever_treated
    FROM TB_Screening_Outcomes GROUP BY client_id
)
SELECT l.lga_name, COUNT(a.art_id),
       COUNT(*) FILTER (WHERE tb.ever_presumptive),
       COUNT(*) FILTER (WHERE tb.ever_confirmed),
       COUNT(*) FILTER (WHERE tb.ever_treated)
FROM LGAs l
JOIN Clients c ON c.lga_id = l.lga_id
JOIN ART_Enrollments a ON a.client_id = c.client_id AND a.current_status = 'Active'
LEFT JOIN tb_per_client tb ON tb.client_id = a.client_id
GROUP BY l.lga_id, l.lga_name;

\echo '==================== Query 3: latest VL unsuppressed ===================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT c.pepfar_uid, v.sample_collected_date, v.viral_load_copies
FROM (SELECT vl.*, ROW_NUMBER() OVER (PARTITION BY vl.client_id
                   ORDER BY vl.sample_collected_date DESC, vl.vload_id DESC) AS rn
      FROM Lab_Viral_Load vl WHERE vl.suppression_status <> 'Pending') v
JOIN Clients c ON c.client_id = v.client_id
JOIN ART_Enrollments a ON a.client_id = v.client_id AND a.current_status = 'Active'
WHERE v.rn = 1 AND v.suppression_status = 'Unsuppressed'
ORDER BY v.viral_load_copies DESC
LIMIT 50;

\echo '==================== Query 4a: client pickup history ===================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT c.pepfar_uid, p.pickup_date, p.months_dispensed, p.next_appointment_date, f.facility_name
FROM Clients c
JOIN ART_Enrollments a ON a.client_id = c.client_id
JOIN ART_Pickups p     ON p.art_id = a.art_id
JOIN Facilities f      ON f.facility_id = p.facility_id
WHERE c.pepfar_uid = 'OS-012345'
ORDER BY p.pickup_date DESC;

\echo '==================== Query 4b: client VL history ===================='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT sample_collected_date, result_date, viral_load_copies, suppression_status
FROM Lab_Viral_Load
WHERE client_id = (SELECT client_id FROM Clients WHERE pepfar_uid = 'OS-012345')
ORDER BY sample_collected_date DESC;
