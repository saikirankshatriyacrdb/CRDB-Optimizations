-- =============================================================================
-- 04-generate-hotspots.sql
-- CockroachDB Cost Optimization Workshop - Hot Range / Write Hotspot Generator
-- =============================================================================
-- PURPOSE:
--   Generates write hotspots by exploiting two common anti-patterns:
--
--   1. MONOTONIC PRIMARY KEYS: The payments table uses unique_rowid() which
--      produces monotonically increasing values. All new inserts go to the
--      same range (the "last" range), creating a single-node bottleneck.
--
--   2. HOT ROW UPDATES: Repeatedly updating the same "counter" row simulates
--      a pattern common in systems that maintain running totals, sequence
--      generators, or global configuration in a single row.
--
-- HOW TO OBSERVE:
--   After running this script, check the DB Console:
--   - Hot Ranges page (Advanced Debug > Hot Ranges)
--   - Replication dashboard (look for uneven QPS across ranges)
--   - Key Visualizer (if available in your CockroachDB version)
--
-- ESTIMATED TIME: 3-5 minutes
-- =============================================================================

USE cost_optimization_demo;


-- =============================================================================
-- SECTION 1: SETUP - Create a counter table for hot row demo
-- =============================================================================

DROP TABLE IF EXISTS global_counters;

CREATE TABLE global_counters (
    counter_name STRING PRIMARY KEY,
    counter_value INT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Insert the counters that will become "hot rows"
INSERT INTO global_counters (counter_name, counter_value) VALUES
    ('total_orders', 500000),
    ('total_revenue_cents', 250000000),
    ('active_sessions', 200000),
    ('daily_signups', 0),
    ('page_views', 0);

SELECT 'Hot row counter table created.' AS status;


-- =============================================================================
-- SECTION 2: MONOTONIC INSERT HOTSPOT
-- =============================================================================
-- The payments table uses INT PRIMARY KEY DEFAULT unique_rowid().
-- unique_rowid() generates monotonically increasing values based on timestamp
-- and node ID. This means ALL new inserts go to the same range -- the one
-- that owns the highest key values.
--
-- In a multi-node cluster, this creates a single leaseholder bottleneck:
-- one node handles ALL writes while the others sit idle.
--
-- WHAT TO LOOK FOR:
--   - In Hot Ranges: the payments table will show one range with
--     disproportionately high write QPS
--   - The range that contains the "end" of the table gets all inserts
--
-- FIX: Use UUID PRIMARY KEY DEFAULT gen_random_uuid() for uniform distribution.

SELECT 'Generating monotonic insert hotspot on payments table...' AS status;
SELECT 'Inserting 50,000 rows rapidly with unique_rowid() PK...' AS note;

-- Rapid burst insert: 10 batches of 5,000 rows with no delay
-- This concentrates writes on the last range of the payments table.

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 1/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 2/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 149999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 3/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 4/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 249999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 5/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 6/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 349999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 7/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 399999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 8/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 449999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 9/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 499999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 5000) AS s;
SELECT 'Hotspot insert batch 10/10 complete. 50,000 rows inserted.' AS progress;


-- Also do the same for inventory_movements (SERIAL PK = monotonic)
SELECT 'Generating monotonic insert hotspot on inventory_movements table...' AS status;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    (random() * 100 + 1)::INT,
    now()
FROM generate_series(1, 10000) AS s;
SELECT 'inventory_movements: 10,000 rapid sequential inserts complete.' AS progress;


-- =============================================================================
-- SECTION 3: HOT ROW UPDATES (single-row contention point)
-- =============================================================================
-- Updating the same counter row hundreds of times simulates systems that
-- maintain a running total in the database. Every update to the same row
-- creates write-write contention and makes that range "hot."
--
-- WHAT TO LOOK FOR:
--   - The global_counters table range will show high write QPS
--   - In a multi-node cluster, all updates serialize on one leaseholder
--
-- FIX: Use a sharded counter pattern:
--   - Instead of one row, use N shard rows (e.g., counter_1, counter_2, ...)
--   - Randomly pick a shard for each increment
--   - SUM all shards when you need the total

SELECT 'Generating hot row updates on global_counters...' AS status;
SELECT 'Updating the same counter row 500 times rapidly...' AS note;

-- Update total_orders counter 500 times
-- We use generate_series to drive repeated updates in a single statement.
-- Each iteration updates the same row.

UPDATE global_counters
SET counter_value = counter_value + 1, updated_at = now()
WHERE counter_name = 'page_views';

UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'page_views';

-- Also update total_orders counter rapidly
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'total_orders';

-- Update daily_signups to create another hot row
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';
UPDATE global_counters SET counter_value = counter_value + 1, updated_at = now() WHERE counter_name = 'daily_signups';

SELECT 'Hot row updates complete.' AS status;

-- Show final counter values
SELECT * FROM global_counters ORDER BY counter_name;


-- =============================================================================
-- SECTION 4: COMPARE WITH PROPER UUID DISTRIBUTION
-- =============================================================================
-- For contrast, show that UUID-based inserts distribute evenly.
-- Create a properly-designed table and insert data to compare.

DROP TABLE IF EXISTS payments_fixed;

CREATE TABLE payments_fixed (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    method STRING NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

SELECT 'Inserting 10,000 rows into UUID-based payments_fixed for comparison...' AS status;

INSERT INTO payments_fixed (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    round((random() * 500 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now()
FROM generate_series(1, 10000) AS s;

SELECT 'UUID-based inserts complete. Compare range distribution:' AS status;


-- =============================================================================
-- SECTION 5: CHECK RANGE DISTRIBUTION
-- =============================================================================
-- Show the range distribution for both tables so the presenter can compare.

SELECT
    'payments (monotonic PK - HOT)' AS table_info,
    count(*) AS total_ranges
FROM [SHOW RANGES FROM TABLE payments];

SELECT
    'payments_fixed (UUID PK - distributed)' AS table_info,
    count(*) AS total_ranges
FROM [SHOW RANGES FROM TABLE payments_fixed];

-- Show range details for the payments table to identify the hot range
SELECT
    start_key,
    end_key,
    lease_holder,
    range_size / 1000000 AS range_size_mb
FROM [SHOW RANGES FROM TABLE payments]
ORDER BY range_size DESC
LIMIT 5;


SELECT '================================================================' AS info;
SELECT 'Hotspot generation complete.' AS info;
SELECT '' AS info;
SELECT 'WHAT TO SHOW THE AUDIENCE:' AS info;
SELECT '  1. DB Console > Hot Ranges page' AS info;
SELECT '  2. Compare payments (monotonic) vs payments_fixed (UUID)' AS info;
SELECT '  3. Range distribution differences between the two tables' AS info;
SELECT '' AS info;
SELECT 'Next step: Run 05-run-diagnostics.sql' AS info;
SELECT '================================================================' AS info;
