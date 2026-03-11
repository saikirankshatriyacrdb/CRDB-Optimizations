-- =============================================================================
-- 04-storage-optimization.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Storage Diagnostics and Optimization
-- =============================================================================
--
-- PURPOSE:
--   Storage is often the largest line item in CockroachDB cost. This file
--   helps you understand what is consuming storage, identify tables that
--   should be using TTLs, and tune MVCC garbage collection to prevent bloat.
--
-- KEY CONCEPTS:
--   - CockroachDB stores data with MVCC (Multi-Version Concurrency Control).
--     Old versions of rows are kept until GC runs.
--   - The replication factor (default 3) multiplies raw data size.
--   - CockroachDB Cloud storage does NOT auto-shrink. Deleted data frees
--     space internally but the provisioned volume does not decrease.
--   - Self-hosted: freed space is available on the filesystem but the
--     underlying volume (EBS, PV) does not shrink automatically.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - CockroachDB v22.2+
--
-- All queries are read-only unless marked with "ACTION:".
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Table Sizes with Replication Factor
-- ---------------------------------------------------------------------------
-- Shows the approximate size of each table, the number of ranges, and the
-- configured replication factor. Multiply data size by the replication factor
-- to get total storage consumed.
--
-- WHAT TO LOOK FOR:
--   - Large tables consuming disproportionate storage.
--   - Tables with replication factor > 3 that could be reduced for non-
--     critical data.
--   - Tables that are large but rarely queried (candidates for archiving
--     or TTL).
--
-- EXAMPLE OUTPUT:
--   table_name   | approx_size_mb | range_count | replication_factor
--   -------------+----------------+-------------+-------------------
--   audit_logs   |         12000  |         300 |                  3
--   orders       |          8000  |         200 |                  3
--   sessions     |          5000  |         125 |                  3

SELECT
    table_name,
    ROUND(SUM(range_size_mb), 2)         AS approx_size_mb,
    COUNT(*)                             AS range_count,
    MAX(array_length(replicas, 1))       AS replication_factor
FROM (
    SELECT
        table_name,
        (range_size / 1024.0 / 1024.0)  AS range_size_mb,
        replicas
    FROM crdb_internal.ranges_no_leases
    WHERE table_name IS NOT NULL
      AND table_name != ''
) sub
GROUP BY table_name
ORDER BY approx_size_mb DESC
LIMIT 30;


-- ---------------------------------------------------------------------------
-- 2. Database-Level Storage Summary
-- ---------------------------------------------------------------------------
-- Aggregates storage at the database level to understand which databases
-- are consuming the most space.

SELECT
    database_name,
    ROUND(SUM(range_size / 1024.0 / 1024.0), 2)  AS approx_size_mb,
    COUNT(*)                                       AS range_count
FROM crdb_internal.ranges_no_leases
WHERE database_name IS NOT NULL
  AND database_name != ''
GROUP BY database_name
ORDER BY approx_size_mb DESC;


-- ---------------------------------------------------------------------------
-- 3. TTL Configuration Examples
-- ---------------------------------------------------------------------------
-- Row-Level TTL automatically expires old rows, preventing unbounded storage
-- growth. This is especially important for:
--   - Audit logs
--   - Session data
--   - Temporary tokens
--   - Event/telemetry tables
--   - Time-series data
--
-- IMPORTANT: TTL only prevents future growth. It does NOT reclaim storage
-- from already-deleted data on CockroachDB Cloud (storage does not shrink).
-- On self-hosted, freed space is available on the filesystem.

-- ACTION: Example - Add 90-day TTL to an audit_logs table
-- Rows older than 90 days will be automatically deleted.
--
-- ALTER TABLE audit_logs SET (
--     ttl_expiration_expression = 'created_at + INTERVAL ''90 days''',
--     ttl_job_cron = '@daily'
-- );

-- ACTION: Example - Add 24-hour TTL to a sessions table
-- Session records expire after 24 hours.
--
-- ALTER TABLE sessions SET (
--     ttl_expiration_expression = 'last_active_at + INTERVAL ''24 hours''',
--     ttl_job_cron = '@hourly'
-- );

-- ACTION: Example - Add 7-day TTL to a tokens table
-- Tokens expire after 7 days.
--
-- ALTER TABLE tokens SET (
--     ttl_expiration_expression = 'issued_at + INTERVAL ''7 days''',
--     ttl_job_cron = '@daily'
-- );

-- ACTION: Example - Create a new table with TTL built in
-- CREATE TABLE telemetry_events (
--     id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
--     event_type STRING NOT NULL,
--     payload JSONB,
--     created_at TIMESTAMPTZ NOT NULL DEFAULT now()
-- ) WITH (
--     ttl_expiration_expression = 'created_at + INTERVAL ''30 days''',
--     ttl_job_cron = '@daily'
-- );

-- Check which tables already have TTL configured:
SELECT
    name                                 AS table_name,
    create_statement
FROM crdb_internal.tables
WHERE create_statement LIKE '%ttl%'
ORDER BY name;


-- ---------------------------------------------------------------------------
-- 4. MVCC Garbage Collection Tuning (gc.ttlseconds)
-- ---------------------------------------------------------------------------
-- CockroachDB keeps old MVCC versions of rows for a configurable period.
-- The default is 14400 seconds (4 hours) for user data. If you do not need
-- point-in-time reads (AS OF SYSTEM TIME) going back that far, you can
-- reduce this to free up space faster.
--
-- WHAT TO LOOK FOR:
--   - If you never use AS OF SYSTEM TIME or follower reads, you can safely
--     reduce gc.ttlseconds to 600 (10 minutes).
--   - If you use follower reads, keep gc.ttlseconds >= your staleness bound
--     (typically >= 300 seconds / 5 minutes).
--   - Tables with heavy UPDATE/DELETE activity benefit most from shorter GC.
--
-- CAUTION:
--   - Do NOT set gc.ttlseconds lower than your backup frequency, or backups
--     may fail with "protected timestamp" errors.
--   - Do NOT set it lower than your changefeed lag tolerance.

-- Check current GC TTL for all zones:
SHOW ZONE CONFIGURATIONS;

-- ACTION: Reduce GC TTL for a specific table to 10 minutes (600 seconds)
-- ALTER TABLE orders CONFIGURE ZONE USING gc.ttlseconds = 600;

-- ACTION: Reduce GC TTL for an entire database
-- ALTER DATABASE mydb CONFIGURE ZONE USING gc.ttlseconds = 600;

-- ACTION: Set GC TTL cluster-wide (affects all new tables)
-- ALTER RANGE default CONFIGURE ZONE USING gc.ttlseconds = 600;


-- ---------------------------------------------------------------------------
-- 5. Replication Factor Optimization
-- ---------------------------------------------------------------------------
-- The default replication factor is 3 (three copies of every range). For
-- non-critical environments (dev, staging, test), you can reduce this to
-- save storage.
--
-- CAUTION:
--   - NEVER reduce replication factor below 3 for production data.
--   - Replication factor 1 means a single node failure loses data.

-- ACTION: Reduce replication for a non-critical database (dev/staging only)
-- ALTER DATABASE staging CONFIGURE ZONE USING num_replicas = 3;

-- ACTION: Reduce replication for a specific non-critical table
-- ALTER TABLE staging_logs CONFIGURE ZONE USING num_replicas = 1;

-- Check current replication factor for all zones:
SELECT
    target,
    config
FROM [SHOW ALL ZONE CONFIGURATIONS]
ORDER BY target;


-- ---------------------------------------------------------------------------
-- 6. Storage Reclamation Notes
-- ---------------------------------------------------------------------------
-- Summary of how storage reclamation works:
--
-- COCKROACHDB CLOUD:
--   - Provisioned storage NEVER auto-shrinks.
--   - Deleting data, dropping tables, or running TTL will free space
--     internally but the billing volume stays the same.
--   - To actually reduce storage cost: take a full BACKUP, create a new
--     cluster with smaller storage, and RESTORE into it.
--
-- SELF-HOSTED:
--   - Deleting data and waiting for GC/compaction frees space on the
--     filesystem (df shows more available space).
--   - However, the underlying volume (EBS, PV, etc.) does not shrink.
--   - To reduce volume size: add new smaller-disk nodes, wait for
--     rebalancing, then decommission old large-disk nodes.
--   - Single-node: backup, provision smaller disk, restore.
--
-- IN BOTH CASES:
--   - Unused indexes consume storage. Drop them (see 03-index-optimization.sql).
--   - Old MVCC versions consume storage. Tune gc.ttlseconds (see above).
--   - Tables without TTL grow unbounded. Add TTLs (see above).
--   - Wide rows with unused columns waste space. Consider column families.


-- =============================================================================
-- END OF 04-storage-optimization.sql
-- =============================================================================
