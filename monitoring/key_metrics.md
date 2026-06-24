# Key Metrics — saas-billing-db

## Overview

Five categories of metrics matter for this schema in production: cache
health, index health, replication health, connection health, and table
bloat — specifically on `invoices`, which never shrinks.

Each section below gives the query to check the metric, the healthy range,
and what an unhealthy reading means.

---

## 1. Cache hit ratio

### What it measures

The percentage of data block reads served from Postgres's shared buffer
cache versus read from disk. A low ratio means the working set doesn't fit
in memory and the database is doing physical I/O for queries that should be
served from RAM.

### Query

```sql
SELECT
    sum(heap_blks_hit)                                          AS cache_hits,
    sum(heap_blks_read)                                         AS disk_reads,
    round(
        sum(heap_blks_hit)::numeric /
        nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100,
    2)                                                           AS cache_hit_ratio
FROM pg_statio_user_tables;
```

### Healthy range

| Ratio | Status |
|---|---|
| > 99% | Healthy — typical for a well-resourced production instance |
| 95–99% | Acceptable, worth monitoring trend |
| < 95% | Investigate — `shared_buffers` may be undersized, or a query is scanning far more data than expected |

### Per-table breakdown (useful when the aggregate looks fine but one table is the problem)

```sql
SELECT
    relname,
    heap_blks_hit,
    heap_blks_read,
    round(
        heap_blks_hit::numeric /
        nullif(heap_blks_hit + heap_blks_read, 0) * 100,
    2) AS cache_hit_ratio
FROM pg_statio_user_tables
ORDER BY heap_blks_read DESC
LIMIT 10;
```

---

## 2. Index usage

### What it measures

Whether queries are actually using the indexes created in Phase 2, and
whether any index is dead weight — never used, only adding write overhead.

### Index hit ratio (index scans vs sequential scans, per table)

```sql
SELECT
    relname,
    seq_scan,
    idx_scan,
    round(
        idx_scan::numeric / nullif(seq_scan + idx_scan, 0) * 100,
    2) AS pct_via_index
FROM pg_stat_user_tables
ORDER BY seq_scan DESC;
```

**Healthy:** `pct_via_index` should be high (>90%) for `invoices`,
`subscriptions`, and `api_usage_events` once data volume grows past seed
scale. Recall from Phase 2 that Postgres correctly prefers `Seq Scan` on
small tables — this metric becomes meaningful as row counts increase, not
at seed scale.

### Unused indexes

Indexes that have never been used are pure write overhead with zero query
benefit. Candidates for removal.

```sql
SELECT
    relname  AS table_name,
    indexrelname AS index_name,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Caution:** an index with `idx_scan = 0` shortly after creation is expected
— it hasn't had a chance to be used yet, or the table is too small for the
planner to choose it (per Phase 2 findings). Only act on this after the
database has handled meaningful production traffic for at least a few
weeks, and cross-reference against `queries/README.md` to confirm the
index isn't intentionally reserved for a query pattern that hasn't run yet.

---

## 3. Replication lag

### What it measures

How far behind the standby is from the primary — covered in depth in
`docs/replication_setup.md`. Repeated here as a metric to monitor
continuously rather than just check during setup or failover.

### Query (run on primary)

```sql
SELECT
    application_name,
    state,
    sync_state,
    write_lag,
    flush_lag,
    replay_lag,
    pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

### Healthy range

| Metric | Healthy | Investigate |
|---|---|---|
| `replay_lag` | < 1 second, often NULL (no lag) | > 5 seconds sustained |
| `state` | `streaming` | anything else |
| `sync_state` | `sync` | `async` (means synchronous_standby_names mismatch) |
| `lag_bytes` | low, stable | growing trend over time |

A `sync_state` of `async` when synchronous replication is expected means the
standby's `application_name` doesn't match `synchronous_standby_names` on
the primary — this is a configuration bug, not a performance issue, and
breaks the zero-data-loss guarantee silently.

---

## 4. Connection health

### What it measures

Whether pgBouncer's pool sizing (Phase 6) is holding up under real load, and
whether the application is leaking idle-in-transaction connections.

### Connection state breakdown

```sql
SELECT
    state,
    count(*)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY state
ORDER BY count(*) DESC;
```

### Healthy range

| State | Healthy | Investigate |
|---|---|---|
| `active` | proportional to load | sustained high count near `max_connections` |
| `idle` | normal — pooled connections waiting | — |
| `idle in transaction` | near zero | any sustained count — indicates app code not committing/rolling back |
| `idle in transaction (aborted)` | zero | any count — app not handling errors correctly |

### Longest-running idle-in-transaction sessions

This is the single most common cause of connection pool exhaustion in
production — a transaction opened and never closed, holding a Postgres
connection (and potentially locks) indefinitely.

```sql
SELECT
    pid,
    usename,
    application_name,
    state,
    now() - state_change AS idle_duration,
    query
FROM pg_stat_activity
WHERE state = 'idle in transaction'
ORDER BY idle_duration DESC;
```

Anything over a few minutes here should be investigated and likely
terminated:

```sql
SELECT pg_terminate_backend(<pid>);
```

### Connections vs pgBouncer pool size

Cross-reference with Phase 6 — total active connections should never exceed
the configured `default_pool_size * app_server_instances` from
`pgbouncer_setup.md` (90 in that configuration). If `pg_stat_activity` shows
more than that, something is bypassing pgBouncer and connecting directly.

---

## 5. Table bloat — invoices

### What it measures

`invoices` is append-only and partitioned (Phase 7), but `UPDATE` operations
still happen on it indirectly through the audit trigger path is not
relevant here — invoices themselves are never updated post-Phase-4 except
for the `status` transition, which `IS` an UPDATE. Every status change
creates a dead tuple. Over years of operation, accumulated dead tuples
inflate table size and slow down sequential scans on partitions that
`VACUUM` hasn't caught up with.

### Query — bloat estimate per partition

```sql
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    round(
        n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100,
    2) AS pct_dead,
    last_autovacuum,
    last_vacuum
FROM pg_stat_user_tables
WHERE relname LIKE 'invoices%'
ORDER BY n_dead_tup DESC;
```

### Healthy range

| `pct_dead` | Status |
|---|---|
| < 10% | Healthy |
| 10–20% | Monitor — autovacuum should catch up on its own |
| > 20% | Investigate — autovacuum may be falling behind, or a partition is receiving more status-change updates than expected |

### Why older invoice partitions should trend toward zero dead tuples

Once an invoice reaches a terminal status (`paid`, `void`, `uncollectible`)
it never changes again — by the append-only design from Phase 1. A
partition for a month that closed long ago should have `n_dead_tup` static
or only decreasing (as `VACUUM` reclaims space), never growing. If an old
partition's dead tuple count is climbing, something is performing
unexpected updates against historical invoice data — a bug worth
investigating immediately given the financial integrity requirements
documented in Phase 1.

### Forcing a manual vacuum (use sparingly — autovacuum should handle this)

```sql
VACUUM (VERBOSE, ANALYZE) invoices_2025_04;
```

Run against a specific partition, not the whole partitioned table, to keep
the operation scoped and avoid locking unrelated partitions.

---

## Putting it together — a daily health check

```sql
-- 1. Cache hit ratio
SELECT round(sum(heap_blks_hit)::numeric / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0) * 100, 2) AS cache_hit_ratio FROM pg_statio_user_tables;

-- 2. Replication lag
SELECT application_name, state, sync_state, replay_lag FROM pg_stat_replication;

-- 3. Idle-in-transaction count
SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction';

-- 4. Dead tuple percentage on the current month's invoice partition
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'invoices_2025_04';
```

Five queries, run in under a second, give a complete picture of database
health. This is the baseline a monitoring dashboard (Grafana + pg_exporter,
or RDS Performance Insights / CloudSQL Insights in production) should
surface continuously rather than checking manually.