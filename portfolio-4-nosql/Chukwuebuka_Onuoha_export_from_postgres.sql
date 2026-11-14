-- =========================================================================
-- Relational -> document migration.
-- Builds one MongoDB document per ART client from the Portfolio 1 tables
-- and writes newline-delimited Extended JSON for mongoimport.
--   psql -d speed_osun -At -f export_from_postgres.sql > data/client_records.ndjson
-- Names are deliberately NOT exported (pseudonymisation; see nosql-report.md).
-- =========================================================================
\set QUIET on

-- Dates as Extended JSON {"$date": ...} so MongoDB stores real Date values.
CREATE FUNCTION pg_temp.mdate(d date) RETURNS json LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN d IS NULL THEN 'null'::json
                ELSE json_build_object('$date', to_char(d, 'YYYY-MM-DD') || 'T00:00:00Z') END
$$;

COPY (
SELECT json_build_object(
    '_id', c.pepfar_uid,
    'demographics', json_build_object(
        'gender', c.gender,
        'birth_year', EXTRACT(YEAR FROM c.dob)::int,
        'lga', l.lga_name,
        'senatorial_district', l.senatorial_district),
    'art', json_build_object(
        'enrollment_date', pg_temp.mdate(a.enrollment_date),
        'facility', f.facility_name,
        'clinical_stage', a.clinical_stage,
        'regimen_line', a.regimen_line,
        'regimen', a.regimen,
        'current_status', a.current_status,
        'last_pickup_date', pg_temp.mdate(a.last_pickup_date),
        'next_appointment_date', pg_temp.mdate(a.next_appointment_date)),
    'pickups', (
        SELECT COALESCE(json_agg(json_build_object(
                   'date', pg_temp.mdate(p.pickup_date),
                   'facility', pf.facility_name,
                   'months_dispensed', p.months_dispensed,
                   'next_appointment', pg_temp.mdate(p.next_appointment_date)) ORDER BY p.pickup_date), '[]'::json)
        FROM ART_Pickups p JOIN Facilities pf ON pf.facility_id = p.facility_id
        WHERE p.art_id = a.art_id),
    'tb_screenings', (
        SELECT COALESCE(json_agg(json_build_object(
                   'date', pg_temp.mdate(t.screening_date),
                   'cough', t.cough_status,
                   'fever', t.fever_status,
                   'status', t.tb_status,
                   'treatment_started', t.tb_treatment_started,
                   'outcome', t.treatment_outcome) ORDER BY t.screening_date), '[]'::json)
        FROM TB_Screening_Outcomes t WHERE t.client_id = c.client_id),
    'viral_loads', (
        SELECT COALESCE(json_agg(json_build_object(
                   'sample_date', pg_temp.mdate(v.sample_collected_date),
                   'result_date', pg_temp.mdate(v.result_date),
                   'copies_per_ml', v.viral_load_copies,
                   'status', v.suppression_status) ORDER BY v.sample_collected_date), '[]'::json)
        FROM Lab_Viral_Load v WHERE v.client_id = c.client_id)
)
FROM Clients c
JOIN ART_Enrollments a ON a.client_id = c.client_id
JOIN LGAs l            ON l.lga_id = c.lga_id
JOIN Facilities f      ON f.facility_id = a.facility_id
ORDER BY c.client_id
) TO STDOUT;
