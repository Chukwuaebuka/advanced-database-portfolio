# Normalisation: from a flat facility register to 3NF

## Starting point: the paper/Excel register (UNF)

Facilities in the programme traditionally keep a flat "ART register" with one row per client visit:

`pepfar_uid, client_name, dob, gender, lga_name, facility_name, facility_type, facility_lga, enrollment_date, regimen, pickup_date, months_dispensed, next_appt, tb_screen_result, vl_result, vl_status`

Problems with this register:

- **Update anomaly.** A regimen switch must be edited on every historical row.
- **Insertion anomaly.** A client who has tested but has not yet visited cannot be recorded.
- **Deletion anomaly.** Deleting a client's only visit also deletes the only record of their demographics.

## 1NF: atomic values, no repeating groups

- Split `client_name` into `first_name` and `last_name`.
- A visit could contain several TB symptoms and several lab results. Move those repeating groups into their own tables (`TB_Screening_Outcomes`, `Lab_Viral_Load`), keyed by client and date.
- Every table gets a primary key.

## 2NF: no partial dependency on a composite key

In the 1NF visit table the natural key is (`pepfar_uid`, `pickup_date`). Partial dependencies:

- `pepfar_uid → client_name, dob, gender, lga_name`
- `pepfar_uid → enrollment_date, regimen, regimen_line, clinical_stage`

Each of these moves to a table keyed by the determinant alone, giving **Clients** and **ART_Enrollments**. **ART_Pickups** then keeps only the attributes that depend on the whole key: (`art_id`, `pickup_date`) → `months_dispensed`, `next_appointment_date`.

## 3NF: no transitive dependency

| Transitive dependency found                                               | Resolution                                          |
| ------------------------------------------------------------------------- | --------------------------------------------------- |
| `client_id → lga_id → lga_name, senatorial_district`                      | Separate **LGAs** table                             |
| `pickup → facility_id → facility_name, facility_type, lga_id`             | Separate **Facilities** table                       |
| `outreach_id → total_tested, total_positive` (derived from HTS rows)      | Removed and replaced by the view `v_outreach_yield` |
| `hts_id → linked_to_art` (derivable from whether an ART enrolment exists) | Removed                                             |

All non-key attributes now depend on "the key, the whole key, and nothing but the key".

## Deliberate, controlled exceptions

1. **`ART_Enrollments.last_pickup_date` / `next_appointment_date`** duplicate the latest `ART_Pickups` row.
   - _Why:_ the retention dashboard (Portfolio 2, Query 1) is the most frequent query. Without this "current snapshot" it would need a `DISTINCT ON` or `MAX()` over ~400k pickup rows.
   - _Control:_ the two values are only changed in the same transaction as the pickup insert (Portfolio 3, Scenario 1). `CHECK (next_appointment_date > last_pickup_date)` protects basic validity.
2. **`Lab_Viral_Load.suppression_status`** is functionally dependent on `viral_load_copies`.
   - _Why:_ it holds the lab's reported classification and makes the filter readable and indexable.
   - _Control:_ `chk_vl_status_consistent` makes an inconsistent row impossible, so the redundancy cannot drift.

## Keys summary

- **Surrogate keys** (`SERIAL`) everywhere. They are stable, narrow, and cheap to join on.
- **Natural candidate keys** are kept as `UNIQUE`: `pepfar_uid`, `lga_name`, (`facility_name`, `lga_id`), (`art_id`, `pickup_date`).
