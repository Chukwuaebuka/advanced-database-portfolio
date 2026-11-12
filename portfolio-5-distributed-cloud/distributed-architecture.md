# Distributed & Cloud Architecture: ECEWS SPEED Osun

This portfolio combines a **working replication + failover setup** ([docker-compose.yml](docker-compose.yml)), a **partitioning model of sharding** ([partitioning.sql](partitioning.sql)), and the design discussion for a production deployment.

**Evidence:**

- [evidence/replication_output.txt](evidence/replication_output.txt)
- [evidence/partitioning_output.txt](evidence/partitioning_output.txt)

Timestamps from inside containers are UTC. The host's `date` line in the failover step is local time (WAT, UTC+1).

## 1. Requirements that drive the design

| Workload                                               | Pattern                                           | Requirement                                                                    |
| ------------------------------------------------------ | ------------------------------------------------- | ------------------------------------------------------------------------------ |
| Clinic data entry (pickups, HTS, enrolment)            | Many small writes, business hours, ~90 facilities | Must never lose an acknowledged pickup; must keep working during short outages |
| Case manager chart lookup                              | Point reads                                       | Low latency                                                                    |
| Programme dashboards (IIT, TB cascade, VL suppression) | Large scans/aggregates                            | Can be minutes stale; must not slow down data entry                            |
| Monthly PEPFAR reporting                               | State-wide aggregation                            | Correct, consistent snapshot                                                   |

## 2. Replication and high availability (implemented)

**Setup.** PostgreSQL 16 primary plus one hot-standby replica using **physical streaming replication**:

- The replica is cloned with `pg_basebackup -R -C -S replica_slot`.
- A dedicated `replicator` role has only the `REPLICATION` privilege.
- A **replication slot** makes the primary retain WAL until the replica has received it, so a temporarily disconnected replica can catch up instead of needing a full re-clone.

**What the evidence shows:**
| Step | Result |
|---|---|
| `pg_stat_replication` | `state = streaming`, `sync_state = async`, replay lag ≈ 0.07 ms on an idle local network |
| Clone check | 50,000 clients on both nodes |
| Write on primary, read on replica | Row committed at 20:56:34.706 UTC and visible on replica at 20:56:34.843 UTC |
| Write on replica | `ERROR: cannot execute INSERT in a read-only transaction` |
| Failover | Primary stopped, `pg_promote()` on the replica. `pg_is_in_recovery` = false, and new writes are accepted. |

**How this serves the workloads.** Dashboards and reports are routed to the replica, so heavy aggregates (Portfolio 2 Q2/Q3) do not compete with clinic writes on the primary.

### Synchronous vs asynchronous replication: the consistency trade-off

- **Async (the demo default).**
  - The primary acknowledges COMMIT before the replica has the WAL.
  - Writes are fast, and a replica outage does not block clinics.
  - If the primary dies, the last few hundred milliseconds of commits can be lost (**RPO > 0**).
  - A dashboard on the replica may briefly show stale data (eventual consistency for reads).
- **Sync** (`synchronous_standby_names = 'walreceiver'`, `synchronous_commit = on`).
  - COMMIT waits for the replica, so a failover loses no acknowledged pickup (**RPO = 0**).
  - Every write pays a network round-trip.
  - With only one standby, _a replica outage blocks all writes_.
- **Decision.** Use **synchronous replication with 2 standbys and `ANY 1`** quorum (`synchronous_standby_names = 'ANY 1 (replica_a, replica_b)'`).
  - Pickup records are clinical, so losing one is not acceptable.
  - The quorum means one replica failing does not stop the clinics.
  - Dashboards read from either replica and accept a small staleness window.

### CAP view

During a network partition between primary and standbys, a sync-replicated PostgreSQL cluster chooses **consistency over availability**: writes wait rather than diverge. That is correct for clinical records.

Facilities with poor connectivity need a different approach. The right fix is not to weaken the central database. Instead, each facility uses **offline-first capture**: a local EMR or mobile app queues records and syncs them when connected. The UNIQUE constraints from Portfolios 1 and 3 make re-sent records idempotent.

### Failover in production

The demo promotes the replica by hand. In production:

- A failover manager handles promotion: **Patroni** with etcd, or the managed equivalent (RDS Multi-AZ).
- Fencing prevents the old primary from coming back as a second writer (split brain).
- Applications connect through a virtual IP or DNS endpoint that moves on failover.

**Targets:** RTO < 2 minutes, RPO = 0 for clinical writes.

## 3. Sharding / partitioning (modelled)

### Shard key choice

| Candidate key          | Data-locality benefit                                     | Problem (measured on seed data)                                                                                                                                                               |
| ---------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lga_id` (first draft) | LGA queries hit one shard                                 | **Skewed and too fine-grained.** Osogbo holds 17.4% of clients versus ~3% for the other LGAs. With only 30 values the shards are lumpy. Clients who move LGA must be migrated between shards. |
| `senatorial_district`  | Matches state programme administration (3 districts)      | Still skewed: Osun Central holds **42.9%** of VL rows because it contains Osogbo                                                                                                              |
| `hash(client_id)`      | Even distribution; one client's records always co-located | District and LGA reports must query every shard (scatter-gather)                                                                                                                              |

**Decision.** Use **hash-distribute on `client_id`**, for example with Citus `create_distributed_table('...', 'client_id')` and co-located clinical tables.

- **Why `client_id`:**
  - The most frequent and latency-sensitive operation is the single-client chart (Portfolio 2 Q4), and that becomes a single-shard query.
  - All joins between a client's tables stay local.
- **Reference tables replicated to every node:** `LGAs` and `Facilities` are small, so a copy on every node keeps joins to them local.
- **Cost:** district dashboards become distributed aggregates. These run on replicas or a nightly materialised view, so the cost is acceptable.

### Partitioning demo

[partitioning.sql](partitioning.sql) builds `lab_viral_load_by_district`, partitioned `BY LIST (senatorial_district)`:

- **A district query** (`WHERE senatorial_district = 'Osun East'`) scans **only `lvl_osun_east`**. This is partition pruning, the single-node equivalent of routing a query to one shard.
- **A state-wide query** produces an `Append` over all three partitions. This is the scatter-gather pattern a distributed query would follow.
- **Design point:** the primary key had to include the partition key (`PRIMARY KEY (senatorial_district, vload_id)`). Uniqueness can only be enforced _within_ a partition or shard. This is a real constraint when moving from a single node to a sharded design.

**Scale context.** At ~50k clients and <1M rows the hub fits easily on one primary. Replication for availability is needed now. Sharding is a growth path, which is why it is modelled here rather than deployed.

## 4. Cloud deployment

| Component                    | Choice                                                                                                                                  | Reason                                                                                                                                                                                                                    |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Database                     | **Managed PostgreSQL with Multi-AZ synchronous standby + 1 read replica**, e.g. Amazon RDS for PostgreSQL                               | Automated failover, backups and patching; same engine as Portfolios 1–3                                                                                                                                                   |
| Region                       | Closest compliant region, subject to data-residency review                                                                              | HIV status is sensitive personal data. Cross-border transfer must satisfy the **Nigeria Data Protection Act 2023**. If in-country hosting is required, deploy the same Patroni design on a Nigerian cloud or data centre. |
| Backups                      | Daily snapshots + continuous WAL archiving (point-in-time recovery), 35-day retention, copy to a second region                          | Recover from operator error, which replication would faithfully copy                                                                                                                                                      |
| Security                     | TLS in transit, encryption at rest (KMS), private subnet only, least-privilege roles (data clerk vs dashboard read-only), audit logging | Clinical data                                                                                                                                                                                                             |
| Document store (Portfolio 4) | Managed MongoDB replica set (3 members, `w: "majority"`)                                                                                | Majority write concern gives the same "no acknowledged write lost" guarantee                                                                                                                                              |

## 5. How to reproduce

```bash
docker compose up -d                       # primary loads Portfolio 1 schema + seed; replica clones it
./replication_demo.sh > evidence/replication_output.txt 2>&1
psql -h localhost -p 5433 -U postgres -d speed_osun -f partitioning.sql   # (or any copy of the database)
docker compose down -v                     # clean up
```
