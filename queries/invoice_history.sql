-- =============================================================================
-- Note: Ideally you would want to have these queries run to create a baseline 
-- for comparisons when using `EXPLAIN ANALYZE` i.e performance comparisons after 
-- applying indexes. (At this point I havent applied indexes only written them.)
-- =============================================================================
-- =============================================================================
-- Query: invoice_history
-- Phase: 2
-- =============================================================================
-- Full invoice timeline per tenant — every invoice, every status, ordered
-- chronologically. Used by support teams when a customer disputes a charge.
--
-- What this query answers:
--   What is the complete invoice history for a given tenant, and what is the
--   current status of each invoice?
--
-- Edge cases handled:
--   - LEFT JOIN from subscriptions to invoices ensures tenants with no
--     invoices (Drifter Tools, trialing) still appear in results with NULL
--     invoice fields. An INNER JOIN would silently drop them — that is a bug.
--   - Void invoices appear in the timeline with status clearly labelled.
--     They must be visible in history but excluded from balance calculations.
--   - Both subscription rows for Pebble HR appear (cancelled starter +
--     active pro), each with their respective invoices.
--   - Soft-deleted tenants are excluded.
--
-- Joins:
--   tenants → subscriptions (LEFT JOIN — tenant may have no subscriptions)
--   subscriptions → invoices (LEFT JOIN — subscription may have no invoices)
--   subscriptions → plans    (JOIN — every subscription has a plan)
--
-- Index usage (after 002_indexes.sql is applied):
--   subscriptions_tenant_id_idx       — JOIN tenants to subscriptions
--   invoices_subscription_id_idx      — JOIN subscriptions to invoices
--   invoices_tenant_id_idx            — WHERE t.id = $1 filter path
-- =============================================================================

SELECT
    t.id                                            AS tenant_id,
    t.name                                          AS tenant_name,
    s.id                                            AS subscription_id,
    s.status                                        AS subscription_status,
    p.name                                          AS plan_name,
    p.billing_cycle                                 AS billing_cycle,
    s.current_period_start                          AS period_start,
    s.current_period_end                            AS period_end,
    i.id                                            AS invoice_id,
    i.amount_cents                                  AS amount_cents,
    ROUND(i.amount_cents / 100.0, 2)                AS amount_dollars,
    i.status                                        AS invoice_status,
    i.due_date                                      AS due_date,
    i.paid_at                                       AS paid_at,
    i.created_at                                    AS invoice_created_at
FROM tenants t
LEFT JOIN subscriptions s ON s.tenant_id = t.id
LEFT JOIN plans         p ON p.id = s.plan_id
LEFT JOIN invoices      i ON i.subscription_id = s.id
WHERE t.deleted_at IS NULL
ORDER BY
    t.name              ASC,
    s.created_at        ASC,
    i.created_at        ASC NULLS LAST;


-- ---------------------------------------------------------------------------
-- Variant: invoice history for a single tenant
-- ---------------------------------------------------------------------------
-- Replace $1 with the tenant UUID when running directly.
-- In application code this becomes a prepared statement parameter.

SELECT
    s.id                                            AS subscription_id,
    s.status                                        AS subscription_status,
    p.name                                          AS plan_name,
    i.id                                            AS invoice_id,
    ROUND(i.amount_cents / 100.0, 2)                AS amount_dollars,
    i.status                                        AS invoice_status,
    i.due_date                                      AS due_date,
    i.paid_at                                       AS paid_at,
    i.created_at                                    AS invoice_created_at
FROM tenants t
LEFT JOIN subscriptions s ON s.tenant_id = t.id
LEFT JOIN plans         p ON p.id = s.plan_id
LEFT JOIN invoices      i ON i.subscription_id = s.id
WHERE t.id         = 'b1000000-0000-0000-0000-000000000004'  -- Pebble HR
  AND t.deleted_at IS NULL
ORDER BY
    s.created_at    ASC,
    i.created_at    ASC NULLS LAST;


-- ---------------------------------------------------------------------------
-- Variant: outstanding invoices only (open + past_due) across all tenants
-- ---------------------------------------------------------------------------
-- Used by finance teams to see what is currently owed.
-- Excludes void, draft, paid, uncollectible.

SELECT
    t.name                                          AS tenant_name,
    p.name                                          AS plan_name,
    i.id                                            AS invoice_id,
    ROUND(i.amount_cents / 100.0, 2)                AS amount_dollars,
    i.status                                        AS invoice_status,
    i.due_date                                      AS due_date,
    -- How many days overdue (negative = not yet due)
    (current_date - i.due_date)                     AS days_overdue
FROM invoices i
JOIN subscriptions s ON s.id = i.subscription_id
JOIN plans         p ON p.id = s.plan_id
JOIN tenants       t ON t.id = i.tenant_id
WHERE i.status       IN ('open', 'past_due')
  AND t.deleted_at  IS NULL
ORDER BY
    days_overdue    DESC,
    t.name          ASC;