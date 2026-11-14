# Portfolio 5: Distributed and Cloud Database

| File                                                                       | Purpose                                                                                              |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [distributed-architecture.md](distributed-architecture.md)                 | Design: replication, sync vs async, CAP, failover, shard-key analysis, cloud deployment and security |
| [docker-compose.yml](docker-compose.yml)                                   | PostgreSQL primary + streaming hot-standby replica                                                   |
| [primary-init/01-replication-user.sh](primary-init/01-replication-user.sh) | Creates the replication role and `pg_hba` rule                                                       |
| [replication_demo.sh](replication_demo.sh)                                 | Shows replication status, replica lag, read-only standby, and failover by promotion                  |
| [partitioning.sql](partitioning.sql)                                       | List partitioning by senatorial district (sharding model) with partition-pruning plans               |
| [evidence/](evidence/)                                                     | Captured output                                                                                      |

## How to run

```bash
docker compose up -d
./replication_demo.sh > evidence/replication_output.txt 2>&1
docker compose down -v
psql -d speed_osun -f partitioning.sql > evidence/partitioning_output.txt
```
