-- =============================================================================
-- 01-cluster-health.sql
-- CockroachDB Cost Optimization Toolkit
-- Category: Basic Cluster Health
-- =============================================================================
--
-- PURPOSE:
--   Verify that the cluster is healthy before diving into optimization.
--   An unhealthy cluster (down nodes, under-replicated ranges, version skew)
--   will produce misleading diagnostic results.
--
-- PREREQUISITES:
--   - Admin SQL user
--   - CockroachDB v22.2+
--
-- All queries are read-only.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 1. Node Status and Resource Utilization
-- ---------------------------------------------------------------------------
-- Shows every node in the cluster, whether it is live, and basic resource info.
--
-- WHAT TO LOOK FOR:
--   - All nodes should show is_live = true.
--   - If any node is not live, investigate before proceeding (the cluster is
--     already in an unhealthy state).
--   - Large imbalances in ranges across nodes may indicate rebalancing issues.
--   - Check the build_tag to confirm all nodes are on the same version.

SELECT
    node_id,
    address,
    sql_address,
    build_tag,
    started_at,
    is_live,
    locality,
    is_decommissioning,
    membership
FROM crdb_internal.gossip_liveness
ORDER BY node_id;


-- ---------------------------------------------------------------------------
-- 2. Range Distribution per Node
-- ---------------------------------------------------------------------------
-- Shows how many ranges (data chunks) each node holds. Even distribution means
-- the cluster is well-balanced.
--
-- WHAT TO LOOK FOR:
--   - All nodes should have roughly the same number of ranges.
--   - A node with significantly more ranges may be a hotspot or may not be
--     rebalancing properly.
--   - A node with zero ranges may have just joined or may be decommissioning.
--
-- EXAMPLE OUTPUT:
--   node_id | range_count
--   --------+------------
--         1 |       4200
--         2 |       4180
--         3 |       4210
--   (Roughly equal = healthy)

SELECT
    lease_holder                        AS node_id,
    COUNT(*)                            AS range_count
FROM crdb_internal.ranges_no_leases
GROUP BY lease_holder
ORDER BY lease_holder;


-- ---------------------------------------------------------------------------
-- 3. Replica Distribution per Node (all replicas, not just leaseholders)
-- ---------------------------------------------------------------------------
-- A more complete picture: counts every replica (not just lease holders)
-- hosted by each node.
--
-- WHAT TO LOOK FOR:
--   - Even replica distribution across all nodes.
--   - If one node has significantly more replicas, check zone configs and
--     rebalancing settings.

SELECT
    unnest(replicas)                     AS node_id,
    COUNT(*)                             AS replica_count
FROM crdb_internal.ranges_no_leases
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------------
-- 4. Cluster Version Check
-- ---------------------------------------------------------------------------
-- Verifies all nodes are running the same CockroachDB version.
--
-- WHAT TO LOOK FOR:
--   - A single row means all nodes are on the same version (good).
--   - Multiple rows indicate a mixed-version cluster. Finish the upgrade
--     before optimizing -- mixed versions can cause unexpected plan choices.

SELECT
    build_tag                            AS version,
    COUNT(*)                             AS node_count
FROM crdb_internal.gossip_liveness
GROUP BY build_tag
ORDER BY build_tag;


-- ---------------------------------------------------------------------------
-- 5. Under-Replicated and Unavailable Ranges
-- ---------------------------------------------------------------------------
-- Critical health check. Under-replicated ranges mean data is at risk.
-- Unavailable ranges mean reads/writes to that data will fail.
--
-- WHAT TO LOOK FOR:
--   - Both counts should be 0 in a healthy cluster.
--   - If under_replicated_ranges > 0, a node may be down or disk may be full.
--   - If unavailable_ranges > 0, the cluster is in a degraded state -- fix
--     this before doing any optimization work.

SELECT
    SUM(CASE WHEN array_length(replicas, 1) < desired_range_size THEN 1 ELSE 0 END)
        AS under_replicated_ranges,
    COUNT(*)                             AS total_ranges
FROM crdb_internal.ranges_no_leases;


-- ---------------------------------------------------------------------------
-- 6. Cluster Settings Snapshot (Key Cost-Related Settings)
-- ---------------------------------------------------------------------------
-- Captures the current values of settings that directly impact cost and
-- performance. Useful as a baseline before making changes.
--
-- WHAT TO LOOK FOR:
--   - kv.rangefeed.enabled: should be true only if you use changefeeds.
--   - sql.stats.automatic_collection.enabled: should be true for good plans.
--   - admission.enabled: should be true for workload isolation.

SELECT
    variable,
    value,
    description
FROM [SHOW ALL CLUSTER SETTINGS]
WHERE variable IN (
    'kv.rangefeed.enabled',
    'sql.stats.automatic_collection.enabled',
    'kv.range_split.by_load_enabled',
    'admission.enabled',
    'server.time_until_store_dead',
    'kv.snapshot_rebalance.max_rate'
)
ORDER BY variable;


-- =============================================================================
-- END OF 01-cluster-health.sql
-- =============================================================================
