# CRDB Query Tuning: Join Optimization

**When to use:** Hash join on large tables visible in EXPLAIN ANALYZE, high latency on multi-table queries, or cartesian product warnings.

---

## Join Types Reference

| Join Type | When Used | Cost |
|---|---|---|
| **Lookup Join** | One side small + other indexed | ✅ Fast |
| **Hash Join** | Neither indexed or both large | ⚠️ Expensive |
| **Merge Join** | Both sides sorted on join key | ✅ Good |
| **Cross Join** | Missing WHERE predicate | ❌ Catastrophic |

---

## Step 1: See the Join Type

```sql
EXPLAIN ANALYZE (DISTSQL) [your join query];
-- Look for: "hash join", "lookup join", "merge join", "cross join"
```

## Step 2: Understand Why the Optimizer Chose That Plan

```sql
EXPLAIN (OPT, VERBOSE) [your join query];
-- Shows cardinality estimates and join ordering logic
```

## Step 3: Find Expensive Join Queries

```sql
SELECT
    substring(key, 1, 80)                                            AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                           AS exec_count,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT, 4)    AS avg_lat_sec,
    ROUND((statistics->'statistics'->'rowsRead'->'mean')::FLOAT)     AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
  AND key ILIKE '%join%'
ORDER BY avg_lat_sec DESC
LIMIT 20;
```

## Step 4: Fix — Force Lookup Join (Testing Only)

```sql
SELECT o.*, c.name
FROM orders o
INNER LOOKUP JOIN customers c ON o.customer_id = c.id
WHERE o.status = 'PENDING';
-- CUSTOMIZE: replace table names, join condition, filter
-- Requires: right-hand table indexed on join key
```

## Step 5: Fix — Add Index to Enable Lookup Join

```sql
CREATE INDEX ON [right_table] ([join_key_column]);   -- CUSTOMIZE
```

## Step 6: Fix — Pre-filter Before Joining

```sql
SELECT *
FROM (SELECT * FROM orders WHERE status = 'PENDING' AND region = 'US') o
JOIN customers c ON o.customer_id = c.id;   -- CUSTOMIZE
```

## Step 7: Check for Accidental Cross Joins

```sql
EXPLAIN [your query];
-- "cross join" with large row estimates = missing predicate
-- Fix: ensure all tables have a JOIN condition or WHERE linking them
```

## Fix Summary

| Problem | Fix |
|---|---|
| Hash join, right table indexed | Use `INNER LOOKUP JOIN` hint for testing |
| Hash join, right table not indexed | Add index on join key column |
| Bad join order | Pre-filter with subquery |
| Cross join | Add missing ON or WHERE predicate |

## Customization Checklist
- [ ] Replace table names and join conditions with actual values
- [ ] Use LOOKUP JOIN hint for testing only — let optimizer decide in production
- [ ] Validate with EXPLAIN ANALYZE before and after changes
- [ ] Check cardinality estimates in EXPLAIN (OPT) — if off, refresh statistics
- [ ] Remove join hints after confirming optimizer makes right choice naturally
