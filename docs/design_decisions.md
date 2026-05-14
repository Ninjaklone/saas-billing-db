# Design Decisions

## Phase 1 — Core Schema

### UUID primary keys (not SERIAL / BIGINT)

All tables use `UUID PRIMARY KEY DEFAULT gen_random_uuid()`.

**Why:** In a multi-tenant SaaS system, IDs frequently leave the database —
they appear in API responses, webhook payloads, URLs, and external billing
systems. Sequential integers might leak information (a competitor can estimate your
customer count from their tenant ID). UUIDs are opaque, globally unique, and
safe to expose publicly.

`gen_random_uuid()` is built into PostgreSQL 13+ — no extension required.
We do not use `uuid-ossp` or `pgcrypto`.

**Trade-off accepted:** UUIDs as primary keys produce slightly larger indexes
and cause more page splits than sequential integers. At the scale this system
targets, this cost is negligible. If we ever hit write throughput limits on
the `invoices` table specifically, the first remedy is ULIDs — not reverting
to integers.

---

### All money stored in cents (INT, not NUMERIC or FLOAT)

`price_cents INT`, `amount_cents INT` throughout.

**Why:** Floating-point types (FLOAT, DOUBLE PRECISION) cannot represent most
decimal values exactly. `0.1 + 0.2 = 0.30000000000000004` commonly in IEEE 754.
This is unacceptable in a billing system — rounding errors in financial
calculations will definitely compound and produce incorrect totals.

NUMERIC avoids rounding errors but introduces variable-length storage and
slower arithmetic. For a billing system where all amounts are whole cents,
integer arithmetic is exact, fast, and simple.

The application layer MUST BE responsible for dividing by 100 before display.
Never store fractional cents.

---

### TIMESTAMPTZ everywhere (not TIMESTAMP)

All timestamp columns use `TIMESTAMPTZ` (timestamp with time zone).

**Why:** `TIMESTAMP` stores a local time with no timezone context. When the
database server timezone changes, or when data is read from a different
timezone, `TIMESTAMP` values become ambiguous. `TIMESTAMPTZ` stores UTC
internally and converts on read — always unambiguous, always correct.

In a multi-tenant SaaS with users across multiple timezones, there is no
legitimate reason to use bare `TIMESTAMP`. It is banned from this schema.

---

### Soft deletes on tenants and users (deleted_at TIMESTAMPTZ)

Tenants and users are never hard-deleted. Instead, `deleted_at` is set to
`now()`. A NULL value means the row is active.

**Why:** Hard-deleting a tenant would require cascading deletes across
subscriptions, invoices, users, and audit logs — destroying financial history
that may be legally required to retain. Soft deletes preserve all historical
data while cleanly marking an entity as inactive.

**Filtering active records:** Application queries must always filter with
`WHERE deleted_at IS NULL`. This should be enforced via views or Row-Level
Security in production; it is a known footgun if forgotten.

**Invoices and audit logs are never soft-deleted.** These are append-only
financial records. No delete mechanism of any kind exists for them — see
below.

---

### Invoices are append-only (no UPDATE, no DELETE)

The `invoices` table has no soft-delete column. There is no mechanism to
update or delete a row.

**Why:** Invoices are a financial ledger. Mutating a record after the fact —
even to correct an error — destroys the audit trail. The correct pattern is
to void the incorrect invoice (status = 'void', as a new state transition on
the existing row) or issue a credit memo as a new row. This mirrors how Stripe
and every serious billing system works.

A database-level trigger to enforce immutability will be added in Phase 4
alongside the audit log.

---

### Tenant isolation via tenant_id foreign key on every data table

Every table that contains tenant data has a `tenant_id UUID NOT NULL
REFERENCES tenants(id)` column. No exceptions.

**Why:** Without this, it is trivially easy to write a query that returns
data across tenant boundaries. With `tenant_id` on every table, correct
multi-tenant queries are the natural path and cross-tenant queries require
deliberate effort.

Row-Level Security (RLS) using `tenant_id` is the planned enforcement
mechanism at the database level. This will be added when the application
layer is built. The foreign key column is the prerequisite.

---

### slug format enforced by CHECK constraint

`CONSTRAINT tenants_slug_format CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')`

**Why:** Slugs are used in URLs and API paths. Accepting mixed-case, spaces,
or special characters silently would produce broken URLs and inconsistent
data. Enforcing format at the database level means no application bug can
insert a malformed slug — the constraint fires regardless of what layer wrote
the data.

**Slugs are immutable after creation.** Changing a slug breaks any external
system (bookmarks, integrations, webhooks) that has stored a URL containing
it. This is a social contract enforced by application logic, not a database
constraint — but it is documented here so the decision is not forgotten.

---

### Cancelled subscription consistency enforced by CHECK constraint

```sql
CONSTRAINT subscriptions_cancelled_consistency CHECK (
    (status = 'cancelled' AND cancelled_at IS NOT NULL)
    OR
    (status <> 'cancelled' AND cancelled_at IS NULL)
)
```

**Why:** Without this constraint, it is possible to have an `active`
subscription with a `cancelled_at` timestamp, or a `cancelled` subscription
with no cancellation date. Both are data corruption. The constraint costs
nothing and prevents an entire class of bugs that are difficult to detect
and painful to remediate in production data.

The same pattern is applied to `invoices.paid_at` — it is non-null if and
only if `status = 'paid'`.

---

### plans.is_active (boolean) — plan retirement without breaking history

`is_active BOOLEAN NOT NULL DEFAULT TRUE` on the `plans` table.

**Why:** Once any subscription references a plan, that plan row cannot be
deleted — the foreign key prevents it. Without a retirement mechanism, old
plans accumulate and remain selectable for new subscriptions indefinitely.
`is_active = FALSE` allows a plan to be retired cleanly: existing
subscriptions are unaffected, new subscriptions cannot use it.

## Phase 1 — Seed Data (Part 2)

### Fixed UUIDs instead of gen_random_uuid()

All seed rows use hardcoded UUIDs in a structured format
(e.g. `'b1000000-0000-0000-0000-000000000001'`).

**Why:** `gen_random_uuid()` in seed data produces different IDs on every
run. That breaks any query, test, or foreign key reference that targets a
specific row by ID. Fixed UUIDs make the seed deterministic — the same IDs
exist in every developer environment, every CI run, and every test assertion.

The structured format (incrementing last segment per table, unique prefix per
table letter) makes it easy to read a UUID in a query result and immediately
know which table and which row it belongs to without looking it up.

---

### Six tenants, not five — the soft-deleted case is load-bearing

I had originally planned for 5 users as the base case
but I have given the seed six, and the sixth
(Defunct Systems) is soft-deleted.

**Why:** Five active tenants test the happy path. The sixth tests the
discipline of `WHERE deleted_at IS NULL`. Any query that forgets this filter
will silently include Defunct Systems in its results — wrong revenue totals,
wrong active tenant counts. Having the corrupt case in the seed means the bug
shows up in development, not in a job interview demo (That would be embarassing).

---

### One tenant per edge case, not all edge cases on one tenant

Each tenant demonstrates exactly one non-standard situation:
- Acme Corp — clean payment history (baseline)
- Bright Ledger — annual billing cycle
- Nomad Stack — past_due status + uncollectible invoice
- Pebble HR — plan upgrade mid-lifecycle, voided invoice, soft-deleted user
- Drifter Tools — trialing with no invoices
- Defunct Systems — soft-deleted tenant with preserved history

**Why:** Stacking multiple edge cases on one tenant makes it impossible to
isolate which condition caused a query to fail. One edge case per tenant means
a broken query result points directly at the scenario responsible.

---

### Drifter Tools has no invoices — intentionally

Drifter Tools is trialing and has zero rows in the `invoices` table.

**Why:** Any query that joins `subscriptions` to `invoices` with an
`INNER JOIN` will silently drop Drifter Tools from the result set. That is a
real bug that I have found to actually appear in production billing systems. The seed makes it
detectable in development. The correct join is `LEFT JOIN`. This case exists
to catch that mistake.

---

### Pebble HR has two subscription rows for the same tenant

The plan upgrade from starter to pro is represented as two separate
subscription rows — one `cancelled`, one `active` — not as an UPDATE to the
original row.

**Why:** Updating a subscription row to change its plan destroys the history
of what the tenant was on before. Two rows preserve the full lifecycle: when
the old plan started, when it was cancelled, when the new plan began. This
is the correct pattern I have found and around Phase 5-6 I plan to implement a proration function that will
operate on cases like this in production. The seed establishes the pattern now so Phase 5-6 has realistic
data to work against.

---

### The voided invoice on Pebble HR is intentional, not a mistake

Invoice `e1000000-0000-0000-0000-000000000012` has `status = 'void'` and
`amount_cents = 2900` against the cancelled starter subscription.

**Why:** This represents an invoice that was generated for a billing period
that was cut short by the plan upgrade. Voiding it — rather than deleting it
or never creating it — is the correct pattern. The financial record exists,
it is marked void, and the replacement invoice was issued under the new
subscription. Any revenue query must exclude void invoices from totals. The
seed makes that requirement visible. Its always important to preserve records
especially in systems that deal with finance.

---

### Defunct Systems invoices are retained after the tenant is soft-deleted

The tenant `defunct-systems` has `deleted_at` set, but its invoices and
subscription rows remain in the database untouched.

**Why:** Soft delete means the tenant is inactive — it does not mean their
financial history is erased. Invoices may need to be referenced for
chargebacks, disputes, or regulatory audit. Cascading a soft delete into
financial records would be a compliance failure. The seed demonstrates that
the correct behaviour is: filter the tenant out of active queries, but leave
every related record intact.

---

### Invoice dates follow real billing timing

Invoice `created_at` values are set to the first of each month. `due_date`
is set 7 days after creation. `paid_at` is 2–4 days after creation for paid
invoices.

**Why:** Unrealistic dates (all invoices on the same day, due dates before
creation) would cause date-range queries to return wrong results and mask
bugs in billing window logic. Realistic timing means the seed data behaves
like production data under any query that filters or aggregates by date.
**Note:** I had similar issues with projects back in College, I would just assign
randomly generated values for demo's and it would occassionally break application logic.

## Phase 2 - Indexes
### The Logic behind the process of perpetually picking the right indexes everytime

Originally, I had planned to give insight into why I wrote the indexes I did and the logic behind 
the index for each table (or combination of tables) and why it was necessary for this particular use-case but instead I
think it would be better to simply draw up a logical framework for adding indexes to just about 
any relational database so that anyone in the future seeing this project gets insight into Performance
Tuning as it pertains to writing indexes. I'll start with the Query Planner, the core of index usage in any DBMS.

---

### Why bringing the query planner into the loop matters

PostgreSQL’s planner chooses indexes by treating query execution as a cost‑minimization problem:
it enumerates possible access paths (sequential, index, bitmap, index‑only), estimates I/O/CPU/memory 
costs using table statistics and planner cost constants, and selects the lowest‑cost plan - you make 
this reliable by keeping statistics accurate, designing indexes to match real query patterns, and 
monitoring planner behavior. Cost based optimization is the game. The planner assigns a numeric cost 
to each candidate plan composed of startup cost, per‑tuple CPU cost, and I/O cost; parameters like 
seq_page_cost, random_page_cost, and cpu_tuple_cost shape those estimates. The chosen plan is the 
one with the lowest estimated total cost **and thats where you come in**. 

When an index exists that can satisfy a predicate or ordering, the planner creates index scan and index‑only 
scan paths alongside sequential and bitmap options. Indexes are therefore alternative routes the planner can 
pick if they reduce estimated work. Why it matters?

### Why selectivity and statistics matter

- **Selectivity drives index usefulness**. The planner uses column statistics (distinct counts, most‑common values, 
histograms, correlation) to estimate how many rows a predicate will return. Highly selective predicates (few matching rows) 
favor index scans; low selectivity favors sequential scans. Stale or insufficient statistics lead to systematically wrong 
choices and your job when tuning performance is eliminate such behaviour.
- **Correlation and physical order affect cost**. If heap rows are poorly correlated with an index’s logical order, index scans 
cause many random heap fetches and in turn become expensive; the planner factors this via statistics and correlation metrics
so you usually just have point it in the right direction. 

### So how do you get the planner to make effectively "right" choices?

- **Keep statistics fresh and rich**. Regular ANALYZE (or tuned default_statistics_target and per‑column statistics) ensures 
the planner’s estimates reflect reality; for skewed distributions raise statistics targets.

- **Design indexes for real query patterns**. Indexes should match common WHERE, JOIN, and ORDER BY patterns; the planner 
will only consider indexes that can satisfy the operators and sort requirements. Choose the correct index type 
(B‑tree, GIN/GiST, BRIN) for the workload. If you are unsure of what counts as "real query pattern", check index statistics,
and make a google search if interpretation might be a problem.

- **Monitor and iterate**. Use EXPLAIN ANALYZE to compare estimated vs actual costs and pg_stat_user_indexes to measure real 
index usage; remove duplicates and unused indexes to reduce write and storage overhead. 


## Phase 3 — Usage Metering

### Hourly buckets, not per-request rows

`api_usage_events` stores one row per tenant per hour per endpoint, not one
row per API call.

**Why:** Per-request logging at any real usage volume produces an unmanageable
table. A tenant making 1,000 requests per hour generates 8.7 million rows per
year from a single tenant. Hourly buckets reduce that to 8,760 rows per year
per tenant — three orders of magnitude smaller — while retaining enough
granularity for billing (which operates on monthly totals) and anomaly
detection (which operates on hourly trends).

Per-request logs belong in an observability platform (Datadog, CloudWatch).
As a billing database the focus is counts and not events, we don't need all that.

---

### recorded_at truncated to the hour at the application layer

The `recorded_at` column stores the bucket timestamp truncated to the hour.
The truncation happens before insert: `date_trunc('hour', now())`.

**Why:** Enforcing this at the application layer rather than with a generated
column keeps the schema simple and the insert logic explicit. The UNIQUE
constraint on `(tenant_id, recorded_at, endpoint)` makes the truncation
a hard requirement — a non-truncated timestamp would create a duplicate
violation during the next aggregation run for the same hour.

---

### UNIQUE constraint on (tenant_id, recorded_at, endpoint)

**Why:** The aggregation job that writes to this table may run more than once
for the same hour (retry on failure, operator re-run). Without this constraint
a retry produces duplicate rows and inflates billing totals. The constraint
makes the insert idempotent — the correct pattern on conflict is
`ON CONFLICT (tenant_id, recorded_at, endpoint) DO UPDATE SET event_count = EXCLUDED.event_count`.

---

### endpoint stored as TEXT, not a foreign key to an endpoints table

**Why:** API endpoints change over time — new versions are added, old ones are
deprecated. A foreign key to an endpoints table would require schema migrations
every time the API surface changes and would block inserts for any endpoint not
yet registered. Storing endpoint as TEXT keeps the usage table decoupled from
API versioning. Normalisation of endpoint values is enforced at the application
layer before insert.

---

### billing_summaries as a materialized view, not a table

**Why:** The data in `billing_summaries` is entirely derived from
`api_usage_events`, `subscriptions`, and `plans`. There is no independent
state. A table would require manual maintenance — triggers or application code
to keep it in sync. A materialized view is refreshed explicitly and is always
a consistent snapshot of the source data.

`REFRESH MATERIALIZED VIEW CONCURRENTLY` allows reads during the refresh
operation, which requires a unique index — `billing_summaries_unique_idx` on
`(subscription_id, endpoint)` satisfies this requirement.

---

### past_due subscriptions included in billing_summaries

The materialized view includes subscriptions with `status = 'past_due'`
alongside active and trialing ones.

**Why:** A past_due tenant is still consuming API calls. Their usage still
needs to be tracked for billing reconciliation and for the dunning process
(which needs to know how much they owe). Excluding past_due subscriptions
would produce an incomplete usage picture and make it harder to recover
revenue from delinquent accounts.

---

### Partitioning deferred to Phase 7

`api_usage_events` will be partitioned by month on `recorded_at` in Phase 7.
The schema is designed now to make that migration non-breaking — `recorded_at`
is TIMESTAMPTZ, the primary key is UUID (partition-safe), and there are no
assumptions baked into the indexes that would conflict with declarative range
partitioning.

The decision to defer is deliberate: partitioning an empty or lightly seeded
table adds complexity with no measurable benefit. Phase 7 will migrate the
existing table to a partitioned parent with monthly child tables.


## Phase 4 — Audit Logging

### Audit status changes only, not every column

The triggers on `subscriptions` and `invoices` fire only when the `status`
column changes. Updates to other columns (period dates, amounts) do not
produce audit rows.

**Why:** In a correctly designed append-only schema, non-status columns on
financial records should never change after insert. If they do, that is a
bug in the application layer, not a normal event to be audited. Auditing
every column change would produce noise that obscures the meaningful signal —
status transitions are the events that matter for billing, compliance, and
support.

---

### Single trigger function for both tables

One function — `fn_log_status_change()` — handles both `subscriptions` and
`invoices` via `TG_TABLE_NAME`.

**Why:** The logic is identical for both tables. Two separate functions would
need to be kept in sync. A single function with `TG_TABLE_NAME` is the
standard Postgres pattern for this case and reduces maintenance surface.

---

### WHEN (OLD.status IS DISTINCT FROM NEW.status) on the trigger definition

The trigger uses `IS DISTINCT FROM` rather than `<>` in the WHEN clause.

**Why:** `<>` returns NULL when either operand is NULL. `IS DISTINCT FROM`
handles NULLs correctly — it returns FALSE when both sides are NULL and TRUE
when one side is NULL and the other is not. Status columns have NOT NULL
constraints so this distinction does not matter today. It is the correct
habit and protects against schema changes that might relax that constraint.

---

### changed_by prefers app.current_user_id, falls back to current_user

The trigger records the identity of whoever made the change. It checks
`current_setting('app.current_user_id', TRUE)` first and falls back to
`current_user` if not set.

**Why:** `current_user` is the database role — useful for identifying
automated jobs and migration scripts, but not useful for identifying which
application user triggered the change. In production, the application sets
`SET LOCAL app.current_user_id = '<user_uuid>'` within the transaction before
the triggering statement. `SET LOCAL` scopes the value to the transaction and
clears it automatically on commit or rollback — no cleanup required.

---

### Seed data inserted directly, not via UPDATE

The audit log seed rows are inserted directly into `billing_audit_log` rather
than replaying the historical UPDATEs that would have triggered them.

**Why:** The triggers only exist from Phase 4 onwards. The subscription and
invoice seed data was inserted in Phase 1 without triggers in place. Direct
inserts reconstruct the audit history that would have been recorded had the
triggers existed from the start. This keeps the seed data internally
consistent without requiring a complex replay script.


## Phase 5 — Proration Logic

### Net invoice approach — one amount, not two separate documents

A plan change produces one net proration amount: charge for remaining days on
the new plan minus credit for unused days on the old plan. This net amount
becomes a single invoice row.

**Why:** Issuing two separate documents (a credit memo and a new invoice) is
more complex for the tenant to reconcile and more complex for the billing
system to track. A single net invoice is what Stripe and every major billing
platform produces. Negative net amounts (downgrades) are valid — they
represent a credit that is applied to the next invoice.

---

### Daily rate uses actual cycle length, not a fixed 30 or 365

The daily rate is `price_cents / (period_end::date - period_start::date)`.
For a monthly plan this uses the actual number of days in the month. For
an annual plan it uses the actual number of days in the year.

**Why:** A fixed 30-day month overcharges tenants in short months (February)
and undercharges in long months (January, March). Using actual cycle length
is accurate and matches what tenants expect when they check the maths
themselves.

---

### Credit rounds down, charge rounds up

`credit_cents = FLOOR(old_daily_rate * days_remaining)`
`charge_cents = CEIL(new_daily_rate  * days_remaining)`

**Why:** Fractional cents cannot appear in the billing system — all amounts
are integers. The rounding direction favours the platform by a fraction of a
cent per transaction. The alternative (always rounding to nearest) would
sometimes favour the tenant and sometimes the platform unpredictably.
The chosen direction is consistent, auditable, and industry standard.

---

### fn_calculate_proration inserts into plan_change_events directly

The function both calculates the amounts and writes the plan_change_events
row. It does not return amounts for the caller to write separately.

**Why:** Separating calculation from recording creates a window where the
amounts are calculated but the event is never recorded — if the caller fails
to insert after receiving the results, the change is unaudited. Combining
both operations in the function and wrapping the call in a transaction
guarantees that a calculation always produces a record.

---

### days_remaining minimum is 1

`GREATEST((p_period_end::date - p_effective_at::date), 1)`

**Why:** A plan change on the last day of a billing cycle would otherwise
produce zero days remaining, zero credit, zero charge, and a zero net invoice.
That is technically correct but creates an empty audit record and an
unnecessary invoice. A minimum of 1 ensures the change is always recorded
with a meaningful amount, even at the boundary.