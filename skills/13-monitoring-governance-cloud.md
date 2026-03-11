# CRDB Monitoring & Governance: CockroachDB Cloud

**Framework:** OBSERVE → ALERT → REVIEW → ACT

> Key differences: Infrastructure managed by CRL. Use Metrics Export + Log Export for full observability. Storage does NOT auto-shrink. Basic tier is RU-based (not CPU-based).

---

## OBSERVE

### Cloud Console Navigation
```
Cloud Console → Metrics              CPU, storage, QPS, latency
Cloud Console → SQL Activity         Statements, transactions, sessions
Cloud Console → Insights             Auto-surfaced slow queries & contention
Cloud Console → Jobs                 Backup status (managed + self-managed)
Cloud Console → Hot Ranges           Write/read hotspot detection
Cloud Console → Databases            Table sizes, index usage, stats
```

### Metrics Export (Standard & Advanced only)
```
Cloud Console → Monitoring → Export Metrics →
  → Datadog          (native integration — recommended)
  → AWS CloudWatch
  → GCP Cloud Monitoring
  → Azure Monitor
  → Grafana Cloud (via Prometheus scrape endpoint)
```

### Log Export (Standard & Advanced only)
```
Cloud Console → Tools → Log Export →
  → AWS CloudWatch Logs
  → GCP Cloud Logging
  → Azure Log Analytics (via Event Hub)
```

### SQL Observability (All Tiers)
```sql
SELECT * FROM crdb_internal.statement_statistics;
SELECT * FROM crdb_internal.transaction_contention_events;
SELECT * FROM crdb_internal.cluster_queries;
SELECT * FROM crdb_internal.cluster_transactions;
SELECT * FROM crdb_internal.cluster_locks;
SELECT * FROM crdb_internal.index_usage_statistics;
```

---

## ALERT

### Infrastructure (via Metrics Export)
| Metric | Threshold | Tier |
|---|---|---|
| CPU utilization | > 70% | Standard / Advanced |
| Storage utilization | > 70% | Standard / Advanced |
| Block cache hit ratio | < 95% | Standard / Advanced |
| Request Units (RU) spike | > 2x baseline | Basic (Serverless) |
| Node liveness failure | Any | Standard / Advanced |
| CDC lag (`changefeed.max_behind_nanos`) | > SLA threshold | All |

### Database Health (SQL — All Tiers)
```sql
-- Under-replicated ranges
SELECT count(*) FROM crdb_internal.ranges
WHERE array_length(replicas, 1) < 3;   -- CUSTOMIZE: match your RF

-- Long running queries
SELECT count(*) FROM crdb_internal.cluster_queries
WHERE now() - start > INTERVAL '60 seconds';   -- CUSTOMIZE

-- Backup failure
SELECT count(*) FROM [SHOW JOBS]
WHERE job_type = 'BACKUP' AND status = 'failed'
  AND created >= now() - INTERVAL '24 hours';

-- No successful backup in 25h
SELECT CASE WHEN MAX(finished) < now() - INTERVAL '25 hours'
            THEN '⚠️ NO RECENT BACKUP' ELSE '✅ Backup OK' END AS status
FROM [SHOW JOBS] WHERE job_type = 'BACKUP' AND status = 'succeeded';

-- Transaction retry rate > 2%
SELECT ROUND(
    SUM((statistics->'statistics'->'maxRetries')::FLOAT) * 100.0
    / NULLIF(SUM((statistics->'statistics'->'cnt')::FLOAT), 0), 2
) AS retry_rate_pct
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '1 hour';
```

---

## REVIEW: Daily (15 min — All Tiers)

```
Cloud Console → Insights       Auto-surfaced slow queries & contention
Cloud Console → Jobs           Verify backup jobs succeeded overnight
Cloud Console → SQL Activity   Top queries by latency and rows read
```

```sql
-- Top 10 queries by total time (24h)
SELECT substring(key, 1, 80) AS fingerprint,
    (statistics->'statistics'->'cnt')::INT AS exec_count,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT, 4) AS avg_lat_sec,
    ROUND((statistics->'statistics'->'runLat'->'mean')::FLOAT
        * (statistics->'statistics'->'cnt')::INT, 2) AS total_time_sec
FROM crdb_internal.statement_statistics
WHERE aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
ORDER BY total_time_sec DESC LIMIT 10;
```

## REVIEW: Weekly (30 min)

```sql
-- Unused indexes
SELECT descriptor_name AS table_name, index_name, total_reads, last_read,
    CASE WHEN last_read IS NULL THEN 'NEVER READ'
         WHEN last_read < now() - INTERVAL '7 days' THEN 'STALE 7d+' END AS status
FROM crdb_internal.index_usage_statistics
WHERE index_name NOT LIKE '%primary%'
  AND (total_reads = 0 OR last_read < now() - INTERVAL '7 days')
ORDER BY descriptor_name;

-- Stale statistics
SELECT descriptor_name AS table_name, MAX(created) AS last_collected, now() - MAX(created) AS age
FROM crdb_internal.table_statistics
GROUP BY 1 HAVING MAX(created) < now() - INTERVAL '7 days'
ORDER BY last_collected ASC;
```

## REVIEW: Monthly (1 hour — Cloud-Specific)

| Item | Where to Look |
|---|---|
| Compute spend | Cloud Console → Billing |
| Storage spend | Cloud Console → Billing |
| Managed backup cost | Cloud Console → Billing (separate line item) |
| Self-managed backup cost | AWS Cost Explorer / GCS Billing / Azure Cost Mgmt |
| RU consumption trend (Basic) | Cloud Console → Metrics |
| Top 20 queries by CPU (30d) | `crdb_internal.statement_statistics` |
| Object storage lifecycle health | Verify lifecycle rules still applied |

## REVIEW: Quarterly (Half Day)

| Item | Action |
|---|---|
| Cluster right-sizing | Cloud Console → Edit Cluster (downsize if avg CPU < 30%) |
| Managed backup retention | Cloud Console → Backup Settings (shorten if over-retaining) |
| Reserved capacity renewal | Cloud Console → Billing (commit for discounts) |
| CRDB Cloud version upgrade | Cloud Console → Upgrade |
| Multi-region topology | Cloud Console → Regions |
| Compliance log retention | Verify Log Export destination retains per policy |

---

## ACT: Cloud-Specific Prioritized Actions

```
🟢 IMMEDIATE (same day)
   • Cancel blocking queries via Cloud Console or CANCEL QUERY
   • Refresh stale statistics: CREATE STATISTICS FROM [table]
   • Check Cloud Console → Insights for auto-surfaced issues
   • Verify backup jobs via Cloud Console → Jobs

🟡 SHORT TERM (this sprint)
   • Drop confirmed unused indexes
   • Add covering/partial indexes for top full-scan queries
   • Set up self-managed backup schedule to object storage
   • Shorten managed backup retention to 7 days
   • Enable Metrics Export → Datadog / CloudWatch / Cloud Monitoring
   • Enable Log Export for compliance / audit trail

🟠 MEDIUM TERM (this quarter)
   • Apply object storage lifecycle policies (tiered → archive → expire)
   • Implement Row-Level TTL on time-series / log tables
   • Enable locality-aware backups for multi-region
   • Hash-shard hot write ranges
   • Tune changefeed scope (emit only needed tables/columns)

🔵 STRATEGIC (quarterly / annual)
   • Right-size cluster via Cloud Console (after 30d review)
   • Renew reserved capacity for compute discounts
   • Upgrade CockroachDB Cloud version (free optimizer improvements)
   • Backup + restore to new cluster if storage bloat accumulated
   • Review multi-region topology vs traffic patterns
   • Audit compliance log retention at export destination
```

---

## Customization Checklist
- [ ] Set alert thresholds based on your SLA
- [ ] For Basic tier: alert on RU consumption, not CPU
- [ ] Adjust managed backup retention in Cloud Console (recommend 7 days)
- [ ] Wire Metrics Export to monitoring stack before going to production
- [ ] Enable Log Export on Standard/Advanced for compliance requirements
- [ ] Assign owners: Daily = on-call, Weekly = DBA, Monthly = Eng Lead, Quarterly = Architect
