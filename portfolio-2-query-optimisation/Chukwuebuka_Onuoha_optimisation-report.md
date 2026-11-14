# Query Optimisation & Execution Plan Report: ECEWS SPEED Osun

## 1. Test setup

| Item     | Value                                                                                                                                                                                                          |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DBMS     | PostgreSQL 16 (Docker `postgres:16`), default configuration                                                                                                                                                    |
| Data     | Synthetic seed ([../portfolio-1-database-design/seed_data.sql](../portfolio-1-database-design/seed_data.sql)): 50,000 clients, 30,000 ART enrolments, 374,581 pickups, 58,857 TB screenings, 77,609 VL results |
| Method   | `EXPLAIN (ANALYZE, BUFFERS)`, parallelism disabled for readable plans, warm cache (each run repeated, second run recorded)                                                                                     |
| Evidence | [evidence/explain_before.txt](evidence/explain_before.txt), [evidence/explain_after.txt](evidence/explain_after.txt), [evidence/query_results.txt](evidence/query_results.txt)                                 |

## 2. Queries

| #   | Purpose                                                                               | SQL features                                  |
| --- | ------------------------------------------------------------------------------------- | --------------------------------------------- |
| Q1  | Interruption-in-Treatment (IIT) risk list: active clients past their appointment date | 4-table join, CASE, ORDER BY + LIMIT          |
| Q2  | TB/HIV co-infection cascade per LGA                                                   | CTE, `bool_or`, `COUNT … FILTER`, GROUP BY    |
| Q3  | Clients whose _latest_ viral load is unsuppressed                                     | Derived-table subquery, `ROW_NUMBER()` window |
| Q4  | Open one client's chart (pickup + VL history)                                         | Point lookup by `pepfar_uid`, scalar subquery |

## 3. Indexes ([indexes.sql](indexes.sql))

PostgreSQL only auto-indexes PRIMARY KEY and UNIQUE columns. **Foreign keys are not indexed**, and that is where most of the gaps were.

| Index                                                              | Target query | Design reasoning                                                                                                                  |
| ------------------------------------------------------------------ | ------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `idx_art_status_next_appt (current_status, next_appointment_date)` | Q1           | Equality column first, range column second. The index also returns rows already sorted, so the planner can stop after 50 (LIMIT). |
| `idx_vl_client_date (client_id, sample_collected_date DESC)`       | Q4b, Q3      | Covers the FK lookup and the per-client "latest first" order.                                                                     |
| `idx_tb_client_date`, `idx_clients_lga`                            | FK lookups   | Cover the client TB history lookup and the LGA joins.                                                                             |
| _(rejected)_ `idx_pickups_art_date`                                | Q4a          | Tested and dropped: the existing `uq_pickup_per_day (art_id, pickup_date)` already serves this query.                             |

## 4. Results (measured)

| Query          | Plan before                                                       | Plan after                                                                        | Time before | Time after                | Buffers before → after      |
| -------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------- | ------------------------- | --------------------------- |
| Q1 IIT list    | Seq Scan on `art_enrollments` + `clients`, hash joins, top-N sort | **Index Scan** on `idx_art_status_next_appt`, nested-loop PK lookups, **no sort** | 18.9 ms     | **0.66 ms** (~29× faster) | 1,116 → 321                 |
| Q2 LGA cascade | Seq Scans + hash joins + HashAggregate                            | Unchanged                                                                         | 47.5 ms     | 46.9 ms                   | 1,661 → 1,661               |
| Q3 latest VL   | Seq Scan + **external merge sort, 2.7 MB spilled to disk**        | Index Scan + incremental sort (no disk)                                           | 46.4 ms     | 49.3 ms                   | 21,250 (+684 temp) → 91,834 |
| Q4a pickups    | Index Scan on `uq_pickup_per_day`                                 | Same                                                                              | 0.05 ms     | 0.07 ms                   | 44 → 44                     |
| Q4b VL history | **Seq Scan** on `lab_viral_load` (77k rows to return 4)           | **Bitmap Index Scan** on `idx_vl_client_date`                                     | 2.50 ms     | **0.04 ms** (~60× faster) | 646 → 9                     |

## 5. Analysis

- **Q1 and Q4b: selective queries benefit most.**
  - Q4b reads 4 rows out of 77k. Without an FK index PostgreSQL must read all 646 pages. With the index it reads 9.
  - Q4b is the case manager's most frequent operation, so this matters more than its absolute time suggests: under concurrent load a full scan per chart open becomes a bottleneck.
  - In Q1, the composite index also removes the sort. Because the index is already ordered by `next_appointment_date` within `current_status = 'Active'`, the `LIMIT 50` stops after reading 50 index entries.
- **Q2: an index cannot help a whole-table aggregate.**
  - It reads every active client and every TB screening. A sequential scan plus hash join is the cheapest plan, and the planner correctly ignored `idx_clients_lga`.
  - The right optimisation is a **materialised view** refreshed nightly. The programme coordinators' dashboard does not need second-by-second freshness.
- **Q3: an index is not automatically a win.**
  - Before, the planner sorted 74,767 rows and spilled 2.7 MB to disk, because the default `work_mem` is 4 MB.
  - After, it read the rows in index order. That removed the sort, but it turned sequential page reads into ~92k random heap page visits. The net time was unchanged.
  - Better options:
    - (a) Raise `work_mem` for this reporting session so the sort stays in memory.
    - (b) Make the index _covering_, i.e. `INCLUDE (suppression_status, viral_load_copies, facility_id)` plus a vacuumed table, so an Index-Only Scan avoids the heap.
    - (c) Maintain a "latest VL" pointer per client.
- **Q4a: the existing index was enough.**
  - A UNIQUE constraint creates a B-tree that can be reused for lookups on its leading column(s).
  - Adding a duplicate index would only slow every pickup INSERT, because each index must be maintained on write.

## 6. Trade-offs considered

- Every index speeds reads but costs writes and storage. `ART_Pickups` and `Lab_Viral_Load` are the highest-insert tables, so their indexes were limited to what the measured queries needed.
- With 30 LGAs × 3 facility types and only 3 status values, low-cardinality columns are poor index leaders on their own. In `idx_art_status_next_appt`, `current_status` works only because a range column follows it.

## How to reproduce

```bash
psql -d speed_osun -f ../portfolio-1-database-design/create_tables.sql -f ../portfolio-1-database-design/seed_data.sql
psql -d speed_osun -f queries.sql             > evidence/query_results.txt
psql -d speed_osun -f explain_queries.sql     > evidence/explain_before.txt
psql -d speed_osun -f indexes.sql
psql -d speed_osun -f explain_queries.sql     > evidence/explain_after.txt
```

Timings vary by machine. The plan _shapes_ (scan types, sort method, buffer counts) are what to compare.
