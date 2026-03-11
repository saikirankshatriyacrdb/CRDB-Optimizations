-- =============================================================================
-- 02-bad-queries.sql
-- CockroachDB Cost Optimization Workshop - Bad Query Anti-Patterns
-- =============================================================================
-- PURPOSE:
--   Demonstrates common query performance anti-patterns. Each query is
--   annotated with:
--     - What anti-pattern it demonstrates
--     - Why it is expensive
--     - What the diagnostic query in 05-run-diagnostics.sql will catch
--     - How to fix it
--
-- INSTRUCTIONS:
--   Run each query one at a time. Observe the execution time.
--   You can use EXPLAIN ANALYZE to see the query plan before/after fixes.
--
-- ESTIMATED TIME: 5-10 minutes (some queries are intentionally slow)
-- =============================================================================

USE cost_optimization_demo;

-- Run each bad query multiple times so it appears in statement statistics.
-- The diagnostic queries look at crdb_internal.statement_statistics.


-- =============================================================================
-- ANTI-PATTERN 1: FULL TABLE SCAN
-- =============================================================================
-- WHAT IS WRONG:
--   Filtering on 'name' column which has no index. CockroachDB must read
--   every row in the 50K-row users table to find matches.
--
-- DIAGNOSTIC CATCH:
--   05-run-diagnostics.sql "Full Table Scans" query will show this statement
--   with full_scan = true.
--
-- FIX: CREATE INDEX idx_users_name ON users (name);

SELECT 'ANTI-PATTERN 1: Full table scan on users.name (no index)' AS demo;

EXPLAIN ANALYZE
SELECT id, email, name, created_at
FROM users
WHERE name = 'Alice Smith';

-- Run it a few more times without EXPLAIN to populate statement stats
SELECT id, email, name, created_at FROM users WHERE name = 'Alice Smith';
SELECT id, email, name, created_at FROM users WHERE name = 'Bob Johnson';
SELECT id, email, name, created_at FROM users WHERE name = 'Charlie Williams';


-- =============================================================================
-- ANTI-PATTERN 2: SELECT * (fetching unnecessary columns)
-- =============================================================================
-- WHAT IS WRONG:
--   SELECT * fetches all columns from both tables, including large fields
--   that are not needed. This wastes network bandwidth, memory, and prevents
--   the optimizer from using covering indexes.
--
-- DIAGNOSTIC CATCH:
--   The "CPU-heavy queries" and "rows read vs returned" diagnostics will
--   flag this. Also visible in the Statements page as high latency.
--
-- FIX: SELECT only the columns you need:
--   SELECT o.id, o.status, oi.quantity, oi.unit_price FROM orders o JOIN ...

SELECT 'ANTI-PATTERN 2: SELECT * from large join' AS demo;

EXPLAIN ANALYZE
SELECT *
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.status = 'pending'
LIMIT 100;

-- Run without EXPLAIN to populate stats
SELECT * FROM orders o JOIN order_items oi ON oi.order_id = o.id WHERE o.status = 'pending' LIMIT 100;
SELECT * FROM orders o JOIN order_items oi ON oi.order_id = o.id WHERE o.status = 'shipped' LIMIT 100;


-- =============================================================================
-- ANTI-PATTERN 3: HIGH ROWS-READ-TO-RETURNED RATIO
-- =============================================================================
-- WHAT IS WRONG:
--   This query reads the entire audit_logs table (1M rows) but only returns
--   rows matching a very specific JSONB field value. The ratio of rows
--   read to rows returned will be extremely high (e.g., 100,000:1).
--
-- DIAGNOSTIC CATCH:
--   05-run-diagnostics.sql "Rows Read vs Returned" query will show this
--   statement with a very high ratio.
--
-- FIX: Add a GIN index on the JSONB column, or extract the field into a
--   regular column with an index:
--   CREATE INVERTED INDEX idx_audit_logs_details ON audit_logs (details);

SELECT 'ANTI-PATTERN 3: High rows-read-to-returned ratio (JSONB filter)' AS demo;

EXPLAIN ANALYZE
SELECT id, user_id, action, created_at
FROM audit_logs
WHERE details->>'ip' = '192.168.1.1';

-- Run again to populate stats
SELECT id, user_id, action, created_at FROM audit_logs WHERE details->>'ip' = '192.168.1.1';
SELECT id, user_id, action, created_at FROM audit_logs WHERE details->>'ip' = '10.0.1.1';


-- =============================================================================
-- ANTI-PATTERN 4: MISSING INDEX CAUSING EXPENSIVE SORT
-- =============================================================================
-- WHAT IS WRONG:
--   ORDER BY on total_amount requires sorting 500K rows in memory.
--   While idx_orders_total_amount exists from 01-create-bad-indexes.sql,
--   this query filters on a non-indexed predicate (updated_at range) forcing
--   a full scan + sort. The sort on a large result set is very expensive.
--
-- DIAGNOSTIC CATCH:
--   Will appear as a high-latency query in statement statistics.
--   EXPLAIN will show a "sort" node processing many rows.
--
-- FIX: Create a composite index: CREATE INDEX ON orders (updated_at, total_amount);

SELECT 'ANTI-PATTERN 4: Missing index causing expensive sort' AS demo;

EXPLAIN ANALYZE
SELECT id, user_id, total_amount, status
FROM orders
WHERE updated_at > now() - INTERVAL '30 days'
ORDER BY total_amount DESC
LIMIT 50;

-- Run again
SELECT id, user_id, total_amount, status FROM orders WHERE updated_at > now() - INTERVAL '30 days' ORDER BY total_amount DESC LIMIT 50;
SELECT id, user_id, total_amount, status FROM orders WHERE updated_at > now() - INTERVAL '60 days' ORDER BY total_amount DESC LIMIT 50;


-- =============================================================================
-- ANTI-PATTERN 5: ACCIDENTAL CROSS JOIN (CARTESIAN PRODUCT)
-- =============================================================================
-- WHAT IS WRONG:
--   Missing JOIN condition between products and order_items creates a
--   cartesian product. With 10K products and 2M order_items, this would
--   attempt to produce 20 BILLION rows. The LIMIT saves us, but the
--   optimizer still has to plan for the worst case.
--
-- DIAGNOSTIC CATCH:
--   Will appear with extremely high rows_read in statement stats.
--   EXPLAIN will show a "cross join" node.
--
-- FIX: Add the proper JOIN condition:
--   FROM products p JOIN order_items oi ON oi.product_id = p.id

SELECT 'ANTI-PATTERN 5: Accidental cross join (cartesian product)' AS demo;

-- WARNING: This query is intentionally limited to prevent runaway execution.
-- In production, without LIMIT, this would be catastrophic.
EXPLAIN ANALYZE
SELECT p.name, oi.quantity
FROM products p, order_items oi
WHERE p.category = 'Electronics'
LIMIT 10;

-- Run again
SELECT p.name, oi.quantity FROM products p, order_items oi WHERE p.category = 'Electronics' LIMIT 10;


-- =============================================================================
-- ANTI-PATTERN 6: LIKE WITH LEADING WILDCARD
-- =============================================================================
-- WHAT IS WRONG:
--   A LIKE pattern starting with '%' cannot use a B-tree index. Even though
--   idx_users_email exists, CockroachDB must perform a full table scan
--   because it cannot seek to a specific position in the index.
--
-- DIAGNOSTIC CATCH:
--   Full table scan detection will flag this query.
--
-- FIX: Use a trigram index (CREATE INDEX ON users USING GIN (email gin_trgm_ops))
--   or restructure the query to avoid leading wildcards. For email domain
--   searches, consider storing the domain as a separate indexed column.

SELECT 'ANTI-PATTERN 6: LIKE with leading wildcard' AS demo;

EXPLAIN ANALYZE
SELECT id, email, name
FROM users
WHERE email LIKE '%@gmail.com';

-- Run again
SELECT id, email, name FROM users WHERE email LIKE '%@gmail.com';
SELECT id, email, name FROM users WHERE email LIKE '%@yahoo.com';
SELECT id, email, name FROM users WHERE email LIKE '%company.com';


-- =============================================================================
-- ANTI-PATTERN 7: IMPLICIT TYPE CONVERSION
-- =============================================================================
-- WHAT IS WRONG:
--   The payments table has id as INT, but we are comparing it to a STRING.
--   CockroachDB may need to cast every row's id to STRING (or vice versa),
--   which can prevent index usage and cause a full table scan.
--
-- DIAGNOSTIC CATCH:
--   Full table scan detection, plus high rows_read for a single-row lookup.
--
-- FIX: Use the correct type in the WHERE clause:
--   WHERE id = 123456 (without quotes)

SELECT 'ANTI-PATTERN 7: Implicit type conversion (INT compared to STRING)' AS demo;

-- First, get a real payment ID to use
-- (We use a subquery to get a valid ID, then cast it to string for the bad query)

EXPLAIN ANALYZE
SELECT id, order_id, amount, method
FROM payments
WHERE id::STRING = (SELECT id::STRING FROM payments LIMIT 1);

-- A slightly different version: filtering with a string literal on an INT column.
-- This forces CockroachDB to evaluate the expression for every row.
EXPLAIN ANALYZE
SELECT id, order_id, amount, method
FROM payments
WHERE id::STRING LIKE '1%'
LIMIT 10;

SELECT id, order_id, amount, method FROM payments WHERE id::STRING LIKE '1%' LIMIT 10;


-- =============================================================================
-- ANTI-PATTERN 8: PAGINATION WITH LARGE OFFSET
-- =============================================================================
-- WHAT IS WRONG:
--   OFFSET 100000 means CockroachDB must read and discard 100,000 rows
--   before returning the next 10. This gets progressively worse as the
--   offset increases. At OFFSET 100000 on a 500K-row table, 20% of the
--   table is read and thrown away.
--
-- DIAGNOSTIC CATCH:
--   High rows_read vs rows_returned ratio. The ratio here is 10,001:1.
--
-- FIX: Use keyset pagination (cursor-based pagination):
--   WHERE created_at > $last_seen_created_at ORDER BY created_at LIMIT 10

SELECT 'ANTI-PATTERN 8: Large OFFSET pagination' AS demo;

EXPLAIN ANALYZE
SELECT id, user_id, total_amount, status, created_at
FROM orders
ORDER BY created_at
OFFSET 100000 LIMIT 10;

-- Even worse: very large offset
EXPLAIN ANALYZE
SELECT id, user_id, total_amount, status, created_at
FROM orders
ORDER BY created_at
OFFSET 400000 LIMIT 10;

-- Run without EXPLAIN for stats
SELECT id, user_id, total_amount, status, created_at FROM orders ORDER BY created_at OFFSET 100000 LIMIT 10;
SELECT id, user_id, total_amount, status, created_at FROM orders ORDER BY created_at OFFSET 200000 LIMIT 10;


-- =============================================================================
-- ANTI-PATTERN 9: N+1 QUERY PATTERN
-- =============================================================================
-- WHAT IS WRONG:
--   Instead of fetching all data in one query with a JOIN, the application
--   first fetches a list of orders, then issues a SEPARATE query for each
--   order to get its items. With 100 orders, this becomes 101 queries
--   (1 for the list + 100 for items).
--
-- DIAGNOSTIC CATCH:
--   You will see the order_items SELECT with very high execution_count in
--   statement statistics, with low rows_returned per execution.
--
-- FIX: Use a single JOIN query:
--   SELECT o.id, oi.product_id, oi.quantity
--   FROM orders o
--   JOIN order_items oi ON oi.order_id = o.id
--   WHERE o.status = 'pending'
--   LIMIT 400;
--
-- NOTE: In a real application, the N+1 pattern happens in application code
-- (e.g., a for-loop making individual DB calls). Below we simulate it by
-- running the "inner" query repeatedly with different order IDs.

SELECT 'ANTI-PATTERN 9: N+1 query pattern (simulated)' AS demo;
SELECT 'In production, this happens in app code loops. We simulate it here.' AS note;

-- Step 1: The "outer" query fetches order IDs
-- (In real code, the app would iterate over these results)
SELECT id FROM orders WHERE status = 'pending' LIMIT 20;

-- Step 2: For each order, the app issues a separate query (N+1).
-- We simulate by running the inner query 20 times with different orders.
-- In a real app, each of these would be a separate network round-trip.

-- Simulate N+1: pick 20 random orders and query their items individually
SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 0);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 1);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 2);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 3);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 4);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 5);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 6);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 7);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 8);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 9);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 10);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 11);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 12);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 13);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 14);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 15);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 16);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 17);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 18);

SELECT oi.id, oi.product_id, oi.quantity, oi.unit_price
FROM order_items oi
WHERE oi.order_id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 19);


-- =============================================================================
-- ANTI-PATTERN 10 (BONUS): UNNECESSARY DISTINCT ON UNIQUE COLUMN
-- =============================================================================
-- WHAT IS WRONG:
--   Using DISTINCT on a column that is already unique (PK) adds an
--   unnecessary sort/hash aggregate step. The optimizer may not always
--   eliminate it.
--
-- FIX: Remove the DISTINCT keyword.

SELECT 'ANTI-PATTERN 10: Unnecessary DISTINCT on unique column' AS demo;

SELECT DISTINCT id, email, name
FROM users
WHERE status = 'active'
LIMIT 100;


SELECT '================================================================' AS info;
SELECT 'All bad queries executed. Statement statistics are now populated.' AS info;
SELECT 'Next step: Run 03-generate-contention.sql' AS info;
SELECT '================================================================' AS info;
