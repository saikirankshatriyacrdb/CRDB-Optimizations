-- =============================================================================
-- 06-tuning-settings.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Performance Tuning Settings
-- =============================================================================
--
-- PURPOSE:
--   CockroachDB has several configuration parameters that directly affect
--   performance, resource utilization, and cost. This file documents the
--   most impactful settings with recommended values.
--
-- IMPORTANT:
--   - Some settings require node restart (startup flags).
--   - Some settings are cluster-wide and take effect immediately.
--   - Always test in non-production first.
--   - Document your baseline before making changes.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - For startup flag changes: access to the cockroach start command or
--     Kubernetes deployment manifest
--
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Cache Configuration (Startup Flag)
-- ---------------------------------------------------------------------------
-- The --cache flag controls how much memory CockroachDB uses for its block
-- cache (Pebble/RocksDB). This is critical for read performance.
--
-- RECOMMENDATION: Set to 25-35% of total RAM.
--   - Default is 128MB, which is far too small for production.
--   - Using 25-35% leaves room for the OS page cache, SQL memory, and other
--     processes.
--
-- HOW TO SET (startup flag):
--   cockroach start --cache=.35 ...        # 35% of total RAM
--   cockroach start --cache=8GiB ...       # Fixed 8GB
--
-- Verify the current cache size (approximate):
SHOW CLUSTER SETTING kv.raft.command.max_size;
-- Note: There is no direct SQL way to check --cache. Check the startup
-- flags in your deployment config or the DB Console > Advanced Debug page.

-- ---------------------------------------------------------------------------
-- 2. Max SQL Memory (Startup Flag)
-- ---------------------------------------------------------------------------
-- The --max-sql-memory flag limits how much memory the SQL layer can use
-- for query processing (sorts, hash joins, window functions, etc.).
--
-- RECOMMENDATION: Set to 25-35% of total RAM.
--   - Default is 128MB for self-hosted, which causes queries to spill to
--     disk prematurely.
--   - Combined with --cache, total should not exceed 75% of RAM.
--
-- HOW TO SET (startup flag):
--   cockroach start --max-sql-memory=.35 ...    # 35% of total RAM
--   cockroach start --max-sql-memory=8GiB ...   # Fixed 8GB
--
-- EXAMPLE CONFIGURATION for a 32GB RAM node:
--   cockroach start \
--     --cache=.30 \            # ~9.6GB for block cache
--     --max-sql-memory=.25 \   # ~8GB for SQL processing
--     ...
-- Remaining ~14.4GB for OS page cache, Go runtime, and overhead.


-- ---------------------------------------------------------------------------
-- 3. Automatic Table Statistics
-- ---------------------------------------------------------------------------
-- Auto table statistics ensure the query optimizer has accurate data
-- distribution information. Without fresh stats, the optimizer makes
-- bad plan choices.
--
-- RECOMMENDATION: Keep enabled (default). Only disable if you have a
-- specific reason and are managing stats manually.

-- Check if auto stats are enabled:
SHOW CLUSTER SETTING sql.stats.automatic_collection.enabled;

-- ACTION: Ensure auto stats are enabled
SET CLUSTER SETTING sql.stats.automatic_collection.enabled = true;

-- Check recent auto-stats jobs:
SELECT
    job_id,
    description,
    status,
    created,
    finished
FROM [SHOW AUTOMATIC JOBS]
WHERE job_type = 'AUTO CREATE STATS'
ORDER BY created DESC
LIMIT 10;

-- Manually refresh stats on a specific table (after large data loads):
-- CREATE STATISTICS refresh_stats FROM your_table_name;


-- ---------------------------------------------------------------------------
-- 4. Admission Control
-- ---------------------------------------------------------------------------
-- Admission control prevents overload by queuing or shedding work when the
-- cluster is under heavy load. This is critical for maintaining stability
-- under mixed workloads (OLTP + background jobs).
--
-- RECOMMENDATION: Keep enabled (default in v23.1+). This prevents
-- over-provisioning the cluster just to handle occasional spikes.

-- Check if admission control is enabled:
SHOW CLUSTER SETTING admission.enabled;

-- ACTION: Enable admission control if not already enabled
-- SET CLUSTER SETTING admission.enabled = true;

-- Admission control sub-settings for fine-tuning:
-- SHOW CLUSTER SETTING admission.kv.enabled;
-- SHOW CLUSTER SETTING admission.sql_kv_response.enabled;
-- SHOW CLUSTER SETTING admission.sql_sql_response.enabled;


-- ---------------------------------------------------------------------------
-- 5. Range Split by Load
-- ---------------------------------------------------------------------------
-- When enabled, CockroachDB automatically splits ranges that receive
-- disproportionate traffic. This helps distribute hot ranges across nodes.
--
-- RECOMMENDATION: Keep enabled (default). This is essential for preventing
-- hotspots, especially with sequential key patterns.

-- Check if range split by load is enabled:
SHOW CLUSTER SETTING kv.range_split.by_load_enabled;

-- ACTION: Ensure it is enabled
-- SET CLUSTER SETTING kv.range_split.by_load_enabled = true;

-- The threshold for splitting (queries per second):
SHOW CLUSTER SETTING kv.range_split.load_qps_threshold;

-- ACTION: Lower the threshold if you want more aggressive splitting:
-- SET CLUSTER SETTING kv.range_split.load_qps_threshold = 1000;
-- Default is 2500 QPS. Lower values split sooner but create more ranges.


-- ---------------------------------------------------------------------------
-- 6. Write Buffer Size (Environment Variable)
-- ---------------------------------------------------------------------------
-- Pebble's write buffer size controls how much data is buffered in memory
-- before flushing to disk. Larger buffers improve write throughput but use
-- more memory.
--
-- RECOMMENDATION: For write-heavy workloads, increase to 128MB or 256MB.
--   Default is typically 64MB.
--
-- HOW TO SET (environment variable, before starting cockroach):
--   export COCKROACH_PEBBLE_WRITE_BUFFER_SIZE=134217728    # 128MB
--   export COCKROACH_PEBBLE_WRITE_BUFFER_SIZE=268435456    # 256MB
--
-- NOTE: This is set per-node as an environment variable, not a cluster
-- setting. Requires node restart to take effect.


-- ---------------------------------------------------------------------------
-- 7. Idle Transaction Timeout
-- ---------------------------------------------------------------------------
-- Long-idle transactions hold locks and bloat MVCC storage. Setting a
-- timeout automatically closes sessions that leave transactions open.
--
-- RECOMMENDATION: Set to 60-120 seconds for production workloads.

-- Check current setting:
SHOW CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout;

-- ACTION: Set idle transaction timeout to 120 seconds
-- SET CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout = '120s';


-- ---------------------------------------------------------------------------
-- 8. Rebalance Rate
-- ---------------------------------------------------------------------------
-- Controls how fast data moves between nodes during rebalancing. Higher
-- values speed up rebalancing but increase I/O and network load.
--
-- RECOMMENDATION: Default (32MB) is fine for steady state. Increase
-- temporarily during planned rebalancing operations (node additions,
-- decommissions) and then reset.

-- Check current rate:
SHOW CLUSTER SETTING kv.snapshot_rebalance.max_rate;

-- ACTION: Temporarily increase for faster rebalancing
-- SET CLUSTER SETTING kv.snapshot_rebalance.max_rate = '64MB';
-- After rebalancing completes, reset:
-- SET CLUSTER SETTING kv.snapshot_rebalance.max_rate = '32MB';


-- ---------------------------------------------------------------------------
-- 9. Changefeed / Rangefeed Settings
-- ---------------------------------------------------------------------------
-- Rangefeeds are required for changefeeds (CDC). They add CPU overhead
-- across the cluster even for ranges not being watched. Only enable if
-- you actively use changefeeds.

-- Check if rangefeeds are enabled:
SHOW CLUSTER SETTING kv.rangefeed.enabled;

-- ACTION: Disable rangefeeds if you do NOT use changefeeds
-- SET CLUSTER SETTING kv.rangefeed.enabled = false;


-- ---------------------------------------------------------------------------
-- 10. Summary: Recommended Startup Configuration
-- ---------------------------------------------------------------------------
-- For a production node with 32GB RAM and SSDs:
--
--   cockroach start \
--     --cache=.30 \
--     --max-sql-memory=.25 \
--     --store=/data/cockroach \
--     --join=node1:26257,node2:26257,node3:26257 \
--     --locality=region=us-east-1,zone=us-east-1a \
--     --certs-dir=/certs
--
-- Environment variables (set before starting):
--   export COCKROACH_PEBBLE_WRITE_BUFFER_SIZE=134217728   # 128MB
--
-- Cluster settings (run once after cluster init):
--   SET CLUSTER SETTING sql.stats.automatic_collection.enabled = true;
--   SET CLUSTER SETTING admission.enabled = true;
--   SET CLUSTER SETTING kv.range_split.by_load_enabled = true;
--   SET CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout = '120s';


-- ---------------------------------------------------------------------------
-- 11. View All Current Cluster Settings
-- ---------------------------------------------------------------------------
-- Use this to capture a baseline before making changes.

-- SHOW ALL CLUSTER SETTINGS;

-- Or filter to settings you have changed from defaults:
SELECT
    variable,
    value,
    description
FROM [SHOW ALL CLUSTER SETTINGS]
WHERE value != default_value
ORDER BY variable;


-- =============================================================================
-- END OF 06-tuning-settings.sql
-- =============================================================================
