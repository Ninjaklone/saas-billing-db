# Slow Query Configuration — saas-billing-db

## Overview

Two complementary mechanisms are used to identify slow queries:

- **`pg_stat_statements`** — aggregate statistics across all query types,
  normalized (parameters stripped). Answers "which query *shape* is heaviest
  overall."
- **Slow query log** — logs the exact text of any individual statement that
  exceeds a duration threshold. Answers "what exactly ran, with what
  parameters, at 3:14am, that took 4 seconds."

Both are needed. `pg_stat_statements` will not show you the one tenant whose
specific filter caused a 30-second outlier; the slow query log will not show
you that a particular query shape runs 50,000 times a day and is responsible
for 80% of total database time even though no single execution is slow.

---

    ## pg_stat_statements setup

    ### Step 1 — enable via shared_preload_libraries

    Requires a restart, not just a reload.

    ```ini
    # postgresql.conf
    shared_preload_libraries = 'pg_stat_statements'

    pg_stat_statements.max          = 5000   -- number of distinct query shapes tracked
    pg_stat_statements.track        = top    -- top-level statements only, not nested
    pg_stat_statements.track_utility = off   -- exclude DDL/utility commands from tracking
    pg_stat_statements.save         = on     -- persist stats across restarts
    ```

    ```bash
    pg_ctl restart -D /var/lib/postgresql/data
    ```

    ### Step 2 — create the extension

    ```sql
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    ```

    ### Step 3 — verify it's collecting

    ```sql
    SELECT count(*) FROM pg_stat_statements;
    -- Should return > 0 after the database has handled some traffic
    ```

    ---

## Querying pg_stat_statements

### Top 10 queries by total execution time

The single most useful query — surfaces what's actually consuming database
time in aggregate, not just what's slow per-call.

```sql
SELECT
    query,
    calls,
    round(total_exec_time::numeric, 2)                 AS total_ms,
    round(mean_exec_time::numeric, 2)                  AS mean_ms,
    round((total_exec_time / sum(total_exec_time) OVER () * 100)::numeric, 2) AS pct_of_total
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

### Top 10 queries by mean execution time (with a minimum call count)

Filters out one-off slow queries to focus on consistently slow query shapes.

```sql
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2)  AS mean_ms,
    round(max_exec_time::numeric, 2)   AS max_ms
FROM pg_stat_statements
WHERE calls > 50
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### Queries with the widest variance between mean and max

High variance often means a query is fast for most tenants but pathological
for a few — a missing index on a skewed column, for example.

```sql
SELECT
    query,
    calls,
    round(mean_exec_time::numeric, 2) AS mean_ms,
    round(max_exec_time::numeric, 2)  AS max_ms,
    round((max_exec_time - mean_exec_time)::numeric, 2) AS variance_ms
FROM pg_stat_statements
WHERE calls > 10
ORDER BY variance_ms DESC
LIMIT 10;
```

### Reset statistics

Useful after a deployment to get a clean baseline for the new code.

```sql
SELECT pg_stat_statements_reset();
```

---

## Slow query log setup

### Configuration

```ini
# postgresql.conf
log_min_duration_statement = 200      -- log any statement over 200ms
log_line_prefix             = '%t [%p]: user=%u,db=%d,app=%a,client=%h '
log_statement               = 'none'  -- do not log all statements, only slow ones
log_duration                = off     -- redundant with log_min_duration_statement
```

**Why 200ms:** After Phase 2 indexing, the queries in this schema should
complete in single-digit milliseconds at any realistic data volume. A query
exceeding 200ms is either missing an index, scanning far more rows than
expected, or blocked waiting on a lock. 200ms is tight enough to catch
regressions early without flooding the log with noise from acceptable
variance.

Reload to apply (no restart needed for this setting):

```bash
pg_ctl reload -D /var/lib/postgresql/data
```

### Reading the log output

A logged slow query looks like:

```
2025-04-15 09:14:22 UTC [4821]: user=app_user,db=saas_billing,app=billing-api,client=10.0.1.4 LOG:  duration: 312.441 ms  statement: SELECT * FROM invoices WHERE tenant_id = $1 AND status = $2
```