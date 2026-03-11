-- =============================================================================
-- 99-cleanup.sql
-- CockroachDB Cost Optimization Workshop - Cleanup Script
-- =============================================================================
-- PURPOSE:
--   Drops all objects created by the demo scripts. Run this after the
--   workshop is complete to clean up the cluster.
--
-- WARNING:
--   This script is DESTRUCTIVE. It drops the entire cost_optimization_demo
--   database and all its contents. There is no undo.
--
-- ESTIMATED TIME: < 1 minute
-- =============================================================================

SELECT '================================================================' AS warning;
SELECT 'DROPPING the cost_optimization_demo database and ALL its data.' AS warning;
SELECT 'This action is irreversible.' AS warning;
SELECT '================================================================' AS warning;

-- Drop the entire database. CASCADE drops all tables, indexes, and data.
DROP DATABASE IF EXISTS cost_optimization_demo CASCADE;

SELECT '================================================================' AS status;
SELECT 'Cleanup complete. The cost_optimization_demo database has been dropped.' AS status;
SELECT 'All tables, indexes, and data have been removed.' AS status;
SELECT '================================================================' AS status;
