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