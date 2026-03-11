# Connection Pooling Best Practices

Connection pooling is one of the most impactful and often overlooked cost optimization techniques for CockroachDB. Without proper pooling, applications create too many connections, which wastes compute resources and can force you to over-provision the cluster.

## The Core Rule

**Keep active SQL connections at or below 4 per vCPU across the cluster.**

This is not the total number of connections in the pool -- it is the number of connections **actively executing SQL** at any given moment.

| Cluster vCPUs (total) | Max Active Connections |
|---|---|
| 8 vCPUs (e.g., 2 nodes x 4 vCPU) | 32 |
| 16 vCPUs (e.g., 4 nodes x 4 vCPU) | 64 |
| 32 vCPUs (e.g., 4 nodes x 8 vCPU) | 128 |
| 64 vCPUs (e.g., 8 nodes x 8 vCPU) | 256 |

Going beyond this threshold causes contention, context switching overhead, and increased tail latency -- all of which push you toward over-provisioning.

## Pool Sizing Formula

```
max_pool_size = (total_cluster_vCPUs * 4) / number_of_application_instances
```

### Example

- Cluster: 4 nodes, 8 vCPUs each = 32 total vCPUs
- Target active connections: 32 * 4 = 128
- Application instances: 8 pods/servers
- Max pool size per instance: 128 / 8 = **16 connections per app instance**

### Accounting for Headroom

In practice, not all pooled connections are active simultaneously. A good starting point:

```
pool_size = max_active_per_instance * 1.5

Example: 16 * 1.5 = 24 connections in the pool (16 active, 8 idle headroom)
```

## Configuration Examples

### HikariCP (Java / Spring Boot)

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 16
      minimum-idle: 4
      idle-timeout: 300000          # 5 minutes
      max-lifetime: 1800000         # 30 minutes
      connection-timeout: 10000     # 10 seconds
      validation-timeout: 5000     # 5 seconds
```

### pgBouncer

```ini
[databases]
mydb = host=cockroachdb-lb port=26257 dbname=mydb

[pgbouncer]
pool_mode = transaction
max_client_conn = 200
default_pool_size = 16
min_pool_size = 4
reserve_pool_size = 4
reserve_pool_timeout = 3
server_idle_timeout = 300
server_lifetime = 1800
```

Key settings:
- `pool_mode = transaction`: connections are returned to the pool after each transaction (not each session). This is the recommended mode for CockroachDB.
- `default_pool_size`: matches your per-instance calculation above.
- `max_client_conn`: total connections pgBouncer will accept from all application instances.

### Node.js (node-postgres / pg)

```javascript
const { Pool } = require('pg');

const pool = new Pool({
  host: 'cockroachdb-lb',
  port: 26257,
  database: 'mydb',
  user: 'app_user',
  ssl: { rejectUnauthorized: true },
  max: 16,                    // max connections in pool
  idleTimeoutMillis: 300000,  // 5 minutes
  connectionTimeoutMillis: 10000,
});
```

### Python (psycopg2 + SQLAlchemy)

```python
from sqlalchemy import create_engine

engine = create_engine(
    "cockroachdb://app_user@cockroachdb-lb:26257/mydb?sslmode=verify-full",
    pool_size=16,
    max_overflow=4,            # allow 4 extra connections under burst
    pool_timeout=10,
    pool_recycle=1800,         # recycle connections every 30 minutes
    pool_pre_ping=True,        # validate connections before use
)
```

### Go (pgx)

```go
config, _ := pgxpool.ParseConfig(
    "postgresql://app_user@cockroachdb-lb:26257/mydb?sslmode=verify-full",
)
config.MaxConns = 16
config.MinConns = 4
config.MaxConnLifetime = 30 * time.Minute
config.MaxConnIdleTime = 5 * time.Minute

pool, _ := pgxpool.NewWithConfig(context.Background(), config)
```

## Common Anti-Patterns

### 1. No Connection Pooling

Every request opens a new connection and closes it when done. TCP handshake + TLS + authentication on every request is extremely expensive.

**Fix**: Use a connection pool in every application.

### 2. Pool Size = Number of Application Threads

Setting pool size to match thread count (e.g., 200 threads = 200 connections) overwhelms the database.

**Fix**: Pool size should be based on cluster vCPUs, not application threads. Let threads wait for a connection from the pool.

### 3. Session-Mode pgBouncer

Using `pool_mode = session` keeps connections tied to a client for the entire session, not just the transaction. This defeats the purpose of pooling.

**Fix**: Use `pool_mode = transaction` for CockroachDB.

### 4. No Idle Connection Cleanup

Connections that sit idle for hours waste database resources.

**Fix**: Set `idle-timeout` and `max-lifetime` so connections are recycled regularly.

### 5. No Connection Validation

Stale connections (from node restarts, network blips) cause errors on first use.

**Fix**: Enable connection validation (`pool_pre_ping` in SQLAlchemy, `validation-timeout` in HikariCP).

## Monitoring Connection Usage

Use this SQL query to see current connection counts per application:

```sql
SELECT
    application_name,
    client_address,
    COUNT(*)                AS connection_count
FROM crdb_internal.cluster_sessions
GROUP BY application_name, client_address
ORDER BY connection_count DESC;
```

Compare the total connections against your cluster's vCPU count * 4. If you are consistently above this threshold, reduce pool sizes.

## Decision Tree

```
Is your cluster CPU > 60% average?
  |
  +-- YES --> Check connection count. Above 4 per vCPU?
  |             |
  |             +-- YES --> Reduce pool sizes first (cheapest fix)
  |             +-- NO  --> Queries may need optimization (see 02-query-performance.sql)
  |
  +-- NO  --> Check connection count. Above 4 per vCPU?
                |
                +-- YES --> You are over-connected but not yet bottlenecked.
                |           Reduce pool sizes to avoid future problems.
                +-- NO  --> Connection pooling is healthy.
```
