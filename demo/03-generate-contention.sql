-- =============================================================================
-- 03-generate-contention.sql
-- CockroachDB Cost Optimization Workshop - Lock Contention Generator
-- =============================================================================
-- PURPOSE:
--   Generates lock contention by running concurrent transactions that
--   target the same rows with intentional delays. This simulates the kind
--   of contention that occurs in production when multiple application
--   instances try to update the same "hot" rows simultaneously.
--
-- HOW TO USE:
--   This script is designed to be run from MULTIPLE SQL shells simultaneously.
--   1. Open 3-4 separate terminal windows.
--   2. Connect to CockroachDB in each: cockroach sql --url="..."
--   3. Copy-paste a different "Session" block into each terminal.
--   4. Execute them at roughly the same time.
--
--   Alternatively, you can run the single-shell version at the bottom
--   which uses separate transactions sequentially (less dramatic but
--   still generates contention events in the logs).
--
-- WHAT TO OBSERVE:
--   - In the DB Console: go to Insights > Workload Insights to see contention events
--   - In the DB Console: SQL Activity > Statements page shows contention time
--   - The diagnostic query in 05-run-diagnostics.sql will show contention events
--
-- ESTIMATED TIME: 2-3 minutes
-- =============================================================================

USE cost_optimization_demo;

-- =============================================================================
-- SETUP: Create a known contention target
-- =============================================================================
-- We create a small "hot" table that multiple sessions will fight over.
-- This ensures predictable contention regardless of which random rows
-- exist in the larger tables.

DROP TABLE IF EXISTS contention_demo;

CREATE TABLE contention_demo (
    id INT PRIMARY KEY,
    counter INT NOT NULL DEFAULT 0,
    last_updated_by STRING NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Insert 5 rows that will be the contention targets
INSERT INTO contention_demo (id, counter) VALUES (1, 0), (2, 0), (3, 0), (4, 0), (5, 0);

SELECT 'Contention demo table created with 5 rows.' AS status;
SELECT 'Now open multiple SQL shells and run the Session blocks below.' AS instruction;


-- =============================================================================
-- SESSION 1: Copy-paste this block into Terminal 1
-- =============================================================================
-- Run this in a SEPARATE cockroach sql shell:
/*

USE cost_optimization_demo;

-- Transaction 1A: Lock row 1, sleep, then update row 2
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 1;
SELECT pg_sleep(5);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 2;
COMMIT;

-- Transaction 1B: Another round
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 3;
SELECT pg_sleep(5);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 1;
COMMIT;

-- Transaction 1C: Target the same rows again
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 1;
SELECT pg_sleep(3);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session1', updated_at = now() WHERE id = 2;
COMMIT;

*/


-- =============================================================================
-- SESSION 2: Copy-paste this block into Terminal 2
-- =============================================================================
-- Run this in a SEPARATE cockroach sql shell:
/*

USE cost_optimization_demo;

-- Transaction 2A: Lock row 2, sleep, then try row 1 (will contend with Session 1)
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 2;
SELECT pg_sleep(5);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 1;
COMMIT;

-- Transaction 2B: Another round
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 1;
SELECT pg_sleep(5);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 3;
COMMIT;

-- Transaction 2C: More contention
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 2;
SELECT pg_sleep(3);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session2', updated_at = now() WHERE id = 1;
COMMIT;

*/


-- =============================================================================
-- SESSION 3: Copy-paste this block into Terminal 3
-- =============================================================================
-- Run this in a SEPARATE cockroach sql shell:
/*

USE cost_optimization_demo;

-- Transaction 3A: Lock row 1, contend with both other sessions
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 1;
SELECT pg_sleep(4);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 3;
COMMIT;

-- Transaction 3B: Different pattern
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 2;
SELECT pg_sleep(4);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 1;
COMMIT;

-- Transaction 3C: Final round
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 1;
SELECT pg_sleep(3);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'session3', updated_at = now() WHERE id = 2;
COMMIT;

*/


-- =============================================================================
-- SINGLE-SHELL VERSION (if you cannot open multiple terminals)
-- =============================================================================
-- This version runs contention-generating transactions sequentially.
-- It generates less dramatic contention but still creates entries in
-- the contention event log. The pg_sleep delays simulate application
-- think time that holds locks open.

SELECT '================================================================' AS info;
SELECT 'Running single-shell contention generator...' AS info;
SELECT 'For best results, also run the multi-session version above.' AS info;
SELECT '================================================================' AS info;

-- Generate contention against the main tables too, not just the demo table.
-- These UPDATE statements target orders rows, which is more realistic.

-- Transaction A: Update an order, hold the lock, update another
BEGIN;
UPDATE orders
SET status = 'processing', updated_at = now()
WHERE id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1);
SELECT pg_sleep(2);
UPDATE orders
SET status = 'processing', updated_at = now()
WHERE id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1 OFFSET 1);
COMMIT;

-- Transaction B: Update the same status range
BEGIN;
UPDATE orders
SET status = 'shipped', updated_at = now()
WHERE id = (SELECT id FROM orders WHERE status = 'pending' LIMIT 1);
SELECT pg_sleep(2);
COMMIT;

-- Transaction C: Contention on the contention_demo table
BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_A' WHERE id = 1;
SELECT pg_sleep(2);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_A' WHERE id = 2;
COMMIT;

BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_B' WHERE id = 1;
SELECT pg_sleep(2);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_B' WHERE id = 2;
COMMIT;

BEGIN;
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_C' WHERE id = 2;
SELECT pg_sleep(1);
UPDATE contention_demo SET counter = counter + 1, last_updated_by = 'single_shell_C' WHERE id = 1;
COMMIT;

-- Show the final state of the contention demo table
SELECT * FROM contention_demo ORDER BY id;

SELECT '================================================================' AS info;
SELECT 'Contention generation complete.' AS info;
SELECT 'Check DB Console > Insights > Workload Insights for contention events.' AS info;
SELECT 'Next step: Run 04-generate-hotspots.sql' AS info;
SELECT '================================================================' AS info;
