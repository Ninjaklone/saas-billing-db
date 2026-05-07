-- I did not plan to create this folder.
-- But for the sake of Modularity without the need to comb through the raw 'schema.sql'
-- file, I'll divide the key sections up amongst several files.
-- If there are any increments they will go in schema/migrations/.
-- =============================================================================
-- Migration: 001_core_tables
-- Phase:     1
-- Date:      2025-04-01
-- Author:    Gara Kinkinsoko Joshua
-- =============================================================================
-- Creates the five core tables for the saas-billing-db schema.
-- Should be run on fresh database — no IF NOT EXISTS guards.
-- For incremental changes use subsequent migration files under schema/migrations/.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
-- gen_random_uuid() is built-in from PostgreSQL 13+. No extension needed.

-- ---------------------------------------------------------------------------
-- 1. tenants
-- ---------------------------------------------------------------------------
CREATE TABLE tenants (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    slug        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT tenants_slug_unique          UNIQUE (slug),
    CONSTRAINT tenants_slug_format          CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
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
CREATE TABLE plans (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT        NOT NULL,
    price_cents   INT         NOT NULL,
    billing_cycle TEXT        NOT NULL,
    api_limit     INT,
    is_active     BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT plans_price_non_negative  CHECK (price_cents >= 0),
    CONSTRAINT plans_billing_cycle_valid CHECK (billing_cycle IN ('monthly', 'annual')),
    CONSTRAINT plans_api_limit_positive  CHECK (api_limit IS NULL OR api_limit > 0),
    CONSTRAINT plans_name_unique         UNIQUE (name)
);

COMMENT ON TABLE  plans             IS 'Pricing tiers available on the platform. Not tenant-specific.';
COMMENT ON COLUMN plans.price_cents IS 'Monthly or annual price in cents. Use INT, never FLOAT. 0 = free plan.';
COMMENT ON COLUMN plans.api_limit   IS 'Max API calls per billing cycle. NULL = unlimited.';
COMMENT ON COLUMN plans.is_active   IS 'FALSE = plan is retired. Existing subscriptions keep the old plan_id; new subscriptions cannot use it.';

-- ---------------------------------------------------------------------------
-- 3. users
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID        NOT NULL REFERENCES tenants(id),
    email       TEXT        NOT NULL,
    role        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at  TIMESTAMPTZ,

    CONSTRAINT users_tenant_email_unique    UNIQUE (tenant_id, email),
    CONSTRAINT users_email_format           CHECK (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT users_role_valid             CHECK (role IN ('admin', 'member', 'viewer')),
    CONSTRAINT users_deleted_after_created  CHECK (
        deleted_at IS NULL OR deleted_at > created_at
    )
);

COMMENT ON TABLE  users            IS 'Individual users scoped to a tenant. Email unique per tenant, not globally.';
COMMENT ON COLUMN users.role       IS 'admin = full access; member = standard access; viewer = read-only.';
COMMENT ON COLUMN users.deleted_at IS 'NULL = active. Set to soft-delete. Role is preserved for audit history.';

-- ---------------------------------------------------------------------------
-- 4. subscriptions
-- ---------------------------------------------------------------------------
CREATE TABLE subscriptions (
    id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            UUID        NOT NULL REFERENCES tenants(id),
    plan_id              UUID        NOT NULL REFERENCES plans(id),
    status               TEXT        NOT NULL,
    current_period_start TIMESTAMPTZ NOT NULL,
    current_period_end   TIMESTAMPTZ NOT NULL,
    cancelled_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT subscriptions_status_valid            CHECK (status IN ('active', 'cancelled', 'past_due', 'trialing')),
    CONSTRAINT subscriptions_period_valid            CHECK (current_period_end > current_period_start),
    CONSTRAINT subscriptions_cancelled_consistency   CHECK (
        (status = 'cancelled' AND cancelled_at IS NOT NULL)
        OR
        (status <> 'cancelled' AND cancelled_at IS NULL)
    ),
    CONSTRAINT subscriptions_cancelled_after_created CHECK (
        cancelled_at IS NULL OR cancelled_at >= created_at
    )
);

COMMENT ON TABLE  subscriptions                    IS 'Tenant plan enrollments. Retain all rows — historical subscriptions are audit evidence.';
COMMENT ON COLUMN subscriptions.status             IS 'active | trialing | past_due | cancelled. One active subscription per tenant enforced via partial unique index.';
COMMENT ON COLUMN subscriptions.current_period_end IS 'End of current billing cycle. Do not recycle rows on renewal — insert a new subscription instead.';
COMMENT ON COLUMN subscriptions.cancelled_at       IS 'Must be set iff status = cancelled. Enforced by check constraint.';

-- ---------------------------------------------------------------------------
-- 5. invoices
-- ---------------------------------------------------------------------------
CREATE TABLE invoices (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID        NOT NULL REFERENCES tenants(id),
    subscription_id UUID        NOT NULL REFERENCES subscriptions(id),
    amount_cents    INT         NOT NULL,
    status          TEXT        NOT NULL,
    due_date        DATE        NOT NULL,
    paid_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT invoices_amount_non_negative CHECK (amount_cents >= 0),
    CONSTRAINT invoices_status_valid        CHECK (status IN ('draft', 'open', 'paid', 'void', 'uncollectible')),
    CONSTRAINT invoices_paid_consistency    CHECK (
        (status = 'paid' AND paid_at IS NOT NULL)
        OR
        (status <> 'paid' AND paid_at IS NULL)
    ),
    CONSTRAINT invoices_paid_after_created  CHECK (paid_at IS NULL OR paid_at >= created_at),
    CONSTRAINT invoices_due_date_valid      CHECK (due_date >= created_at::DATE)
);

COMMENT ON TABLE  invoices              IS 'Financial ledger. APPEND-ONLY — no UPDATE or DELETE, ever. Voids and corrections are new rows.';
COMMENT ON COLUMN invoices.amount_cents IS 'Charge amount in cents. INT, never FLOAT. 0 valid for free-plan invoices.';
COMMENT ON COLUMN invoices.status       IS 'draft → open → paid | void | uncollectible. Mirrors Stripe lifecycle.';
COMMENT ON COLUMN invoices.paid_at      IS 'Timestamp of payment confirmation. NULL until paid. Set iff status = paid.';