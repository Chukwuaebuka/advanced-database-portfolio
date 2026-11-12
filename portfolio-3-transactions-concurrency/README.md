# Portfolio 3: Transactions and Concurrency

| File                                                                                                             | Purpose                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| [transactions.sql](transactions.sql)                                                                             | Single-session scenarios: COMMIT, automatic rollback on error, explicit ROLLBACK, SAVEPOINT, UNIQUE duplicate block   |
| [run_concurrency_demo.sh](run_concurrency_demo.sh)                                                               | Runs two psql sessions concurrently: lost update, `SELECT … FOR UPDATE`, `REPEATABLE READ` conflict, duplicate pickup |
| [clerk_extend_appointment.sql](clerk_extend_appointment.sql), [clerk_record_pickup.sql](clerk_record_pickup.sql) | The per-clerk session scripts used by the demo                                                                        |
| [concurrency-report.md](concurrency-report.md)                                                                   | Results and analysis                                                                                                  |
| [evidence/](evidence/)                                                                                           | Captured output of both scripts                                                                                       |

## How to run

Run after Portfolio 1 has been loaded:

```bash
psql -d speed_osun -f transactions.sql > evidence/transactions_output.txt 2>&1
PSQL="psql -d speed_osun" ./run_concurrency_demo.sh > evidence/concurrency_output.txt 2>&1
```

Errors in the output are intentional; each one demonstrates a rollback or a conflict being detected.
