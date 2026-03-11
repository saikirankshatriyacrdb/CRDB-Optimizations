# CRDB Query Tuning: Contention & Hot Ranges

**When to use:** Transaction retry storms, latency spikes under write load, or DB Console Hot Ranges shows imbalance.

---

## Step 1: View Live Contention Right Now

```sql
SELECT * FROM crdb_internal.cluster_locks
WHERE granted = false
ORDER BY txn_age DESC;
```

## Step 2: Historical Contention by Table/Index

```sql
-- CUSTOMIZE: INTERVAL lookback window
SELECT
    database_name, schema_name, table_name, index_name,
    COUNT(*)                            AS contention_events,
    SUM(contention_duration)            AS total_contention_duration,
    AVG(contention_duration)            AS avg_contention_duration
FROM crdb_internal.transaction_contention_events
WHERE collection_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
GROUP BY 1, 2, 3, 4
ORDER BY total_contention_duration DESC
LIMIT 20;
```

## Step 3: Find Waiting Transactions

```sql
SELECT
    waiting_stmt_id, collection_ts,
    contention_duration, contending_key, contending_txn_id
FROM crdb_internal.transaction_contention_events
WHERE collection_ts >= now() - INTERVAL '1 hour'   -- CUSTOMIZE
ORDER BY contention_duration DESC
LIMIT 20;
```

## Step 4: High Retry Rate Queries

```sql
SELECT
    substring(key, 1, 80)                                                AS fingerprint,
    (statistics->'statistics'->'cnt')::INT                               AS exec_count,
    (statistics->'statistics'->'maxRetries')::INT                        AS max_retries,
    ROUND(
        (statistics->'statistics'->'maxRetries')::FLOAT * 100.0
        / NULLIF((statistics->'statistics'->'cnt')::FLOAT, 0), 2
    )                                                                    AS retry_rate_pct
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'
  AND (statistics->'statistics'->'maxRetries')::INT > 0
ORDER BY retry_rate_pct DESC
LIMIT 20;
```

## Step 5: Find Hot Ranges

```sql
SELECT
    range_id, table_name, index_name,
    ROUND(queries_per_second::FLOAT, 2)        AS qps,
    ROUND(written_bytes_per_second::FLOAT, 0)  AS write_bytes_sec,
    lease_holder
FROM crdb_internal.ranges_no_leases
ORDER BY queries_per_second DESC
LIMIT 20;
```

## Step 6: Detect Monotonic PK Hotspots

```sql
SELECT table_name, column_name, column_default
FROM information_schema.columns
WHERE column_default LIKE '%nextval%'
   OR column_default LIKE '%unique_rowid%'
ORDER BY table_name;
```

## Fixes by Root Cause

| Root Cause | Fix |
|---|---|
| Monotonic PK (SERIAL) | UUID PKs or hash-sharded indexes |
| SELECT FOR UPDATE too broad | Narrow scope or optimistic concurrency |
| Hot counter rows | Distributed counters or batch updates |
| Long lock-holding transactions | Set `idle_in_transaction_session_timeout` |

### Fix: Hash-Sharded Index
```sql
-- CUSTOMIZE: BUCKET_COUNT (8-16 for high-write tables)
CREATE INDEX ON [table] ([col]) USING HASH WITH BUCKET_COUNT = 8;
```

### Fix: Transaction Timeout
```sql
SET CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout = '5m';  -- CUSTOMIZE
```

## Customization Checklist
- [ ] Adjust `INTERVAL` to match review cadence
- [ ] Set BUCKET_COUNT based on write concurrency
- [ ] Add `AND table_name = '[table]'` to scope to specific tables
- [ ] Alert threshold: retry rate > 2% = warning, > 5% = critical

## DB Console Shortcuts
- **DB Console → SQL Activity → Transactions → Sort by: Contention Time**
- **DB Console → Hot Ranges → View by: QPS or Written Bytes/sec**
- **DB Console → Metrics → SQL → Transaction Restarts**
