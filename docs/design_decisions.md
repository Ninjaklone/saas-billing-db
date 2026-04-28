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