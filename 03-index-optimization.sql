-- =============================================================================
-- 03-index-optimization.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Index Analysis and Optimization
-- =============================================================================
--
-- PURPOSE:
--   Indexes are one of the biggest levers for both performance AND cost.
--   - Missing indexes cause full scans (wastes CPU).
--   - Unused indexes waste storage and add write amplification on every
--     INSERT/UPDATE/DELETE.
--   - Over-indexed tables slow down writes and increase backup sizes.
--
--   This file helps you find and fix all three problems.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - CockroachDB v22.2+
--   - Index usage statistics must be enabled (on by default)
--
-- All queries are read-only unless marked with "ACTION:".
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Unused Indexes (Total Reads < 10)
-- ---------------------------------------------------------------------------
-- Finds secondary indexes that have been read fewer than 10 times since
-- statistics were last reset. These indexes cost storage and write
-- amplification but provide no query benefit.
--
-- WHAT TO LOOK FOR:
--   - Indexes with total_reads = 0 are almost certainly safe to drop.
--   - Indexes with total_reads < 10 may be used only by rare admin queries.
--   - Check last_read: if it is NULL or > 30 days ago, the index is stale.
--   - ALWAYS verify with EXPLAIN on key queries before dropping.
--
-- EXAMPLE OUTPUT:
--   table_name | index_name        | total_reads | last_read           | status
--   -----------+-------------------+-------------+---------------------+-----------
--   orders     | idx_orders_region |           0 | NULL                | NEVER READ
--   users      | idx_users_email   |           3 | 2024-11-01 10:00:00 | STALE (30d+)

SELECT
    ti.descriptor_name                   AS table_name,
    ti.index_name,
    ti.total_reads,
    ti.last_read,
    CASE
        WHEN ti.last_read IS NULL THEN 'NEVER READ'
        WHEN ti.last_read < now() - INTERVAL '30 days' THEN 'STALE (30d+)'
        ELSE 'ACTIVE'
    END                                  AS status
FROM crdb_internal.index_usage_statistics ti
WHERE ti.total_reads < 10
  AND ti.index_name NOT LIKE '%primary%'
ORDER BY ti.total_reads ASC, ti.descriptor_name
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 2. Completely Unused Indexes (Zero Reads)
-- ---------------------------------------------------------------------------
-- A stricter filter: indexes with absolutely zero reads.
--
-- ACTION: After verifying these indexes are not needed, drop them:
--   DROP INDEX IF EXISTS <table_name>@<index_name>;
--   Always test with EXPLAIN on critical queries first.

SELECT
    ti.descriptor_name                   AS table_name,
    ti.index_name,
    ti.total_reads,
    ti.last_read
FROM crdb_internal.index_usage_statistics ti
WHERE ti.total_reads = 0
  AND ti.index_name NOT LIKE '%primary%'
ORDER BY ti.descriptor_name;


-- ---------------------------------------------------------------------------
-- 3. Over-Indexed Tables (More Than 5 Indexes)
-- ---------------------------------------------------------------------------
-- Tables with many indexes pay a write amplification penalty on every
-- INSERT, UPDATE, and DELETE. Each additional index adds a separate KV
-- write.
--
-- WHAT TO LOOK FOR:
--   - Tables with > 5 indexes: review each index for necessity.
--   - Cross-reference with the unused index queries above.
--   - Consider consolidating overlapping indexes (e.g., if you have an
--     index on (a) and another on (a, b), the single-column index is
--     often redundant).
--
-- EXAMPLE OUTPUT:
--   table_name | index_count
--   -----------+------------
--   orders     |           8
--   events     |           6

SELECT
    table_name,
    COUNT(*)                             AS index_count
FROM information_schema.statistics
GROUP BY table_name
HAVING COUNT(*) > 5
ORDER BY index_count DESC;


-- ---------------------------------------------------------------------------
-- 4. Index Usage Statistics (Full View)
-- ---------------------------------------------------------------------------
-- Shows read counts for all indexes, sorted by most-used first. Useful for
-- understanding which indexes are actually providing value.
--
-- WHAT TO LOOK FOR:
--   - Primary indexes will typically have the highest reads.
--   - Secondary indexes with very low reads relative to others may be
--     candidates for removal.

SELECT
    ti.descriptor_name                   AS table_name,
    ti.index_name,
    ti.total_reads,
    ti.last_read
FROM crdb_internal.index_usage_statistics ti
ORDER BY ti.total_reads DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 5. SELECT * Audit (Missing Covering Index Candidates)
-- ---------------------------------------------------------------------------
-- Finds queries that use SELECT * and read large amounts of data. These
-- queries are candidates for:
--   (a) Rewriting to select only needed columns, or
--   (b) Adding a covering index with STORING to avoid primary key lookups.
--
-- WHAT TO LOOK FOR:
--   - High avg_bytes_read with SELECT * patterns.
--   - High exec_count makes the waste compound quickly.
--   - For each query found here, check: does the query actually need all
--     columns? If not, rewrite it. If it does, consider a covering index.
--
-- HOW TO ADD A COVERING INDEX:
--   CREATE INDEX idx_orders_customer
--   ON orders (customer_id)
--   STORING (status, created_at, total);
--   -- This lets queries filtered on customer_id also fetch status,
--   -- created_at, and total without a KV round-trip to the primary index.

SELECT
    substring(key, 1, 100)                                   AS fingerprint,
    (statistics->'statistics'->'bytesRead'->'mean')::FLOAT   AS avg_bytes_read,
    (statistics->'statistics'->'cnt')::INT                    AS exec_count,
    (statistics->'statistics'->'rowsRead'->'mean')::FLOAT    AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE key ILIKE '%select *%'
  AND (statistics->'statistics'->'bytesRead'->'mean')::FLOAT > 100000
  AND aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY avg_bytes_read DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 6. Hot Key / Monotonic Primary Key Detection
-- ---------------------------------------------------------------------------
-- Finds tables with sequential primary keys (nextval, unique_rowid) that
-- can cause write hotspots. All inserts go to the last range when the PK
-- is monotonically increasing.
--
-- WHAT TO LOOK FOR:
--   - Tables using nextval() or unique_rowid() in their PK default.
--   - These tables are at high risk for write hotspots.
--
-- FIXES:
--   - Use UUID primary keys:
--       ALTER TABLE events ALTER COLUMN id SET DEFAULT gen_random_uuid();
--   - Use hash-sharded indexes:
--       CREATE INDEX ON events (id) USING HASH WITH BUCKET_COUNT = 8;
--   - For new tables, design with UUID PKs from the start:
--       CREATE TABLE events (
--           id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
--           ...
--       );

SELECT
    table_name,
    column_name,
    column_default
FROM information_schema.columns
WHERE column_default LIKE '%nextval%'
   OR column_default LIKE '%unique_rowid%'
ORDER BY table_name;


-- ---------------------------------------------------------------------------
-- 7. Check for Index Recommendations in Statement Statistics
-- ---------------------------------------------------------------------------
-- CockroachDB tracks index recommendations for queries that would benefit
-- from new indexes. This surfaces the optimizer's own suggestions.
--
-- WHAT TO LOOK FOR:
--   - Repeated recommendations for the same index across many queries
--     strongly indicate a missing index.
--   - Evaluate the recommendation against your write patterns before adding.

SELECT
    substring(key, 1, 80)                                    AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                   AS exec_count,
    statistics->'statistics'->'indexes'                      AS index_recommendations
FROM crdb_internal.statement_statistics
WHERE statistics->'statistics'->'indexes' IS NOT NULL
  AND statistics->'statistics'->'indexes' != 'null'
  AND aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY exec_count DESC
LIMIT 20;


-- ---------------------------------------------------------------------------
-- 8. Show All Indexes on a Specific Table (Template)
-- ---------------------------------------------------------------------------
-- Replace 'your_table_name' with the actual table name.
-- Use this to audit a specific table after identifying it in the queries above.

-- SHOW INDEXES FROM your_table_name;

-- Or use information_schema for a more detailed view:
-- SELECT
--     index_name,
--     column_name,
--     seq_in_index,
--     direction,
--     storing,
--     implicit
-- FROM information_schema.statistics
-- WHERE table_name = 'your_table_name'
-- ORDER BY index_name, seq_in_index;


-- =============================================================================
-- END OF 03-index-optimization.sql
-- =============================================================================
