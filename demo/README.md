# CockroachDB Cost Optimization Workshop - Demo Dataset

This directory contains a self-contained demo dataset for the CockroachDB Cost Optimization Workshop. Use it when customers prefer not to run diagnostic queries against their own production workloads. The presenter can spin up this demo dataset and showcase all optimization scenarios in a controlled environment.

---

## Prerequisites

- A running CockroachDB cluster (single-node or multi-node)
  - Recommended: CockroachDB v23.1 or later
  - A 3-node cluster is ideal for demonstrating hot ranges and contention
  - Single-node (`cockroach demo` or `cockroach start-single-node`) works for most diagnostics
- The `cockroach sql` shell or any compatible SQL client (DBeaver, psql, etc.)
- At least **2 GB of free disk space** for the demo data
- For the contention demo (Step 3): **3-4 separate terminal windows**

---

## Quick Start

```bash
# Connect to your CockroachDB cluster
cockroach sql --url="postgresql://root@localhost:26257?sslmode=disable"

# Run scripts in order (from the SQL shell):
\i 00-setup-schema.sql
\i 01-create-bad-indexes.sql
\i 02-bad-queries.sql
\i 03-generate-contention.sql
\i 04-generate-hotspots.sql
\i 05-run-diagnostics.sql

# Clean up when done:
\i 99-cleanup.sql
```

Or from the command line:

```bash
CRDB_URL="postgresql://root@localhost:26257/defaultdb?sslmode=disable"

cockroach sql --url="$CRDB_URL" < 00-setup-schema.sql
cockroach sql --url="$CRDB_URL" < 01-create-bad-indexes.sql
cockroach sql --url="$CRDB_URL" < 02-bad-queries.sql
cockroach sql --url="$CRDB_URL" < 03-generate-contention.sql
cockroach sql --url="$CRDB_URL" < 04-generate-hotspots.sql
cockroach sql --url="$CRDB_URL" < 05-run-diagnostics.sql
```

---

## Step-by-Step Walkthrough

### Step 0: Schema Setup and Data Population

**Script:** `00-setup-schema.sql`
**Time:** 15-25 minutes

Creates the `cost_optimization_demo` database with 8 tables and populates them with synthetic data:

| Table | Rows | Purpose |
|-------|------|---------|
| `users` | ~50K | Customer accounts |
| `products` | ~10K | Product catalog |
| `orders` | ~500K | Customer orders |
| `order_items` | ~2M | Order line items |
| `audit_logs` | ~1M | User activity logs (TTL candidate) |
| `sessions` | ~200K | User sessions (TTL candidate) |
| `payments` | ~500K | Payment records (monotonic PK for hotspot demo) |
| `inventory_movements` | ~1M | Stock changes |

**What to tell the audience:** "We are setting up a realistic e-commerce dataset with several million rows across 8 tables. This is representative of a mid-size production workload."

**Progress indicators:** The script prints batch completion messages. The largest table (`order_items`, 2M rows) inserts in 40 batches of 50K.

---

### Step 1: Create Intentionally Bad Indexes

**Script:** `01-create-bad-indexes.sql`
**Time:** 3-5 minutes

Creates indexes that represent common optimization opportunities:

- **6 unused indexes** that no query in the demo workload ever reads
- **9 total indexes on the `orders` table** (over-indexed for a 6-column table)
- **1 redundant index** (`user_id` alone when `user_id, created_at` composite exists)
- **2 wide covering indexes** with unnecessary `STORING` clauses
- **1 partial duplicate** on `products`

**What to tell the audience:** "In many production databases, indexes accumulate over time. Developers add indexes for specific queries, but never remove them when queries change. Let us see what that looks like."

---

### Step 2: Execute Bad Queries

**Script:** `02-bad-queries.sql`
**Time:** 5-10 minutes

Runs queries that demonstrate 10 common anti-patterns:

| # | Anti-Pattern | What It Demonstrates |
|---|---|---|
| 1 | Full table scan | WHERE on non-indexed column |
| 2 | SELECT * | Fetching all columns from a large join |
| 3 | High read-to-return ratio | JSONB filter scanning 1M rows for 10 results |
| 4 | Missing index sort | ORDER BY on non-indexed column |
| 5 | Cross join | Missing JOIN condition (cartesian product) |
| 6 | Leading wildcard LIKE | `WHERE email LIKE '%@gmail.com'` |
| 7 | Implicit type conversion | Comparing INT column to STRING |
| 8 | Large OFFSET pagination | `OFFSET 100000 LIMIT 10` |
| 9 | N+1 query pattern | 20 individual queries instead of one JOIN |
| 10 | Unnecessary DISTINCT | DISTINCT on unique PK column |

**What to tell the audience:** "These queries represent patterns we see constantly in production workloads. Each one wastes compute resources in a different way. After running them, we will use diagnostic queries to identify them systematically."

---

### Step 3: Generate Lock Contention

**Script:** `03-generate-contention.sql`
**Time:** 2-3 minutes

For the full contention demo, open **3-4 separate terminal windows** and run the Session blocks simultaneously. The script includes:

- A `contention_demo` table with 5 rows as contention targets
- Multi-session transaction blocks with `pg_sleep` delays to hold locks
- A single-shell fallback version that generates contention sequentially

**What to tell the audience:** "Lock contention is one of the most common performance problems in production. It happens when multiple application instances try to update the same rows at the same time. Let us simulate that."

**Multi-session instructions:**
1. Open 3 terminal windows, each connected to the same CockroachDB cluster
2. From the main shell, run the setup portion (CREATE TABLE, INSERT)
3. Copy-paste the `SESSION 1` block into Terminal 1
4. Copy-paste the `SESSION 2` block into Terminal 2
5. Copy-paste the `SESSION 3` block into Terminal 3
6. Execute all three at roughly the same time

---

### Step 4: Generate Write Hotspots

**Script:** `04-generate-hotspots.sql`
**Time:** 3-5 minutes

Demonstrates two hotspot patterns:

1. **Monotonic PK inserts:** Rapidly inserts 50K rows into the `payments` table (which uses `unique_rowid()` as PK). All inserts go to the same range.
2. **Hot row updates:** Repeatedly updates the same counter row in `global_counters`, simulating a running-total pattern.

Also creates a `payments_fixed` table with UUID PKs for comparison.

**What to tell the audience:** "Monotonic primary keys are one of the most common causes of write hotspots in CockroachDB. All new data goes to the last range, creating a bottleneck on one node. Let us see the difference between monotonic and UUID-based keys."

**What to show in DB Console:**
- Hot Ranges page
- Replication dashboard (QPS per range)
- Compare range distribution between `payments` (skewed) and `payments_fixed` (even)

---

### Step 5: Run Diagnostic Queries

**Script:** `05-run-diagnostics.sql`
**Time:** 10-15 minutes (with discussion)

This is the main diagnostic portion of the workshop. Run each diagnostic one at a time and discuss results:

| # | Diagnostic | What It Finds |
|---|---|---|
| 1 | Full table scans | Queries without usable indexes |
| 2 | Unused indexes | Indexes with zero reads |
| 3 | CPU-heavy queries | Statements with highest cumulative latency |
| 4 | Rows read vs returned | Queries with 1000:1+ read-to-return ratios |
| 5 | Contention events | Lock contention between transactions |
| 6 | Hot ranges | Uneven range distribution |
| 7 | Stale statistics | Outdated optimizer statistics |
| 8 | Over-indexed tables | Tables with too many indexes |
| 9 | Redundant indexes | Indexes that are prefixes of other indexes |
| 10 | TTL candidates | Tables with old data that should expire |
| 11 | Storage usage | Disk consumption by table |

**What to tell the audience:** "These diagnostic queries are the same ones you would run against your own production cluster. They identify the low-hanging fruit for cost optimization -- the changes that give you the biggest savings with the least risk."

---

### Cleanup

**Script:** `99-cleanup.sql`
**Time:** < 1 minute

Drops the entire `cost_optimization_demo` database and all its contents. Run this after the workshop is complete.

```sql
\i 99-cleanup.sql
```

---

## Timing Summary

| Step | Script | Duration |
|------|--------|----------|
| 0 | `00-setup-schema.sql` | 15-25 min |
| 1 | `01-create-bad-indexes.sql` | 3-5 min |
| 2 | `02-bad-queries.sql` | 5-10 min |
| 3 | `03-generate-contention.sql` | 2-3 min |
| 4 | `04-generate-hotspots.sql` | 3-5 min |
| 5 | `05-run-diagnostics.sql` | 10-15 min |
| -- | `99-cleanup.sql` | < 1 min |
| **Total** | | **40-65 min** |

**Tip:** If you are short on time, you can skip Steps 3 and 4 (contention and hotspots) and focus on the index and query diagnostics. The most impactful diagnostics are Steps 1, 2, and 5.

---

## Presenter Tips

1. **Pre-load the data before the workshop.** Run Steps 0-4 ahead of time so the audience does not have to wait 20 minutes for data to load. Then walk through the diagnostic queries (Step 5) live.

2. **Have the DB Console open.** Many findings are easier to show visually in the Statements page, Hot Ranges page, and Insights tab.

3. **Connect the diagnostics to cost.** After each finding, explain the cost implication:
   - Unused indexes = wasted storage + slower writes
   - Full table scans = wasted CPU + higher latency
   - Hot ranges = underutilized cluster capacity
   - Stale data (TTL candidates) = paying for storage of data you do not need

4. **Show the fix.** For each diagnostic finding, show the corrective action:
   - Drop unused indexes
   - Add the right index for full-scan queries
   - Use UUID PKs instead of monotonic
   - Enable Row-Level TTL for old data

---

## Troubleshooting

**Data load is very slow:**
- Ensure your CockroachDB cluster has adequate resources (at least 2 CPUs, 4 GB RAM)
- For single-node demos, use `cockroach start-single-node` with `--cache=1GiB`
- Check for resource contention from other processes on the machine

**Contention demo does not show events:**
- Contention events are only visible after both transactions have completed
- Make sure you run the multi-session version (3 terminals) for visible contention
- Check `crdb_internal.cluster_contention_events` a few seconds after the transactions finish

**Diagnostic queries return empty results:**
- Statement statistics are collected after queries execute -- wait 10 seconds after running Step 2
- If results are empty, run `SELECT * FROM crdb_internal.statement_statistics WHERE metadata->>'db' = 'cost_optimization_demo' LIMIT 5;` to verify stats exist
- Try resetting statement stats first: `SELECT crdb_internal.reset_sql_stats();` then re-run Step 2

**SHOW RANGES returns unexpected results:**
- Range information depends on cluster topology; single-node clusters will show fewer ranges
- Range sizes may differ from expectations based on compaction timing
