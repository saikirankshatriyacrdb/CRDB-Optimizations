# CRDB Query Tuning: Rows Read vs Returned Ratio

**When to use:** High I/O costs, large bytes read per query, or part of weekly query review.

> Ratio > 100x = database scanned 100 rows to return 1. Almost always fixable with the right index.

---

## Ratio Interpretation Guide

| Ratio | Signal | Action |
|---|---|---|
| 1:1 to 10:1 | ✅ Efficient | No action |
| 10:1 to 100:1 | ⚠️ Review | Check covering index opportunity |
| 100:1 to 1000:1 | 🔶 Fix soon | Missing index or bad predicate |
| > 1000:1 | 🔴 Critical | Likely full scan — fix immediately |

---

## Step 1: Find High Ratio Queries

```sql
-- CUSTOMIZE: rowsRead threshold and INTERVAL
SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    ROUND((statistics->'statistics'->'rowsRead'->'mean')::FLOAT)         AS avg_rows_read,
    ROUND((statistics->'statistics'->'numRows'->'mean')::FLOAT)          AS avg_rows_returned,
    CASE
        WHEN (statistics->'statistics'->'numRows'->'mean')::FLOAT = 0 THEN 999999
        ELSE ROUND(
            (statistics->'statistics'->'rowsRead'->'mean')::FLOAT /
            NULLIF((statistics->'statistics'->'numRows'->'mean')::FLOAT, 0)
        )
    END                                                                  AS read_to_return_ratio
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'         -- CUSTOMIZE
  AND (statistics->'statistics'->'rowsRead'->'mean')::FLOAT > 1000  -- CUSTOMIZE
ORDER BY read_to_return_ratio DESC
LIMIT 20;
```

## Step 2: Check for KV Lookup (Index + Primary Fetch)

```sql
EXPLAIN ANALYZE (DISTSQL) [your query];
-- Two-step plan (index scan + fetch) = KV round-trip = add STORING columns
```

## Step 3: Fix — Covering Index

```sql
CREATE INDEX idx_[table]_covering
ON [table] ([filter_column])
STORING ([col1], [col2], [col3]);   -- CUSTOMIZE: all columns in SELECT list

-- Example:
-- CREATE INDEX ON orders (customer_id) STORING (status, created_at);
```

## Step 4: Fix — Partial Index

```sql
CREATE INDEX ON [table] ([other_col])
WHERE [selective_col] = '[value]';   -- CUSTOMIZE
-- Example:
-- CREATE INDEX ON orders (customer_id) WHERE status = 'PENDING';
```

## Step 5: Check for Stale Statistics

```sql
SELECT name, column_ids, created, row_count, distinct_count
FROM [SHOW STATISTICS FOR TABLE [table_name]];  -- CUSTOMIZE

-- Refresh if stale:
CREATE STATISTICS [stat_name] FROM [table_name];
```

## Customization Checklist
- [ ] Set `rowsRead > 1000` threshold based on your table sizes
- [ ] Adjust `INTERVAL` to match review cadence
- [ ] Add `AND application_name = '[app]'` to scope to specific app
- [ ] List ALL columns from SELECT clause in `STORING()` for covering index
- [ ] Re-run EXPLAIN ANALYZE after adding index to verify improvement
