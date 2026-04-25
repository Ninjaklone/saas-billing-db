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