-- =============================================================================
-- 00-setup-schema.sql
-- CockroachDB Cost Optimization Workshop - Demo Dataset
-- =============================================================================
-- PURPOSE:
--   Creates a realistic e-commerce schema and populates it with synthetic data.
--   This dataset is used when customers prefer not to run diagnostic queries
--   against their own production workloads.
--
-- TABLES CREATED:
--   users               ~50K rows
--   products             ~10K rows
--   orders              ~500K rows
--   order_items           ~2M rows
--   audit_logs            ~1M rows  (TTL candidate)
--   sessions             ~200K rows (TTL candidate)
--   payments             ~500K rows (hot key / monotonic PK demo)
--   inventory_movements   ~1M rows
--
-- ESTIMATED TIME: 15-25 minutes depending on cluster size
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Step 0: Create the database
-- ---------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS cost_optimization_demo;
USE cost_optimization_demo;

-- ---------------------------------------------------------------------------
-- Step 1: Drop tables if they exist (idempotent re-runs)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS inventory_movements CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS sessions CASCADE;
DROP TABLE IF EXISTS audit_logs CASCADE;
DROP TABLE IF EXISTS order_items CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- ---------------------------------------------------------------------------
-- Step 2: Create tables
-- ---------------------------------------------------------------------------

-- USERS: 50K customers
CREATE TABLE users (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email      STRING NOT NULL,
    name       STRING NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_login TIMESTAMPTZ,
    status     STRING NOT NULL DEFAULT 'active',
    INDEX idx_users_email (email),
    INDEX idx_users_status (status)
);

-- PRODUCTS: 10K products across categories
CREATE TABLE products (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            STRING NOT NULL,
    category        STRING NOT NULL,
    price           DECIMAL(10,2) NOT NULL,
    inventory_count INT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_products_category (category)
);

-- ORDERS: 500K orders
CREATE TABLE orders (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id),
    total_amount DECIMAL(12,2) NOT NULL,
    status       STRING NOT NULL DEFAULT 'pending',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_orders_user_id_created (user_id, created_at),
    INDEX idx_orders_status (status)
);

-- ORDER_ITEMS: ~2M line items
CREATE TABLE order_items (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id   UUID NOT NULL REFERENCES orders(id),
    product_id UUID NOT NULL REFERENCES products(id),
    quantity   INT NOT NULL,
    unit_price DECIMAL(10,2) NOT NULL,
    INDEX idx_order_items_order_id (order_id),
    INDEX idx_order_items_product_id (product_id)
);

-- AUDIT_LOGS: 1M rows - candidate for TTL (Row-Level TTL)
-- Old audit logs should be automatically expired.
CREATE TABLE audit_logs (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL,
    action     STRING NOT NULL,
    details    JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_audit_logs_user_id (user_id),
    INDEX idx_audit_logs_created_at (created_at)
);

-- SESSIONS: 200K rows - candidate for TTL
-- Stale sessions should be cleaned up automatically.
CREATE TABLE sessions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL,
    token          STRING NOT NULL,
    last_active_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_sessions_user_id (user_id),
    INDEX idx_sessions_token (token)
);

-- PAYMENTS: 500K rows - uses unique_rowid() for monotonic PK (hotspot demo)
-- This intentionally uses a monotonic primary key to demonstrate write hotspots.
CREATE TABLE payments (
    id           INT PRIMARY KEY DEFAULT unique_rowid(),
    order_id     UUID NOT NULL,
    amount       DECIMAL(12,2) NOT NULL,
    method       STRING NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_payments_order_id (order_id)
);

-- INVENTORY_MOVEMENTS: 1M rows - uses SERIAL PK (another monotonic PK)
CREATE TABLE inventory_movements (
    id              SERIAL PRIMARY KEY,
    product_id      UUID NOT NULL,
    warehouse_id    INT NOT NULL,
    quantity_change INT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_inv_movements_product_id (product_id),
    INDEX idx_inv_movements_warehouse_id (warehouse_id)
);


-- =============================================================================
-- Step 3: Populate data
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 3a. USERS - 50K rows (inserted in one batch)
-- ---------------------------------------------------------------------------
-- Uses generate_series to create 50,000 users with varied creation dates
-- spanning the last 2 years, and varied statuses.

SELECT 'Inserting users (50,000 rows)...' AS progress;

INSERT INTO users (id, email, name, created_at, last_login, status)
SELECT
    gen_random_uuid(),
    'user' || s::STRING || '@' ||
        CASE (s % 5)
            WHEN 0 THEN 'gmail.com'
            WHEN 1 THEN 'yahoo.com'
            WHEN 2 THEN 'outlook.com'
            WHEN 3 THEN 'company.com'
            WHEN 4 THEN 'fastmail.net'
        END,
    CASE (s % 10)
        WHEN 0 THEN 'Alice'
        WHEN 1 THEN 'Bob'
        WHEN 2 THEN 'Charlie'
        WHEN 3 THEN 'Diana'
        WHEN 4 THEN 'Edward'
        WHEN 5 THEN 'Fiona'
        WHEN 6 THEN 'George'
        WHEN 7 THEN 'Hannah'
        WHEN 8 THEN 'Ivan'
        WHEN 9 THEN 'Julia'
    END || ' ' ||
    CASE (s % 8)
        WHEN 0 THEN 'Smith'
        WHEN 1 THEN 'Johnson'
        WHEN 2 THEN 'Williams'
        WHEN 3 THEN 'Brown'
        WHEN 4 THEN 'Jones'
        WHEN 5 THEN 'Garcia'
        WHEN 6 THEN 'Miller'
        WHEN 7 THEN 'Davis'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '30 days'),
    CASE
        WHEN random() < 0.85 THEN 'active'
        WHEN random() < 0.95 THEN 'inactive'
        ELSE 'suspended'
    END
FROM generate_series(1, 50000) AS s;

SELECT 'Users inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3b. PRODUCTS - 10K rows
-- ---------------------------------------------------------------------------
SELECT 'Inserting products (10,000 rows)...' AS progress;

INSERT INTO products (id, name, category, price, inventory_count, created_at)
SELECT
    gen_random_uuid(),
    CASE (s % 12)
        WHEN 0  THEN 'Widget'
        WHEN 1  THEN 'Gadget'
        WHEN 2  THEN 'Doohickey'
        WHEN 3  THEN 'Thingamajig'
        WHEN 4  THEN 'Whatchamacallit'
        WHEN 5  THEN 'Gizmo'
        WHEN 6  THEN 'Contraption'
        WHEN 7  THEN 'Apparatus'
        WHEN 8  THEN 'Device'
        WHEN 9  THEN 'Module'
        WHEN 10 THEN 'Component'
        WHEN 11 THEN 'Assembly'
    END || ' ' ||
    CASE (s % 6)
        WHEN 0 THEN 'Pro'
        WHEN 1 THEN 'Lite'
        WHEN 2 THEN 'Max'
        WHEN 3 THEN 'Mini'
        WHEN 4 THEN 'Ultra'
        WHEN 5 THEN 'Basic'
    END || ' ' || (s % 500)::STRING,
    CASE (s % 8)
        WHEN 0 THEN 'Electronics'
        WHEN 1 THEN 'Clothing'
        WHEN 2 THEN 'Home & Garden'
        WHEN 3 THEN 'Sports'
        WHEN 4 THEN 'Books'
        WHEN 5 THEN 'Toys'
        WHEN 6 THEN 'Automotive'
        WHEN 7 THEN 'Health'
    END,
    round((random() * 499 + 1)::DECIMAL, 2),
    (random() * 1000)::INT,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 10000) AS s;

SELECT 'Products inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3c. ORDERS - 500K rows (batches of 50K)
-- ---------------------------------------------------------------------------
-- We need user IDs to reference. We use a subquery approach:
-- pick a random user_id by offsetting into the users table.

SELECT 'Inserting orders (500,000 rows in batches of 50,000)...' AS progress;

-- Batch 1 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 1/10 complete.' AS progress;

-- Batch 2 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 2/10 complete.' AS progress;

-- Batch 3 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 3/10 complete.' AS progress;

-- Batch 4 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 4/10 complete.' AS progress;

-- Batch 5 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 5/10 complete.' AS progress;

-- Batch 6 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 6/10 complete.' AS progress;

-- Batch 7 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 7/10 complete.' AS progress;

-- Batch 8 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 8/10 complete.' AS progress;

-- Batch 9 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'Orders batch 9/10 complete.' AS progress;

-- Batch 10 of 10
INSERT INTO orders (id, user_id, total_amount, status, created_at, updated_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 6)
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'processing'
        WHEN 2 THEN 'shipped'
        WHEN 3 THEN 'delivered'
        WHEN 4 THEN 'delivered'
        WHEN 5 THEN 'cancelled'
    END,
    now() - (random() * INTERVAL '730 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;

SELECT 'All 500,000 orders inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3d. ORDER_ITEMS - ~2M rows (batches of 50K, 40 batches)
-- ---------------------------------------------------------------------------
-- Each order gets ~4 items on average.
-- We pick a random order_id and product_id for each row.

SELECT 'Inserting order_items (~2,000,000 rows in batches of 50,000)...' AS progress;
SELECT 'This is the largest table -- expect this step to take 5-10 minutes.' AS note;

-- We will insert 40 batches of 50,000 rows = 2,000,000 rows total.
-- To avoid repeating 40 nearly identical INSERT blocks, we use a loop via
-- a simple approach: 4 groups of 10 batches using different series offsets.

-- Group A: Batches 1-10 (500K rows)
INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 1/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 2/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 3/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 4/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 5/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 6/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 7/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 8/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 9/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 10/40 complete.' AS progress;

-- Group B: Batches 11-20 (500K rows)
INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 11/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 12/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 13/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 14/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 15/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 16/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 17/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 18/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 19/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 20/40 complete. Halfway there!' AS progress;

-- Group C: Batches 21-30 (500K rows)
INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 21/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 22/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 23/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 24/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 25/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 26/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 27/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 28/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 29/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 30/40 complete.' AS progress;

-- Group D: Batches 31-40 (500K rows)
INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 31/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 32/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 33/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 34/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 35/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 36/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 37/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 38/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'order_items batch 39/40 complete.' AS progress;

INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
SELECT
    gen_random_uuid(),
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,
    round((random() * 199 + 1)::DECIMAL, 2)
FROM generate_series(1, 50000) AS s;
SELECT 'All 2,000,000 order_items inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3e. AUDIT_LOGS - 1M rows (batches of 50K, 20 batches)
-- ---------------------------------------------------------------------------
SELECT 'Inserting audit_logs (1,000,000 rows in batches of 50,000)...' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7)
        WHEN 0 THEN 'login'
        WHEN 1 THEN 'logout'
        WHEN 2 THEN 'page_view'
        WHEN 3 THEN 'add_to_cart'
        WHEN 4 THEN 'checkout'
        WHEN 5 THEN 'update_profile'
        WHEN 6 THEN 'password_change'
    END,
    jsonb_build_object(
        'ip', '192.168.' || (s % 255)::STRING || '.' || ((s * 7) % 255)::STRING,
        'user_agent', CASE (s % 3)
            WHEN 0 THEN 'Mozilla/5.0 Chrome'
            WHEN 1 THEN 'Mozilla/5.0 Firefox'
            WHEN 2 THEN 'Mozilla/5.0 Safari'
        END,
        'session_id', gen_random_uuid()::STRING
    ),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 1/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.0.' || (s % 255)::STRING || '.' || ((s * 3) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 2/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '172.16.' || (s % 255)::STRING || '.' || ((s * 11) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 3/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.1.' || (s % 255)::STRING || '.' || ((s * 13) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 4/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.2.' || (s % 255)::STRING || '.' || ((s * 17) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 5/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.3.' || (s % 255)::STRING || '.' || ((s * 19) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 6/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.4.' || (s % 255)::STRING || '.' || ((s * 23) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 7/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.5.' || (s % 255)::STRING || '.' || ((s * 29) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 8/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.6.' || (s % 255)::STRING || '.' || ((s * 31) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 9/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.7.' || (s % 255)::STRING || '.' || ((s * 37) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 10/20 complete. Halfway!' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.8.' || (s % 255)::STRING || '.' || ((s * 41) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 11/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.9.' || (s % 255)::STRING || '.' || ((s * 43) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 12/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.10.' || (s % 255)::STRING || '.' || ((s * 47) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 13/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.11.' || (s % 255)::STRING || '.' || ((s * 53) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 14/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.12.' || (s % 255)::STRING || '.' || ((s * 59) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 15/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.13.' || (s % 255)::STRING || '.' || ((s * 61) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 16/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.14.' || (s % 255)::STRING || '.' || ((s * 67) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 17/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.15.' || (s % 255)::STRING || '.' || ((s * 71) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 18/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.16.' || (s % 255)::STRING || '.' || ((s * 73) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'audit_logs batch 19/20 complete.' AS progress;

INSERT INTO audit_logs (id, user_id, action, details, created_at)
SELECT gen_random_uuid(), (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    CASE (s % 7) WHEN 0 THEN 'login' WHEN 1 THEN 'logout' WHEN 2 THEN 'page_view' WHEN 3 THEN 'add_to_cart' WHEN 4 THEN 'checkout' WHEN 5 THEN 'update_profile' WHEN 6 THEN 'password_change' END,
    jsonb_build_object('ip', '10.17.' || (s % 255)::STRING || '.' || ((s * 79) % 255)::STRING, 'user_agent', 'Mozilla/5.0', 'session_id', gen_random_uuid()::STRING),
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'All 1,000,000 audit_logs inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3f. SESSIONS - 200K rows (batches of 50K)
-- ---------------------------------------------------------------------------
SELECT 'Inserting sessions (200,000 rows in batches of 50,000)...' AS progress;

INSERT INTO sessions (id, user_id, token, last_active_at, created_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    encode(gen_random_uuid()::BYTES, 'hex') || encode(gen_random_uuid()::BYTES, 'hex'),
    now() - (random() * INTERVAL '90 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;
SELECT 'sessions batch 1/4 complete.' AS progress;

INSERT INTO sessions (id, user_id, token, last_active_at, created_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    encode(gen_random_uuid()::BYTES, 'hex') || encode(gen_random_uuid()::BYTES, 'hex'),
    now() - (random() * INTERVAL '90 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;
SELECT 'sessions batch 2/4 complete.' AS progress;

INSERT INTO sessions (id, user_id, token, last_active_at, created_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    encode(gen_random_uuid()::BYTES, 'hex') || encode(gen_random_uuid()::BYTES, 'hex'),
    now() - (random() * INTERVAL '90 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;
SELECT 'sessions batch 3/4 complete.' AS progress;

INSERT INTO sessions (id, user_id, token, last_active_at, created_at)
SELECT
    gen_random_uuid(),
    (SELECT id FROM users ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    encode(gen_random_uuid()::BYTES, 'hex') || encode(gen_random_uuid()::BYTES, 'hex'),
    now() - (random() * INTERVAL '90 days'),
    now() - (random() * INTERVAL '365 days')
FROM generate_series(1, 50000) AS s;
SELECT 'All 200,000 sessions inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3g. PAYMENTS - 500K rows (batches of 50K)
-- ---------------------------------------------------------------------------
-- Note: payments uses unique_rowid() PK which is monotonic -- this is
-- INTENTIONAL for the hotspot demo. In production you would use UUID.

SELECT 'Inserting payments (500,000 rows in batches of 50,000)...' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 49999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5)
        WHEN 0 THEN 'credit_card'
        WHEN 1 THEN 'debit_card'
        WHEN 2 THEN 'paypal'
        WHEN 3 THEN 'bank_transfer'
        WHEN 4 THEN 'crypto'
    END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 1/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 99999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 2/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 149999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 3/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 199999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 4/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 249999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 5/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 299999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 6/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 349999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 7/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 399999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 8/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 449999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'payments batch 9/10 complete.' AS progress;

INSERT INTO payments (order_id, amount, method, processed_at)
SELECT
    (SELECT id FROM orders ORDER BY id LIMIT 1 OFFSET (random() * 499999)::INT),
    round((random() * 999 + 1)::DECIMAL, 2),
    CASE (s % 5) WHEN 0 THEN 'credit_card' WHEN 1 THEN 'debit_card' WHEN 2 THEN 'paypal' WHEN 3 THEN 'bank_transfer' WHEN 4 THEN 'crypto' END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'All 500,000 payments inserted.' AS progress;


-- ---------------------------------------------------------------------------
-- 3h. INVENTORY_MOVEMENTS - 1M rows (batches of 50K, 20 batches)
-- ---------------------------------------------------------------------------
SELECT 'Inserting inventory_movements (1,000,000 rows in batches of 50,000)...' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT
    (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT,  -- 10 warehouses
    CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 1/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 2/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 3/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 4/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 5/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 6/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 7/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 8/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 9/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 10/20 complete. Halfway!' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 11/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 12/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 13/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 14/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 15/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 16/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 17/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 18/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'inventory_movements batch 19/20 complete.' AS progress;

INSERT INTO inventory_movements (product_id, warehouse_id, quantity_change, created_at)
SELECT (SELECT id FROM products ORDER BY id LIMIT 1 OFFSET (random() * 9999)::INT),
    (random() * 9 + 1)::INT, CASE WHEN random() < 0.6 THEN (random() * 100 + 1)::INT ELSE -(random() * 50 + 1)::INT END,
    now() - (random() * INTERVAL '730 days')
FROM generate_series(1, 50000) AS s;
SELECT 'All 1,000,000 inventory_movements inserted.' AS progress;


-- =============================================================================
-- Step 4: Verify row counts
-- =============================================================================
SELECT 'Verifying row counts...' AS progress;

SELECT
    'users' AS table_name, count(*) AS row_count FROM users
UNION ALL SELECT
    'products', count(*) FROM products
UNION ALL SELECT
    'orders', count(*) FROM orders
UNION ALL SELECT
    'order_items', count(*) FROM order_items
UNION ALL SELECT
    'audit_logs', count(*) FROM audit_logs
UNION ALL SELECT
    'sessions', count(*) FROM sessions
UNION ALL SELECT
    'payments', count(*) FROM payments
UNION ALL SELECT
    'inventory_movements', count(*) FROM inventory_movements
ORDER BY table_name;

-- =============================================================================
-- Step 5: Collect table statistics for the query optimizer
-- =============================================================================
SELECT 'Collecting table statistics (this helps the optimizer make good plans)...' AS progress;

ANALYZE users;
ANALYZE products;
ANALYZE orders;
ANALYZE order_items;
ANALYZE audit_logs;
ANALYZE sessions;
ANALYZE payments;
ANALYZE inventory_movements;

SELECT '======================================================' AS status;
SELECT 'Schema setup and data population complete!' AS status;
SELECT 'Next step: Run 01-create-bad-indexes.sql' AS status;
SELECT '======================================================' AS status;
