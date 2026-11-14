-- =========================================================================
-- Horizontal partitioning by senatorial district: a single-node model of
-- the sharding design in distributed-architecture.md. Each partition stands
-- in for one shard; partition pruning stands in for shard routing.
--   psql -d speed_osun -f partitioning.sql > evidence/partitioning_output.txt
-- =========================================================================
\pset pager off
SET max_parallel_workers_per_gather = 0;

-- Why NOT shard by LGA: distribution is skewed (Osogbo is the state capital).
SELECT l.lga_name, COUNT(*) AS clients,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM Clients c JOIN LGAs l ON l.lga_id = c.lga_id
GROUP BY l.lga_name ORDER BY clients DESC LIMIT 5;

DROP TABLE IF EXISTS lab_viral_load_by_district CASCADE;

-- The shard key (senatorial_district) is carried on the row. Distributed
-- PostgreSQL (e.g. Citus) likewise needs the distribution column in every
-- co-located table, so it is denormalised here on purpose.
CREATE TABLE lab_viral_load_by_district (
    vload_id              INT NOT NULL,
    client_id             INT NOT NULL,
    facility_id           INT NOT NULL,
    senatorial_district   VARCHAR(20) NOT NULL,
    sample_collected_date DATE NOT NULL,
    result_date           DATE,
    viral_load_copies     INT,
    suppression_status    VARCHAR(20) NOT NULL,
    PRIMARY KEY (senatorial_district, vload_id)   -- PK must include the partition key
) PARTITION BY LIST (senatorial_district);

CREATE TABLE lvl_osun_central PARTITION OF lab_viral_load_by_district FOR VALUES IN ('Osun Central');
CREATE TABLE lvl_osun_east    PARTITION OF lab_viral_load_by_district FOR VALUES IN ('Osun East');
CREATE TABLE lvl_osun_west    PARTITION OF lab_viral_load_by_district FOR VALUES IN ('Osun West');

INSERT INTO lab_viral_load_by_district
SELECT v.vload_id, v.client_id, v.facility_id, l.senatorial_district,
       v.sample_collected_date, v.result_date, v.viral_load_copies, v.suppression_status
FROM Lab_Viral_Load v
JOIN Clients c ON c.client_id = v.client_id
JOIN LGAs l    ON l.lga_id = c.lga_id;

ANALYZE lab_viral_load_by_district;

-- Rows per partition ("shard balance")
SELECT tableoid::regclass AS partition, COUNT(*) AS rows,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM lab_viral_load_by_district GROUP BY 1 ORDER BY 1;

-- District-local query: only ONE partition is scanned (partition pruning).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT suppression_status, COUNT(*)
FROM lab_viral_load_by_district
WHERE senatorial_district = 'Osun East'
GROUP BY suppression_status;

-- State-wide query: must visit EVERY partition (scatter-gather across shards).
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT suppression_status, COUNT(*)
FROM lab_viral_load_by_district
GROUP BY suppression_status;
