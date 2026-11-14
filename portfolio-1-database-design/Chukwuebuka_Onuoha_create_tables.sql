-- =========================================================================
-- ECEWS SPEED Osun State Integrated HIV/TB Data Hub - DDL Script
-- Target: PostgreSQL 14+
-- Re-runnable: drops and recreates all objects.
-- =========================================================================

DROP VIEW  IF EXISTS v_outreach_yield;
DROP TABLE IF EXISTS Lab_Viral_Load, TB_Screening_Outcomes, ART_Pickups,
                     ART_Enrollments, HTS_Encounters, Community_Outreaches,
                     Clients, Facilities, LGAs CASCADE;

-- -------------------------------------------------------------------------
-- Reference data
-- -------------------------------------------------------------------------
CREATE TABLE LGAs (
    lga_id              SERIAL PRIMARY KEY,
    lga_name            VARCHAR(100) NOT NULL UNIQUE,
    senatorial_district VARCHAR(20)  NOT NULL
        CHECK (senatorial_district IN ('Osun Central', 'Osun East', 'Osun West')),
    state               VARCHAR(50)  NOT NULL DEFAULT 'Osun'
);

CREATE TABLE Facilities (
    facility_id   SERIAL PRIMARY KEY,
    facility_name VARCHAR(150) NOT NULL,
    lga_id        INT NOT NULL,
    facility_type VARCHAR(50) NOT NULL
        CHECK (facility_type IN ('Primary Health Centre', 'General Hospital', 'Comprehensive Health Centre')),
    CONSTRAINT uq_facility_name_lga UNIQUE (facility_name, lga_id),
    CONSTRAINT fk_facility_lga FOREIGN KEY (lga_id) REFERENCES LGAs(lga_id) ON DELETE RESTRICT
);

-- -------------------------------------------------------------------------
-- Clients and HIV testing
-- -------------------------------------------------------------------------
CREATE TABLE Clients (
    client_id       SERIAL PRIMARY KEY,
    pepfar_uid      VARCHAR(50) NOT NULL UNIQUE,
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    dob             DATE NOT NULL,
    gender          VARCHAR(10) NOT NULL CHECK (gender IN ('Male', 'Female')),
    lga_id          INT NOT NULL,
    date_registered TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_client_dob CHECK (dob <= date_registered::date),
    CONSTRAINT fk_client_lga FOREIGN KEY (lga_id) REFERENCES LGAs(lga_id) ON DELETE RESTRICT
);

-- Outreach event header only. Tested/positive totals are NOT stored here;
-- they are derived from HTS_Encounters (see v_outreach_yield) to avoid
-- update anomalies (3NF: no attribute derivable from other rows).
CREATE TABLE Community_Outreaches (
    outreach_id   SERIAL PRIMARY KEY,
    lga_id        INT NOT NULL,
    outreach_date DATE NOT NULL,
    location_name VARCHAR(150) NOT NULL,
    CONSTRAINT fk_outreach_lga FOREIGN KEY (lga_id) REFERENCES LGAs(lga_id) ON DELETE RESTRICT
);

-- One HIV test event. Exactly one of facility_id / outreach_id is set,
-- depending on whether the test happened in a facility or in the community.
CREATE TABLE HTS_Encounters (
    hts_id         SERIAL PRIMARY KEY,
    client_id      INT NOT NULL,
    facility_id    INT,
    outreach_id    INT,
    testing_point  VARCHAR(30) NOT NULL
        CHECK (testing_point IN ('Facility-OPD', 'Facility-ANC', 'Facility-TB', 'Index-Testing', 'Community-Outreach')),
    hiv_status     VARCHAR(10) NOT NULL CHECK (hiv_status IN ('Positive', 'Negative')),
    encounter_date DATE NOT NULL,
    CONSTRAINT chk_hts_one_location CHECK ((facility_id IS NULL) <> (outreach_id IS NULL)),
    CONSTRAINT fk_hts_client   FOREIGN KEY (client_id)   REFERENCES Clients(client_id) ON DELETE CASCADE,
    CONSTRAINT fk_hts_facility FOREIGN KEY (facility_id) REFERENCES Facilities(facility_id) ON DELETE RESTRICT,
    CONSTRAINT fk_hts_outreach FOREIGN KEY (outreach_id) REFERENCES Community_Outreaches(outreach_id) ON DELETE RESTRICT
);

-- -------------------------------------------------------------------------
-- ART treatment
-- -------------------------------------------------------------------------
-- One enrolment per client (client_id UNIQUE). last_pickup_date and
-- next_appointment_date are a deliberate, controlled denormalisation of the
-- latest ART_Pickups row so that retention dashboards do not need to scan
-- pickup history. They are only ever changed in the same transaction as the
-- ART_Pickups insert (see portfolio-3).
CREATE TABLE ART_Enrollments (
    art_id                SERIAL PRIMARY KEY,
    client_id             INT NOT NULL UNIQUE,
    facility_id           INT NOT NULL,
    enrollment_date       DATE NOT NULL,
    clinical_stage        SMALLINT NOT NULL CHECK (clinical_stage BETWEEN 1 AND 4),
    regimen_line          VARCHAR(20) NOT NULL CHECK (regimen_line IN ('First-Line', 'Second-Line', 'Third-Line')),
    regimen               VARCHAR(50) NOT NULL,
    current_status        VARCHAR(30) NOT NULL DEFAULT 'Active'
        CHECK (current_status IN ('Active', 'Transferred-Out', 'Lost-To-Follow-Up', 'Deceased')),
    last_pickup_date      DATE NOT NULL,
    next_appointment_date DATE NOT NULL,
    CONSTRAINT chk_art_pickup_after_enrol CHECK (last_pickup_date >= enrollment_date),
    CONSTRAINT chk_art_appt_after_pickup  CHECK (next_appointment_date > last_pickup_date),
    CONSTRAINT fk_art_client   FOREIGN KEY (client_id)   REFERENCES Clients(client_id) ON DELETE CASCADE,
    CONSTRAINT fk_art_facility FOREIGN KEY (facility_id) REFERENCES Facilities(facility_id) ON DELETE RESTRICT
);

-- Full drug pickup / multi-month dispensing (MMD) history.
CREATE TABLE ART_Pickups (
    pickup_id             SERIAL PRIMARY KEY,
    art_id                INT NOT NULL,
    facility_id           INT NOT NULL,
    pickup_date           DATE NOT NULL,
    months_dispensed      SMALLINT NOT NULL CHECK (months_dispensed IN (1, 2, 3, 6)),
    next_appointment_date DATE NOT NULL,
    CONSTRAINT uq_pickup_per_day UNIQUE (art_id, pickup_date),   -- blocks duplicate entry of the same visit
    CONSTRAINT chk_pickup_appt CHECK (next_appointment_date > pickup_date),
    CONSTRAINT fk_pickup_art      FOREIGN KEY (art_id)      REFERENCES ART_Enrollments(art_id) ON DELETE CASCADE,
    CONSTRAINT fk_pickup_facility FOREIGN KEY (facility_id) REFERENCES Facilities(facility_id) ON DELETE RESTRICT
);

-- -------------------------------------------------------------------------
-- TB screening and laboratory
-- -------------------------------------------------------------------------
CREATE TABLE TB_Screening_Outcomes (
    tb_screen_id         SERIAL PRIMARY KEY,
    client_id            INT NOT NULL,
    facility_id          INT NOT NULL,
    screening_date       DATE NOT NULL,
    cough_status         BOOLEAN NOT NULL DEFAULT FALSE,
    fever_status         BOOLEAN NOT NULL DEFAULT FALSE,
    tb_status            VARCHAR(30) NOT NULL CHECK (tb_status IN ('Presumptive', 'Confirmed-TB', 'No-Signs')),
    tb_treatment_started BOOLEAN NOT NULL DEFAULT FALSE,
    treatment_outcome    VARCHAR(30) NOT NULL DEFAULT 'Not-Applicable'
        CHECK (treatment_outcome IN ('Not-Applicable', 'Ongoing', 'Cured', 'Treatment-Completed', 'Failed', 'Died', 'Lost-To-Follow-Up')),
    -- Business rules: only confirmed TB is treated; only treated cases have an outcome.
    CONSTRAINT chk_tb_treat_confirmed CHECK (NOT tb_treatment_started OR tb_status = 'Confirmed-TB'),
    CONSTRAINT chk_tb_outcome CHECK (tb_treatment_started OR treatment_outcome = 'Not-Applicable'),
    CONSTRAINT fk_tb_client   FOREIGN KEY (client_id)   REFERENCES Clients(client_id) ON DELETE CASCADE,
    CONSTRAINT fk_tb_facility FOREIGN KEY (facility_id) REFERENCES Facilities(facility_id) ON DELETE RESTRICT
);

CREATE TABLE Lab_Viral_Load (
    vload_id              SERIAL PRIMARY KEY,
    client_id             INT NOT NULL,
    facility_id           INT NOT NULL,
    sample_collected_date DATE NOT NULL,
    result_date           DATE,
    viral_load_copies     INT CHECK (viral_load_copies >= 0),
    suppression_status    VARCHAR(20) NOT NULL DEFAULT 'Pending'
        CHECK (suppression_status IN ('Suppressed', 'Unsuppressed', 'Pending')),
    CONSTRAINT chk_vl_result_date CHECK (result_date IS NULL OR result_date >= sample_collected_date),
    -- suppression_status is functionally dependent on viral_load_copies.
    -- It is kept for readability/indexing, and this CHECK makes an
    -- inconsistent combination impossible (threshold: 1000 copies/mL).
    CONSTRAINT chk_vl_status_consistent CHECK (
           (suppression_status = 'Pending'      AND viral_load_copies IS NULL AND result_date IS NULL)
        OR (suppression_status = 'Suppressed'   AND viral_load_copies <  1000 AND result_date IS NOT NULL)
        OR (suppression_status = 'Unsuppressed' AND viral_load_copies >= 1000 AND result_date IS NOT NULL)
    ),
    CONSTRAINT fk_vl_client   FOREIGN KEY (client_id)   REFERENCES Clients(client_id) ON DELETE CASCADE,
    CONSTRAINT fk_vl_facility FOREIGN KEY (facility_id) REFERENCES Facilities(facility_id) ON DELETE RESTRICT
);

-- -------------------------------------------------------------------------
-- Derived data exposed as a view instead of stored columns
-- -------------------------------------------------------------------------
CREATE VIEW v_outreach_yield AS
SELECT o.outreach_id,
       o.outreach_date,
       o.location_name,
       l.lga_name,
       COUNT(h.hts_id)                                    AS total_tested,
       COUNT(h.hts_id) FILTER (WHERE h.hiv_status = 'Positive') AS total_positive
FROM Community_Outreaches o
JOIN LGAs l ON l.lga_id = o.lga_id
LEFT JOIN HTS_Encounters h ON h.outreach_id = o.outreach_id
GROUP BY o.outreach_id, o.outreach_date, o.location_name, l.lga_name;
