# CockroachDB Cost Optimization Toolkit

A collection of diagnostic SQL queries and best-practice guides for identifying cost optimization opportunities in CockroachDB clusters (self-hosted and CockroachDB Cloud).

## What This Toolkit Does

This toolkit helps you systematically find and fix the most common sources of waste in a CockroachDB deployment:

- **Over-provisioned compute** -- queries burning excessive CPU or doing unnecessary work
- **Storage bloat** -- unused indexes, missing TTLs, MVCC garbage accumulation
- **Backup cost overruns** -- retention windows that are too wide, missing S3 lifecycle policies
- **Query inefficiency** -- full table scans, read amplification, contention hotspots
- **Misconfigured tuning parameters** -- cache, memory, admission control, and range settings

## Prerequisites

- **CockroachDB cluster access** with `admin` privileges (most queries read from `crdb_internal` tables)
- **SQL client**: `cockroach sql`, DBeaver, DataGrip, or any PostgreSQL-compatible client
- CockroachDB **v22.2 or later** recommended (some `crdb_internal` views may differ on older versions)
- Access to the **DB Console** (typically at `https://<node-ip>:8080`)

## Files in This Toolkit

| File | Purpose |
|------|---------|
| `01-cluster-health.sql` | Node status, range distribution, version checks |
| `02-query-performance.sql` | CPU-heavy queries, full scans, read amplification, contention, hot ranges |
| `03-index-optimization.sql` | Unused indexes, over-indexed tables, covering index candidates, hot keys |
| `04-storage-optimization.sql` | Table sizes, TTL configuration, MVCC GC tuning |
| `05-backup-optimization.sql` | Scheduled backup examples, job monitoring, S3 lifecycle recommendations |
| `06-tuning-settings.sql` | Cache, memory, auto-stats, admission control, range splitting |
| `07-db-console-shortcuts.md` | DB Console quick reference and recommended tuning workflow |
| `08-connection-pooling.md` | Connection pooling best practices and sizing formulas |

## How to Use

### Quick Start

1. Connect to your CockroachDB cluster:
   ```bash
   cockroach sql --url "postgresql://root@<host>:26257/defaultdb?sslmode=verify-full&sslcert=..."
   ```

2. Run the files in order. Each file is self-contained and copy-paste ready:
   ```bash
   cockroach sql --url "..." < 01-cluster-health.sql
   ```

3. Review the output against the interpretation guidelines in each file's comments.

### Recommended Workflow

1. **Start with cluster health** (`01`) -- confirm all nodes are live and balanced.
2. **Identify expensive queries** (`02`) -- find the top CPU consumers and full scans.
3. **Audit indexes** (`03`) -- drop unused indexes, add missing covering indexes.
4. **Check storage** (`04`) -- look for tables that need TTLs or GC tuning.
5. **Review backups** (`05`) -- ensure backup schedules are cost-efficient.
6. **Tune cluster settings** (`06`) -- apply performance tuning where appropriate.
7. **Use DB Console** (`07`) -- for visual confirmation and ongoing monitoring.
8. **Validate connection pooling** (`08`) -- ensure the application tier is not wasting connections.

### Repeat Monthly

Establish a recurring cadence:
- **Monthly**: review top queries by CPU, check for new unused indexes, validate backup costs.
- **Quarterly**: revisit node sizing, backup retention, and schema/index changes.

## Important Notes

- All queries in this toolkit are **read-only** unless explicitly marked otherwise (e.g., `DROP INDEX`, `SET CLUSTER SETTING`).
- Queries that modify the cluster are clearly labeled with `-- ACTION:` comments. Review them before executing.
- Time windows in queries default to the last **1 hour** or **24 hours**. Adjust the `INTERVAL` values to match your needs.
- Some queries return large result sets. Use `LIMIT` to keep output manageable.

## Documentation References

- [CockroachDB Performance Tuning](https://www.cockroachlabs.com/docs/stable/performance-best-practices-overview)
- [Backup and Restore Overview](https://www.cockroachlabs.com/docs/stable/backup-and-restore-overview)
- [Cluster Settings](https://www.cockroachlabs.com/docs/stable/cluster-settings)
- [DB Console Overview](https://www.cockroachlabs.com/docs/stable/ui-overview)

## License

Internal use. Adapt and share with customers as needed.
