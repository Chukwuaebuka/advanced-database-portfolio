-- =========================================================================
-- ECEWS SPEED Osun Hub - Query Processing & Optimisation
-- Run after portfolio-1 create_tables.sql + seed_data.sql.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Query 1: Interruption-in-Treatment (IIT) risk list  (multi-table join)
-- Active ART clients whose next appointment has passed. Clients more than
-- 28 days late are classed as IIT per PEPFAR definitions.
-- -------------------------------------------------------------------------
SELECT c.pepfar_uid,
       c.first_name || ' ' || c.last_name AS client_name,
       l.lga_name,
       f.facility_name,
       a.regimen,
       a.last_pickup_date,
       a.next_appointment_date,
       CURRENT_DATE - a.next_appointment_date AS days_late,
       CASE WHEN CURRENT_DATE - a.next_appointment_date > 28 THEN 'IIT (>28 days late)'
            ELSE 'Missed appointment' END AS retention_flag
FROM ART_Enrollments a
JOIN Clients    c ON c.client_id   = a.client_id
JOIN Facilities f ON f.facility_id = a.facility_id
JOIN LGAs       l ON l.lga_id      = c.lga_id
WHERE a.current_status = 'Active'
  AND a.next_appointment_date < CURRENT_DATE
ORDER BY a.next_appointment_date
LIMIT 50;

-- -------------------------------------------------------------------------
-- Query 2: LGA-level TB/HIV co-infection cascade  (CTE + aggregation)
-- Counts CLIENTS (not screening rows): a client screened twice is counted
-- once, using bool_or() per client before the LGA roll-up.
-- -------------------------------------------------------------------------
WITH tb_per_client AS (
    SELECT client_id,
           bool_or(tb_status = 'Presumptive')  AS ever_presumptive,
           bool_or(tb_status = 'Confirmed-TB') AS ever_confirmed,
           bool_or(tb_treatment_started)       AS ever_treated
    FROM TB_Screening_Outcomes
    GROUP BY client_id
)
SELECT l.lga_name,
       COUNT(a.art_id)                                  AS active_art_clients,
       COUNT(*) FILTER (WHERE tb.ever_presumptive)      AS presumptive_tb_clients,
       COUNT(*) FILTER (WHERE tb.ever_confirmed)        AS confirmed_tb_coinfected,
       COUNT(*) FILTER (WHERE tb.ever_treated)          AS tb_treatment_initiated,
       ROUND(100.0 * COUNT(*) FILTER (WHERE tb.ever_confirmed)
             / NULLIF(COUNT(a.art_id), 0), 2)           AS coinfection_rate_pct
FROM LGAs l
JOIN Clients c              ON c.lga_id = l.lga_id
JOIN ART_Enrollments a      ON a.client_id = c.client_id AND a.current_status = 'Active'
LEFT JOIN tb_per_client tb  ON tb.client_id = a.client_id
GROUP BY l.lga_id, l.lga_name
ORDER BY confirmed_tb_coinfected DESC;

-- -------------------------------------------------------------------------
-- Query 3: Clients whose MOST RECENT viral load is unsuppressed
-- (derived-table subquery + window function). These need enhanced adherence
-- counselling (EAC). Earlier unsuppressed results that have since been
-- re-suppressed are correctly excluded.
-- -------------------------------------------------------------------------
SELECT c.pepfar_uid,
       f.facility_name,
       v.sample_collected_date,
       v.viral_load_copies
FROM (
    SELECT vl.*,
           ROW_NUMBER() OVER (PARTITION BY vl.client_id
                              ORDER BY vl.sample_collected_date DESC, vl.vload_id DESC) AS rn
    FROM Lab_Viral_Load vl
    WHERE vl.suppression_status <> 'Pending'
) v
JOIN Clients c         ON c.client_id = v.client_id
JOIN ART_Enrollments a ON a.client_id = v.client_id AND a.current_status = 'Active'
JOIN Facilities f      ON f.facility_id = v.facility_id
WHERE v.rn = 1
  AND v.suppression_status = 'Unsuppressed'      -- i.e. viral_load_copies >= 1000
ORDER BY v.viral_load_copies DESC
LIMIT 50;

-- -------------------------------------------------------------------------
-- Query 4: Single-client longitudinal history  (point lookup, case manager view)
-- The most common OLTP read: open one client's chart.
-- -------------------------------------------------------------------------
SELECT c.pepfar_uid, p.pickup_date, p.months_dispensed, p.next_appointment_date, f.facility_name
FROM Clients c
JOIN ART_Enrollments a ON a.client_id = c.client_id
JOIN ART_Pickups p     ON p.art_id = a.art_id
JOIN Facilities f      ON f.facility_id = p.facility_id
WHERE c.pepfar_uid = 'OS-012345'
ORDER BY p.pickup_date DESC;

SELECT sample_collected_date, result_date, viral_load_copies, suppression_status
FROM Lab_Viral_Load
WHERE client_id = (SELECT client_id FROM Clients WHERE pepfar_uid = 'OS-012345')
ORDER BY sample_collected_date DESC;
