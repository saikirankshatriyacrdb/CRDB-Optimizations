-- =============================================================================
-- 01-create-bad-indexes.sql
-- CockroachDB Cost Optimization Workshop - Intentionally Bad Indexes
-- =============================================================================
-- PURPOSE:
--   Creates indexes that demonstrate common optimization opportunities:
--   - Unused indexes (never queried by the demo workload)
--   - Over-indexed tables (too many indexes on one table)
--   - Duplicate / redundant indexes (subset of another index)
--   - Wide indexes that are rarely useful
--
-- These indexes will be detected by the diagnostic queries in 05-run-diagnostics.sql.
--
-- ESTIMATED TIME: 3-5 minutes
-- =============================================================================

USE cost_optimization_demo;

-- ============================================================================
-- SECTION 1: UNUSED INDEXES
-- ============================================================================
-- These indexes are never queried by any part of the demo workload.
-- They consume storage and slow down writes for zero read benefit.
-- The diagnostic query for unused indexes will catch all of these.

-- Unused index 1: Nobody queries users by last_login alone
CREATE INDEX idx_users_last_login_unused
    ON users (last_login);

-- Unused index 2: Nobody queries products by inventory_count
CREATE INDEX idx_products_inventory_count_unused
    ON products (inventory_count);

-- Unused index 3: Nobody queries audit_logs by action alone
CREATE INDEX idx_audit_logs_action_unused
    ON audit_logs (action);

-- Unused index 4: Nobody queries sessions by created_at alone
CREATE INDEX idx_sessions_created_at_unused
    ON sessions (created_at);

-- Unused index 5: Nobody queries payments by method alone
CREATE INDEX idx_payments_method_unused
    ON payments (method);

-- Unused index 6: Nobody queries inventory_movements by created_at alone
CREATE INDEX idx_inv_movements_created_at_unused
    ON inventory_movements (created_at);


-- ============================================================================
-- SECTION 2: OVER-INDEXED TABLE (orders)
-- ============================================================================
-- The orders table already has idx_orders_user_id_created and idx_orders_status
-- from the schema setup. We add 6 more indexes to bring the total to 8+.
-- This is a common anti-pattern: adding an index for every query pattern
-- without considering the write amplification cost.
--
-- DIAGNOSTIC: The "over-indexed tables" query will flag orders as having
-- too many indexes relative to its column count.

-- Additional index 1: Redundant with idx_orders_user_id_created
-- This is a DUPLICATE/REDUNDANT index -- a single-column index on user_id
-- when a composite index (user_id, created_at) already exists.
-- The composite index can serve queries that only filter on user_id.
CREATE INDEX idx_orders_user_id_redundant
    ON orders (user_id);

-- Additional index 2: Index on total_amount (rarely queried this way)
CREATE INDEX idx_orders_total_amount
    ON orders (total_amount);

-- Additional index 3: Index on updated_at (rarely useful alone)
CREATE INDEX idx_orders_updated_at
    ON orders (updated_at);

-- Additional index 4: Index on created_at alone (already covered by composite)
CREATE INDEX idx_orders_created_at
    ON orders (created_at);

-- Additional index 5: Composite index on (status, total_amount) -- marginal use
CREATE INDEX idx_orders_status_total
    ON orders (status, total_amount);

-- Additional index 6: Composite index on (status, created_at) -- overlaps
CREATE INDEX idx_orders_status_created
    ON orders (status, created_at);

-- The orders table now has these indexes:
--   1. PRIMARY KEY (id)
--   2. idx_orders_user_id_created (user_id, created_at)  -- from schema
--   3. idx_orders_status (status)                         -- from schema
--   4. idx_orders_user_id_redundant (user_id)             -- REDUNDANT
--   5. idx_orders_total_amount (total_amount)              -- UNUSED
--   6. idx_orders_updated_at (updated_at)                 -- UNUSED
--   7. idx_orders_created_at (created_at)                 -- REDUNDANT
--   8. idx_orders_status_total (status, total_amount)     -- PARTIALLY REDUNDANT
--   9. idx_orders_status_created (status, created_at)     -- PARTIALLY REDUNDANT
-- Total: 9 indexes (including PK) -- this is too many for a 6-column table.


-- ============================================================================
-- SECTION 3: WIDE INDEX (storing many columns unnecessarily)
-- ============================================================================
-- This index stores all columns from the order_items table.
-- It is a "covering index" that is almost never used because the query
-- patterns do not benefit from having all columns in the index.
-- It doubles the storage for this table with minimal read benefit.

CREATE INDEX idx_order_items_wide_covering
    ON order_items (order_id)
    STORING (product_id, quantity, unit_price);

-- Another wide index: stores JSONB details in the audit_logs index.
-- JSONB columns in indexes are especially expensive.
CREATE INDEX idx_audit_logs_wide_with_json
    ON audit_logs (user_id, action)
    STORING (details);


-- ============================================================================
-- SECTION 4: PARTIAL DUPLICATE ON products
-- ============================================================================
-- This index on (category, price) partially overlaps with idx_products_category.
-- The single-column index is a prefix of this composite, making the
-- single-column index partially redundant (but not entirely, as the optimizer
-- may choose either depending on the query).

CREATE INDEX idx_products_category_price
    ON products (category, price);


-- ============================================================================
-- Summary of intentionally bad indexes created
-- ============================================================================
SELECT '================================================================' AS info;
SELECT 'Bad indexes created. Summary:' AS info;
SELECT '  6 unused indexes (never queried by demo workload)' AS info;
SELECT '  9 total indexes on orders table (over-indexed)' AS info;
SELECT '  1 redundant index (user_id when user_id,created_at exists)' AS info;
SELECT '  2 wide covering indexes (unnecessary STORING clauses)' AS info;
SELECT '  1 partial duplicate on products' AS info;
SELECT '================================================================' AS info;
SELECT 'Next step: Run 02-bad-queries.sql' AS info;

-- Show the index count per table for reference
SELECT
    table_name,
    count(*) AS index_count
FROM [SHOW INDEXES FROM cost_optimization_demo]
GROUP BY table_name
ORDER BY index_count DESC;
