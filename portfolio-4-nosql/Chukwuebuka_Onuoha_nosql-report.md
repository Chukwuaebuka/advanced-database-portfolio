# NoSQL Document Model Report: ECEWS SPEED Osun

**Engine:** MongoDB 7 (document store). Same case study and the _same data_ as Portfolios 1–3: the 30,001 documents were migrated from PostgreSQL by [export_from_postgres.sql](export_from_postgres.sql).

**Evidence:**

- [evidence/mongo_setup_output.txt](evidence/mongo_setup_output.txt)
- [evidence/mongo_output.txt](evidence/mongo_output.txt)

## 1. Model

One document per ART client (`client_records`), keyed by the PEPFAR UID. See the real sample in [nosql-model.json](nosql-model.json).

```text
{ _id: "OS-012345",
  demographics: { gender, birth_year, lga, senatorial_district },     <- copied from Clients + LGAs
  art:          { enrollment_date, facility, regimen, current_status,
                  last_pickup_date, next_appointment_date },          <- ART_Enrollments + Facilities
  pickups:       [ { date, facility, months_dispensed, next_appointment } ],   <- ART_Pickups (embedded)
  tb_screenings: [ { date, cough, fever, status, treatment_started, outcome } ],
  viral_loads:   [ { sample_date, result_date, copies_per_ml, status } ] }
```

### Embedding vs referencing decisions

| Data                               | Decision                          | Reason                                                                                                                                                                |
| ---------------------------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pickups, TB screenings, VL results | **Embed**                         | Always read together with the client (the case-manager chart). Owned by one client only. Bounded size (see §4).                                                       |
| LGA, facility names                | **Copy (denormalise) as strings** | Read-mostly reference data. Avoids `$lookup` on every read. The cost is that a renamed facility must be updated in many documents, which is rare and done in a batch. |
| Client names                       | **Not stored**                    | Pseudonymisation: analytics and case-review documents do not need direct identifiers. Names stay in the access-controlled relational system.                          |

## 2. Implementation (what was run)

1. [mongo_setup.js](mongo_setup.js) creates the collection with a **`$jsonSchema` validator**. It requires the core sections and enforces enums (gender, ART status, VL status, `months_dispensed ∈ {1,2,3,6}`) and BSON types (real `date` values, `int` copies).
2. `mongoimport` loaded **30,001 documents, 0 failed validation**.
3. [mongo_queries.js](mongo_queries.js) ran the operations below.

## 3. Results

| #   | Operation                                                                                                             | Result                                                                                                                                                                       |
| --- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Open one client's chart: `findOne({_id})`                                                                             | **One document read** (`IDHACK` plan, 1 key / 1 doc examined). PostgreSQL needed a 4-table join plus a separate VL query (Portfolio 2 Q4).                                   |
| 2   | IIT risk list **before** index                                                                                        | `COLLSCAN`: all 30,001 documents examined, then an in-memory SORT, 15 ms                                                                                                     |
| 2b  | Same query **after** compound index `{art.current_status: 1, art.next_appointment_date: 1}`                           | `IXSCAN`: **5 keys / 5 docs examined**, no SORT stage, 0 ms. This uses the same equality-then-range index design as PostgreSQL in Portfolio 2.                               |
| 3   | Aggregation: viral suppression rate per LGA using each client's _latest resulted_ VL (`$filter` + `$last` + `$group`) | Lowest five LGAs reported, e.g. Ilesa West 85.45% (599/701)                                                                                                                  |
| 4   | **Multikey** index on `{demographics.lga, tb_screenings.status}`: Osogbo clients ever TB-confirmed                    | 395 clients. `IXSCAN`; keys examined = docs returned = 395.                                                                                                                  |
| 5   | Record a 3-month pickup                                                                                               | **One `updateOne`** with `$push` (history) + `$set` (snapshot): `matchedCount 1, modifiedCount 1`, pickups 17 → 18. The `pickups.date: {$ne: …}` filter makes it idempotent. |
| 6   | Insert a malformed record (`gender: "Unknown"`)                                                                       | `Document failed validation`                                                                                                                                                 |

## 4. Suitability: when this model is better, and when it is not

**Advantages for this case study:**

- **Chart reads are one fetch.** Viewing a client's chart is the most frequent clinical read, and it now needs no joins.
- **Atomicity without multi-statement transactions.** MongoDB guarantees atomic writes _per document_. Because the pickup history and the "current appointment" snapshot live in the same document, Result 5 needs no transaction. In PostgreSQL, the same consistency needed an explicit two-table transaction (Portfolio 3, Scenario 1).
- **Flexible schema for evolving programme data.** New PEPFAR indicators (e.g. a new TB test type or an extra screening question) can be added to new sub-documents without an `ALTER TABLE` across 375k rows. The validator still guards the core fields.
- **Natural shard key.** `_id` = client means all of a client's data lives on one shard (see Portfolio 5).

**Limitations, observed and designed for:**

- **Unbounded arrays.**
  - Documents average **2.3 KB** with a maximum of **8.4 KB** (59 pickups), far below MongoDB's **16 MB document limit**.
  - Monthly pickups add ~70 bytes per month, so even decades of history are safe.
  - If high-frequency data were added (e.g. daily adherence SMS logs), it should use the **bucket pattern**: a separate `client_events` collection bucketed per client per year, not the main document.
- **Cross-client analytics are weaker.** The LGA dashboards (Portfolio 2 Q2) must unwind arrays or scan every document. SQL with GROUP BY over normalised tables, or a column store, suits state-wide reporting better.
- **Integrity is weaker than relational.**
  - The validator enforces types and enums, but there are no foreign keys: nothing stops `art.facility` naming a facility that does not exist.
  - It also cannot enforce cross-field rules as cleanly as `chk_vl_status_consistent` (`$expr` validators can, but they are harder to maintain).
- **Copied data can drift.** Facility and LGA names are duplicated in every document.

**Conclusion.** This is **polyglot persistence**:

- PostgreSQL remains the system of record for transactional capture and integrity.
- The MongoDB document view serves case-manager charts and flexible longitudinal records. It is refreshed from PostgreSQL, as done here with the export script, or kept current through change-data-capture in production.

## How to run

```bash
psql -d speed_osun -At -f export_from_postgres.sql > data/client_records.ndjson   # ~98 MB, git-ignored
mongosh --quiet mongo_setup.js
mongoimport --db speed_osun --collection client_records --file data/client_records.ndjson
mongosh --quiet mongo_queries.js > evidence/mongo_output.txt
```
