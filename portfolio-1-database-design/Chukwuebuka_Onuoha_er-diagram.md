# ER Diagram: ECEWS SPEED Osun Hub

The diagram is written in Mermaid, which GitHub renders automatically. You can also open as preview inside of VS code to view the Rendered ER diagram.

```mermaid
erDiagram
    LGAS ||--o{ FACILITIES : "contains"
    LGAS ||--o{ CLIENTS : "resident in"
    LGAS ||--o{ COMMUNITY_OUTREACHES : "hosts"
    CLIENTS ||--o{ HTS_ENCOUNTERS : "is tested in"
    FACILITIES |o--o{ HTS_ENCOUNTERS : "facility test"
    COMMUNITY_OUTREACHES |o--o{ HTS_ENCOUNTERS : "community test"
    CLIENTS ||--o| ART_ENROLLMENTS : "enrols on ART"
    FACILITIES ||--o{ ART_ENROLLMENTS : "manages"
    ART_ENROLLMENTS ||--o{ ART_PICKUPS : "has pickups"
    FACILITIES ||--o{ ART_PICKUPS : "dispenses"
    CLIENTS ||--o{ TB_SCREENING_OUTCOMES : "is screened"
    FACILITIES ||--o{ TB_SCREENING_OUTCOMES : "screens"
    CLIENTS ||--o{ LAB_VIRAL_LOAD : "has samples"
    FACILITIES ||--o{ LAB_VIRAL_LOAD : "collects"

    LGAS {
        int lga_id PK
        varchar lga_name UK
        varchar senatorial_district
        varchar state
    }
    FACILITIES {
        int facility_id PK
        varchar facility_name
        int lga_id FK
        varchar facility_type
    }
    CLIENTS {
        int client_id PK
        varchar pepfar_uid UK
        varchar first_name
        varchar last_name
        date dob
        varchar gender
        int lga_id FK
        timestamp date_registered
    }
    COMMUNITY_OUTREACHES {
        int outreach_id PK
        int lga_id FK
        date outreach_date
        varchar location_name
    }
    HTS_ENCOUNTERS {
        int hts_id PK
        int client_id FK
        int facility_id FK "nullable"
        int outreach_id FK "nullable"
        varchar testing_point
        varchar hiv_status
        date encounter_date
    }
    ART_ENROLLMENTS {
        int art_id PK
        int client_id FK,UK
        int facility_id FK
        date enrollment_date
        smallint clinical_stage
        varchar regimen_line
        varchar regimen
        varchar current_status
        date last_pickup_date
        date next_appointment_date
    }
    ART_PICKUPS {
        int pickup_id PK
        int art_id FK
        int facility_id FK
        date pickup_date
        smallint months_dispensed
        date next_appointment_date
    }
    TB_SCREENING_OUTCOMES {
        int tb_screen_id PK
        int client_id FK
        int facility_id FK
        date screening_date
        boolean cough_status
        boolean fever_status
        varchar tb_status
        boolean tb_treatment_started
        varchar treatment_outcome
    }
    LAB_VIRAL_LOAD {
        int vload_id PK
        int client_id FK
        int facility_id FK
        date sample_collected_date
        date result_date
        int viral_load_copies
        varchar suppression_status
    }
```

## Cardinality notes

- **Client → ART enrolment is 1 : 0..1.** Not every tested client is HIV-positive. A client is enrolled at most once; a transfer updates `facility_id` and does not create a new enrolment.
- **HTS encounter → location is exactly one of facility or outreach.** This is enforced by `chk_hts_one_location`.
- **Enrolment → pickups is 1 : many.** This gives the full multi-month dispensing (MMD) history.
