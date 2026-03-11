# CRDB Monitoring & Governance: Self-Hosted

**Framework:** OBSERVE → ALERT → REVIEW → ACT

---

## OBSERVE

```
DB Console dashboards              crdb_internal.statement_statistics
Prometheus (/_status/vars)         crdb_internal.transaction_contention_events
DB Console → Insights              DB Console → Hot Ranges
Grafana (any backend)              changefeed.max_behind_nanos (Prometheus)
  AWS: CloudWatch                  Object storage bucket size metrics
  GCP: Cloud Monitoring            Backup job status (SHOW JOBS)
  Azure: Azure Monitor
  Self-hosted: Prometheus + Grafana
```

---

## ALERT

### Infrastructure (Prometheus / Grafana / Datadog / CloudWatch)
| Metric | Threshold | Severity |
|---|---|---|
| CPU utilization | > 70% | Warning |
| Storage utilization | > 70% | Warning |
| Block cache hit ratio | < 95% | Warning |
| Open file descriptors | > 80% ulimit | Critical |
| Node liveness failure | Any | Critical |

### Database Health (SQL — CUSTOMIZE thresholds)

```sql
-- Under-replicated ranges > 0
SELECT count(*) FROM crdb_internal.ranges
WHERE array_length(replicas, 1) < 3;   -- CUSTOMIZE: match your RF

-- Long running queries
SELECT count(*) FROM crdb_internal.cluster_queries
WHERE now() - start > INTERVAL '60 seconds';   -- CUSTOMIZE

-- Long running transactions
SELECT count(*) FROM crdb_internal.cluster_transactions
WHERE now() - start > INTERVAL '5 minutes';    -- CUSTOMIZE

-- Transaction retry rate > 2%
SELECT ROUND(
    SUM((statistics->'statistics'->'maxRetries')::FLOAT) * 100.0
    / NULLIF(SUM((statistics->'statistics'->'cnt')::FLOAT), 0), 2
) AS retry_rate_pct
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '1 hour';

-- Backup failure in last 24h
SELECT count(*) FROM [SHOW JOBS]
WHERE job_type = 'BACKUP' AND status = 'failed'
  AND created >= now() - INTERVAL '24 hours';
```

---

## REVIEW: Daily (15 min)

```sql
-- Top 10 slowest queries (24h)
SELECT
    substring(key, 1, 80) AS fingerprint,
    (statistics->'statistics'->'cnt')::INT AS exec_count,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT, 4) AS avg_lat_sec,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT
        * (statistics->'statistics'->'cnt')::INT, 2) AS total_time_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
ORDER BY total_time_sec DESC LIMIT 10;

-- New full scans (24h)
SELECT substring(key, 1, 80) AS fingerprint,
    (statistics->'statistics'->'cnt')::INT AS exec_count,
    ROUND((statistics->'statistics'->'rowsRead'->'mean')::FLOAT) AS avg_rows_read
FROM crdb_internal.statement_statistics
WHERE statistics->'statistics'->>'fullScans' = 'true'
  AND aggregated_ts >= now() - INTERVAL '24 hours'
ORDER BY avg_rows_read DESC;

-- Contention hotspots (24h)
SELECT table_name, index_name, COUNT(*) AS events, SUM(contention_duration) AS total
FROM crdb_internal.transaction_contention_events
WHERE collection_ts >= now() - INTERVAL '24 hours'
GROUP BY 1, 2 ORDER BY total DESC LIMIT 10;
```

## REVIEW: Weekly (30 min)

```sql
-- Unused indexes
SELECT descriptor_name AS table_name, index_name, total_reads, last_read,
    CASE WHEN last_read IS NULL THEN 'NEVER READ'
         WHEN last_read < now() - INTERVAL '7 days' THEN 'STALE 7d+' END AS status
FROM crdb_internal.index_usage_statistics
WHERE index_name NOT LIKE '%primary%'
  AND (total_reads = 0 OR last_read < now() - INTERVAL '7 days')   -- CUSTOMIZE
ORDER BY descriptor_name;

-- Stale statistics
SELECT descriptor_name AS table_name, MAX(created) AS last_collected, now() - MAX(created) AS age
FROM crdb_internal.table_statistics
GROUP BY 1 HAVING MAX(created) < now() - INTERVAL '7 days'
ORDER BY last_collected ASC;

-- Storage growth per node
SELECT node_id,
    ROUND(used_logical_bytes / 1073741824.0, 2) AS used_gb,
    ROUND(capacity_bytes / 1073741824.0, 2) AS total_gb,
    ROUND(used_logical_bytes * 100.0 / NULLIF(capacity_bytes, 0), 1) AS pct_used
FROM crdb_internal.kv_store_status ORDER BY pct_used DESC;
```

## REVIEW: Monthly (1 hour)

```sql
-- Top 20 most expensive queries (30 days)
SELECT substring(key, 1, 80) AS fingerprint,
    (statistics->'statistics'->'cnt')::INT AS exec_count,
    ROUND(((statistics->'statistics'->'cpuSQLNanos'->'mean')::FLOAT / 1e9)
        * (statistics->'statistics'->'cnt')::INT, 2) AS total_cpu_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '30 days'
ORDER BY total_cpu_sec DESC LIMIT 20;
```

---

## ACT: Prioritized Action Plan

```
🟢 IMMEDIATE (same day)
   • Cancel blocking queries / long transactions
   • Refresh stale statistics on hot tables
   • Investigate & resolve under-replicated ranges
   • Verify backup jobs completed successfully

🟡 SHORT TERM (this sprint)
   • Drop confirmed unused indexes
   • Add covering/partial indexes for top full-scan queries
   • Enable follower reads on read-only reporting paths
   • Set idle_in_transaction_session_timeout

🟠 MEDIUM TERM (this quarter)
   • Hash-shard hot monotonic PKs / write hotspots
   • Implement Row-Level TTL on time-series tables
   • Restructure backup → tiered object storage lifecycle
   • Right-size nodes based on 30-day CPU/disk trend

🔵 STRATEGIC (quarterly / annual)
   • Offload analytics to warehouse
   • CockroachDB version upgrade (free optimizer improvements)
   • Multi-region topology review
   • Backup retention policy vs compliance review
```

---

## Customization Checklist
- [ ] Set alert thresholds based on your SLA
- [ ] Adjust replication factor check (default 3 — change if using RF=5)
- [ ] Change INTERVAL windows to match review cadence
- [ ] Wire SQL alert queries into monitoring tool (Datadog, Grafana, CloudWatch)
- [ ] Assign owners: Daily = on-call, Weekly = DBA, Monthly = Eng Lead, Quarterly = Architect
