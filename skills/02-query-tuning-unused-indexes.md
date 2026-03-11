# CRDB Query Tuning: Unused Indexes

**When to use:** Weekly index audit, pre-upgrade cleanup, or when storage/write costs are high.

> Every index adds write amplification, storage, and backup costs. Audit regularly.

---

## Step 1: Find Indexes with Zero Reads

```sql
SELECT
    descriptor_name   AS table_name,
    index_name,
    total_reads,
    last_read
FROM crdb_internal.index_usage_statistics
WHERE index_name NOT LIKE '%primary%'
  AND total_reads = 0
ORDER BY descriptor_name;
```

## Step 2: Find Stale Indexes (Low or Old Usage)

```sql
-- CUSTOMIZE: staleness threshold
SELECT
    descriptor_name   AS table_name,
    index_name,
    total_reads,
    last_read,
    CASE
        WHEN last_read IS NULL                          THEN 'NEVER READ'
        WHEN last_read < now() - INTERVAL '30 days'    THEN 'STALE 30d+'
        WHEN last_read < now() - INTERVAL '7 days'     THEN 'STALE 7d+'
        ELSE 'ACTIVE'
    END AS status
FROM crdb_internal.index_usage_statistics
WHERE index_name NOT LIKE '%primary%'
  AND (total_reads = 0 OR last_read < now() - INTERVAL '7 days')  -- CUSTOMIZE
ORDER BY total_reads ASC, last_read ASC NULLS FIRST;
```

## Step 3: View All Indexes on a Table

```sql
SHOW INDEXES FROM [table_name];   -- CUSTOMIZE
```

## Step 4: Validate Before Dropping

```sql
-- Run EXPLAIN on critical queries first
EXPLAIN (VERBOSE) SELECT [columns] FROM [table] WHERE [condition];
-- If the index name appears in the plan → DO NOT drop it
```

## Step 5: Safely Drop the Index

```sql
DROP INDEX IF EXISTS [table_name]@[index_name];
```

## Step 6: Monitor After Drop

```sql
EXPLAIN ANALYZE (DISTSQL) SELECT [columns] FROM [table] WHERE [condition];
-- Verify no plan regression
```

## Customization Checklist
- [ ] Set staleness threshold to match your query pattern (7d, 30d, 90d)
- [ ] Add `AND descriptor_name = '[table]'` to scope to specific tables
- [ ] Always EXPLAIN top queries before dropping
- [ ] Schedule this audit weekly/monthly
- [ ] Note: `index_usage_statistics` resets on node restart — use 30d+ windows for accuracy

## DB Console Shortcut
**DB Console → Databases → [Database] → [Table] → Indexes tab**
