# Portfolio 2: Query Processing and Optimisation

| File                                             | Purpose                                                                             |
| ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| [queries.sql](queries.sql)                       | Q1 IIT risk list, Q2 LGA TB/HIV cascade, Q3 latest unsuppressed VL, Q4 client chart |
| [indexes.sql](indexes.sql)                       | Index definitions with reasoning (including one index that was tested and rejected) |
| [explain_queries.sql](explain_queries.sql)       | `EXPLAIN (ANALYZE, BUFFERS)` for every query                                        |
| [optimisation-report.md](optimisation-report.md) | Before/after plans, timings and analysis                                            |
| [evidence/](evidence/)                           | Query results, before/after plans, index list                                       |

## How to run

Run after Portfolio 1 has been loaded:

```bash
psql -d speed_osun -f queries.sql         > evidence/query_results.txt
psql -d speed_osun -f explain_queries.sql > evidence/explain_before.txt
psql -d speed_osun -f indexes.sql
psql -d speed_osun -f explain_queries.sql > evidence/explain_after.txt
```

## Headline result

- **Q1 (IIT list):** 18.9 ms → 0.66 ms.
- **Q4b (client VL history):** 2.5 ms → 0.04 ms. A sequential scan became an index scan.
- **Q2 and Q3 did not improve, and the report explains why.**
