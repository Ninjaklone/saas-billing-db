-- Still Writing Tests in pgAdmin4
-- Need to figure out if I have implemented everything correctly.

-- =============================================================================
-- saas-billing-db: Constraint Assertions — Phase 1
-- =============================================================================
-- Each test will attempt an INSERT that should be rejected.
-- Everything from this point should go within a transaction and roll back — nothing persists.
--
-- Usage: (Command should look something like)
--    psql -h localhost -U postgres -d saas-billing-db -f .\tests\assertions.sql 
--  (On the assumption that a terminal is opened from the directory where this file is stored)
-- 
-- A passing test prints:   PASS: <description>
-- A failing test prints:   FAIL: <description> — constraint did not fire
--
-- If a constraint is missing or misconfigured, the INSERT will succeed
-- and the FAIL message will print. Ideally nothing should FAIL.
-- =============================================================================

DO $$
DECLARE
    test_tenant_id    UUID := 'f9000000-0000-0000-0000-000000000001';
    test_plan_id      UUID := 'f9000000-0000-0000-0000-000000000002';
    test_sub_id       UUID := 'f9000000-0000-0000-0000-000000000003';
BEGIN

-- ---------------------------------------------------------------------------
-- Setup: insert a valid tenant, plan, and subscription to use as FK targets
-- ---------------------------------------------------------------------------
INSERT INTO tenants (id, name, slug)
    VALUES (test_tenant_id, 'Test Tenant', 'test-tenant');

INSERT INTO plans (id, name, price_cents, billing_cycle)
    VALUES (test_plan_id, 'test-plan', 500, 'monthly');

INSERT INTO subscriptions (id, tenant_id, plan_id, status, current_period_start, current_period_end)
    VALUES (test_sub_id, test_tenant_id, test_plan_id, 'active',
            now(), now() + interval '30 days');


-- ===========================================================================
-- tenants
-- ===========================================================================

-- TEST: slug must be unique
BEGIN
    INSERT INTO tenants (name, slug) VALUES ('Dupe Slug Corp', 'test-tenant');
    RAISE WARNING 'FAIL: tenants — duplicate slug was accepted';
EXCEPTION WHEN unique_violation THEN
    RAISE INFO 'PASS: tenants — duplicate slug rejected';
END;

-- TEST: slug format rejects uppercase
BEGIN
    INSERT INTO tenants (name, slug) VALUES ('Bad Slug Corp', 'Bad-Slug');
    RAISE WARNING 'FAIL: tenants — uppercase slug was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: tenants — uppercase slug rejected';
END;

-- TEST: slug format rejects spaces
BEGIN
    INSERT INTO tenants (name, slug) VALUES ('Bad Slug Corp', 'bad slug');
    RAISE WARNING 'FAIL: tenants — slug with space was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: tenants — slug with space rejected';
END;

-- TEST: slug format rejects trailing hyphen
BEGIN
    INSERT INTO tenants (name, slug) VALUES ('Bad Slug Corp', 'bad-slug-');
    RAISE WARNING 'FAIL: tenants — trailing hyphen slug was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: tenants — trailing hyphen slug rejected';
END;

-- TEST: deleted_at must be after created_at
BEGIN
    INSERT INTO tenants (name, slug, created_at, deleted_at)
        VALUES ('Time Paradox Ltd', 'time-paradox',
                '2025-01-15 10:00:00+00', '2025-01-14 10:00:00+00');
    RAISE WARNING 'FAIL: tenants — deleted_at before created_at was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: tenants — deleted_at before created_at rejected';
END;

-- TEST: name is NOT NULL
BEGIN
    INSERT INTO tenants (name, slug) VALUES (NULL, 'null-name-corp');
    RAISE WARNING 'FAIL: tenants — NULL name was accepted';
EXCEPTION WHEN not_null_violation THEN
    RAISE INFO 'PASS: tenants — NULL name rejected';
END;


-- ===========================================================================
-- plans
-- ===========================================================================

-- TEST: price_cents cannot be negative
BEGIN
    INSERT INTO plans (name, price_cents, billing_cycle)
        VALUES ('negative-price', -1, 'monthly');
    RAISE WARNING 'FAIL: plans — negative price_cents was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: plans — negative price_cents rejected';
END;

-- TEST: billing_cycle only accepts valid values
BEGIN
    INSERT INTO plans (name, price_cents, billing_cycle)
        VALUES ('bad-cycle', 1000, 'weekly');
    RAISE WARNING 'FAIL: plans — invalid billing_cycle was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: plans — invalid billing_cycle rejected';
END;

-- TEST: api_limit cannot be zero
BEGIN
    INSERT INTO plans (name, price_cents, billing_cycle, api_limit)
        VALUES ('zero-limit', 1000, 'monthly', 0);
    RAISE WARNING 'FAIL: plans — api_limit of 0 was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: plans — api_limit of 0 rejected';
END;

-- TEST: api_limit cannot be negative
BEGIN
    INSERT INTO plans (name, price_cents, billing_cycle, api_limit)
        VALUES ('negative-limit', 1000, 'monthly', -100);
    RAISE WARNING 'FAIL: plans — negative api_limit was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: plans — negative api_limit rejected';
END;

-- TEST: plan name must be unique
BEGIN
    INSERT INTO plans (name, price_cents, billing_cycle)
        VALUES ('test-plan', 999, 'monthly');
    RAISE WARNING 'FAIL: plans — duplicate plan name was accepted';
EXCEPTION WHEN unique_violation THEN
    RAISE INFO 'PASS: plans — duplicate plan name rejected';
END;


-- ===========================================================================
-- users
-- ===========================================================================

-- TEST: email must be unique within a tenant
BEGIN
    INSERT INTO users (tenant_id, email, role)
        VALUES (test_tenant_id, 'duplicate@example.com', 'admin');
    INSERT INTO users (tenant_id, email, role)
        VALUES (test_tenant_id, 'duplicate@example.com', 'member');
    RAISE WARNING 'FAIL: users — duplicate email within tenant was accepted';
EXCEPTION WHEN unique_violation THEN
    RAISE INFO 'PASS: users — duplicate email within tenant rejected';
END;

-- TEST: same email is valid across different tenants
DECLARE
    second_tenant_id UUID := 'f9000000-0000-0000-0000-000000000099';
BEGIN
    INSERT INTO tenants (id, name, slug)
        VALUES (second_tenant_id, 'Second Tenant', 'second-tenant');
    INSERT INTO users (tenant_id, email, role)
        VALUES (test_tenant_id,   'shared@example.com', 'admin');
    INSERT INTO users (tenant_id, email, role)
        VALUES (second_tenant_id, 'shared@example.com', 'admin');
    RAISE INFO 'PASS: users — same email accepted across different tenants';
EXCEPTION WHEN unique_violation THEN
    RAISE WARNING 'FAIL: users — same email across tenants was incorrectly rejected';
END;

-- TEST: role only accepts valid values
BEGIN
    INSERT INTO users (tenant_id, email, role)
        VALUES (test_tenant_id, 'badrole@example.com', 'superuser');
    RAISE WARNING 'FAIL: users — invalid role was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: users — invalid role rejected';
END;

-- TEST: email format rejects missing @
BEGIN
    INSERT INTO users (tenant_id, email, role)
        VALUES (test_tenant_id, 'notanemail', 'member');
    RAISE WARNING 'FAIL: users — malformed email was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: users — malformed email rejected';
END;

-- TEST: deleted_at must be after created_at
BEGIN
    INSERT INTO users (tenant_id, email, role, created_at, deleted_at)
        VALUES (test_tenant_id, 'paradox@example.com', 'member',
                '2025-01-15 10:00:00+00', '2025-01-14 10:00:00+00');
    RAISE WARNING 'FAIL: users — deleted_at before created_at was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: users — deleted_at before created_at rejected';
END;

-- TEST: tenant_id must reference a real tenant
BEGIN
    INSERT INTO users (tenant_id, email, role)
        VALUES ('00000000-0000-0000-0000-000000000000', 'ghost@example.com', 'member');
    RAISE WARNING 'FAIL: users — non-existent tenant_id was accepted';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE INFO 'PASS: users — non-existent tenant_id rejected';
END;


-- ===========================================================================
-- subscriptions
-- ===========================================================================

-- TEST: status only accepts valid values
BEGIN
    INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
        VALUES (test_tenant_id, test_plan_id, 'expired',
                now(), now() + interval '30 days');
    RAISE WARNING 'FAIL: subscriptions — invalid status was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: subscriptions — invalid status rejected';
END;

-- TEST: period_end must be after period_start
BEGIN
    INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
        VALUES (test_tenant_id, test_plan_id, 'active',
                now(), now() - interval '1 day');
    RAISE WARNING 'FAIL: subscriptions — period_end before period_start was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: subscriptions — period_end before period_start rejected';
END;

-- TEST: cancelled_at must be set when status = cancelled
BEGIN
    INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end, cancelled_at)
        VALUES (test_tenant_id, test_plan_id, 'cancelled',
                now(), now() + interval '30 days', NULL);
    RAISE WARNING 'FAIL: subscriptions — cancelled status with NULL cancelled_at was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: subscriptions — cancelled status with NULL cancelled_at rejected';
END;

-- TEST: cancelled_at must be NULL when status != cancelled
BEGIN
    INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end, cancelled_at)
        VALUES (test_tenant_id, test_plan_id, 'active',
                now(), now() + interval '30 days', now());
    RAISE WARNING 'FAIL: subscriptions — active status with cancelled_at set was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: subscriptions — active status with cancelled_at set rejected';
END;

-- TEST: plan_id must reference a real plan
BEGIN
    INSERT INTO subscriptions (tenant_id, plan_id, status, current_period_start, current_period_end)
        VALUES (test_tenant_id, '00000000-0000-0000-0000-000000000000', 'active',
                now(), now() + interval '30 days');
    RAISE WARNING 'FAIL: subscriptions — non-existent plan_id was accepted';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE INFO 'PASS: subscriptions — non-existent plan_id rejected';
END;


-- ===========================================================================
-- invoices
-- ===========================================================================

-- TEST: amount_cents cannot be negative
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date)
        VALUES (test_tenant_id, test_sub_id, -1, 'open', current_date + 7);
    RAISE WARNING 'FAIL: invoices — negative amount_cents was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: invoices — negative amount_cents rejected';
END;

-- TEST: status only accepts valid values
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date)
        VALUES (test_tenant_id, test_sub_id, 1000, 'overdue', current_date + 7);
    RAISE WARNING 'FAIL: invoices — invalid status was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: invoices — invalid status rejected';
END;

-- TEST: paid_at must be set when status = paid
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date, paid_at)
        VALUES (test_tenant_id, test_sub_id, 1000, 'paid', current_date + 7, NULL);
    RAISE WARNING 'FAIL: invoices — paid status with NULL paid_at was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: invoices — paid status with NULL paid_at rejected';
END;

-- TEST: paid_at must be NULL when status != paid
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date, paid_at)
        VALUES (test_tenant_id, test_sub_id, 1000, 'open', current_date + 7, now());
    RAISE WARNING 'FAIL: invoices — non-paid status with paid_at set was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: invoices — non-paid status with paid_at set rejected';
END;

-- TEST: due_date cannot be before created_at date
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date, created_at)
        VALUES (test_tenant_id, test_sub_id, 1000, 'open',
                '2020-01-01', '2025-04-01 00:00:00+00');
    RAISE WARNING 'FAIL: invoices — due_date before created_at was accepted';
EXCEPTION WHEN check_violation THEN
    RAISE INFO 'PASS: invoices — due_date before created_at rejected';
END;

-- TEST: subscription_id must reference a real subscription
BEGIN
    INSERT INTO invoices (tenant_id, subscription_id, amount_cents, status, due_date)
        VALUES (test_tenant_id, '00000000-0000-0000-0000-000000000000',
                1000, 'open', current_date + 7);
    RAISE WARNING 'FAIL: invoices — non-existent subscription_id was accepted';
EXCEPTION WHEN foreign_key_violation THEN
    RAISE INFO 'PASS: invoices — non-existent subscription_id rejected';
END;

-- ---------------------------------------------------------------------------
-- Teardown: roll back everything — no test data persists
-- ---------------------------------------------------------------------------
RAISE INFO '---';
RAISE INFO 'All assertions complete. Rolling back.';

END $$;