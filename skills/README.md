# CockroachDB Optimization Skills Library

A modular, customer-customizable playbook library for CockroachDB query tuning, cost optimization, and monitoring & governance.

Each skill is self-contained and independently usable. Customers can pick the skills relevant to their workload and customize the placeholders for their environment.

---

## 📁 Skill Index

### 🔍 Query Tuning

| File | What It Covers |
|---|---|
| [01-query-tuning-full-scans.md](01-query-tuning-full-scans.md) | Find and fix full table scan queries |
| [02-query-tuning-unused-indexes.md](02-query-tuning-unused-indexes.md) | Audit and drop unused indexes |
| [03-query-tuning-cpu-latency.md](03-query-tuning-cpu-latency.md) | Top CPU and latency heavy queries |
| [04-query-tuning-contention-hot-ranges.md](04-query-tuning-contention-hot-ranges.md) | Lock contention and hot range detection |
| [05-query-tuning-rows-read-ratio.md](05-query-tuning-rows-read-ratio.md) | Rows read vs returned ratio & covering indexes |
| [06-query-tuning-join-optimization.md](06-query-tuning-join-optimization.md) | Hash vs lookup join optimization |
| [07-query-tuning-statistics-planner.md](07-query-tuning-statistics-planner.md) | Stale statistics and query planner issues |
| [08-query-tuning-schema-antipatterns.md](08-query-tuning-schema-antipatterns.md) | OFFSET pagination, SELECT *, hot PKs, wide UPDATEs |

### 💰 Cost Optimization

| File | What It Covers |
|---|---|
| [09-cost-optimization-storage.md](09-cost-optimization-storage.md) | Right-sizing, TTL, follower reads, GC tuning |
| [10-cost-optimization-backups-selfhosted.md](10-cost-optimization-backups-selfhosted.md) | Backup strategy for self-hosted (S3/GCS/Azure/MinIO) |
| [11-cost-optimization-backups-cloud.md](11-cost-optimization-backups-cloud.md) | Backup strategy for CockroachDB Cloud |

### 📡 Monitoring & Governance

| File | What It Covers |
|---|---|
| [12-monitoring-governance-selfhosted.md](12-monitoring-governance-selfhosted.md) | Observe → Alert → Review → Act for self-hosted |
| [13-monitoring-governance-cloud.md](13-monitoring-governance-cloud.md) | Observe → Alert → Review → Act for CockroachDB Cloud |

---

## 🔧 How to Use These Skills

### Customization Placeholders
All skills use consistent placeholder conventions:
- `[table_name]` — Replace with your actual table name
- `[db_name]` — Replace with your database name
- `[column]` / `[filter_column]` — Replace with column names
- `[bucket]` / `[path]` — Replace with your object storage details
- `INTERVAL '24 hours'` — Change to your desired time window
- `LIMIT 20` — Adjust for your query volume
- `[your_app]` — Replace with your application name

### Recommended Starting Points

**New customer performance review:**
1. Start with `03-query-tuning-cpu-latency.md` → find top offenders
2. Cross-reference with `01-query-tuning-full-scans.md` → identify missing indexes
3. Check `02-query-tuning-unused-indexes.md` → drop index dead weight

**Storage cost concern:**
1. Start with `09-cost-optimization-storage.md` → right-size + TTL
2. Then `10-cost-optimization-backups-selfhosted.md` or `11-cost-optimization-backups-cloud.md`

**Governance / QBR prep:**
1. Use `12-monitoring-governance-selfhosted.md` or `13-monitoring-governance-cloud.md`
2. Pull the monthly review queries and bring results to the QBR

---

## ☁️ Cloud Provider Coverage

All skills are cloud-agnostic. Object storage references cover:

| Provider | Storage | Auth |
|---|---|---|
| AWS | S3 | IAM Role (implicit) or Access Keys (specified) |
| GCP | Cloud Storage (GCS) | Service Account (implicit) or JSON key (specified) |
| Azure | Blob Storage | Account Key or SAS (specified) |
| Self-hosted | MinIO / Ceph / NetApp | S3-compatible endpoint |
| NFS | Nodelocal | Direct path |

---

## 🔄 Governance Cadence Summary

| Cadence | Time | Key Actions |
|---|---|---|
| **Daily** | 15 min | Insights review, backup check, contention hotspots |
| **Weekly** | 30 min | Index audit, stale stats, storage growth |
| **Monthly** | 1 hour | Cost review, top CPU queries (30d), backup costs |
| **Quarterly** | Half day | Right-sizing, version upgrade, retention policy, topology |

---

## 📚 Related Resources
- [CockroachDB Docs — Query Tuning](https://www.cockroachlabs.com/docs/stable/make-queries-fast.html)
- [CockroachDB Docs — Backup & Restore](https://www.cockroachlabs.com/docs/stable/backup-and-restore-overview.html)
- [CockroachDB Cloud — Monitoring](https://www.cockroachlabs.com/docs/cockroachcloud/monitoring-page.html)
- [DB Console Guide](https://www.cockroachlabs.com/docs/stable/ui-overview.html)
