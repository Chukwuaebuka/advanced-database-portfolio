-- =========================================================================
-- ECEWS SPEED Osun Hub - Indexes (apply AFTER capturing the "before" plans)
-- NOTE: PostgreSQL does NOT automatically index foreign-key columns, only
-- PRIMARY KEY and UNIQUE constraints. Most of the gains below come from that.
-- =========================================================================

-- Query 1: equality on status + range on date -> composite B-tree,
-- equality column first, range column second. Also returns rows already
-- ordered by next_appointment_date, so the planner can skip the sort.
CREATE INDEX IF NOT EXISTS idx_art_status_next_appt
    ON ART_Enrollments (current_status, next_appointment_date);

-- Query 4 (pickup history): NO new index needed. The UNIQUE constraint
-- uq_pickup_per_day (art_id, pickup_date) already creates a B-tree whose
-- leading column is art_id, and the planner uses it (see explain_before.txt).
-- An extra (art_id, pickup_date DESC) index was tested and removed: it gave
-- no speed-up and would only add write cost on every pickup insert.

-- Query 4 (VL history) and Query 3 latest-per-client.
CREATE INDEX IF NOT EXISTS idx_vl_client_date
    ON Lab_Viral_Load (client_id, sample_collected_date DESC);

-- FK lookups used when opening a client's TB history.
CREATE INDEX IF NOT EXISTS idx_tb_client_date
    ON TB_Screening_Outcomes (client_id, screening_date);

-- FK used by LGA-level reports (Query 2).
CREATE INDEX IF NOT EXISTS idx_clients_lga
    ON Clients (lga_id);

ANALYZE;
