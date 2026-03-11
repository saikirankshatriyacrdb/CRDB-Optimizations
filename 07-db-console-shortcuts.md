# DB Console Quick Reference

The CockroachDB DB Console (typically at `https://<node-ip>:8080`) provides visual dashboards and diagnostic tools that complement the SQL queries in this toolkit. This guide shows you where to find what you need.

## Shortcuts Table

| What You Want | Where to Find It | What to Look For |
|---|---|---|
| Slowest queries | SQL Activity > Statements > sort by **P99 Latency** | Queries with P99 > 1s are candidates for optimization |
| Full scan queries | SQL Activity > Statements > filter **Full Scan = Yes** | Any full scan on a table with > 1000 rows needs an index |
| CPU-heavy queries | SQL Activity > Statements > sort by **CPU Time** | Top entries are your biggest compute cost drivers |
| Transaction contention | SQL Activity > Transactions > sort by **Contention Time** | High contention = transactions waiting on each other |
| Auto-surfaced problems | **Insights** > Statement Insights / Transaction Insights | CockroachDB automatically detects slow queries, contention, and failed plans |
| Hot ranges | **Hot Ranges** (top-level navigation) | Ranges with disproportionately high QPS are hotspots |
| Node CPU and disk | Metrics > **Hardware** | CPU should be 20-60% avg, disk I/O should not be saturated |
| Node memory | Metrics > **Hardware** > Memory | Watch for OOM risk if memory usage approaches node limit |
| Index recommendations | Databases > [Database] > [Table] > **Indexes** | Console suggests missing indexes based on query patterns |
| Range distribution | Metrics > **Replication** | All nodes should have roughly equal range counts |
| Network latency | Metrics > **Network** | Cross-region latency affects multi-region cost decisions |
| Changefeed lag | Metrics > **Changefeeds** | High lag may indicate the cluster is undersized for CDC load |
| Backup status | Jobs (top-level navigation) > filter by BACKUP | All recent backups should show status "succeeded" |
| Cluster version | Cluster Settings (Advanced Debug) | All nodes should be on the same version |

## Key Dashboards and What to Look For

### SQL Activity > Statements

This is the most important dashboard for cost optimization.

- **Sort by CPU Time**: reveals queries consuming the most compute.
- **Sort by Rows Read**: reveals queries scanning the most data.
- **Filter by Full Scan = Yes**: reveals queries missing indexes.
- **Sort by Contention Time**: reveals queries causing lock waits.
- Click on any statement fingerprint to see:
  - Execution plan (EXPLAIN)
  - Execution statistics (rows read vs. returned, latency breakdown)
  - Index recommendations

### Insights

The Insights page automatically surfaces optimization opportunities:

- **High Retry Count**: transactions that are frequently retried due to contention.
- **Slow Execution**: queries exceeding expected latency.
- **Failed Execution**: queries that are failing (check for schema issues).
- **Suboptimal Plan**: the optimizer chose a plan that may not be ideal.
- **Index Recommendation**: a missing index that would improve a specific query.

### Hot Ranges

Shows ranges receiving disproportionately high traffic.

- Ranges with QPS much higher than the average are hotspots.
- Click on a range to see the table, index, and key range involved.
- Common fixes: hash-sharded indexes, UUID primary keys, schema redesign.

### Metrics > Hardware

- **CPU**: sustained average above 70% indicates the cluster may be undersized.
- **CPU**: sustained average below 20% indicates the cluster may be oversized.
- **Disk I/O**: high disk utilization with low CPU may indicate insufficient cache.
- **Memory**: usage near the node limit risks OOM kills.

### Metrics > Replication

- **Under-Replicated Ranges**: should be 0. Non-zero means data is at risk.
- **Unavailable Ranges**: should be 0. Non-zero means queries are failing.
- **Range Count per Node**: should be roughly equal across nodes.

## Recommended Tuning Workflow

Use this step-by-step workflow to systematically identify and fix cost issues:

```
Step 1: DB Console > Insights
        Grab the top offending statement/transaction fingerprints.
        These are problems CockroachDB has already identified for you.

Step 2: SQL Activity > Statements > Sort by CPU Time
        Identify the top 10-20 queries by CPU consumption.
        Cross-reference with crdb_internal.statement_statistics.

Step 3: EXPLAIN ANALYZE (DISTSQL) on top offenders
        Run each problematic query with EXPLAIN ANALYZE to see:
        - Actual rows vs. estimated rows
        - Where time is spent (network, CPU, disk)
        - Join types (hash join vs. lookup join)

Step 4: EXPLAIN (OPT, VERBOSE) on queries with bad plans
        Understand WHY the optimizer chose a particular plan.
        Check for stale statistics or bad cardinality estimates.

Step 5: Apply fixes
        - Add missing indexes (covering, partial, expression)
        - Rewrite queries (eliminate SELECT *, add predicates)
        - Fix schema issues (hash-sharded PKs, column families)

Step 6: Re-run EXPLAIN ANALYZE to verify improvement
        Confirm the new plan is better before declaring victory.

Step 7: Monitor crdb_internal.index_usage_statistics
        Confirm new indexes are being used.
        Check that old unused indexes can be dropped.
```

## Useful DB Console URLs

Replace `<host>` with your node IP or hostname:

| Page | URL |
|---|---|
| Overview | `https://<host>:8080/#/overview/list` |
| SQL Activity | `https://<host>:8080/#/sql-activity` |
| Insights | `https://<host>:8080/#/insights` |
| Hot Ranges | `https://<host>:8080/#/hotranges` |
| Databases | `https://<host>:8080/#/databases` |
| Jobs | `https://<host>:8080/#/jobs` |
| Metrics | `https://<host>:8080/#/metrics/overview/cluster` |
| Advanced Debug | `https://<host>:8080/#/reports` |
