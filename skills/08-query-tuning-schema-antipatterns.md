# CRDB Query Tuning: Schema Anti-Patterns

**When to use:** Application scaling issues, write hotspots, or developer code review for CockroachDB-specific gotchas.

---

## Anti-Pattern 1: OFFSET Pagination

```sql
-- ❌ BAD: Scans and discards N rows — gets slower as offset grows
SELECT * FROM orders ORDER BY id LIMIT 100 OFFSET 50000;

-- ✅ GOOD: Keyset pagination — always fast
-- First page:
SELECT * FROM orders ORDER BY id LIMIT 100;
-- Next page (pass last seen id from app):
SELECT * FROM orders WHERE id > [last_seen_id] ORDER BY id LIMIT 100;  -- CUSTOMIZE
```

---

## Anti-Pattern 2: SELECT * on Wide Tables

```sql
-- Find offending queries:
SELECT
    substring(key, 1, 100)                                       AS fingerprint,
    ROUND((statistics->'statistics'->'bytesRead'->'mean')::FLOAT) AS avg_bytes_read,
    (statistics->'statistics'->'cnt')::INT                       AS exec_count
FROM crdb_internal.statement_statistics
WHERE key ILIKE '%select *%'
  AND aggregated_ts >= now() - INTERVAL '24 hours'   -- CUSTOMIZE
  AND (statistics->'statistics'->'bytesRead'->'mean')::FLOAT > 100000
ORDER BY avg_bytes_read DESC LIMIT 20;

-- ❌ BAD: SELECT * FROM users WHERE id = 123;
-- ✅ GOOD:
SELECT id, email, name, created_at FROM users WHERE id = 123;  -- CUSTOMIZE columns
```

---

## Anti-Pattern 3: Monotonic PKs (Write Hotspots)

```sql
-- Find tables using sequential PKs:
SELECT table_name, column_name, column_default
FROM information_schema.columns
WHERE column_default LIKE '%nextval%' OR column_default LIKE '%unique_rowid%';

-- ✅ Fix A: UUID PK
CREATE TABLE [table] (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    -- CUSTOMIZE: add your columns
);

-- ✅ Fix B: Hash-sharded index (existing table)
-- CUSTOMIZE: BUCKET_COUNT (8-16 for high-write tables)
CREATE INDEX ON [table] ([pk_col]) USING HASH WITH BUCKET_COUNT = 8;
```

---

## Anti-Pattern 4: Wide UPDATE Statements

```sql
-- ❌ BAD: Rewrites entire row even for one column change

-- ✅ Fix: Column families (group by update frequency)
CREATE TABLE users (
    id UUID PRIMARY KEY,
    email STRING,
    last_login TIMESTAMP,
    FAMILY hot_cols (id, email, last_login),    -- frequently updated
    preferences JSONB,
    settings JSONB,
    FAMILY cold_cols (preferences, settings)    -- rarely updated
);
```

---

## Anti-Pattern 5: Large IN() Lists / Broad OR Chains

```sql
-- ❌ BAD: SELECT * FROM orders WHERE id IN (1, 2, 3, ... 10000);

-- ✅ Fix A: VALUES join
SELECT o.* FROM orders o
JOIN (VALUES (1), (2), (3)) AS ids(id) ON o.id = ids.id;  -- CUSTOMIZE

-- ✅ Fix B: UNION ALL for OR chains
SELECT * FROM orders WHERE status = 'ACTIVE'
UNION ALL
SELECT * FROM orders WHERE status = 'PENDING';  -- CUSTOMIZE
```

---

## Anti-Pattern 6: Non-Parameterized Queries

```sql
-- ❌ BAD: Unique literals bypass plan cache — each is a different query fingerprint
-- SELECT * FROM orders WHERE id = 12345;
-- SELECT * FROM orders WHERE id = 67890;

-- ✅ Fix: Use bind parameters in your application driver
-- Python: cursor.execute("SELECT * FROM orders WHERE id = $1", (order_id,))
-- Go:     db.QueryRow("SELECT * FROM orders WHERE id = $1", orderID)
-- Java:   stmt.setInt(1, orderId)
```

---

## Anti-Pattern 7: Always-Conflicting Upserts (Counter Storms)

```sql
-- ❌ BAD: Always conflicts = slow UPDATE with massive lock contention
-- INSERT INTO counters (key, value) VALUES ('hits', 1)
-- ON CONFLICT (key) DO UPDATE SET value = counters.value + 1;

-- ✅ Fix: Shard the counter across N rows
-- CUSTOMIZE: N = number of shards (e.g., 8)
INSERT INTO counters (shard, key, value)
VALUES (floor(random() * 8)::INT, 'hits', 1)
ON CONFLICT (shard, key) DO UPDATE SET value = counters.value + 1;

-- Read total:
SELECT SUM(value) FROM counters WHERE key = 'hits';
```

---

## Customization Checklist
- [ ] Replace `[table_name]`, `[column]`, `[last_seen_id]` with actual values
- [ ] Set `BUCKET_COUNT` based on write concurrency (8–16 for high-write tables)
- [ ] Implement keyset pagination cursor in application layer
- [ ] Group column families by update frequency in your schema
- [ ] Use bind parameters in ALL application queries
