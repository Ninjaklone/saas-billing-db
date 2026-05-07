-- =============================================================================
-- Migration: 002_indexes
-- Phase:     2
-- Date:      2025-04-07
-- Author:    Gara Kinkinsoko Joshua
-- =============================================================================
-- Indexes for the five core tables.
--
-- Every index here targets a specific, documented query pattern.
-- Do not add indexes speculatively — each one has a named reason.
--
-- Run EXPLAIN ANALYZE on affected queries before and after applying this file.
-- Save both outputs in queries/README.md.
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