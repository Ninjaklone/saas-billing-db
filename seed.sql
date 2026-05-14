-- =============================================================================
-- UUID Prefix Convention
-- =============================================================================
-- All seed UUIDs follow the pattern: <prefix>000000-0000-0000-0000-00000000000N
-- where N is the row number within that table.
--
-- Prefixes are two hexadecimal characters (0-9, a-f only).
-- One prefix per table — no reuse for the sake of uniqueness.
--
-- Current assignments:
--   a1 — plans
--   a2 — plan_change_events
--   b1 — tenants
--   c1 — users
--   d1 — subscriptions
--   e1 — invoices
--   f1 — billing_audit_log
-- =============================================================================
-- =============================================================================
-- saas-billing-db: Seed Data — Phase 1
-- =============================================================================
-- 5 realistic tenants across varied plan types, billing cycles, subscription
-- statuses, and invoice states. Includes edge cases:
--   - A tenant on a free plan
--   - A tenant mid-cancellation (past_due)
--   - A cancelled subscription with a follow-on active one (plan change)
--   - A voided invoice
--   - An uncollectible invoice
--   - A trialing tenant who has never been invoiced
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Plans
-- ---------------------------------------------------------------------------
-- Insert plans first — subscriptions and invoices reference them.
-- Four tiers: free, starter (monthly), pro (monthly), enterprise (annual).

INSERT INTO plans (id, name, price_cents, billing_cycle, api_limit, is_active) VALUES
    ('a1000000-0000-0000-0000-000000000001', 'free',       0,      'monthly', 1000,  TRUE),
    ('a1000000-0000-0000-0000-000000000002', 'starter',    2900,   'monthly', 10000, TRUE),
    ('a1000000-0000-0000-0000-000000000003', 'pro',        9900,   'monthly', NULL,  TRUE),  -- NULL = unlimited
    ('a1000000-0000-0000-0000-000000000004', 'enterprise', 49900,  'annual',  NULL,  TRUE),
    ('a1000000-0000-0000-0000-000000000005', 'starter-legacy', 1900, 'monthly', 5000, FALSE); -- retired plan (gotta make it real)

-- ---------------------------------------------------------------------------
-- Tenants
-- ---------------------------------------------------------------------------

INSERT INTO tenants (id, name, slug, created_at, deleted_at) VALUES
    -- 1. Acme Corp — healthy pro subscriber, long-standing customer
    ('b1000000-0000-0000-0000-000000000001', 'Acme Corp',          'acme-corp',       '2023-06-15 09:00:00+00', NULL),

    -- 2. Bright Ledger — enterprise annual subscriber
    ('b1000000-0000-0000-0000-000000000002', 'Bright Ledger Ltd',  'bright-ledger',   '2023-09-01 11:30:00+00', NULL),

    -- 3. Nomad Stack — past_due, needs intervention
    ('b1000000-0000-0000-0000-000000000003', 'Nomad Stack',        'nomad-stack',     '2024-01-10 14:00:00+00', NULL),

    -- 4. Pebble HR — upgraded from starter to pro mid-lifecycle
    ('b1000000-0000-0000-0000-000000000004', 'Pebble HR',          'pebble-hr',       '2024-03-20 08:00:00+00', NULL),

    -- 5. Drifter Tools — trialing, no invoices yet
    ('b1000000-0000-0000-0000-000000000005', 'Drifter Tools',      'drifter-tools',   '2025-03-01 10:00:00+00', NULL),

    -- 6. Soft-deleted tenant — tests that deleted tenants are excluded from active queries
    ('b1000000-0000-0000-0000-000000000006', 'Defunct Systems Inc','defunct-systems', '2023-11-01 09:00:00+00', '2024-06-30 17:00:00+00');

-- ---------------------------------------------------------------------------
-- Users
-- ---------------------------------------------------------------------------

INSERT INTO users (id, tenant_id, email, role, created_at, deleted_at) VALUES
    -- Acme Corp
    ('c1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'sara.chen@acmecorp.io',    'admin',  '2023-06-15 09:05:00+00', NULL),
    ('c1000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 'james.obi@acmecorp.io',    'member', '2023-07-01 10:00:00+00', NULL),
    ('c1000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-000000000001', 'lena.marsh@acmecorp.io',   'viewer', '2023-08-12 09:00:00+00', NULL),

    -- Bright Ledger
    ('c1000000-0000-0000-0000-000000000004', 'b1000000-0000-0000-0000-000000000002', 'admin@brightledger.com',   'admin',  '2023-09-01 11:35:00+00', NULL),
    ('c1000000-0000-0000-0000-000000000005', 'b1000000-0000-0000-0000-000000000002', 'ops@brightledger.com',     'member', '2023-09-05 09:00:00+00', NULL),

    -- Nomad Stack
    ('c1000000-0000-0000-0000-000000000006', 'b1000000-0000-0000-0000-000000000003', 'founder@nomadstack.dev',   'admin',  '2024-01-10 14:05:00+00', NULL),

    -- Pebble HR
    ('c1000000-0000-0000-0000-000000000007', 'b1000000-0000-0000-0000-000000000004', 'it@pebblehr.com',          'admin',  '2024-03-20 08:10:00+00', NULL),
    ('c1000000-0000-0000-0000-000000000008', 'b1000000-0000-0000-0000-000000000004', 'billing@pebblehr.com',     'member', '2024-03-20 08:15:00+00', NULL),
    -- Soft-deleted user (left the company)
    ('c1000000-0000-0000-0000-000000000009', 'b1000000-0000-0000-0000-000000000004', 'ex-cto@pebblehr.com',      'admin',  '2024-03-20 08:20:00+00', '2024-09-01 17:00:00+00'),

    -- Drifter Tools
    ('c1000000-0000-0000-0000-000000000010', 'b1000000-0000-0000-0000-000000000005', 'hello@driftertools.io',    'admin',  '2025-03-01 10:05:00+00', NULL),

    -- Defunct Systems (soft-deleted tenant — users retained for history)
    ('c1000000-0000-0000-0000-000000000011', 'b1000000-0000-0000-0000-000000000006', 'owner@defunct.example',   'admin',  '2023-11-01 09:10:00+00', NULL);

-- ---------------------------------------------------------------------------
-- Subscriptions
-- ---------------------------------------------------------------------------

INSERT INTO subscriptions (id, tenant_id, plan_id, status, current_period_start, current_period_end, cancelled_at, created_at) VALUES

    -- Acme Corp — active on pro, currently in April 2025 billing period
    ('d1000000-0000-0000-0000-000000000001',
     'b1000000-0000-0000-0000-000000000001',
     'a1000000-0000-0000-0000-000000000003', -- pro
     'active',
     '2025-04-01 00:00:00+00',
     '2025-04-30 23:59:59+00',
     NULL,
     '2023-06-15 09:10:00+00'),

    -- Bright Ledger — active on enterprise annual
    ('d1000000-0000-0000-0000-000000000002',
     'b1000000-0000-0000-0000-000000000002',
     'a1000000-0000-0000-0000-000000000004', -- enterprise
     'active',
     '2025-01-01 00:00:00+00',
     '2025-12-31 23:59:59+00',
     NULL,
     '2023-09-01 11:40:00+00'),

    -- Nomad Stack — past_due, payment failed
    ('d1000000-0000-0000-0000-000000000003',
     'b1000000-0000-0000-0000-000000000003',
     'a1000000-0000-0000-0000-000000000002', -- starter
     'past_due',
     '2025-03-01 00:00:00+00',
     '2025-03-31 23:59:59+00',
     NULL,
     '2024-01-10 14:10:00+00'),

    -- Pebble HR — cancelled starter subscription (before they upgraded)
    ('d1000000-0000-0000-0000-000000000004',
     'b1000000-0000-0000-0000-000000000004',
     'a1000000-0000-0000-0000-000000000002', -- starter
     'cancelled',
     '2024-03-20 00:00:00+00',
     '2024-09-19 23:59:59+00',
     '2024-09-15 11:00:00+00',
     '2024-03-20 08:30:00+00'),

    -- Pebble HR — active pro subscription (plan upgrade, new subscription row)
    ('d1000000-0000-0000-0000-000000000005',
     'b1000000-0000-0000-0000-000000000004',
     'a1000000-0000-0000-0000-000000000003', -- pro
     'active',
     '2025-04-01 00:00:00+00',
     '2025-04-30 23:59:59+00',
     NULL,
     '2024-09-15 11:05:00+00'),

    -- Drifter Tools — trialing, no invoices yet
    ('d1000000-0000-0000-0000-000000000006',
     'b1000000-0000-0000-0000-000000000005',
     'a1000000-0000-0000-0000-000000000002', -- starter
     'trialing',
     '2025-03-01 00:00:00+00',
     '2025-03-28 23:59:59+00',
     NULL,
     '2025-03-01 10:10:00+00'),

    -- Defunct Systems — cancelled subscription (tenant was soft-deleted after)
    ('d1000000-0000-0000-0000-000000000007',
     'b1000000-0000-0000-0000-000000000006',
     'a1000000-0000-0000-0000-000000000002', -- starter
     'cancelled',
     '2023-11-01 00:00:00+00',
     '2024-06-30 23:59:59+00',
     '2024-06-25 09:00:00+00',
     '2023-11-01 09:15:00+00');

-- ---------------------------------------------------------------------------
-- Invoices
-- ---------------------------------------------------------------------------
-- Covers: paid, open, void, uncollectible. Specifically Drifter Tools has no invoices
-- (trialing). Pebble HR has invoices under both subscriptions.

INSERT INTO invoices (id, tenant_id, subscription_id, amount_cents, status, due_date, paid_at, created_at) VALUES

    -- Acme Corp — 6 months of paid pro invoices + 1 open current month
    ('e1000000-0000-0000-0000-000000000001',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'paid', '2024-11-08', '2024-11-02 10:15:00+00', '2024-11-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000002',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'paid', '2024-12-08', '2024-12-03 09:40:00+00', '2024-12-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000003',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'paid', '2025-01-08', '2025-01-04 11:00:00+00', '2025-01-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000004',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'paid', '2025-02-08', '2025-02-03 14:22:00+00', '2025-02-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000005',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'paid', '2025-03-08', '2025-03-05 09:10:00+00', '2025-03-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000006',
     'b1000000-0000-0000-0000-000000000001',
     'd1000000-0000-0000-0000-000000000001', 9900, 'open', '2025-04-08', NULL, '2025-04-01 00:00:00+00'),

    -- Bright Ledger — single annual enterprise invoice (paid upfront)
    ('e1000000-0000-0000-0000-000000000007',
     'b1000000-0000-0000-0000-000000000002',
     'd1000000-0000-0000-0000-000000000002', 49900, 'paid', '2025-01-08', '2025-01-03 16:00:00+00', '2025-01-01 00:00:00+00'),

    -- Nomad Stack — one paid invoice, one that became uncollectible
    ('e1000000-0000-0000-0000-000000000008',
     'b1000000-0000-0000-0000-000000000003',
     'd1000000-0000-0000-0000-000000000003', 2900, 'paid', '2025-02-08', '2025-02-06 08:30:00+00', '2025-02-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000009',
     'b1000000-0000-0000-0000-000000000003',
     'd1000000-0000-0000-0000-000000000003', 2900, 'uncollectible', '2025-03-08', NULL, '2025-03-01 00:00:00+00'),

    -- Pebble HR — starter period invoices
    ('e1000000-0000-0000-0000-000000000010',
     'b1000000-0000-0000-0000-000000000004',
     'd1000000-0000-0000-0000-000000000004', 2900, 'paid', '2024-04-27', '2024-04-25 10:00:00+00', '2024-04-20 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000011',
     'b1000000-0000-0000-0000-000000000004',
     'd1000000-0000-0000-0000-000000000004', 2900, 'paid', '2024-07-27', '2024-07-24 11:30:00+00', '2024-07-20 00:00:00+00'),

    -- Pebble HR — voided invoice (issued in error before plan change was processed)
    ('e1000000-0000-0000-0000-000000000012',
     'b1000000-0000-0000-0000-000000000004',
     'd1000000-0000-0000-0000-000000000004', 2900, 'void', '2024-09-27', NULL, '2024-09-15 11:00:00+00'),

    -- Pebble HR — pro invoices after upgrade
    ('e1000000-0000-0000-0000-000000000013',
     'b1000000-0000-0000-0000-000000000004',
     'd1000000-0000-0000-0000-000000000005', 9900, 'paid', '2024-10-08', '2024-10-06 09:00:00+00', '2024-10-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000014',
     'b1000000-0000-0000-0000-000000000004',
     'd1000000-0000-0000-0000-000000000005', 9900, 'open', '2025-04-08', NULL, '2025-04-01 00:00:00+00'),

    -- Defunct Systems — paid invoices before churn (historical record preserved)
    ('e1000000-0000-0000-0000-000000000015',
     'b1000000-0000-0000-0000-000000000006',
     'd1000000-0000-0000-0000-000000000007', 2900, 'paid', '2024-02-08', '2024-02-05 14:00:00+00', '2024-02-01 00:00:00+00'),

    ('e1000000-0000-0000-0000-000000000016',
     'b1000000-0000-0000-0000-000000000006',
     'd1000000-0000-0000-0000-000000000007', 2900, 'paid', '2024-05-08', '2024-05-03 10:00:00+00', '2024-05-01 00:00:00+00');


-- ---------------------------------------------------------------------------
-- api_usage_events seed
-- ---------------------------------------------------------------------------
-- Hourly buckets across April 2025 for active tenants.
-- Covers: normal usage, a tenant approaching their API limit (Nomad Stack
-- on starter with 10k limit), and a tenant on an unlimited plan (Acme Corp).
-- Drifter Tools is trialing — included to verify they appear in
-- billing_summaries with usage correctly scoped to their trial period.

INSERT INTO api_usage_events (tenant_id, recorded_at, endpoint, event_count) VALUES

    -- Acme Corp (pro, unlimited) — steady usage across two endpoints
    ('b1000000-0000-0000-0000-000000000001', '2025-04-01 09:00:00+00', '/api/v1/invoices',      142),
    ('b1000000-0000-0000-0000-000000000001', '2025-04-01 09:00:00+00', '/api/v1/subscriptions',  87),
    ('b1000000-0000-0000-0000-000000000001', '2025-04-01 10:00:00+00', '/api/v1/invoices',      198),
    ('b1000000-0000-0000-0000-000000000001', '2025-04-01 10:00:00+00', '/api/v1/subscriptions',  64),
    ('b1000000-0000-0000-0000-000000000001', '2025-04-02 09:00:00+00', '/api/v1/invoices',      211),
    ('b1000000-0000-0000-0000-000000000001', '2025-04-02 09:00:00+00', '/api/v1/subscriptions', 103),

    -- Bright Ledger (enterprise, unlimited) — lower volume, single endpoint
    ('b1000000-0000-0000-0000-000000000002', '2025-04-01 08:00:00+00', '/api/v1/invoices',       45),
    ('b1000000-0000-0000-0000-000000000002', '2025-04-01 14:00:00+00', '/api/v1/invoices',       62),
    ('b1000000-0000-0000-0000-000000000002', '2025-04-02 08:00:00+00', '/api/v1/invoices',       38),

    -- Nomad Stack (starter, 10k limit) — heavy usage, approaching limit
    -- Total here: 8,847 calls — close to the 10k ceiling
    ('b1000000-0000-0000-0000-000000000003', '2025-03-01 09:00:00+00', '/api/v1/invoices',     2341),
    ('b1000000-0000-0000-0000-000000000003', '2025-03-01 10:00:00+00', '/api/v1/invoices',     1876),
    ('b1000000-0000-0000-0000-000000000003', '2025-03-02 09:00:00+00', '/api/v1/invoices',     2109),
    ('b1000000-0000-0000-0000-000000000003', '2025-03-02 10:00:00+00', '/api/v1/invoices',     2521),

    -- Pebble HR (pro, unlimited) — usage split across both subscription periods
    -- Events during the old starter subscription period
    ('b1000000-0000-0000-0000-000000000004', '2024-04-20 11:00:00+00', '/api/v1/users',          93),
    ('b1000000-0000-0000-0000-000000000004', '2024-04-20 14:00:00+00', '/api/v1/users',          71),
    -- Events during the current pro subscription period
    ('b1000000-0000-0000-0000-000000000004', '2025-04-01 09:00:00+00', '/api/v1/users',         187),
    ('b1000000-0000-0000-0000-000000000004', '2025-04-01 09:00:00+00', '/api/v1/invoices',      134),
    ('b1000000-0000-0000-0000-000000000004', '2025-04-02 09:00:00+00', '/api/v1/users',         209),

    -- Drifter Tools (trialing, starter) — light usage within trial period
    ('b1000000-0000-0000-0000-000000000005', '2025-03-05 10:00:00+00', '/api/v1/invoices',       28),
    ('b1000000-0000-0000-0000-000000000005', '2025-03-05 11:00:00+00', '/api/v1/invoices',       14);

-- Defunct Systems intentionally has no usage events.
-- Their subscription was cancelled before this table existed in the schema.
--
--
-- ---------------------------------------------------------------------------
-- billing_audit_log seed
-- ---------------------------------------------------------------------------
-- Simulates the status history that would have been recorded had the trigger
-- existed when the subscription and invoice seed data was inserted.
-- Inserted directly — triggers only fire on UPDATE, not INSERT.

INSERT INTO billing_audit_log (id, table_name, row_id, changed_by, old_status, new_status, changed_at) VALUES

    -- Pebble HR starter subscription cancelled ahead of plan upgrade
    ('f1000000-0000-0000-0000-000000000001',
     'subscriptions',
     'd1000000-0000-0000-0000-000000000004',
     'system', 'active', 'cancelled', '2024-09-15 11:00:00+00'),

    -- Nomad Stack subscription moved to past_due after failed payment
    ('f1000000-0000-0000-0000-000000000002',
     'subscriptions',
     'd1000000-0000-0000-0000-000000000003',
     'system', 'active', 'past_due', '2025-03-09 08:00:00+00'),

    -- Defunct Systems subscription cancelled
    ('f1000000-0000-0000-0000-000000000003',
     'subscriptions',
     'd1000000-0000-0000-0000-000000000007',
     'system', 'active', 'cancelled', '2024-06-25 09:00:00+00'),

    -- Pebble HR voided invoice (issued in error during plan change)
    ('f1000000-0000-0000-0000-000000000004',
     'invoices',
     'e1000000-0000-0000-0000-000000000012',
     'system', 'open', 'void', '2024-09-15 11:05:00+00'),

    -- Nomad Stack invoice moved to uncollectible after failed collection
    ('f1000000-0000-0000-0000-000000000005',
     'invoices',
     'e1000000-0000-0000-0000-000000000009',
     'system', 'open', 'uncollectible', '2025-03-15 09:00:00+00');


     -- ---------------------------------------------------------------------------
-- plan_change_events seed
-- ---------------------------------------------------------------------------
-- Reconstructs the proration event for Pebble HR's upgrade from starter
-- ($29/month) to pro ($99/month) on 2024-09-15.
--
-- Billing period: 2024-09-01 to 2024-09-30 (30 days in September)
-- Effective at:   2024-09-15
-- Days remaining: 15 (Sep 15 to Sep 30, inclusive of change date)
-- Days in cycle:  30
--
-- Old daily rate: 2900 / 30 = 96.67 cents
-- New daily rate: 9900 / 30 = 330.00 cents
--
-- Credit:  FLOOR(96.67  * 15) = FLOOR(1450.05) = 1450 cents ($14.50)
-- Charge:  CEIL(330.00  * 15) = CEIL(4950.00)  = 4950 cents ($49.50)
-- Net:     4950 - 1450        = 3500 cents ($35.00)

INSERT INTO plan_change_events (
    id, tenant_id, subscription_id,
    old_plan_id, new_plan_id,
    effective_at, days_remaining, days_in_cycle,
    credit_cents, charge_cents, net_cents, created_at
) VALUES (
    'a2000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000004',  -- Pebble HR
    'd1000000-0000-0000-0000-000000000004',  -- cancelled starter subscription
    'a1000000-0000-0000-0000-000000000002',  -- starter
    'a1000000-0000-0000-0000-000000000003',  -- pro
    '2024-09-15 11:05:00+00',
    15, 30,
    1450, 4950, 3500,
    '2024-09-15 11:05:00+00'
);