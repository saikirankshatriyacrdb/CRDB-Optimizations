# CRDB Cost Optimization: Storage & Infrastructure

**When to use:** Monthly cost review, cluster right-sizing, or when storage is growing unbounded.

---

## 1. Right-Size Node CPU & Memory

```sql
-- Current per-node disk usage
SELECT
    node_id,
    ROUND(used_logical_bytes / 1073741824.0, 2)  AS disk_used_gb,
    ROUND(capacity_bytes / 1073741824.0, 2)       AS disk_total_gb,
    ROUND(used_logical_bytes * 100.0 / NULLIF(capacity_bytes, 0), 1) AS disk_pct
FROM crdb_internal.kv_store_status
ORDER BY disk_pct DESC;
```

### Right-Sizing Guidelines
| Avg CPU | Action |
|---|---|
| < 20% sustained | Downsize node or reduce count |
| 20–60% | ✅ Optimal range |
| 60–80% | Monitor — approaching threshold |
| > 80% sustained | Upsize or add nodes |

---

## 2. Find Largest Tables

```sql
SELECT
    table_name, schema_name,
    ROUND(total_bytes / 1073741824.0, 3)  AS total_gb,
    range_count
FROM crdb_internal.table_spans
ORDER BY total_bytes DESC NULLS LAST
LIMIT 20;
```

---

## 3. Row-Level TTL (Auto-Expire Old Data)

```sql
-- Check existing TTL tables
SELECT table_name, ttl_expiration_expression, ttl_job_cron
FROM [SHOW TABLES WITH TTL];

-- Add TTL to a table — CUSTOMIZE: table, column, retention, schedule
ALTER TABLE [table_name]
    SET (
        ttl_expiration_expression = '(([timestamp_col] AT TIME ZONE ''UTC'') + INTERVAL ''90 days'')',
        ttl_job_cron = '@daily',
        ttl_delete_batch_size = 100
    );
-- Example:
-- ALTER TABLE events SET (
--   ttl_expiration_expression = '((created_at AT TIME ZONE ''UTC'') + INTERVAL ''30 days'')',
--   ttl_job_cron = '@daily'
-- );
```

---

## 4. Follower Reads (Reduce Leaseholder Load)

```sql
-- For read-only queries where slight staleness is acceptable:
SELECT * FROM [table]
AS OF SYSTEM TIME follower_read_timestamp();   -- CUSTOMIZE: add your query

-- Bounded staleness (choose your window):
SELECT * FROM [table]
AS OF SYSTEM TIME with_max_staleness('10s');   -- CUSTOMIZE: staleness tolerance
```

---

## 5. Replication Factor Tuning

```sql
SHOW ZONE CONFIGURATION FOR TABLE [table_name];

-- CUSTOMIZE: 1 = non-prod, 3 = prod, 5 = critical
ALTER TABLE [table_name]
    CONFIGURE ZONE USING num_replicas = 3;

ALTER DATABASE [db_name]
    CONFIGURE ZONE USING num_replicas = 3;
```

---

## 6. GC TTL (MVCC Garbage Collection)

```sql
-- High GC TTL inflates storage with old MVCC row versions
-- Default: 14400s (4 hours) — lower for high-write tables
ALTER TABLE [table_name]
    CONFIGURE ZONE USING gc.ttlseconds = 7200;   -- CUSTOMIZE (min: 600s)
```

---

## 7. Connection Audit

```sql
-- Active statements (target: ≲ 4 per vCPU)
SELECT count(*) FROM crdb_internal.cluster_queries WHERE phase = 'executing';

-- Connections by application
SELECT application_name, count(*) AS connections
FROM crdb_internal.cluster_sessions
GROUP BY 1 ORDER BY 2 DESC;
```

---

## 8. Kill Long-Running Transactions

```sql
SELECT id, node_id, start, now() - start AS duration, num_stmts
FROM crdb_internal.cluster_transactions
WHERE now() - start > INTERVAL '5 minutes'   -- CUSTOMIZE
ORDER BY duration DESC;

-- Set idle transaction timeout:
SET CLUSTER SETTING sql.defaults.idle_in_transaction_session_timeout = '5m';  -- CUSTOMIZE
```

---

## Customization Checklist
- [ ] Set disk alert threshold (common: 70%)
- [ ] Choose TTL retention based on compliance / data lifecycle requirements
- [ ] Set follower read staleness based on application freshness needs
- [ ] Set `num_replicas`: 1 = dev, 3 = prod, 5 = critical
- [ ] Tune `gc.ttlseconds` based on MVCC history needs (min: 600s)
- [ ] Target active SQL connections ≲ 4 per vCPU via connection pooling
