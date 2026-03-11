# CRDB Query Tuning: Statistics & Query Planner

**When to use:** Query suddenly got slower without schema changes, wrong index chosen, or after a large data load.

> Stale stats → wrong cardinality → bad plans → slow queries with no obvious index issue.

---

## Step 1: Find Tables with Stale or Missing Statistics

```sql
-- CUSTOMIZE: staleness threshold
SELECT
    descriptor_name         AS table_name,
    MAX(created)            AS last_collected,
    now() - MAX(created)    AS age,
    MAX(row_count)          AS last_known_row_count
FROM crdb_internal.table_statistics
GROUP BY 1
HAVING MAX(created) < now() - INTERVAL '7 days'    -- CUSTOMIZE
    OR MAX(created) IS NULL
ORDER BY last_collected ASC NULLS FIRST;
```

## Step 2: View Stats for a Specific Table

```sql
SHOW STATISTICS FOR TABLE [table_name];   -- CUSTOMIZE
-- Review: created, row_count, distinct_count, null_count
```

## Step 3: Check Auto-Statistics Health

```sql
SELECT * FROM [SHOW AUTOMATIC JOBS]
WHERE job_type = 'AUTO CREATE STATS'
ORDER BY created DESC LIMIT 10;

-- Confirm auto-stats enabled:
SHOW CLUSTER SETTING sql.stats.automatic_collection.enabled;
-- Should return: true
```

## Step 4: Manually Refresh Statistics

```sql
-- Full table refresh
CREATE STATISTICS [stat_name] FROM [table_name];   -- CUSTOMIZE

-- Specific column (for skewed distributions)
CREATE STATISTICS [stat_name] ON [column_name] FROM [table_name];
```

## Step 5: Diagnose a Bad Plan

```sql
-- A: See plan and optimizer reasoning
EXPLAIN (OPT, VERBOSE) [your query];

-- B: Compare estimated vs actual rows
EXPLAIN ANALYZE (DISTSQL) [your query];
-- estimated << actual rows = table grew since stats collected
-- estimated >> actual rows = data deleted or heavily skewed

-- C: Force a specific index for testing (remove in production)
SELECT * FROM [table]@[index_name] WHERE [condition];   -- CUSTOMIZE
```

## Step 6: Tune Auto-Statistics Sensitivity

```sql
-- Lower = more frequent stats collection
SET CLUSTER SETTING sql.stats.automatic_collection.fraction_stale_rows = 0.2;  -- CUSTOMIZE

-- Minimum rows changed before triggering
SET CLUSTER SETTING sql.stats.automatic_collection.min_stale_rows = 500;       -- CUSTOMIZE
```

## Stale Stats Signals

| Signal | Meaning |
|---|---|
| Estimated rows << Actual | Table grew since stats collected |
| Estimated rows >> Actual | Data deleted or stats from larger dataset |
| Wrong index chosen | Histogram doesn't reflect current distribution |
| Good plan yesterday, bad today | Large load without stats refresh |

## Customization Checklist
- [ ] Set staleness threshold based on write volume (high-write: 1-4h, low-write: 7d)
- [ ] After bulk loads (IMPORT, large INSERT), always run `CREATE STATISTICS` manually
- [ ] For skewed multi-tenant tables, collect stats on the tenant ID column specifically
- [ ] Consider scheduling `CREATE STATISTICS` as a nightly job on critical tables
