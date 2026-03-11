# CRDB Query Tuning: CPU & Latency Heavy Queries

**When to use:** High cluster CPU, latency spikes, or as part of regular performance reviews.

> Key insight: A query running 1000x/hour at 10ms is MORE expensive than one running 1x/day at 5s. Always sort by TOTAL impact.

---

## Step 1: Top Queries by Total Execution Time

```sql
-- CUSTOMIZE: INTERVAL and LIMIT
SELECT
    substring(key, 1, 80)                                            AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                           AS exec_count,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT, 4)    AS avg_lat_sec,
    ROUND(
        (statistics->'statistics'->'runLat'->'mean')::FLOAT
        * (statistics->'statistics'->'cnt')::INT, 2
    )                                                                AS total_time_sec,
    ROUND((statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9, 4) AS avg_cpu_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
ORDER BY total_time_sec DESC
LIMIT 20;
```

## Step 2: Top Queries by Total CPU

```sql
SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    ROUND((statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9, 4)    AS avg_cpu_sec,
    ROUND(
        ((statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9)
        * (statistics->'statistics'->'cnt')::INT, 2
    )                                                                    AS total_cpu_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY total_cpu_sec DESC
LIMIT 20;
```

## Step 3: P99 Latency Outliers

```sql
SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT, 4)        AS avg_lat_sec,
    ROUND((statistics->'statistics'->'runLat'->'max')::FLOAT, 4)         AS max_lat_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'
  AND (statistics->'statistics'->'runLat'->'mean')::FLOAT > 0.1   -- CUSTOMIZE: seconds
ORDER BY max_lat_sec DESC
LIMIT 20;
```

## Step 4: Deep Dive on a Specific Query

```sql
-- Actual execution plan with timing
EXPLAIN ANALYZE (DISTSQL) [your query];

-- Optimizer reasoning
EXPLAIN (OPT, VERBOSE) [your query];
```

## Common Fixes

| Root Cause | Fix |
|---|---|
| Full table scan | Add index on filter column |
| Hash join on large tables | Add index → enables lookup join |
| Expensive per-row functions | Expression index or pre-compute |
| High rows read vs returned | Partial or covering index |
| Stale statistics → bad plan | `CREATE STATISTICS` on hot tables |

## Customization Checklist
- [ ] Change `INTERVAL` to your review window (hourly, daily, weekly)
- [ ] Add `AND application_name = '[app]'` to filter by application
- [ ] Adjust latency threshold in P99 query (default: 0.1s = 100ms)
- [ ] Use `EXPLAIN ANALYZE (DISTSQL)` for top 3 offenders each review cycle

## DB Console Shortcut
**DB Console → SQL Activity → Statements → Sort by: CPU Time or P99 Latency**
