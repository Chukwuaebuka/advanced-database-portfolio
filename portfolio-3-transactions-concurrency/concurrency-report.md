# Transactions & Concurrency Control Report: ECEWS SPEED Osun

**Environment:** PostgreSQL 16, default isolation `READ COMMITTED`, synthetic seed data from Portfolio 1.

**Evidence:**

- [evidence/transactions_output.txt](evidence/transactions_output.txt): single-session scenarios
- [evidence/concurrency_output.txt](evidence/concurrency_output.txt): two concurrent sessions

## Why transactions matter in this system

Many facility workstations write to the same client records. Two operations are critical:

- **Recording a pickup** writes to two tables: `ART_Pickups` (history) and `ART_Enrollments` (the current snapshot used by the IIT dashboard).
  - If only one of them is saved, a client can appear "missed" when they actually collected drugs.
  - Or a client can appear "on schedule" with no dispensing record behind it.
- **Several clerks may edit the same client at once.** A pharmacist and a data clerk, for example, may both update the next appointment. If one edit silently overwrites the other, the client gets a wrong appointment date and may be wrongly tracked as interrupted.

## Part A: ACID scenarios ([transactions.sql](transactions.sql))

| #   | Scenario                                                                                                                           | What the output shows                                                                                                                                                                    | ACID property              |
| --- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| 1   | **COMMIT**: record a 3-month MMD pickup (INSERT pickup + UPDATE enrolment)                                                         | Both changes visible together after COMMIT                                                                                                                                               | Atomicity, Durability      |
| 2   | **Automatic rollback**: UPDATE succeeds, then INSERT with `months_dispensed = 4` violates a CHECK                                  | PostgreSQL aborts the transaction. The next statement is refused (`current transaction is aborted`). After ROLLBACK the dates are `unchanged = t`: the successful UPDATE was undone too. | Atomicity, Consistency     |
| 3   | **Explicit ROLLBACK**: clerk marks the wrong client "Deceased"                                                                     | Inside the transaction the status reads `Deceased`; after ROLLBACK it reads `Active`                                                                                                     | Atomicity                  |
| 4   | **SAVEPOINT**: register client + HTS + ART; VL entry rejected (`Suppressed` with 5,000 copies violates `chk_vl_status_consistent`) | `ROLLBACK TO SAVEPOINT` discards only the bad VL row. The registration commits with the VL stored as `Pending`.                                                                          | Partial rollback           |
| 5   | **Duplicate visit**: same client, same pickup date                                                                                 | `duplicate key … uq_pickup_per_day`                                                                                                                                                      | Consistency via constraint |

## Part B: concurrency anomalies and controls ([run_concurrency_demo.sh](run_concurrency_demo.sh))

Two `psql` sessions run at the same time against the same client.

- **Clerk A** reads the appointment date, "thinks" for 2 seconds, then adds **90 days** (3-month MMD).
- **Clerk B** starts 0.5 seconds later, reads the same date, "thinks" for 3 seconds, then adds **30 days** (top-up).
- Starting from 2027-01-04, the correct serial result is **2027-05-04** (+120 days).

| Demo | Control                                 | Result (from evidence log)                                                                                                                                                                                                           | Correct?         |
| ---- | --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------- |
| 1    | None: `READ COMMITTED` + plain `SELECT` | Both clerks read 2027-01-04. A writes 2027-04-04, then B overwrites it with **2027-02-03**. **Lost update:** A's 90-day dispensing silently disappeared.                                                                             | ❌               |
| 2    | **Pessimistic:** `SELECT … FOR UPDATE`  | B's read **blocks for ~1.5 s** until A commits. It then reads 2027-04-04 and writes **2027-05-04**.                                                                                                                                  | ✅               |
| 3    | **Optimistic:** `REPEATABLE READ`       | B's snapshot still shows 2027-01-04. On UPDATE, PostgreSQL detects that A changed the row and raises `could not serialize access due to concurrent update`. B is rolled back and must retry. Final value 2027-04-04: no silent loss. | ✅ (needs retry) |
| 4    | **UNIQUE constraint**                   | A inserts the pickup and holds the transaction open. B's identical insert **waits on A's uncommitted index entry**, then fails with `duplicate key` once A commits. Exactly 1 row is stored.                                         | ✅               |

### Why Demo 1 fails under PostgreSQL's default

- `READ COMMITTED` prevents dirty reads, but not the **read-then-write** pattern used by application forms.
- Each clerk computes the new value from a stale read, and the later write wins.
- An atomic `UPDATE … SET next_appointment_date = next_appointment_date + 30` would _not_ lose the update. PostgreSQL re-reads the latest committed row for UPDATE. But real data-entry screens show the value first and save it later, so the anomaly is realistic.

### Choosing a control for this system

| Approach                                        | Pros                                                       | Cons                                                                                                                       | Use in SPEED hub                                                                                          |
| ----------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `FOR UPDATE` (pessimistic)                      | Simple; no retries                                         | Blocks other users; a lock held while a clerk is idle stalls the row; deadlock risk if rows are locked in different orders | **Pickup and appointment edits.** Short transactions, high conflict on the same client during clinic days |
| `REPEATABLE READ` / `SERIALIZABLE` (optimistic) | No blocking; conflicts are detected                        | Application must catch SQLSTATE `40001` and retry                                                                          | Monthly batch jobs, e.g. recomputing retention status                                                     |
| Constraints (`UNIQUE`, `CHECK`)                 | Enforced regardless of application code or isolation level | Only covers rules that can be expressed declaratively                                                                      | Always on, as the last line of defence                                                                    |

## How to reproduce

```bash
psql -d speed_osun -f transactions.sql > evidence/transactions_output.txt 2>&1
PSQL="psql -d speed_osun" ./run_concurrency_demo.sh > evidence/concurrency_output.txt 2>&1
```

The demo restores the client's original appointment date and removes its test pickup when it finishes. For screenshots, open two terminals and run the statements from [clerk_extend_appointment.sql](clerk_extend_appointment.sql) by hand, one step at a time.
