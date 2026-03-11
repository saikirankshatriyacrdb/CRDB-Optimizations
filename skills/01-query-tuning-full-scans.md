# CRDB Query Tuning: Full Scans

**When to use:** Customer reports slow queries, high rows-read counts, or DB Console → Insights → Full Scan filter shows hits.

---

## Step 1: Find Full Scan Queries

```sql
-- CUSTOMIZE: change INTERVAL and LIMIT as needed
SELECT
    substring(key, 1, 80)                                    AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                   AS exec_count,
    (statistics->'statistics'->'rowsRead'->'mean')::FLOAT    AS avg_rows_read,
    (statistics->'statistics'->'bytesRead'->'mean')::FLOAT   AS avg_bytes_read,
    (statistics->'statistics'->'runLat'->'mean')::FLOAT      AS avg_latency_sec
FROM crdb_internal.statement_statistics
WHERE statistics->'statistics'->>'fullScans' = 'true'
  AND aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE: '1 hour', '7 days'
ORDER BY avg_rows_read DESC
LIMIT 20;                                             -- CUSTOMIZE
```

## Step 2: Confirm the Plan with EXPLAIN

```sql
EXPLAIN (VERBOSE) SELECT * FROM [table] WHERE [condition];
-- Good: spans: [/'value' - /'value'/PrefixEnd]
-- Bad:  spans: FULL SCAN
```

## Step 3: Get Real Execution Data

```sql
EXPLAIN ANALYZE (DISTSQL) SELECT * FROM [table] WHERE [condition];
-- Check: estimated rows vs actual rows, time per operator
```

## Step 4: Fix Options

### Option A — Simple index
```sql
CREATE INDEX ON [table] ([filter_column]);
```

### Option B — Partial index (for skewed predicates)
```sql
CREATE INDEX ON [table] ([filter_column]) WHERE [filter_column] = '[value]';
-- Example: CREATE INDEX ON orders (status) WHERE status = 'PENDING';
```

### Option C — Covering index (avoids KV round-trip)
```sql
CREATE INDEX ON [table] ([filter_column]) STORING ([col1], [col2]);
```

### Option D — Expression index (for function-wrapped predicates)
```sql
-- If query uses: WHERE lower(email) = 'foo@bar.com'
CREATE INDEX ON [table] (lower([column]));
```

## Customization Checklist
- [ ] Change `INTERVAL '24 hours'` to your lookback window
- [ ] Add `AND application_name = '[your_app]'` to filter by app
- [ ] Replace `[table]`, `[column]`, `[condition]` with actual values
- [ ] Re-run EXPLAIN ANALYZE after adding index to verify improvement
- [ ] Monitor `crdb_internal.index_usage_statistics` to confirm new index is used

## DB Console Shortcut
**DB Console → SQL Activity → Statements → Filter: Full Scan = Yes → Sort by Rows Read**
