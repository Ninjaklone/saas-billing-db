# Partitioning Guide — saas-billing-db

## Why these tables are partitioned

`invoices` and `api_usage_events` are the only two tables in this schema
that grow without bound. Every other table has a natural ceiling tied to
the number of customers — tenants, plans, users, subscriptions all stop
growing once tenant acquisition slows. Invoices and usage events accumulate
indefinitely as long as the platform is running.

Both are partitioned by month using declarative range partitioning —
`invoices` on `created_at`, `api_usage_events` on `recorded_at`.

---

## Partition strategy

### Why monthly

Monthly partitions align with billing cycles, which is the natural query
boundary for both tables. A revenue report for April touches exactly one
invoice partition. A usage report for a tenant's billing period touches at
most two partitions if the period crosses a month boundary.

Weekly partitions would require touching multiple partitions for the same
query with no benefit. Daily partitions would produce 365 partitions per
year, which is more than the query planner handles efficiently and more
than is operationally manageable.

### Partition naming

```
invoices_YYYY_MM

api_usage_events_YYYY_MM
```

Example: `invoices_2025_04` covers `2025-04-01` through `2025-04-30`
inclusive, exclusive of `2025-05-01`.

### Boundaries created

- Historical: `2023-01` through `2024-12`
- Current and near future: `2025-01` through `2025-09` (3 months ahead of
  the migration date)
- Default partition: catches anything outside the explicit ranges

---

## How partition pruning works

When a query filters on the partition key, Postgres only scans the
partitions that could contain matching rows — every other partition is
skipped entirely. This is the entire performance benefit of partitioning.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM invoices
WHERE created_at >= '2025-04-01'
  AND created_at <  '2025-05-01';
```

Expected plan:
```
Seq Scan on invoices_2025_04

Filter: (created_at >= '2025-04-01' AND created_at < '2025-05-01')
```

Only `invoices_2025_04` appears in the plan. No other partition is touched.
If the plan shows a scan across multiple partitions or the parent table
itself, the query is not using a sargable filter on the partition key —
check that you didn't write the date comparison wrapped in a function like
`date_trunc()` directly on the column, which can defeat pruning.

### What defeats pruning

```sql
-- BAD — wraps the partition key in a function, defeats pruning
WHERE date_trunc('month', created_at) = '2025-04-01'

-- GOOD — direct range comparison on the partition key
WHERE created_at >= '2025-04-01' AND created_at < '2025-05-01'
```

Always filter with a direct range comparison on the raw column. Computed
expressions on the partition key force Postgres to scan every partition
because it cannot determine which partitions satisfy the expression without
evaluating it row by row.

---

## Verifying the default partition is empty

The default partition should always be empty in normal operation. Any rows
in it mean partition creation has fallen behind.

```sql
SELECT COUNT(*) FROM invoices
WHERE tableoid::regclass::text = 'invoices_default';

SELECT COUNT(*) FROM api_usage_events
WHERE tableoid::regclass::text = 'api_usage_events_default';
```

Both should return `0`. Check this monthly alongside partition creation.

---

## Adding a new partition

Run on the first of each month, creating the partition three months ahead.
This buffer means a missed scheduled job does not cause immediate failures —
data falls into the default partition only after three consecutive missed
months.

```sql
CREATE TABLE invoices_2025_10 PARTITION OF invoices
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

CREATE TABLE api_usage_events_2025_10 PARTITION OF api_usage_events
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
```

No index or constraint statements are needed — both are created on the
parent table and apply automatically to every partition, including ones
created after the indexes were defined.

### Automating with pg_cron

```sql
SELECT cron.schedule(
    'create-monthly-partitions',
    '0 0 1 * *',  -- midnight on the first of every month
    $$
    CREATE TABLE IF NOT EXISTS invoices_2025_10 PARTITION OF invoices
        FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
    CREATE TABLE IF NOT EXISTS api_usage_events_2025_10 PARTITION OF api_usage_events
        FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
    $$
);
```

The actual date values need to be generated dynamically rather than
hardcoded — in production this lives in a small wrapper function or an
Airflow DAG task rather than a static cron string. The static version above
is illustrative.

---

## Recovering rows from the default partition

If the default partition has accumulated rows because a scheduled partition
was missed, move them once the correct partition exists.

```sql
-- 1. Create the partition that should have existed
CREATE TABLE invoices_2025_10 PARTITION OF invoices
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- 2. Move matching rows out of the default partition
WITH moved AS (
    DELETE FROM invoices_default
    WHERE created_at >= '2025-10-01' AND created_at < '2025-11-01'
    RETURNING *
)
INSERT INTO invoices SELECT * FROM moved;
```

Postgres automatically routes the re-inserted rows into the correct
partition based on `created_at`.

---

## Dropping old partitions

Partitions can be detached and archived without touching live data or
locking the parent table for more than a moment.

```sql
-- Detach — instant, does not delete the data
ALTER TABLE invoices DETACH PARTITION invoices_2023_01;

-- The detached table is now a normal standalone table.
-- Archive it (export to S3, cold storage, etc.) then drop it.
DROP TABLE invoices_2023_01;
```

Detach before drop, never drop directly. Detaching gives you a window to
confirm the data was archived correctly before it is gone for good — this
matters more for `invoices` than `api_usage_events` given the append-only
financial record requirement. In practice, invoice partitions should be
archived to cold storage, not dropped, to satisfy long-term audit retention.

---

## Cost-performance notes

At seed-data scale, the difference between partitioned and unpartitioned
queries is unmeasurable — both complete in microseconds. The benefit is
entirely about behavior at scale:

An unpartitioned `invoices` table with 10 million rows scans all 10 million
rows (or relies entirely on index efficiency) for any query, and `VACUUM`
has to process the whole table in one pass. A partitioned table with the
same 10 million rows split across 36 monthly partitions means a single-month
query scans roughly 280,000 rows — the partition for that month only — and
`VACUUM` can process partitions independently, often skipping old partitions
entirely if they have no new dead tuples.

The other practical benefit is retention. Dropping a year-old partition is
an instant metadata operation. Deleting a year of rows from an unpartitioned
table is a slow, lock-heavy `DELETE` that generates a large amount of WAL
and leaves bloat behind for `VACUUM` to clean up.