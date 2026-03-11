-- =============================================================================
-- 05-run-diagnostics.sql
-- CockroachDB Cost Optimization Workshop - Diagnostic Queries
-- =============================================================================
-- PURPOSE:
--   These are the diagnostic queries the presenter runs AFTER executing the
--   bad workload scripts (00 through 04). Each query detects a specific
--   optimization opportunity and is annotated with expected results.
--
-- INSTRUCTIONS:
--   Run each diagnostic query one at a time. Discuss the results with the
--   audience and explain how to interpret them.
--
-- ESTIMATED TIME: 10-15 minutes (discussion included)
-- =============================================================================

USE cost_optimization_demo;


-- =============================================================================
-- DIAGNOSTIC 1: DETECT FULL TABLE SCANS
-- =============================================================================
-- This query finds statements that performed full table scans. These are
-- queries that read entire tables because no suitable index was available.
--
-- EXPECTED RESULT: You should see queries from 02-bad-queries.sql including:
--   - SELECT on users WHERE name = ... (no index on name)
--   - SELECT on users WHERE email LIKE '%@gmail.com' (leading wildcard)
--   - SELECT on audit_logs WHERE details->>'ip' = ... (JSONB filter)
--   - SELECT on payments WHERE id::STRING LIKE ... (type conversion)

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 1: Full Table Scans Detected' AS section;
SELECT '================================================================' AS section;

SELECT
    metadata->>'query' AS query_text,
    statistics->'statistics'->'cnt' AS execution_count,
    statistics->'statistics'->'rowsRead'->'mean' AS avg_rows_read,
    statistics->'statistics'->'numRows'->'mean' AS avg_rows_returned,
    statistics->'statistics'->'runLat'->'mean' AS avg_latency_seconds
FROM crdb_internal.statement_statistics
WHERE metadata->>'fullScan' = 'true'
    AND metadata->>'db' = 'cost_optimization_demo'
ORDER BY (statistics->'statistics'->'runLat'->'mean')::FLOAT DESC
LIMIT 20;


-- =============================================================================
-- DIAGNOSTIC 2: UNUSED INDEXES
-- =============================================================================
-- This query finds indexes that have not been used for any reads since the
-- cluster started (or since stats were last reset). These indexes cost
-- storage and write amplification for zero benefit.
--
-- EXPECTED RESULT: You should see at least 6 unused indexes:
--   - idx_users_last_login_unused
--   - idx_products_inventory_count_unused
--   - idx_audit_logs_action_unused
--   - idx_sessions_created_at_unused
--   - idx_payments_method_unused
--   - idx_inv_movements_created_at_unused
--   Plus several of the over-indexing indexes on the orders table.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 2: Unused Indexes' AS section;
SELECT '================================================================' AS section;

SELECT
    ti.descriptor_name AS table_name,
    ti.index_name,
    ti.index_type,
    total_reads,
    total_writes,
    created_at AS index_created_at,
    last_read
FROM crdb_internal.index_usage_statistics AS us
JOIN crdb_internal.table_indexes AS ti
    ON us.index_id = ti.index_id
    AND us.table_id = ti.descriptor_id
WHERE total_reads = 0
    AND ti.descriptor_name IN (
        'users', 'products', 'orders', 'order_items',
        'audit_logs', 'sessions', 'payments', 'inventory_movements'
    )
    AND index_type != 'primary'
ORDER BY total_writes DESC;


-- =============================================================================
-- DIAGNOSTIC 3: CPU-HEAVY / HIGH-LATENCY QUERIES
-- =============================================================================
-- This query identifies the most CPU-intensive statements by looking at
-- cumulative execution time (count * average latency).
--
-- EXPECTED RESULT: You should see the bad queries from 02-bad-queries.sql
-- dominating this list, particularly:
--   - The cross join query
--   - The full table scan queries
--   - The large OFFSET pagination queries

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 3: CPU-Heavy / High-Latency Queries' AS section;
SELECT '================================================================' AS section;

SELECT
    metadata->>'query' AS query_text,
    statistics->'statistics'->'cnt' AS exec_count,
    round(
        (statistics->'statistics'->'runLat'->'mean')::FLOAT::DECIMAL * 1000, 2
    ) AS avg_latency_ms,
    round(
        (statistics->'statistics'->'runLat'->'mean')::FLOAT::DECIMAL *
        (statistics->'statistics'->'cnt')::INT::DECIMAL * 1000, 2
    ) AS total_latency_ms,
    statistics->'statistics'->'rowsRead'->'mean' AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE metadata->>'db' = 'cost_optimization_demo'
    AND (statistics->'statistics'->'cnt')::INT > 0
ORDER BY (statistics->'statistics'->'runLat'->'mean')::FLOAT *
         (statistics->'statistics'->'cnt')::INT DESC
LIMIT 20;


-- =============================================================================
-- DIAGNOSTIC 4: ROWS READ vs ROWS RETURNED (Inefficient Queries)
-- =============================================================================
-- This query finds statements with a high ratio of rows read to rows returned.
-- A high ratio means the query is doing a lot of work to produce few results.
-- Ratios above 100:1 are usually a sign of missing indexes.
--
-- EXPECTED RESULT: You should see:
--   - The JSONB filter query (reads 1M rows, returns ~10)
--   - The LIKE '%@gmail.com' query (reads 50K, returns ~10K)
--   - The OFFSET 100000 LIMIT 10 query (reads 100K, returns 10)

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 4: Rows Read vs Rows Returned (Inefficient Queries)' AS section;
SELECT '================================================================' AS section;

SELECT
    metadata->>'query' AS query_text,
    statistics->'statistics'->'cnt' AS exec_count,
    round((statistics->'statistics'->'rowsRead'->'mean')::FLOAT::DECIMAL, 0) AS avg_rows_read,
    round((statistics->'statistics'->'numRows'->'mean')::FLOAT::DECIMAL, 0) AS avg_rows_returned,
    CASE
        WHEN (statistics->'statistics'->'numRows'->'mean')::FLOAT > 0
        THEN round(
            (statistics->'statistics'->'rowsRead'->'mean')::FLOAT::DECIMAL /
            (statistics->'statistics'->'numRows'->'mean')::FLOAT::DECIMAL, 1
        )
        ELSE 0
    END AS read_to_return_ratio
FROM crdb_internal.statement_statistics
WHERE metadata->>'db' = 'cost_optimization_demo'
    AND (statistics->'statistics'->'cnt')::INT > 0
    AND (statistics->'statistics'->'numRows'->'mean')::FLOAT > 0
ORDER BY (statistics->'statistics'->'rowsRead'->'mean')::FLOAT /
         GREATEST((statistics->'statistics'->'numRows'->'mean')::FLOAT, 1) DESC
LIMIT 20;


-- =============================================================================
-- DIAGNOSTIC 5: CONTENTION EVENTS
-- =============================================================================
-- This query shows recent transaction contention events. Contention occurs
-- when multiple transactions try to write to the same key simultaneously.
--
-- EXPECTED RESULT: You should see contention events from 03-generate-contention.sql
-- targeting the contention_demo table and possibly the orders table.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 5: Contention Events' AS section;
SELECT '================================================================' AS section;

-- Show contention from transaction contention events
SELECT
    table_id,
    index_id,
    num_contention_events,
    cumulative_contention_time,
    key
FROM crdb_internal.cluster_contention_events
ORDER BY num_contention_events DESC
LIMIT 20;


-- =============================================================================
-- DIAGNOSTIC 6: HOT RANGES
-- =============================================================================
-- This query identifies ranges with disproportionate QPS (queries per second).
-- Hot ranges indicate uneven load distribution, often caused by monotonic keys.
--
-- EXPECTED RESULT: You should see the payments table ranges showing
-- higher QPS than other tables, especially the last range which receives
-- all sequential inserts.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 6: Hot Ranges (Range Distribution)' AS section;
SELECT '================================================================' AS section;

-- Show ranges sorted by size (proxy for activity in this demo)
SELECT
    table_name,
    start_key,
    end_key,
    lease_holder,
    replicas,
    range_size / 1000000 AS range_size_mb
FROM [SHOW RANGES FROM DATABASE cost_optimization_demo]
ORDER BY range_size DESC
LIMIT 20;

-- Compare range distribution: monotonic vs UUID tables
SELECT
    'payments (monotonic INT PK)' AS table_type,
    count(*) AS num_ranges,
    sum(range_size) / 1000000 AS total_size_mb,
    max(range_size) / 1000000 AS largest_range_mb,
    min(range_size) / 1000000 AS smallest_range_mb
FROM [SHOW RANGES FROM TABLE payments]

UNION ALL

SELECT
    'payments_fixed (UUID PK)' AS table_type,
    count(*) AS num_ranges,
    sum(range_size) / 1000000 AS total_size_mb,
    max(range_size) / 1000000 AS largest_range_mb,
    min(range_size) / 1000000 AS smallest_range_mb
FROM [SHOW RANGES FROM TABLE payments_fixed];


-- =============================================================================
-- DIAGNOSTIC 7: STALE TABLE STATISTICS
-- =============================================================================
-- Table statistics are used by the query optimizer to choose execution plans.
-- Stale statistics can cause the optimizer to choose suboptimal plans.
--
-- EXPECTED RESULT: Since we ran ANALYZE in 00-setup-schema.sql but then
-- inserted more data in 04-generate-hotspots.sql, the payments and
-- inventory_movements statistics may be stale (row count mismatch).

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 7: Table Statistics Freshness' AS section;
SELECT '================================================================' AS section;

SELECT
    table_name,
    statistic_name AS stat_name,
    column_names,
    row_count AS stats_row_count,
    created AS stats_collected_at
FROM [SHOW STATISTICS FOR TABLE users]
WHERE statistic_name = '__auto__'
ORDER BY created DESC LIMIT 1;

SELECT
    table_name,
    statistic_name AS stat_name,
    column_names,
    row_count AS stats_row_count,
    created AS stats_collected_at
FROM [SHOW STATISTICS FOR TABLE orders]
WHERE statistic_name = '__auto__'
ORDER BY created DESC LIMIT 1;

SELECT
    table_name,
    statistic_name AS stat_name,
    column_names,
    row_count AS stats_row_count,
    created AS stats_collected_at
FROM [SHOW STATISTICS FOR TABLE payments]
WHERE statistic_name = '__auto__'
ORDER BY created DESC LIMIT 1;

-- Compare stats row counts with actual counts
SELECT
    'users' AS table_name,
    count(*) AS actual_rows
FROM users
UNION ALL
SELECT 'orders', count(*) FROM orders
UNION ALL
SELECT 'payments', count(*) FROM payments
UNION ALL
SELECT 'inventory_movements', count(*) FROM inventory_movements
ORDER BY table_name;


-- =============================================================================
-- DIAGNOSTIC 8: OVER-INDEXED TABLES
-- =============================================================================
-- This query identifies tables that have an excessive number of indexes
-- relative to their column count. Over-indexing wastes storage and slows
-- down writes because every INSERT/UPDATE/DELETE must maintain all indexes.
--
-- EXPECTED RESULT: The 'orders' table should appear with 9 indexes
-- (including PK). For a table with only 6 columns, this is excessive.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 8: Over-Indexed Tables' AS section;
SELECT '================================================================' AS section;

SELECT
    table_name,
    count(*) AS index_count,
    string_agg(index_name, ', ' ORDER BY index_name) AS index_names
FROM [SHOW INDEXES FROM cost_optimization_demo]
WHERE table_name IN (
    'users', 'products', 'orders', 'order_items',
    'audit_logs', 'sessions', 'payments', 'inventory_movements'
)
GROUP BY table_name
HAVING count(*) > 4
ORDER BY count(*) DESC;


-- =============================================================================
-- DIAGNOSTIC 9: REDUNDANT INDEXES
-- =============================================================================
-- This query helps identify indexes that are prefixes of other indexes.
-- For example, an index on (user_id) is redundant if an index on
-- (user_id, created_at) already exists -- the composite index can serve
-- all queries that the single-column index serves.
--
-- EXPECTED RESULT: You should see:
--   - idx_orders_user_id_redundant is a prefix of idx_orders_user_id_created
--   - idx_products_category is a prefix of idx_products_category_price

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 9: Potentially Redundant Indexes' AS section;
SELECT '================================================================' AS section;

SELECT
    a.table_name,
    a.index_name AS shorter_index,
    a.column_name AS shorter_index_column,
    b.index_name AS longer_index,
    b.column_name AS longer_index_columns
FROM (
    SELECT table_name, index_name, column_name, seq_in_index
    FROM [SHOW INDEXES FROM cost_optimization_demo]
    WHERE seq_in_index = 1
) a
JOIN (
    SELECT table_name, index_name, column_name, seq_in_index
    FROM [SHOW INDEXES FROM cost_optimization_demo]
    WHERE seq_in_index = 1
) b ON a.table_name = b.table_name
    AND a.column_name = b.column_name
    AND a.index_name != b.index_name
WHERE a.table_name IN (
    'users', 'products', 'orders', 'order_items',
    'audit_logs', 'sessions', 'payments', 'inventory_movements'
)
ORDER BY a.table_name, a.index_name;


-- =============================================================================
-- DIAGNOSTIC 10: TTL CANDIDATES (Large Tables with Old Data)
-- =============================================================================
-- Tables that accumulate historical data are candidates for Row-Level TTL.
-- This query identifies tables with old data that could be automatically
-- expired.
--
-- EXPECTED RESULT: audit_logs and sessions should appear as TTL candidates
-- because they have data spanning 2 years with no cleanup mechanism.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 10: Row-Level TTL Candidates' AS section;
SELECT '================================================================' AS section;

-- Check how much old data exists in audit_logs
SELECT
    'audit_logs' AS table_name,
    count(*) AS total_rows,
    count(*) FILTER (WHERE created_at < now() - INTERVAL '90 days') AS rows_older_than_90d,
    count(*) FILTER (WHERE created_at < now() - INTERVAL '365 days') AS rows_older_than_1y,
    round(
        count(*) FILTER (WHERE created_at < now() - INTERVAL '90 days')::DECIMAL /
        count(*)::DECIMAL * 100, 1
    ) AS pct_older_than_90d
FROM audit_logs;

SELECT
    'sessions' AS table_name,
    count(*) AS total_rows,
    count(*) FILTER (WHERE last_active_at < now() - INTERVAL '7 days') AS inactive_over_7d,
    count(*) FILTER (WHERE last_active_at < now() - INTERVAL '30 days') AS inactive_over_30d,
    round(
        count(*) FILTER (WHERE last_active_at < now() - INTERVAL '30 days')::DECIMAL /
        count(*)::DECIMAL * 100, 1
    ) AS pct_inactive_30d
FROM sessions;

-- Show the recommended TTL ALTER statements
SELECT 'To enable TTL on audit_logs (expire after 90 days):' AS recommendation;
SELECT 'ALTER TABLE audit_logs SET (ttl_expire_after = ''90 days'', ttl_job_cron = ''@daily'');' AS sql;

SELECT 'To enable TTL on sessions (expire after 7 days of inactivity):' AS recommendation;
SELECT 'ALTER TABLE sessions SET (ttl_expire_after = ''7 days'', ttl_job_cron = ''@hourly'');' AS sql;


-- =============================================================================
-- DIAGNOSTIC 11: STORAGE USAGE BY TABLE
-- =============================================================================
-- Shows how much storage each table and its indexes consume.
-- This helps prioritize which optimizations will save the most resources.
--
-- EXPECTED RESULT: order_items and audit_logs should be the largest tables.
-- The wide covering indexes should show significant storage overhead.

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTIC 11: Storage Usage by Table' AS section;
SELECT '================================================================' AS section;

SELECT
    table_name,
    sum(range_size) / 1000000 AS total_size_mb,
    count(*) AS num_ranges
FROM [SHOW RANGES FROM DATABASE cost_optimization_demo]
GROUP BY table_name
ORDER BY sum(range_size) DESC;


-- =============================================================================
-- SUMMARY
-- =============================================================================

SELECT '================================================================' AS section;
SELECT 'DIAGNOSTICS COMPLETE - Summary of Findings' AS section;
SELECT '================================================================' AS section;
SELECT '' AS section;
SELECT 'FINDING 1: Full table scans detected on users, audit_logs, payments' AS finding;
SELECT 'FINDING 2: 6+ unused indexes consuming storage with zero reads' AS finding;
SELECT 'FINDING 3: orders table is over-indexed with 9 indexes on 6 columns' AS finding;
SELECT 'FINDING 4: Redundant indexes detected (user_id prefix of user_id,created_at)' AS finding;
SELECT 'FINDING 5: JSONB filter and LIKE wildcard queries have 1000:1+ read ratio' AS finding;
SELECT 'FINDING 6: Lock contention events from concurrent updates' AS finding;
SELECT 'FINDING 7: Monotonic PK causing write hotspot on payments table' AS finding;
SELECT 'FINDING 8: audit_logs and sessions are TTL candidates (old data accumulation)' AS finding;
SELECT 'FINDING 9: Table statistics may be stale after bulk inserts' AS finding;
SELECT '' AS section;
SELECT 'Refer to the workshop deck for recommended fixes for each finding.' AS next_step;
