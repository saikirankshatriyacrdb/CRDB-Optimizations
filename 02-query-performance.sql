-- =============================================================================
-- 02-query-performance.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Query Performance Diagnostics
-- =============================================================================
--
-- PURPOSE:
--   Identify the most expensive queries in your cluster so you can focus
--   optimization effort where it will have the biggest cost impact.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - CockroachDB v22.2+
--   - Statement statistics must be enabled (on by default)
--
-- All queries are read-only.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Top CPU-Heavy Queries (Last 24 Hours)
-- ---------------------------------------------------------------------------
-- Ranks queries by total CPU time consumed across all executions.
-- This is the single most important view for cost optimization: the queries
-- at the top of this list are what your cluster spends the most compute on.
--
-- WHAT TO LOOK FOR:
--   - Queries with high total_cpu_sec are your biggest cost drivers.
--   - Compare avg_cpu_sec to avg_latency_sec: if CPU is a large fraction
--     of latency, the query is CPU-bound (optimize the plan).
--   - High exec_count with moderate avg_cpu_sec can still dominate total cost.
--
-- EXAMPLE OUTPUT:
--   fingerprint                     | exec_count | avg_cpu_sec | total_cpu_sec
--   --------------------------------+------------+-------------+--------------
--   SELECT * FROM orders WHERE ...  |     50000  |       0.12  |       6000.0
--   INSERT INTO events VALUES ...   |    200000  |       0.01  |       2000.0

SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    (statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9      AS avg_cpu_sec,
    ((statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9)
        * (statistics->'statistics'->'cnt')::INT                         AS total_cpu_sec,
    (statistics->'statistics'->'runLat'->'mean')::FLOAT                  AS avg_latency_sec,
    (statistics->'statistics'->'rowsRead'->'mean')::INT                  AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY total_cpu_sec DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 2. Top CPU-Heavy Queries (Last 1 Hour) -- Shorter Window for Active Issues
-- ---------------------------------------------------------------------------
-- Same as above but for the last hour. Use this when investigating a
-- current performance problem.

SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    (statistics->'statistics'->'runLat'->'mean')::FLOAT                  AS avg_lat_sec,
    (statistics->'statistics'->'runLat'->'mean')::FLOAT
        * (statistics->'statistics'->'cnt')::INT                         AS total_time_sec,
    (statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9      AS avg_cpu_sec,
    (statistics->'statistics'->'rowsRead'->'mean')::INT                  AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '1 hour'
ORDER BY total_time_sec DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 3. Full Table Scan Queries with Read Amplification
-- ---------------------------------------------------------------------------
-- Finds queries that are doing full table scans. Full scans read every row
-- in the table regardless of how many rows the query actually needs.
--
-- WHAT TO LOOK FOR:
--   - Any query here is a candidate for adding an index.
--   - Compare avg_rows_read to the table size. If they are close, the query
--     is scanning the entire table.
--   - High exec_count on a full-scan query is extremely expensive.

SELECT
    substring(key, 1, 60)                                     AS statement_fingerprint,
    (statistics->'statistics'->'cnt')::INT                    AS exec_count,
    (statistics->'statistics'->'rowsRead'->'mean')::FLOAT     AS avg_rows_read,
    (statistics->'statistics'->'bytesRead'->'mean')::FLOAT    AS avg_bytes_read,
    (statistics->'statistics'->'runLat'->'mean')::FLOAT       AS avg_latency_sec
FROM crdb_internal.statement_statistics
WHERE (statistics->'statistics'->'fullScans')::BOOL = true
  AND aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY avg_rows_read DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 4. Rows Read vs Rows Returned Ratio (Read Amplification)
-- ---------------------------------------------------------------------------
-- Compares how many rows the storage layer reads to how many the query
-- actually returns. A high ratio means the query is doing a lot of wasted
-- work.
--
-- WHAT TO LOOK FOR:
--   - Ratio > 10x:  Probably missing an index or predicate.
--   - Ratio > 100x: Almost certainly needs a better index or query rewrite.
--   - Ratio = 999999: Query returns 0 rows but reads many (e.g., existence
--     checks on large tables without proper indexes).
--
-- EXAMPLE OUTPUT:
--   fingerprint                     | avg_rows_read | avg_rows_returned | ratio
--   --------------------------------+---------------+-------------------+------
--   SELECT * FROM users WHERE em... |       500000  |                 1 | 500000

SELECT
    substring(key, 1, 80)                                            AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                           AS exec_count,
    (statistics->'statistics'->'rowsRead'->'mean')::FLOAT            AS avg_rows_read,
    (statistics->'statistics'->'numRows'->'mean')::FLOAT             AS avg_rows_returned,
    CASE
        WHEN (statistics->'statistics'->'numRows'->'mean')::FLOAT = 0 THEN 999999
        ELSE ROUND(
            (statistics->'statistics'->'rowsRead'->'mean')::FLOAT /
            NULLIF((statistics->'statistics'->'numRows'->'mean')::FLOAT, 0)
        )
    END                                                              AS read_to_return_ratio
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'
  AND (statistics->'statistics'->'rowsRead'->'mean')::FLOAT > 1000
ORDER BY read_to_return_ratio DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 5. Long-Running Queries (Active Right Now, > 30 seconds)
-- ---------------------------------------------------------------------------
-- Shows queries that have been executing for more than 30 seconds. These may
-- be legitimate long operations (backups, bulk imports) or problematic
-- queries that need optimization.
--
-- WHAT TO LOOK FOR:
--   - Analytical / reporting queries running on the OLTP cluster.
--   - Queries stuck waiting on locks (check contention queries below).
--   - If a query has been running for hours, consider cancelling it.
--
-- ACTION: To cancel a problem query, use:
--   CANCEL QUERY '<query_id>';

SELECT
    query_id,
    node_id,
    user_name,
    start,
    now() - start                     AS duration,
    application_name,
    query
FROM crdb_internal.cluster_queries
WHERE now() - start > INTERVAL '30 seconds'
ORDER BY duration DESC;


-- ---------------------------------------------------------------------------
-- 6. Long-Running Transactions (Active Right Now, > 30 seconds)
-- ---------------------------------------------------------------------------
-- Idle or long-running transactions hold locks, block other work, and
-- inflate MVCC storage with old versions.
--
-- WHAT TO LOOK FOR:
--   - Transactions with high duration but low num_stmts may be idle-in-
--     transaction (application opened a transaction but is not using it).
--   - High num_retries indicates serialization conflicts.
--
-- RECOMMENDATION:
--   Set idle_in_transaction_session_timeout to automatically kill idle txns:
--   SET CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout = '60s';

SELECT
    id,
    node_id,
    start,
    now() - start                     AS duration,
    txn_string,
    num_stmts,
    num_retries,
    isolation_level
FROM crdb_internal.cluster_transactions
WHERE now() - start > INTERVAL '30 seconds'
ORDER BY duration DESC;


-- ---------------------------------------------------------------------------
-- 7. Contention Events by Table/Index
-- ---------------------------------------------------------------------------
-- Aggregates lock contention events to show which tables and indexes
-- experience the most contention. High contention means transactions are
-- waiting on each other, which wastes CPU and inflates latency.
--
-- WHAT TO LOOK FOR:
--   - Tables with high total_contention_duration are bottlenecks.
--   - If contention is on a primary index with monotonic keys, consider
--     hash-sharded indexes or UUID primary keys.
--   - If contention is on a secondary index, check if SELECT FOR UPDATE
--     is being overused.

SELECT
    database_name,
    schema_name,
    table_name,
    index_name,
    COUNT(*)                            AS contention_events,
    SUM(contention_duration)            AS total_contention_duration,
    AVG(contention_duration)            AS avg_contention_duration
FROM crdb_internal.transaction_contention_events
GROUP BY 1, 2, 3, 4
ORDER BY total_contention_duration DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 8. Live Lock Contention (Right Now)
-- ---------------------------------------------------------------------------
-- Shows locks that are currently blocked (granted = false). Useful for
-- diagnosing real-time contention issues.
--
-- WHAT TO LOOK FOR:
--   - Locks with high txn_age are transactions holding locks for a long time.
--   - If the same key appears repeatedly, that key is a hotspot.

SELECT *
FROM crdb_internal.cluster_locks
WHERE granted = false
ORDER BY txn_age DESC;


-- ---------------------------------------------------------------------------
-- 9. Hot Ranges Detection
-- ---------------------------------------------------------------------------
-- Identifies the ranges (data chunks) that are handling the most queries
-- per second. Hot ranges are the #1 cause of uneven load distribution.
--
-- WHAT TO LOOK FOR:
--   - A range with queries_per_second much higher than others is a hotspot.
--   - Check the table_name and index_name to understand what data is hot.
--   - Common fixes: hash-sharded indexes, UUID PKs, or schema redesign.
--
-- EXAMPLE OUTPUT:
--   range_id | table_name | queries_per_second | lease_holder
--   ---------+------------+--------------------+-------------
--       1234 | orders     |             5000.2 |            3
--       5678 | events     |             3200.1 |            1

SELECT
    range_id,
    table_name,
    index_name,
    queries_per_second,
    written_bytes_per_second,
    read_bytes_per_second,
    lease_holder
FROM crdb_internal.ranges_no_leases
ORDER BY queries_per_second DESC
LIMIT 20;


-- =============================================================================
-- END OF 02-query-performance.sql
-- =============================================================================
