-- =============================================================================
-- Note: Ideally you would want to have these queries run to create a baseline 
-- for comparisons when using `EXPLAIN ANALYZE` i.e performance comparisons after 
-- applying indexes. (At this point I havent applied indexes only written them.)
-- =============================================================================
-- =============================================================================
-- Query: tenant_usage
-- Phase: 2
-- =============================================================================
-- Active tenants with their current plan, subscription status, and
-- outstanding balance (sum of open invoice amounts).
--
-- What this query answers:
--   Which tenants are active right now, what plan are they on, and how much
--   do they currently owe?
--
-- Joins:
--   tenants -> subscriptions (on tenant_id, filtered to active/trialing)
--   subscriptions -> plans   (on plan_id)
--   subscriptions -> invoices (LEFT JOIN, filtered to open invoices only)
--
-- Index usage (after 002_indexes.sql is applied):
--   subscriptions_tenant_status_idx   — WHERE s.status IN (...)
--   subscriptions_plan_id_idx         — JOIN to plans
--   invoices_tenant_status_idx        — LEFT JOIN filtered to open invoices
--   invoices_subscription_id_idx      — JOIN subscriptions to invoices
-- =============================================================================

SELECT
    t.id                                            AS tenant_id,
    t.name                                          AS tenant_name,
    t.slug                                          AS tenant_slug,
    t.created_at                                    AS tenant_since,
    p.name                                          AS plan_name,
    p.billing_cycle                                 AS billing_cycle,
    p.price_cents                                   AS plan_price_cents,
    ROUND(p.price_cents / 100.0, 2)                 AS plan_price_dollars,
    p.api_limit                                     AS api_limit,
    s.status                                        AS subscription_status,
    s.current_period_start                          AS period_start,
    s.current_period_end                            AS period_end,
    -- Days remaining in current billing period
    (s.current_period_end::date - current_date)     AS days_remaining_in_period,
    -- Outstanding balance: sum of open invoices only
    -- COALESCE handles the case where there are no open invoices (e.g. trialing)
    COALESCE(SUM(i.amount_cents), 0)                AS outstanding_cents,
    ROUND(COALESCE(SUM(i.amount_cents), 0) / 100.0, 2) AS outstanding_dollars,
    COUNT(i.id)                                     AS open_invoice_count
FROM tenants t
JOIN subscriptions s
    ON  s.tenant_id  = t.id
    AND s.status     IN ('active', 'trialing')
JOIN plans p
    ON  p.id         = s.plan_id
LEFT JOIN invoices i
    ON  i.subscription_id = s.id
    AND i.status          = 'open'          -- open invoices only for balance
WHERE t.deleted_at IS NULL
GROUP BY
    t.id,
    t.name,
    t.slug,
    t.created_at,
    p.name,
    p.billing_cycle,
    p.price_cents,
    p.api_limit,
    s.status,
    s.current_period_start,
    s.current_period_end
ORDER BY
    outstanding_cents   DESC,
    t.name              ASC;


-- ---------------------------------------------------------------------------
-- Variant: tenants approaching renewal in the next 7 days
-- ---------------------------------------------------------------------------
-- Used by renewal jobs and proactive support outreach.
-- Relies on subscriptions_period_end_idx for performance.

SELECT
    t.name                                          AS tenant_name,
    p.name                                          AS plan_name,
    p.price_cents                                   AS renewal_amount_cents,
    ROUND(p.price_cents / 100.0, 2)                 AS renewal_amount_dollars,
    s.current_period_end                            AS renews_at,
    (s.current_period_end::date - current_date)     AS days_until_renewal
FROM tenants t
JOIN subscriptions s
    ON  s.tenant_id  = t.id
    AND s.status     = 'active'
JOIN plans p
    ON  p.id         = s.plan_id
WHERE t.deleted_at          IS NULL
  AND s.current_period_end  BETWEEN now() AND now() + interval '7 days'
ORDER BY
    s.current_period_end ASC;


-- ---------------------------------------------------------------------------
-- Variant: plan distribution — how many active tenants are on each plan
-- ---------------------------------------------------------------------------
-- Used by product and finance teams to understand plan adoption.

SELECT
    p.name                                          AS plan_name,
    p.billing_cycle                                 AS billing_cycle,
    ROUND(p.price_cents / 100.0, 2)                 AS price_dollars,
    COUNT(s.id)                                     AS active_tenant_count,
    -- Monthly recurring revenue contribution from this plan
    -- Annual plans divided by 12 to normalise to MRR
    ROUND(
        SUM(
            CASE p.billing_cycle
                WHEN 'monthly' THEN p.price_cents
                WHEN 'annual'  THEN p.price_cents / 12.0
            END
        ) / 100.0,
    2)                                              AS mrr_contribution_dollars
FROM subscriptions s
JOIN plans  p ON p.id = s.plan_id
JOIN tenants t ON t.id = s.tenant_id
WHERE s.status      = 'active'
  AND t.deleted_at IS NULL
GROUP BY
    p.id,
    p.name,
    p.billing_cycle,
    p.price_cents
ORDER BY
    active_tenant_count DESC;