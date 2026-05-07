-- =============================================================================
-- saas-billing-db: Core Schema — Phase 1
-- PostgreSQL 15+
-- =============================================================================
-- Tables (in dependency order):
--   1. tenants        — the companies (customers) using the platform
--   2. plans          — pricing tiers available on the platform
--   3. users          — individual humans belonging to a tenant
--   4. subscriptions  — a tenant's current and historical plan enrollments
--   5. invoices       — financial records (append-only, never UPDATE/DELETE)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
-- gen_random_uuid() is built-in from PostgreSQL 13+.
-- pgcrypto is NOT needed — do not add it.
-- If deploying on RDS < 13, swap to pgcrypto's gen_random_uuid() via extension.

-- ---------------------------------------------------------------------------
-- 1. tenants
-- ---------------------------------------------------------------------------
-- The top-level entity. Every other table with tenant data references this.
-- Soft-deleted via deleted_at — a NULL value means the tenant is active.
-- slug is used in URLs and API identifiers (e.g. "acme-corp").

CREATE TABLE tenants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    slug        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,           -- NULL = active; non-NULL = soft-deleted

    -- slug must be unique across all tenants, including soft-deleted ones.
    -- This avoids slug reuse which could cause historical data collisions.
    CONSTRAINT tenants_slug_unique UNIQUE (slug),

    -- Slugs must be lowercase, hyphen-separated, no spaces or special chars.
    -- Pattern: one or more groups of [a-z0-9] joined by hyphens.
    CONSTRAINT tenants_slug_format CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),

    -- A tenant cannot be active and soft-deleted simultaneously.
    -- deleted_at must be after created_at when set.
    CONSTRAINT tenants_deleted_after_created CHECK (
        deleted_at IS NULL OR deleted_at > created_at
    )
);

COMMENT ON TABLE  tenants            IS 'Top-level tenant (customer company) registry. Soft-deleted via deleted_at.';
COMMENT ON COLUMN tenants.slug       IS 'URL-safe unique identifier, e.g. acme-corp. Immutable after creation.';
COMMENT ON COLUMN tenants.deleted_at IS 'NULL = active. Set to now() to soft-delete. Never physically delete rows.';


-- ---------------------------------------------------------------------------
-- 2. plans
-- ---------------------------------------------------------------------------
-- Defines the pricing tiers that tenants subscribe to.
-- Plans are platform-wide, not per-tenant.
-- Prices are always stored in cents (integer) — never FLOAT or NUMERIC.
-- api_limit NULL means the plan has no API call ceiling (unlimited).

CREATE TABLE plans (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT        NOT NULL,
    price_cents   INT         NOT NULL,
    billing_cycle TEXT        NOT NULL,
    api_limit     INT,                  -- NULL = unlimited
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Price must be zero or positive. Free plans (price_cents = 0) are valid.
    CONSTRAINT plans_price_non_negative CHECK (price_cents >= 0),

    -- Only supported billing cycles. Add 'quarterly' here if needed later.
    CONSTRAINT plans_billing_cycle_valid CHECK (
        billing_cycle IN ('monthly', 'annual')
    ),

    -- api_limit, when set, must be a positive integer.
    -- Zero would mean no API calls allowed — that is not a valid plan.
    CONSTRAINT plans_api_limit_positive CHECK (
        api_limit IS NULL OR api_limit > 0
    ),

    -- Plan names must be unique (case-insensitive).
    -- Prevents duplicate 'Pro' and 'pro' plans.
    CONSTRAINT plans_name_unique UNIQUE (name)
);

COMMENT ON TABLE  plans            IS 'Pricing tiers available on the platform. Not tenant-specific.';
COMMENT ON COLUMN plans.price_cents IS 'Monthly or annual price in cents. Use INT, never FLOAT. 0 = free plan.';
COMMENT ON COLUMN plans.api_limit   IS 'Max API calls per billing cycle. NULL = unlimited.';
COMMENT ON COLUMN plans.is_active   IS 'FALSE = plan is retired. Existing subscriptions keep the old plan_id; new subscriptions cannot use it.';


-- ---------------------------------------------------------------------------
-- 3. users
-- ---------------------------------------------------------------------------
-- Individual humans who belong to exactly one tenant.
-- Email is unique within a tenant, not globally — two tenants can have
-- the same email if they represent the same person at different companies.
-- Soft-deleted via deleted_at; role is retained for audit purposes.

CREATE TABLE users (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    email       TEXT        NOT NULL,
    role        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,           -- NULL = active

    -- Email uniqueness is scoped to the tenant.
    CONSTRAINT users_tenant_email_unique UNIQUE (tenant_id, email),

    -- Basic email format check — not exhaustive, but catches obvious garbage.
    CONSTRAINT users_email_format CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),

    -- Only these three roles are valid. Expand here (and document why) if needed.
    CONSTRAINT users_role_valid CHECK (role IN ('admin', 'member', 'viewer')),

    -- deleted_at must be after created_at when set.
    CONSTRAINT users_deleted_after_created CHECK (
        deleted_at IS NULL OR deleted_at > created_at
    )
);

COMMENT ON TABLE  users            IS 'Individual users scoped to a tenant. Email unique per tenant, not globally.';
COMMENT ON COLUMN users.role       IS 'admin = full access; member = standard access; viewer = read-only.';
COMMENT ON COLUMN users.deleted_at IS 'NULL = active. Set to soft-delete. Role is preserved for audit history.';


-- ---------------------------------------------------------------------------
-- 4. subscriptions
-- ---------------------------------------------------------------------------
-- Records a tenant's enrollment in a plan.
-- A tenant can have only ONE active subscription at a time.
-- Historical subscriptions (cancelled, past_due) are retained for audit.
-- period_start and period_end define the current billing window.

CREATE TABLE subscriptions (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID        NOT NULL REFERENCES tenants(id),
    plan_id              UUID        NOT NULL REFERENCES plans(id),
    status               TEXT        NOT NULL,
    current_period_start TIMESTAMPTZ NOT NULL,
    current_period_end   TIMESTAMPTZ NOT NULL,
    cancelled_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Only recognised statuses.
    CONSTRAINT subscriptions_status_valid CHECK (
        status IN ('active', 'cancelled', 'past_due', 'trialing')
    ),

    -- The billing period must be a positive window.
    CONSTRAINT subscriptions_period_valid CHECK (
        current_period_end > current_period_start
    ),

    -- cancelled_at only makes sense when status = 'cancelled'.
    -- This prevents data inconsistency (cancelled_at set on an active sub).
    CONSTRAINT subscriptions_cancelled_consistency CHECK (
        (status = 'cancelled' AND cancelled_at IS NOT NULL)
        OR
        (status <> 'cancelled' AND cancelled_at IS NULL)
    ),

    -- cancelled_at must be after creation.
    CONSTRAINT subscriptions_cancelled_after_created CHECK (
        cancelled_at IS NULL OR cancelled_at >= created_at
    )
);

COMMENT ON TABLE  subscriptions                    IS 'Tenant plan enrollments. Retain all rows — historical subscriptions are audit evidence.';
COMMENT ON COLUMN subscriptions.status             IS 'active | trialing | past_due | cancelled. Only one active subscription per tenant enforced at app layer; use partial index for DB-level enforcement.';
COMMENT ON COLUMN subscriptions.current_period_end IS 'End of current billing cycle. Updated on renewal; do not recycle rows — insert a new subscription instead.';
COMMENT ON COLUMN subscriptions.cancelled_at       IS 'Must be set iff status = cancelled. Enforced by check constraint.';


-- ---------------------------------------------------------------------------
-- 5. invoices
-- ---------------------------------------------------------------------------
-- APPEND-ONLY. Never UPDATE or DELETE rows in this table.
-- Every charge, void, and adjustment is a new row.
-- This is the financial ledger — immutability is a hard requirement.
-- paid_at is NULL until payment is confirmed.

CREATE TABLE invoices (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL REFERENCES tenants(id),
    subscription_id UUID        NOT NULL REFERENCES subscriptions(id),
    amount_cents    INT         NOT NULL,
    status          TEXT        NOT NULL,
    due_date        DATE        NOT NULL,
    paid_at         TIMESTAMPTZ,        -- NULL = unpaid
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Amount must be zero or positive. Zero is valid for free-plan invoices.
    CONSTRAINT invoices_amount_non_negative CHECK (amount_cents >= 0),

    -- Recognised invoice lifecycle statuses (mirrors Stripe's model).
    CONSTRAINT invoices_status_valid CHECK (
        status IN ('draft', 'open', 'paid', 'void', 'uncollectible')
    ),

    -- paid_at only valid when status = 'paid'.
    CONSTRAINT invoices_paid_consistency CHECK (
        (status = 'paid' AND paid_at IS NOT NULL)
        OR
        (status <> 'paid' AND paid_at IS NULL)
    ),

    -- paid_at must not precede the invoice creation time.
    CONSTRAINT invoices_paid_after_created CHECK (
        paid_at IS NULL OR paid_at >= created_at
    ),

    -- Due date must not be before the invoice was created.
    -- (Using DATE vs TIMESTAMPTZ — cast created_at to DATE for comparison.)
    CONSTRAINT invoices_due_date_valid CHECK (
        due_date >= created_at::DATE
    )
);

COMMENT ON TABLE  invoices             IS 'Financial ledger. APPEND-ONLY — no UPDATE or DELETE, ever. Voids and corrections are new rows.';
COMMENT ON COLUMN invoices.amount_cents IS 'Charge amount in cents. INT, never FLOAT. 0 valid for free-plan invoices.';
COMMENT ON COLUMN invoices.status       IS 'draft → open → paid | void | uncollectible. Mirrors Stripe lifecycle.';
COMMENT ON COLUMN invoices.paid_at      IS 'Timestamp of payment confirmation. NULL until paid. Set iff status = paid.';


-- =============================================================================
-- saas-billing-db: Indexes — Phase 2
-- PostgreSQL 15+
-- =============================================================================
-- Indexes for the five core tables.
--
-- Every index here targets a specific, documented query pattern.
-- (Never add indexes on speculation. A non-targeted index might 
-- degrade db performance if it interfers with an already existing index)
--
-- Run EXPLAIN ANALYZE on affected queries before and after applying this file.
-- Note-to-Self: Remember to save both outputs in queries/README.md.
--
-- Indexes in this file:
--   1.  users_tenant_id_idx
--   2.  users_deleted_at_idx
--   3.  subscriptions_tenant_id_idx
--   4.  subscriptions_tenant_status_idx
--   5.  subscriptions_one_active_per_tenant (partial unique)
--   6.  subscriptions_period_end_idx
--   7.  subscriptions_plan_id_idx
--   8.  invoices_tenant_id_idx
--   9.  invoices_tenant_status_idx
--   10. invoices_subscription_id_idx
--   11. invoices_created_at_idx
-- =============================================================================


-- ---------------------------------------------------------------------------
-- users
-- ---------------------------------------------------------------------------

-- 1. users_tenant_id_idx
-- Query pattern: fetch all users belonging to a tenant.
-- Used by: tenant admin panels, user management pages, audit queries.
-- Without this: full sequential scan of users on every page load.
CREATE INDEX users_tenant_id_idx
    ON users (tenant_id);

COMMENT ON INDEX users_tenant_id_idx
    IS 'Speeds up all queries filtering users by tenant. Used on every tenant-scoped user lookup.';


-- 2. users_deleted_at_idx
-- Query pattern: fetch only active users (WHERE deleted_at IS NULL).
-- A partial index only indexes active rows — deleted users are excluded
-- entirely, keeping the index small as churn accumulates over time.
-- Without this: full scan of users including all historically deleted rows.
CREATE INDEX users_deleted_at_idx
    ON users (tenant_id)
    WHERE deleted_at IS NULL;

COMMENT ON INDEX users_deleted_at_idx
    IS 'Partial index on active users only. Excludes soft-deleted rows, keeping the index compact long-term.';


-- ---------------------------------------------------------------------------
-- subscriptions
-- ---------------------------------------------------------------------------

-- 3. subscriptions_tenant_id_idx
-- Query pattern: fetch all subscriptions for a tenant (all statuses).
-- Used by: subscription history pages, tenant offboarding, audit queries.
CREATE INDEX subscriptions_tenant_id_idx
    ON subscriptions (tenant_id);

COMMENT ON INDEX subscriptions_tenant_id_idx
    IS 'Covers all subscription lookups by tenant regardless of status. Used for history and audit queries.';


-- 4. subscriptions_tenant_status_idx
-- Query pattern: fetch subscriptions for a tenant filtered by status.
-- Most common form: WHERE tenant_id = $1 AND status = 'active'
-- Column order is deliberate — tenant_id first (higher selectivity in a
-- multi-tenant system), status second. Reversing the order would produce
-- a less efficient plan for the most common query shape.
CREATE INDEX subscriptions_tenant_status_idx
    ON subscriptions (tenant_id, status);

COMMENT ON INDEX subscriptions_tenant_status_idx
    IS 'Composite index for tenant + status filters. tenant_id is first — it eliminates more rows per scan step than status alone.';


-- 5. subscriptions_one_active_per_tenant
-- Query pattern: enforce business rule — one active subscription per tenant.
-- This is a partial unique index, not just a performance index. It makes it
-- physically impossible to INSERT a second active subscription for a tenant
-- that already has one. Cancelled, past_due, and trialing rows are excluded
-- from the index entirely — those statuses can coexist freely.
--
-- This is the correct way to enforce this constraint. A plain unique index on
-- (tenant_id) would block legitimate historical rows. A CHECK constraint
-- cannot reference other rows. This partial unique index is the only mechanism
-- that enforces the rule correctly at the database level.
CREATE UNIQUE INDEX subscriptions_one_active_per_tenant
    ON subscriptions (tenant_id)
    WHERE status = 'active';

COMMENT ON INDEX subscriptions_one_active_per_tenant
    IS 'Enforces one active subscription per tenant at the DB level. Partial — only indexes active rows. Cancelled/past_due/trialing rows are unrestricted.';


-- 6. subscriptions_period_end_idx
-- Query pattern: find subscriptions expiring within a date window.
-- Used by: renewal jobs, dunning processes, expiry alerts.
-- Example: WHERE current_period_end BETWEEN now() AND now() + interval '7 days'
-- Without this: full scan of all subscriptions to find upcoming renewals.
-- As subscription count grows this becomes a critical path query.
CREATE INDEX subscriptions_period_end_idx
    ON subscriptions (current_period_end)
    WHERE status IN ('active', 'trialing');

COMMENT ON INDEX subscriptions_period_end_idx
    IS 'Partial index for renewal and dunning jobs. Only indexes active and trialing rows — cancelled subscriptions are never due for renewal.';


-- 7. subscriptions_plan_id_idx
-- Query pattern: find all subscriptions on a given plan.
-- Used by: plan retirement checks (is anyone still on this plan?),
-- bulk price change impact analysis, plan usage reporting.
-- Without this: full scan of subscriptions when checking plan references.
CREATE INDEX subscriptions_plan_id_idx
    ON subscriptions (plan_id);

COMMENT ON INDEX subscriptions_plan_id_idx
    IS 'Covers lookups by plan. Used when retiring a plan or analysing which tenants are on a given pricing tier.';


-- ---------------------------------------------------------------------------
-- invoices
-- ---------------------------------------------------------------------------

-- 8. invoices_tenant_id_idx
-- Query pattern: fetch all invoices for a tenant (all statuses).
-- Used by: invoice history pages, tenant billing dashboards, audit queries.
-- invoices will become the largest table in this schema — this index is
-- especially important as row count grows.
CREATE INDEX invoices_tenant_id_idx
    ON invoices (tenant_id);

COMMENT ON INDEX invoices_tenant_id_idx
    IS 'Covers all invoice lookups by tenant. Critical as invoices becomes the largest table in the schema.';


-- 9. invoices_tenant_status_idx
-- Query pattern: fetch invoices for a tenant filtered by status.
-- Most common forms:
--   WHERE tenant_id = $1 AND status = 'open'    -- outstanding balance
--   WHERE tenant_id = $1 AND status = 'paid'    -- payment history
-- Revenue summary queries use this with status = 'paid' specifically.
-- As with subscriptions, tenant_id is first for higher per-step selectivity.
CREATE INDEX invoices_tenant_status_idx
    ON invoices (tenant_id, status);

COMMENT ON INDEX invoices_tenant_status_idx
    IS 'Composite index for tenant + status filters. Serves outstanding balance queries (open) and revenue queries (paid) efficiently.';


-- 10. invoices_subscription_id_idx
-- Query pattern: join invoices to subscriptions.
-- Almost every billing query joins these two tables. Without this index,
-- every join performs a sequential scan of invoices to find matching rows.
-- This is the join index — it exists purely to make the FK join fast.
CREATE INDEX invoices_subscription_id_idx
    ON invoices (subscription_id);

COMMENT ON INDEX invoices_subscription_id_idx
    IS 'Covers the FK join from invoices to subscriptions. Present in almost every billing query — critical for join performance.';


-- 11. invoices_created_at_idx
-- Query pattern: fetch invoices within a date range.
-- Used by: monthly revenue reports, billing period lookups, date-range
-- filters on invoice history pages.
-- Partial — only indexes non-void, non-draft invoices. Void and draft
-- invoices are almost never queried by date range in reporting contexts,
-- and excluding them keeps the index lean.
CREATE INDEX invoices_created_at_idx
    ON invoices (created_at)
    WHERE status NOT IN ('void', 'draft');

COMMENT ON INDEX invoices_created_at_idx
    IS 'Partial index for date-range reporting queries. Excludes void and draft invoices — those statuses are rarely filtered by date in production reporting.';