# Query Performance Documentation

> **If you are reading this then run `EXPLAIN ANALYZE` on the main variant of
> each query and save the raw output. This will become the baseline. There will
> be no way to tell what difference the indexes make without a baseline.**

---

## How to run EXPLAIN ANALYZE

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) <query here>;
```

Run each query twice before saving — the first run will most likely show inflated times
due to a cold cache. Ideally, you would want to use the second run.

**Key signals to look for:**

| Signal | Meaning |
|---|---|
| `Seq Scan` | Full table scan — every row read regardless of filters |
| `Index Scan` | Postgres walked the index to fetch specific rows |
| `Rows Removed by Filter` | Rows scanned but discarded — wasted work |
| `actual time=X..Y` | Real execution time in milliseconds |
| `Buffers: shared hit=N` | Pages read from cache |

> At seed scale, absolute times will be microseconds regardless of indexes.
> This is just a show of plan shape — `Seq Scan` vs `Index Scan` — not
> the milliseconds. Plan shape is what determines performance at scale
> afterall.

---

## billing_summary.sql

Total revenue per tenant per billing period, restricted to paid invoices only.

**Correctness check:** Nomad Stack's uncollectible invoice and Pebble HR's
voided invoice must not appear in the output. If they do, the
`WHERE i.status = 'paid'` filter is missing.

### Before indexes

```
"Sort  (cost=41.38..41.39 rows=1 width=200) (actual time=0.116..0.117 rows=10 loops=1)"
"  Sort Key: t.name, (date_trunc('month'::text, i.created_at))"
"  Sort Method: quicksort  Memory: 25kB"
"  Buffers: shared hit=42"
"  ->  GroupAggregate  (cost=41.33..41.37 rows=1 width=200) (actual time=0.088..0.094 rows=10 loops=1)"
"        Group Key: (date_trunc('month'::text, i.created_at)), t.id, p.name, p.billing_cycle"
"        Buffers: shared hit=42"
"        ->  Sort  (cost=41.33..41.34 rows=1 width=172) (actual time=0.082..0.083 rows=10 loops=1)"
"              Sort Key: (date_trunc('month'::text, i.created_at)), t.id, p.name, p.billing_cycle"
"              Sort Method: quicksort  Memory: 25kB"
"              Buffers: shared hit=42"
"              ->  Nested Loop  (cost=34.47..41.32 rows=1 width=172) (actual time=0.061..0.076 rows=10 loops=1)"
"                    Buffers: shared hit=42"
"                    ->  Nested Loop  (cost=34.32..41.07 rows=1 width=124) (actual time=0.052..0.060 rows=10 loops=1)"
"                          Buffers: shared hit=22"
"                          ->  Merge Join  (cost=34.17..34.21 rows=1 width=124) (actual time=0.044..0.047 rows=10 loops=1)"
"                                Merge Cond: (i.tenant_id = t.id)"
"                                Buffers: shared hit=2"
"                                ->  Sort  (cost=17.65..17.66 rows=3 width=60) (actual time=0.022..0.023 rows=12 loops=1)"
"                                      Sort Key: i.tenant_id"
"                                      Sort Method: quicksort  Memory: 25kB"
"                                      Buffers: shared hit=1"
"                                      ->  Seq Scan on invoices i  (cost=0.00..17.62 rows=3 width=60) (actual time=0.009..0.012 rows=12 loops=1)"
"                                            Filter: (status = 'paid'::text)"
"                                            Rows Removed by Filter: 4"
"                                            Buffers: shared hit=1"
"                                ->  Sort  (cost=16.52..16.53 rows=3 width=80) (actual time=0.020..0.020 rows=6 loops=1)"
"                                      Sort Key: t.id"
"                                      Sort Method: quicksort  Memory: 25kB"
"                                      Buffers: shared hit=1"
"                                      ->  Seq Scan on tenants t  (cost=0.00..16.50 rows=3 width=80) (actual time=0.004..0.005 rows=7 loops=1)"
"                                            Filter: (deleted_at IS NULL)"
"                                            Rows Removed by Filter: 1"
"                                            Buffers: shared hit=1"
"                          ->  Index Scan using subscriptions_pkey on subscriptions s  (cost=0.15..6.83 rows=1 width=32) (actual time=0.001..0.001 rows=1 loops=10)"
"                                Index Cond: (id = i.subscription_id)"
"                                Buffers: shared hit=20"
"                    ->  Index Scan using plans_pkey on plans p  (cost=0.15..0.25 rows=1 width=80) (actual time=0.001..0.001 rows=1 loops=10)"
"                          Index Cond: (id = s.plan_id)"
"                          Buffers: shared hit=20"
"Planning:"
"  Buffers: shared hit=4"
"Planning Time: 0.273 ms"
"Execution Time: 0.163 ms"
```

### After indexes

```
"Sort  (cost=5.36..5.39 rows=10 width=112) (actual time=0.090..0.091 rows=10 loops=1)"
"  Sort Key: t.name, (date_trunc('month'::text, i.created_at))"
"  Sort Method: quicksort  Memory: 25kB"
"  Buffers: shared hit=4"
"  ->  HashAggregate  (cost=5.00..5.20 rows=10 width=112) (actual time=0.064..0.068 rows=10 loops=1)"
"        Group Key: date_trunc('month'::text, i.created_at), t.id, p.name, p.billing_cycle"
"        Batches: 1  Memory Usage: 24kB"
"        Buffers: shared hit=4"
"        ->  Hash Join  (cost=3.48..4.85 rows=10 width=84) (actual time=0.049..0.056 rows=10 loops=1)"
"              Hash Cond: (s.plan_id = p.id)"
"              Buffers: shared hit=4"
"              ->  Hash Join  (cost=2.35..3.64 rows=10 width=85) (actual time=0.026..0.031 rows=10 loops=1)"
"                    Hash Cond: (i.subscription_id = s.id)"
"                    Buffers: shared hit=3"
"                    ->  Hash Join  (cost=1.17..2.42 rows=10 width=85) (actual time=0.016..0.020 rows=10 loops=1)"
"                          Hash Cond: (i.tenant_id = t.id)"
"                          Buffers: shared hit=2"
"                          ->  Seq Scan on invoices i  (cost=0.00..1.20 rows=12 width=60) (actual time=0.004..0.005 rows=12 loops=1)"
"                                Filter: (status = 'paid'::text)"
"                                Rows Removed by Filter: 4"
"                                Buffers: shared hit=1"
"                          ->  Hash  (cost=1.08..1.08 rows=7 width=41) (actual time=0.006..0.006 rows=7 loops=1)"
"                                Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                                Buffers: shared hit=1"
"                                ->  Seq Scan on tenants t  (cost=0.00..1.08 rows=7 width=41) (actual time=0.005..0.005 rows=7 loops=1)"
"                                      Filter: (deleted_at IS NULL)"
"                                      Rows Removed by Filter: 1"
"                                      Buffers: shared hit=1"
"                    ->  Hash  (cost=1.08..1.08 rows=8 width=32) (actual time=0.005..0.005 rows=8 loops=1)"
"                          Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                          Buffers: shared hit=1"
"                          ->  Seq Scan on subscriptions s  (cost=0.00..1.08 rows=8 width=32) (actual time=0.003..0.003 rows=8 loops=1)"
"                                Buffers: shared hit=1"
"              ->  Hash  (cost=1.06..1.06 rows=6 width=31) (actual time=0.012..0.012 rows=6 loops=1)"
"                    Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                    Buffers: shared hit=1"
"                    ->  Seq Scan on plans p  (cost=0.00..1.06 rows=6 width=31) (actual time=0.007..0.008 rows=6 loops=1)"
"                          Buffers: shared hit=1"
"Planning:"
"  Buffers: shared hit=67"
"Planning Time: 0.466 ms"
"Execution Time: 0.148 ms"
```

### Interpretation

```
The indexes were not used on any table — at 16 invoice rows and 7 tenant rows, every table fits in a single buffer page and a sequential scan is always cheaper than an index lookup at this scale. Postgres made the correct call.
What did improve was the join strategy. If you noticed before indexes the planner used Merge Join between invoices and tenants, which required sorting both sides first — two extra Sort nodes. After indexes the planner had better row estimates and switched to Hash Join throughout, eliminating both sort steps. Total buffer reads dropped from 42 to 4. Execution time dropped from 0.163ms to 0.148ms.
The correctness check passes — Rows Removed by Filter: 4 on the invoices scan confirms the 4 non-paid invoices (Nomad Stack's uncollectible, Pebble HR's void, and 2 open invoices) were discarded correctly. Neither appears in the output.
At production scale with 500k+ invoice rows, invoices_tenant_status_idx will replace the Seq Scan with an Index Scan fetching only the paid bucket. The plan shape changes completely at that point, for those that might not understand this index is not redundant,
it simply has nothing to do yet.
```

---

## invoice_history.sql

Full invoice timeline per tenant across all statuses.

**Correctness check:** Drifter Tools has no invoices and must still appear in
results with NULL invoice fields. If it is missing, the `LEFT JOIN` has been
changed to an `INNER JOIN` somewhere.

### Before indexes

```
"Sort  (cost=53.12..53.13 rows=3 width=288) (actual time=0.098..0.099 rows=17 loops=1)"
"  Sort Key: t.name, s.created_at, i.created_at"
"  Sort Method: quicksort  Memory: 27kB"
"  Buffers: shared hit=35"
"  ->  Nested Loop Left Join  (cost=34.06..53.10 rows=3 width=288) (actual time=0.052..0.069 rows=17 loops=1)"
"        Buffers: shared hit=35"
"        ->  Hash Right Join  (cost=33.91..52.33 rows=3 width=208) (actual time=0.041..0.047 rows=17 loops=1)"
"              Hash Cond: (i.subscription_id = s.id)"
"              Buffers: shared hit=3"
"              ->  Seq Scan on invoices i  (cost=0.00..16.10 rows=610 width=88) (actual time=0.002..0.003 rows=16 loops=1)"
"                    Buffers: shared hit=1"
"              ->  Hash  (cost=33.87..33.87 rows=3 width=136) (actual time=0.033..0.033 rows=8 loops=1)"
"                    Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                    Buffers: shared hit=2"
"                    ->  Hash Right Join  (cost=16.54..33.87 rows=3 width=136) (actual time=0.026..0.030 rows=8 loops=1)"
"                          Hash Cond: (s.tenant_id = t.id)"
"                          Buffers: shared hit=2"
"                          ->  Seq Scan on subscriptions s  (cost=0.00..15.80 rows=580 width=104) (actual time=0.003..0.004 rows=8 loops=1)"
"                                Buffers: shared hit=1"
"                          ->  Hash  (cost=16.50..16.50 rows=3 width=48) (actual time=0.017..0.017 rows=7 loops=1)"
"                                Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                                Buffers: shared hit=1"
"                                ->  Seq Scan on tenants t  (cost=0.00..16.50 rows=3 width=48) (actual time=0.011..0.013 rows=7 loops=1)"
"                                      Filter: (deleted_at IS NULL)"
"                                      Rows Removed by Filter: 1"
"                                      Buffers: shared hit=1"
"        ->  Index Scan using plans_pkey on plans p  (cost=0.15..0.25 rows=1 width=80) (actual time=0.001..0.001 rows=1 loops=17)"
"              Index Cond: (id = s.plan_id)"
"              Buffers: shared hit=32"
"Planning Time: 0.187 ms"
"Execution Time: 0.143 ms"
```

### After indexes

```
"Sort  (cost=5.20..5.24 rows=14 width=169) (actual time=0.083..0.085 rows=17 loops=1)"
"  Sort Key: t.name, s.created_at, i.created_at"
"  Sort Method: quicksort  Memory: 27kB"
"  Buffers: shared hit=4"
"  ->  Hash Left Join  (cost=3.48..4.94 rows=14 width=169) (actual time=0.043..0.056 rows=17 loops=1)"
"        Hash Cond: (s.plan_id = p.id)"
"        Buffers: shared hit=4"
"        ->  Hash Right Join  (cost=2.35..3.64 rows=14 width=138) (actual time=0.029..0.040 rows=17 loops=1)"
"              Hash Cond: (s.tenant_id = t.id)"
"              Buffers: shared hit=3"
"              ->  Hash Right Join  (cost=1.18..2.40 rows=16 width=125) (actual time=0.013..0.020 rows=18 loops=1)"
"                    Hash Cond: (i.subscription_id = s.id)"
"                    Buffers: shared hit=2"
"                    ->  Seq Scan on invoices i  (cost=0.00..1.16 rows=16 width=61) (actual time=0.002..0.003 rows=16 loops=1)"
"                          Buffers: shared hit=1"
"                    ->  Hash  (cost=1.08..1.08 rows=8 width=80) (actual time=0.006..0.006 rows=8 loops=1)"
"                          Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                          Buffers: shared hit=1"
"                          ->  Seq Scan on subscriptions s  (cost=0.00..1.08 rows=8 width=80) (actual time=0.003..0.004 rows=8 loops=1)"
"                                Buffers: shared hit=1"
"              ->  Hash  (cost=1.08..1.08 rows=7 width=29) (actual time=0.011..0.011 rows=7 loops=1)"
"                    Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                    Buffers: shared hit=1"
"                    ->  Seq Scan on tenants t  (cost=0.00..1.08 rows=7 width=29) (actual time=0.007..0.008 rows=7 loops=1)"
"                          Filter: (deleted_at IS NULL)"
"                          Rows Removed by Filter: 1"
"                          Buffers: shared hit=1"
"        ->  Hash  (cost=1.06..1.06 rows=6 width=31) (actual time=0.007..0.007 rows=6 loops=1)"
"              Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"              Buffers: shared hit=1"
"              ->  Seq Scan on plans p  (cost=0.00..1.06 rows=6 width=31) (actual time=0.005..0.005 rows=6 loops=1)"
"                    Buffers: shared hit=1"
"Planning:"
"  Buffers: shared hit=24"
"Planning Time: 0.270 ms"
"Execution Time: 0.128 ms"
```

### Interpretation

```
Same story as billing_summary — all Seq Scans, tables too small for indexes to engage. The meaningful change is in the join strategy and cost estimates.
Before indexes the planner estimated 3 output rows and produced a Nested Loop Left Join at the top level with plans looked up per-row inside the loop — 17 iterations of that index scan, 32 buffer hits just from the plans lookup alone. After indexes the planner correctly estimated 14 rows and restructured the entire plan to Hash Left Join throughout. The plans lookup moved out of the loop into a single hash build, dropping plans-related buffer hits from 32 to 1.
Total buffer reads dropped from 35 to 4. Execution time dropped from 0.143ms to 0.128ms.
The correctness check passes — 17 rows returned, which includes Drifter Tools appearing with NULL invoice fields as expected. The LEFT JOIN chain is working correctly.
```

---

## tenant_usage.sql

Active tenants with current plan and outstanding balance.

**Correctness checks:**
- Drifter Tools must show `outstanding_cents = 0`, not NULL
- Pebble HR must appear once — active pro subscription only
- Nomad Stack (`past_due`) must not appear
- Defunct Systems (soft-deleted) must not appear

### Before indexes

```
"Sort  (cost=56.60..56.60 rows=1 width=292) (actual time=0.084..0.085 rows=5 loops=1)"
"  Sort Key: (COALESCE(sum(i.amount_cents), '0'::bigint)) DESC, t.name"
"  Sort Method: quicksort  Memory: 25kB"
"  Buffers: shared hit=17"
"  ->  GroupAggregate  (cost=45.22..56.59 rows=1 width=292) (actual time=0.066..0.071 rows=5 loops=1)"
"        Group Key: t.id, p.name, p.billing_cycle, p.price_cents, p.api_limit, s.status, s.current_period_start, s.current_period_end"
"        Buffers: shared hit=17"
"        ->  Incremental Sort  (cost=45.22..56.51 rows=2 width=228) (actual time=0.058..0.059 rows=5 loops=1)"
"              Sort Key: t.id, p.name, p.billing_cycle, p.price_cents, p.api_limit, s.status, s.current_period_start, s.current_period_end"
"              Presorted Key: t.id"
"              Full-sort Groups: 1  Sort Method: quicksort  Average Memory: 25kB  Peak Memory: 25kB"
"              Buffers: shared hit=17"
"              ->  Nested Loop Left Join  (cost=34.00..56.42 rows=1 width=228) (actual time=0.035..0.053 rows=5 loops=1)"
"                    Join Filter: (i.subscription_id = s.id)"
"                    Rows Removed by Join Filter: 8"
"                    Buffers: shared hit=17"
"                    ->  Nested Loop  (cost=34.00..38.75 rows=1 width=224) (actual time=0.032..0.038 rows=5 loops=1)"
"                          Buffers: shared hit=12"
"                          ->  Merge Join  (cost=33.85..33.91 rows=1 width=168) (actual time=0.027..0.029 rows=5 loops=1)"
"                                Merge Cond: (t.id = s.tenant_id)"
"                                Buffers: shared hit=2"
"                                ->  Sort  (cost=16.52..16.53 rows=3 width=88) (actual time=0.015..0.015 rows=7 loops=1)"
"                                      Sort Key: t.id"
"                                      Sort Method: quicksort  Memory: 25kB"
"                                      Buffers: shared hit=1"
"                                      ->  Seq Scan on tenants t  (cost=0.00..16.50 rows=3 width=88) (actual time=0.009..0.010 rows=7 loops=1)"
"                                            Filter: (deleted_at IS NULL)"
"                                            Rows Removed by Filter: 1"
"                                            Buffers: shared hit=1"
"                                ->  Sort  (cost=17.33..17.34 rows=6 width=96) (actual time=0.009..0.009 rows=5 loops=1)"
"                                      Sort Key: s.tenant_id"
"                                      Sort Method: quicksort  Memory: 25kB"
"                                      Buffers: shared hit=1"
"                                      ->  Seq Scan on subscriptions s  (cost=0.00..17.25 rows=6 width=96) (actual time=0.005..0.006 rows=5 loops=1)"
"                                            Filter: (status = ANY ('{active,trialing}'::text[]))"
"                                            Rows Removed by Filter: 3"
"                                            Buffers: shared hit=1"
"                          ->  Index Scan using plans_pkey on plans p  (cost=0.15..4.83 rows=1 width=88) (actual time=0.001..0.001 rows=1 loops=5)"
"                                Index Cond: (id = s.plan_id)"
"                                Buffers: shared hit=10"
"                    ->  Seq Scan on invoices i  (cost=0.00..17.62 rows=3 width=36) (actual time=0.001..0.002 rows=2 loops=5)"
"                          Filter: (status = 'open'::text)"
"                          Rows Removed by Filter: 14"
"                          Buffers: shared hit=5"
"Planning:"
"  Buffers: shared hit=6"
"Planning Time: 0.243 ms"
"Execution Time: 0.137 ms"
```

### After indexes

```
"Sort  (cost=4.99..5.00 rows=4 width=180) (actual time=0.079..0.080 rows=5 loops=1)"
"  Sort Key: (COALESCE(sum(i.amount_cents), '0'::bigint)) DESC, t.name"
"  Sort Method: quicksort  Memory: 25kB"
"  Buffers: shared hit=4"
"  ->  HashAggregate  (cost=4.82..4.95 rows=4 width=180) (actual time=0.063..0.067 rows=5 loops=1)"
"        Group Key: t.id, p.name, p.billing_cycle, p.price_cents, p.api_limit, s.status, s.current_period_start, s.current_period_end"
"        Batches: 1  Memory Usage: 32kB"
"        Buffers: shared hit=4"
"        ->  Hash Join  (cost=3.48..4.72 rows=4 width=116) (actual time=0.048..0.053 rows=5 loops=1)"
"              Hash Cond: (s.plan_id = p.id)"
"              Buffers: shared hit=4"
"              ->  Hash Right Join  (cost=2.34..3.56 rows=4 width=109) (actual time=0.029..0.033 rows=5 loops=1)"
"                    Hash Cond: (i.subscription_id = s.id)"
"                    Buffers: shared hit=3"
"                    ->  Seq Scan on invoices i  (cost=0.00..1.20 rows=2 width=36) (actual time=0.004..0.005 rows=2 loops=1)"
"                          Filter: (status = 'open'::text)"
"                          Rows Removed by Filter: 14"
"                          Buffers: shared hit=1"
"                    ->  Hash  (cost=2.29..2.29 rows=4 width=105) (actual time=0.021..0.021 rows=5 loops=1)"
"                          Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                          Buffers: shared hit=2"
"                          ->  Hash Join  (cost=1.17..2.29 rows=4 width=105) (actual time=0.016..0.019 rows=5 loops=1)"
"                                Hash Cond: (s.tenant_id = t.id)"
"                                Buffers: shared hit=2"
"                                ->  Seq Scan on subscriptions s  (cost=0.00..1.10 rows=5 width=72) (actual time=0.004..0.005 rows=5 loops=1)"
"                                      Filter: (status = ANY ('{active,trialing}'::text[]))"
"                                      Rows Removed by Filter: 3"
"                                      Buffers: shared hit=1"
"                                ->  Hash  (cost=1.08..1.08 rows=7 width=49) (actual time=0.005..0.006 rows=7 loops=1)"
"                                      Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                                      Buffers: shared hit=1"
"                                      ->  Seq Scan on tenants t  (cost=0.00..1.08 rows=7 width=49) (actual time=0.003..0.004 rows=7 loops=1)"
"                                            Filter: (deleted_at IS NULL)"
"                                            Rows Removed by Filter: 1"
"                                            Buffers: shared hit=1"
"              ->  Hash  (cost=1.06..1.06 rows=6 width=39) (actual time=0.014..0.014 rows=6 loops=1)"
"                    Buckets: 1024  Batches: 1  Memory Usage: 9kB"
"                    Buffers: shared hit=1"
"                    ->  Seq Scan on plans p  (cost=0.00..1.06 rows=6 width=39) (actual time=0.006..0.007 rows=6 loops=1)"
"                          Buffers: shared hit=1"
"Planning:"
"  Buffers: shared hit=26"
"Planning Time: 0.366 ms"
"Execution Time: 0.129 ms"
```

### Interpretation

```
This one had the most problematic plan before indexes. The Nested Loop Left Join for invoices ran 5 times — once per active/trialing subscription — and each iteration did a full Seq Scan of invoices discarding 14 rows to find the open ones. That is 5 × 16 = 80 invoice rows scanned to find 2 open ones. Rows Removed by Filter: 14 with loops=5 is the signal — wasted work multiplied by the loop count.
After indexes the planner collapsed this into a single Hash Right Join — invoices scanned once, hashed once, joined once. The repeated scan is gone entirely. Buffer reads dropped from 17 to 4. Execution time dropped from 0.137ms to 0.129ms.
At production scale this improvement is the most significant of the three. A Nested Loop with a Seq Scan inside it scales as O(subscriptions × invoices). With 50k active subscriptions and 500k invoice rows that plan is completely unusable. invoices_subscription_id_idx turns the inner scan into an index lookup, making the join O(subscriptions × invoices_per_subscription) instead.
The correctness checks all pass — 5 rows returned, Drifter Tools shows outstanding_cents = 0, Pebble HR appears once, Nomad Stack and Defunct Systems are absent.
```

---

## Partial unique index verification[Additional] - Run this AFTER the Partial Index has been added

Proves `subscriptions_one_active_per_tenant` is working.

**Test 1 — duplicate active subscription must be rejected.**
Acme Corp already has an active subscription in the seed data.

```sql
INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000003',
    'active', now(), now() + interval '30 days'
);
-- Expected: ERROR: duplicate key value violates unique constraint
--           "subscriptions_one_active_per_tenant"
```

**Test 2 — second cancelled subscription must be accepted.**
The partial index only covers `status = 'active'`.

```sql
INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end, cancelled_at)
VALUES (
    'b1000000-0000-0000-0000-000000000001',
    'a1000000-0000-0000-0000-000000000002',
    'cancelled', '2023-01-01 00:00:00+00', '2023-06-14 23:59:59+00', '2023-06-14 12:00:00+00'
);
-- Expected: INSERT 0 1
```

---

## Index reference

| Index | Table | Columns | Type |
|---|---|---|---|
| `users_tenant_id_idx` | users | `tenant_id` | Standard |
| `users_deleted_at_idx` | users | `tenant_id` | Partial (`deleted_at IS NULL`) |
| `subscriptions_tenant_id_idx` | subscriptions | `tenant_id` | Standard |
| `subscriptions_tenant_status_idx` | subscriptions | `(tenant_id, status)` | Composite |
| `subscriptions_one_active_per_tenant` | subscriptions | `tenant_id` | Partial unique (`status = 'active'`) |
| `subscriptions_period_end_idx` | subscriptions | `current_period_end` | Partial (`status IN ('active', 'trialing')`) |
| `subscriptions_plan_id_idx` | subscriptions | `plan_id` | Standard |
| `invoices_tenant_id_idx` | invoices | `tenant_id` | Standard |
| `invoices_tenant_status_idx` | invoices | `(tenant_id, status)` | Composite |
| `invoices_subscription_id_idx` | invoices | `subscription_id` | Standard |
| `invoices_created_at_idx` | invoices | `created_at` | Partial (`status NOT IN ('void', 'draft')`) |
