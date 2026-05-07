-- =============================================================================
-- Note: Ideally you would want to have these queries run to create a baseline 
-- for comparisons when using `EXPLAIN ANALYZE` i.e performance comparisons after 
-- applying indexes. (At this point I havent applied indexes only written them.)
-- =============================================================================
-- =============================================================================
-- Query: billing_summary
-- Phase: 2
-- =============================================================================
-- Total revenue per tenant per billing period, restricted to paid invoices.
--
-- What this query answers:
--   How much did each tenant pay, in which billing period, and on which plan?
--
-- Edge cases handled:
--   - Void and uncollectible invoices are excluded from revenue totals.
--     (Nomad Stack's uncollectible and Pebble HR's voided invoice must not
--     appear in revenue figures.)
--   - Soft-deleted tenants are excluded.
--   - Tenants with no paid invoices do not appear in results.
--     (Drifter Tools is trialing with no invoices — correct to omit here.)
--   - Annual plans produce a single large row rather than 12 monthly rows.
--     (Bright Ledger's $499 enterprise invoice is a single row — correct.)
--
-- Joins:
--   invoices → subscriptions (on subscription_id)
--   subscriptions → plans    (on plan_id)
--   invoices → tenants       (on tenant_id)
--
-- Index usage (after 002_indexes.sql is applied):
--   invoices_tenant_status_idx        — WHERE i.status = 'paid'
--   invoices_subscription_id_idx      — JOIN to subscriptions
--   subscriptions_tenant_id_idx       — JOIN to tenants via subscriptions
-- =============================================================================

SELECT
    t.id                                            AS tenant_id,
    t.name                                          AS tenant_name,
    t.slug                                          AS tenant_slug,
    p.name                                          AS plan_name,
    p.billing_cycle                                 AS billing_cycle,
    date_trunc('month', i.created_at)               AS billing_month,
    COUNT(i.id)                                     AS invoice_count,
    SUM(i.amount_cents)                             AS total_cents,
    -- Display-friendly amount in dollars (divide by 100)
    -- Never store this value — compute on read only
    ROUND(SUM(i.amount_cents) / 100.0, 2)           AS total_dollars
FROM invoices i
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans         p ON p.id = s.plan_id
JOIN tenants       t ON t.id = i.tenant_id
WHERE i.status        = 'paid'          -- paid invoices only
  AND t.deleted_at   IS NULL            -- exclude soft-deleted tenants
GROUP BY
    t.id,
    t.name,
    t.slug,
    p.name,
    p.billing_cycle,
    date_trunc('month', i.created_at)
ORDER BY
    t.name ASC,
    billing_month ASC;


-- ---------------------------------------------------------------------------
-- Variant: revenue summary across all tenants for a specific month
-- ---------------------------------------------------------------------------
-- Swap the WHERE clause date filter to parameterise by billing month.
-- Example: April 2025 revenue across all active tenants.

SELECT
    t.name                                          AS tenant_name,
    p.name                                          AS plan_name,
    SUM(i.amount_cents)                             AS total_cents,
    ROUND(SUM(i.amount_cents) / 100.0, 2)           AS total_dollars
FROM invoices i
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans         p ON p.id = s.plan_id
JOIN tenants       t ON t.id = i.tenant_id
WHERE i.status               = 'paid'
  AND t.deleted_at          IS NULL
  AND date_trunc('month', i.created_at) = date_trunc('month', '2025-04-01'::timestamptz)
GROUP BY
    t.name,
    p.name
ORDER BY
    total_cents DESC;


-- ---------------------------------------------------------------------------
-- Variant: lifetime revenue per tenant (single row per tenant)
-- ---------------------------------------------------------------------------

SELECT
    t.id                                            AS tenant_id,
    t.name                                          AS tenant_name,
    COUNT(i.id)                                     AS total_invoices_paid,
    SUM(i.amount_cents)                             AS lifetime_cents,
    ROUND(SUM(i.amount_cents) / 100.0, 2)           AS lifetime_dollars,
    MIN(i.paid_at)                                  AS first_payment_at,
    MAX(i.paid_at)                                  AS most_recent_payment_at
FROM invoices i
JOIN tenants t ON t.id = i.tenant_id
WHERE i.status      = 'paid'
  AND t.deleted_at IS NULL
GROUP BY
    t.id,
    t.name
ORDER BY
    lifetime_cents DESC;