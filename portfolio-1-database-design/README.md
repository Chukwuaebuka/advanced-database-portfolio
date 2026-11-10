# Portfolio 1: Database Design and Modelling

| File                                   | Purpose                                                                             |
| -------------------------------------- | ----------------------------------------------------------------------------------- |
| [case-study.md](case-study.md)         | Organisation, users, data and operations                                            |
| [er-diagram.md](er-diagram.md)         | Mermaid ER diagram + cardinality notes                                              |
| [schema-design.md](schema-design.md)   | Relational schema, keys, constraints, referential actions, changes from first draft |
| [normalisation.md](normalisation.md)   | UNF → 1NF → 2NF → 3NF with functional dependencies; justified denormalisations      |
| [create_tables.sql](create_tables.sql) | PostgreSQL DDL (re-runnable)                                                        |
| [seed_data.sql](seed_data.sql)         | Deterministic synthetic data: 50k clients, 30k ART enrolments, ~375k pickups        |

## How to run

```bash
psql -d speed_osun -f create_tables.sql
psql -d speed_osun -f seed_data.sql      # prints row counts at the end
```

## How it was tested

- The seed loads with zero constraint violations. Every CHECK, UNIQUE and FK constraint is satisfied by ~650k generated rows.
